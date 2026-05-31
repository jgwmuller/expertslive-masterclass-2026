#!/usr/bin/env bash
# ============================================================================
#  hammer.sh — the convergence reveal (run this in TERMINAL A).
#
#  Fires a request at the AGC frontend every ~0.1s and keeps a live tally of:
#    OK    — HTTP 2xx/3xx responses
#    FAIL  — timeouts, connection errors, or 5xx (a dropped request)
#    BLUE  — responses served by backend-v1 (the active service)
#    GREEN — responses served by backend-v2 (the standby service)
#
#  Each request uses a short timeout, so a real outage would immediately show up
#  as FAIL. While this runs, kill the BLUE backend in another terminal
#  (scripts/kill-active.sh). AGC reconverges to GREEN in under a second:
#  BLUE freezes, GREEN climbs, and FAIL never moves off 0.
#
#  Usage:
#    ./hammer.sh <AGC_FQDN | http://AGC_FQDN>
#    INTERVAL=0.05 ./hammer.sh <AGC_FQDN>     # hammer harder
# ============================================================================
set -uo pipefail

FQDN="${1:-}"
if [[ -z "$FQDN" ]]; then
  echo "Usage: $0 <AGC_FQDN>   (the *.alb.azure.com name from deploy.sh)" >&2
  exit 1
fi
# Accept either a bare FQDN or a full URL.
URL="$FQDN"
[[ "$URL" == http*://* ]] || URL="http://$FQDN"

INTERVAL="${INTERVAL:-0.1}"

total=0; ok=0; fail=0; blue=0; green=0; last=""
start_epoch=$(date +%s)

summary() {
  echo
  echo "------------------------------------------------------------"
  echo " Final tally after $(( $(date +%s) - start_epoch ))s"
  echo "   total requests : $total"
  echo "   OK   (2xx/3xx) : $ok"
  echo "   FAIL (5xx/err) : $fail        <-- the number that should stay 0"
  echo "   served by BLUE : $blue"
  echo "   served by GREEN: $green"
  echo "------------------------------------------------------------"
  rm -f "${body:-}"
  exit 0
}

printf 'Hammering %s every %ss. Press Ctrl-C to stop.\n\n' "$URL" "$INTERVAL"
body="$(mktemp)"
trap summary INT

while true; do
  total=$((total+1))
  # set -e is intentionally off; a curl failure just yields an empty/000 code.
  code="$(curl -s -o "$body" -w '%{http_code}' --connect-timeout 2 --max-time 3 "$URL" 2>/dev/null)"
  code="${code:-000}"

  if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
    ok=$((ok+1))
    if grep -q 'GREEN' "$body" 2>/dev/null; then
      green=$((green+1)); last='GREEN'
    elif grep -q 'BLUE' "$body" 2>/dev/null; then
      blue=$((blue+1)); last='BLUE'
    else
      last="?($code)"
    fi
  else
    fail=$((fail+1)); last="FAIL($code)"
  fi

  printf '\r total=%-6d OK=%-6d FAIL=%-4d | BLUE=%-6d GREEN=%-6d | last=%-10s' \
    "$total" "$ok" "$fail" "$blue" "$green" "$last"
  sleep "$INTERVAL"
done
