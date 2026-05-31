#Requires -Version 7.0
<#
============================================================================
  Deploy the APIM "AI gateway" module (Track A continuation of the AGC lab).
  PowerShell variant of deploy-apim.sh.

  RUN ORDER (the whole point): APIM Developer SKU takes ~30-45 MINUTES — longer
  than this module. So we kick APIM off ASYNC (--no-wait), build the fast stuff
  (OpenAI + PEs + DNS) while it bakes, then wait for APIM and finish wiring.

  >>> Start this at t=0, right after you launch ../deploy.ps1.

  Usage:
    ./deploy-apim.ps1
    ./deploy-apim.ps1 -Location westeurope
    ./deploy-apim.ps1 -PeerAksVnet 1 -AksRg rg-agc-convergence-lab
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg                      = ($env:RG                        ?? 'rg-apim-ai-gw-lab'),
  [string]$Location                = ($env:LOCATION                  ?? 'northeurope'),
  [string]$OpenAiPrimaryLocation   = ($env:OPENAI_PRIMARY_LOCATION   ?? 'swedencentral'),
  [string]$OpenAiSecondaryLocation = ($env:OPENAI_SECONDARY_LOCATION ?? 'eastus2'),
  [string]$PublisherEmail          = ($env:PUBLISHER_EMAIL           ?? 'admin@contoso.com'),
  [string]$PublisherName           = ($env:PUBLISHER_NAME            ?? 'Experts Live Masterclass'),
  [string]$ModelName               = ($env:MODEL_NAME                ?? 'gpt-4o'),
  [string]$ModelVersion            = ($env:MODEL_VERSION             ?? '2024-11-20'),
  [string]$PeerAksVnet             = ($env:PEER_AKS_VNET             ?? '0'),
  [string]$AksRg                   = ($env:AKS_RG                    ?? 'rg-agc-convergence-lab'),
  [string]$AksName                 = ($env:AKS_NAME                  ?? 'aks-agc-lab'),
  [string]$OpenAiApiVersion        = ($env:OPENAI_API_VERSION        ?? '2024-10-21')
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
function New-JsonFile { param([string]$Json)  # write JSON body to a temp file for `az rest --body @file`
  $f = New-TemporaryFile
  Set-Content -Path $f -Value $Json -Encoding utf8
  return $f.FullName
}

$ScriptDir  = $PSScriptRoot
$PolicyDir  = Join-Path $ScriptDir 'policies'
$DeployName = "apim-ai-gw-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$RoleOpenAiUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'   # Cognitive Services OpenAI User

# ---- Prereqs --------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error "Azure CLI (az) not found."; exit 1 }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }
Write-Host "Subscription: $(Invoke-AzOut account show --query name -o tsv)"
$SubId = Invoke-AzOut account show --query id -o tsv

# ---- Register providers ---------------------------------------------------
Write-Host "Registering resource providers (idempotent)..."
foreach ($ns in 'Microsoft.ApiManagement','Microsoft.CognitiveServices','Microsoft.Network') {
  Invoke-AzNone provider register --namespace $ns -o none
}

# ---- Resource group -------------------------------------------------------
Write-Host "Creating resource group '$Rg' in '$Location'..."
Invoke-AzNone group create -n $Rg -l $Location -o none

