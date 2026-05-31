#!/usr/bin/env bash
# ============================================================================
#  Lab 2A — one-command entry point for attendees.
#
#  Fires the AGC blue/green deploy and the APIM AI-gateway deploy IN PARALLEL,
#  because APIM Developer SKU takes ~30–45 min to provision (longer than the
#  whole module). If you run them serially, you'll never finish in a 90-min
#  workshop slot. This wrapper exists so attendees can't forget the parallel
#  start.
#
#  Usage:
#    ./deploy-both.sh
#
#  Override anything via env var, e.g.:
#    LOCATION=westeurope ./deploy-both.sh
#    PEER_AKS_VNET=1 ./deploy-both.sh
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGC_LOG="${AGC_LOG:-/tmp/agc-deploy-$(date +%s).log}"
APIM_LOG="${APIM_LOG:-/tmp/apim-deploy-$(date +%s).log}"

command -v az >/dev/null || { echo "ERROR: Azure CLI not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

echo "============================================================"
echo "  Lab 2A — parallel deploy"
echo "============================================================"
echo "  Subscription : $(az account show --query name -o tsv)"
echo "  AGC log      : $AGC_LOG"
echo "  APIM log     : $APIM_LOG"
echo
echo "AGC will deploy in ~12-18 min."
echo "APIM Developer SKU will deploy in ~30-45 min (the long pole)."
echo "Running both in parallel; you'll be back at the prompt when both finish."
echo

# Kick off AGC first so its output prints first; both run in parallel after this.
("$SCRIPT_DIR/deploy.sh" > "$AGC_LOG" 2>&1; echo "[AGC] exit=$?" >> "$AGC_LOG") &
AGC_PID=$!
# Tiny stagger so the two scripts don't race on `az provider register` calls.
sleep 5
("$SCRIPT_DIR/apim/deploy-apim.sh" > "$APIM_LOG" 2>&1; echo "[APIM] exit=$?" >> "$APIM_LOG") &
APIM_PID=$!

echo "AGC  PID: $AGC_PID  -> tail with: tail -f $AGC_LOG"
echo "APIM PID: $APIM_PID  -> tail with: tail -f $APIM_LOG"
echo
echo "Watching both. Live status every 30s..."
echo

# Live status loop — emit one line whenever either child finishes.
agc_done=0; apim_done=0
while [[ $agc_done -eq 0 || $apim_done -eq 0 ]]; do
  sleep 30
  if [[ $agc_done -eq 0 ]] && ! kill -0 "$AGC_PID" 2>/dev/null; then
    agc_done=1
    AGC_EXIT="$(grep -oE '\[AGC\] exit=[0-9]+' "$AGC_LOG" | tail -1 | cut -d= -f2)"
    echo "[$(date +%H:%M:%S)] AGC finished (exit=${AGC_EXIT:-?}). APIM still going."
  fi
  if [[ $apim_done -eq 0 ]] && ! kill -0 "$APIM_PID" 2>/dev/null; then
    apim_done=1
    APIM_EXIT="$(grep -oE '\[APIM\] exit=[0-9]+' "$APIM_LOG" | tail -1 | cut -d= -f2)"
    echo "[$(date +%H:%M:%S)] APIM finished (exit=${APIM_EXIT:-?}). AGC ${agc_done:+done}."
  fi
  # Lightweight heartbeat while waiting
  if [[ $agc_done -eq 0 || $apim_done -eq 0 ]]; then
    echo "[$(date +%H:%M:%S)] AGC: $([[ $agc_done -eq 1 ]] && echo done || echo running) | APIM: $([[ $apim_done -eq 1 ]] && echo done || echo running)"
  fi
done

echo
echo "============================================================"
echo "  Both deploys finished. Summary:"
echo "============================================================"
echo
echo "--- AGC tail (last 25 lines of $AGC_LOG) ---"
tail -25 "$AGC_LOG"
echo
echo "--- APIM tail (last 25 lines of $APIM_LOG) ---"
tail -25 "$APIM_LOG"
echo
echo "Next steps are printed in each tail above (blue/green hammer for AGC, smoke test for APIM)."
echo "When you're done with the lab, tear both down with:"
echo "  ./cleanup.sh                          # AGC RG"
echo "  ./apim/cleanup-apim.sh                # APIM RG (note: APIM Dev-SKU is non-deletable for ~45 min after create)"
