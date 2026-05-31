#!/usr/bin/env bash
# ============================================================================
#  Deploy the AGC "sub-second convergence" lab (Managed-by-ALB).
#
#  Bicep (main.bicep) stands up AKS + the managed identity + federation.
#  This thin az-CLI wrapper does the imperative steps that AGC Managed mode
#  genuinely requires and that cannot live in Bicep:
#    1. add a delegated `subnet-alb` to the AKS-managed VNet
#    2. assign the controller identity its 3 roles (per Microsoft quickstart)
#    3. install the ALB controller via Helm
#    4. apply the Gateway API objects (AGC, app, Gateway, weighted HTTPRoute)
#    5. wait for everything to go Programmed and print the demo instructions
#
#  Usage:
#    ./deploy.sh
#
#  Override anything via environment variables, e.g.:
#    LOCATION=westeurope ./deploy.sh
#    ALB_SUBNET_PREFIX=10.226.0.0/24 ./deploy.sh
# ============================================================================
set -euo pipefail

# ---- Config (override via env) -------------------------------------------
RG="${RG:-rg-agc-convergence-lab}"
LOCATION="${LOCATION:-northeurope}"                 # must be an AGC-supported region
AKS_NAME="${AKS_NAME:-aks-agc-lab}"
ALB_IDENTITY_NAME="${ALB_IDENTITY_NAME:-azure-alb-identity}"
ALB_SUBNET_NAME="${ALB_SUBNET_NAME:-subnet-alb}"
ALB_SUBNET_PREFIX="${ALB_SUBNET_PREFIX:-10.225.0.0/24}"   # inside the AKS-managed VNet (10.224.0.0/12), outside the node subnet (10.224.0.0/16)
ALB_CONTROLLER_VERSION="${ALB_CONTROLLER_VERSION:-1.10.28}"  # chart version current as of Microsoft docs, May 2026
HELM_NAMESPACE="${HELM_NAMESPACE:-azure-alb-system}"
CONTROLLER_NAMESPACE="azure-alb-system"             # must match the federated-credential subject in main.bicep
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_NAME="agc-convergence-$(date +%s)"

# Built-in role definition IDs (stable GUIDs — same in every tenant)
ROLE_READER='acdd72a7-3385-48ef-bd42-f606fba81ae7'
ROLE_AGC_CONFIG_MANAGER='fbc52c3f-28ad-4303-a892-8a056630b8f1'   # AppGw for Containers Configuration Manager
ROLE_NETWORK_CONTRIBUTOR='4d97b98b-1d4f-4787-a291-c67834d212e7'

# ---- Prereqs --------------------------------------------------------------
need() { command -v "$1" >/dev/null || { echo "ERROR: '$1' not found. $2" >&2; exit 1; }; }
need az     "Install the Azure CLI."
need kubectl "Install kubectl (e.g. 'az aks install-cli')."
need helm    "Install Helm 3 (https://helm.sh/docs/intro/install/)."
need envsubst "Install gettext (provides envsubst)."
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

echo "Subscription: $(az account show --query name -o tsv)"

# ---- Register resource providers + AGC CLI extension ----------------------
echo "Registering resource providers (idempotent)..."
for ns in Microsoft.ContainerService Microsoft.Network Microsoft.NetworkFunction Microsoft.ServiceNetworking; do
  az provider register --namespace "$ns" -o none
done
az extension add --name alb --only-show-errors -o none 2>/dev/null || az extension update --name alb --only-show-errors -o none 2>/dev/null || true

# ---- Resource group -------------------------------------------------------
echo "Creating resource group '$RG' in '$LOCATION'..."
az group create -n "$RG" -l "$LOCATION" -o none

# ---- Deploy Bicep (AKS + identity + federation) ---------------------------
echo "Deploying AKS + managed identity via Bicep (this is the slow part, ~5-8 min)..."
az deployment group create \
  -g "$RG" \
  -n "$DEPLOY_NAME" \
  -f "$SCRIPT_DIR/main.bicep" \
  -p location="$LOCATION" \
       aksName="$AKS_NAME" \
       albIdentityName="$ALB_IDENTITY_NAME" \
  -o none