# ---- STEP 1: launch the Bicep ASYNC (APIM is the long pole) ---------------
Write-Host ""
Write-Host ">>> STEP 1: launching the Bicep deployment ASYNC (APIM is the long pole, ~30-45 min)..."
Invoke-AzNone deployment group create -g $Rg -n $DeployName -f (Join-Path $ScriptDir 'main.bicep') `
  -p "location=$Location" "openAiPrimaryLocation=$OpenAiPrimaryLocation" "openAiSecondaryLocation=$OpenAiSecondaryLocation" `
     "publisherEmail=$PublisherEmail" "publisherName=$PublisherName" "modelName=$ModelName" "modelVersion=$ModelVersion" `
  --no-wait -o none
Write-Host "    Deployment '$DeployName' submitted. APIM is now provisioning in the background."

function Get-Out { param([string]$Name)
  $v = & az deployment group show -g $Rg -n $DeployName --query "properties.outputs.$Name.value" -o tsv 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $v) { return '' }
  return $v
}

# ---- STEP 2: wait for OpenAI accounts + PEs (the fast part) ---------------
Write-Host ""
Write-Host ">>> STEP 2: waiting for the Azure OpenAI accounts + Private Endpoints (the fast part)..."
$OaiPrimary = ''; $OaiSecondary = ''; $VnetName = ''; $DnsZone = ''
for ($i=1; $i -le 60; $i++) {
  $OaiPrimary   = Get-Out openAiPrimaryName
  $OaiSecondary = Get-Out openAiSecondaryName
  $VnetName     = Get-Out vnetName
  $DnsZone      = Get-Out privateDnsZoneName
  if ($OaiPrimary -and $OaiSecondary) { break }
  $names = @(& az cognitiveservices account list -g $Rg --query "[?kind=='OpenAI'].name" -o tsv 2>$null | Where-Object { $_ })
  if ($names.Count -gt 0) {
    if ($names[0]) { $OaiPrimary = $names[0] }
    if ($names.Count -gt 1 -and $names[1]) { $OaiSecondary = $names[1] }
    if ($OaiPrimary -and $OaiSecondary) { break }
  }
  Write-Host "    ...still creating OpenAI accounts (attempt $i/60); sleeping 15s"
  Start-Sleep 15
}
if (-not $OaiPrimary -or -not $OaiSecondary) {
  Write-Warning "Could not yet confirm both OpenAI accounts. Check: az deployment group show -g $Rg -n $DeployName --query properties.provisioningState"
} else {
  Write-Host "    OpenAI primary  : $OaiPrimary ($OpenAiPrimaryLocation)"
  Write-Host "    OpenAI secondary: $OaiSecondary ($OpenAiSecondaryLocation)"
}

# ---- STEP 3: private-DNS reveal you can do BEFORE APIM is ready ------------
Write-Host ""
Write-Host ">>> STEP 3: private DNS check — OpenAI should resolve to a PE private IP."
if ($OaiPrimary) {
  Write-Host "    Manual check from a host that can see the private zone:"
  Write-Host "      nslookup $OaiPrimary.openai.azure.com"
  Write-Host "    Expect an answer in 10.226.0.x (the PE), NOT a public IP."
  if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    & kubectl version --request-timeout=5s 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "    Trying the lookup from inside the AKS cluster (needs VNet peering + DNS reachability)..."
      & kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 --request-timeout=60s -- nslookup "$OaiPrimary.openai.azure.com" 2>$null
      if ($LASTEXITCODE -ne 0) { Write-Host "    (cluster lookup skipped/failed — peer the VNets and ensure the cluster uses a resolver that sees the private zone)" }
    }
  }
}

# ---- STEP 4 (OPTIONAL): peer the APIM VNet to the AKS-managed VNet ---------
if ($PeerAksVnet -eq '1' -and $VnetName) {
  Write-Host ""
  Write-Host ">>> STEP 4: peering APIM VNet '$VnetName' to the AKS-managed VNet..."
  $McRg = & az aks show -g $AksRg -n $AksName --query nodeResourceGroup -o tsv 2>$null
  if ($McRg) {
    $AksVnetName = & az network vnet list -g $McRg --query '[0].name' -o tsv 2>$null
    if ($AksVnetName) {
      $ApimVnetId = Invoke-AzOut network vnet show -g $Rg -n $VnetName --query id -o tsv
      $AksVnetId  = Invoke-AzOut network vnet show -g $McRg -n $AksVnetName --query id -o tsv
      Invoke-AzNone network vnet peering create -g $Rg -n apim-to-aks --vnet-name $VnetName --remote-vnet $AksVnetId --allow-vnet-access -o none
      Invoke-AzNone network vnet peering create -g $McRg -n aks-to-apim --vnet-name $AksVnetName --remote-vnet $ApimVnetId --allow-vnet-access -o none
      if ($DnsZone) {
        & az network private-dns link vnet create -g $Rg -z $DnsZone -n aks-vnet-link -v $AksVnetId -e false -o none 2>$null
      }
      Write-Host "    Peering + DNS link done."
    } else { Write-Warning "could not find the AKS-managed VNet in $McRg — skipping peering." }
  } else { Write-Warning "could not find AKS '$AksName' in '$AksRg' — skipping peering." }
}

# ---- STEP 5: WAIT for APIM (the long pole) --------------------------------
Write-Host ""
Write-Host ">>> STEP 5: waiting for APIM to finish provisioning (~30-45 min total from t=0)..."
Write-Host "    Go run the AGC blue/green zero-drop reveal now — come back when this clears."
$ApimName = ''
for ($i=1; $i -le 180; $i++) {
  $ApimName = Get-Out apimName
  if (-not $ApimName) { $ApimName = (& az apim list -g $Rg --query '[0].name' -o tsv 2>$null) }
  if ($ApimName) {
    $state = & az apim show -g $Rg -n $ApimName --query provisioningState -o tsv 2>$null
    Write-Host "    APIM '$ApimName' provisioningState=$state (poll $i)"
    if ($state -eq 'Succeeded') { break }
    if ($state -eq 'Failed') { Write-Error "APIM provisioning failed."; exit 1 }
  } else {
    Write-Host "    APIM resource not visible yet (poll $i)..."
  }
  Start-Sleep 20
}
if (-not $ApimName) { Write-Error "APIM never became visible. Check: az deployment group show -g $Rg -n $DeployName"; exit 1 }

Write-Host "    Confirming the Bicep deployment as a whole reached 'Succeeded'..."
for ($i=1; $i -le 30; $i++) {
  $dstate = & az deployment group show -g $Rg -n $DeployName --query properties.provisioningState -o tsv 2>$null
  if ($dstate -eq 'Succeeded') { break }
  if ($dstate -eq 'Failed') { Write-Error "Bicep deployment failed — see portal."; exit 1 }
  Start-Sleep 20
}

# Refresh outputs now that the deployment is done.
$ApimName       = Get-Out apimName
$ApimGw         = Get-Out apimGatewayUrl
$ApimPrincipal  = Get-Out apimPrincipalId
$OaiPrimary     = Get-Out openAiPrimaryName
$OaiSecondary   = Get-Out openAiSecondaryName
$OaiPrimaryId   = Get-Out openAiPrimaryId
$OaiSecondaryId = Get-Out openAiSecondaryId
$ApiName        = Get-Out apiName
$ModelDeploy    = Get-Out modelDeploymentName

# ---- STEP 6: grant APIM identity OpenAI User on both accounts -------------
Write-Host ""
Write-Host ">>> STEP 6: granting APIM identity 'Cognitive Services OpenAI User' on both accounts..."
function Grant-OpenAiUser { param([string]$Scope)
  for ($a=1; $a -le 6; $a++) {
    & az role assignment create --assignee-object-id $ApimPrincipal --assignee-principal-type ServicePrincipal --scope $Scope --role $RoleOpenAiUser -o none 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    Write-Host "     (identity not replicated yet — retrying in 15s, attempt $a/6)"
    Start-Sleep 15
  }
  Write-Warning "could not assign OpenAI User on $Scope after retries — assign it manually."
}
if ($OaiPrimaryId)   { Grant-OpenAiUser $OaiPrimaryId }
if ($OaiSecondaryId) { Grant-OpenAiUser $OaiSecondaryId }

# ---- STEP 6b: IP-allowlist APIM's outbound IPs on both OpenAI accounts -----
Write-Host ""
Write-Host ">>> STEP 6b: allowlisting APIM's outbound IPs on both OpenAI accounts..."
$apimIps = @((& az apim show -g $Rg -n $ApimName --query "publicIpAddresses[]" -o tsv 2>$null) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Write-Host "    APIM outbound IPs:"; $apimIps | ForEach-Object { Write-Host "      $_" }
if ($apimIps.Count -eq 0) {
  Write-Warning "could not read APIM publicIpAddresses — leaving OpenAI ACLs default-deny. Smoke test will fail until you add APIM IPs manually."
} else {
  # Build the ipRules JSON as a string (guarantees array form regardless of count).
  $rulesJson = ($apimIps | ForEach-Object { '{"value":"' + $_ + '"}' }) -join ','
  $bodyJson  = '{"properties":{"publicNetworkAccess":"Enabled","networkAcls":{"defaultAction":"Deny","ipRules":[' + $rulesJson + '],"virtualNetworkRules":[]}}}'
  foreach ($acct in @($OaiPrimary,$OaiSecondary)) {
    if (-not $acct) { continue }
    Write-Host "    PATCH $acct -> networkAcls.ipRules"
    $bf = New-JsonFile $bodyJson
    try {
      # Brace ${acct}: a bare $acct? would parse the '?' into the variable name and throw.
      & az rest --method patch --uri "https://management.azure.com/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.CognitiveServices/accounts/${acct}?api-version=2024-10-01" --body "@$bf" -o none
      if ($LASTEXITCODE -ne 0) { Write-Warning "PATCH failed on $acct" }
    } finally { Remove-Item $bf -Force -ErrorAction SilentlyContinue }
  }
  Write-Host "    Waiting 60s for the ACL change to propagate before the smoke test..."
  Start-Sleep 60
}

# ---- STEP 7: import the Azure OpenAI REST API into the APIM API shell ------
Write-Host ""
Write-Host ">>> STEP 7: importing the Azure OpenAI OpenAPI spec into API '$ApiName'..."
$SpecUrl = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/$OpenAiApiVersion/inference.json"
& az apim api import -g $Rg --service-name $ApimName --api-id $ApiName --path openai --specification-format OpenApi --specification-url $SpecUrl -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "    WARNING: spec import via URL failed — VERIFY-IN-TEST: download inference.json for OPENAI_API_VERSION=$OpenAiApiVersion and import with --specification-path."
}

# A subscription key so attendees can call the gateway (az apim subscription was
# removed from the CLI — go straight to ARM REST: PUT creates, listSecrets returns key).
Write-Host "    Creating a demo subscription key ('ai-gw-demo') scoped to all APIs..."
$ApimSubBase   = "https://management.azure.com/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.ApiManagement/service/$ApimName"
$ApimApiVer    = '2022-08-01'
$ApimScope     = "/subscriptions/$SubId/resourceGroups/$Rg/providers/Microsoft.ApiManagement/service/$ApimName/apis"
$subBodyJson   = '{"properties":{"scope":"' + $ApimScope + '","displayName":"AI GW demo key"}}'
$sbf = New-JsonFile $subBodyJson
try {
  & az rest --method put --uri "$ApimSubBase/subscriptions/ai-gw-demo?api-version=$ApimApiVer" --body "@$sbf" -o none 2>$null
} finally { Remove-Item $sbf -Force -ErrorAction SilentlyContinue }
$SubKey = & az rest --method post --uri "$ApimSubBase/subscriptions/ai-gw-demo/listSecrets?api-version=$ApimApiVer" --query primaryKey -o tsv 2>$null
if (-not $SubKey) { $SubKey = '<create-in-portal>' }

$gwUrl = if ($ApimGw) { $ApimGw } else { "https://$ApimName.azure-api.net" }
Write-Host @"

============================================================
  APIM AI-gateway module deployed.
============================================================
  APIM name        : $ApimName
  Gateway URL      : $gwUrl
  OpenAI primary   : $OaiPrimary   ($OpenAiPrimaryLocation)
  OpenAI secondary : $OaiSecondary ($OpenAiSecondaryLocation)
  Model deployment : $ModelDeploy
  Demo sub key     : $SubKey

  Smoke test (no policy yet) — should return a completion:
    curl -s "$gwUrl/openai/deployments/$ModelDeploy/chat/completions?api-version=$OpenAiApiVersion" -H "Ocp-Apim-Subscription-Key: $SubKey" -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"Say hi in 3 words"}]}'

    # NOTE: APIM's default subscription-key header on this API is
    # 'Ocp-Apim-Subscription-Key'. The native Azure OpenAI client uses 'api-key' —
    # add 'api-key' as a subscription header in the Portal if you want SDK code to work unchanged.

  APPLY THE FOUR POLICIES ONE AT A TIME (re-run after editing each XML):

    # 1) Token rate-limit (watch the 3rd call get 429 + Retry-After)
    az apim api policy create -g $Rg --service-name $ApimName --api-id $ApiName --xml-path "$PolicyDir/token-rate-limit.xml"

    # 2) Semantic cache (reword a prompt -> instant, ~0 tokens) — PREREQ: external Redis + embeddings backend (see README)
    az apim api policy create -g $Rg --service-name $ApimName --api-id $ApiName --xml-path "$PolicyDir/semantic-cache.xml"

    # 3) Weighted load-balance across both backends (watch the split move)
    az apim api policy create -g $Rg --service-name $ApimName --api-id $ApiName --xml-path "$PolicyDir/load-balance.xml"

    # 4) Circuit breaker — fail one backend, watch APIM serve 100% from the survivor
    az apim api policy create -g $Rg --service-name $ApimName --api-id $ApiName --xml-path "$PolicyDir/circuit-breaker.xml"

  Tear everything down when done (APIM Dev SKU is non-deletable for ~30-45 min after create):
    ./cleanup-apim.ps1 -Rg $Rg
============================================================
"@
