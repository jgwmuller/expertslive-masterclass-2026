#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
============================================================================
  Private Endpoint latency reveal — run ON the client VM.
  (PowerShell variant of lab-on-vm.sh — keep the two in sync if you edit.)

  Needs `dig` and `mtr`, so this runs under pwsh on the Linux client VM. It is
  a 1:1 translation of the bash original, not a Windows-only variant.

  Usage: pwsh lab-on-vm.ps1 -Near <near-blob-fqdn> -Far <far-blob-fqdn>
============================================================================
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, HelpMessage = 'NEAR storage blob FQDN')][string]$Near,
  [Parameter(Mandatory, HelpMessage = 'FAR storage blob FQDN')][string]$Far
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Let native commands (dig/mtr) set $LASTEXITCODE without throwing — mirrors the
# bash original's `|| true` tolerance on the mtr calls.
$PSNativeCommandUseErrorActionPreference = $false

function Write-Rule { Write-Host ('-' * 72) }

Write-Host ''
Write-Rule
Write-Host '  STEP 1 - DNS: where do these FQDNs resolve?'
Write-Rule
foreach ($fqdn in @($Near, $Far)) {
  Write-Host "-> $fqdn"
  dig +noall +answer $fqdn
  Write-Host ''
}
Write-Host 'Both resolve to PRIVATE IPs in the LOCAL private-endpoint subnet (10.20.2.x).'
Write-Host "From DNS alone the two services look identical and equally 'local'."
Write-Host ''

Write-Rule
Write-Host '  STEP 2 - Latency: mtr -T -P 443 (TCP SYN to the data plane)'
Write-Rule
Write-Host "-> NEAR storage ($Near)"
mtr -T -P 443 -c 20 --report --no-dns $Near
Write-Host ''
Write-Host "-> FAR storage ($Far)"
mtr -T -P 443 -c 20 --report --no-dns $Far
Write-Host ''

Write-Rule
Write-Host '  THE REVEAL'
Write-Rule
Write-Host @'
Both Private Endpoints are local NICs in the SAME subnet, yet:
  * NEAR storage answers in single-digit milliseconds.
  * FAR  storage answers in ~200+ ms.

If the PE were a network hop / proxy, BOTH would be local-fast.
They are not. The PE only injected a /32 route + a DNS record.
The TCP handshake actually round-trips to the storage account's
REAL region over Microsoft's backbone.

==> A Private Endpoint never carries data. It is control-plane only.
'@
