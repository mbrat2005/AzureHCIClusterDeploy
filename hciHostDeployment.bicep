param location string // all resource except HCI Arc Nodes + HCI resources
param vnetSubnetID string = '' // use to connect the HCI Azure Host VM to an existing VNET in the same region
param useSpotVM bool = false // change to false to use regular priority VM
param hostVMSize string = 'Standard_E32bds_v5' // Azure VM size for the HCI Host VM - must support nested virtualization and have sufficient capacity for the HCI node VMs!
param hciNodeCount int = 2 // number of Azure Stack HCI nodes to deploy
// specify either a VHDX or ISO download URL; if both are specified, the VHDX download URL will be used
param hciVHDXDownloadURL string = ''
param hciISODownloadURL string = 'https://azurestackreleases.download.prss.microsoft.com/dbazure/AzureStackHCI/OS-Composition/10.2405.0.3018/AZURESTACKHCI.25398.469.LCM_2405.0.3018.x64.en-us.iso'
param localAdminUsername string = 'admin-hci'
@secure()
param localAdminPassword string

// vm managed identity used for HCI Arc onboarding
resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  location: location
  name: 'hciHost01Identity'
}

// grant identity owner permissions on the subscription
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().subscriptionId, userAssignedIdentity.name, 'Owner', resourceGroup().id)
  properties: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    principalType: 'ServicePrincipal'
    description: 'Role assigned used for Azure Stack HCI IaC testing pipeline - remove if identity no longer exists!'
  }
}

// optional VNET and subnet for the HCI host Azure VM
resource vnet 'Microsoft.Network/virtualNetworks@2020-11-01' = if (vnetSubnetID == '') {
  name: 'vnet01'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/24']
    }
    subnets: [
      {
        name: 'subnet01'
        properties: {
          addressPrefix: '10.0.0.0/24'
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
              locations: [location]
            }
            {
              service: 'Microsoft.KeyVault'
              locations: [location]
            }
          ]
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2020-11-01' = {
  location: location
  name: 'nic01'
  properties: {
    ipConfigurations: [
      {
        name: 'ipConfig01'
        properties: {
          subnet: {
            id: vnetSubnetID == '' ? vnet.properties.subnets[0].id : vnetSubnetID
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Azure Stack HCI Host VM -
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  location: location
  name: 'hciHost01'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: hostVMSize
    }
    priority: useSpotVM ? 'Spot' : 'Regular'
    evictionPolicy: useSpotVM ? 'Deallocate' : null
    billingProfile: useSpotVM
      ? {
          maxPrice: -1
        }
      : null
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        deleteOption: 'Delete'
      }
      dataDisks: [
        for diskNum in range(1, hciNodeCount): {
          name: 'dataDisk${string(diskNum)}'
          createOption: 'Empty'
          diskSizeGB: 4096
          lun: diskNum
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
          deleteOption: 'Delete'
        }
      ]
      diskControllerType: 'SCSI'
    }
    osProfile: {
      adminPassword: localAdminPassword
      adminUsername: localAdminUsername
      computerName: 'hciHost01'
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
          enableHotpatching: false
        }
      }
    }
    securityProfile: {
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
      securityType: 'TrustedLaunch'
    }
    licenseType: 'Windows_Server'
  }
}

// installs roles and features required for Azure Stack HCI Host VM
resource runCommand1 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand1'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage1.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
}

// schedules a reboot of the VM
resource runCommand2 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand2'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage2.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [runCommand1]
}

// initiates a wait for the VM to reboot
resource wait1 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  location: location
  kind: 'AzurePowerShell'
  name: 'wait1'
  properties: {
    azPowerShellVersion: '3.0'
    scriptContent: 'Start-Sleep -Seconds 90'
    retentionInterval: 'PT6H'
  }
  dependsOn: [runCommand2]
}

// initializes and mounts data disks, downloads HCI VHDX, configures the Azure Stack HCI Host VM with AD, routing, DNS, DHCP
resource runCommand3 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand3'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage3.ps1')
    }
    parameters: [
      {
        name: 'hciVHDXDownloadURL'
        value: hciVHDXDownloadURL
      }
      {
        name: 'hciISODownloadURL'
        value: hciISODownloadURL
      }
      {
        name: 'hciNodeCount'
        value: string(hciNodeCount)
      }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [wait1]
}

// schedules a reboot of the VM
resource runCommand4 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand4'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage4.ps1')
    }
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [runCommand3]
}

// initiates a wait for the VM to reboot - extra time for AD initialization
resource wait2 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  location: location
  kind: 'AzurePowerShell'
  name: 'wait2'
  properties: {
    azPowerShellVersion: '3.0'
    scriptContent: 'Start-Sleep -Seconds 300 #enough time for AD start-up'
    retentionInterval: 'PT6H'
  }
  dependsOn: [runCommand4]
}

// creates hyper-v resources, configures NAT, builds and preps the Azure Stack HCI node VMs
resource runCommand5 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand5'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage5.ps1')
    }
    parameters: [
      {
        name: 'adminUsername'
        value: localAdminUsername
      }
      {
        name: 'hciNodeCount'
        value: string(hciNodeCount)
      }
    ]
    protectedParameters: [
      {
        name: 'adminPw'
        value: localAdminPassword
      }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [wait2]
}

// prepares AD for ASHCI onboarding, initiates Arc onboarding of HCI node VMs
resource runCommand6 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand6'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage6.ps1')
    }
    parameters: [
      {
        name: 'location'
        value: location
      }
      {
        name: 'resourceGroupName'
        value: resourceGroup().name
      }
      {
        name: 'subscriptionId'
        value: subscription().subscriptionId
      }
      {
        name: 'tenantId'
        value: tenant().tenantId
      }
      {
        name: 'accountName'
        value: userAssignedIdentity.properties.principalId
      }
      {
        name: 'adminUsername'
        value: localAdminUsername
      }
    ]
    protectedParameters: [
      {
        name: 'adminPw'
        value: localAdminPassword
      }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [runCommand5]
}

// waits for HCI extensions to be in succeeded state
resource runCommand7 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand7'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage7.ps1')
    }
    parameters: [
      {
        name: 'hciNodeCount'
        value: string(hciNodeCount)
      }
      {
        name: 'resourceGroupName'
        value: resourceGroup().name
      }
    ]
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [runCommand6]
}

output vnetSubnetId string = vnetSubnetID == '' ? vnet.properties.subnets[0].id : vnetSubnetID
