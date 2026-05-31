#!/usr/bin/env bash
# ============================================================================
#  Deploy the APIM "AI gateway" module (Track A continuation of the AGC lab).
#
#  RUN ORDER (the whole point of this script):
#    APIM Developer SKU takes ~30-45 MINUTES to provision — longer than this
#    lab module. So we DO NOT block on it. The sequence is:
#
#      t=0   : kick off APIM creation ASYNC (az ... --no-wait) so it bakes in
#              parallel with the AKS+AGC build the attendees already started.
#      t~1-8 : while APIM provisions, create the two Azure OpenAI accounts +
#              gpt-4o-mini deployments + the two Private Endpoints + the
#              privatelink.openai.azure.com zone + VNet link (the fast stuff).
#      t~8   : verify nslookup resolves OpenAI privately, (optionally) peer the
#              APIM VNet to the AKS-managed VNet.
#      ...   : WAIT for APIM to reach 'Succeeded' (this is the long pole).
#      end   : grant APIM's managed identity OpenAI access, import the OpenAI
#              API, create a subscription key, and print HOW to apply each of
#              the four policies one at a time during the demo.
#
#  >>> Start this script at t=0, right after you launch ../deploy.sh. Do NOT
#  >>> wait until minute 35 to 'az apim create' — it will never finish in time.
#
#  Usage:
#    ./deploy-apim.sh
#
#  Override anything via environment variables, e.g.:
#    LOCATION=westeurope ./deploy-apim.sh
#    OPENAI_SECONDARY_LOCATION=francecentral ./deploy-apim.sh
#    PEER_AKS_VNET=1 AKS_RG=rg-agc-convergence-lab ./deploy-apim.sh   # peer to the AKS lab VNet
# ============================================================================
set -euo pipefail

# ---- Config (override via env) -------------------------------------------
RG="${RG:-rg-apim-ai-gw-lab}"
LOCATION="${LOCATION:-northeurope}"                          # APIM + VNet region; keep close to the room
# OpenAI region defaults are deliberately DIFFERENT from APIM's LOCATION because
# many APIM regions (notably northeurope) don't offer the `Standard` SKU for the
# gpt-4o family — they only have `GlobalProvisionedManaged` (PTU commitment).
# swedencentral + eastus2 both have Standard SKU for gpt-4o; verified May 2026.
OPENAI_PRIMARY_LOCATION="${OPENAI_PRIMARY_LOCATION:-swedencentral}"
OPENAI_SECONDARY_LOCATION="${OPENAI_SECONDARY_LOCATION:-eastus2}"  # DIFFERENT region for the failover/LB demo
PUBLISHER_EMAIL="${PUBLISHER_EMAIL:-admin@contoso.com}"
PUBLISHER_NAME="${PUBLISHER_NAME:-Experts Live Masterclass}"
# Model defaults: gpt-4o-mini 2024-07-18 was ARM-deprecated 2026-03-31 even though
# `az cognitiveservices model list` still lists it (listing API and ARM disagree).
# gpt-4o 2024-11-20 has Standard SKU in both default regions; verified May 2026.
MODEL_NAME="${MODEL_NAME:-gpt-4o}"
MODEL_VERSION="${MODEL_VERSION:-2024-11-20}"                 # VERIFY-IN-TEST: must exist in BOTH regions with Standard SKU
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="$SCRIPT_DIR/policies"
DEPLOY_NAME="apim-ai-gw-$(date +%s)"

# Optional: peer the APIM VNet to the AKS-managed VNet from ../deploy.sh.
PEER_AKS_VNET="${PEER_AKS_VNET:-0}"
AKS_RG="${AKS_RG:-rg-agc-convergence-lab}"   # the RG ../deploy.sh used
AKS_NAME="${AKS_NAME:-aks-agc-lab}"

# Built-in role: "Cognitive Services OpenAI User" (stable GUID, same in every tenant)
ROLE_OPENAI_USER='5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

# ---- Prereqs --------------------------------------------------------------
need() { command -v "$1" >/dev/null || { echo "ERROR: '$1' not found. $2" >&2; exit 1; }; }
need az "Install the Azure CLI."
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

