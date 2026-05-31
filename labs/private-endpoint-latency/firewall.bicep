// ============================================================================
//  Private Endpoint Latency Lab — Firewall module (Parts B & C)
//  "Your routes might be lying" + "Azure Firewall app rules are a proxy"
// ----------------------------------------------------------------------------
//  Opt-in extension wired from main.bicep when deployFirewall = true.
//  Adds a HUB VNet (AzureFirewallSubnet + Azure Firewall + firewall policy),
//  peers it bidirectionally to the existing pelab VNet, and lays down the
//  route table the client subnet uses to send PE traffic via the firewall.
//
//  Part A (the latency reveal) does NOT need any of this — leaving
//  deployFirewall=false keeps the lab at pennies/hour. Azure Firewall is the
//  only meaningful cost add (~$1.25/hr), so this stays off by default.
// ============================================================================

targetScope = 'resourceGroup'

@description('Region for the hub VNet + Azure Firewall. Match the "near" region so peering + routing stay in one region.')
param location string

@description('Name of the existing pelab VNet (the spoke) to peer the hub to. From main.bicep.')
param spokeVnetName string

@description('Resource ID of the existing pelab VNet (the spoke). From main.bicep.')
param spokeVnetId string

@description('Name of the shared privatelink.blob private DNS zone (declared in main.bicep). Linked to the hub so AzFW app rules (Part C) resolve to the PE, not the public IP.')
param blobDnsZoneName string

@description('Azure Firewall SKU tier. Standard is enough for app rules; Premium adds IDPS/TLS-inspection (out of scope for this lab).')
@allowed([
  'Standard'
  'Premium'
])
param firewallTier string = 'Standard'

// ---- Derived names -------------------------------------------------------
var hubVnetName     = 'vnet-hub'
var fwSubnetName    = 'AzureFirewallSubnet' // name is mandatory & case-sensitive
var fwName          = 'azfw-pelab'
var fwPolicyName    = 'azfwpolicy-pelab'
var fwPipName       = 'pip-azfw'
var routeTableName  = 'rt-client-to-fw'
var hubToSpokeName  = 'peer-hub-to-spoke'
var spokeToHubName  = 'peer-spoke-to-hub'

// Hub address space — distinct from the spoke's 10.20.0.0/16.
var hubAddressSpace = '10.30.0.0/16'
var fwSubnetPrefix  = '10.30.0.0/24' // AzureFirewallSubnet must be /26 or larger; /24 is fine.

// ---- Hub VNet with the (mandatory-named) AzureFirewallSubnet -------------
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: hubVnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ hubAddressSpace ]
    }
    subnets: [
      {
        name: fwSubnetName
        properties: {
          addressPrefix: fwSubnetPrefix
        }
      }
    ]
  }
}

// ---- Public IP for the firewall (required even for an internal-only demo) -
resource fwPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: fwPipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ---- Firewall policy ------------------------------------------------------
// Part C lives here: the application rule collection is added/edited live by
// scripts/part-c-firewall.sh, so we ship the policy with an EMPTY rule
// collection group the script can target by name. Shipping it empty keeps the
// "firewall is bypassed until you configure it" story honest in Part B.
resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: fwPolicyName
  location: location
  properties: {
    sku: { tier: firewallTier }
    threatIntelMode: 'Alert'
  }
}

// Empty rule-collection group, priority 200, that part-c-firewall.sh populates
// with the blob application rule. Kept separate so Part B can show the
// firewall in-path-but-passing-nothing before Part C opens the FQDN.
resource fwPolicyRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: fwPolicy
  name: 'pelab-app-rules'
  properties: {
    priority: 200
    ruleCollections: []
  }
}

// ---- Azure Firewall -------------------------------------------------------
resource azfw 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: fwName
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: firewallTier
    }
    firewallPolicy: { id: fwPolicy.id }
    ipConfigurations: [
      {
        name: 'fw-ipconfig'
        properties: {
          subnet: { id: '${hubVnet.id}/subnets/${fwSubnetName}' }
          publicIPAddress: { id: fwPip.id }
        }
      }
    ]
  }
  // The RCG must exist on the policy before the firewall references the policy,
  // otherwise the first deploy can race. Explicit dependsOn keeps it ordered.
  dependsOn: [
    fwPolicyRcg
  ]
}

// ---- Hub <-> Spoke peering (bidirectional) -------------------------------
// PEs inject /32s into directly-peered VNets, so the firewall in the hub DOES
// see the PE /32s once the hub and spoke are directly peered.
resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: hubToSpokeName
  properties: {
    remoteVirtualNetwork: { id: spokeVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// The spoke side of the peering. Declared here (not in main.bicep) so the whole
// hub story is self-contained in this opt-in module.
resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: '${spokeVnetName}/${spokeToHubName}'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ---- Route table for the client subnet -----------------------------------
// Ships EMPTY on purpose. Part B adds routes live so attendees watch the
// behavior change:
//   1. a legacy /32 UDR per PE IP -> firewall  (gets silently bypassed)
//   2. after enabling RouteTableEnabled PE network policies, a single
//      summary /24 UDR -> firewall  (now actually honored)
//
// We create the route table here but DELIBERATELY do NOT associate it to the
// client subnet from Bicep. The client subnet is declared inline inside the
// VNet in main.bicep; re-declaring it from this module to bolt on the route
// table races with main.bicep and can strip the SSH NSG. Instead
// part-b-routes.sh does the association live with:
//   az network vnet subnet update --route-table rt-client-to-fw
// which is also a cleaner teaching moment (attendees see the subnet flip from
// "no route table" to "firewall next-hop").
resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: routeTableName
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: []
  }
}

// ---- Link the blob private DNS zone to the HUB VNet (Part C dependency) ---
// AzFW application rules proxy on SNI and do their OWN DNS lookup. If the
// privatelink.blob zone is NOT linked to the firewall's VNet, AzFW resolves to
// the PUBLIC storage IP and bypasses the PE entirely. Linking it here is the
// whole point of Part C's "DNS-zone-link dependency" reveal.
//
// A zone link can't be shipped "disabled", so it IS created here.
// part-c-firewall.sh demonstrates the dependency by first REMOVING it
// (az network private-dns link vnet delete) to show the bypass, then
// re-creating it. Shipping it present keeps the happy path one command away.
resource blobDnsHubLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${blobDnsZoneName}/link-to-${hubVnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: hubVnet.id }
  }
}

// ---- Outputs (consumed by deploy.sh / part-b / part-c scripts) -----------
output hubVnetName         string = hubVnetName
output firewallName         string = fwName
output firewallPolicyName   string = fwPolicyName
output appRuleCollectionGroup string = fwPolicyRcg.name
output routeTableName       string = routeTableName
output firewallPrivateIp    string = azfw.properties.ipConfigurations[0].properties.privateIPAddress
output hubDnsLinkName       string = 'link-to-${hubVnetName}'
