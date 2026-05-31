// ============================================================================
//  modules/privatedns.bicep — the six privatelink zones
// ----------------------------------------------------------------------------
//  Foundry private networking needs SIX private DNS zones (MS Learn DNS-zone
//  table). The Foundry account ALONE needs three (its three data-plane
//  hostnames resolve into different zones):
//      privatelink.cognitiveservices.azure.com   (cognitiveservices.azure.com)
//      privatelink.openai.azure.com              (openai.azure.com)
//      privatelink.services.ai.azure.com         (services.ai.azure.com)
//  Plus one each for the BYO data resources:
//      privatelink.search.windows.net            (Azure AI Search)
//      privatelink.documents.azure.com           (Azure Cosmos DB, Sql)
//      privatelink.blob.core.windows.net         (Azure Storage, blob)
//
//  Every zone is linked to BOTH the spoke (where the agent + PEs live) AND the
//  hub (so the jump box resolves the same private A-records when an attendee
//  runs nslookup from inside the VNet). registrationEnabled = false everywhere.
//
//  If you front this with a custom DNS server / Private Resolver instead, add a
//  conditional forwarder for each PUBLIC zone to the Azure DNS virtual server
//  168.63.129.16 (MS Learn).
// ============================================================================

@description('Resource id of the hub VNet to link each zone to.')
param hubVnetId string

@description('Resource id of the spoke VNet to link each zone to.')
param spokeVnetId string

var zoneNames = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.search.windows.net'
  'privatelink.documents.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'   // privatelink.blob.core.windows.net in public cloud
]

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for name in zoneNames: {
  name: name
  location: 'global'
}]

// Link every zone to the spoke VNet.
resource spokeLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (name, i) in zoneNames: {
  parent: zones[i]
  name: 'link-spoke'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: spokeVnetId }
  }
}]

// Link every zone to the hub VNet too (so the jump box resolves the same IPs).
resource hubLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (name, i) in zoneNames: {
  parent: zones[i]
  name: 'link-hub'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: hubVnetId }
  }
}]

// ---- Outputs: zone ids, by purpose (consumed by the PE module) -----------
output zoneCognitiveServicesId string = zones[0].id
output zoneOpenAiId            string = zones[1].id
output zoneServicesAiId        string = zones[2].id
output zoneSearchId            string = zones[3].id
output zoneCosmosId            string = zones[4].id
output zoneBlobId              string = zones[5].id
