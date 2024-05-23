param(
    [Parameter()]
    [String]
    $resourceGroupName,

    [Parameter()]
    [String[]]
    $hciNodeNames

)
Function log {
    Param (
        [string]$message,
        [string]$logPath = 'C:\temp\hciHostDeploy.log'
    )

    If (!(Test-Path -Path C:\temp)) {
        New-Item -Path C:\temp -ItemType Directory
    }
    
    Write-Host $message
    Add-Content -Path $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $message"
}

$ErrorActionPreference = 'Stop'

Login-AzAccount -Identity

log "Waiting for HCI Arc Machines to exist in the resource group '$($resourceGroupName)'..."

While (($arcMachines = Get-AzConnectedMachine -ResourceGroupName $resourceGroupName | Where-Object {$_.name -in ($hciNodeNames)}).Count -lt $hciNodeNames.Count) {
    log "Found '$($arcMachines.Count)' HCI Arc Machines, waiting for '$($hciNodeNames.Count)'..."
    Start-Sleep -Seconds 30
}

log "Waiting for HCI Arc Machine extensions to be installed..."
$allExtensionsReady = $false
while (!$allExtensionsReady) {
    $allExtensionsReadyCheck = $true
    foreach ($arcMachine in $arcMachines) {
        $extensions = Get-AzConnectedMachineExtension -ResourceGroupName $resourceGroupName -MachineName $arcMachine.Name
        if ($extensions.Type -notcontains 'TelemetryAndDiagnostics' -or $extensions.Type -notcontains 'DeviceManagementExtension' -or $extensions.Type -notcontains 'LcmController' -or $extensions.Type -notcontains 'EdgeRemoteSupport') {
            log "Waiting for extensions to be installed on HCI Arc Machine '$($arcMachine.Name)'..."
            $allExtensionsReadyCheck = $false
            continue
        }
        elseIf (($extensionState = $extensions | Where-Object Type -eq 'TelemetryAndDiagnostics').ProvisioningState -ne 'Succeeded') {
            log "Waiting for TelemetryAndDiagnostics extension to be installed on HCI Arc Machine '$($arcMachine.Name)'. Current state: '$($extensionState.ProvisioningState)'..."
            $allExtensionsReadyCheck = $false
        }
        elseIf (($extensionState = $extensions | Where-Object Type -eq 'DeviceManagementExtension').ProvisioningState -ne 'Succeeded') {
            log "Waiting for DeviceManagementExtension extension to be installed on HCI Arc Machine '$($arcMachine.Name)'. Current state: '$($extensionState.ProvisioningState)'..."
            $allExtensionsReadyCheck = $false
        }
        elseIf (($extensionState = $extensions | Where-Object Type -eq 'LcmController').ProvisioningState -ne 'Succeeded') {
            log "Waiting for LcmController extension to be installed on HCI Arc Machine '$($arcMachine.Name)'. Current state: '$($extensionState.ProvisioningState)'..."
            $allExtensionsReadyCheck = $false
        }
        elseIf (($extensionState = $extensions | Where-Object Type -eq 'EdgeRemoteSupport').ProvisioningState -ne 'Succeeded') {
            log "Waiting for EdgeRemoteSupport extension to be installed on HCI Arc Machine '$($arcMachine.Name)'. Current state: '$($extensionState.ProvisioningState)'..."
            $allExtensionsReadyCheck = $false
        }
        else {
            log "All extensions are installed and ready on HCI Arc Machine '$($arcMachine.Name)'"
        }
    }
    $allExtensionsReady = $allExtensionsReadyCheck
    Start-Sleep -Seconds 30
}
