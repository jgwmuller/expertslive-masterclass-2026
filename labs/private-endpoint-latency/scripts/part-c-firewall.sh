#!/usr/bin/env bash
# ============================================================================
#  PART C — "Azure Firewall application rules are a proxy"
# ----------------------------------------------------------------------------
#  Run this FROM your machine (drives `az` locally, SSHes to the client VM for
#  mtr). Requires Part B done first (firewall in path via PE network policies).
#
#  The arc:
#    1. Add an AzFW APPLICATION rule allowing the blob FQDN(s). App rules make
#       AzFW terminate TCP/TLS, read the SNI, and do its OWN DNS lookup.
#    2. Show the DNS-zone-link dependency: DELETE the privatelink.blob link to
#       the firewall's hub VNet -> AzFW resolves the PUBLIC IP -> PE bypassed /
#       storage (publicNetworkAccess=Disabled) rejects it. Re-create the link
#       -> AzFW resolves the PE private IP -> works.
#    3. From the client, `mtr -T -P 443` to the FAR-region blob FQDN shows an
#       "impossible" low latency: you're hitting the FIREWALL (the real TCP
#       endpoint), not the far storage region. Proof AzFW is a proxy.
#
#  Usage:
#    RG=rg-pe-latency-lab CLIENT_IP=x.x.x.x ADMIN_USER=azureuser \
#      FAR_FQDN=stfarXXXX.blob.core.windows.net \
#      NEAR_FQDN=stnearXXXX.blob.core.windows.net \
#      ./scripts/part-c-firewall.sh
# ============================================================================
set -euo pipefail

# ---- Config (override via env) -------------------------------------------
RG="${RG:-rg-pe-latency-lab}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
CLIENT_IP="${CLIENT_IP:?Set CLIENT_IP=<client VM public IP> (from deploy.sh output)}"
FAR_FQDN="${FAR_FQDN:?Set FAR_FQDN=<far storage blob FQDN> (from deploy.sh output)}"
NEAR_FQDN="${NEAR_FQDN:-}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}"

FW_NAME="${FW_NAME:-azfw-pelab}"
FW_POLICY="${FW_POLICY:-azfwpolicy-pelab}"
RCG="${RCG:-pelab-app-rules}"                 # rule collection GROUP shipped by firewall.bicep
HUB_VNET="${HUB_VNET:-vnet-hub}"
BLOB_ZONE="${BLOB_ZONE:-privatelink.blob.core.windows.net}"
HUB_DNS_LINK="${HUB_DNS_LINK:-link-to-${HUB_VNET}}"

command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

line() { printf -- '=%.0s' {1..76}; echo; }
pause() { if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then read -r -p ">> Press Enter to continue..." _; fi; }
on_vm() { ssh $SSH_OPTS "${ADMIN_USER}@${CLIENT_IP}" "$@"; }

FW_IP="${FW_IP:-$(az network firewall show -n "$FW_NAME" -g "$RG" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv 2>/dev/null || true)}"
[[ -n "$FW_IP" ]] || { echo "ERROR: firewall '$FW_NAME' not found. Deploy with DEPLOY_FIREWALL=1." >&2; exit 1; }
echo "Azure Firewall private IP: $FW_IP"

# ===========================================================================
line
echo "  STEP 1 — Add an Azure Firewall APPLICATION rule for the blob FQDN(s)"
line
# Build the FQDN target list (NEAR optional).
FQDNS="$FAR_FQDN"
[[ -n "$NEAR_FQDN" ]] && FQDNS="$FQDNS $NEAR_FQDN"
echo "Allowing FQDN(s): $FQDNS"

