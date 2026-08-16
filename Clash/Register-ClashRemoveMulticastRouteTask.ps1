#Requires -Version 5.1
<#
.SYNOPSIS
  Create or remove IosEnv-Clash-RemoveMihomoMulticast (RunLevel Highest).

.DESCRIPTION
  Must run elevated. Register-IphoneUsbAltServer.ps1 UAC-launches this once so
  USB plug-in can Start-ScheduledTask the drop without Access denied.
#>
[CmdletBinding()]
param(
    [switch] $Unregister
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here 'Get-Clash.ps1')

if (-not (Test-ClashProcessElevated)) {
    $pwsh = Get-ClashPwshExe
    $self = Join-Path $here 'Register-ClashRemoveMulticastRouteTask.ps1'
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
    if (Unregister-ClashRemoveMulticastRouteTask) {
        Write-Host 'Removed scheduled task: IosEnv-Clash-RemoveMihomoMulticast'
    } else {
        Write-Host 'No scheduled task named IosEnv-Clash-RemoveMihomoMulticast'
    }
    exit 0
}

$name = Register-ClashRemoveMulticastRouteTask
Write-Host "Registered: $name (highest privileges)"
exit 0
