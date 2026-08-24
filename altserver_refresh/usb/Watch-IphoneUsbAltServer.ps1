#Requires -Version 5.1
<#
.SYNOPSIS
  When an iPhone appears on USB, start AltServer and run the phone-subnet check.

.DESCRIPTION
  Polls PnP for Apple USB. On a rising edge (unplugged -> plugged), waits for
  usbmux to settle, then runs Invoke-AltServerIfNeeded.ps1, Mihomo/Surfshark
  multicast drop, and Invoke-AltServerPhoneSubnetIfNeeded.ps1 (same pair as
  Join-AltStoreDeployPrep).
  Stays idle while the phone remains connected. Does not tap AltStore Refresh All.

  Direct run is a foreground loop (Ctrl+C to stop). The logon task from
  Register-IphoneUsbAltServer.ps1 starts this hidden.

.PARAMETER Once
  If USB is present, run the helpers once and exit (no watch loop).

.PARAMETER SkipPhoneSubnet
  Only ensure AltServer; skip USB pcapd / WifiRestart.

.PARAMETER KeepUsbLogSessions
  After each plug-in, keep only this many USB-connect blocks in the log (default 5).
#>
[CmdletBinding()]
param(
    [switch] $Once,
    [switch] $SkipPhoneSubnet,
    [int] $PollSeconds = 3,
    [int] $SettleSeconds = 8,
    [int] $CooldownSeconds = 20,
    [int] $UnlockRetries = 3,
    [int] $UnlockRetryDelaySec = 12,
    [int] $KeepUsbLogSessions = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UsbDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$RefreshRoot = Split-Path -Parent $UsbDir
$JoinPath = Join-Path $RefreshRoot 'lib\Join-AltStoreDeployPrep.ps1'
if (-not (Test-Path -LiteralPath $JoinPath)) {
    throw "Missing $JoinPath"
}
. $JoinPath

$LogDir = $RefreshRoot
$LogFile = Join-Path $LogDir 'iphone-usb-altserver.log'
$script:UsbLogSessionMarker = '==== USB connect '

function Write-UsbLog {
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {}
}

function Limit-UsbLogSessions {
    param([int] $Keep = 5)
    $keep = [Math]::Max(1, $Keep)
    try {
        if (-not (Test-Path -LiteralPath $LogFile)) { return }
        $text = [System.IO.File]::ReadAllText($LogFile)
        if ([string]::IsNullOrEmpty($text)) { return }
        $marker = $script:UsbLogSessionMarker
        $starts = New-Object System.Collections.Generic.List[int]
        $pos = 0
        while ($pos -lt $text.Length) {
            $i = $text.IndexOf($marker, $pos)
            if ($i -lt 0) { break }
            [void]$starts.Add($i)
            $pos = $i + $marker.Length
        }
        if ($starts.Count -le $keep) { return }
        $cut = $starts[$starts.Count - $keep]
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($LogFile, $text.Substring($cut), $utf8)
    } catch {}
}

function Test-IphoneUsbConnected {
    try {
        $hit = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop -Filter `
                "ConfigManagerErrorCode = 0 AND (Name LIKE '%Apple Mobile Device%' OR Name LIKE '%Apple iPhone%')")
        if ($hit.Count -gt 0) { return $true }
    } catch {}
    try {
        $devices = @(Get-PnpDevice -Status OK -ErrorAction SilentlyContinue | Where-Object {
                $_.FriendlyName -match 'Apple Mobile Device|Apple iPhone'
            })
        return ($devices.Count -gt 0)
    } catch {
        return $false
    }
}

function Invoke-UsbAltServerChild {
    param(
        [Parameter(Mandatory = $true)][string] $PwshExe,
        [Parameter(Mandatory = $true)][string] $ScriptPath,
        [string[]] $ExtraArgs = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -NoWaitEnter @ExtraArgs 2>&1 |
            ForEach-Object {
                $s = [string]$_
                Write-Host $s
                try { Add-Content -LiteralPath $LogFile -Value $s -Encoding UTF8 } catch {}
            }
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match 'ALTSERVER_SUBNET_EXIT:(\d+)') { return [int]$Matches[1] }
        if ($msg -match 'ALTSERVER_EXIT:(\d+)') { return [int]$Matches[1] }
        Write-UsbLog ("{0} threw: {1}" -f (Split-Path -Leaf $ScriptPath), $msg)
        return 1
    } finally {
        $ErrorActionPreference = $prev
    }
    return (Get-IosAltStorePrepExitCode $code)
}

function Invoke-UsbAltServerPrep {
    param([switch] $SkipPhoneSubnet)
    $pwsh = Get-IosAltStorePrepPwsh
    if (-not $pwsh) {
        Write-UsbLog 'pwsh (PowerShell 7) not found; skip'
        return 1
    }
    $ifNeeded = Join-Path $script:IosAltRefreshDir 'sideload\Invoke-AltServerIfNeeded.ps1'
    $subnet = Join-Path $script:IosAltRefreshDir 'lan\Invoke-AltServerPhoneSubnetIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $ifNeeded)) {
        Write-UsbLog ("missing {0}" -f $ifNeeded)
        return 1
    }
    $subnetCode = $null
    if (-not $SkipPhoneSubnet) {
        if (-not (Test-Path -LiteralPath $subnet)) {
            Write-UsbLog ("missing {0}" -f $subnet)
            return 1
        }
        Write-UsbLog 'Phone LAN vs PC/AltServer subnet (USB pcapd)...'
        $subnetCode = Invoke-UsbAltServerChild -PwshExe $pwsh -ScriptPath $subnet
        Write-UsbLog ("Subnet helper exit {0}" -f $subnetCode)
    }
    Write-UsbLog 'Mihomo/Surfshark Bonjour (AltStore finds AltServer)...'
    Invoke-IosAltStoreVpnMdns
    Write-UsbLog 'Restarting AltServer so Bonjour matches this LAN...'
    $altCode = Invoke-UsbAltServerChild -PwshExe $pwsh -ScriptPath $ifNeeded -ExtraArgs @('-ForceRestart')
    Write-UsbLog ("AltServer helper exit {0}" -f $altCode)
    if ($SkipPhoneSubnet) { return $altCode }
    return $subnetCode
}

function Invoke-UsbAltServerPrepWithRetries {
    param([switch] $SkipPhoneSubnet)
    $code = 1
    $tries = [Math]::Max(1, $UnlockRetries)
    for ($n = 1; $n -le $tries; $n++) {
        if (-not (Test-IphoneUsbConnected)) {
            Write-UsbLog 'USB gone before helpers ran'
            return 2
        }
        $code = Invoke-UsbAltServerPrep -SkipPhoneSubnet:$SkipPhoneSubnet
        if ($code -ne 2) { break }
        Write-UsbLog ("no USB iPhone from usbmux (exit 2); unlock/Trust retry {0}/{1}" -f $n, $tries)
        Start-Sleep -Seconds ([Math]::Max(1, $UnlockRetryDelaySec))
    }
    if ($code -eq 4 -and -not $SkipPhoneSubnet) {
        Write-UsbLog 'pcapd miss (exit 4); one more try after delay'
        Start-Sleep -Seconds ([Math]::Max(1, $UnlockRetryDelaySec))
        if (Test-IphoneUsbConnected) {
            $code = Invoke-UsbAltServerPrep -SkipPhoneSubnet:$SkipPhoneSubnet
        }
    }
    return $code
}

function Invoke-UsbAltServerOnPlug {
    param([switch] $SkipPhoneSubnet)
    Write-UsbLog ("{0}{1} ====" -f $script:UsbLogSessionMarker, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $settle = [Math]::Max(0, $SettleSeconds)
    if ($settle -gt 0) {
        Write-UsbLog ("iPhone USB present; waiting {0}s for usbmux/lockdown..." -f $settle)
        Start-Sleep -Seconds $settle
    }
    if (-not (Test-IphoneUsbConnected)) {
        Write-UsbLog 'USB gone during settle; skip'
        Limit-UsbLogSessions -Keep $KeepUsbLogSessions
        return
    }
    [void](Invoke-UsbAltServerPrepWithRetries -SkipPhoneSubnet:$SkipPhoneSubnet)
    Limit-UsbLogSessions -Keep $KeepUsbLogSessions
}

$mutex = $null
$owns = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\IosEnvAltServerUsbWatch')
    try {
        $owns = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $owns = $true
    }
    if (-not $owns) {
        $others = $false
        try {
            $others = [bool]@(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -match 'Watch-IphoneUsbAltServer' -and [int]$_.ProcessId -ne $PID }).Count
        } catch {}
        if ($others) {
            Write-Host '[usb-altserver] Already running.'
            exit 0
        }
        Write-UsbLog 'Mutex was held but no watcher process; taking over.'
        try {
            $owns = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $owns = $true
        }
        if (-not $owns) {
            Write-Host '[usb-altserver] Already running.'
            exit 0
        }
    }

    Write-UsbLog ("Watch start (poll {0}s, settle {1}s). Ctrl+C to stop." -f $PollSeconds, $SettleSeconds)

    if ($Once) {
        if (Test-IphoneUsbConnected) {
            Invoke-UsbAltServerOnPlug -SkipPhoneSubnet:$SkipPhoneSubnet
        } else {
            Write-UsbLog 'No Apple iPhone USB right now (-Once); exit'
        }
        exit 0
    }

    $wasConnected = $false
    $cooldownUntil = [datetime]::MinValue
    while ($true) {
        try {
            $now = Test-IphoneUsbConnected
            if ($now -and -not $wasConnected) {
                $utc = [datetime]::UtcNow
                if ($utc -ge $cooldownUntil) {
                    Invoke-UsbAltServerOnPlug -SkipPhoneSubnet:$SkipPhoneSubnet
                    $cooldownUntil = [datetime]::UtcNow.AddSeconds([Math]::Max(0, $CooldownSeconds))
                } else {
                    Write-UsbLog 'USB appeared again inside cooldown; skip'
                }
            }
            $wasConnected = $now
        } catch {
            Write-UsbLog ("Watch poll error: {0}" -f $_.Exception.Message)
        }
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    }
} finally {
    if ($owns -and $null -ne $mutex) {
        try { [void]$mutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
