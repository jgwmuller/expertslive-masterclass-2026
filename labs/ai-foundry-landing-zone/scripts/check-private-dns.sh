#!/usr/bin/env bash
# ============================================================================
#  Readable copy of the DNS reveal (also dropped onto the jump VM by cloud-init).
#
#  Run this FROM INSIDE the VNet (Bastion -> jump box). Every Foundry/Search/
#  Storage/Cosmos FQDN should resolve to a PRIVATE 192.168.1.x address.
#
#  Then run the SAME nslookups from your laptop (outside the VNet): the names
#  either NXDOMAIN or return a public IP / CNAME chain that lands nowhere
#  reachable — proving the data plane is private.
#
#  Usage (FQDNs come from deploy.sh output):
#    check-private-dns.sh <cognitive-fqdn> <openai-fqdn> <search-fqdn> <blob-fqdn> <cosmos-fqdn>
# ============================================================================
set -u

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <fqdn> [<fqdn> ...]" >&2
  exit 1
fi

for fqdn in "$@"; do
  echo "=============================================================="
  echo "nslookup $fqdn"
  nslookup "$fqdn" || true
done

cat <<'EOF'
==============================================================
Expected from INSIDE the VNet: every name resolves to a PRIVATE 192.168.1.x IP.

The teaching moment — run the SAME command from OUTSIDE the VNet (your laptop):
  - public network access is Disabled, so the public name is unreachable
  - and the private A-records only exist in the private DNS zones linked to
    the hub/spoke VNets, so your laptop can't see them at all.

If a name NXDOMAINs or returns a public IP from inside the VNet, its private
endpoint or its private DNS zone link is missing. PEs to Search/Storage/Cosmos
are NOT auto-created with Foundry — that is the failure this lab makes you feel.
EOF
