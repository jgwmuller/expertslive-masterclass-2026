#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
============================================================================
  PART B — "Your routes might be lying"   (PowerShell variant of part-b-routes.sh)
----------------------------------------------------------------------------
  Run this FROM your machine (it drives `az` locally and SSHes to the client
  VM for traceroute). Requires the firewall deploy first
  (./deploy.ps1 -DeployFirewall 1, or DEPLOY_FIREWALL=1 ./deploy.sh).

  The arc:
    1. Show the client NIC effective routes — the injected /32
       InterfaceEndpoint routes for each Private Endpoint.
    2. Associate an EMPTY route table to the client subnet, then add a LEGACY
       /32 UDR per PE IP -> Azure Firewall. Re-read effective routes +
       traceroute. Watch whether the /32 PE route still wins (firewall
       bypassed) — the "routes are lying" moment.
    3. Enable `--ple-network-policies RouteTableEnabled` on the PE subnet,
       swap the /32s for a SINGLE summary /24 UDR -> firewall, re-read.
       Now the firewall actually sees the traffic.

  Usage (parameters or the same env vars as part-b-routes.sh both work):
    ./part-b-routes.ps1 -ClientIp x.x.x.x -Rg rg-pe-latency-lab -AdminUser azureuser
    # or:  $env:CLIENT_IP='x.x.x.x'; ./part-b-routes.ps1
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg             = ($env:RG              ?? 'rg-pe-latency-lab'),
  [string]$AdminUser      = ($env:ADMIN_USER      ?? 'azureuser'),
  [string]$ClientIp       = $env:CLIENT_IP,
  [string]$Vnet           = ($env:VNET            ?? 'vnet-pelab'),
  [string]$ClientSubnet   = ($env:CLIENT_SUBNET   ?? 'snet-client'),
  [string]$PeSubnet       = ($env:PE_SUBNET       ?? 'snet-pe'),
  [string]$PeSubnetPrefix = ($env:PE_SUBNET_PREFIX ?? '10.20.2.0/24'),
  [string]$RouteTable     = ($env:ROUTE_TABLE     ?? 'rt-client-to-fw'),
  [string]$Nic            = ($env:NIC             ?? 'nic-client'),
  [string]$FwIp           = $env:FW_IP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# az/ssh do not throw in PowerShell; we check $LASTEXITCODE explicitly (and keep
# native error-action off so the tolerant `2>$null` deletes below don't throw).
$PSNativeCommandUseErrorActionPreference = $false

# ---- Helpers --------------------------------------------------------------
# Plain functions using the automatic $args (NOT advanced functions — a param()
# block would make `-o` bind to -OutVariable instead of passing through to az).
function Invoke-AzNone {
  & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}
function Invoke-AzOut {
  $out = & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
  return $out
}
function Write-Rule { Write-Host ('=' * 76) }
function Invoke-Pause {
  if ($env:NONINTERACTIVE -ne '1') { Read-Host '>> Press Enter to continue' | Out-Null }
}
function Invoke-OnVm([string]$RemoteCommand) {
  ssh @SshOpts "$AdminUser@$ClientIp" $RemoteCommand
}

# ---- Prereqs --------------------------------------------------------------
if (-not $ClientIp) { throw 'Set -ClientIp <client VM public IP> (or $env:CLIENT_IP) — see deploy output.' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found.' }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Not logged in. Run: az login' }

