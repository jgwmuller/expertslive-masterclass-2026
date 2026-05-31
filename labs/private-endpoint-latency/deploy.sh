#!/usr/bin/env bash
# ============================================================================
#  Deploy the Private Endpoint latency lab.
#  Bicep (main.bicep) for infra + this thin az-CLI wrapper for orchestration.
#
#  Usage:
#    ./deploy.sh
#
#  Override anything via environment variables, e.g.:
#    LOCATION=southeastasia FAR_LOCATION=westeurope ./deploy.sh
#
#  Parts B & C (routing + firewall) need the hub + Azure Firewall. Opt in with:
#    DEPLOY_FIREWALL=1 ./deploy.sh
#  Leave it unset for the cheap Part-A-only latency reveal (no AzFW billing).
# ============================================================================
set -euo pipefail

# ---- Config (override via env) -------------------------------------------
# TOPOLOGY:
#   simple       (default) — main.bicep — both PEs LOCAL to client; far storage slow.
#                            Supports Parts B & C (firewall) via DEPLOY_FIREWALL=1.
#   cross-region            — main-cross-region.bicep — both PEs in the REMOTE region,
#                            storage in BOTH regions. Part A ONLY (no firewall,
#                            no Parts B/C). Reveal angle: "the PE is in Germany
#                            but my Australian storage answers in 3 ms".
TOPOLOGY="${TOPOLOGY:-simple}"
TOPOLOGY_LC="$(printf '%s' "${TOPOLOGY}" | tr '[:upper:]' '[:lower:]')"

RG="${RG:-rg-pe-latency-lab}"
LOCATION="${LOCATION:-australiaeast}"               # "near" region: client + both PEs (simple) / just client (cross-region)
FAR_LOCATION="${FAR_LOCATION:-germanywestcentral}"  # "far" storage region (simple) / both PEs + far storage (cross-region)
VM_SIZE="${VM_SIZE:-Standard_B1s}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"
DEPLOY_FIREWALL="${DEPLOY_FIREWALL:-0}"             # 1 = add hub + Azure Firewall for Parts B & C (simple topology only; not supported with cross-region)
FIREWALL_TIER="${FIREWALL_TIER:-Standard}"          # Standard | Premium
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_NAME="pe-latency-$(date +%s)"

# cross-region topology does NOT support Parts B/C — refuse the combination clearly
# rather than deploy something the part-b/c scripts can't drive.
if [[ "$TOPOLOGY_LC" == "cross-region" && "${DEPLOY_FIREWALL}" != "0" ]]; then
  echo "ERROR: TOPOLOGY=cross-region does not support DEPLOY_FIREWALL=1 (Parts B/C are tied to the simple topology)." >&2
  echo "       Run the simple topology for routes/firewall demos." >&2
  exit 1
fi

# Normalize DEPLOY_FIREWALL (1/true/yes -> true) for the Bicep bool param.
# Use `tr` for lowercase (bash 3.2 on stock macOS lacks ${var,,}).
DEPLOY_FIREWALL_LC="$(printf '%s' "${DEPLOY_FIREWALL:-}" | tr '[:upper:]' '[:lower:]')"
case "$DEPLOY_FIREWALL_LC" in
  1|true|yes|on) BICEP_DEPLOY_FW="true" ;;
  *)             BICEP_DEPLOY_FW="false" ;;
esac

# ---- Prereqs --------------------------------------------------------------
command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found. Install it first." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

echo "Subscription: $(az account show --query name -o tsv)"

# ---- SSH key --------------------------------------------------------------
if [[ ! -f "$SSH_KEY" ]]; then
  echo "No SSH public key at $SSH_KEY — generating a new key pair..."
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY%.pub}" -N "" -q
  echo "  -> Created ${SSH_KEY%.pub} (private) + ${SSH_KEY} (public)"
  echo "  -> If you don't want this key kept after the lab, delete both files post-cleanup:"
  echo "       rm ${SSH_KEY%.pub} ${SSH_KEY}"
fi
SSH_KEY_DATA="$(cat "$SSH_KEY")"

# ---- Detect deployer public IP for the SSH NSG rule ----------------------
MYIP="$(curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || true)"
ALLOWED_CIDR="${ALLOWED_CIDR:-${MYIP:+${MYIP}/32}}"
if [[ -z "${ALLOWED_CIDR:-}" ]]; then
  echo "ERROR: Could not detect your public IP. Set ALLOWED_CIDR=x.x.x.x/32 and re-run." >&2
  exit 1
fi
echo "Locking inbound SSH to: $ALLOWED_CIDR"

# ---- Resource group -------------------------------------------------------
echo "Creating resource group '$RG' in '$LOCATION'..."
az group create -n "$RG" -l "$LOCATION" -o none

