#Requires -Version 7.0
<#
============================================================================
  Deploy the Private Endpoint latency lab. (PowerShell variant of deploy.sh.)
  Bicep (main.bicep) for infra + this thin az-CLI wrapper for orchestration.

  Usage:
    ./deploy.ps1

  Override anything via -Parameters OR the same env vars as deploy.sh, e.g.:
    ./deploy.ps1 -Location southeastasia -FarLocation westeurope
    $env:LOCATION='southeastasia'; ./deploy.ps1

  Parts B & C (routing + firewall) need the hub + Azure Firewall. Opt in with:
    ./deploy.ps1 -DeployFirewall 1
  Leave it unset for the cheap Part-A-only latency reveal (no AzFW billing).
============================================================================
#>
[CmdletBinding()]
param(
  # TOPOLOGY:
  #   simple       (default) — main.bicep — both PEs LOCAL to client; far storage slow.
  #                            Supports Parts B & C (firewall) via -DeployFirewall 1.
  #   cross-region            — main-cross-region.bicep — both PEs in the REMOTE region,
  #                            storage in BOTH regions. Part A ONLY (no firewall, no Parts B/C).
  [string]$Topology        = ($env:TOPOLOGY        ?? 'simple'),
  [string]$Rg              = ($env:RG              ?? 'rg-pe-latency-lab'),
  [string]$Location        = ($env:LOCATION        ?? 'australiaeast'),         # "near" region
  [string]$FarLocation     = ($env:FAR_LOCATION    ?? 'germanywestcentral'),    # "far" storage region
  [string]$VmSize          = ($env:VM_SIZE         ?? 'Standard_B1s'),
  [string]$AdminUser       = ($env:ADMIN_USER      ?? 'azureuser'),
  [string]$SshKey          = ($env:SSH_KEY         ?? (Join-Path $HOME '.ssh/id_rsa.pub')),
  [string]$DeployFirewall  = ($env:DEPLOY_FIREWALL ?? '0'),                      # 1 = add hub + Azure Firewall for Parts B & C
  [string]$FirewallTier    = ($env:FIREWALL_TIER   ?? 'Standard'),              # Standard | Premium
  [string]$AllowedCidr     = $env:ALLOWED_CIDR
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Helpers --------------------------------------------------------------
# az does not throw in PowerShell; check $LASTEXITCODE after every call.
# NOTE: plain functions using the automatic $args. A param() with [Parameter()]
# would make these ADVANCED functions (auto common params), and then `-o` binds
# ambiguously to -OutVariable/-OutBuffer instead of passing through to az.
function Invoke-AzNone {
  & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}
function Invoke-AzOut {
  $out = & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
  return $out
}

$TopologyLc = $Topology.ToLowerInvariant()
$ScriptDir  = $PSScriptRoot
$DeployName = "pe-latency-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

# cross-region topology does NOT support Parts B/C — refuse the combination clearly.
if ($TopologyLc -eq 'cross-region' -and $DeployFirewall -ne '0') {
  Write-Error "TOPOLOGY=cross-region does not support -DeployFirewall 1 (Parts B/C are tied to the simple topology). Run the simple topology for routes/firewall demos."
  exit 1
}

# Normalize DeployFirewall (1/true/yes/on -> true) for the Bicep bool param.
$BicepDeployFw = switch ($DeployFirewall.ToLowerInvariant()) {
  { $_ -in '1','true','yes','on' } { 'true'; break }
  default                          { 'false' }
}

# ---- Prereqs --------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  Write-Error "Azure CLI (az) not found. Install it first."; exit 1
}
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }

Write-Host "Subscription: $(Invoke-AzOut account show --query name -o tsv)"

# ---- SSH key --------------------------------------------------------------
if (-not (Test-Path $SshKey)) {
  Write-Host "No SSH public key at $SshKey — generating a new key pair..."
  $priv = $SshKey -replace '\.pub$',''
  & ssh-keygen -t rsa -b 4096 -f $priv -N '' -q
  if ($LASTEXITCODE -ne 0) { Write-Error "ssh-keygen failed. On Windows, enable the OpenSSH Client optional feature."; exit 1 }
  Write-Host "  -> Created $priv (private) + $SshKey (public)"
}
$SshKeyData = (Get-Content $SshKey -Raw).Trim()

# ---- Detect deployer public IP for the SSH NSG rule ----------------------
if (-not $AllowedCidr) {
  $myip = $null
  foreach ($u in 'https://api.ipify.org','https://ifconfig.me/ip') {
    try { $myip = (Invoke-RestMethod -Uri $u -TimeoutSec 10).ToString().Trim(); if ($myip) { break } } catch {}
  }
  if (-not $myip) { Write-Error "Could not detect your public IP. Set -AllowedCidr x.x.x.x/32 and re-run."; exit 1 }
  $AllowedCidr = "$myip/32"
}
Write-Host "Locking inbound SSH to: $AllowedCidr"

