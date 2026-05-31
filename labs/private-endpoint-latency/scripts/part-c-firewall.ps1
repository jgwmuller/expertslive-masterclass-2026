#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
============================================================================
  PART C — "Azure Firewall application rules are a proxy"
----------------------------------------------------------------------------
  (PowerShell variant of part-c-firewall.sh.)
  Run this FROM your machine (drives `az` locally, SSHes to the client VM for
  mtr). Requires Part B done first (firewall in path via PE network policies).

  The arc:
    1. Add an AzFW APPLICATION rule allowing the blob FQDN(s). App rules make
       AzFW terminate TCP/TLS, read the SNI, and do its OWN DNS lookup.
    2. Show the DNS-zone-link dependency: DELETE the privatelink.blob link to
       the firewall's hub VNet -> AzFW resolves the PUBLIC IP -> PE bypassed /
       storage (publicNetworkAccess=Disabled) rejects it. Re-create the link
       -> AzFW resolves the PE private IP -> works.
    3. From the client, `mtr -T -P 443` to the FAR-region blob FQDN shows an
       "impossible" low latency: you're hitting the FIREWALL (the real TCP
       endpoint), not the far storage region. Proof AzFW is a proxy.

  Usage (parameters or the same env vars as part-c-firewall.sh both work):
    ./part-c-firewall.ps1 -ClientIp x.x.x.x -Rg rg-pe-latency-lab -AdminUser azureuser `
      -FarFqdn stfarXXXX.blob.core.windows.net -NearFqdn stnearXXXX.blob.core.windows.net
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg         = ($env:RG         ?? 'rg-pe-latency-lab'),
  [string]$AdminUser  = ($env:ADMIN_USER ?? 'azureuser'),
  [string]$ClientIp   = $env:CLIENT_IP,
  [string]$FarFqdn    = $env:FAR_FQDN,
  [string]$NearFqdn   = $env:NEAR_FQDN,
  [string]$FwName     = ($env:FW_NAME    ?? 'azfw-pelab'),
  [string]$FwPolicy   = ($env:FW_POLICY  ?? 'azfwpolicy-pelab'),
  [string]$Rcg        = ($env:RCG        ?? 'pelab-app-rules'),
  [string]$HubVnet    = ($env:HUB_VNET   ?? 'vnet-hub'),
  [string]$BlobZone   = ($env:BLOB_ZONE  ?? 'privatelink.blob.core.windows.net'),
  [string]$HubDnsLink = $env:HUB_DNS_LINK,
  [string]$FwIp       = $env:FW_IP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# az/ssh do not throw in PowerShell; we check $LASTEXITCODE explicitly (and keep
# native error-action off so the tolerant `2>$null` delete below doesn't throw).
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

# ---- Prereqs / derived defaults -------------------------------------------
if (-not $ClientIp) { throw 'Set -ClientIp <client VM public IP> (or $env:CLIENT_IP) — see deploy output.' }
if (-not $FarFqdn)  { throw 'Set -FarFqdn <far storage blob FQDN> (or $env:FAR_FQDN) — see deploy output.' }
if (-not $HubDnsLink) { $HubDnsLink = "link-to-$HubVnet" }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found.' }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Not logged in. Run: az login' }

$SshOpts = if ($env:SSH_OPTS) { $env:SSH_OPTS -split '\s+' }
           else { @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10') }

if (-not $FwIp) {
  $FwIp = & az network firewall show -n $FwName -g $Rg --query "ipConfigurations[0].privateIPAddress" -o tsv 2>$null
}
if (-not $FwIp) { throw "Firewall '$FwName' not found. Deploy with the firewall (-DeployFirewall 1)." }
Write-Host "Azure Firewall private IP: $FwIp"

# ===========================================================================
Write-Rule
Write-Host '  STEP 1 — Add an Azure Firewall APPLICATION rule for the blob FQDN(s)'
Write-Rule
# Build the FQDN target list (NEAR optional).
$Fqdns = @($FarFqdn)
if ($NearFqdn) { $Fqdns += $NearFqdn }
Write-Host "Allowing FQDN(s): $($Fqdns -join ' ')"

# App rule collection lives in the rule-collection GROUP shipped empty by
# firewall.bicep. (KB section 4: app rules cause AzFW to proxy on SNI.)
Write-Host '+ az network firewall policy rule-collection-group collection add-filter-collection \'
Write-Host "    -g $Rg --policy-name $FwPolicy --rule-collection-group-name $Rcg \"
Write-Host '    --name allow-blob --collection-priority 1000 --action Allow \'
Write-Host '    --rule-name allow-blob-fqdn --rule-type ApplicationRule \'
Write-Host "    --target-fqdns $($Fqdns -join ' ') --protocols Https=443 --source-addresses '*'"
Invoke-AzNone network firewall policy rule-collection-group collection add-filter-collection `
  -g $Rg --policy-name $FwPolicy --rule-collection-group-name $Rcg `
  --name allow-blob --collection-priority 1000 --action Allow `
  --rule-name allow-blob-fqdn --rule-type ApplicationRule `
  --target-fqdns @Fqdns --protocols Https=443 --source-addresses '*' -o none
# VERIFY-IN-TEST: confirm this exact `add-filter-collection` invocation +
# parameter names on your az CLI version (it has churned across releases). If it
# errors, the equivalent is building the policy with a ruleCollectionGroups ARM
# body, or `az network firewall policy rule-collection-group collection
# add-filter-collection --help` for the current flag spelling.

