[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $adminUsername,

    [Parameter()]
    [string]
    $adminPw,

    [Parameter()]
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

Function Test-ADConnection {
    try {
        If ((Get-Service -Name 'ADWS' -ErrorAction SilentlyContinue).Status -ne 'Running') { return $false }
        $env:ADPS_LoadDefaultDrive = 0
        Import-Module -Name ActiveDirectory -ErrorAction Stop
        [bool](Get-ADDomainController -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue)
    }
    catch {
        $false
    }
}

$ErrorActionPreference = 'Stop'

# create hyperv switches
log "Creating Hyper-V switches..."
$existingSwitches = Get-VMSwitch
If ($existingSwitches.Name -notcontains 'external' ) { New-VMSwitch -Name external -AllowManagementOS:$true -NetAdapterName Ethernet }
If ($existingSwitches.Name -notcontains 'hciNodeCompInternal' ) { New-VMSwitch -Name hciNodeCompInternal -SwitchType Internal }
If ($existingSwitches.Name -notcontains 'hciNodeMgmtInternal' ) { New-VMSwitch -Name hciNodeMgmtInternal -SwitchType Internal }
If ($existingSwitches.Name -notcontains 'hciNodeStoragePrivate' ) { New-VMSwitch -Name hciNodeStoragePrivate -SwitchType Private }

# add IPs for host
log "Adding IPs for host..."
$existingIPs = Get-NetIPAddress
If ($existingIPs.IPAddress -notcontains '172.20.0.1') { New-NetIPAddress -InterfaceAlias 'vEthernet (hciNodeMgmtInternal)' -IPAddress 172.20.0.1 -PrefixLength 24 }
If ($existingIPs.IPAddress -notcontains '10.0.0.1') { New-NetIPAddress -InterfaceAlias 'vEthernet (hciNodeCompInternal)' -IPAddress 10.0.0.1 -PrefixLength 24 }

# configure NAT
Restart-Service RemoteAccess

log "Configuring NAT..."

netsh routing ip nat uninstall
netsh routing ip nat install
netsh routing ip nat set global tcptimeoutmins=1440 udptimeoutmins=1 loglevel=ERROR
netsh routing ip nat add interface name="vEthernet (external)" mode=FULL
If (!$?) {
    $message = "Failed to run netsh command: ''netsh routing ip nat add interface name='vEthernet (external)' mode=FULL''."
    log $message
    Write-Error $message
}
netsh routing ip nat add interface name="vEthernet (hciNodeCompInternal)" mode=PRIVATE
If (!$?) {
    $message = "Failed to run netsh command: ''netsh routing ip nat add interface name='vEthernet (hciNodeCompInternal)' mode=PRIVATE''."
    log $message
    Write-Error $message
}
netsh routing ip nat add interface name="vEthernet (hciNodeMgmtInternal)" mode=PRIVATE
If (!$?) {
    $message = "Failed to run netsh command: ''netsh routing ip nat add interface name='vEthernet (hciNodeMgmtInternal)' mode=PRIVATE''."
    log $message
    Write-Error $message
}

# create DHCP scopes
log "Creating DHCP scopes..."
$existingScopes = Get-DhcpServerv4Scope
If ($existingScopes.name -notcontains 'HCIComp') { Add-DhcpServerv4Scope -StartRange 10.0.0.10 -EndRange 10.0.0.250 -Name HCIComp -State Active -SubnetMask 255.255.255.0 }
If ($existingScopes.name -notcontains 'HCIMgmt') { Add-DhcpServerv4Scope -StartRange 172.20.0.10 -EndRange 172.20.0.250 -Name HCIMgmt -State Active -SubnetMask 255.255.255.0 }

# test DC connectivity before attempting to authorize DHCP server in AD
log "Testing DC connectivity..."
$count = 0
While (!(Test-ADConnection) -and $count -lt 120) {
    Start-Sleep -Seconds 5
    log "Waiting for AD Web Services to be available..."
    $count++
}

# authorize DHCP servers in AD for DNS updates
log "Authorizing DHCP servers in AD for DNS updates..."
try {
    $existingAuthorizedServers = Get-DhcpServerInDC -ErrorAction Stop
}
catch {
    log "Failed to query authorized DHCP servers in AD. Waiting 120 seconds before retrying..."
    Start-Sleep -Seconds 120
    $existingAuthorizedServers = Get-DhcpServerInDC
}

If ($existingAuthorizedServers.IPAddress -notcontains '172.20.0.1') { Add-DhcpServerInDC -DnsName "$($env:COMPUTERNAME).hci.local" -IPAddress 172.20.0.1 }
If ($existingAuthorizedServers.IPAddress -notcontains '10.0.0.1') { Add-DhcpServerInDC -DnsName "$($env:COMPUTERNAME).hci.local" -IPAddress 10.0.0.1 }

# set router and dns options for mgmt DHCP scope
log "Setting router and dns options for mgmt DHCP scope..."
Set-DhcpServerv4OptionValue -ScopeId 172.20.0.0 -DnsDomain hci.local -DnsServer 172.20.0.1 -Router 172.20.0.1

# create HCI node VMs
log "Creating HCI node VMs..."
$existingVMs = Get-VM
For ($i = 1; $i -le $hciNodeCount; $i++) {
    $hciNodeName = "hcinode$i"
    $hciNodePath = "C:\diskMounts\$hciNodeName"

    If ($existingVMs.name -notcontains $hciNodeName) { new-vm -Name $hciNodeName -MemoryStartupBytes 32GB -BootDevice VHD -SwitchName hciNodeMgmtInternal -Path C:\diskMounts\ -VHDPath "$hciNodePath\hci_os.vhdx" -Generation 2 }
}

# configure HCI node VMs
log "Configuring HCI node VMs..."
Get-VM | Set-VMProcessor -ExposeVirtualizationExtensions $true -Count 16
if (Get-VMNetworkAdapter -Name 'Network Adapter' -VMName * -ErrorAction SilentlyContinue) { Rename-VMNetworkAdapter -NewName mgmt -VMName * -Name 'Network Adapter' }
Get-VM | Get-VMNetworkAdapter -Name 'mgmt' | Set-VMNetworkAdapter -DeviceNaming On

# add additional NICs to HCI node VMs
log "Adding additional NICs to HCI node VMs..."
ForEach ($existingVM in (Get-VM)) {
    $existingNICs = Get-VMNetworkAdapter -VM $existingVM
    If ($existingNICs.name -notcontains 'comp0') { $existingVM | Add-VMNetworkAdapter -Name comp0 -SwitchName hciNodeCompInternal -DeviceNaming On }
    If ($existingNICs.name -notcontains 'comp1') { $existingVM | Add-VMNetworkAdapter -Name comp1 -SwitchName hciNodeCompInternal -DeviceNaming On }
    If ($existingNICs.name -notcontains 'smb0') { $existingVM | Add-VMNetworkAdapter -Name smb0 -SwitchName hciNodeStoragePrivate -DeviceNaming On -Passthru | Set-VMNetworkAdapterVlan -Trunk -AllowedVlanIdList '711' -NativeVlanId 0 }
    If ($existingNICs.name -notcontains 'smb1') { $existingVM | Add-VMNetworkAdapter -Name smb1 -SwitchName hciNodeStoragePrivate -DeviceNaming On -Passthru | Set-VMNetworkAdapterVlan -Trunk -AllowedVlanIdList '712' -NativeVlanId 0 }
}

# add disks to HCI node VMs
log "Adding disks to HCI node VMs..."
Foreach ($vm in (Get-VM)) {
    (1..4) | ForEach-Object {
        $diskPath = "C:\diskMounts\$($vm.Name)\hciNodeDisk$($_).vhdx"
        If (!(Test-Path -path $diskPath)) {
            New-VHD -Path $diskPath -SizeBytes 1TB -Dynamic
        }
        If ($VM.HardDrives.Path -notcontains $diskPath) {
            Add-VMHardDiskDrive -VMName $vm.Name -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $_ -Path $diskPath
        }
    }
}

# eanble mac soofing on HCI node VMs
log "Enabling MAC spoofing on HCI node VMs..."
Get-VM | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

# define unattend.xml for HCI node VMs template
$unattendSource = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$hciNodeName</ComputerName>
            <RegisteredOrganization>Organization</RegisteredOrganization>
            <RegisteredOwner>Owner</RegisteredOwner>
            <TimeZone>UTC</TimeZone>
        </component>
        <component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <IEHardenAdmin>false</IEHardenAdmin>
        </component>
        <component name="Microsoft-Windows-ErrorReportingCore" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DisableWER>1</DisableWER>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Interfaces>
                <Interface wcm:action="add">
                    <Ipv4Settings>
                        <DhcpEnabled>true</DhcpEnabled>
                    </Ipv4Settings>
                </Interface>
            </Interfaces>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell.exe -command &quot;Get-NetAdapterAdvancedProperty -DisplayName 'Hyper-V Network Adapter Name' | Foreach-Object {`$_ | Get-NetAdapter | Rename-NetAdapter -NewName `$_.DisplayValue}&quot;</CommandLine>
                    <Order>1</Order>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>powershell.exe -command &quot;Enable-WindowsOptionalFeature -Online -FeatureName 'microsoft-hyper-v-online' -all -NoRestart&quot;</CommandLine>
                    <Order>2</Order>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                <CommandLine>powershell.exe -command &quot;Remove-Item -Path &apos;C:\unattend.xml&apos; -Force&quot;</CommandLine>
                <Order>3</Order>
                <RequiresUserInput>false</RequiresUserInput>
            </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <CommandLine>shutdown -r -f -t 0</CommandLine>
                    <Order>4</Order>
                    <RequiresUserInput>false</RequiresUserInput>
            </SynchronousCommand>
            </FirstLogonCommands>
            <AutoLogon>
                <Username>Administrator</Username>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Password>
                    <Value>$adminPw</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$adminPw</Value>
                    <PlainText>True</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>en-us</InputLocale>
            <SystemLocale>en-us</SystemLocale>
            <UILanguage>en-us</UILanguage>
            <UILanguageFallback>en-us</UILanguageFallback>
            <UserLocale>en-us</UserLocale>
        </component>
    </settings>
</unattend>
'@

# inject updated sysp answer file into each HCI node disk
log "Injecting updated sysprep answer file into each HCI node disk..."
For ($i = 1; $i -le $hciNodeCount; $i++) {
    $hciNodeName = "hciNode$i"
    $hciProductKey = ''

    Push-location c:\diskMounts\$hciNodeName

    If (!(Test-Path -Path unattend_injected.status) -and (Get-VM -Name $hciNodeName).State -eq 'Off') {
        $mountedVolume = mount-vhd .\hci_os.vhdx -Passthru | get-disk | Get-Partition | get-volume | Where-Object FileSystemType -eq 'NTFS'

        $clone = $unattendSource.psobject.copy()
        $clone = $ExecutionContext.InvokeCommand.ExpandString($clone)

        Set-Content -Path "$($mountedVolume.DriveLetter):\unattend.xml" -Value $clone -Force

        dismount-vhd .\hci_os.vhdx

        Set-Content 'unattend_injected.status' -Value 'Unattend.xml injected'
    }

    Pop-location
}

# start HCI node VMs
log "Starting HCI node VMs..."
try {
    $errorActionPreference = 'Stop'
    Get-VM | Start-VM
}
catch {
    log "Failed to start HCI node VMs. $_"
    Write-Error "Failed to start HCI node VMs. $_"
}

#wait for vms to boot
log "Waiting for VMs to boot..."
Start-Sleep -Seconds 300