get_out() { az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query "properties.outputs.$1.value" -o tsv; }
AKS_NAME="$(get_out aksName)"
MC_RG="$(get_out nodeResourceGroup)"
ALB_CLIENT_ID="$(get_out albIdentityClientId)"
ALB_PRINCIPAL_ID="$(get_out albIdentityPrincipalId)"
echo "  AKS cluster        : $AKS_NAME"
echo "  Node resource group: $MC_RG"

# ---- Add a delegated subnet for AGC into the AKS-managed VNet --------------
# Find the VNet AKS created for its nodes, then carve a delegated subnet for the
# Application Gateway for Containers association resource.
echo "Locating the AKS-managed VNet..."
CLUSTER_SUBNET_ID="$(az vmss list --resource-group "$MC_RG" \
  --query '[0].virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].subnet.id' -o tsv)"
# Parse the VNET name + RG directly from the subnet ID path. We previously tried
# `az network vnet show --ids "$VNET_ID" --query '[name, resourceGroup]' -o tsv`
# but that returns the two values on SEPARATE LINES, and `read -r A B <<<` only
# splits whitespace on a single line — so the RG silently ended up empty and the
# next `az` call hit "https://.../resourceGroups//providers/...".
VNET_ID="${CLUSTER_SUBNET_ID%/subnets/*}"
VNET_NAME="${VNET_ID##*/}"
_tmp="${VNET_ID#*/resourceGroups/}"; VNET_RG="${_tmp%%/*}"
echo "  Managed VNet: $VNET_NAME (rg: $VNET_RG)"

