#!/usr/bin/env bash
# ============================================================================
#  Tear down the AI Foundry landing-zone lab — IN THE CORRECT ORDER.
#
#  *** THE ORDER MATTERS. ***
#  The Standard Agent places a service-association-link (SAL) on the delegated
#  agent subnet (Microsoft.App/environments). While the Foundry resource exists
#  — including in its SOFT-DELETED state — that SAL blocks deletion of the
#  subnet and therefore the spoke VNet. MS Learn is explicit:
#
#    "Before deleting the virtual network, delete AND PURGE your Foundry resource."
#
#  So this script:
#    1. deletes the Foundry account (soft delete)
#    2. PURGES it (removes the soft-deleted resource, releasing the SAL)
#    3. only THEN deletes the resource group (VNet, firewall, PEs, data, etc.)
#
#  If you skip the purge, the RG delete hangs on the spoke VNet with:
#    "Subnet requires ... delegation(s) [Microsoft.App/environments] to
#     reference service association link .../legionservicelink."
#
#  Usage:
#    RG=rg-ai-foundry-lz-lab ./cleanup.sh    # prompts for confirmation
#    CONFIRM=1 ./cleanup.sh                  # no prompt (scripted)
# ============================================================================
set -euo pipefail

RG="${RG:-rg-ai-foundry-lz-lab}"

command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

if ! az group show -n "$RG" >/dev/null 2>&1; then
  echo "Resource group '$RG' does not exist — nothing to delete."
  exit 0
fi

echo "This will DELETE + PURGE the Foundry resource, then delete resource group: $RG"
az resource list -g "$RG" --query "[].{name:name, type:type}" -o table || true

if [[ "${CONFIRM:-}" != "1" ]]; then
  read -r -p "Type the resource group name to confirm teardown: " ANSWER
  [[ "$ANSWER" == "$RG" ]] || { echo "Name mismatch. Aborting."; exit 1; }
fi

# ---- 1) Find the Foundry (Cognitive Services AIServices) account(s) -------
# Use a while-read loop instead of `mapfile` (bash 3.2 on stock macOS lacks it).
echo "Locating Foundry account(s) in '$RG'..."
FOUNDRY_ACCTS=()
while IFS= read -r line; do FOUNDRY_ACCTS+=("$line"); done < <(az cognitiveservices account list -g "$RG" \
  --query "[?kind=='AIServices'].name" -o tsv 2>/dev/null || true)

if [[ ${#FOUNDRY_ACCTS[@]} -eq 0 ]]; then
  echo "  (no AIServices account found — maybe already removed; continuing to RG delete.)"
fi

# ---- 2) Delete + PURGE each Foundry account (releases the subnet SAL) ------
# Use the `${arr[@]+...}` guard so an empty array doesn't trip `set -u` (bash 3.2
# treats expansion of an empty array as "unbound variable").
for acct in ${FOUNDRY_ACCTS[@]+"${FOUNDRY_ACCTS[@]}"}; do
  [[ -z "$acct" ]] && continue
  LOC="$(az cognitiveservices account show -g "$RG" -n "$acct" --query location -o tsv 2>/dev/null || echo '')"
  echo "Deleting Foundry account '$acct' (soft delete)..."
  az cognitiveservices account delete -g "$RG" -n "$acct" -o none || true

  echo "Purging Foundry account '$acct' (removes the soft-deleted copy + its subnet SAL)..."
  # Purge requires the original location; retry a few times since the soft-deleted
  # record can take a moment to become purgeable.
  for attempt in 1 2 3 4 5 6; do
    if az cognitiveservices account purge -g "$RG" -n "$acct" -l "$LOC" -o none 2>/dev/null; then
      echo "  purged '$acct'."
      break
    fi
    echo "  (not purgeable yet — retrying in 15s, attempt $attempt/6)"
    sleep 15
  done
done

# Safety net: purge any soft-deleted AIServices account that still references
# this lab (in case the account was already hard-deleted from the RG but the
# soft-deleted record — and its SAL — lingers).
echo "Checking for any lingering soft-deleted Foundry accounts to purge..."
az cognitiveservices account list-deleted \
  --query "[?contains(name, 'foundry')].{name:name, location:location, rg:resourceGroup}" -o tsv 2>/dev/null \
  | while read -r dname dloc drg; do
      [[ -z "$dname" ]] && continue
      echo "  purging soft-deleted '$dname' ($dloc)..."
      az cognitiveservices account purge -g "$drg" -n "$dname" -l "$dloc" -o none 2>/dev/null || true
    done

# ---- 3) NOW delete the resource group (VNet, firewall, PEs, data, etc.) ----
echo "Deleting resource group '$RG' (the SAL is released, so the spoke VNet can go)..."
az group delete -n "$RG" --yes --no-wait
echo "Delete started (background). Verify later with: az group show -n $RG"
echo
echo "If the RG delete ever hangs on the spoke VNet, re-run this script — step 2"
echo "(purge) is the fix for the Microsoft.App/environments service-association-link."
