#Requires -Version 7.0
<#
============================================================================
  Deploy the AI Foundry landing-zone lab. (PowerShell variant of deploy.sh.)
  Bicep (main.bicep + modules/) for infra; this wrapper registers providers,
  runs a region capacity pre-flight, deploys, and prints verification steps.

  SOURCE: Microsoft Learn (Apr 2026). Foundry account/project/capabilityHost
  resources are version-sensitive — see VERIFY-IN-TEST notes in the Bicep.

  Usage:
    ./deploy.ps1
    ./deploy.ps1 -Location eastus2
    $env:FOUNDRY_REGIONS='eastus westus3 swedencentral'; ./deploy.ps1
    ./deploy.ps1 -SkipRegionProbe 1 -Location eastus2     # force, no fallback
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg              = ($env:RG             ?? 'rg-ai-foundry-lz-lab'),
  [string]$Location        = ($env:LOCATION       ?? 'swedencentral'),   # Foundry + spoke VNet COLOCATED here
  [string]$AdminUser       = ($env:ADMIN_USER     ?? 'azureuser'),
  [string]$SshKey          = ($env:SSH_KEY        ?? (Join-Path $HOME '.ssh/id_rsa.pub')),
  [string]$VmSize          = ($env:VM_SIZE        ?? 'Standard_B2s'),
  [string]$ModelName       = ($env:MODEL_NAME     ?? 'gpt-4o'),
  [string]$ModelVersion    = ($env:MODEL_VERSION  ?? '2024-11-20'),
  [string]$ModelCapacity   = ($env:MODEL_CAPACITY ?? '20'),
  [string]$FoundryRegions  = $env:FOUNDRY_REGIONS,
  [string]$SkipRegionProbe = ($env:SKIP_REGION_PROBE ?? '0')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Plain functions using $args (NOT advanced) so `-o`/`-g`/`-e` pass through to az.
function Invoke-AzNone {
  & az @args; if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}
function Invoke-AzOut {
  $out = & az @args; if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }; return $out
}

$ScriptDir  = $PSScriptRoot
$DeployName = "ai-foundry-lz-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

# ---- Prereqs --------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error "Azure CLI (az) not found. Install it first."; exit 1 }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }
Write-Host "Subscription: $(Invoke-AzOut account show --query name -o tsv)"

# ---- SSH key (for the jump VM) --------------------------------------------
if (-not (Test-Path $SshKey)) {
  Write-Host "No SSH public key at $SshKey — generating a new key pair..."
  $priv = $SshKey -replace '\.pub$',''
  & ssh-keygen -t rsa -b 4096 -f $priv -N '' -q
  if ($LASTEXITCODE -ne 0) { Write-Error "ssh-keygen failed. On Windows, enable the OpenSSH Client optional feature."; exit 1 }
}
$SshKeyData = (Get-Content $SshKey -Raw).Trim()

# ---- Register resource providers (idempotent) -----------------------------
Write-Host "Registering resource providers (idempotent — can take a few minutes the first time)..."
foreach ($ns in 'Microsoft.App','Microsoft.ContainerService','Microsoft.CognitiveServices','Microsoft.Search',
                'Microsoft.Storage','Microsoft.DocumentDB','Microsoft.Network','Microsoft.KeyVault','Microsoft.MachineLearningServices') {
  Invoke-AzNone provider register --namespace $ns -o none
}

# ---- Region capacity pre-flight ------------------------------------------
if (-not $FoundryRegions) { $FoundryRegions = "$Location westus3 canadacentral northcentralus eastus2 swedencentral" }
$SubIdForProbe = Invoke-AzOut account show --query id -o tsv

function Test-Region { param([string]$R)  # returns $true if all checks pass
  $failed = ''
  # 1. gpt-4o Standard SKU availability + non-deprecated version
  $skuHit = & az cognitiveservices model list -l $R --query "[?model.name=='$ModelName' && model.version=='$ModelVersion' && contains(model.skus[].name, 'Standard')] | [0].model.version" -o tsv 2>$null
  if (-not $skuHit) { $failed += 'gpt-4o-Standard ' }
  # 2. AI Search standard SKU quota
  $searchLimit = & az rest --method get --uri "https://management.azure.com/subscriptions/$SubIdForProbe/providers/Microsoft.Search/locations/$R/usages?api-version=2024-06-01-preview" --query "value[?name.value=='standard'].limit | [0]" -o tsv 2>$null
  if ($searchLimit -notmatch '^[1-9]') { $failed += 'search-standard ' }
  # 3. (no reliable Cosmos pre-flight; surfaced by the actual deploy if it fails)
  if ($failed) { Write-Host "    [$R] FAIL: $failed"; return $false }
  Write-Host "    [$R] OK (gpt-4o Standard + AI Search quota)"
  return $true
}

