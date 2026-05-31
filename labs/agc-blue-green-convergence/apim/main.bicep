// ============================================================================
//  APIM as an AI gateway — Track A continuation of the AGC blue/green lab.
//  Run AFTER the AKS + AGC deploy (../deploy.sh). This module fronts Azure
//  OpenAI privately with API Management and teaches the four GenAI-gateway
//  policies: token-limit, semantic cache, weighted load-balance, circuit breaker.
//
//  Masterclass anchors:
//    - KB 06, "AI Networking patterns" Pattern 1 (Private Endpoints for OpenAI)
//      and Pattern 2 (APIM as an AI Gateway).
//    - Microsoft Learn — APIM GenAI gateway capabilities:
//      https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities
//
//  WHAT THIS BICEP BUILDS
//    - API Management, Developer SKU (1 unit). Developer is the cheapest SKU that
//      still supports the GenAI policies and a real (non-Consumption) gateway.
//    - TWO Azure OpenAI accounts (Microsoft.CognitiveServices/accounts, kind=OpenAI),
//      "primary" and "secondary", each with a gpt-4o-mini deployment. Two accounts
//      (rather than two deployments in one account) gives the load-balance +
//      circuit-breaker demo two genuinely independent backends you can fail one of.
//    - A small APIM VNet (10.226.0.0/24) with two subnets:
//        * snet-pe   — holds the Private Endpoints to both OpenAI accounts
//        * snet-apim — reserved for an OPTIONAL APIM VNet integration / future PE
//      Developer-SKU APIM here is NOT VNet-injected (kept on its public control
//      plane to stay simple + fast); it reaches OpenAI *outbound* via the PEs +
//      private DNS. The VNet is peerable to the AKS-managed VNet — deploy-apim.sh
//      does the peering as an optional step. See README "Networking choice".
//    - Two Private Endpoints (one per OpenAI account) in snet-pe.
//    - The privatelink.openai.azure.com private DNS zone + a VNet link, so
//      *.openai.azure.com resolves to the PE private IPs from inside the VNet.
//    - APIM backends:
//        * one backend per OpenAI account (each pointing at its account's
//          *.openai.azure.com base URL, which resolves privately via the PE)
//        * a load-balanced POOL backend over the two, for the load-balance demo,
//          with a circuit breaker that trips on 429.
//    - An APIM API ("azure-openai") imported against the OpenAI data-plane path
//      and an operation for chat completions.
//
//  WHAT deploy-apim.sh DOES INSTEAD OF BICEP (and why)
//    - Kicks off APIM creation FIRST so its ~30-45 min provisioning overlaps the
//      AKS+AGC build. Bicep alone would block; the script starts it async.
//    - Optionally peers this VNet to the AKS-managed VNet.
//    - Applies the four policy XML fragments to the imported API once APIM is up.
//      (Importing the OpenAI OpenAPI spec + attaching policy XML is far more
//      robust via `az apim` / `az rest` than encoding 4 large XML blobs in Bicep.)
// ============================================================================

targetScope = 'resourceGroup'

@description('Region for APIM + the APIM VNet. Keep this close to the room; APIM Developer SKU is single-region.')
param location string = resourceGroup().location

@description('Primary Azure OpenAI region. Default differs from `location` because many APIM regions (e.g. northeurope) lack `Standard` SKU for gpt-4o (only GlobalProvisionedManaged). swedencentral has Standard. VERIFY-IN-TEST: confirm Standard SKU + chosen model version still available.')
param openAiPrimaryLocation string = 'swedencentral'

@description('Secondary Azure OpenAI region — use a DIFFERENT region to demo cross-region failover/load-balance. eastus2 has Standard SKU for gpt-4o. VERIFY-IN-TEST: confirm Standard SKU + model availability.')
param openAiSecondaryLocation string = 'eastus2'

@description('APIM instance name. Must be globally unique (it becomes <name>.azure-api.net).')
param apimName string = 'apim-ai-gw-${uniqueString(resourceGroup().id)}'

