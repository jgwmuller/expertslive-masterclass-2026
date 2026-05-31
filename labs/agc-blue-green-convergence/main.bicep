// ============================================================================
//  Application Gateway for Containers — "Sub-second convergence" lab
//  Demonstrates AGC sub-second blue/green failover with zero dropped requests.
// ----------------------------------------------------------------------------
//  What this Bicep builds:
//    - An AKS cluster with AZURE CNI OVERLAY, OIDC issuer + Workload Identity.
//      (We let AKS create its OWN managed VNet — deploy.sh then bolts a
//       delegated `subnet-alb` onto it. This avoids the BYO-VNet RBAC
//       chicken-and-egg and matches Microsoft's "new subnet in the AKS managed
//       virtual network" happy path.)
//    - A user-assigned managed identity for the ALB controller.
//    - A federated identity credential tying that identity to the controller's
//      Kubernetes service account (system:serviceaccount:azure-alb-system:alb-controller-sa).
//
//  Everything that CANNOT be expressed in Bicep for AGC Managed mode — the
//  delegated subnet inside the AKS-managed VNet, the role assignments on the
//  node resource group + subnet, the Helm install of the ALB controller, and
//  the Gateway API objects — is done by deploy.sh, faithfully following the
//  Microsoft quickstart. See README.md for why the split looks like this.
// ============================================================================

targetScope = 'resourceGroup'

@description('Region for the AKS cluster. Must be a region where Application Gateway for Containers is available. See https://learn.microsoft.com/azure/application-gateway/for-containers/overview#supported-regions')
param location string = resourceGroup().location

@description('AKS cluster name.')
param aksName string = 'aks-agc-lab'

@description('DNS prefix for the AKS API server.')
param dnsPrefix string = 'agclab'

@description('Node VM size. D2s_v3 (2 vCPU / 8 GB) gives the system pool headroom for the ALB controller plus the blue/green app.')
param vmSize string = 'Standard_D2s_v3'

@description('Node count for the system pool. 2 is enough for the demo and keeps the AGC data plane redundant against a single node.')
@minValue(1)
@maxValue(5)
param nodeCount int = 2

@description('Kubernetes version. Leave empty to let AKS pick the default for the region.')
param kubernetesVersion string = ''

@description('Name of the user-assigned managed identity for the ALB controller. Keep in sync with deploy.sh.')
param albIdentityName string = 'azure-alb-identity'

// ---- User-assigned managed identity for the ALB controller ----------------
resource albIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: albIdentityName
  location: location
}

// ---- AKS cluster ----------------------------------------------------------
// System-assigned identity + AKS-managed VNet => no manual subnet RBAC needed.
// Azure CNI Overlay: nodes get VNet IPs; pods get a private podCidr that is NOT
// routable in the VNet, yet AGC still reaches pod IPs directly (Azure SDN forwards
// Overlay pods unencapsulated — clean L3, visible in VNet Flow Logs).
resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: aksName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true

    // The two switches that make Workload Identity (and thus the ALB
    // controller's federated credential) possible.
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: nodeCount
        vmSize: vmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
      // Defaults shown explicitly so the address plan is obvious to students.
      podCidr: '10.244.0.0/16'      // overlay pods — NOT routable in the VNet
      serviceCidr: '10.0.0.0/16'    // cluster-internal Services
      dnsServiceIP: '10.0.0.10'
    }
  }
}

// ---- Federate the managed identity to the ALB controller's service account
// The OIDC issuer URL only exists after the cluster is created; Bicep wires the
// dependency automatically through the property reference below.
resource albFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: albIdentity
  name: albIdentityName
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:azure-alb-system:alb-controller-sa'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

// ---- Outputs (consumed by deploy.sh) -------------------------------------
output aksName string = aks.name
output nodeResourceGroup string = aks.properties.nodeResourceGroup
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output albIdentityName string = albIdentity.name
output albIdentityClientId string = albIdentity.properties.clientId
output albIdentityPrincipalId string = albIdentity.properties.principalId
output location string = location