echo "Subscription: $(az account show --query name -o tsv)"

# ---- Register providers ---------------------------------------------------
echo "Registering resource providers (idempotent)..."
for ns in Microsoft.ApiManagement Microsoft.CognitiveServices Microsoft.Network; do
  az provider register --namespace "$ns" -o none
done

# ---- Resource group -------------------------------------------------------
echo "Creating resource group '$RG' in '$LOCATION'..."
az group create -n "$RG" -l "$LOCATION" -o none

# ============================================================================
#  STEP 1 — kick APIM off ASYNC so it bakes in the background (~30-45 min).
#  We deploy the WHOLE Bicep template with --no-wait. Bicep wires APIM + OpenAI
#  + PEs + DNS + backends + the API shell in one deployment; --no-wait returns
#  immediately so we can poll OpenAI/PE readiness while APIM provisions.
# ============================================================================
echo
echo ">>> STEP 1: launching the Bicep deployment ASYNC (APIM is the long pole, ~30-45 min)..."
az deployment group create \
  -g "$RG" \
  -n "$DEPLOY_NAME" \
  -f "$SCRIPT_DIR/main.bicep" \
  -p location="$LOCATION" \
       openAiPrimaryLocation="$OPENAI_PRIMARY_LOCATION" \
       openAiSecondaryLocation="$OPENAI_SECONDARY_LOCATION" \
       publisherEmail="$PUBLISHER_EMAIL" \
       publisherName="$PUBLISHER_NAME" \
       modelName="$MODEL_NAME" \
       modelVersion="$MODEL_VERSION" \
  --no-wait \
  -o none
echo "    Deployment '$DEPLOY_NAME' submitted. APIM is now provisioning in the background."

# ============================================================================
#  STEP 2 — while APIM bakes, watch the FAST resources land.
#  The OpenAI accounts, deployments, PEs and DNS are part of the same Bicep
#  deployment but finish in minutes. We poll for them so the lab can do the
#  private-DNS reveal long before APIM is ready.
# ============================================================================
echo
echo ">>> STEP 2: waiting for the Azure OpenAI accounts + Private Endpoints (the fast part)..."
# Derive the deterministic resource names Bicep generated (uniqueString(rg.id)).
# Easiest robust path: read them back from the deployment outputs as they appear.
get_out() { az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query "properties.outputs.$1.value" -o tsv 2>/dev/null || true; }

# Poll until the OpenAI accounts exist (outputs populate once those resources finish).
OAI_PRIMARY=""; OAI_SECONDARY=""; VNET_NAME=""; DNS_ZONE=""
for i in $(seq 1 60); do
  OAI_PRIMARY="$(get_out openAiPrimaryName)"
  OAI_SECONDARY="$(get_out openAiSecondaryName)"
  VNET_NAME="$(get_out vnetName)"
  DNS_ZONE="$(get_out privateDnsZoneName)"
  if [[ -n "$OAI_PRIMARY" && -n "$OAI_SECONDARY" ]]; then break; fi
  # Outputs only appear when the deployment SUCCEEDS; for partial progress, probe directly.
  if az cognitiveservices account list -g "$RG" --query "[?kind=='OpenAI'].name" -o tsv 2>/dev/null | grep -q .; then
    # Use a while-read loop instead of `mapfile` (bash 3.2 on stock macOS lacks it).
    _names=()
    while IFS= read -r line; do _names+=("$line"); done < <(az cognitiveservices account list -g "$RG" --query "[?kind=='OpenAI'].name" -o tsv)
    [[ -n "${_names[0]:-}" ]] && OAI_PRIMARY="${_names[0]}"
    [[ -n "${_names[1]:-}" ]] && OAI_SECONDARY="${_names[1]}"
    [[ -n "$OAI_PRIMARY" && -n "$OAI_SECONDARY" ]] && break
  fi
  echo "    ...still creating OpenAI accounts (attempt $i/60); sleeping 15s"
  sleep 15
done

