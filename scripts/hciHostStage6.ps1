[CmdletBinding()]
param (
  [Parameter()]
  [String]
  $resourceGroupName,

  [Parameter()]
  [String]
  $subscriptionId,

  [Parameter()]
  [String]
  $tenantId,

  [Parameter()]
  [String]
  $location,

  [Parameter()]
  [String]
  $accountName,

  [Parameter()]
  [String]
  $adminUsername,

  [Parameter()]
  [String]
  $adminPw
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

# export or re-import local administrator credential
# we do this to support re-run of the template. If deployed, the HCI node password will be set to the password provided in the template, but future re-runs will generate a new password.
If (!(Test-Path -Path 'C:\temp\hciHostDeployAdminCred.xml')) {
  log "Exporting local '$($adminUsername)' credential (for re-use if script is re-run)..."
  $adminCred = [pscredential]::new($adminUsername, (ConvertTo-SecureString -AsPlainText -Force $adminPw))
  $adminCred | Export-Clixml -Path 'C:\temp\hciHostDeployAdminCred.xml'
} Else {
  log "Re-importing local '$($adminUsername)' credential..."
  $adminCredOld = Import-Clixml -Path 'C:\temp\hciHostDeployAdminCred.xml'

  $newCredFileName = 'hciHostDeployAdminCred_{0}.xml' -f (Get-Date -Format 'yyyyMMddHHmmss')
  log "Renaming the old credential file to '$newCredFileName' prevent overwriting..."
  Rename-Item -Path 'C:\temp\hciHostDeployAdminCred.xml' -NewName $newCredFileName

  log "Exporting local '$($adminUsername)' credential (for re-use if script is re-run)..."
  $adminCred = [pscredential]::new($adminUsername, (ConvertTo-SecureString -AsPlainText -Force $adminPw))
  $adminCred | Export-Clixml -Path 'C:\temp\hciHostDeployAdminCred.xml'
}

# get an access token for the VM MSI, which has been granted rights and will be used for the HCI Arc Initialization
$response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' `
  -Headers @{Metadata = 'true' } `
  -UseBasicParsing
$content = $response.Content | ConvertFrom-Json
$t = $content.access_token

# pre-create AD objects
log 'Pre-creating AD objects...'
$deployUserCred = [pscredential]::new('deployUser', (ConvertTo-SecureString -AsPlainText -Force $adminPw))

If (!(Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { Register-PSRepository -Default }
If (!(Get-PackageProvider -Name Nuget -ListAvailable -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -Confirm:$false -Force }
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module AsHciADArtifactsPreCreationTool
New-HciAdObjectsPreCreation -AzureStackLCMUserCredential $deployUserCred -AsHciOUName 'ou=hci,dc=hci,dc=local'

## set the LCM deployUser password to the adminPw value - this aligns the password with the KeyVault during re-runs
log 'Setting deployUser password...'
Set-AdAccountPassword -Identity 'deployUser' -NewPassword (ConvertTo-SecureString -AsPlainText -Force $adminPw) -Reset -Confirm:$false

# initialize arc on hci nodes
log 'Initializing Azure Arc on HCI nodes...'

# wait for VMs to reach 'Running' state
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
while ((Get-VM | Where-Object State -NE 'Running') -and $stopwatch.Elapsed.TotalMinutes -lt 15) {
  log "Waiting for HCI node VMs to reach 'Running' state. Current state: $((Get-VM) | Select-Object Name,State)..."
  Start-Sleep -Seconds 30
}

If ($stopwatch.Elapsed.TotalMinutes -ge 15) {
  log "HCI node VMs did not reach 'Running' state within 15 minutes. Exiting..."
  Write-Error "HCI node VMs did not reach 'Running' state within 15 minutes. Exiting..."
  Exit 1
}

log "Creating PSSessions to HCI nodes [$((Get-VM).Name -join ',')]..."
try {
  If ($adminCredOld) {
    log 'Using old local administrator credential from exported CliXML...'
    $localAdminCred = $adminCredOld
  } Else {
    log 'Using new local administrator credential from parameter input...'
    $localAdminCred = $adminCred
  }
  $sessions = New-PSSession -VMName (Get-VM).Name -Credential $localAdminCred -ErrorAction Stop

  if ($sessions.Count -eq 2 -and $sessions.State -eq 'Opened') {
    log "PSSessions to HCI nodes [$((Get-VM).Name -join ',')] created successfully."
  } else {
    log "Failed to create PSSessions to HCI nodes [$((Get-VM).Name -join ',')]. Exiting..."
    Write-Error "Failed to create PSSessions to HCI nodes [$((Get-VM).Name -join ',')]. Exiting..."
    Exit 1
  }
} catch {
  log "Failed to create PSSessions to HCI nodes [$((Get-VM).Name -join ',')]. $_ Exiting..."
  Write-Error "Failed to create PSSessions to HCI nodes [$((Get-VM).Name -join ',')]. $_ Exiting..."
  Exit 1
}

# update local admin password to match the adminPw value
If ($adminCredOld) {
  log 'Updating local administrator password to match the adminPw value...'
  Invoke-Command -VMName (Get-VM).Name -Credential $adminCredOld {
    $ErrorActionPreference = 'Stop'

    $adminPw = $args[0]
    $adminUsername = $args[1]

    Write-Host "$($env:computerName):Setting local administrator password to match the adminPw value..."
    $adminCred = [pscredential]::new($adminUsername, (ConvertTo-SecureString -AsPlainText -Force $adminPw))
    Set-LocalUser -Name $adminUsername -Password $adminCred.Password -Confirm:$false
  } -ArgumentList $adminPw, $adminUsername
} Else {
  log "Password for '$($adminUsername)' should already match the adminPw value..."
}

# name net adapters - seems to be required on 2405
log 'Renaming network adapters on HCI nodes...'
$vmNicLocalNamingOut = Invoke-Command -VMName (Get-VM).Name -Credential $adminCred {
  $ErrorActionPreference = 'Stop'

  Get-NetAdapter | ForEach-Object {
    $adapter = $_

    try {
      Write-Output "Getting Hyper-V network adapter name for '$($adapter.Name)' on VM '$($env:COMPUTERNAME)'..."
      $newAdapterName = Get-NetAdapterAdvancedProperty -RegistryKeyword HyperVNetworkAdapterName -Name $adapter.Name | Select-Object -ExpandProperty DisplayValue
    } catch {
      Write-Output "Failed to get Hyper-V network adapter name for '$($adapter.Name)' on VM '$($env:COMPUTERNAME)'. Ensure DeviceNaming is turned on for the VM Network Adapter! $_ Exiting..."
      Write-Error "Failed to get Hyper-V network adapter name for '$($adapter.Name)'  on VM '$($env:COMPUTERNAME)'. Ensure DeviceNaming is turned on for the VM Network Adapter! $_ Exiting..." -ErrorAction Stop
      Exit 1
    }

    If ($adapter.InterfaceAlias -ne $newAdapterName) {
      Write-Output "Renaming network adapter '$($adapter.InterfaceAlias)' to '$newAdapterName'  on VM '$($env:COMPUTERNAME)'..."
      Rename-NetAdapter -Name $adapter.Name -NewName $newAdapterName
    } Else {
      Write-Output "Network adapter '$($adapter.InterfaceAlias)' is already named correctly on VM '$($env:COMPUTERNAME)'..."
    }
  }
}

log "VM NIC local naming output: $vmNicLocalNamingOut"

## test node internet connection - required for Azure Arc initialization
$firstVM = Get-VM | Select-Object -First 1
$testNodeInternetConnection = Invoke-Command -VMName $firstVM.Name -Credential $adminCred {
  [bool](Invoke-RestMethod ipinfo.io -UseBasicParsing)
}

If (!$testNodeInternetConnection) {
  log "Node '$($firstVM.name)' does not have internet connection. Check RRAS NAT configuration. Exiting..."
  Write-Error "Node '$($firstVM.name)' does not have internet connection. Check RRAS NAT configuration. Exiting..."
  Exit 1
}

## create jobs for each node to initialize Azure Arc
$arcInitializationJobs = Invoke-Command -VMName (Get-VM).Name -Credential $adminCred {
  $ErrorActionPreference = 'Stop'

  $t = $args[0]
  $subscriptionId = $args[1]
  $resourceGroupName = $args[2]
  $tenantId = $args[3]
  $location = $args[4]
  $accountName = $args[5]

  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
  If (!(Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) { Register-PSRepository -Default }
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  Install-Module Az.Resources, AzsHCI.ARCinstaller -Force
  Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted
  Invoke-AzStackHciArcInitialization -SubscriptionID $subscriptionId -ResourceGroup $resourceGroupName -TenantID $tenantId -Cloud AzureCloud -AccountID $accountName -ArmAccessToken $t -Region $location
} -AsJob -ArgumentList $t, $subscriptionId, $resourceGroupName, $tenantId, $location, $accountName

log 'Waiting up to 30 minutes for Azure Arc initialization to complete on nodes...'

$arcInitializationJobs | Wait-Job -Timeout 1800

# check for failed arc initialization jobs
$arcInitializationJobs | ForEach-Object {
  $job = $_
  Get-Job -Id $job.Id -IncludeChildJob | Receive-Job -ErrorAction SilentlyContinue | ForEach-Object {
    If ($_.Exception) {
      log "Azure Arc initialization failed on node '$($job.Location)' with error: $($_.Exception.Message)"
      Exit 1
    } Else {
      log "Job output: $_"
    }
  }
}
