@description('Small beta only; increase only after a measured capacity check.')
@allowed(['Standard_B1ms', 'Standard_B2s'])
param vmSize string = 'Standard_B1ms'
param location string = 'westeurope'
param adminUsername string = 'calltypeadmin'
@description('SSH public key only. Never pass the private key.')
param sshPublicKey string
@description('Administrator public IPv4 CIDR, normally one address /32. Do not use 0.0.0.0/0.')
param adminSshCidr string
@description('Unique public DNS label; resulting FQDN is returned by Azure.')
param dnsLabel string

var prefix = 'calltype-beta'
var tags = { 'managed-by': 'Codex', project: 'calltype', environment: 'beta' }
var cloudInit = '''
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - ca-certificates
runcmd:
  - systemctl enable --now docker
  - mkdir -p /opt/calltype/web
  - chown -R ${adminUsername}:${adminUsername} /opt/calltype
  - chmod 700 /opt/calltype
  - usermod -aG docker ${adminUsername}
'''

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AdminSsh'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminSshCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'WebHttps'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'TurnTcp'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3478'
        }
      }
      {
        name: 'TurnUdp'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Udp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['3478', '49160-49200']
        }
      }
    ]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.71.0.0/16'] }
    subnets: [{ name: 'app', properties: { addressPrefix: '10.71.0.0/24', networkSecurityGroup: { id: nsg.id } } }]
  }
}
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-ip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static', dnsSettings: { domainNameLabel: dnsLabel } }
}
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${prefix}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${prefix}-vm'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: { createOption: 'FromImage', diskSizeGB: 32, managedDisk: { storageAccountType: 'StandardSSD_LRS' } }
    }
    osProfile: {
      computerName: prefix
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'ctbeta${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    accessTier: 'Hot'
  }
}
resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: { deleteRetentionPolicy: { enabled: true, days: 7 } }
}
resource backups 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blob
  name: 'backups'
  properties: { publicAccess: 'None' }
}
output vmName string = vm.name
output publicFqdn string = publicIp.properties.dnsSettings.fqdn
output publicIpv4 string = publicIp.properties.ipAddress
output storageAccountName string = storage.name