# App rule collection lives in the rule-collection GROUP shipped empty by
# firewall.bicep. (KB section 4: app rules cause AzFW to proxy on SNI.)
echo "+ az network firewall policy rule-collection-group collection add-filter-collection \\"
echo "    -g $RG --policy-name $FW_POLICY --rule-collection-group-name $RCG \\"
echo "    --name allow-blob --collection-priority 1000 --action Allow \\"
echo "    --rule-name allow-blob-fqdn --rule-type ApplicationRule \\"
echo "    --target-fqdns $FQDNS --protocols Https=443 --source-addresses '*'"
az network firewall policy rule-collection-group collection add-filter-collection \
  -g "$RG" --policy-name "$FW_POLICY" --rule-collection-group-name "$RCG" \
  --name allow-blob --collection-priority 1000 --action Allow \
  --rule-name allow-blob-fqdn --rule-type ApplicationRule \
  --target-fqdns $FQDNS --protocols Https=443 --source-addresses '*' -o none
# VERIFY-IN-TEST: confirm this exact `add-filter-collection` invocation +
# parameter names on your az CLI version (it has churned across releases). If it
# errors, the equivalent is building the policy with a ruleCollectionGroups ARM
# body, or `az network firewall policy rule-collection-group collection
# add-filter-collection --help` for the current flag spelling.

echo "Application rule added. Source '*' is fine for the lab; tighten in prod."
pause

# ===========================================================================
line
echo "  STEP 2 — The DNS-zone-link dependency (the silent-bypass trap)"
line
cat <<EOF
AzFW app rules do their OWN DNS lookup against the firewall VNet's resolver.
If the privatelink.blob zone is NOT linked to the hub VNet, AzFW resolves the
PUBLIC storage IP — and because the storage accounts have
publicNetworkAccess=Disabled, the request fails. We prove both states by
using a DIFFERENT FQDN in each (NEAR for the missing-link case, FAR for the
re-linked case) so AzFW's per-FQDN DNS cache works WITH us instead of against
us. No 5-minute cache-expiry sleep required.
EOF
[[ -n "$NEAR_FQDN" ]] || { echo "ERROR: This demo needs NEAR_FQDN as well as FAR_FQDN. Set NEAR_FQDN=<near storage FQDN> and re-run." >&2; exit 1; }

echo
echo "2a. REMOVE the zone link to the hub (simulate the forgotten link):"
echo "+ az network private-dns link vnet delete -g $RG -z $BLOB_ZONE -n $HUB_DNS_LINK --yes"
az network private-dns link vnet delete -g "$RG" -z "$BLOB_ZONE" -n "$HUB_DNS_LINK" --yes -o none 2>/dev/null || \
  echo "  (link '$HUB_DNS_LINK' not present — continuing)"

# Quick ARM/DNS propagation wait so the zone-link delete is visible to AzFW's
# resolver. Tens of seconds, not minutes — we are NOT waiting for cache expiry
# (the cache stays full of the prior PE IP, but we hit it with a different
# FQDN below so the cache misses and AzFW does a fresh lookup).
echo "  Waiting 30s for zone-link delete to propagate to AzFW's resolver..."
sleep 30

echo
echo "2a curl — using NEAR FQDN (AzFW has NEVER resolved this one, so cache miss):"
echo "+ (on VM) curl -sv --resolve ${NEAR_FQDN}:443:${FW_IP} https://${NEAR_FQDN}/ ..."
on_vm "curl -s -o /dev/null -w 'HTTP %{http_code}  time_total=%{time_total}s\n' \
  --resolve ${NEAR_FQDN}:443:${FW_IP} https://${NEAR_FQDN}/ --max-time 15 || true"
cat <<'EOF'

EXPECTED while the link is MISSING: the request fails — usually a
network-level timeout or a 4xx from the storage account refusing public
traffic. AzFW just did its FIRST DNS lookup for NEAR, got the PUBLIC IP
(no hub link to the privatelink zone), opened a connection to that public
IP, and the storage refused (publicNetworkAccess=Disabled).
EOF
pause

echo
echo "2b. RE-CREATE the zone link to the hub VNet (the fix):"
HUB_VNET_ID="$(az network vnet show -n "$HUB_VNET" -g "$RG" --query id -o tsv)"
echo "+ az network private-dns link vnet create -g $RG -z $BLOB_ZONE -n $HUB_DNS_LINK \\"
echo "    --virtual-network $HUB_VNET_ID --registration-enabled false"
az network private-dns link vnet create -g "$RG" -z "$BLOB_ZONE" -n "$HUB_DNS_LINK" \
  --virtual-network "$HUB_VNET_ID" --registration-enabled false -o none