if [[ -z "$OAI_PRIMARY" || -z "$OAI_SECONDARY" ]]; then
  echo "WARNING: Could not yet confirm both OpenAI accounts. Check the deployment:" >&2
  echo "         az deployment group show -g $RG -n $DEPLOY_NAME --query properties.provisioningState" >&2
else
  echo "    OpenAI primary  : $OAI_PRIMARY ($OPENAI_PRIMARY_LOCATION)"
  echo "    OpenAI secondary: $OAI_SECONDARY ($OPENAI_SECONDARY_LOCATION)"
fi

# ============================================================================
#  STEP 3 — the private-DNS reveal you can do BEFORE APIM is ready.
#  From any host with the private zone in scope, *.openai.azure.com must resolve
#  to a 10.226.0.x PE address, NOT a public IP. We try to do it from inside the
#  AKS cluster (it has the closest network vantage point if you peer the VNets),
#  and always print the manual command.
# ============================================================================
echo
echo ">>> STEP 3: private DNS check — OpenAI should resolve to a PE private IP."
if [[ -n "$OAI_PRIMARY" ]]; then
  echo "    Manual check from a host that can see the private zone:"
  echo "      nslookup ${OAI_PRIMARY}.openai.azure.com"
  echo "    Expect an answer in 10.226.0.x (the PE), NOT a public IP."
  # If kubectl is wired to the AKS lab cluster, demo it from a throwaway pod.
  if command -v kubectl >/dev/null && kubectl version --request-timeout=5s >/dev/null 2>&1; then
    echo "    Trying the lookup from inside the AKS cluster (needs VNet peering + DNS reachability)..."
    kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 --request-timeout=60s -- \
      nslookup "${OAI_PRIMARY}.openai.azure.com" 2>/dev/null || \
      echo "    (cluster lookup skipped/failed — peer the VNets and ensure the cluster uses a resolver that sees the private zone)"
  fi
fi

# ============================================================================
#  STEP 4 — OPTIONAL: peer the APIM VNet to the AKS-managed VNet.
#  Lets an AKS inference pod (the 72-85 min stretch goal) call APIM, and lets the
#  in-cluster nslookup above resolve the OpenAI PE. Off by default to keep the
#  baseline simple.
# ============================================================================
if [[ "$PEER_AKS_VNET" == "1" && -n "$VNET_NAME" ]]; then
  echo
  echo ">>> STEP 4: peering APIM VNet '$VNET_NAME' to the AKS-managed VNet..."
  # Find the AKS node RG, then its managed VNet (same discovery ../deploy.sh uses).
  MC_RG="$(az aks show -g "$AKS_RG" -n "$AKS_NAME" --query nodeResourceGroup -o tsv 2>/dev/null || true)"
  if [[ -n "$MC_RG" ]]; then
    AKS_VNET_NAME="$(az network vnet list -g "$MC_RG" --query '[0].name' -o tsv 2>/dev/null || true)"
    if [[ -n "$AKS_VNET_NAME" ]]; then
      APIM_VNET_ID="$(az network vnet show -g "$RG" -n "$VNET_NAME" --query id -o tsv)"
      AKS_VNET_ID="$(az network vnet show -g "$MC_RG" -n "$AKS_VNET_NAME" --query id -o tsv)"
      az network vnet peering create -g "$RG" -n apim-to-aks \
        --vnet-name "$VNET_NAME" --remote-vnet "$AKS_VNET_ID" \
        --allow-vnet-access -o none
      az network vnet peering create -g "$MC_RG" -n aks-to-apim \
        --vnet-name "$AKS_VNET_NAME" --remote-vnet "$APIM_VNET_ID" \
        --allow-vnet-access -o none
      # So the AKS cluster can resolve the OpenAI PE, link the private zone to the AKS VNet too.
      [[ -n "$DNS_ZONE" ]] && az network private-dns link vnet create \
        -g "$RG" -z "$DNS_ZONE" -n aks-vnet-link \
        -v "$AKS_VNET_ID" -e false -o none 2>/dev/null || true
      echo "    Peering + DNS link done."
    else
      echo "    WARNING: could not find the AKS-managed VNet in $MC_RG — skipping peering." >&2
    fi
  else
    echo "    WARNING: could not find AKS '$AKS_NAME' in '$AKS_RG' — skipping peering." >&2
    echo "             VERIFY-IN-TEST: confirm the APIM VNet ($VNET_NAME) range does not overlap the AKS VNet before peering." >&2
  fi
