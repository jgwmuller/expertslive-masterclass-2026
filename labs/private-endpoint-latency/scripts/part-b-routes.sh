#!/usr/bin/env bash
# ============================================================================
#  PART B — "Your routes might be lying"
# ----------------------------------------------------------------------------
#  Run this FROM your machine (it drives `az` locally and SSHes to the client
#  VM for traceroute). Requires DEPLOY_FIREWALL=1 on deploy.sh first.
#
#  The arc:
#    1. Show the client NIC effective routes — the injected /32
#       InterfaceEndpoint routes for each Private Endpoint.
#    2. Associate an EMPTY route table to the client subnet, then add a LEGACY
#       /32 UDR per PE IP -> Azure Firewall. Re-read effective routes +
#       traceroute. Watch whether the /32 PE route still wins (firewall
#       bypassed) — the "routes are lying" moment.
#    3. Enable `--ple-network-policies RouteTableEnabled` on the PE subnet,
#       swap the /32s for a SINGLE summary /24 UDR -> firewall, re-read.
#       Now the firewall actually sees the traffic (traceroute shows the AzFW
#       instance IPs as the first hop).
#
#  Usage:
#    RG=rg-pe-latency-lab CLIENT_IP=x.x.x.x ADMIN_USER=azureuser \
#      ./scripts/part-b-routes.sh
# ============================================================================
set -euo pipefail

# ---- Config (override via env) -------------------------------------------
RG="${RG:-rg-pe-latency-lab}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
CLIENT_IP="${CLIENT_IP:?Set CLIENT_IP=<client VM public IP> (from deploy.sh output)}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}"

