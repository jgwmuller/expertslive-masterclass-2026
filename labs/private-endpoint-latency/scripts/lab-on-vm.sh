#!/usr/bin/env bash
# ============================================================================
#  Private Endpoint latency reveal — run ON the client VM.
#  (A readable copy of the script cloud-init installs at
#   /usr/local/bin/lab-on-vm.sh — keep the two in sync if you edit.)
#
#  Usage: sudo lab-on-vm.sh <near-blob-fqdn> <far-blob-fqdn>
# ============================================================================
set -euo pipefail

NEAR="${1:?Pass the NEAR storage blob FQDN as arg 1}"
FAR="${2:?Pass the FAR storage blob FQDN as arg 2}"

line() { printf -- '-%.0s' {1..72}; echo; }

echo
line
echo "  STEP 1 - DNS: where do these FQDNs resolve?"
line
for fqdn in "$NEAR" "$FAR"; do
  echo "-> $fqdn"
  dig +noall +answer "$fqdn"
  echo
done
echo "Both resolve to PRIVATE IPs in the LOCAL private-endpoint subnet (10.20.2.x)."
echo "From DNS alone the two services look identical and equally 'local'."
echo

line
echo "  STEP 2 - Latency: mtr -T -P 443 (TCP SYN to the data plane)"
line
echo "-> NEAR storage ($NEAR)"
mtr -T -P 443 -c 20 --report --no-dns "$NEAR" || true
echo
echo "-> FAR storage ($FAR)"
mtr -T -P 443 -c 20 --report --no-dns "$FAR" || true
echo

line
echo "  THE REVEAL"
line
cat <<'EOF'
Both Private Endpoints are local NICs in the SAME subnet, yet:
  * NEAR storage answers in single-digit milliseconds.
  * FAR  storage answers in ~200+ ms.

If the PE were a network hop / proxy, BOTH would be local-fast.
They are not. The PE only injected a /32 route + a DNS record.
The TCP handshake actually round-trips to the storage account's
REAL region over Microsoft's backbone.

==> A Private Endpoint never carries data. It is control-plane only.
EOF
