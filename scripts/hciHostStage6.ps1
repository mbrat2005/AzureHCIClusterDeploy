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
    $location = 'eastus',

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

# get an access token for the VM MSI, which has been granted rights and will be used for the HCI Arc Initialization
$response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' `
                              -Headers @{Metadata="true"} `
							  -UseBasicParsing
$content =$response.Content | ConvertFrom-Json
$t = $content.access_token

# pre-create AD objects
log "Pre-creating AD objects..."
$deployUserCred = [pscredential]::new('deployUser', (ConvertTo-SecureString -AsPlainText -Force $adminPw))

If (!(Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {Register-PSRepository -Default}
If (!(Get-PackageProvider -Name Nuget -ListAvailable -ErrorAction SilentlyContinue)) {Install-PackageProvider -Name NuGet -confirm:$false -force}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module AsHciADArtifactsPreCreationTool
New-HciAdObjectsPreCreation  -AzureStackLCMUserCredential $deployUserCred -AsHciOUName 'ou=hci,dc=hci,dc=local'

# initialize arc on hci nodes
log "Initializing Azure Arc on HCI nodes..."
$cred = [pscredential]::new('administrator', (ConvertTo-SecureString -AsPlainText -Force $adminPw))

log "Creating PSSessions to HCI nodes [$((Get-VM).Name -join ',')]..."
$sessions = New-PSSession -VMName (Get-VM).Name -Credential $cred

## test node internet connection - required for Azure Arc initialization
$testNodeInternetConnection = Invoke-Command $sessions[0] {
    [bool](Invoke-RestMethod ipinfo.io -UseBasicParsing)
}

If (!$testNodeInternetConnection) {
    log "Node '$($sessions[0].ComputerName)' does not have internet connection. Check RRAS NAT configuration. Exiting..."
    Write-Error "Node '$($sessions[0].ComputerName)' does not have internet connection. Check RRAS NAT configuration. Exiting..."
    Exit
}

## create jobs for each node to initialize Azure Arc
$arcInitializationJobs = Invoke-Command $sessions {
    $t = $args[0]
    $subscriptionId = $args[1]
    $resourceGroupName = $args[2]
    $tenantId = $args[3]
    $location = $args[4]
    $accountName = $args[5]

    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    If (!(Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {Register-PSRepository -Default}
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module Az.Resources,AzsHCI.ARCinstaller -Force
    Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted
    Invoke-AzStackHciArcInitialization -SubscriptionID $subscriptionId -ResourceGroup $resourceGroupName -TenantID $tenantId -Cloud AzureCloud -AccountID $accountName -ArmAccessToken $t -Region $location
} -AsJob -ArgumentList $t,$subscriptionId, $resourceGroupName, $tenantId, $location, $accountName

log "Waiting up to 30 minutes for Azure Arc initialization to complete on nodes..."

$arcInitializationJobs | Wait-Job -Timeout 1800
