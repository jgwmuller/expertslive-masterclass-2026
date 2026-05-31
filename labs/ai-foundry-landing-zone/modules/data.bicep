// ============================================================================
//  modules/data.bicep — Bring-Your-Own (BYO) data resources
// ----------------------------------------------------------------------------
//  A Standard private agent REQUIRES you to bring your own:
//    - Azure Storage (blob)   — files
//    - Azure AI Search        — vector store
//    - Azure Cosmos DB (Sql)  — threads / agent state
//  All agent data stays in YOUR tenant. The capability host needs exactly ONE
//  connection to each (see modules/foundry.bicep). Miss one and the capability
//  host create fails ("supports a single, non empty value for ...Connections").
//
//  Every resource has PUBLIC NETWORK ACCESS = DISABLED. With no PE + no DNS,
//  the agent cannot reach them at all — which is the point. The PEs are created
//  separately in modules/privateendpoints.bicep (they are NOT auto-created).
//
//  These data resources MAY live in a different region from Foundry (only the
//  Foundry account must be colocated with the VNet) — but cross-region adds
//  data-transfer cost, so this lab keeps them in `location`.
// ============================================================================

@description('Region for the BYO data resources. Keep == Foundry region to avoid cross-region data-transfer cost.')
param location string

@description('Suffix for globally-unique names.')
param suffix string

var storageName = 'stagent${suffix}'
var searchName  = 'srch-agent-${suffix}'
var cosmosName  = 'cosmos-agent-${suffix}'

// ---- Storage (blob) — public access Disabled ----------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// ---- Azure AI Search — public access Disabled ----------------------------
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  sku: { name: 'standard' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'disabled'
    // Foundry connects to Search with AAD; disable local API keys for a
    // defence-in-depth, identity-only posture (CAF/WAF security).
    // VERIFY-IN-TEST: if your Foundry connection uses an API key instead of
    // AAD, flip this to false and add the appropriate `authOptions` block.
    disableLocalAuth: true
  }
}

// ---- Cosmos DB (SQL / Core) — public access Disabled ----------------------
// CAPACITY NOTE: `isZoneRedundant: false` is set here, but Azure has still
// returned `ServiceUnavailable` for Cosmos in `eastus` (2026-05-25) and
// `westeurope` (2026-05-26) with error text mentioning "zonal redundant
// accounts" — apparently Microsoft's error message is generic regardless of
// the actual full-capacity bucket. If you hit this on workshop day, the
// reliable fallback is to try another region. A future polish could probe
// Cosmos capacity per region before deploying; today we accept the variance.
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true   // identity-only (CAF/WAF security)
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false   // explicit; capacity errors are not AZ-bound (see above)
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

// ---- Outputs -------------------------------------------------------------
output storageAccountId   string = storage.id
output storageAccountName string = storageName
output searchServiceId    string = search.id
output searchServiceName  string = searchName
output cosmosDbId         string = cosmos.id
output cosmosDbName       string = cosmosName
