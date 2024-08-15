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
    $BackupDate = ${env:DATEOFBACKUP}
    $StorageAccountName = ${env:STORAGEACCOUNT}
    $StorageAccountContext = Set-AzContext -Subscription ${env:SUBSCRIPTION} -Tenant $TenantId
    $StorageAccount = Get-AzStorageAccount -DefaultProfile $StorageAccountContext | Where-Object {$PSItem.StorageAccountName -eq $StorageAccountName}
    $StorageContainers = $StorageAccount | Get-AzStorageContainer -DefaultProfile $StorageAccountContext
    $StorageBlobs = $StorageContainers | ForEach-Object {Get-AzStorageBlob -DefaultProfile $StorageAccountContext -Container $PSItem.Name -Context $StorageAccount.Context}
    $StorageBlobNames = ($StorageBlobs.Name).Split("-backup-") | Where-Object {$PSItem -notlike "*.json"} | Select-Object -Unique
    $SubscriptionContext = Set-AzContext -Subscription ${env:SUBSCRIPTION} -Tenant $TenantId
    $ContainerName = "backup-vnetrg-" + $(${env:SUBSCRIPTION}).Replace(" ","-").ToLower()
    [System.Collections.ArrayList]$StorageBlobNamesFiltered = @(($StorageBlobs.Name).Split("-backup-") | Where-Object {$PSItem -notlike "*.json"} | Select-Object -Unique)

    $AllRGs = @()
    [System.Collections.ArrayList]$AllRGsFiltered = @()

    $RGsWithError = @()

    (Get-AzResourceGroup -DefaultProfile $SubscriptionContext).ResourceGroupName | ForEach-Object {
        $AllRGs += $PSItem
        $AllRGsFiltered += $PSItem
    }

    $RGsBySubscription |
        ForEach-Object {
            $GitVNet = $PSItem
            $SubscriptionContext = Set-AzContext -Subscription $GitVNet.Subscription -Tenant $TenantId
            if ($StorageBlobNames -contains $GitVNet.Name) {
                try {
                    Get-AzResourceGroup -ResourceGroupName $GitVNet.Name -DefaultProfile $SubscriptionContext -ErrorAction Stop
                }
                catch {
                    New-AzResourceGroup -Name $GitVNet.Name -Location $GitVNet.Location -DefaultProfile $SubscriptionContext
                }

                $Blob = $StorageBlobs | Where-Object {$PSItem.Name -like "$($GitVNet.Name)*"} | Where-Object {$PSItem.Name -like "*$BackupDate*"} | Sort-Object -Property Name -Descending | Select-Object -First 1
                $BackupToRestore = Get-AzStorageBlobContent -Blob $Blob.Name -Container $ContainerName -Context $StorageAccount.Context -Force
                $LocalJsonsToClean += $Blob.Name
                $StorageBlobNamesFiltered.Remove(($GitVNet.Name).ToLower())
                $AllRGsFiltered.Remove(($AllRGsFiltered | Where-Object {$PSItem -eq $GitVNet.Name}))

                New-AzResourceGroupDeployment -ResourceGroupName $GitVnet.Name -TemplateFile $BackupToRestore.Name -DefaultProfile $SubscriptionContext
                # New-AzResourceGroupDeployment -ResourceGroupName $GitVnet.Name -TemplateFile $BackupToRestore.Name -DefaultProfile $SubscriptionContext -Mode Complete -Force -WhatIf
            }
            elseif (($StorageBlobNames -notcontains $GitVNet.Name) -and ($AllRGs -contains $GitVNet.Name)) {
                $RGsWithError += "$($GitVnet.Name) | Blob = NO | Azure = YES | Git = YES"
                $AllRGsFiltered.Remove(($AllRGsFiltered | Where-Object {$PSItem -eq $GitVNet.Name}))
            }
            elseif (($StorageBlobNames -notcontains $GitVNet.Name) -and ($AllRGs -notcontains $GitVNet.Name)) {
                $RGsWithError += "$($GitVnet.Name) | Blob = NO | Azure = NO | Git = YES"
            } else {}
        }

    Write-Host ""
    Write-Host -ForegroundColor DarkYellow ">>> >>> >>> Extra Blobs <<< <<< <<<"

    $StorageBlobs |
        ForEach-Object {
            $StorageBlob = $PSItem
            $StorageBlobNamesFiltered | ForEach-Object {
                if ($StorageBlob.Name -like "$PSItem*") {
                    Write-Host $StorageBlob.Name
                } else {}
            } |
        Sort-Object
    }

    Write-Host ""
    Write-Host -ForegroundColor DarkYellow ">>> >>> >>> Extra RGs with VNet reources <<< <<< <<<"

    $AllRGsFiltered |
        Sort-Object |
        ForEach-Object {
            $RequiredResourceTypes = @(
                "virtualNetworks",
                "networkSecurityGroups",
                "routeTables"
            )
            $RGTest = ((Get-AzResource -ResourceGroupName $PSItem -DefaultProfile $SubscriptionContext).ResourceType) ?? "NothingToFindHere" | ForEach-Object {$PSItem.Split("/") | Select-Object -Last 1}
            if ((Compare-Object -ReferenceObject $RequiredResourceTypes -DifferenceObject $RGTest).Count -eq 0) {
                Write-Host $PSItem "-" ${env:SUBSCRIPTION}
            } else {}
        }

    Write-Host ""
    Write-Host -ForegroundColor Red ">>> >>> >>> RGs with Error <<< <<< <<<"

    $RGsWithError | ForEach-Object {
        Write-Host $PSItem
    }

    Write-Host ""

    if ($LocalJsonsToClean.Count -ne 0) {
        foreach ($LocalJson in $LocalJsonsToClean) {
            $TestedLocalJson = ((Get-Location).Path + "/" + $LocalJson)
            
            if ((Test-Path -Path $TestedLocalJson) -eq $true) {
                Remove-Item -Path $TestedLocalJson -Force
            } else {}
        }
    } else {}

} else {}