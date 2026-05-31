#Requires -Version 7.0
<#
============================================================================
  Tear down the APIM AI-gateway module. (PowerShell variant of cleanup-apim.sh.)

  Deleting the RG removes APIM, both Azure OpenAI accounts, the PEs, the private
  DNS zone, and the APIM VNet. Then we PURGE the soft-deleted APIM + OpenAI so
  tomorrow's redeploy doesn't collide with 'ServiceAlreadyExistsInSoftDeletedState'.

  >>> CAVEAT: an APIM Developer-SKU instance is NON-DELETABLE for ~30-45 minutes
  >>> after create. If you just deployed, the RG delete will hang on APIM until
  >>> that window passes.

  Usage:
    ./cleanup-apim.ps1 -Rg rg-apim-ai-gw-lab   # prompts for confirmation
    ./cleanup-apim.ps1 -Confirm1 1             # no prompt (scripted)
    $env:CONFIRM='1'; ./cleanup-apim.ps1
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg       = ($env:RG      ?? 'rg-apim-ai-gw-lab'),
  [string]$Confirm1 = ($env:CONFIRM ?? '0')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }

if ($Confirm1 -ne '1') {
  $ans = Read-Host "Delete resource group '$Rg' and EVERYTHING in it (APIM, OpenAI, PEs, DNS, VNet)? [y/N]"
  if ($ans -notmatch '^[Yy]$') { Write-Host "Aborted."; exit 0 }
}

# Capture APIM + OpenAI names/locations BEFORE deleting (needed for purge).
$ApimName = & az apim list -g $Rg --query "[0].name" -o tsv 2>$null
$ApimLoc  = if ($ApimName) { & az apim show -g $Rg -n $ApimName --query "location" -o tsv 2>$null } else { '' }
$oaiEntries = @()
$rows = @(& az cognitiveservices account list -g $Rg --query "[?kind=='OpenAI'].[name, location]" -o tsv 2>$null | Where-Object { $_ })
foreach ($row in $rows) {
  $parts = $row -split "`t"
  if ($parts[0]) { $oaiEntries += ,@($parts[0], $parts[1]) }
}

Write-Host "Deleting resource group '$Rg'..."
Write-Host "NOTE: if APIM was created < ~45 min ago, this delete will block on it until the lock lifts."
& az group delete -n $Rg --yes --no-wait
if ($LASTEXITCODE -ne 0) { throw "az group delete failed (exit $LASTEXITCODE)" }
Write-Host "Delete started (running in the background). APIM, both OpenAI accounts, PEs, DNS and the VNet all go with it."

function Remove-DeletedApim { param([string]$Name,[string]$Loc)
  for ($a=1; $a -le 6; $a++) {
    & az apim deletedservice purge --service-name $Name --location $Loc -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  purged APIM '$Name'"; return }
    Start-Sleep 15
  }
  Write-Warning "could not purge APIM '$Name' after retries — purge manually later."
}
function Remove-DeletedOpenAi { param([string]$Name,[string]$Loc)
  for ($a=1; $a -le 6; $a++) {
    & az cognitiveservices account purge --name $Name --location $Loc --resource-group $Rg -o none 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  purged OpenAI '$Name'"; return }
    Start-Sleep 15
  }
  Write-Warning "could not purge OpenAI '$Name' after retries — purge manually later."
}

if ($ApimName -and $ApimLoc) {
  Write-Host "Purging soft-deleted APIM '$ApimName' in $ApimLoc..."
  Remove-DeletedApim $ApimName $ApimLoc
}
foreach ($e in $oaiEntries) {
  if (-not $e[0] -or -not $e[1]) { continue }
  Write-Host "Purging soft-deleted OpenAI '$($e[0])' in $($e[1])..."
  Remove-DeletedOpenAi $e[0] $e[1]
}
Write-Host "Purge attempts complete. Verify with: az apim deletedservice list  /  az cognitiveservices account list-deleted"
