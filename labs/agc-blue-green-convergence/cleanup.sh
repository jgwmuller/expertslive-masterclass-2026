#!/usr/bin/env bash
# ============================================================================
#  Tear down the AGC convergence lab.
#
#  Deleting the resource group removes the AKS cluster and the managed identity.
#  The Application Gateway for Containers resource (and its association) was
#  created by the ALB controller in the AKS NODE resource group, which AKS
#  deletes automatically when the cluster is deleted — so a single RG delete
#  cleans everything up.
#
#  Usage:
#    RG=rg-agc-convergence-lab ./cleanup.sh      # prompts for confirmation
#    CONFIRM=1 ./cleanup.sh                        # no prompt (scripted)
# ============================================================================
set -euo pipefail

RG="${RG:-rg-agc-convergence-lab}"

az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

if [[ "${CONFIRM:-0}" != "1" ]]; then
  read -r -p "Delete resource group '$RG' and EVERYTHING in it? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

echo "Deleting resource group '$RG'..."
az group delete -n "$RG" --yes --no-wait
echo "Delete started (running in the background). The AGC, AKS, identity and VNet all go with it."