# ---- Resource group -------------------------------------------------------
Write-Host "Creating resource group '$Rg' in '$Location'..."
Invoke-AzNone group create -n $Rg -l $Location -o none

# ---- Deploy ---------------------------------------------------------------
if ($TopologyLc -eq 'cross-region') {
  Write-Host "Deploying lab '$DeployName' — TOPOLOGY=cross-region."
  Write-Host "  Client in $Location; BOTH PE NICs in $FarLocation."
  Invoke-AzNone deployment group create -g $Rg -n $DeployName -f (Join-Path $ScriptDir 'main-cross-region.bicep') `
    -p "clientLocation=$Location" "peLocation=$FarLocation" "adminUsername=$AdminUser" `
       "adminSshPublicKey=$SshKeyData" "allowedSshSourceCidr=$AllowedCidr" "vmSize=$VmSize" -o none
}
else {
  if ($BicepDeployFw -eq 'true') {
    Write-Host "Deploying lab '$DeployName' WITH hub + Azure Firewall ($FirewallTier)."
    Write-Host "  (AzFW provisioning adds ~5-10 min and ~`$1.25/hr — Parts B & C enabled.)"
  } else {
    Write-Host "Deploying lab '$DeployName' (Part A only; a few minutes; VPN-free design keeps this short)."
    Write-Host "  (Re-run with -DeployFirewall 1 to add the hub + firewall for Parts B & C.)"
  }
  Invoke-AzNone deployment group create -g $Rg -n $DeployName -f (Join-Path $ScriptDir 'main.bicep') `
    -p "location=$Location" "farLocation=$FarLocation" "adminUsername=$AdminUser" `
       "adminSshPublicKey=$SshKeyData" "allowedSshSourceCidr=$AllowedCidr" "vmSize=$VmSize" `
       "deployFirewall=$BicepDeployFw" "firewallTier=$FirewallTier" -o none
}

# ---- Read outputs ---------------------------------------------------------
function Get-Out { param([string]$Name)
  Invoke-AzOut deployment group show -g $Rg -n $DeployName --query "properties.outputs.$Name.value" -o tsv
}
$ClientIp  = Get-Out clientPublicIp
$NearFqdn  = Get-Out nearStorageBlobFqdn
$FarFqdn   = Get-Out farStorageBlobFqdn
$NearRegion = Get-Out nearRegion
$FarRegion  = Get-Out farRegion

Write-Host @"

============================================================
  Lab deployed.
  (cloud-init may need ~2 min more to finish installing mtr.)
============================================================
  Client VM public IP       : $ClientIp
  NEAR storage ($NearRegion) : $NearFqdn
  FAR  storage ($FarRegion) : $FarFqdn
"@

if ($TopologyLc -eq 'cross-region') {
  $PeRegion = Get-Out peRegion
  Write-Host "  PE NIC region             : $PeRegion  <-- BOTH PE NICs live HERE (cross-region topology)"
}

Write-Host @"

  PART A — run the latency reveal:
    ssh $AdminUser@$ClientIp 'sudo lab-on-vm.sh $NearFqdn $FarFqdn'
"@

if ($TopologyLc -eq 'cross-region') {
  Write-Host @"

  Cross-region reveal: BOTH FQDNs resolve to a $($PeRegion) PE NIC IP, yet:
    NEAR ($NearRegion storage) should answer in SINGLE-DIGIT ms.
    FAR  ($FarRegion storage) should answer in ~200+ ms (PE-local, but the
      backend is genuinely $FarRegion away from the client).
  The PE never carries data — it just hands the client an /32 + DNS record.
"@
}

if ($BicepDeployFw -eq 'true') {
  $FwIp = Get-Out firewallPrivateIp
  Write-Host @"

  PART B — your routes might be lying (run from this machine):
    $ScriptDir/scripts/part-b-routes.ps1 -Rg $Rg -ClientIp $ClientIp -AdminUser $AdminUser
    # (or the bash driver: bash $ScriptDir/scripts/part-b-routes.sh)

  PART C — the firewall is a proxy (run from this machine):
    $ScriptDir/scripts/part-c-firewall.ps1 -Rg $Rg -ClientIp $ClientIp -AdminUser $AdminUser ``
      -FarFqdn $FarFqdn -NearFqdn $NearFqdn
    # (or the bash driver: bash $ScriptDir/scripts/part-c-firewall.sh)

  Azure Firewall private IP : $FwIp
"@
} else {
  Write-Host "`n  (Parts B & C need the firewall — re-deploy with -DeployFirewall 1.)"
}

Write-Host @"

  Tear down when done (deletes the WHOLE RG, firewall included):
    ./cleanup.ps1 -Rg $Rg
============================================================
"@
