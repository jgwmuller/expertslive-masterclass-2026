#Requires -Version 7.0
<#
============================================================================
  Tear down the Private Endpoint latency lab. (PowerShell variant of cleanup.sh.)
  Deletes the entire resource group so nothing keeps billing.

  Usage:
    ./cleanup.ps1                    # prompts for confirmation
    ./cleanup.ps1 -Rg rg-pe-latency-lab
    ./cleanup.ps1 -Confirm1 1        # skip the prompt (for scripted teardown)
    $env:CONFIRM='1'; ./cleanup.ps1  # env-var equivalent
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg       = ($env:RG      ?? 'rg-pe-latency-lab'),
  [string]$Confirm1 = ($env:CONFIRM ?? '')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error "Azure CLI (az) not found."; exit 1 }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }

& az group show -n $Rg 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Resource group '$Rg' does not exist — nothing to delete."
  exit 0
}

Write-Host "This will DELETE resource group: $Rg"
& az resource list -g $Rg --query "[].{name:name, type:type}" -o table

if ($Confirm1 -ne '1') {
  $answer = Read-Host "Type the resource group name to confirm deletion"
  if ($answer -ne $Rg) { Write-Host "Name mismatch. Aborting."; exit 1 }
}

Write-Host "Deleting '$Rg' (running in the background)..."
& az group delete -n $Rg --yes --no-wait
if ($LASTEXITCODE -ne 0) { throw "az group delete failed (exit $LASTEXITCODE)" }
Write-Host "Deletion started. Verify later with: az group show -n $Rg"
