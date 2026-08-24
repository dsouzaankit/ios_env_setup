#Requires -Version 5.1
<#
.SYNOPSIS
  Create or remove IosEnv-Vpn-RemoveMulticast (RunLevel Highest).

.DESCRIPTION
  Must run elevated. Register-IphoneUsbAltServer.ps1 UAC-launches this once so
  USB plug-in can Start-ScheduledTask the drop without Access denied.
  Also removes the old task name IosEnv-Clash-RemoveMihomoMulticast.
#>
[CmdletBinding()]
param(
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here 'Get-VpnMulticast.ps1')

if (-not (Test-VpnProcessElevated)) {
    $pwsh = Get-VpnMulticastPwshExe
    $self = Join-Path $here 'Register-VpnMulticastRouteTask.ps1'
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
    if ($Unregister) { $arg = "$arg -Unregister" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $psi.Arguments = $arg
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $p) { throw 'elevated register did not start' }
    $p.WaitForExit()
    exit $p.ExitCode
}

if ($Unregister) {
    if (Unregister-VpnMulticastRouteTask) {
        Write-Host 'Removed scheduled task: IosEnv-Vpn-RemoveMulticast (and old Clash name if present)'
    } else {
        Write-Host 'No scheduled task named IosEnv-Vpn-RemoveMulticast or IosEnv-Clash-RemoveMihomoMulticast'
    }
    exit 0
}

$name = Register-VpnMulticastRouteTask
Write-Host "Registered: $name (highest privileges)"
exit 0
