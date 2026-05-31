#Requires -Version 7.0
<#
============================================================================
  Lab 2A — one-command entry point for attendees. (PowerShell variant.)

  Fires the AGC blue/green deploy and the APIM AI-gateway deploy IN PARALLEL,
  because APIM Developer SKU takes ~30-45 min to provision (longer than the
  whole module). If you run them serially you'll never finish in a 90-min slot.

  Usage:
    ./deploy-both.ps1
    ./deploy-both.ps1 -Location westeurope     (any -Param / $env override is
    $env:LOCATION='westeurope'; ./deploy-both.ps1   inherited by both children)
============================================================================
#>
[CmdletBinding()]
param(
  [string]$Location = $env:LOCATION   # passed through to both children via inherited env
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Propagate -Location to the children (they read $env:LOCATION).
if ($Location) { $env:LOCATION = $Location }

$ScriptDir = $PSScriptRoot
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$tmp = [IO.Path]::GetTempPath()
$AgcLog  = if ($env:AGC_LOG)  { $env:AGC_LOG }  else { Join-Path $tmp "agc-deploy-$ts.log" }
$ApimLog = if ($env:APIM_LOG) { $env:APIM_LOG } else { Join-Path $tmp "apim-deploy-$ts.log" }

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Write-Error "Azure CLI not found."; exit 1 }
& az account show 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }

Write-Host "============================================================"
Write-Host "  Lab 2A — parallel deploy"
Write-Host "============================================================"
Write-Host "  Subscription : $(& az account show --query name -o tsv)"
Write-Host "  AGC log      : $AgcLog"
Write-Host "  APIM log     : $ApimLog"
Write-Host ""
Write-Host "AGC will deploy in ~12-18 min."
Write-Host "APIM Developer SKU will deploy in ~30-45 min (the long pole)."
Write-Host "Running both in parallel; you'll be back at the prompt when both finish."
Write-Host ""

# Kick off AGC first; both run in parallel after this. Children inherit env.
$agc = Start-Process pwsh -ArgumentList '-NoProfile','-File',(Join-Path $ScriptDir 'deploy.ps1') `
  -RedirectStandardOutput $AgcLog -RedirectStandardError "$AgcLog.err" -PassThru -NoNewWindow
# Tiny stagger so the two scripts don't race on `az provider register` calls.
Start-Sleep 5
$apim = Start-Process pwsh -ArgumentList '-NoProfile','-File',(Join-Path $ScriptDir 'apim/deploy-apim.ps1') `
  -RedirectStandardOutput $ApimLog -RedirectStandardError "$ApimLog.err" -PassThru -NoNewWindow

Write-Host "AGC  PID: $($agc.Id)"
Write-Host "APIM PID: $($apim.Id)"
Write-Host ""
Write-Host "Watching both. Live status every 30s..."
Write-Host ""

$agcDone = $false; $apimDone = $false
while (-not ($agcDone -and $apimDone)) {
  Start-Sleep 30
  $now = (Get-Date).ToString('HH:mm:ss')
  if (-not $agcDone -and $agc.HasExited) {
    $agcDone = $true
    Write-Host "[$now] AGC finished (exit=$($agc.ExitCode)). APIM still going."
  }
  if (-not $apimDone -and $apim.HasExited) {
    $apimDone = $true
    Write-Host "[$now] APIM finished (exit=$($apim.ExitCode))."
  }
  if (-not ($agcDone -and $apimDone)) {
    $a = if ($agcDone) { 'done' } else { 'running' }
    $p = if ($apimDone) { 'done' } else { 'running' }
    Write-Host "[$now] AGC: $a | APIM: $p"
  }
}

function Show-Tail { param([string]$Path,[int]$N=25)
  if (Test-Path $Path) { Get-Content $Path -Tail $N } else { Write-Host "(no log at $Path)" }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  Both deploys finished. Summary:"
Write-Host "============================================================"
Write-Host ""
Write-Host "--- AGC tail (last 25 lines of $AgcLog) ---"
Show-Tail $AgcLog
Write-Host ""
Write-Host "--- APIM tail (last 25 lines of $ApimLog) ---"
Show-Tail $ApimLog
Write-Host ""
Write-Host "Next steps are printed in each tail above (blue/green hammer for AGC, smoke test for APIM)."
Write-Host "When you're done with the lab, tear both down with:"
Write-Host "  ./cleanup.ps1                          # AGC RG"
Write-Host "  ./apim/cleanup-apim.ps1                # APIM RG (note: APIM Dev-SKU is non-deletable for ~45 min after create)"
