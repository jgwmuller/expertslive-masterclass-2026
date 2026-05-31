// ============================================================================
//  Private Endpoint Latency Lab — VARIANT: cross-region topology
//  (client in Region A, both PE NICs in Region B)
// ----------------------------------------------------------------------------
//  Client in REGION A, BOTH private endpoints in REGION B (the "remote"
//  region), storage accounts in BOTH regions.
//
//  The cross-region reveal:
//    Even though BOTH PE NICs live in Region B (Germany, far from the client),
//    the storage account that ALSO lives in Region A (Australia) answers in
//    single-digit ms — because the PE never carries data. The Australian
//    storage is reached directly over Microsoft's backbone, region-to-region,
//    bypassing the German PE NIC entirely.
//
//  Compared to `main.bicep` (the simplified VPN-free variant):
//    - simplified:    both PEs LOCAL to client; far storage is slow (~250 ms)
//    - cross-region:  both PEs in REMOTE region; near storage is fast (~3-5 ms)
//                     -> the dramatic angle: "the PE is in Germany but I'm
//                        hitting Australian storage in 3 ms"
//
//  No VPN gateway. No Azure Firewall. No Parts B/C. Pure Part A reveal.
//  For routes/firewall demos use the standard main.bicep with DEPLOY_FIREWALL=1.
// ============================================================================

targetScope = 'resourceGroup'

@description('Region A — where the CLIENT VM lives. The "wow" reveal needs storage to ALSO exist in this region.')
param clientLocation string = 'australiaeast'

@description('Region B — where BOTH PRIVATE ENDPOINT NICs live. Geographically distant from `clientLocation` to dramatize the reveal.')
param peLocation string = 'germanywestcentral'

@description('Admin username for the client VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for the client VM.')
@secure()
param adminSshPublicKey string

@description('Source IP/CIDR allowed to SSH the client VM. deploy.sh detects this.')
param allowedSshSourceCidr string

@description('Client VM size. B1s is plenty for mtr.')
param vmSize string = 'Standard_B1s'

@description('Short suffix to keep storage account names globally unique.')
param suffix string = take(uniqueString(resourceGroup().id), 8)

// ---- Derived names -------------------------------------------------------
var clientVnetName     = 'vnet-client'      // Region A (client + the single subnet)
var peVnetName         = 'vnet-pe-remote'   // Region B (just the PE subnet)
var clientSubnetName   = 'snet-client'
var peSubnetName       = 'snet-pe'
var clientVnetPrefix   = '10.20.0.0/16'
var clientSubnetPrefix = '10.20.1.0/24'
var peVnetPrefix       = '10.30.0.0/16'     // disjoint from client VNet — required for VNet peering
var peSubnetPrefix     = '10.30.1.0/24'
var blobDnsZoneName    = 'privatelink.blob.${environment().suffixes.storage}'
// Storage names — "near" / "far" reflect distance to the CLIENT (not the PE):
//   regionAStorage  — in REGION A (client's region) -> reached fast despite PE being in B
//   regionBStorage  — in REGION B (PE's region)     -> reached slow because storage is in B
var regionAStorageName = 'staeu${suffix}'   // "the AU storage" in the reveal
var regionBStorageName = 'stbgw${suffix}'   // "the DE storage" in the reveal

// ---- NSG: SSH only from the deployer (Region A) -------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-client'
  location: clientLocation
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

// ---- Client VNet in Region A (just the client subnet) -------------------
resource clientVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: clientVnetName
  location: clientLocation
  properties: {
    addressSpace: { addressPrefixes: [ clientVnetPrefix ] }
    subnets: [
      {
        name: clientSubnetName
        properties: {
          addressPrefix: clientSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---- PE VNet in Region B (just the PE subnet) --------------------------
resource peVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: peVnetName
  location: peLocation
  properties: {
    addressSpace: { addressPrefixes: [ peVnetPrefix ] }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ---- Global (cross-region) VNet peering, both directions ----------------
// Direct peering is REQUIRED for the PE's /32 route to be injected onto the
// client NIC. Without this peering the client cannot resolve / reach the PE.
resource clientToPe 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: clientVnet
  name: 'to-pe-remote'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: { id: peVnet.id }
  }
}

resource peToClient 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: peVnet
  name: 'to-client'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: { id: clientVnet.id }
  }
}

// ---- Client VM (Ubuntu) with locked-down public IP ----------------------
resource clientPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-client'
  location: clientLocation
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-client'
  location: clientLocation
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${clientVnet.id}/subnets/${clientSubnetName}' }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: clientPip.id }
        }
      }
    ]
  }
}

