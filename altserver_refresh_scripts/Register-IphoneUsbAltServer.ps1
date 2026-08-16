#Requires -Version 5.1
<#
.SYNOPSIS
  Start Watch-IphoneUsbAltServer.ps1 at logon (and now) so AltServer helpers run on USB plug-in.

.DESCRIPTION
  Registers an interactive logon task that polls for Apple iPhone USB and, on each
  plug-in, starts AltServer, drops Clash/mihomo TUN 224.0.0.0/4 (Bonjour), and
  checks the phone subnet (WifiRestart if off-subnet).
  Same helpers as Join-AltStoreDeployPrep.ps1. Does not tap AltStore Refresh All.
  Also registers IosEnv-Clash-RemoveMihomoMulticast (highest privileges) so the
  multicast drop does not prompt UAC on every cable.

.PARAMETER Unregister
  Remove the scheduled task (does not kill a watcher that is already running).

.PARAMETER ShowWindow
  Run the watcher in a visible console (default is hidden).

.PARAMETER SkipPhoneSubnet
  Watcher only ensures AltServer; skip USB pcapd / WifiRestart.

.PARAMETER NoStart
  Register the task but do not start it until the next logon.

.EXAMPLE
  pwsh -File .\Register-IphoneUsbAltServer.ps1

.EXAMPLE
  pwsh -File .\Register-IphoneUsbAltServer.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [string] $TaskName = 'IosEnv-AltServer-UsbWatch',
    [switch] $Unregister,
    [switch] $ShowWindow,
    [switch] $SkipPhoneSubnet,
    [switch] $NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$WatchScript = Join-Path $ScriptDir 'Watch-IphoneUsbAltServer.ps1'
$JoinPath = Join-Path $ScriptDir 'Join-AltStoreDeployPrep.ps1'
$ClashCore = Join-Path (Split-Path -Parent $ScriptDir) 'Clash\Get-Clash.ps1'
if (Test-Path -LiteralPath $ClashCore) { . $ClashCore }

function Stop-IosEnvUsbWatchProcesses {
    $match = @()
    try {
        $match = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -and
                $_.CommandLine -notmatch '-Once' -and
                ($_.CommandLine -match 'Watch-IphoneUsbAltServer' -or $_.CommandLine -match 'Start-IphoneUsbAltServerWatchHidden')
            })
    } catch {}
    foreach ($p in $match) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }
}

if ($Unregister) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task: $TaskName"
    } else {
        Write-Host "No scheduled task named $TaskName"
    }
    if (Get-Command Unregister-ClashRemoveMulticastRouteTask -ErrorAction SilentlyContinue) {
        $removed = $false
        try { $removed = [bool](Unregister-ClashRemoveMulticastRouteTask) } catch { $removed = $false }
        if ($removed) {
            Write-Host 'Removed scheduled task: IosEnv-Clash-RemoveMihomoMulticast'
        } elseif (Get-Command Start-ClashRegisterMulticastTaskElevated -ErrorAction SilentlyContinue) {
            try {
                [void](Start-ClashRegisterMulticastTaskElevated -Unregister)
                Write-Host 'Removed scheduled task: IosEnv-Clash-RemoveMihomoMulticast'
            } catch {
                Write-Warning ("Could not remove elevated multicast task: {0}" -f $_.Exception.Message)
            }
        }
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $WatchScript)) {
    throw "Missing $WatchScript"
}
if (-not (Test-Path -LiteralPath $JoinPath)) {
    throw "Missing $JoinPath"
}
. $JoinPath

$pwsh = Get-IosAltStorePrepPwsh
if (-not $pwsh) {
    throw 'PowerShell 7 (pwsh) is required. Install from https://aka.ms/powershell'
}

$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$triggerKeep = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
# TimeSpan.Zero becomes ExecutionTimeLimit 00:00:00, which this Task Scheduler rejects.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 365)
try {
    $settings.MultipleInstances = 'IgnoreNew'
} catch {}
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

if ($ShowWindow) {
    $fileArgs = "-WindowStyle Normal -NoProfile -ExecutionPolicy Bypass -File `"$WatchScript`""
    if ($SkipPhoneSubnet) { $fileArgs = "$fileArgs -SkipPhoneSubnet" }
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $fileArgs -WorkingDirectory $ScriptDir
} else {
    $vbs = Join-Path $ScriptDir 'Start-IphoneUsbAltServerWatchHidden.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) {
        throw "Missing $vbs"
    }
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $vbsArgs = "//nologo `"$vbs`" `"$pwsh`" `"$WatchScript`""
    if ($SkipPhoneSubnet) { $vbsArgs = "$vbsArgs -SkipPhoneSubnet" }
    $action = New-ScheduledTaskAction -Execute $wscript -Argument $vbsArgs -WorkingDirectory $ScriptDir
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Stop-IosEnvUsbWatchProcesses
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($triggerLogon, $triggerKeep) -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $task.Settings.ExecutionTimeLimit = 'PT0S'
    try {
        $task.Settings.RestartCount = 3
        $task.Settings.RestartInterval = 'PT1M'
    } catch {}
    Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
} catch {}

$created = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $created) {
    throw "Scheduled task $TaskName was not created."
}

Write-Host "Registered: $TaskName"
Write-Host "Watcher: $WatchScript"
Write-Host "pwsh: $pwsh"
if ($SkipPhoneSubnet) {
    Write-Host 'Mode: AltServer only (no phone-subnet / WifiRestart)'
} else {
    Write-Host 'Mode: AltServer tray + Clash multicast drop + phone-subnet check on each USB plug-in'
}
if (Get-Command Start-ClashRegisterMulticastTaskElevated -ErrorAction SilentlyContinue) {
    $mdnsName = Get-ClashRemoveMulticastRouteTaskName
    $mdnsTask = Get-ScheduledTask -TaskName $mdnsName -ErrorAction SilentlyContinue
    if ($mdnsTask) {
        Write-Host "Already registered: $mdnsName (highest; started on each USB plug-in, no per-cable UAC)"
    } else {
        try {
            $mdnsName = Start-ClashRegisterMulticastTaskElevated
            Write-Host "Registered: $mdnsName (highest; started on each USB plug-in, no per-cable UAC)"
        } catch {
            Write-Warning ("Could not register elevated multicast task ({0}). USB plug-in will prompt UAC to drop 224.0.0.0/4." -f $_.Exception.Message)
        }
    }
}
Write-Host ("Log: {0}" -f (Join-Path $ScriptDir 'iphone-usb-altserver.log'))
Write-Host ("Remove: pwsh -File `"{0}`" -Unregister" -f (Join-Path $ScriptDir 'Register-IphoneUsbAltServer.ps1'))

if (-not $NoStart) {
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Start-Sleep -Seconds 2
    $state = [string](Get-ScheduledTask -TaskName $TaskName).State
    Write-Host "Started $TaskName (State=$state). Hidden watcher should stay Running until it exits; 2-min keep-alive is ignored while Running."
    if ($state -ne 'Running') {
        Write-Warning 'UsbWatch is not Running. Check iphone-usb-altserver.log and Task Scheduler Last Run Result.'
    }
}
