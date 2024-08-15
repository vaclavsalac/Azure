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
                New-AzResourceGroup -Name $GitVNet.Name -Location $GitVNet.Location -DefaultProfile $SubscriptionContext
            }

            # New-AzResourceGroupDeployment -ResourceGroupName $GitVNet.Name -TemplateFile ("./" + $GitVNet.Name + ".json") -DefaultProfile $SubscriptionContext -WhatIf
            # New-AzResourceGroupDeployment -ResourceGroupName $GitVNet.Name -TemplateFile ("./" + $GitVNet.Name + ".json") -DefaultProfile $SubscriptionContext -Force -WhatIf
            New-AzResourceGroupDeployment -ResourceGroupName $GitVNet.Name -TemplateObject $TemplateObject -DefaultProfile $SubscriptionContext -Mode Complete -Force
        }
        else {
            Write-Host -ForegroundColor DarkYellow $GitVNet.Name "cannot be deployed due to the above reasons."
        }
    }
} else {}