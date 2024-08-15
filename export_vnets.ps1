$GlobalStatus = 0

function Get-GitVnetList ($SubscriptionGroup) {
    $PAT = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$(${env:PERSONALACCESSTOKEN})"))
    $GitVNetListURL = "https://dev.azure.com/*/items/VS/vnets-list.json"
    try {
        $GitVNetList = Invoke-RestMethod -Uri $GitVNetListURL -Headers @{Authorization = "Basic $PAT"} -Method Get -ContentType application/json | Select-Object -ExpandProperty VNetsRG | Where-Object {$PSItem.Subscription -eq $SubscriptionGroup} -ErrorAction Stop

        return $GitVNetList
    }
    catch {
        Write-Host -ForegroundColor Red "VNets-List.json cannot be found in the Git repository!"
        $GlobalStatus ++
    }
}

$RGsBySubscription = Get-GitVnetList (${env:SUBSCRIPTION})

if ($GlobalStatus -eq 0) {
    $LocalJsonsToClean = @()
    $TenantId = (Get-AzTenant).Id
    $StorageAccountName = ${env:STORAGEACCOUNT}
    $StorageAccountContext = Set-AzContext -Subscription ${env:SUBSCRIPTION} -Tenant $TenantId
    $StorageAccount = Get-AzStorageAccount -DefaultProfile $StorageAccountContext | Where-Object {$PSItem.StorageAccountName -eq $StorageAccountName}
    $StorageContainers = $StorageAccount | Get-AzStorageContainer -DefaultProfile $StorageAccountContext
    $StorageBlobs = $StorageContainers | ForEach-Object {Get-AzStorageBlob -DefaultProfile $StorageAccountContext -Container $PSItem.Name -Context $StorageAccount.Context}
    $SubscriptionContext = Set-AzContext -Subscription ${env:SUBSCRIPTION} -Tenant $TenantId
    $ContainerName = "backup-vnetrg-" + $(${env:SUBSCRIPTION}).Replace(" ","-").ToLower()
    [System.Collections.ArrayList]$RGsToVNetTest = @((Get-AzResourceGroup -DefaultProfile $SubscriptionContext).ResourceGroupName)
    $RequiredResourceTypes = @(
        "virtualNetworks",
        "networkSecurityGroups",
        "routeTables"
    )

    foreach ($RG in $RGsBySubscription) {
        $ForEachStatus = 0
        try {
            Get-AzResourceGroup -ResourceGroupName $RG.Name -DefaultProfile $SubscriptionContext -ErrorAction Stop
        }
        catch {
            Write-Host -ForegroundColor Red $RG.Name "does not exist in Azure."
            Write-Host ""
            $ForEachStatus ++
        }

        if ($ForEachStatus -eq 0) {
            ## Using Null-coalescing Operator - ?? - "with default value if true"
            $RGInTest = ((Get-AzResource -ResourceGroupName $RG.Name -DefaultProfile $SubscriptionContext).ResourceType) ?? "NothingToFindHere" | ForEach-Object {$PSItem.Split("/") | Select-Object -Last 1}
            if ((Compare-Object -ReferenceObject $RequiredResourceTypes -DifferenceObject $RGInTest).Count -eq 0) {
                try {
                    $StorageAccount | Get-AzStorageContainer -Name $ContainerName -DefaultProfile $StorageAccountContext -ErrorAction Stop
                }
                catch {
                    $StorageAccount | New-AzStorageContainer $ContainerName.ToLower() -DefaultProfile $StorageAccountContext
                }
    
                $BlobName = ($RG.Name + "-backup-" + $(Get-Date).ToString("yyyyMMdd-HHmmss") + ".json").ToLower()
                $Export = Export-AzResourceGroup -ResourceGroupName $RG.Name -DefaultProfile $SubscriptionContext -SkipAllParameterization -Force
                $LocalJsonsToClean += $RG.Name
                $RGsToVNetTest.Remove(($RGsToVNetTest | Where-Object {$PSItem -eq $RG.Name}))

                Set-AzStorageBlobContent -File $Export.Path -Container $ContainerName -Blob $BlobName -Context $StorageAccount.context -Force
            }
            else {
                Write-Host -ForegroundColor Red $RG.Name "is missing some resource(s)."
                Write-Host ""
            }
        } else {}
    }

    Write-Host -ForegroundColor DarkYellow ">>> >>> >>> Extra RGs with VNet reources <<< <<< <<<"

    $RGsToVNetTest |
        ForEach-Object {
            $RGContext = Set-AzContext -Subscription ${env:SUBSCRIPTION} -Tenant $TenantId
            $RGInTest = ((Get-AzResource -ResourceGroupName $PSItem -DefaultProfile $RGContext).ResourceType) ?? "NothingToFindHere" | ForEach-Object {$PSItem.Split("/") | Select-Object -Last 1}
            if ((Compare-Object -ReferenceObject $RequiredResourceTypes -DifferenceObject $RGInTest).Count -eq 0) {
                Write-Host $PSItem "-" ${env:SUBSCRIPTION}
            } else {}
        }

    Write-Host ""
    Write-Host -ForegroundColor DarkYellow ">>> >>> >>> Blobs removed due to age threshold <<< <<< <<<"

    $StorageBlobs | ForEach-Object {
        $BlobName = $PSItem.Name
        $BlobAge = $PSItem.LastModified.DateTime
        $BlobAgeDiff = ((Get-Date) - $BlobAge).TotalHours

        if ($BlobAgeDiff -gt ([int]${env:BLOBAGETHRESHOLD} * 24)) {
            try {
                Remove-AzStorageBlob -Blob $BlobName -Container $ContainerName -Context $StorageAccount.context -DefaultProfile $SubscriptionContext -Force
                Write-Host $BlobName
            }
            catch {
                Write-Host "Deletion failed for $BlobName."
            }
        }
        else {}
    }
    
    if ($LocalJsonsToClean.Count -ne 0) {
        foreach ($LocalJson in $LocalJsonsToClean) {
            $TestedLocalJson = ((Get-Location).Path + "/" + $LocalJson + ".json")
            
            if ((Test-Path -Path $TestedLocalJson) -eq $true) {
                Remove-Item -Path $TestedLocalJson -Force
            } else {}
        }
    } else {}
}
else {}