// ============================================================================
//  modules/foundry.bicep — Foundry account + project + model + capability host
// ----------------------------------------------------------------------------
//  *** THIS IS THE VERSION-SENSITIVE PART OF THE LAB. ***
//  Sourced from Microsoft Learn, "Set up private networking for Foundry Agent
//  Service" (Bicep tab, updated 2026-04-14) and the foundry-samples BYO-VNet
//  setup. The resource SHAPES below match the documented model, but the API
//  versions and exact property names for the Foundry account/project/
//  capabilityHost/connections MOVE FAST. Every such resource is flagged
//  `// VERIFY-IN-TEST:` — confirm against the live MS Learn Bicep tab and a
//  `az resource show` after deploy. Do NOT assume these compile cleanly in an
//  old local Bicep CLI; the types may not yet be in your bicep's type cache.
//
//  Foundry "account" == Microsoft.CognitiveServices/accounts with kind 'AIServices'.
//  The project, model deployment, connections and capability host are CHILD
//  resources of that account. Network injection is set on the account's
//  networkInjections / agent-subnet wiring at CREATE time.
// ============================================================================

@description('Foundry account region — MUST equal the spoke VNet region (hard requirement).')
param location string

param foundryName string
param projectName string

@description('Resource id of the delegated agent subnet (Microsoft.App/environments).')
param agentSubnetId string

param modelName string
param modelVersion string
param modelCapacity int

@description('BYO data resource ids for the capability-host connections.')
param storageAccountId string
param searchServiceId string
param cosmosDbId string

// ---- Existing BYO resources (for their data-plane endpoints / names) ------
// Referenced as `existing` so we read endpoints idiomatically. The module
// already depends on the data module via these passed-in ids.
resource byoStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: last(split(storageAccountId, '/'))
}
resource byoCosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: last(split(cosmosDbId, '/'))
}
var searchName = last(split(searchServiceId, '/'))

// ---------------------------------------------------------------------------
// 1) FOUNDRY ACCOUNT (Cognitive Services, kind=AIServices) + NETWORK INJECTION
// ---------------------------------------------------------------------------
// VERIFY-IN-TEST: api-version + the `networkInjections` property shape. As of
// the Apr-2026 MS Learn Bicep tab, the Standard-private-agent account carries:
//   - publicNetworkAccess: 'Disabled'
//   - networkAcls.defaultAction: 'Deny'
//   - properties.networkInjections[]: the agent-subnet delegation wiring
//     (scenario 'agent', subnetArmId = the delegated /24, useMicrosoftManagedNetwork=false)
// The exact casing/array name has changed across previews — confirm live.
// allowProjectManagement:true enables child Microsoft.CognitiveServices/accounts/projects.
resource foundry 'Microsoft.CognitiveServices/accounts@2026-03-01' = {
  name: foundryName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    // Custom subdomain is REQUIRED for private endpoints + AAD token auth.
    customSubDomainName: foundryName
    publicNetworkAccess: 'Disabled'
    allowProjectManagement: true
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
    // VERIFY-IN-TEST: network injection into the delegated agent subnet.
    // This is what places the Standard Agent compute inside snet-agent.
    // Property name has appeared as `networkInjections` (array) in the
    // Apr-2026 docs. If your bicep type cache rejects it, keep this block and
    // verify the exact schema against the MS Learn Bicep tab / `az rest`.
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 2) gpt-4o MODEL DEPLOYMENT (child of the account)
// ---------------------------------------------------------------------------
// VERIFY-IN-TEST: model `version` must be one your subscription/region offers.
// sku.name 'GlobalStandard' vs 'Standard' depends on quota in your region.
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-03-01' = {
  parent: foundry
  name: modelName
  sku: {
    name: 'GlobalStandard'   // VERIFY-IN-TEST: 'Standard' if GlobalStandard quota unavailable
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

// ---------------------------------------------------------------------------
// 3) FOUNDRY PROJECT (child of the account)
// ---------------------------------------------------------------------------
// VERIFY-IN-TEST: the projects child type + api-version. The project inherits
// the account's network posture; agents are created/run inside the project.
resource project 'Microsoft.CognitiveServices/accounts/projects@2026-03-01' = {
  parent: foundry
  name: projectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: projectName
    description: 'AI Foundry landing-zone lab project (private, hub-spoke).'
  }
  dependsOn: [ modelDeployment ]
}