if ($SkipRegionProbe -ne '1') {
  Write-Host ""
  Write-Host "Probing region capacity before Bicep submit (override with -SkipRegionProbe 1)..."
  $probeLocation = ''
  foreach ($r in ($FoundryRegions -split '\s+' | Where-Object { $_ })) {
    if (Test-Region $r) { $probeLocation = $r; break }
  }
  if (-not $probeLocation) {
    Write-Error "none of the candidate regions ($FoundryRegions) passed the pre-flight. Bump quota / try another region (set -FoundryRegions ...), or skip with -SkipRegionProbe 1."
    exit 1
  }
  if ($probeLocation -ne $Location) {
    Write-Host "  -> '$Location' did not pass; falling back to '$probeLocation'."
    $Location = $probeLocation
  } else { Write-Host "  -> using '$Location'." }
}

# ---- Resource group -------------------------------------------------------
Write-Host "Creating resource group '$Rg' in '$Location'..."
Invoke-AzNone group create -n $Rg -l $Location -o none

# ---- Deploy ---------------------------------------------------------------
Write-Host "Deploying '$DeployName' (hub + spoke + BYO data + Foundry + PEs + DNS)."
Write-Host "This is the slow lab (~15-25 min: Firewall, Bastion, capability host)..."
Invoke-AzNone deployment group create -g $Rg -n $DeployName -f (Join-Path $ScriptDir 'main.bicep') `
  -p "location=$Location" "adminUsername=$AdminUser" "adminSshPublicKey=$SshKeyData" "vmSize=$VmSize" `
     "modelName=$ModelName" "modelVersion=$ModelVersion" "modelCapacity=$ModelCapacity" -o none

# ---- Read outputs ---------------------------------------------------------
function Get-Out { param([string]$Name) Invoke-AzOut deployment group show -g $Rg -n $DeployName --query "properties.outputs.$Name.value" -o tsv }
$BastionName = Get-Out bastionName
$JumpVm      = Get-Out jumpVmName
$FoundryAcct = Get-Out foundryAccountName
$FoundryProj = Get-Out foundryProjectName
$AzfwIp      = Get-Out firewallPrivateIp
$CogFqdn     = Get-Out foundryCognitiveFqdn
$OaiFqdn     = Get-Out foundryOpenAiFqdn
$SearchFqdn  = Get-Out searchFqdn
$BlobFqdn    = Get-Out blobFqdn
$CosmosFqdn  = Get-Out cosmosFqdn

Write-Host @"

============================================================
  AI Foundry landing-zone deployed.
============================================================
  Resource group         : $Rg  ($Location)
  Foundry account        : $FoundryAcct   (public access: Disabled)
  Foundry project        : $FoundryProj
  Hub firewall private IP : $AzfwIp   (the single egress chokepoint, NO TLS inspection)
  Bastion                : $BastionName
  Jump VM                : $JumpVm   (no public IP — reach it via Bastion)

  1) GET INSIDE THE VNET — connect to the jump box via Bastion:
       az network bastion ssh --name $BastionName --resource-group $Rg --target-resource-id `$(az vm show -g $Rg -n $JumpVm --query id -o tsv) --auth-type ssh-key --username $AdminUser --ssh-key $SshKey

  2) PROVE PRIVATE DNS (run ON the jump box — every name should be 192.168.1.x):
       check-private-dns.sh $CogFqdn $OaiFqdn $SearchFqdn $BlobFqdn $CosmosFqdn
     Then run the SAME nslookups from your laptop (outside) — they fail. That
     gap IS the private landing zone.

  3) RUN AN AGENT END-TO-END (on the jump box, inside the venv):
       /opt/agentvenv/bin/python run-agent.py "https://$FoundryAcct.services.ai.azure.com/api/projects/$FoundryProj"
     (Confirm the exact project endpoint in the Foundry portal — Project > Overview.)

  4) INSPECT EGRESS — tour the Azure Firewall logs to see only the allowlisted
     AAD / Container Apps FQDNs leaving, with NO TLS inspection.

  Tear down when done (PURGES Foundry BEFORE the VNet — required):
       ./cleanup.ps1 -Rg $Rg
============================================================
"@