Write-Host "Application rule added. Source '*' is fine for the lab; tighten in prod."
Invoke-Pause

# ===========================================================================
Write-Rule
Write-Host '  STEP 2 — The DNS-zone-link dependency (the silent-bypass trap)'
Write-Rule
Write-Host @'
AzFW app rules do their OWN DNS lookup against the firewall VNet's resolver.
If the privatelink.blob zone is NOT linked to the hub VNet, AzFW resolves the
PUBLIC storage IP — and because the storage accounts have
publicNetworkAccess=Disabled, the request fails. We prove both states by
using a DIFFERENT FQDN in each (NEAR for the missing-link case, FAR for the
re-linked case) so AzFW's per-FQDN DNS cache works WITH us instead of against
us. No 5-minute cache-expiry sleep required.
'@
if (-not $NearFqdn) { throw 'This demo needs -NearFqdn as well as -FarFqdn. Set -NearFqdn <near storage FQDN> and re-run.' }

Write-Host ''
Write-Host '2a. REMOVE the zone link to the hub (simulate the forgotten link):'
Write-Host "+ az network private-dns link vnet delete -g $Rg -z $BlobZone -n $HubDnsLink --yes"
# Tolerant delete (link may already be absent) — call az directly, ignore failure.
& az network private-dns link vnet delete -g $Rg -z $BlobZone -n $HubDnsLink --yes -o none 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  (link '$HubDnsLink' not present — continuing)" }

# Quick ARM/DNS propagation wait so the zone-link delete is visible to AzFW's
# resolver. Tens of seconds, not minutes — we are NOT waiting for cache expiry
# (the cache stays full of the prior PE IP, but we hit it with a different
# FQDN below so the cache misses and AzFW does a fresh lookup).
Write-Host "  Waiting 30s for zone-link delete to propagate to AzFW's resolver..."
Start-Sleep -Seconds 30

Write-Host ''
Write-Host '2a curl — using NEAR FQDN (AzFW has NEVER resolved this one, so cache miss):'
Write-Host "+ (on VM) curl -sv --resolve ${NearFqdn}:443:${FwIp} https://${NearFqdn}/ ..."
Invoke-OnVm "curl -s -o /dev/null -w 'HTTP %{http_code}  time_total=%{time_total}s\n' --resolve ${NearFqdn}:443:${FwIp} https://${NearFqdn}/ --max-time 15 || true"
Write-Host @'

EXPECTED while the link is MISSING: the request fails — usually a
network-level timeout or a 4xx from the storage account refusing public
traffic. AzFW just did its FIRST DNS lookup for NEAR, got the PUBLIC IP
(no hub link to the privatelink zone), opened a connection to that public
IP, and the storage refused (publicNetworkAccess=Disabled).
'@
Invoke-Pause

Write-Host ''
Write-Host '2b. RE-CREATE the zone link to the hub VNet (the fix):'
$HubVnetId = Invoke-AzOut network vnet show -n $HubVnet -g $Rg --query id -o tsv
Write-Host "+ az network private-dns link vnet create -g $Rg -z $BlobZone -n $HubDnsLink \"
Write-Host "    --virtual-network $HubVnetId --registration-enabled false"
Invoke-AzNone network private-dns link vnet create -g $Rg -z $BlobZone -n $HubDnsLink `
  --virtual-network $HubVnetId --registration-enabled false -o none

Write-Host "  Waiting 30s for zone-link create to propagate to AzFW's resolver..."
Start-Sleep -Seconds 30
Write-Host ''
Write-Host '2b curl — using FAR FQDN (AzFW has NEVER resolved this one either,'
Write-Host 'so it cache-misses, does a fresh lookup WITH the hub zone link present,'
Write-Host 'and gets the PE private IP):'
Invoke-OnVm "curl -s -o /dev/null -w 'HTTP %{http_code}  time_total=%{time_total}s\n' --resolve ${FarFqdn}:443:${FwIp} https://${FarFqdn}/ --max-time 15 || true"
Write-Host @'

EXPECTED now: HTTP 400/403/409 (an AUTH/storage-level response, NOT a network
failure) — meaning the TLS handshake completed THROUGH the firewall to the PE.
The 4xx is storage saying "no anonymous request"; the network path is good.

WHY this works without a 5-min cache-expiry sleep: 2a used the NEAR FQDN
(fresh, no cache); 2b uses the FAR FQDN (also fresh, no cache). Each curl
forces AzFW to do a NEW DNS lookup, so the link state at the moment of the
lookup is what wins. If you used the same FQDN in both, AzFW would cache
the first answer for ~5 min and the second curl would silently return the
stale cached value.
'@
Invoke-Pause

# ===========================================================================
Write-Rule
Write-Host '  STEP 3 — The impossible latency: mtr proves AzFW is the TCP endpoint'
Write-Rule
Write-Host @'
Now mtr -T -P 443 the FAR-region blob FQDN. With the firewall PROXYING on SNI,
the client's TCP/TLS terminates AT THE FIREWALL — so RTT collapses to the
~local firewall latency, NOT the ~200+ ms it took in Part A straight to the
far storage region. AzFW also does NOT decrement TTL (proxy), so it isn't even
a visible hop. That low number to a far region is physically impossible unless
something local is answering the TCP — the firewall is.
'@
Write-Host ''
Write-Host "-> FAR blob through the firewall app-rule proxy ($FarFqdn)"
Invoke-OnVm "mtr -T -P 443 -c 20 --report --no-dns $FarFqdn || true"
Write-Host @"

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
  ../cleanup.ps1 -Rg $Rg
"@