@description('APIM Developer SKU. Cheapest SKU that supports the GenAI policies and a dedicated gateway. NOTE: non-deletable for ~30-45 min after create.')
@allowed([
  'Developer'
])
param apimSku string = 'Developer'

@description('Publisher email shown on the APIM developer portal — required by ARM, not used in the demo.')
param publisherEmail string = 'admin@contoso.com'

@description('Publisher org name — required by ARM.')
param publisherName string = 'Experts Live Masterclass'

@description('Name of the primary Azure OpenAI account. Globally unique; becomes <name>.openai.azure.com.')
param openAiPrimaryName string = 'oai-primary-${uniqueString(resourceGroup().id)}'

@description('Name of the secondary Azure OpenAI account.')
param openAiSecondaryName string = 'oai-secondary-${uniqueString(resourceGroup().id)}'

@description('Model name to deploy in both accounts. Default is gpt-4o (not gpt-4o-mini) because gpt-4o-mini 2024-07-18 was ARM-deprecated 2026-03-31 — and that is its only published version. gpt-4o has multiple non-deprecated versions.')
param modelName string = 'gpt-4o'

@description('Model version. VERIFY-IN-TEST: confirm this version + Standard SKU is available in BOTH chosen regions before the live run; both move regionally.')
param modelVersion string = '2024-11-20'

@description('Tokens-per-minute capacity (in thousands) for each deployment. 8 = 8K TPM, plenty for a demo and cheap.')
@minValue(1)
param modelCapacity int = 8

@description('Address space for the small APIM VNet. Default avoids the AKS-managed VNet (10.224.0.0/12) — but it is INSIDE 10.224.0.0/12, so peering still works while staying clear of the node + ALB subnets. VERIFY-IN-TEST: confirm no overlap with the AKS VNet ranges actually in use.')
param vnetAddressPrefix string = '10.226.0.0/24'

@description('Subnet for the OpenAI Private Endpoints.')
param peSubnetPrefix string = '10.226.0.0/26'

@description('Subnet reserved for optional APIM VNet integration / future PEs.')
param apimSubnetPrefix string = '10.226.0.64/26'

// ---- Names for child resources (kept as vars so deploy-apim.sh can predict them)
var privateDnsZoneName = 'privatelink.openai.azure.com'
var peSubnetName = 'snet-pe'
var apimSubnetName = 'snet-apim'
var vnetName = 'vnet-apim-ai'
var apiName = 'azure-openai'
var backendPrimaryName = 'openai-primary'
var backendSecondaryName = 'openai-secondary'
var backendPoolName = 'openai-pool'

// ============================================================================
//  NETWORK — small APIM VNet, PE subnet, optional APIM subnet
// ============================================================================
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          // PEs need network policies off for the PE NIC by default; we keep
          // them enabled here because we are not putting a UDR /32 trap in front
          // of these PEs (that lesson lives in Lab 1). VERIFY-IN-TEST: if you add
          // a firewall in front, set privateEndpointNetworkPolicies accordingly.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: apimSubnetName
        properties: {
          addressPrefix: apimSubnetPrefix
        }
      }
    ]
  }
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: peSubnetName
}

// ============================================================================
//  PRIVATE DNS — privatelink.openai.azure.com + VNet link
//  Pattern 1 (KB 06): the regional FQDN <acct>.openai.azure.com CNAMEs to the
//  privatelink zone, which the PE registers an A record into. With public access
//  Disabled, this zone is the ONLY way APIM resolves OpenAI to a private IP.
// ============================================================================
resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
}

resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ============================================================================
//  AZURE OPENAI — two accounts, public access DISABLED, each with a deployment
// ============================================================================
// publicNetworkAccess is INTENTIONALLY 'Enabled' here even though the lab is
// branded a "private AI gateway". Why: this APIM is Developer SKU + NOT
// VNet-integrated (kept on its public control plane for simplicity + cost).
// A public APIM cannot reach a `publicNetworkAccess: 'Disabled'` OpenAI account
// via the PE because APIM doesn't see the spoke VNet's private DNS — it
// resolves the OpenAI FQDN to a PUBLIC IP and the account refuses.
// Workaround: enable public access on OpenAI, but `defaultAction: 'Deny'` with
// no ipRules here = nothing can reach the data plane yet. The post-Bicep step
// in deploy-apim.sh reads APIM's outbound public IPs and PATCHes them into
// networkAcls.ipRules so ONLY this APIM can hit OpenAI publicly. Net effect:
// equivalent security posture (APIM is the only allowed caller), without
// serialising the deployment behind APIM's 30-45 min provision time.
// For the stricter "no public endpoint at all" story, VNet-integrate APIM
// (External mode) instead — see the #16 polish task notes in the test report.
resource openAiPrimary 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAiPrimaryName
  location: openAiPrimaryLocation
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: openAiPrimaryName  // required so the account gets an *.openai.azure.com host that a PE can serve
    publicNetworkAccess: 'Enabled'          // deny-by-default ACL below; deploy-apim.sh allowlists APIM's IPs after deploy
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []                           // populated post-deploy from apim.properties.publicIpAddresses
      virtualNetworkRules: []
    }
  }
}

resource openAiSecondary 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: openAiSecondaryName
  location: openAiSecondaryLocation
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: openAiSecondaryName
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Deny'
      ipRules: []                           // populated post-deploy from apim.properties.publicIpAddresses
      virtualNetworkRules: []
    }
  }
}

// Model deployments. sku.name 'Standard' = regional PAYG. Two deployments give
// the load-balance demo two independent targets; fail one and watch APIM reroute.
resource deployPrimary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAiPrimary
  name: modelName
  sku: {
    name: 'Standard'
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

resource deploySecondary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAiSecondary
  name: modelName
  sku: {
    name: 'Standard'
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

// ============================================================================
//  PRIVATE ENDPOINTS — one per OpenAI account, both in snet-pe
// ----------------------------------------------------------------------------
//  Explicit `dependsOn` to the MODEL DEPLOYMENT (not just the account). When a
//  model deployment is added to a Cognitive Services account, the account
//  briefly re-enters `Accepted` state until the model deployment lands. PE
//  creation against an account in `Accepted` state fails with
//      "AccountProvisioningStateInvalid: Account ... in state Accepted"
//  Without these dependsOn, Bicep schedules the PE and the model deployment in
//  parallel and races; with them, the PE waits until the deployment is GA, by
//  which time the account is back to `Succeeded`.
// ============================================================================
resource pePrimary 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${openAiPrimaryName}'
  location: location
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-primary'
        properties: {
          privateLinkServiceId: openAiPrimary.id
          groupIds: [
            'account'   // the group ID for Cognitive Services / OpenAI accounts
          ]
        }
      }
    ]
  }
  dependsOn: [
    deployPrimary
  ]
}

resource peSecondary 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${openAiSecondaryName}'
  location: location
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-secondary'
        properties: {
          privateLinkServiceId: openAiSecondary.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
  dependsOn: [
    deploySecondary
  ]
}

// Register each PE's NIC IP into the privatelink.openai.azure.com zone so the
// regional FQDN resolves privately. The zoneGroup wires the PE to the zone.
resource peDnsPrimary 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pePrimary
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'openai'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

resource peDnsSecondary 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: peSecondary
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'openai'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
}