fi

# ============================================================================
#  STEP 5 — WAIT for APIM. This is the long pole; do the AGC blue/green reveal
#  on the AKS lab while this runs. We poll provisioningState until 'Succeeded'.
# ============================================================================
echo
echo ">>> STEP 5: waiting for APIM to finish provisioning (~30-45 min total from t=0)..."
echo "    Go run the AGC blue/green zero-drop reveal now — come back when this clears."
APIM_NAME=""
for i in $(seq 1 180); do   # up to ~60 min at 20s cadence
  APIM_NAME="$(get_out apimName)"
  if [[ -z "$APIM_NAME" ]]; then
    APIM_NAME="$(az apim list -g "$RG" --query '[0].name' -o tsv 2>/dev/null || true)"
  fi
  if [[ -n "$APIM_NAME" ]]; then
    STATE="$(az apim show -g "$RG" -n "$APIM_NAME" --query provisioningState -o tsv 2>/dev/null || true)"
    echo "    APIM '$APIM_NAME' provisioningState=$STATE (poll $i)"
    [[ "$STATE" == "Succeeded" ]] && break
    [[ "$STATE" == "Failed" ]] && { echo "ERROR: APIM provisioning failed." >&2; exit 1; }
  else
    echo "    APIM resource not visible yet (poll $i)..."
  fi
  sleep 20
done

if [[ -z "$APIM_NAME" ]]; then
  echo "ERROR: APIM never became visible. Check: az deployment group show -g $RG -n $DEPLOY_NAME" >&2
  exit 1
fi

# Make sure the full Bicep deployment also completed (backends/API shell exist).
echo "    Confirming the Bicep deployment as a whole reached 'Succeeded'..."
for i in $(seq 1 30); do
  DSTATE="$(az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query properties.provisioningState -o tsv 2>/dev/null || true)"
  [[ "$DSTATE" == "Succeeded" ]] && break
  [[ "$DSTATE" == "Failed" ]] && { echo "ERROR: Bicep deployment failed — see portal." >&2; exit 1; }
  sleep 20
done

# Refresh all the outputs now that the deployment is done.
APIM_NAME="$(get_out apimName)"
APIM_GW="$(get_out apimGatewayUrl)"
APIM_PRINCIPAL="$(get_out apimPrincipalId)"
OAI_PRIMARY="$(get_out openAiPrimaryName)"
OAI_SECONDARY="$(get_out openAiSecondaryName)"
OAI_PRIMARY_ID="$(get_out openAiPrimaryId)"
OAI_SECONDARY_ID="$(get_out openAiSecondaryId)"
API_NAME="$(get_out apiName)"
MODEL_DEPLOY="$(get_out modelDeploymentName)"

# ============================================================================
#  STEP 6 — grant APIM's managed identity access to both OpenAI accounts.
#  Lets the gateway auth with managed identity instead of a key (Pattern 2's
#  "hide the key"). Retried because identity replication lags.
# ============================================================================
echo
echo ">>> STEP 6: granting APIM identity 'Cognitive Services OpenAI User' on both accounts..."
assign_openai_user() {  # $1 = scope (account id)
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create \
        --assignee-object-id "$APIM_PRINCIPAL" \
        --assignee-principal-type ServicePrincipal \
        --scope "$1" --role "$ROLE_OPENAI_USER" -o none 2>/dev/null; then
      return 0
    fi
    echo "     (identity not replicated yet — retrying in 15s, attempt $attempt/6)"
    sleep 15
  done
  echo "WARNING: could not assign OpenAI User on $1 after retries — assign it manually." >&2
}
[[ -n "$OAI_PRIMARY_ID"   ]] && assign_openai_user "$OAI_PRIMARY_ID"
[[ -n "$OAI_SECONDARY_ID" ]] && assign_openai_user "$OAI_SECONDARY_ID"