resource clientVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-client'
  location: clientLocation
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'vm-client'
      adminUsername: adminUsername
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

// ---- Storage accounts: ONE in Region A, ONE in Region B ------------------
// Both have publicNetworkAccess=Disabled — the only way to reach them is via
// the PE in Region B. The cross-region peering + PE injection makes this work.
resource regionAStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: regionAStorageName
  location: clientLocation          // SAME region as the client
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource regionBStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: regionBStorageName
  location: peLocation              // SAME region as the PE NICs
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// ---- Private DNS zone (global, linked to BOTH vnets) --------------------
// Linking to both means the CLIENT resolves the storage FQDNs to the PE IPs
// (without DNS the client can't reach the PE). Linking to the PE vnet too is
// MS-recommended for symmetric behaviour.
resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: blobDnsZoneName
  location: 'global'
}

resource blobDnsZoneLinkClient 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobDnsZone
  name: 'link-to-${clientVnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: clientVnet.id }
  }
}

resource blobDnsZoneLinkPe 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobDnsZone
  name: 'link-to-${peVnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: peVnet.id }
  }
}

// ---- Private endpoints — both NICs in Region B (snet-pe in vnet-pe-remote)
// THIS is the load-bearing structural choice: both PEs live REMOTE to the
// client. The client (Region A) reaches them via the global VNet peering.
resource peRegionA 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-region-a-blob'           // PE for the AU storage; PE NIC sits in DE
  location: peLocation
  properties: {
    subnet: { id: '${peVnet.id}/subnets/${peSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'region-a-blob'
        properties: {
          privateLinkServiceId: regionAStorage.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource peRegionADnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: peRegionA
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: blobDnsZone.id } }
    ]
  }
}

resource peRegionB 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-region-b-blob'           // PE for the DE storage; PE NIC also in DE
  location: peLocation
  properties: {
    subnet: { id: '${peVnet.id}/subnets/${peSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'region-b-blob'
        properties: {
          privateLinkServiceId: regionBStorage.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource peRegionBDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: peRegionB
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: blobDnsZone.id } }
    ]
  }
}

// ---- Outputs (consumed by deploy.sh in TOPOLOGY=cross-region mode) ------
output clientPublicIp           string = clientPip.properties.ipAddress
output adminUsername            string = adminUsername
// Storage FQDNs follow the script's NEAR/FAR naming: NEAR=client's region,
// FAR=far from client. Since PEs are now in Region B, BOTH FQDNs resolve to a
// Region B address (the PE NIC IP), but the DATA PLANE goes to:
//   NEAR  -> Region A (client-local backend)  -> ~3-5 ms
//   FAR   -> Region B (PE-local backend)      -> ~250+ ms
output nearStorageBlobFqdn      string = '${regionAStorageName}.blob.${environment().suffixes.storage}'
output farStorageBlobFqdn       string = '${regionBStorageName}.blob.${environment().suffixes.storage}'
output nearRegion               string = clientLocation     // where the NEAR storage backend lives
output farRegion                string = peLocation         // where the FAR storage backend lives
output peRegion                 string = peLocation         // where BOTH PE NICs physically live (cross-region topology)
// Names for completeness — Parts B/C are NOT supported in cross-region mode.
output clientVnetName           string = clientVnetName
output peVnetName               string = peVnetName
output clientSubnetName         string = clientSubnetName
output peSubnetName             string = peSubnetName
output blobDnsZoneName          string = blobDnsZoneName
