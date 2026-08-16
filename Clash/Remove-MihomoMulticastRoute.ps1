#Requires -Version 5.1
<#
.SYNOPSIS
  Drop the Clash/mihomo TUN 224.0.0.0/4 on-link route so Bonjour/mDNS stays on Wi-Fi.

.DESCRIPTION
  Run elevated after enabling TUN. Mihomo often re-adds this route; interface index is not stable.
  Also sets Mihomo interface metric high and restarts Bonjour so _altserver._tcp is on Wi-Fi.
#>
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Get-Clash.ps1')
if (Get-Command Invoke-ClashFixBonjourAfterMulticast -ErrorAction SilentlyContinue) {
    [void](Invoke-ClashFixBonjourAfterMulticast)
} else {
    [void](Invoke-ClashRemoveMulticastRoute)
}
