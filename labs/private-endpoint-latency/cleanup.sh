#!/usr/bin/env bash
# ============================================================================
#  Tear down the Private Endpoint latency lab.
#  Deletes the entire resource group so nothing keeps billing.
#
#  Usage:
#    ./cleanup.sh                 # prompts for confirmation
#    RG=rg-pe-latency-lab ./cleanup.sh
#    CONFIRM=1 ./cleanup.sh       # skip the prompt (for scripted teardown)
# ============================================================================
set -euo pipefail

RG="${RG:-rg-pe-latency-lab}"

command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

if ! az group show -n "$RG" >/dev/null 2>&1; then
  echo "Resource group '$RG' does not exist — nothing to delete."
  exit 0
fi

echo "This will DELETE resource group: $RG"
az resource list -g "$RG" --query "[].{name:name, type:type}" -o table || true

if [[ "${CONFIRM:-}" != "1" ]]; then
  read -r -p "Type the resource group name to confirm deletion: " ANSWER
  [[ "$ANSWER" == "$RG" ]] || { echo "Name mismatch. Aborting."; exit 1; }
fi

echo "Deleting '$RG' (running in the background)..."
az group delete -n "$RG" --yes --no-wait
echo "Deletion started. Verify later with: az group show -n $RG"
