#Requires -Version 7.0
<#
============================================================================
  Tear down the AGC convergence lab. (PowerShell variant of cleanup.sh.)

  Deleting the resource group removes the AKS cluster and the managed identity.
  The AGC resource + association live in the AKS NODE resource group, which AKS
  deletes automatically with the cluster — so a single RG delete cleans up all.

  Usage:
    ./cleanup.ps1 -Rg rg-agc-convergence-lab   # prompts for confirmation
    ./cleanup.ps1 -Confirm1 1                   # no prompt (scripted)
    $env:CONFIRM='1'; ./cleanup.ps1
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Rg       = ($env:RG      ?? 'rg-agc-convergence-lab'),
  [string]$Confirm1 = ($env:CONFIRM ?? '0')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }

if ($Confirm1 -ne '1') {
  $ans = Read-Host "Delete resource group '$Rg' and EVERYTHING in it? [y/N]"
  if ($ans -notmatch '^[Yy]$') { Write-Host "Aborted."; exit 0 }
}

Write-Host "Deleting resource group '$Rg'..."
& az group delete -n $Rg --yes --no-wait
if ($LASTEXITCODE -ne 0) { throw "az group delete failed (exit $LASTEXITCODE)" }
Write-Host "Delete started (running in the background). The AGC, AKS, identity and VNet all go with it."
