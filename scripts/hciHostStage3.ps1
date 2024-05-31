[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $hciVHDXDownloadURL,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int]
    $hciNodeCount
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

# download HCI VHDX
log "Downloading HCI VHDX..."
mkdir c:\ISOs
If (! (Test-Path c:\ISOs\hci_os.vhdx)) {
    [System.Net.WebClient]::new().DownloadFile($hciVHDXDownloadURL, 'c:\isos\hci_os.vhdx')
}

# create mount point directories on C:\
log "Creating mount points..."
For ($i = 0; $i -lt $hciNodeCount; $i++) {
    mkdir "c:\diskmounts\hcinode$($i + 1)"
}

# format and mount disks
log "Formatting and mounting disks..."
$count = 0
$rawDisks = Get-Disk | Where-Object PartitionStyle -eq 'RAW'
$rawDisks |
Initialize-Disk -PartitionStyle GPT -PassThru |
  New-Partition -UseMaximumSize -AssignDriveLetter:$false |
  Format-Volume -FileSystem NTFS |
  Get-Partition |
  Where-Object { $_.type -ne 'Reserved' } |
    ForEach-Object { $count++; mountvol c:\diskMounts\HCINode$count $_.accesspaths[0] }

log "Copying VHDX to mount points..."
For ($i = 0; $i -lt $hciNodeCount; $i++) {
    If (!(Test-Path -Path "c:\diskmounts\hcinode$($i + 1)\hci_os.vhdx")) {
        Copy-Item -Path c:\isos\hci_os.vhdx -Destination "c:\diskmounts\hcinode$($i + 1)"
    }
}

# install RRAS configure for routing
log "Installing RRAS and configuring for routing..."
While (!(Test-Path -Path 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\RemoteAccess\RemoteAccess.psd1')) {
    Start-Sleep -Seconds 5
    log "Waiting for RRAS module to be available..."
}
Import-Module 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\RemoteAccess\RemoteAccess.psd1'
Install-RemoteAccess -VpnType RoutingOnly
Set-Service -Name RemoteAccess -StartupType Automatic -PassThru | Start-Service

# install domain controller
log "Installing AD forest controller..."
Import-Module 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\ADDSDeployment\ADDSDeployment.psd1'
$ADRecoveryPassword = ConvertTo-SecureString -Force -AsPlainText (New-Guid).guid
Install-ADDSForest -DomainName hci.local -DomainNetbiosName hci -ForestMode Default -DomainMode Default -InstallDns:$true -SafeModeAdministratorPassword $ADRecoveryPassword -NoRebootOnCompletion:$true -Force:$true

log "Adding DNS forwarders..."
Import-Module 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\DnsServer\DnsServer.psd1'
Add-DnsServerForwarder -IPAddress 8.8.8.8

# create reboot status file
If (Test-Path -path 'C:\Reboot2Completed.status') {
    log "Reboot has already been completed, skipping..."
}
ElseIf (Test-Path -path 'C:\Reboot2Initiated.status') {
    log "Reboot has already been initiated, skipping..."
}
Else {
    log "Reboot required, creating status file..."
    Set-Content -Path 'C:\Reboot2Required.status' -Value "Reboot 2 Required"
}
