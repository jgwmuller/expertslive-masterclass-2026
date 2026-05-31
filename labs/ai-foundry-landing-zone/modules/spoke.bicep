// ============================================================================
//  modules/spoke.bicep — workload spoke
// ----------------------------------------------------------------------------
//  The CAF "workload" spoke. Two subnets, per the MS Learn reference plan:
//    - agent subnet  192.168.0.0/24  DELEGATED to Microsoft.App/environments
//        This is where Foundry injects the Standard Agent compute. /24 is the
//        recommended size (/27 minimum) because the delegation to
//        Microsoft.App/environments (Azure Container Apps) consumes addresses.
//        ONE agent subnet per Foundry resource — it cannot be shared.
//    - pe subnet     192.168.1.0/24  hosts the private endpoints
//
//  A route table on BOTH subnets forces 0.0.0.0/0 to the hub Azure Firewall,
//  so egress is observable + controllable (no public egress for the agent).
//
//  Spoke address space MUST be a valid RFC1918 range (10/8, 172.16-31/12, or
//  192.168/16). CGNAT 100.64.0.0/10 is NOT supported (MS Learn limitation).
// ============================================================================

@description('Spoke region — MUST equal the Foundry account region (MS Learn hard requirement: Foundry colocated with the VNet).')
param location string

param spokeVnetName string
param spokeAddressSpace string
param agentSubnetPrefix string
param peSubnetPrefix string

@description('Private IP of the hub Azure Firewall — next hop for the default route.')
param firewallPrivateIp string

// ---- Route table: force all egress to the hub firewall -------------------
resource egressRouteTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'rt-spoke-egress'
  location: location
  properties: {
    // Disable BGP propagation so a peered gateway can't override our forced tunnel.
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-azfw'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// ---- Spoke VNet ----------------------------------------------------------
resource spokeVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: spokeVnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ spokeAddressSpace ] }
    subnets: [
      {
        name: 'snet-agent'
        properties: {
          addressPrefix: agentSubnetPrefix
          // VERIFY-IN-TEST: delegation type string must be exactly
          // 'Microsoft.App/environments'. This is what makes the subnet eligible
          // for Standard Agent network injection. Subnet must be /27 or larger;
          // /24 recommended.
          delegations: [
            {
              name: 'aca-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
          routeTable: { id: egressRouteTable.id }
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          // PE NICs require network policies disabled on their subnet.
          privateEndpointNetworkPolicies: 'Disabled'
          routeTable: { id: egressRouteTable.id }
        }
      }
    ]
  }
}

// ---- Outputs -------------------------------------------------------------
output spokeVnetId  string = spokeVnet.id
output agentSubnetId string = '${spokeVnet.id}/subnets/snet-agent'
output peSubnetId    string = '${spokeVnet.id}/subnets/snet-pe'
