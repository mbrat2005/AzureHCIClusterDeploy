param location string = 'westus3' // all resource except HCI Arc Nodes + HCI resources, which will be in eastus
param vnetSubnetID string = ''
param adminUsername string = 'admin-hci'
@secure()
param adminPassword string

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  location: location
  name: 'hciHost01Identity'
  properties: {
    tenantId: subscription().tenantId
  }
}

// grant identity owner permissions on the subscription
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().subscriptionId, userAssignedIdentity.name, 'Owner', resourceGroup().id)
  properties: {
    principalId: userAssignedIdentity.properties.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    principalType: 'ServicePrincipal'
  }
}

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
      vmSize: 'Standard_E32bds_v5'
    }
    priority: 'Spot'
    evictionPolicy: 'Deallocate'
    billingProfile: {
      maxPrice: -1
    }
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
        {
          createOption: 'Empty'
          diskSizeGB: 4096
          lun: 0
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
        {
          createOption: 'Empty'
          diskSizeGB: 4096
          lun: 1
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
      diskControllerType: 'SCSI'
    }
    osProfile: {
      adminPassword: adminPassword
      adminUsername: adminUsername
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

resource runCommand1 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand1'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage1.ps1')
    }
  }
}

resource runCommand2 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand2'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage2.ps1')
    }
  }
  dependsOn: [runCommand1]
}

resource wait1 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  location: location
  kind: 'AzurePowerShell'
  name: 'wait1'
  properties: {
    azPowerShellVersion: '3.0'
    scriptContent: 'Start-Sleep -Seconds 90'
    retentionInterval: 'PT60M'
  }
  dependsOn: [runCommand2]
}

resource runCommand3 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand3'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage3.ps1')
    }
  }
  dependsOn: [wait1]
}

resource runCommand4 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand4'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage4.ps1')
    }
  }
  dependsOn: [runCommand3]
}

resource wait2 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  location: location
  kind: 'AzurePowerShell'
  name: 'wait2'
  properties: {
    azPowerShellVersion: '3.0'
    scriptContent: 'Start-Sleep -Seconds 300 #enough time for AD start-up'
    retentionInterval: 'PT60M'
  }
  dependsOn: [runCommand4]
}

resource runCommand5 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand5'
  properties: {
    source: {
      script: loadTextContent('./scripts/hciHostStage5.ps1')
    }
    parameters: [
      { name: 'adminUsername', value: adminUsername }
      { name: 'adminPw', value: adminPassword }
    ]
  }
  dependsOn: [wait2]
}

resource runCommand6 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: vm
  location: location
  name: 'runCommand6'
  properties: {
    //runAsUser: 'hci\\admin-fta'
    //runAsPassword: '!'
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

      { name: 'adminUsername', value: adminUsername }
      { name: 'adminPw', value: adminPassword }
    ]
  }
  dependsOn: [runCommand5]
}
