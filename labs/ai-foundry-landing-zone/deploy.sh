#!/usr/bin/env bash
# ============================================================================
#  Deploy the AI Foundry landing-zone lab.
#  Bicep (main.bicep + modules/) for infra; this thin az-CLI wrapper registers
#  providers, deploys, and prints the verification steps (nslookup from the jump
#  box, how to reach the project).
#
#  SOURCE: Microsoft Learn (Apr 2026). The Foundry
#  account/project/capabilityHost resources are version-sensitive — see the
#  VERIFY-IN-TEST notes in modules/foundry.bicep and modules/privateendpoints.bicep.
#
#  Usage:
#    ./deploy.sh
#
#  Override anything via environment variables, e.g.:
#    LOCATION=swedencentral ./deploy.sh
#    LOCATION=eastus2 MODEL_VERSION=2024-11-20 ./deploy.sh
# ============================================================================
set -euo pipefail

# ---- Config (override via env) -------------------------------------------
RG="${RG:-rg-ai-foundry-lz-lab}"
LOCATION="${LOCATION:-swedencentral}"   # Foundry account + spoke VNet are COLOCATED here (hard requirement)
ADMIN_USER="${ADMIN_USER:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
MODEL_NAME="${MODEL_NAME:-gpt-4o}"
MODEL_VERSION="${MODEL_VERSION:-2024-11-20}"   # VERIFY-IN-TEST: a version your region offers
MODEL_CAPACITY="${MODEL_CAPACITY:-20}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_NAME="ai-foundry-lz-$(date +%s)"

# ---- Prereqs --------------------------------------------------------------
command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found. Install it first." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }
echo "Subscription: $(az account show --query name -o tsv)"

# ---- SSH key (for the jump VM) --------------------------------------------
if [[ ! -f "$SSH_KEY" ]]; then
  echo "No SSH public key at $SSH_KEY — generating a new key pair..."
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY%.pub}" -N "" -q
fi
SSH_KEY_DATA="$(cat "$SSH_KEY")"

# ---- Register resource providers (idempotent) -----------------------------
# Exactly the providers MS Learn requires for a Standard private agent, plus
# Network/DocumentDB for the rest of the landing zone.
echo "Registering resource providers (idempotent — registration can take a few minutes the first time)..."
for ns in \
  Microsoft.App \
  Microsoft.ContainerService \
  Microsoft.CognitiveServices \
  Microsoft.Search \
  Microsoft.Storage \
  Microsoft.DocumentDB \
  Microsoft.Network \
  Microsoft.KeyVault \
  Microsoft.MachineLearningServices ; do
  az provider register --namespace "$ns" -o none
done

# ---- Region capacity pre-flight ------------------------------------------
# Across 2026-05-25 / -26 testing, Foundry deploys hit `ServiceUnavailable`
# (Cosmos AZ), `InsufficientResourcesAvailable` (Search), and
# `BadGatewayConnection` (Foundry agent capability host) in different
# regions. The Bicep is correct; Azure regional capacity is the wildcard.
# This pre-flight probes the three failure modes BEFORE submitting the Bicep,
# and walks an opt-in fallback list if the primary fails.
#
# Override via env:
#   FOUNDRY_REGIONS="westus3 canadacentral northcentralus"  # the fallback list
#   SKIP_REGION_PROBE=1  # skip the pre-flight and try anyway (legacy behavior)
FOUNDRY_REGIONS="${FOUNDRY_REGIONS:-$LOCATION westus3 canadacentral northcentralus eastus2 swedencentral}"
SKIP_REGION_PROBE="${SKIP_REGION_PROBE:-0}"

probe_region() {  # $1 = region. returns 0 if all three checks pass.
  local r="$1" failed=""
  # 1. gpt-4o Standard SKU availability + non-deprecated version
  if ! az cognitiveservices model list -l "$r" --query "[?model.name=='$MODEL_NAME' && model.version=='$MODEL_VERSION' && contains(model.skus[].name, 'Standard')] | [0].model.version" -o tsv 2>/dev/null | grep -q .; then
    failed="${failed}gpt-4o-Standard "
  fi
  # 2. AI Search standard SKU availability — we don't have a perfect probe,
  #    but `az search service list-skus` shows quota status.
  if ! az rest --method get --uri "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.Search/locations/${r}/usages?api-version=2024-06-01-preview" --query "value[?name.value=='standard'].limit | [0]" -o tsv 2>/dev/null | grep -qE '^[1-9]'; then
    failed="${failed}search-standard "
  fi
  # 3. Cosmos DB capacity — there's no perfect pre-flight; best effort is the
  #    sql account-level NameAvailability check that also surfaces "region not
  #    available for new accounts" hints. We don't fail solely on this — it's
  #    a soft signal.
  # (deliberately no Cosmos probe — Azure does not expose a reliable
  # pre-flight; if it fails, we surface the error from the actual deploy.)
  if [[ -n "$failed" ]]; then
    echo "    [$r] FAIL: $failed"
    return 1
  fi
  echo "    [$r] OK (gpt-4o Standard + AI Search quota)"
  return 0
}