# ============================================================================
#  STEP 6b — IP-allowlist APIM's outbound IPs on both OpenAI accounts.
#  The Bicep leaves both OpenAI accounts as `publicNetworkAccess: 'Enabled'`
#  with `defaultAction: 'Deny'` and an EMPTY ipRules list — nothing can reach
#  the data plane until we add APIM's IPs here. Doing it post-Bicep keeps the
#  Bicep parallel-friendly (OpenAI doesn't have to wait for APIM to provision).
# ============================================================================
echo
echo ">>> STEP 6b: allowlisting APIM's outbound IPs on both OpenAI accounts..."
# Read APIM's outbound IPs as newline-separated TSV (one IP per line). `az ... -o json`
# pretty-prints multi-line, which corrupts inline `python -c "$VAR"` expansions
# (newlines become command separators) — TSV avoids the trap entirely.
APIM_IPS_TSV="$(az apim show -g "$RG" -n "$APIM_NAME" --query "publicIpAddresses[]" -o tsv 2>/dev/null)"
echo "    APIM outbound IPs:"; printf '      %s\n' $APIM_IPS_TSV
# Build the ipRules JSON in pure shell (bash 3.2 safe).
ip_rules=""
while IFS= read -r ip; do
  [[ -n "$ip" ]] || continue
  [[ -n "$ip_rules" ]] && ip_rules="${ip_rules},"
  ip_rules="${ip_rules}{\"value\":\"$ip\"}"
done <<< "$APIM_IPS_TSV"
IP_RULES_JSON="[$ip_rules]"
if [[ "$IP_RULES_JSON" == "[]" ]]; then
  echo "    WARNING: could not read APIM publicIpAddresses — leaving OpenAI ACLs default-deny. Smoke test will fail until you add APIM IPs manually." >&2
else
  for acct in "$OAI_PRIMARY" "$OAI_SECONDARY"; do
    [[ -z "$acct" ]] && continue
    echo "    PATCH $acct -> networkAcls.ipRules=$IP_RULES_JSON"
    BODY="{\"properties\":{\"publicNetworkAccess\":\"Enabled\",\"networkAcls\":{\"defaultAction\":\"Deny\",\"ipRules\":${IP_RULES_JSON},\"virtualNetworkRules\":[]}}}"
    az rest --method patch \
      --uri "https://management.azure.com/subscriptions/${SUB_ID:-$(az account show --query id -o tsv)}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${acct}?api-version=2024-10-01" \
      --body "$BODY" -o none 2>&1 | tail -5 || echo "      WARNING: PATCH failed on $acct" >&2
  done
  echo "    Waiting 60s for the ACL change to propagate before the smoke test..."
  sleep 60
fi

# ============================================================================
#  STEP 7 — import the Azure OpenAI REST API into the APIM API shell.
#  We import the published Azure OpenAI inference OpenAPI spec onto the existing
#  'azure-openai' API (path 'openai'). VERIFY-IN-TEST: pin the api-version in the
#  spec URL to one your deployments support; the inference spec URL/version moves.
# ============================================================================
echo
echo ">>> STEP 7: importing the Azure OpenAI OpenAPI spec into API '$API_NAME'..."
OPENAI_API_VERSION="${OPENAI_API_VERSION:-2024-10-21}"
SPEC_URL="https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/${OPENAI_API_VERSION}/inference.json"
# Import as an overlay on the existing API id so we keep path/serviceUrl from Bicep.
az apim api import \
  -g "$RG" --service-name "$APIM_NAME" \
  --api-id "$API_NAME" \
  --path openai \
  --specification-format OpenApi \
  --specification-url "$SPEC_URL" \
  -o none 2>/dev/null \
  || echo "    WARNING: spec import via URL failed — VERIFY-IN-TEST: download inference.json for OPENAI_API_VERSION=$OPENAI_API_VERSION and import with --specification-path."

