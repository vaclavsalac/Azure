$GlobalStatus = 0

$PAT = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$(${env:PERSONALACCESSTOKEN})"))

function Get-GitVnetList ($SubscriptionGroup) {
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
    $TenantId = (Get-AzTenant).Id
    $AllChangesAgainstDSC = @()

    foreach ($GitVNet in $RGsBySubscription) {
        $ForEachStatus = 0
        $SubscriptionContext = Set-AzContext -Subscription $GitVNet.Subscription -Tenant $TenantId
        $URLTemplate = "https://dev.azure.com/*/items/VS/" + ($GitVNet.Name).ToLower() + ".json"

        try {
            $TemplateObject = Invoke-WebRequest -Uri $URLTemplate -Headers @{Authorization = "Basic $PAT"} | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            Write-Host ""
            Write-Host -ForegroundColor DarkYellow "No template exist in Git Repository for Resource Group:" $GitVNet.Name
            $ForEachStatus ++
        }

        if ($ForEachStatus -eq 0) {
            try {
                Get-AzResourceGroup -ResourceGroupName $GitVNet.Name -DefaultProfile $SubscriptionContext -ErrorAction Stop
            }
            catch {
                Write-Host ""
                Write-Host -ForegroundColor DarkYellow "No Resource Group exist with name:" $GitVNet.Name
                $ForEachStatus ++
            }

            if ($ForEachStatus -eq 0) {
                # $TemplateFileText = [System.IO.File]::ReadAllText("./Downloads/Azure/_Backup_VNets/vs-rg-1.json")
                # $TemplateObject = ConvertFrom-Json $TemplateFileText -AsHashtable
                
                $Result = Get-AzResourceGroupDeploymentWhatIfResult -TemplateObject $TemplateObject -ResourceGroupName $GitVNet.Name

                if ($Result.Status -eq "Succeeded") {
                    $ResultChangeType = $Result.Changes.ChangeType | Select-Object -Unique | Where-Object {$PSItem.ChangeType -ne "NoChange"}

                    if (($ResultChangeType.Count -ne 0)) {

                        $ChangesAgainstRG = $Result.Changes | Where-Object {$PSItem.ChangeType -ne "NoChange"} | Select-Object -Property FullyQualifiedResourceId, ChangeType
                        $ChangesAgainstRG |
                            ForEach-Object {
                                $AllChangesAgainstDSC += [PSCustomObject]@{FullyQualifiedResourceId = $PSItem.FullyQualifiedResourceId; ChangeType = $PSItem.ChangeType}
                            }
                    
                    } else {}

                } else {
                    Write-Host ""
                    Write-Host -ForegroundColor DarkYellow "Test Resource Group Deployment FAILED for:" $GitVNet.Name
                }
            } else {}
        }
        else {
            Write-Host -ForegroundColor DarkYellow $GitVNet.Name "cannot be deployed due to the above reasons."
        }
    }

    if ($AllChangesAgainstDSC.Count -ne 0) {
        Write-Host -ForegroundColor DarkYellow ">>> >>> >>> Changes made in the monitored RGs compared to DSC <<< <<< <<<"
        $AllChangesAgainstDSC |
            ForEach-Object {
                Write-Host $PSItem.FullyQualifiedResourceId "............" $PSItem.ChangeType
            }
        Write-Host ""
        
        throw "${env:SUBSCRIPTION} -> -> Some changes were made to the monitored RGs!"

    } else {}
} else {}