if [[ "$SKIP_REGION_PROBE" != "1" ]]; then
  echo
  echo "Probing region capacity before Bicep submit (override with SKIP_REGION_PROBE=1)..."
  PROBE_LOCATION=""
  for r in $FOUNDRY_REGIONS; do
    if probe_region "$r"; then PROBE_LOCATION="$r"; break; fi
  done
  if [[ -z "$PROBE_LOCATION" ]]; then
    echo "ERROR: none of the candidate regions ($FOUNDRY_REGIONS) passed the pre-flight." >&2
    echo "       Either bump quota / try another region (set FOUNDRY_REGIONS=...), or" >&2
    echo "       skip with SKIP_REGION_PROBE=1 to attempt the requested region anyway." >&2
    exit 1
  fi
  if [[ "$PROBE_LOCATION" != "$LOCATION" ]]; then
    echo "  -> '$LOCATION' did not pass; falling back to '$PROBE_LOCATION'."
    LOCATION="$PROBE_LOCATION"
  else
    echo "  -> using '$LOCATION'."
  fi
fi

# ---- Resource group -------------------------------------------------------
echo "Creating resource group '$RG' in '$LOCATION'..."
az group create -n "$RG" -l "$LOCATION" -o none

# ---- Deploy ---------------------------------------------------------------
# NOTE: Azure Firewall + Bastion + the Foundry capability host make this the
# slow lab (~15-25 min). Start it in the coffee break and walk the architecture
# while it bakes.
echo "Deploying '$DEPLOY_NAME' (hub + spoke + BYO data + Foundry + PEs + DNS)."
echo "This is the slow lab (~15-25 min: Firewall, Bastion, capability host)..."
az deployment group create \
  -g "$RG" \
  -n "$DEPLOY_NAME" \
  -f "$SCRIPT_DIR/main.bicep" \
  -p location="$LOCATION" \
       adminUsername="$ADMIN_USER" \
       adminSshPublicKey="$SSH_KEY_DATA" \
       vmSize="$VM_SIZE" \
       modelName="$MODEL_NAME" \
       modelVersion="$MODEL_VERSION" \
       modelCapacity="$MODEL_CAPACITY" \
  -o none

# ---- Read outputs ---------------------------------------------------------
get_out() { az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query "properties.outputs.$1.value" -o tsv; }
BASTION_NAME="$(get_out bastionName)"
JUMP_VM="$(get_out jumpVmName)"
FOUNDRY_ACCT="$(get_out foundryAccountName)"
FOUNDRY_PROJ="$(get_out foundryProjectName)"
AZFW_IP="$(get_out firewallPrivateIp)"
COG_FQDN="$(get_out foundryCognitiveFqdn)"
OAI_FQDN="$(get_out foundryOpenAiFqdn)"
SEARCH_FQDN="$(get_out searchFqdn)"
BLOB_FQDN="$(get_out blobFqdn)"
COSMOS_FQDN="$(get_out cosmosFqdn)"

cat <<EOF

============================================================
  AI Foundry landing-zone deployed.
============================================================
  Resource group        : $RG  ($LOCATION)
  Foundry account        : $FOUNDRY_ACCT   (public access: Disabled)
  Foundry project        : $FOUNDRY_PROJ
  Hub firewall private IP : $AZFW_IP   (the single egress chokepoint, NO TLS inspection)
  Bastion                : $BASTION_NAME
  Jump VM                : $JUMP_VM   (no public IP — reach it via Bastion)

  1) GET INSIDE THE VNET — connect to the jump box via Bastion:
       az network bastion ssh \\
         --name $BASTION_NAME --resource-group $RG \\
         --target-resource-id \$(az vm show -g $RG -n $JUMP_VM --query id -o tsv) \\
         --auth-type ssh-key --username $ADMIN_USER --ssh-key $SSH_KEY

  2) PROVE PRIVATE DNS (run ON the jump box — every name should be 192.168.1.x):
       check-private-dns.sh \\
         $COG_FQDN \\
         $OAI_FQDN \\
         $SEARCH_FQDN \\
         $BLOB_FQDN \\
         $COSMOS_FQDN
     Then run the SAME nslookups from your laptop (outside) — they fail. That
     gap IS the private landing zone.

  3) RUN AN AGENT END-TO-END (on the jump box, inside the venv):
       /opt/agentvenv/bin/python run-agent.py \\
         "https://${FOUNDRY_ACCT}.services.ai.azure.com/api/projects/${FOUNDRY_PROJ}"
     (Confirm the exact project endpoint in the Foundry portal — Project > Overview.)

  4) INSPECT EGRESS — tour the Azure Firewall logs to see only the allowlisted
     AAD / Container Apps FQDNs leaving, with NO TLS inspection.

  Tear down when done (PURGES Foundry BEFORE the VNet — required, see below):
       RG=$RG ${SCRIPT_DIR}/cleanup.sh
============================================================
EOF