# ---- Deploy ---------------------------------------------------------------
if [[ "$TOPOLOGY_LC" == "cross-region" ]]; then
  echo "Deploying lab '$DEPLOY_NAME' — TOPOLOGY=cross-region."
  echo "  Client in $LOCATION; BOTH PE NICs in $FAR_LOCATION."
  echo "  Reveal: 'PE is in $FAR_LOCATION, but $LOCATION storage answers in single-digit ms'."
  az deployment group create \
    -g "$RG" \
    -n "$DEPLOY_NAME" \
    -f "$SCRIPT_DIR/main-cross-region.bicep" \
    -p clientLocation="$LOCATION" \
         peLocation="$FAR_LOCATION" \
         adminUsername="$ADMIN_USER" \
         adminSshPublicKey="$SSH_KEY_DATA" \
         allowedSshSourceCidr="$ALLOWED_CIDR" \
         vmSize="$VM_SIZE" \
    -o none
else
  if [[ "$BICEP_DEPLOY_FW" == "true" ]]; then
    echo "Deploying lab '$DEPLOY_NAME' WITH hub + Azure Firewall ($FIREWALL_TIER)."
    echo "  (AzFW provisioning adds ~5-10 min and ~\$1.25/hr — Parts B & C enabled.)"
  else
    echo "Deploying lab '$DEPLOY_NAME' (Part A only; a few minutes; VPN-free design keeps this short)."
    echo "  (Re-run with DEPLOY_FIREWALL=1 to add the hub + firewall for Parts B & C.)"
  fi
  az deployment group create \
    -g "$RG" \
    -n "$DEPLOY_NAME" \
    -f "$SCRIPT_DIR/main.bicep" \
    -p location="$LOCATION" \
         farLocation="$FAR_LOCATION" \
         adminUsername="$ADMIN_USER" \
         adminSshPublicKey="$SSH_KEY_DATA" \
         allowedSshSourceCidr="$ALLOWED_CIDR" \
         vmSize="$VM_SIZE" \
         deployFirewall="$BICEP_DEPLOY_FW" \
         firewallTier="$FIREWALL_TIER" \
  -o none
fi

# ---- Read outputs ---------------------------------------------------------
get_out() { az deployment group show -g "$RG" -n "$DEPLOY_NAME" --query "properties.outputs.$1.value" -o tsv; }
CLIENT_IP="$(get_out clientPublicIp)"
NEAR_FQDN="$(get_out nearStorageBlobFqdn)"
FAR_FQDN="$(get_out farStorageBlobFqdn)"
NEAR_REGION="$(get_out nearRegion)"
FAR_REGION="$(get_out farRegion)"

cat <<EOF

============================================================
  Lab deployed.
  (cloud-init may need ~2 min more to finish installing mtr.)
============================================================
  Client VM public IP       : $CLIENT_IP
  NEAR storage ($NEAR_REGION) : $NEAR_FQDN
  FAR  storage ($FAR_REGION) : $FAR_FQDN
EOF

if [[ "$TOPOLOGY_LC" == "cross-region" ]]; then
  PE_REGION="$(get_out peRegion)"
  cat <<EOF
  PE NIC region             : $PE_REGION  <-- BOTH PE NICs live HERE (cross-region topology)
EOF
fi

cat <<EOF

  PART A — run the latency reveal:
    ssh ${ADMIN_USER}@${CLIENT_IP} \\
      'sudo lab-on-vm.sh ${NEAR_FQDN} ${FAR_FQDN}'
EOF

if [[ "$TOPOLOGY_LC" == "cross-region" ]]; then
  cat <<EOF

  Cross-region reveal: BOTH FQDNs resolve to a $PE_REGION PE NIC IP, yet:
    NEAR ($NEAR_REGION storage) should answer in SINGLE-DIGIT ms
      -> backbone backs the PE straight to the $NEAR_REGION storage backend.
    FAR  ($FAR_REGION storage) should answer in ~200+ ms (PE-local, but the
      backend is genuinely $FAR_REGION away from the client).
  The PE never carries data — it just hands the client an /32 + DNS record.
EOF
fi

if [[ "$BICEP_DEPLOY_FW" == "true" ]]; then
  FW_IP="$(get_out firewallPrivateIp)"
  cat <<EOF

  PART B — your routes might be lying (run from this machine):
    RG=${RG} LOCATION=${LOCATION} CLIENT_IP=${CLIENT_IP} ADMIN_USER=${ADMIN_USER} \\
      ${SCRIPT_DIR}/scripts/part-b-routes.sh

  PART C — the firewall is a proxy (run from this machine):
    RG=${RG} LOCATION=${LOCATION} CLIENT_IP=${CLIENT_IP} ADMIN_USER=${ADMIN_USER} \\
      FAR_FQDN=${FAR_FQDN} NEAR_FQDN=${NEAR_FQDN} \\
      ${SCRIPT_DIR}/scripts/part-c-firewall.sh

  Azure Firewall private IP : ${FW_IP}
EOF
else
  cat <<EOF

  (Parts B & C need the firewall — re-deploy with DEPLOY_FIREWALL=1.)
EOF
fi

cat <<EOF

  Tear down when done (deletes the WHOLE RG, firewall included):
    RG=${RG} ${SCRIPT_DIR}/cleanup.sh
============================================================
EOF
