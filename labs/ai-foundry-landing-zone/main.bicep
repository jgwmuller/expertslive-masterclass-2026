// ============================================================================
//  AI Foundry Landing Zone — main.bicep (orchestrator)
// ----------------------------------------------------------------------------
//  An enterprise, WAF/CAF-aligned, hub-and-spoke, fully privately-networked
//  Microsoft Foundry Agent Service (Standard setup with private networking).
//
//  SOURCE OF TRUTH: Microsoft Learn, "Set up private networking for Foundry
//  Agent Service" (last updated 2026-04-14).
//    https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/virtual-networks
//    https://learn.microsoft.com/en-us/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-landing-zone
//
//  Module layout:
//    modules/hub.bicep        — hub VNet, Azure Firewall (+policy), Bastion, jump VM
//    modules/spoke.bicep      — spoke VNet (delegated agent subnet + PE subnet),
//                               peering, route table forcing egress to AzFW
//    modules/data.bicep       — BYO Storage + AI Search + Cosmos DB (public access Disabled)
//    modules/privatedns.bicep — the 6 privatelink zones, linked to hub + spoke
//    modules/foundry.bicep    — Foundry account + project + gpt-4o + capability host
//                               + network injection  (THE version-sensitive part)
//    modules/privateendpoints.bicep — explicit PEs for Foundry/Search/Storage/Cosmos
//                               (these are NOT auto-created — that's a key lesson)
// ============================================================================

targetScope = 'resourceGroup'

// ---- Parameters ----------------------------------------------------------
@description('Region for the Foundry account AND the spoke VNet — they MUST be colocated (MS Learn hard requirement).')
param location string = resourceGroup().location

@description('Region for the hub VNet (Firewall/Bastion/jump box). Can match location; kept separate for clarity.')
param hubLocation string = location

@description('Short suffix to keep globally-unique resource names (storage, cosmos, search, foundry) distinct.')
param suffix string = take(uniqueString(resourceGroup().id), 6)

@description('Admin username for the jump VM.')
param adminUsername string = 'azureuser'

@description('SSH public key (contents of e.g. ~/.ssh/id_rsa.pub) for the jump VM. deploy.sh supplies this.')
@secure()
param adminSshPublicKey string

@description('Jump VM size. B2s is plenty for nslookup/az/python from inside the VNet.')
param vmSize string = 'Standard_B2s'

@description('Model name to deploy on the Foundry account.')
param modelName string = 'gpt-4o'

@description('Model version for the gpt-4o deployment. VERIFY-IN-TEST: pin to a version your region/subscription actually offers.')
param modelVersion string = '2024-11-20'

@description('Model deployment capacity (TPM in thousands). Keep small for a lab.')
param modelCapacity int = 20

// ---- Address plan (hub + spoke) ------------------------------------------
// Spoke uses the MS Learn reference plan (192.168.0.0/16) so the agent subnet
// is the documented /24 delegated to Microsoft.App/environments and the PE
// subnet is the documented /24. The hub is a separate, non-overlapping space.
var hubAddressSpace      = '10.10.0.0/16'
var firewallSubnetPrefix = '10.10.0.0/26'   // name MUST be AzureFirewallSubnet, min /26
var bastionSubnetPrefix  = '10.10.1.0/26'   // name MUST be AzureBastionSubnet, min /26
var jumpSubnetPrefix     = '10.10.2.0/24'

var spokeAddressSpace = '192.168.0.0/16'
var agentSubnetPrefix = '192.168.0.0/24'    // delegated to Microsoft.App/environments (/24 recommended, /27 min)
var peSubnetPrefix    = '192.168.1.0/24'    // hosts the private endpoints

// ---- Names ---------------------------------------------------------------
var hubVnetName   = 'vnet-hub'
var spokeVnetName = 'vnet-spoke'
var foundryName   = 'foundry${suffix}'
var projectName   = 'proj${suffix}'

// =============================================================================
//  1. HUB — firewall (egress control), bastion, jump box
// =============================================================================
module hub 'modules/hub.bicep' = {
  name: 'hub'
  params: {
    location: hubLocation
    hubVnetName: hubVnetName
    hubAddressSpace: hubAddressSpace
    firewallSubnetPrefix: firewallSubnetPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    jumpSubnetPrefix: jumpSubnetPrefix
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    vmSize: vmSize
  }
}

// =============================================================================
//  2. SPOKE — delegated agent subnet + PE subnet, peered to hub, UDR to AzFW
// =============================================================================
module spoke 'modules/spoke.bicep' = {
  name: 'spoke'
  params: {
    location: location
    spokeVnetName: spokeVnetName
    spokeAddressSpace: spokeAddressSpace
    agentSubnetPrefix: agentSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
    firewallPrivateIp: hub.outputs.firewallPrivateIp
  }
}

