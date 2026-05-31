#Requires -Version 7.0
<#
============================================================================
  Tear down the AI Foundry landing-zone lab — IN THE CORRECT ORDER.
  (PowerShell variant of cleanup.sh.)

  *** THE ORDER MATTERS. ***
  The Standard Agent places a service-association-link (SAL) on the delegated
  agent subnet (Microsoft.App/environments). While the Foundry resource exists —
  including in its SOFT-DELETED state — that SAL blocks deletion of the subnet
  and therefore the spoke VNet. So this script:
    1. deletes the Foundry account (soft delete)
    2. PURGES it (releases the SAL)
    3. only THEN deletes the resource group (VNet, firewall, PEs, data, etc.)

  Usage:
    ./cleanup.ps1 -Rg rg-ai-foundry-lz-lab   # prompts for confirmation
    ./cleanup.ps1 -Confirm1 1                # no prompt (scripted)
    $env:CONFIRM='1'; ./cleanup.ps1
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg       = ($env:RG      ?? 'rg-ai-foundry-lz-lab'),
  [string]$Confirm1 = ($env:CONFIRM ?? '')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error "Azure CLI (az) not found."; exit 1 }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }

& az group show -n $Rg 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "Resource group '$Rg' does not exist — nothing to delete."; exit 0 }

Write-Host "This will DELETE + PURGE the Foundry resource, then delete resource group: $Rg"
& az resource list -g $Rg --query "[].{name:name, type:type}" -o table

if ($Confirm1 -ne '1') {
  $answer = Read-Host "Type the resource group name to confirm teardown"
  if ($answer -ne $Rg) { Write-Host "Name mismatch. Aborting."; exit 1 }
}

# ---- 1) Find the Foundry (Cognitive Services AIServices) account(s) -------
Write-Host "Locating Foundry account(s) in '$Rg'..."
$foundryAccts = @(& az cognitiveservices account list -g $Rg --query "[?kind=='AIServices'].name" -o tsv 2>$null | Where-Object { $_ })
if ($foundryAccts.Count -eq 0) { Write-Host "  (no AIServices account found — maybe already removed; continuing to RG delete.)" }

# ---- 2) Delete + PURGE each Foundry account (releases the subnet SAL) ------
foreach ($acct in $foundryAccts) {
  if (-not $acct) { continue }
  $loc = & az cognitiveservices account show -g $Rg -n $acct --query location -o tsv 2>$null
  Write-Host "Deleting Foundry account '$acct' (soft delete)..."
  & az cognitiveservices account delete -g $Rg -n $acct -o none 2>$null

  Write-Host "Purging Foundry account '$acct' (removes the soft-deleted copy + its subnet SAL)..."
  for ($a=1; $a -le 6; $a++) {
    & az cognitiveservices account purge -g $Rg -n $acct -l $loc -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  purged '$acct'."; break }
    Write-Host "  (not purgeable yet — retrying in 15s, attempt $a/6)"
    Start-Sleep 15
  }
}

# Safety net: purge any lingering soft-deleted AIServices account referencing this lab.
Write-Host "Checking for any lingering soft-deleted Foundry accounts to purge..."
$deleted = @(& az cognitiveservices account list-deleted --query "[?contains(name, 'foundry')].{name:name, location:location, rg:resourceGroup}" -o tsv 2>$null | Where-Object { $_ })
foreach ($row in $deleted) {
  $p = $row -split "`t"
  if (-not $p[0]) { continue }
  Write-Host "  purging soft-deleted '$($p[0])' ($($p[1]))..."
  & az cognitiveservices account purge -g $p[2] -n $p[0] -l $p[1] -o none 2>$null
}

# ---- 3) NOW delete the resource group (VNet, firewall, PEs, data, etc.) ----
Write-Host "Deleting resource group '$Rg' (the SAL is released, so the spoke VNet can go)..."
& az group delete -n $Rg --yes --no-wait
if ($LASTEXITCODE -ne 0) { throw "az group delete failed (exit $LASTEXITCODE)" }
Write-Host "Delete started (background). Verify later with: az group show -n $Rg"
Write-Host ""
Write-Host "If the RG delete ever hangs on the spoke VNet, re-run this script — step 2 (purge)"
Write-Host "is the fix for the Microsoft.App/environments service-association-link."