# A subscription key so attendees can call the gateway.
# NOTE: `az apim subscription create/show` was REMOVED from the current az CLI
# (`az apim` only has the `api` subgroup as of May 2026). We go straight to the
# ARM REST API via `az rest`. PUT creates/updates; listSecrets POST returns the
# primaryKey (which `subscription show` would never include anyway — secret).
echo "    Creating a demo subscription key ('ai-gw-demo') scoped to all APIs..."
SUB_ID="$(az account show --query id -o tsv)"
APIM_SUB_BASE="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}"
APIM_API_VERSION='2022-08-01'
APIM_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis"
az rest --method put \
  --uri "${APIM_SUB_BASE}/subscriptions/ai-gw-demo?api-version=${APIM_API_VERSION}" \
  --body "{\"properties\":{\"scope\":\"${APIM_SCOPE}\",\"displayName\":\"AI GW demo key\"}}" \
  -o none 2>/dev/null || true
SUB_KEY="$(az rest --method post \
  --uri "${APIM_SUB_BASE}/subscriptions/ai-gw-demo/listSecrets?api-version=${APIM_API_VERSION}" \
  --query primaryKey -o tsv 2>/dev/null || echo '<create-in-portal>')"

# ============================================================================
#  DONE — print the demo runbook. Policies are applied ONE AT A TIME, by hand,
#  during the session so attendees see each effect in isolation.
# ============================================================================
cat <<EOF

============================================================
  APIM AI-gateway module deployed.
============================================================
  APIM name        : ${APIM_NAME}
  Gateway URL      : ${APIM_GW:-https://${APIM_NAME}.azure-api.net}
  OpenAI primary   : ${OAI_PRIMARY}   ($OPENAI_PRIMARY_LOCATION)
  OpenAI secondary : ${OAI_SECONDARY} ($OPENAI_SECONDARY_LOCATION)
  Model deployment : ${MODEL_DEPLOY}
  Demo sub key     : ${SUB_KEY}

  Smoke test (no policy yet) — should return a completion:
    curl -s "${APIM_GW:-https://${APIM_NAME}.azure-api.net}/openai/deployments/${MODEL_DEPLOY}/chat/completions?api-version=${OPENAI_API_VERSION}" \\
      -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" -H "Content-Type: application/json" \\
      -d '{"messages":[{"role":"user","content":"Say hi in 3 words"}]}'

    # NOTE: APIM's default subscription-key header on this API is
    # 'Ocp-Apim-Subscription-Key' (verified via the API's
    # subscriptionKeyParameterNames). The native Azure OpenAI client uses
    # 'api-key' — if you want SDK code to work unchanged, edit the API to also
    # accept 'api-key' as the subscription header (Portal -> APIs -> Azure
    # OpenAI -> Settings -> Subscription key parameter names).

  APPLY THE FOUR POLICIES ONE AT A TIME (re-run after editing each XML):

    # 1) Token rate-limit (watch the 3rd call get 429 + Retry-After)
    az apim api policy create -g ${RG} --service-name ${APIM_NAME} \\
      --api-id ${API_NAME} --xml-path "${POLICY_DIR}/token-rate-limit.xml"

    # 2) Semantic cache (reword a prompt -> instant, ~0 tokens)
    #    PREREQ: external Redis Enterprise cache + an embeddings backend. See README.
    az apim api policy create -g ${RG} --service-name ${APIM_NAME} \\
      --api-id ${API_NAME} --xml-path "${POLICY_DIR}/semantic-cache.xml"

    # 3) Weighted load-balance across both backends (watch the split move)
    az apim api policy create -g ${RG} --service-name ${APIM_NAME} \\
      --api-id ${API_NAME} --xml-path "${POLICY_DIR}/load-balance.xml"

    # 4) Circuit breaker — fail one backend (drive it to 429 or disable its
    #    deployment), watch APIM trip its breaker and serve 100% from the survivor
    az apim api policy create -g ${RG} --service-name ${APIM_NAME} \\
      --api-id ${API_NAME} --xml-path "${POLICY_DIR}/circuit-breaker.xml"

  Tear everything down when done (note: APIM Dev SKU is non-deletable for
  ~30-45 min after create — if you just made it, wait before deleting):
    RG=${RG} ${SCRIPT_DIR}/cleanup-apim.sh
============================================================
EOF