# Sanity-check that our delegated-subnet prefix actually fits inside the VNet's
# address space. AKS-managed VNets default to 10.224.0.0/12 (node subnet
# 10.224.0.0/16), so the default ALB_SUBNET_PREFIX=10.225.0.0/24 fits. If AKS
# ever changes that default, fail with a clear instruction instead of a cryptic
# ARM error mid-demo.
VNET_CIDR="$(az network vnet show -g "$VNET_RG" -n "$VNET_NAME" --query 'addressSpace.addressPrefixes[0]' -o tsv)"
echo "  Managed VNet address space: $VNET_CIDR"
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
in_cidr() { # $1=ip $2=cidr -> 0 if ip is inside cidr
  local ipi neti bits mask
  ipi=$(ip2int "${1}"); neti=$(ip2int "${2%/*}"); bits="${2#*/}"
  mask=$(( (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
  [[ $(( ipi & mask )) -eq $(( neti & mask )) ]]
}
if ! in_cidr "${ALB_SUBNET_PREFIX%/*}" "$VNET_CIDR"; then
  echo "ERROR: ALB_SUBNET_PREFIX ($ALB_SUBNET_PREFIX) is not inside the AKS-managed VNet ($VNET_CIDR)." >&2
  echo "       Re-run with a prefix inside that range, e.g.:  ALB_SUBNET_PREFIX=<net>/24 ./deploy.sh" >&2
  exit 1
fi

echo "Creating delegated subnet '$ALB_SUBNET_NAME' ($ALB_SUBNET_PREFIX)..."
az network vnet subnet create \
  --resource-group "$VNET_RG" \
  --vnet-name "$VNET_NAME" \
  --name "$ALB_SUBNET_NAME" \
  --address-prefixes "$ALB_SUBNET_PREFIX" \
  --delegations 'Microsoft.ServiceNetworking/trafficControllers' \
  -o none
ALB_SUBNET_ID="$(az network vnet subnet show --name "$ALB_SUBNET_NAME" --resource-group "$VNET_RG" --vnet-name "$VNET_NAME" --query id -o tsv)"

# ---- Assign the 3 roles the ALB controller needs (Managed mode) -----------
# Reader + "AppGw for Containers Configuration Manager" on the node RG, and
# Network Contributor (for subnet join) on the association subnet.
mcResourceGroupId="$(az group show --name "$MC_RG" --query id -o tsv)"
assign_role() {  # $1 = role GUID, $2 = scope, $3 = friendly name
  echo "  -> $3"
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create \
        --assignee-object-id "$ALB_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --scope "$2" --role "$1" -o none 2>/dev/null; then
      return 0
    fi
    echo "     (identity not replicated yet — retrying in 15s, attempt $attempt/6)"
    sleep 15
  done
  echo "ERROR: could not assign role $3 after retries." >&2; exit 1
}
echo "Assigning roles to the ALB controller identity..."
assign_role "$ROLE_READER"               "$mcResourceGroupId" "Reader on node RG"
assign_role "$ROLE_AGC_CONFIG_MANAGER"   "$mcResourceGroupId" "AppGw for Containers Configuration Manager on node RG"
assign_role "$ROLE_NETWORK_CONTRIBUTOR"  "$ALB_SUBNET_ID"     "Network Contributor on $ALB_SUBNET_NAME"

# ---- Cluster credentials --------------------------------------------------
echo "Fetching AKS credentials..."
az aks get-credentials --resource-group "$RG" --name "$AKS_NAME" --overwrite-existing -o none

# ---- Install the ALB controller via Helm ----------------------------------
echo "Installing the ALB controller (chart $ALB_CONTROLLER_VERSION)..."
helm upgrade --install alb-controller \
  oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --namespace "$HELM_NAMESPACE" --create-namespace \
  --version "$ALB_CONTROLLER_VERSION" \
  --set albController.namespace="$CONTROLLER_NAMESPACE" \
  --set albController.podIdentity.clientID="$ALB_CLIENT_ID" \
  --wait --timeout 5m

echo "Waiting for the GatewayClass 'azure-alb-external' to register..."
for i in $(seq 1 30); do
  if kubectl get gatewayclass azure-alb-external >/dev/null 2>&1; then break; fi
  sleep 5
done
kubectl wait --for=condition=Accepted gatewayclass/azure-alb-external --timeout=120s

# ---- Create the AGC (ApplicationLoadBalancer) -----------------------------
echo "Creating the Application Gateway for Containers resource (Managed mode)..."
export ALB_SUBNET_ID
envsubst < "$SCRIPT_DIR/k8s/00-alb.yaml" | kubectl apply -f -

echo "Waiting for the AGC to reach 'Programmed' (ARM provisioning, ~5-6 min)..."
for i in $(seq 1 90); do
  dep="$(kubectl get applicationloadbalancer alb-test -n alb-test-infra \
        -o jsonpath='{.status.conditions[?(@.type=="Deployment")].status}' 2>/dev/null || true)"
  if [[ "$dep" == "True" ]]; then echo "  AGC is Programmed."; break; fi
  sleep 10
done

# ---- Deploy the blue/green app + Gateway + weighted HTTPRoute -------------
echo "Deploying the blue/green app, Gateway and weighted HTTPRoute..."
kubectl apply -f "$SCRIPT_DIR/k8s/10-app-bluegreen.yaml"
kubectl rollout status deploy/backend-v1 -n test-infra --timeout=120s
kubectl rollout status deploy/backend-v2 -n test-infra --timeout=120s
kubectl apply -f "$SCRIPT_DIR/k8s/20-gateway.yaml"
kubectl apply -f "$SCRIPT_DIR/k8s/30-httproute.yaml"

echo "Waiting for the Gateway listener to be Programmed and assigned an FQDN..."
FQDN=""
for i in $(seq 1 60); do
  FQDN="$(kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  prog="$(kubectl get gateway gateway-01 -n test-infra -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  if [[ -n "$FQDN" && "$prog" == "True" ]]; then break; fi
  sleep 10
done

if [[ -z "$FQDN" ]]; then
  echo "WARNING: Gateway FQDN not assigned yet. Check: kubectl get gateway gateway-01 -n test-infra -o yaml" >&2
fi

cat <<EOF

============================================================
  AGC convergence lab deployed.
============================================================
  AGC frontend FQDN : ${FQDN:-<pending — re-check in a minute>}

  1) In TERMINAL A, start the traffic hammer:
       ${SCRIPT_DIR}/scripts/hammer.sh ${FQDN:-<FQDN>}

  2) In TERMINAL B, kill the active (BLUE) backend live:
       ${SCRIPT_DIR}/scripts/kill-active.sh

     Watch Terminal A: BLUE freezes, GREEN takes over in <1s,
     and the FAIL counter stays at 0. That's the whole point.

  Reset for another run:
       kubectl scale deploy/backend-v1 -n test-infra --replicas=2

  Tear everything down when done:
       RG=${RG} ${SCRIPT_DIR}/cleanup.sh
============================================================
EOF
