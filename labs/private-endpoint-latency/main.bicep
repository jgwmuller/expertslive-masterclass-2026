// ============================================================================
//  Private Endpoint Latency Lab
//  "A Private Endpoint never carries data" — simplified single-client topology
// ----------------------------------------------------------------------------
//  Simplified single-client design:
//   - ONE client VM + BOTH private endpoints live LOCALLY (Region A / "near").
//   - The two storage accounts they target sit in TWO different regions.
//   - Latency from the client to each storage differs entirely by the
//     storage account's REAL region — even though both PEs are local NICs in
//     the same subnet. Proof: the PE is a control-plane shim, never a hop.
// ============================================================================

targetScope = 'resourceGroup'

@description('Region for the client VM, the VNet, and BOTH private endpoints (the "near" region).')
param location string = resourceGroup().location

@description('Region for the FAR storage account — geographically distant from "location" to dramatize latency.')
param farLocation string = 'germanywestcentral'

@description('Admin username for the client VM.')
param adminUsername string = 'azureuser'

@description('SSH public key (the contents of e.g. ~/.ssh/id_rsa.pub) for the client VM.')
@secure()
param adminSshPublicKey string

@description('Source IP in CIDR form allowed to SSH to the client VM, e.g. 203.0.113.5/32. deploy.sh detects this for you.')
param allowedSshSourceCidr string

@description('Client VM size. B1s is plenty for an mtr-based latency demo.')
param vmSize string = 'Standard_B1s'

@description('Short suffix to keep storage account names globally unique.')
param suffix string = take(uniqueString(resourceGroup().id), 8)

@description('Opt-in: deploy the hub VNet + Azure Firewall for Parts B & C. Leave false for the cheap Part-A-only latency reveal (AzFW is ~$1.25/hr).')
param deployFirewall bool = false

@description('Azure Firewall SKU tier (only used when deployFirewall=true). Standard is enough for the app-rules proxy demo.')
@allowed([
  'Standard'
  'Premium'
])
param firewallTier string = 'Standard'

// ---- Derived names -------------------------------------------------------
var vnetName         = 'vnet-pelab'
var clientSubnetName = 'snet-client'
var peSubnetName     = 'snet-pe'
var clientSubnetPrefix = '10.20.1.0/24'
var peSubnetPrefix     = '10.20.2.0/24'
var blobDnsZoneName  = 'privatelink.blob.${environment().suffixes.storage}'
var nearStorageName  = 'stnear${suffix}'
var farStorageName   = 'stfar${suffix}'

// ---- NSG: SSH only from the deployer ------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-client'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Deployer'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedSshSourceCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// ---- VNet with a client subnet and a private-endpoint subnet -------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.20.0.0/16' ]
    }
    subnets: [
      {
        name: clientSubnetName
        properties: {
          addressPrefix: clientSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          // Disable PE network policies so the PE NICs can be created here.
          // Part B flips this to RouteTableEnabled live to make UDRs win.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ---- Client VM (Ubuntu 24.04) with public IP locked down by NSG ----------
resource clientPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-client'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-client'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/${clientSubnetName}' }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: clientPip.id }
        }
      }
    ]
  }
}

resource clientVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-client'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'vm-client'
      adminUsername: adminUsername
      // cloud-init installs mtr/dig and drops /usr/local/bin/lab-on-vm.sh
      customData: loadFileAsBase64('cloud-init.yaml')
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: clientNic.id } ]
    }
  }
}

// ---- Two storage accounts: one NEAR (Region A), one FAR (Region B) -------
// Public network access disabled so ALL traffic must use the private endpoint.
resource nearStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: nearStorageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource farStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: farStorageName
  location: farLocation
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// ---- Private DNS zone (shared) + link to the VNet ------------------------
resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: blobDnsZoneName
  location: 'global'
}

resource blobDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobDnsZone
  name: 'link-to-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// ---- NEAR private endpoint (local NIC -> Region A storage) ---------------
resource nearPe 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-near-blob'
  location: location
  properties: {
    subnet: { id: '${vnet.id}/subnets/${peSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'near-blob'
        properties: {
          privateLinkServiceId: nearStorage.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource nearPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: nearPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: blobDnsZone.id }
      }
    ]
  }
}

// ---- FAR private endpoint (LOCAL NIC in Region A -> Region B storage) -----
// This is the crux: the PE NIC sits in Region A, but its target storage is
// in Region B. The PE registers a LOCAL A-record, yet the data plane still
// round-trips to Region B.
resource farPe 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-far-blob'
  location: location
  properties: {
    subnet: { id: '${vnet.id}/subnets/${peSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'far-blob'
        properties: {
          privateLinkServiceId: farStorage.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource farPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: farPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: blobDnsZone.id }
      }
    ]
  }
}

// ---- Parts B & C: opt-in hub VNet + Azure Firewall -----------------------
// Only deployed when deployFirewall=true. Everything firewall-related lives in
// firewall.bicep so Part A stays a clean, cheap latency reveal.
module firewall 'firewall.bicep' = if (deployFirewall) {
  name: 'firewall-module'
  params: {
    location: location
    spokeVnetName: vnetName
    spokeVnetId: vnet.id
    blobDnsZoneName: blobDnsZoneName
    firewallTier: firewallTier
  }
  // The blob DNS zone (declared above) must exist before the module links it
  // to the hub VNet.
  dependsOn: [
    blobDnsZone
  ]
}

// ---- Outputs (consumed by deploy.sh) -------------------------------------
output clientPublicIp      string = clientPip.properties.ipAddress
output adminUsername       string = adminUsername
output nearStorageBlobFqdn string = '${nearStorageName}.blob.${environment().suffixes.storage}'
output farStorageBlobFqdn  string = '${farStorageName}.blob.${environment().suffixes.storage}'
output nearRegion          string = location
output farRegion           string = farLocation

// Names the Part B / Part C scripts need (stable, so emitted unconditionally).
output vnetName            string = vnetName
output clientSubnetName    string = clientSubnetName
output peSubnetName        string = peSubnetName
output clientSubnetPrefix  string = clientSubnetPrefix
output peSubnetPrefix      string = peSubnetPrefix
output blobDnsZoneName     string = blobDnsZoneName

// Firewall outputs — only meaningful when deployFirewall=true.
// Uses Bicep's null-conditional access (`.?`) + null-coalescing (`??`) so the
// type checker stops warning BCP318. The ternary form `deployFirewall ? ... : ''`
// is logically safe but Bicep can't statically prove it.
output deployedFirewall    bool   = deployFirewall
output firewallName        string = firewall.?outputs.firewallName ?? ''
output firewallPolicyName  string = firewall.?outputs.firewallPolicyName ?? ''
output appRuleCollectionGroup string = firewall.?outputs.appRuleCollectionGroup ?? ''
output routeTableName      string = firewall.?outputs.routeTableName ?? ''
output firewallPrivateIp   string = firewall.?outputs.firewallPrivateIp ?? ''
output hubVnetName         string = firewall.?outputs.hubVnetName ?? ''
output hubDnsLinkName      string = firewall.?outputs.hubDnsLinkName ?? ''
