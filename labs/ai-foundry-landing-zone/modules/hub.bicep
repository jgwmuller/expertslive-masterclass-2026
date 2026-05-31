// ============================================================================
//  modules/hub.bicep — platform hub
// ----------------------------------------------------------------------------
//  The CAF "connectivity" hub for this landing zone:
//    - AzureFirewallSubnet + Azure Firewall + Firewall Policy
//        egress allowlist (AzureActiveDirectory service tag + the Container Apps
//        managed-identity FQDNs).  *** NO TLS INSPECTION *** — TLS inspection
//        breaks Foundry/agent auth (cert pinning). MS Learn is explicit: verify
//        no self-signed cert is injected at the firewall.
//    - AzureBastionSubnet + Bastion + a small Linux jump VM, so attendees can
//      reach the private project "from inside the VNet" and run nslookup.
//
//  Egress note: the agent compute lives in the SPOKE's delegated subnet; its
//  default route (0.0.0.0/0) is forced to this firewall by the spoke's route
//  table. So the firewall is the single, observable egress chokepoint.
// ============================================================================

@description('Hub region.')
param location string

param hubVnetName string
param hubAddressSpace string
param firewallSubnetPrefix string
param bastionSubnetPrefix string
param jumpSubnetPrefix string

param adminUsername string
@secure()
param adminSshPublicKey string
param vmSize string

// ---- Hub VNet with the three required subnets ----------------------------
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: hubVnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ hubAddressSpace ] }
    subnets: [
      {
        name: 'AzureFirewallSubnet'   // exact name required by Azure Firewall
        properties: { addressPrefix: firewallSubnetPrefix }
      }
      {
        name: 'AzureBastionSubnet'    // exact name required by Bastion
        properties: { addressPrefix: bastionSubnetPrefix }
      }
      {
        name: 'snet-jump'
        properties: { addressPrefix: jumpSubnetPrefix }
      }
    ]
  }
}

// ---- Public IPs (Firewall + Bastion both need a Standard static PIP) ------
resource firewallPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-azfw'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-bastion'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ---- Azure Firewall Policy: egress allowlist, NO TLS inspection ----------
// We deliberately do NOT configure transportSecurity / a CA certificate. TLS
// inspection would terminate the agent's TLS and present a self-signed cert,
// breaking AAD/Foundry auth. The application rule below matches on SNI/FQDN
// only — no decryption.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: 'afwp-hub'
  location: location
  properties: {
    sku: { tier: 'Standard' }    // Standard is enough; Premium would enable TLS inspection — which we explicitly avoid
    threatIntelMode: 'Alert'
    // NOTE: intentionally no `transportSecurity` block => no TLS inspection.
  }
}

// Azure Firewall requires HOMOGENEOUS rule collections — each FilterRuleCollection
// can hold either NetworkRules OR ApplicationRules, not both. We split here:
//  - allow-agent-egress-network: NetworkRule(s) → AzureActiveDirectory service tag
//  - allow-agent-egress-app    : ApplicationRule(s) → Container Apps managed-identity FQDNs
resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: firewallPolicy
  name: 'agent-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-agent-egress-network'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            // Network rule: allow Entra ID by service tag. The MS Learn firewall
            // guidance says: allow the Container Apps managed-identity FQDNs OR
            // the AzureActiveDirectory service tag. Service tag is the simplest
            // robust option for a lab.
            ruleType: 'NetworkRule'
            name: 'allow-aad'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ '*' ]
            destinationAddresses: [ 'AzureActiveDirectory' ]   // service tag
            destinationPorts: [ '443' ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-agent-egress-app'
        priority: 210
        action: { type: 'Allow' }
        rules: [
          {
            // Application rule: managed-identity / Container Apps control-plane FQDNs.
            // VERIFY-IN-TEST: confirm the exact FQDN list from MS Learn
            //   "Integrate Azure Container Apps with Azure Firewall" (Application rules)
            //   https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall
            // No TLS termination — SNI/FQDN match only.
            ruleType: 'ApplicationRule'
            name: 'allow-containerapps-mi'
            sourceAddresses: [ '*' ]
            protocols: [ { protocolType: 'Https', port: 443 } ]
            targetFqdns: [
              'login.microsoftonline.com'
              'login.microsoft.com'
              '*.identity.azure.net'
              'mcr.microsoft.com'
              '*.data.mcr.microsoft.com'
              'login.windows.net'
            ]
          }
        ]
      }
    ]
  }
}

// ---- Azure Firewall ------------------------------------------------------
resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: 'azfw-hub'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'azfw-ipconfig'
        properties: {
          subnet: { id: '${hubVnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallPip.id }
        }
      }
    ]
  }
  dependsOn: [ ruleCollectionGroup ]
}

// ---- Azure Bastion -------------------------------------------------------
resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'bastion-hub'
  location: location
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: { id: '${hubVnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

// ---- Jump VM (Ubuntu) — the "from inside the VNet" workstation -----------
// Reached via Bastion (no public IP on the VM). Has nslookup/dig + az CLI +
// python via cloud-init so attendees can resolve the private FQDNs and run an
// agent end-to-end from inside the network.
resource jumpNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-jump'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${hubVnet.id}/subnets/snet-jump' }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource jumpVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-jump'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'vm-jump'
      adminUsername: adminUsername
      customData: loadFileAsBase64('../cloud-init.yaml')
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
      networkInterfaces: [ { id: jumpNic.id } ]
    }
  }
}

// ---- Outputs -------------------------------------------------------------
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
output bastionName       string = bastion.name
output jumpVmName        string = jumpVm.name
output jumpVmResourceId  string = jumpVm.id
