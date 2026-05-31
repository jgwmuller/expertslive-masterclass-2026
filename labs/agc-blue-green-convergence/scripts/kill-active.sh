#!/usr/bin/env bash
# ============================================================================
#  kill-active.sh — the live failover (run this in TERMINAL B, on stage).
#
#  Scales the ACTIVE backend (BLUE / backend-v1) down to zero replicas while the
#  hammer is running in Terminal A. This rips every BLUE endpoint out from under
#  AGC. Watch Terminal A: AGC reconverges all traffic to GREEN in under a second,
#  and the FAIL counter stays at 0.
#
#  Reset for another take:
#    kubectl scale deploy/backend-v1 -n test-infra --replicas=2
# ============================================================================
set -euo pipefail

NS="${NS:-test-infra}"
TARGET="${TARGET:-backend-v1}"

echo "[$(date '+%H:%M:%S.%3N')] Scaling $TARGET to 0 replicas (killing BLUE)..."
kubectl scale deploy/"$TARGET" -n "$NS" --replicas=0
echo "[$(date '+%H:%M:%S.%3N')] Done. AGC should already be serving 100% GREEN."
echo
echo "Reset with: kubectl scale deploy/$TARGET -n $NS --replicas=2"