// ---- Bidirectional VNet peering (hub <-> spoke) --------------------------
// Done at the orchestrator scope so each side can reference the other's VNet
// id without a circular module dependency.
resource hubVnetRef 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: hubVnetName
}
resource spokeVnetRef 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: spokeVnetName
}

resource peerHubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hubVnetRef
  name: 'hub-to-spoke'
  properties: {
    remoteVirtualNetwork: { id: spokeVnetRef.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [ hub, spoke ]
}

resource peerSpokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spokeVnetRef
  name: 'spoke-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnetRef.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [ hub, spoke ]
}

// =============================================================================
//  3. PRIVATE DNS — the 6 privatelink zones, linked to BOTH hub and spoke
// =============================================================================
module privatedns 'modules/privatedns.bicep' = {
  name: 'privatedns'
  params: {
    hubVnetId: hubVnetRef.id
    spokeVnetId: spokeVnetRef.id
  }
  dependsOn: [ hub, spoke ]
}

// =============================================================================
//  4. BYO DATA — Storage + AI Search + Cosmos DB, public access Disabled
//     (mandatory for a Standard private agent: all agent data stays in-tenant)
// =============================================================================
module data 'modules/data.bicep' = {
  name: 'data'
  params: {
    location: location
    suffix: suffix
  }
}

// =============================================================================
//  5. FOUNDRY — account + project + gpt-4o + capability host + net injection
//     VERIFY-IN-TEST: this whole module. API versions/shapes move fast.
// =============================================================================
module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    location: location
    foundryName: foundryName
    projectName: projectName
    agentSubnetId: spoke.outputs.agentSubnetId
    modelName: modelName
    modelVersion: modelVersion
    modelCapacity: modelCapacity
    storageAccountId: data.outputs.storageAccountId
    searchServiceId: data.outputs.searchServiceId
    cosmosDbId: data.outputs.cosmosDbId
  }
  dependsOn: [ privatedns ]
}

// =============================================================================
//  6. PRIVATE ENDPOINTS — explicit PEs for Foundry, Search, Storage, Cosmos.
//     These are NOT auto-created when you deploy Foundry — you MUST create them
//     yourself (MS Learn note). Forget one and DNS may resolve but the agent
//     can't reach its data plane. That gotcha is a lab teaching moment.
// =============================================================================
module privateEndpoints 'modules/privateendpoints.bicep' = {
  name: 'privateEndpoints'
  params: {
    location: location
    peSubnetId: spoke.outputs.peSubnetId
    foundryAccountId: foundry.outputs.foundryAccountId
    storageAccountId: data.outputs.storageAccountId
    searchServiceId: data.outputs.searchServiceId
    cosmosDbId: data.outputs.cosmosDbId
    // DNS zone ids so each PE's privateDnsZoneGroup wires its A-record automatically
    dnsZoneCognitiveServicesId: privatedns.outputs.zoneCognitiveServicesId
    dnsZoneOpenAiId: privatedns.outputs.zoneOpenAiId
    dnsZoneServicesAiId: privatedns.outputs.zoneServicesAiId
    dnsZoneSearchId: privatedns.outputs.zoneSearchId
    dnsZoneCosmosId: privatedns.outputs.zoneCosmosId
    dnsZoneBlobId: privatedns.outputs.zoneBlobId
  }
}

// ---- Outputs (consumed by deploy.sh) -------------------------------------
output hubVnetName            string = hubVnetName
output spokeVnetName          string = spokeVnetName
output firewallPrivateIp      string = hub.outputs.firewallPrivateIp
output bastionName            string = hub.outputs.bastionName
output jumpVmName             string = hub.outputs.jumpVmName
output jumpVmResourceId       string = hub.outputs.jumpVmResourceId
output foundryAccountName     string = foundryName
output foundryProjectName     string = projectName
output agentSubnetId          string = spoke.outputs.agentSubnetId
output peSubnetId             string = spoke.outputs.peSubnetId
output storageAccountName     string = data.outputs.storageAccountName
output searchServiceName      string = data.outputs.searchServiceName
output cosmosDbName           string = data.outputs.cosmosDbName
// FQDNs to nslookup from the jump box (should resolve to 192.168.1.x private IPs)
output foundryCognitiveFqdn   string = '${foundryName}.cognitiveservices.azure.com'
output foundryOpenAiFqdn      string = '${foundryName}.openai.azure.com'
output searchFqdn             string = '${data.outputs.searchServiceName}.search.windows.net'
output blobFqdn               string = '${data.outputs.storageAccountName}.blob.${environment().suffixes.storage}'
output cosmosFqdn             string = '${data.outputs.cosmosDbName}.documents.azure.com'