echo "  Waiting 30s for zone-link create to propagate to AzFW's resolver..."
sleep 30
echo
echo "2b curl — using FAR FQDN (AzFW has NEVER resolved this one either,"
echo "so it cache-misses, does a fresh lookup WITH the hub zone link present,"
echo "and gets the PE private IP):"
on_vm "curl -s -o /dev/null -w 'HTTP %{http_code}  time_total=%{time_total}s\n' \
  --resolve ${FAR_FQDN}:443:${FW_IP} https://${FAR_FQDN}/ --max-time 15 || true"
cat <<'EOF'

EXPECTED now: HTTP 400/403/409 (an AUTH/storage-level response, NOT a network
failure) — meaning the TLS handshake completed THROUGH the firewall to the PE.
The 4xx is storage saying "no anonymous request"; the network path is good.

WHY this works without a 5-min cache-expiry sleep: 2a used the NEAR FQDN
(fresh, no cache); 2b uses the FAR FQDN (also fresh, no cache). Each curl
forces AzFW to do a NEW DNS lookup, so the link state at the moment of the
lookup is what wins. If you used the same FQDN in both, AzFW would cache
the first answer for ~5 min and the second curl would silently return the
stale cached value.
EOF
pause

# ===========================================================================
line
echo "  STEP 3 — The impossible latency: mtr proves AzFW is the TCP endpoint"
line
cat <<EOF
Now mtr -T -P 443 the FAR-region blob FQDN. With the firewall PROXYING on SNI,
the client's TCP/TLS terminates AT THE FIREWALL — so RTT collapses to the
~local firewall latency, NOT the ~200+ ms it took in Part A straight to the
far storage region. AzFW also does NOT decrement TTL (proxy), so it isn't even
a visible hop. That low number to a far region is physically impossible unless
something local is answering the TCP — the firewall is.
EOF
echo
echo "-> FAR blob through the firewall app-rule proxy ($FAR_FQDN)"
on_vm "mtr -T -P 443 -c 20 --report --no-dns $FAR_FQDN || true"
cat <<EOF

WHAT YOU'LL SEE:
    mtr -T -P 443 stXXXXfar.blob.core.windows.net
    1.  10.20.2.x   ~1-5 ms     <- the PE IP, but ANSWERED by AzFW (~5 ms RTT)

  AzFW is TTL-transparent — it doesn't appear as its own hop. The visible hop
  is still the PE IP that DNS resolved to. The proof is the LATENCY, not the
  hop list: single-digit ms to a FAR-region target is physically impossible
  unless something local terminated the TCP. That "something" is the firewall.

THE REVEAL:
  In Part A this same FAR FQDN measured ~250+ ms (real region distance). Routed
  through the AzFW application rule it measures single-digit ms — because AzFW
  terminated the TCP, read the SNI, and opened its OWN connection onward. The
  destination IP in the client packet is irrelevant; the SNI is what matters.

  KQL to see the proxied request in AzFW logs (KB section 4):
    AzureDiagnostics
    | where TimeGenerated > ago(15m)
    | where Category in ("AZFWApplicationRule", "AZFWNetworkRule")
    | project TimeGenerated, Category, SourceIP, Fqdn_s, Protocol_s, Action_s

THE PUNCHLINE:
  AzFW application rules are a TLS-terminating proxy. They resolve DNS
  themselves, so you MUST link the privatelink.* zone to the firewall VNet —
  forget it and AzFW resolves the public IP and bypasses the PE entirely.
  "Who's proxying?" is the third troubleshooting question after "what /32" and
  "what next-hop".

Tear down when done (deletes the WHOLE RG, firewall included):
  RG=$RG ../cleanup.sh
EOF
