#Requires -Version 5.1
<#
.SYNOPSIS
  Drop TUN/VPN 224.0.0.0/4 on-link routes so Bonjour/mDNS stays on Wi-Fi.

.DESCRIPTION
  Run elevated. Drops 224.0.0.0/4 on Mihomo (Clash TUN) and Surfshark OpenVPN
  adapters, raises those interface metrics, and restarts Bonjour.
  Does not disconnect Surfshark. Mihomo often re-adds the route when TUN comes up.
#>
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Get-VpnMulticast.ps1')
if (Get-Command Invoke-VpnFixBonjourAfterMulticast -ErrorAction SilentlyContinue) {
    [void](Invoke-VpnFixBonjourAfterMulticast)
} else {
    [void](Invoke-MihomoRemoveMulticastRoute)
}
