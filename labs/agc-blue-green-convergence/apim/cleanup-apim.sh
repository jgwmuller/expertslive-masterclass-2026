#!/usr/bin/env bash
# ============================================================================
#  Tear down the APIM AI-gateway module.
#
#  Deleting the resource group removes APIM, both Azure OpenAI accounts, the
#  Private Endpoints, the private DNS zone, and the APIM VNet in one shot. If you
#  peered the APIM VNet to the AKS-managed VNet (PEER_AKS_VNET=1 at deploy), the
#  remote peering on the AKS side is removed automatically when this RG goes.
#
#  >>> CAVEAT: an APIM Developer-SKU instance is NON-DELETABLE for ~30-45 minutes
#  >>> after it is created. If you just deployed, the RG delete will hang on the
#  >>> APIM resource until that window passes. Either wait, or soft-delete the
#  >>> APIM first (it gets purged with the RG anyway).
#
#  Usage:
#    RG=rg-apim-ai-gw-lab ./cleanup-apim.sh      # prompts for confirmation
#    CONFIRM=1 ./cleanup-apim.sh                  # no prompt (scripted)
# ============================================================================
set -euo pipefail

RG="${RG:-rg-apim-ai-gw-lab}"

az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

if [[ "${CONFIRM:-0}" != "1" ]]; then
  read -r -p "Delete resource group '$RG' and EVERYTHING in it (APIM, OpenAI, PEs, DNS, VNet)? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# Capture APIM + OpenAI names BEFORE deleting the RG (we need them for the purge
# step). Both APIM and Cognitive Services use soft-delete; without an explicit
# purge their names linger and NEXT day's redeploy collides with
# 'ServiceAlreadyExistsInSoftDeletedState' / 'FlagMustBeSetForRestore'.
APIM_NAME="$(az apim list -g "$RG" --query "[0].name" -o tsv 2>/dev/null || true)"
APIM_LOC="$(az apim show -g "$RG" -n "$APIM_NAME" --query "location" -o tsv 2>/dev/null || true)"
OAI_NAMES_AND_LOCS=()
while IFS=$'\t' read -r n l; do
  [[ -n "$n" ]] && OAI_NAMES_AND_LOCS+=("$n	$l")
done < <(az cognitiveservices account list -g "$RG" --query "[?kind=='OpenAI'].[name, location]" -o tsv 2>/dev/null || true)

echo "Deleting resource group '$RG'..."
echo "NOTE: if APIM was created < ~45 min ago, this delete will block on it until the lock lifts."
az group delete -n "$RG" --yes --no-wait
echo "Delete started (running in the background). APIM, both OpenAI accounts, PEs, DNS and the VNet all go with it."

# Purge the soft-deleted services so tomorrow's redeploy doesn't collide. We
# fire-and-retry because the soft-deleted record can take a moment to appear
# after the RG delete kicks off.
purge_apim() {  # $1 = name, $2 = location
  for attempt in 1 2 3 4 5 6; do
    if az apim deletedservice purge --service-name "$1" --location "$2" -o none 2>/dev/null; then
      echo "  purged APIM '$1'"; return 0
    fi
    sleep 15
  done
  echo "  WARNING: could not purge APIM '$1' after retries — purge manually later." >&2
}
purge_oai() {  # $1 = name, $2 = location
  for attempt in 1 2 3 4 5 6; do
    if az cognitiveservices account purge --name "$1" --location "$2" --resource-group "$RG" -o none 2>/dev/null; then
      echo "  purged OpenAI '$1'"; return 0
    fi
    sleep 15
  done
  echo "  WARNING: could not purge OpenAI '$1' after retries — purge manually later." >&2
}

if [[ -n "$APIM_NAME" && -n "$APIM_LOC" ]]; then
  echo "Purging soft-deleted APIM '$APIM_NAME' in $APIM_LOC..."
  purge_apim "$APIM_NAME" "$APIM_LOC" &
fi
for entry in "${OAI_NAMES_AND_LOCS[@]+"${OAI_NAMES_AND_LOCS[@]}"}"; do
  IFS=$'\t' read -r oai_name oai_loc <<< "$entry"
  [[ -z "$oai_name" || -z "$oai_loc" ]] && continue
  echo "Purging soft-deleted OpenAI '$oai_name' in $oai_loc..."
  purge_oai "$oai_name" "$oai_loc" &
done
wait 2>/dev/null || true
echo "Purge attempts complete. Verify with: az apim deletedservice list  /  az cognitiveservices account list-deleted"
