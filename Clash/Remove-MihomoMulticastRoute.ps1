#Requires -Version 5.1
<#
.SYNOPSIS
  Drop the Clash/mihomo TUN 224.0.0.0/4 on-link route so Bonjour/mDNS stays on Wi-Fi.

.DESCRIPTION
  Run elevated after enabling TUN. Mihomo often re-adds this route; interface index is not stable.
#>
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Get-Clash.ps1')
[void](Invoke-ClashRemoveMulticastRoute)