command -v az >/dev/null || { echo "ERROR: Azure CLI (az) not found." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in. Run: az login" >&2; exit 1; }

line() { printf -- '=%.0s' {1..76}; echo; }
pause() { if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then read -r -p ">> Press Enter to continue..." _; fi; }

# ---- Discover the deployed names from the lab --------------------------
echo "Reading lab resource names from RG '$RG'..."
VNET="$(az network vnet list -g "$RG" --query "[?name=='vnet-pelab'].name | [0]" -o tsv)"
VNET="${VNET:-vnet-pelab}"
CLIENT_SUBNET="${CLIENT_SUBNET:-snet-client}"
PE_SUBNET="${PE_SUBNET:-snet-pe}"
PE_SUBNET_PREFIX="${PE_SUBNET_PREFIX:-10.20.2.0/24}"
ROUTE_TABLE="${ROUTE_TABLE:-rt-client-to-fw}"

# Client NIC name (from main.bicep this is 'nic-client').
NIC="${NIC:-nic-client}"

# Azure Firewall private IP (next hop for all our UDRs).
FW_IP="${FW_IP:-$(az network firewall show -n azfw-pelab -g "$RG" \
  --query "ipConfigurations[0].privateIPAddress" -o tsv 2>/dev/null || true)}"
if [[ -z "${FW_IP:-}" ]]; then
  echo "ERROR: Could not find Azure Firewall 'azfw-pelab'. Did you deploy with DEPLOY_FIREWALL=1?" >&2
  exit 1
fi
echo "Azure Firewall private IP (UDR next hop): $FW_IP"

# Discover the two PE NIC private IPs (the /32s we'll try to override).
# Use a while-read loop instead of `mapfile` (bash 3.2 on stock macOS lacks it).
echo "Discovering Private Endpoint IPs..."
PE_IPS=()
while IFS= read -r line; do PE_IPS+=("$line"); done < <(az network private-endpoint list -g "$RG" \
  --query "[].customDnsConfigs[].ipAddresses[]" -o tsv | sort -u)
if [[ "${#PE_IPS[@]}" -eq 0 ]]; then
  # Fallback: read from the PE NICs directly.
  PE_IPS=()
  while IFS= read -r line; do PE_IPS+=("$line"); done < <(az network nic list -g "$RG" \
    --query "[?contains(name,'pe-')].ipConfigurations[].privateIPAddress" -o tsv | sort -u)
fi
echo "Private Endpoint IPs: ${PE_IPS[*]:-<none found>}"
# VERIFY-IN-TEST: confirm customDnsConfigs[].ipAddresses[] returns the PE IPs on
# your CLI/API version. If empty, the NIC fallback above should populate PE_IPS.

# Helper: run a command on the client VM over SSH.
on_vm() { ssh $SSH_OPTS "${ADMIN_USER}@${CLIENT_IP}" "$@"; }

# ===========================================================================
line
echo "  STEP 1 — The injected /32 routes (the truth the SDN programmed)"
line
# Exact command from KB section 2:
#   az network nic show-effective-route-table -n hubvmVMNic -g \$rg -o table
echo "+ az network nic show-effective-route-table -n $NIC -g $RG -o table"
az network nic show-effective-route-table -n "$NIC" -g "$RG" -o table
cat <<'EOF'

Look for the InterfaceEndpoint rows — one /32 per Private Endpoint:

  Source   State   Address Prefix   Next Hop Type
  Default  Active  10.20.2.4/32     InterfaceEndpoint
  Default  Active  10.20.2.5/32     InterfaceEndpoint

These are NOT advertised over BGP and never show on a gateway/vHub route table.
They are SDN-programmed per-NIC. This is the route you are about to try to beat.
EOF
# VERIFY-IN-TEST: capture the EXACT effective-route output here (column order,
# whether the /32s show as 'InterfaceEndpoint' vs 'Other', and the real PE IPs).
pause

# ===========================================================================
line
echo "  STEP 2 — Legacy /32 UDRs -> firewall (the method that used to work)"
line
echo "Associating route table '$ROUTE_TABLE' to subnet '$CLIENT_SUBNET'..."
echo "+ az network vnet subnet update -n $CLIENT_SUBNET --vnet-name $VNET -g $RG --route-table $ROUTE_TABLE"
az network vnet subnet update -n "$CLIENT_SUBNET" --vnet-name "$VNET" -g "$RG" \
  --route-table "$ROUTE_TABLE" -o none

# Add one /32 UDR per PE IP, next hop = Azure Firewall (KB section 2, Method A):
#   AddressPrefix    NextHopIpAddress   NextHopType
#   10.13.77.4/32    10.13.76.68        VirtualAppliance
i=0
for ip in "${PE_IPS[@]}"; do
  i=$((i + 1))
  echo "+ az network route-table route create -n pe-${i}-to-fw -g $RG --route-table-name $ROUTE_TABLE \\"
  echo "    --address-prefix ${ip}/32 --next-hop-type VirtualAppliance --next-hop-ip-address $FW_IP"
  az network route-table route create -n "pe-${i}-to-fw" -g "$RG" \
    --route-table-name "$ROUTE_TABLE" \
    --address-prefix "${ip}/32" \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "$FW_IP" -o none
done

echo
echo "Re-reading the client NIC effective routes (give the SDN ~30-60s to converge)..."
sleep 30
echo "+ az network nic show-effective-route-table -n $NIC -g $RG -o table"
az network nic show-effective-route-table -n "$NIC" -g "$RG" -o table

echo
echo "Traceroute from the client VM to a PE (TCP/443):"
for ip in "${PE_IPS[@]}"; do
  echo "-> $ip"
  on_vm "sudo traceroute -T -p 443 -m 5 -w 2 $ip || true"
  echo
done
cat <<EOF

WHAT TO LOOK FOR — the latency tells you which mode you're in:

  (a) FAR-PE latency COLLAPSES from Part A's ~250+ ms to a few ms
      -> AzFW IS in path; the /32 UDR is being honoured.
      -> Expected in THIS lab's topology (no VPN gateway / GatewaySubnet).
  (b) FAR-PE latency STAYS at ~250+ ms
      -> AzFW BYPASSED; /32 PE route silently won (the documented failure mode).
      -> Only reliably reproduces inside the GatewaySubnet of an active/active
         VPN gateway. THIS LAB DOES NOT HAVE ONE, so don't expect to see (b)
         here — that demo needs a separate appendix lab with a VNG attached.

  IMPORTANT: AzFW does NOT decrement TTL when forwarding TCP. Traceroute will
  ALWAYS show the PE as the single visible hop, whether or not the firewall is
  in path. **Latency is your only evidence**, not hop count. Compare against
  Part A's ~250 ms number for the FAR PE to know which mode you got.

  Either way, Step 3 (RouteTableEnabled + summary UDR) is the GA-supported
  durable pattern. In this lab it's defence in depth; in the GatewaySubnet
  scenario it's the only thing that works.
EOF
pause

# ===========================================================================
line
echo "  STEP 3 — The real fix: PE network policies + a summary UDR"
line
# KB section 2, Method B — the GA (Aug 2022) supported fix:
echo "Enabling RouteTableEnabled PE network policies on the PE subnet..."
echo "+ az network vnet subnet update -n $PE_SUBNET --vnet-name $VNET -g $RG --ple-network-policies RouteTableEnabled"
az network vnet subnet update -n "$PE_SUBNET" --vnet-name "$VNET" -g "$RG" \
  --ple-network-policies RouteTableEnabled -o none

echo "Removing the legacy /32 UDRs and adding ONE summary UDR for the whole PE subnet..."
i=0
for _ in "${PE_IPS[@]}"; do
  i=$((i + 1))
  az network route-table route delete -n "pe-${i}-to-fw" -g "$RG" \
    --route-table-name "$ROUTE_TABLE" -o none 2>/dev/null || true
done

# Single summary UDR (KB section 2, Method B):  10.13.77.0/24 -> VirtualAppliance
echo "+ az network route-table route create -n pe-subnet-to-fw -g $RG --route-table-name $ROUTE_TABLE \\"
echo "    --address-prefix $PE_SUBNET_PREFIX --next-hop-type VirtualAppliance --next-hop-ip-address $FW_IP"
az network route-table route create -n "pe-subnet-to-fw" -g "$RG" \
  --route-table-name "$ROUTE_TABLE" \
  --address-prefix "$PE_SUBNET_PREFIX" \
  --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FW_IP" -o none

echo
echo "Re-reading effective routes (allow the SDN ~30-60s to converge)..."
sleep 30
echo "+ az network nic show-effective-route-table -n $NIC -g $RG -o table"
az network nic show-effective-route-table -n "$NIC" -g "$RG" -o table

echo
echo "Traceroute from the client VM, now expecting the firewall in path:"
for ip in "${PE_IPS[@]}"; do
  echo "-> $ip"
  on_vm "sudo traceroute -T -p 443 -m 5 -w 2 $ip || true"
  echo
done
cat <<EOF

THE FIX confirmed — by LATENCY DROP, not by traceroute hops:

  AzFW does NOT decrement TTL when it forwards, so traceroute shows ONE hop
  (the PE) in BOTH "firewall bypassed" and "firewall intercepting" states.
  Hop count is not the signal — latency is.

      Part A (direct, no firewall)            ->  FAR PE ~250+ ms
      Part B Step 3 (UDR + RouteTableEnabled) ->  FAR PE single-digit ms

  If FAR-PE latency just collapsed by two orders of magnitude, the firewall
  IS terminating the TCP locally. If it stayed at ~250 ms, the fix didn't
  take — most likely RouteTableEnabled isn't set on the PE subnet, OR your
  UDR prefix isn't more-specific than the PE subnet's VNet route.

  Definitive proof in the firewall logs (KB section 2 KQL):
    AzureDiagnostics
    | where TimeGenerated > ago(10m)
    | project TimeGenerated, Category, SourceIP, DestinationIp_s, Fqdn_s, Action_s

THE PUNCHLINE:
  The "/32 PE route silently wins over a legacy /32 UDR" behavior is the
  GatewaySubnet/VPN-gateway failure mode — not reproducible in this pure-spoke
  lab, but it's the reason RouteTableEnabled exists. It's the durable,
  recommended pattern any time you need PE traffic inspected by a hub firewall.
  The troubleshooting triad: what /32 was injected, what next-hop did it get,
  is RouteTableEnabled on the PE subnet?

Next:
  Part C — show that the firewall is a TLS-terminating PROXY:
    RG=$RG CLIENT_IP=$CLIENT_IP ADMIN_USER=$ADMIN_USER \\
      $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/part-c-firewall.sh
EOF