// ---------------------------------------------------------------------------
// 4) PROJECT CONNECTIONS to the BYO data resources (exactly one each)
// ---------------------------------------------------------------------------
// VERIFY-IN-TEST: connection `category` strings and `target`/`metadata` shapes.
// The capability host requires EXACTLY ONE connection of each kind:
//   storage (blob), vector store (AI Search), thread storage (Cosmos DB).
// Providing fewer than all three fails capability-host creation with:
//   "CapabilityHost supports a single, non empty value for <x>Connections."
// authType 'AAD' uses the project's managed identity (identity-only posture).
resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = {
  parent: project
  name: 'byo-storage'
  properties: {
    category: 'AzureStorageAccount'   // VERIFY-IN-TEST exact category string
    target: byoStorage.properties.primaryEndpoints.blob
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: storageAccountId
    }
  }
}

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = {
  parent: project
  name: 'byo-search'
  properties: {
    category: 'CognitiveSearch'       // VERIFY-IN-TEST exact category string
    target: 'https://${searchName}.search.windows.net'
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServiceId
    }
  }
}

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = {
  parent: project
  name: 'byo-cosmos'
  properties: {
    category: 'CosmosDB'              // VERIFY-IN-TEST exact category string
    target: byoCosmos.properties.documentEndpoint
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: cosmosDbId
    }
  }
}

// ---------------------------------------------------------------------------
// 5) CAPABILITY HOST (account-level + project-level) — wires the agent runtime
// ---------------------------------------------------------------------------
// VERIFY-IN-TEST: capabilityHosts child type, api-version, and the exact
// property names for the three connection arrays. The Apr-2026 docs use a
// project-scoped capabilityHost referencing the three connections by NAME:
//   storageConnections, vectorStoreConnections, threadStorageConnections
// Each MUST be a single-element, non-empty array (see troubleshooting errors).
resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2026-03-01' = {
  parent: foundry
  name: '${foundryName}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [ project ]
}

resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2026-03-01' = {
  parent: project
  name: '${projectName}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
    // The 2026-03-01 schema requires FOUR connection arrays, each with EXACTLY ONE
    // non-empty value. Per the current MS Learn / foundry-samples reference shape:
    //   storageConnections       -> blob storage (file uploads)
    //   threadStorageConnections -> Cosmos DB (agent thread state)
    //   vectorStoreConnections   -> Cosmos DB (used AS the vector store, not Search)
    //   aiServicesConnections    -> Azure AI Search (the RAG / search layer)
    // Earlier preview API versions silently accepted vectorStoreConnections=Search
    // and worked WITHOUT aiServicesConnections; under 2026-03-01 the agent runtime
    // calls AmlRp with the new schema and the missing aiServicesConnections /
    // misassigned vectorStoreConnections fails with cryptic VNet-id errors.
    storageConnections:       [ storageConnection.name ]
    threadStorageConnections: [ cosmosConnection.name ]
    vectorStoreConnections:   [ cosmosConnection.name ]
    aiServicesConnections:    [ searchConnection.name ]
  }
  dependsOn: [
    accountCapabilityHost
    storageConnection
    searchConnection
    cosmosConnection
  ]
}

// ---- Outputs -------------------------------------------------------------
output foundryAccountId          string = foundry.id
output foundryAccountName        string = foundryName
output foundryPrincipalId        string = foundry.identity.principalId
output projectPrincipalId        string = project.identity.principalId
output projectResourceId         string = project.id