// ============================================================================
//  API MANAGEMENT — Developer SKU
//  System-assigned identity so APIM can auth to OpenAI with managed identity
//  (the "hide the key" half of Pattern 2). The role assignment that grants
//  "Cognitive Services OpenAI User" to this identity on each account is done in
//  deploy-apim.sh (role assignments are awkward to scope cleanly in this module).
// ============================================================================
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: apimSku
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// ---- APIM backends ---------------------------------------------------------
// One backend per OpenAI account. The URL is the account's data-plane base; it
// resolves to the PE private IP because APIM's outbound DNS uses the zone above.
// VERIFY-IN-TEST: Developer SKU is NOT VNet-injected here, so its OUTBOUND name
// resolution uses Azure-provided DNS. Confirm APIM resolves *.openai.azure.com
// to the PE (it should, since the platform DNS honours the linked private zone
// for the APIM service's own lookups in the same tenant) — if not, switch APIM
// to VNet integration (External/Internal) on snet-apim, or front OpenAI via the
// APIM VNet. This is the single most important thing to validate live.
resource backendPrimary 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendPrimaryName
  properties: {
    protocol: 'http'
    url: 'https://${openAiPrimaryName}.openai.azure.com/openai'
    // Circuit breaker on the individual backend: trip on 429 so the pool routes
    // away from a throttled account, and honour Retry-After when re-closing.
    circuitBreaker: {
      rules: [
        {
          name: 'openai429'
          failureCondition: {
            count: 3
            interval: 'PT1M'           // ISO8601: collect failures over 1 minute
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
            ]
          }
          tripDuration: 'PT1M'         // stay open for 1 minute
          acceptRetryAfter: true       // respect the OpenAI Retry-After header
        }
      ]
    }
  }
}

resource backendSecondary 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendSecondaryName
  properties: {
    protocol: 'http'
    url: 'https://${openAiSecondaryName}.openai.azure.com/openai'
    circuitBreaker: {
      rules: [
        {
          name: 'openai429'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

// ---- Load-balanced POOL backend over the two accounts ----------------------
// type 'Pool' fans one logical backend across the two real ones with weights.
// The load-balance.xml policy targets THIS backend via set-backend-service.
// VERIFY-IN-TEST: the Pool backend type + circuitBreaker shipped via preview API
// versions (2023-05-01-preview onward). On the 2024-05-01 GA version used here
// these properties are present in current docs; if ARM rejects 'type'/'pool',
// bump apiVersion to a *-preview that lists them, or create the pool in
// deploy-apim.sh with `az apim ... ` / `az rest`.
resource backendPool 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendPoolName
  properties: {
    type: 'Pool'
    pool: {
      services: [
        {
          id: backendPrimary.id
          priority: 1
          weight: 50
        }
        {
          id: backendSecondary.id
          priority: 1
          weight: 50
        }
      ]
    }
  }
}

// ---- The Azure OpenAI API exposed by APIM ----------------------------------
// We create the API shell here; deploy-apim.sh imports the OpenAI OpenAPI spec
// into it (most reliable) and attaches the policy XML. path 'openai' means
// callers hit https://<apim>.azure-api.net/openai/... mirroring the native path.
resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiName
  properties: {
    displayName: 'Azure OpenAI'
    path: 'openai'
    protocols: [
      'https'
    ]
    // Pointed at the pool's logical base via the policy; serviceUrl here is a
    // placeholder the per-API policy (set-backend-service backend-id) overrides.
    serviceUrl: 'https://${openAiPrimaryName}.openai.azure.com/openai'
    subscriptionRequired: true
    apiType: 'http'
  }
}

// Default API-level policy: route at the load-balanced pool, auth to OpenAI via
// APIM's managed identity. Without this, the smoke test prints HTTP 500 until
// the operator applies one of the demo policies. Each demo policy in
// apim/policies/*.xml REPLACES this when applied (and each demo includes the
// same `set-backend-service` + `authentication-managed-identity` so the API
// stays functional). When attendees finish a demo, they can either:
//   (a) re-PUT this default policy to "reset" to a working baseline, OR
//   (b) just apply the next demo policy.
resource apiDefaultPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'xml'
    value: '''<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="openai-pool" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''
  }
  dependsOn: [
    backendPool   // ensure the pool exists before the policy that references it
  ]
}

// ============================================================================
//  OUTPUTS (consumed by deploy-apim.sh)
// ============================================================================
output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output openAiPrimaryName string = openAiPrimary.name
output openAiSecondaryName string = openAiSecondary.name
output openAiPrimaryId string = openAiPrimary.id
output openAiSecondaryId string = openAiSecondary.id
output modelDeploymentName string = modelName
output apiName string = apiName
output backendPrimaryName string = backendPrimaryName
output backendSecondaryName string = backendSecondaryName
output backendPoolName string = backendPoolName
output vnetName string = vnet.name
output privateDnsZoneName string = privateDnsZoneName
output location string = location