$SshOpts = if ($env:SSH_OPTS) { $env:SSH_OPTS -split '\s+' }
           else { @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10') }

# ---- Discover the deployed names from the lab --------------------------
Write-Host "Reading lab resource names from RG '$Rg'..."
$found = Invoke-AzOut network vnet list -g $Rg --query "[?name=='vnet-pelab'].name | [0]" -o tsv
if ($found) { $Vnet = $found }

# Azure Firewall private IP (next hop for all our UDRs).
if (-not $FwIp) {
  $FwIp = & az network firewall show -n azfw-pelab -g $Rg --query "ipConfigurations[0].privateIPAddress" -o tsv 2>$null
}
if (-not $FwIp) {
  throw "Could not find Azure Firewall 'azfw-pelab'. Did you deploy with the firewall (-DeployFirewall 1)?"
}
Write-Host "Azure Firewall private IP (UDR next hop): $FwIp"

# Discover the two PE NIC private IPs (the /32s we'll try to override).
Write-Host 'Discovering Private Endpoint IPs...'
$PeIps = @(Invoke-AzOut network private-endpoint list -g $Rg --query "[].customDnsConfigs[].ipAddresses[]" -o tsv |
    Where-Object { $_ } | Sort-Object -Unique)
if ($PeIps.Count -eq 0) {
  # Fallback: read from the PE NICs directly.
  $PeIps = @(Invoke-AzOut network nic list -g $Rg --query "[?contains(name,'pe-')].ipConfigurations[].privateIPAddress" -o tsv |
      Where-Object { $_ } | Sort-Object -Unique)
}
$peIpsDisplay = if ($PeIps.Count) { $PeIps -join ' ' } else { '<none found>' }
Write-Host "Private Endpoint IPs: $peIpsDisplay"
# VERIFY-IN-TEST: confirm customDnsConfigs[].ipAddresses[] returns the PE IPs on
# your CLI/API version. If empty, the NIC fallback above should populate PeIps.

# ===========================================================================
Write-Rule
Write-Host '  STEP 1 — The injected /32 routes (the truth the SDN programmed)'
Write-Rule
# Exact command from KB section 2:
#   az network nic show-effective-route-table -n hubvmVMNic -g $rg -o table
Write-Host "+ az network nic show-effective-route-table -n $Nic -g $Rg -o table"
Invoke-AzNone network nic show-effective-route-table -n $Nic -g $Rg -o table
Write-Host @'

Look for the InterfaceEndpoint rows — one /32 per Private Endpoint:

  Source   State   Address Prefix   Next Hop Type
  Default  Active  10.20.2.4/32     InterfaceEndpoint
  Default  Active  10.20.2.5/32     InterfaceEndpoint

These are NOT advertised over BGP and never show on a gateway/vHub route table.
They are SDN-programmed per-NIC. This is the route you are about to try to beat.
'@
# VERIFY-IN-TEST: capture the EXACT effective-route output here (column order,
# whether the /32s show as 'InterfaceEndpoint' vs 'Other', and the real PE IPs).
Invoke-Pause

# ===========================================================================
Write-Rule
Write-Host '  STEP 2 — Legacy /32 UDRs -> firewall (the method that used to work)'
Write-Rule
Write-Host "Associating route table '$RouteTable' to subnet '$ClientSubnet'..."
Write-Host "+ az network vnet subnet update -n $ClientSubnet --vnet-name $Vnet -g $Rg --route-table $RouteTable"
Invoke-AzNone network vnet subnet update -n $ClientSubnet --vnet-name $Vnet -g $Rg --route-table $RouteTable -o none

# Add one /32 UDR per PE IP, next hop = Azure Firewall (KB section 2, Method A):
#   AddressPrefix    NextHopIpAddress   NextHopType
#   10.13.77.4/32    10.13.76.68        VirtualAppliance
$i = 0
foreach ($ip in $PeIps) {
  $i++
  Write-Host "+ az network route-table route create -n pe-$i-to-fw -g $Rg --route-table-name $RouteTable \"
  Write-Host "    --address-prefix $ip/32 --next-hop-type VirtualAppliance --next-hop-ip-address $FwIp"
  Invoke-AzNone network route-table route create -n "pe-$i-to-fw" -g $Rg `
    --route-table-name $RouteTable --address-prefix "$ip/32" `
    --next-hop-type VirtualAppliance --next-hop-ip-address $FwIp -o none
}

Write-Host ''
Write-Host 'Re-reading the client NIC effective routes (give the SDN ~30-60s to converge)...'
Start-Sleep -Seconds 30
Write-Host "+ az network nic show-effective-route-table -n $Nic -g $Rg -o table"
Invoke-AzNone network nic show-effective-route-table -n $Nic -g $Rg -o table

Write-Host ''
Write-Host 'Traceroute from the client VM to a PE (TCP/443):'
foreach ($ip in $PeIps) {
  Write-Host "-> $ip"
  Invoke-OnVm "sudo traceroute -T -p 443 -m 5 -w 2 $ip || true"
  Write-Host ''
}
Write-Host @'

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
'@
Invoke-Pause

# ===========================================================================
Write-Rule
Write-Host '  STEP 3 — The real fix: PE network policies + a summary UDR'
Write-Rule
# KB section 2, Method B — the GA (Aug 2022) supported fix:
Write-Host 'Enabling RouteTableEnabled PE network policies on the PE subnet...'
Write-Host "+ az network vnet subnet update -n $PeSubnet --vnet-name $Vnet -g $Rg --ple-network-policies RouteTableEnabled"
Invoke-AzNone network vnet subnet update -n $PeSubnet --vnet-name $Vnet -g $Rg --ple-network-policies RouteTableEnabled -o none

Write-Host 'Removing the legacy /32 UDRs and adding ONE summary UDR for the whole PE subnet...'
$i = 0
foreach ($ip in $PeIps) {
  $i++
  # Tolerant delete (route may already be gone) — call az directly, ignore failure.
  & az network route-table route delete -n "pe-$i-to-fw" -g $Rg --route-table-name $RouteTable -o none 2>$null
}

# Single summary UDR (KB section 2, Method B):  10.13.77.0/24 -> VirtualAppliance
Write-Host "+ az network route-table route create -n pe-subnet-to-fw -g $Rg --route-table-name $RouteTable \"
Write-Host "    --address-prefix $PeSubnetPrefix --next-hop-type VirtualAppliance --next-hop-ip-address $FwIp"
Invoke-AzNone network route-table route create -n 'pe-subnet-to-fw' -g $Rg `
  --route-table-name $RouteTable --address-prefix $PeSubnetPrefix `
  --next-hop-type VirtualAppliance --next-hop-ip-address $FwIp -o none

Write-Host ''
Write-Host 'Re-reading effective routes (allow the SDN ~30-60s to converge)...'
Start-Sleep -Seconds 30
Write-Host "+ az network nic show-effective-route-table -n $Nic -g $Rg -o table"
Invoke-AzNone network nic show-effective-route-table -n $Nic -g $Rg -o table

Write-Host ''
Write-Host 'Traceroute from the client VM, now expecting the firewall in path:'
foreach ($ip in $PeIps) {
  Write-Host "-> $ip"
  Invoke-OnVm "sudo traceroute -T -p 443 -m 5 -w 2 $ip || true"
  Write-Host ''
}
Write-Host @"

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
    $PSScriptRoot/part-c-firewall.ps1 -Rg $Rg -ClientIp $ClientIp -AdminUser $AdminUser ``
      -FarFqdn <FAR_FQDN> -NearFqdn <NEAR_FQDN>
"@
