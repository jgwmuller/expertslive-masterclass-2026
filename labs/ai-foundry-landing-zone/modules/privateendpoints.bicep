// ============================================================================
//  modules/privateendpoints.bicep — the EXPLICIT private endpoints
// ----------------------------------------------------------------------------
//  *** KEY LESSON OF THIS LAB ***
//  Private endpoints to Foundry, Azure AI Search, Azure Storage, and Azure
//  Cosmos DB are NOT auto-created when you deploy your Foundry resource (MS
//  Learn note). You MUST create them yourself. Forget one and DNS may resolve
//  (if the zone exists) but the agent can't reach that data plane — or the
//  name NXDOMAINs entirely. The demo deliberately shows the failure, then fixes
//  it by adding the missing PE.
//
//  Each PE here:
//    1. lands a NIC in snet-pe (192.168.1.0/24)
//    2. targets the right `groupId` (sub-resource) of its PaaS service
//    3. wires a privateDnsZoneGroup so the A-record is written into the right
//       privatelink zone automatically
//
//  groupId mapping (sub-resource):
//    Foundry account ......... 'account'   -> registers into all three Foundry
//                                             zones (cognitiveservices/openai/services.ai)
//    Azure AI Search ......... 'searchService' -> privatelink.search.windows.net
//    Azure Storage ........... 'blob'      -> privatelink.blob.core.windows.net
//    Azure Cosmos DB ......... 'Sql'       -> privatelink.documents.azure.com
// ============================================================================

@description('PE region — same as the spoke VNet.')
param location string

@description('Resource id of snet-pe (192.168.1.0/24).')
param peSubnetId string

param foundryAccountId string
param storageAccountId string
param searchServiceId string
param cosmosDbId string

// Foundry uses THREE zones for its one 'account' PE.
param dnsZoneCognitiveServicesId string
param dnsZoneOpenAiId string
param dnsZoneServicesAiId string
param dnsZoneSearchId string
param dnsZoneCosmosId string
param dnsZoneBlobId string

// ---------------------------------------------------------------------------
// FOUNDRY private endpoint  (groupId 'account')
// VERIFY-IN-TEST: groupId for the Foundry account PE has been 'account' in the
// Apr-2026 docs. Its DNS zone group writes A-records into ALL THREE Foundry
// zones. If a deploy reports an invalid groupId, check the live target's
// privateLinkResources via `az network private-link-resource list`.
// ---------------------------------------------------------------------------
resource peFoundry 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-foundry'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'foundry'
        properties: {
          privateLinkServiceId: foundryAccountId
          groupIds: [ 'account' ]
        }
      }
    ]
  }
}

resource peFoundryDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peFoundry
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'cognitiveservices', properties: { privateDnsZoneId: dnsZoneCognitiveServicesId } }
      { name: 'openai',            properties: { privateDnsZoneId: dnsZoneOpenAiId } }
      { name: 'servicesai',        properties: { privateDnsZoneId: dnsZoneServicesAiId } }
    ]
  }
}

// ---------------------------------------------------------------------------
// AZURE AI SEARCH private endpoint  (groupId 'searchService')
// ---------------------------------------------------------------------------
resource peSearch 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-search'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'search'
        properties: {
          privateLinkServiceId: searchServiceId
          groupIds: [ 'searchService' ]
        }
      }
    ]
  }
}

resource peSearchDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peSearch
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'search', properties: { privateDnsZoneId: dnsZoneSearchId } }
    ]
  }
}

// ---------------------------------------------------------------------------
// AZURE STORAGE (blob) private endpoint  (groupId 'blob')
// ---------------------------------------------------------------------------
resource peStorage 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-storage-blob'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'storage-blob'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource peStorageDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peStorage
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: dnsZoneBlobId } }
    ]
  }
}

// ---------------------------------------------------------------------------
// AZURE COSMOS DB (Sql) private endpoint  (groupId 'Sql')
// ---------------------------------------------------------------------------
resource peCosmos 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-cosmos-sql'
  location: location
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'cosmos-sql'
        properties: {
          privateLinkServiceId: cosmosDbId
          groupIds: [ 'Sql' ]
        }
      }
    ]
  }
}

resource peCosmosDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peCosmos
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'cosmos', properties: { privateDnsZoneId: dnsZoneCosmosId } }
    ]
  }
}

// ---- Outputs -------------------------------------------------------------
output foundryPeName string = peFoundry.name
output searchPeName  string = peSearch.name
output storagePeName string = peStorage.name
output cosmosPeName  string = peCosmos.name
