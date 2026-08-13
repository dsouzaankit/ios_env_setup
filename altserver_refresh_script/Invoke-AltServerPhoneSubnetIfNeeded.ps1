# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Ensure the USB iPhone's Wi-Fi IPv4 is on the same subnet as AltServer (this PC).

.DESCRIPTION
  Uses pymobiledevice3 (USB identify + Bonjour mobdev2) for the phone LAN IP.
  Compares it to this PC's LAN IPv4(s) — AltServer binds those interfaces.

  If subnets differ, infers telnet_reboot_wlan_*.py from
  P:\all_scripts\5g_router_reboot (wifi_dx_common_*.py ROUTER_IP on the phone's
  current subnet), reboots that AP, waits for a new phone IP, and checks again.

  Direct run waits for Enter. Pass -NoWaitEnter when invoked as a child.

.EXAMPLE
  pwsh -File .\Invoke-AltServerPhoneSubnetIfNeeded.ps1
#>
[CmdletBinding()]
param(
    [string] $RebootScriptsRoot = 'P:\all_scripts\5g_router_reboot',
    [int] $PrefixLength = 0,
    [ValidateRange(2, 60)]
    [int] $PollSec = 5,
    [ValidateRange(15, 3600)]
    [int] $WaitPhoneIpSec = 180,
    [ValidateRange(1, 20)]
    [int] $MaxRounds = 3,
    [switch] $SkipReboot,
    [switch] $NoWaitEnter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    exit $ExitCode
}

trap {
    Write-Host ""
    Write-Host ('[altserver-subnet] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($NoWaitEnter) { throw $_ }
    Wait-EnterToClose
    exit 1
}

function Get-PwshExe {
    $cmd = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }
    foreach ($path in @(
            (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7\pwsh.exe')
        )) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    throw 'PowerShell 7 (pwsh) is required. Install from https://aka.ms/powershell'
}

if ($PSVersionTable.PSEdition -ne 'Core' -or [int]$PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-PwshExe
    Write-Host ("[pwsh] Re-launching under PowerShell 7: {0}" -f $pwsh) -ForegroundColor Cyan
    $fileArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($PSBoundParameters.Keys)) {
        $val = $PSBoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { [void]$fileArgs.Add("-$key") }
            continue
        }
        [void]$fileArgs.Add("-$key")
        [void]$fileArgs.Add([string]$val)
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fileArgs
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    exit $code
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$GetIpPy = Join-Path $ScriptDir 'Get-IphoneLanIpv4.py'

function Get-Py312Launcher {
    $py = Get-Command -Name py.exe -ErrorAction SilentlyContinue
    if ($null -eq $py) { $py = Get-Command -Name py -ErrorAction SilentlyContinue }
    if ($null -eq $py) {
        throw 'Python launcher py.exe not found. Install Python 3.12 and pymobiledevice3.'
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $py.Source -3.12 -c "import pymobiledevice3; print('ok')" 2>&1
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = (@($out) | ForEach-Object { [string]$_ }) -join "`n"
    if ($code -ne 0 -or $text -notmatch '(?m)^ok\s*$') {
        throw @"
pymobiledevice3 not available for py -3.12.
  py -3.12 -m pip install -U pymobiledevice3
"@
    }
    return $py.Source
}

function ConvertTo-Ipv4UInt32 {
    param([Parameter(Mandatory = $true)][string] $IpAddress)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress.Trim(), [ref]$parsed)) {
        throw "Invalid IPv4 address: $IpAddress"
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Not an IPv4 address: $IpAddress"
    }
    $bytes = $parsed.GetAddressBytes()
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-SameIpv4Subnet {
    param(
        [Parameter(Mandatory = $true)][string] $IpA,
        [Parameter(Mandatory = $true)][string] $IpB,
        [Parameter(Mandatory = $true)][int] $PrefixLen
    )
    if ($PrefixLen -lt 0 -or $PrefixLen -gt 32) {
        throw "PrefixLength must be 0..32 (got $PrefixLen)"
    }
    $hostBits = 32 - $PrefixLen
    [uint32]$mask = 0
    if ($PrefixLen -ge 32) {
        $mask = [uint32]::MaxValue
    } elseif ($PrefixLen -gt 0) {
        $mask = [uint32](-bnot (([uint32]1 -shl $hostBits) - 1))
    }
    $netA = (ConvertTo-Ipv4UInt32 -IpAddress $IpA) -band $mask
    $netB = (ConvertTo-Ipv4UInt32 -IpAddress $IpB) -band $mask
    return ($netA -eq $netB)
}

function Get-PcLanIdentities {
    $list = [System.Collections.Generic.List[object]]::new()
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' })
        foreach ($cfg in $configs) {
            $v4s = @($cfg.IPv4Address) | Where-Object {
                $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1'
            }
            foreach ($v4 in $v4s) {
                $prefix = 24
                if ($null -ne $v4.PrefixLength -and [int]$v4.PrefixLength -gt 0) {
                    $prefix = [int]$v4.PrefixLength
                }
                $gw = $null
                if ($cfg.IPv4DefaultGateway -and $cfg.IPv4DefaultGateway.NextHop) {
                    $gw = ([string]$cfg.IPv4DefaultGateway.NextHop).Trim()
                }
                [void]$list.Add([pscustomobject]@{
                    Ip           = ([string]$v4.IPAddress).Trim()
                    PrefixLength = $prefix
                    Gateway      = $gw
                    Adapter      = [string]$cfg.NetAdapter.Name
                })
            }
        }
    } catch {}
    return @($list.ToArray())
}

function Get-IphoneLanIpv4 {
    param([Parameter(Mandatory = $true)][string] $PyExe)
    if (-not (Test-Path -LiteralPath $GetIpPy)) {
        throw "Missing $GetIpPy"
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $PyExe -3.12 $GetIpPy 2>&1
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($out | ForEach-Object { [string]$_ })
    $jsonLine = $lines | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1
    $errText = ($lines | Where-Object { $_ -notmatch '^\s*\{' }) -join "`n"
    $ip = $null
    if ($jsonLine) {
        try {
            $obj = $jsonLine | ConvertFrom-Json
            if ($obj.ip) { $ip = [string]$obj.ip }
        } catch {}
    }
    return [pscustomobject]@{
        ExitCode = $code
        Ip       = $ip
        Error    = $errText
    }
}

function Find-RebootScriptForIp {
    param(
        [Parameter(Mandatory = $true)][string] $PhoneIp,
        [Parameter(Mandatory = $true)][string] $ScriptsRoot,
        [int] $PrefixLen = 24
    )
    if (-not (Test-Path -LiteralPath $ScriptsRoot)) {
        throw "Router reboot scripts folder not found: $ScriptsRoot"
    }
    $commons = @(Get-ChildItem -LiteralPath $ScriptsRoot -Filter 'wifi_dx_common_*.py' -File -ErrorAction SilentlyContinue)
    foreach ($common in $commons) {
        $text = Get-Content -LiteralPath $common.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -notmatch '(?m)^ROUTER_IP\s*=\s*"([^"]+)"') { continue }
        $routerIp = $Matches[1].Trim()
        if (-not (Test-SameIpv4Subnet -IpA $PhoneIp -IpB $routerIp -PrefixLen $PrefixLen)) { continue }
        if ($common.BaseName -notmatch '^wifi_dx_common_(.+)$') { continue }
        $candidate = Join-Path $ScriptsRoot ("telnet_reboot_wlan_{0}.py" -f $Matches[1])
        if (Test-Path -LiteralPath $candidate) {
            return [pscustomobject]@{
                RouterIp = $routerIp
                Model    = $Matches[1]
                Script   = $candidate
            }
        }
    }
    return $null
}

function Test-PhoneOnPcSubnet {
    param(
        [Parameter(Mandatory = $true)][string] $PhoneIp,
        [Parameter(Mandatory = $true)] $PcLans,
        [int] $PrefixOverride = 0
    )
    foreach ($lan in $PcLans) {
        $prefix = if ($PrefixOverride -gt 0) { $PrefixOverride } else { [int]$lan.PrefixLength }
        if (Test-SameIpv4Subnet -IpA $PhoneIp -IpB $lan.Ip -PrefixLen $prefix) {
            return $lan
        }
    }
    return $null
}

try {
    if (-not (Test-Path -LiteralPath $GetIpPy)) {
        throw "Missing $GetIpPy"
    }
    $py = Get-Py312Launcher
    $pcLans = @(Get-PcLanIdentities)
    if ($pcLans.Count -eq 0) {
        throw 'No PC LAN IPv4 found (AltServer has nothing to share a subnet with).'
    }
    Write-Host '[altserver-subnet] PC / AltServer LAN:' -ForegroundColor Cyan
    foreach ($lan in $pcLans) {
        Write-Host ('  {0}/{1} gw={2} ({3})' -f $lan.Ip, $lan.PrefixLength, $(if ($lan.Gateway) { $lan.Gateway } else { '(none)' }), $lan.Adapter)
    }

    function Show-PhoneProbe([object] $Probe) {
        if ($Probe.Ip) {
            Write-Host ('[altserver-subnet] Phone LAN IP: {0}' -f $Probe.Ip) -ForegroundColor Cyan
        } else {
            Write-Host ('[altserver-subnet] Phone LAN IP: (none) exit={0}' -f $Probe.ExitCode)
            if ($Probe.Error) {
                Write-Host $Probe.Error -ForegroundColor DarkGray
            }
        }
    }

    $probe = Get-IphoneLanIpv4 -PyExe $py
    Show-PhoneProbe $probe
    if ($probe.ExitCode -eq 2) {
        Write-Host '[altserver-subnet] No USB iPhone (plug in, Trust This Computer, unlock).' -ForegroundColor Yellow
        Exit-WithEnter 2
    }
    if ($probe.ExitCode -eq 4 -and -not $probe.Ip) {
        Write-Host '[altserver-subnet] USB iPhone present but Bonjour advertised no Wi-Fi IPv4 (enable Wi-Fi lockdown / join Wi-Fi).' -ForegroundColor Yellow
        Exit-WithEnter 4
    }

    $round = 0
    while ($true) {
        if ($probe.Ip) {
            $match = Test-PhoneOnPcSubnet -PhoneIp $probe.Ip -PcLans $pcLans -PrefixOverride $PrefixLength
            if ($match) {
                Write-Host ('[altserver-subnet] OK — phone {0} shares subnet with PC/AltServer {1}/{2} ({3}).' -f `
                    $probe.Ip, $match.Ip, $match.PrefixLength, $match.Adapter) -ForegroundColor Green
                Exit-WithEnter 0
            }
            Write-Host ('[altserver-subnet] Phone {0} is NOT on a PC/AltServer subnet.' -f $probe.Ip) -ForegroundColor Yellow
        } else {
            Write-Host '[altserver-subnet] Phone has no advertised Wi-Fi IPv4 yet (USB ok).' -ForegroundColor Yellow
        }

        if ($SkipReboot) {
            Write-Host '[altserver-subnet] Skipping gateway reboot (-SkipReboot).'
            Exit-WithEnter 1
        }

        $round++
        if ($round -gt $MaxRounds) {
            Write-Host ('[altserver-subnet] Gave up after {0} reboot rounds.' -f $MaxRounds) -ForegroundColor Red
            Exit-WithEnter 1
        }

        $prefixForMatch = if ($PrefixLength -gt 0) { $PrefixLength } else { 24 }
        $target = $null
        if ($probe.Ip) {
            $target = Find-RebootScriptForIp -PhoneIp $probe.Ip -ScriptsRoot $RebootScriptsRoot -PrefixLen $prefixForMatch
        }
        if (-not $target) {
            throw @"
[altserver-subnet] No matching reboot script under $RebootScriptsRoot
(need wifi_dx_common_*.py ROUTER_IP on the phone's current subnet -> telnet_reboot_wlan_*.py).
Phone IP: $(if ($probe.Ip) { $probe.Ip } else { '(unknown — cannot infer AP)' })
"@
        }

        Write-Host ('[altserver-subnet] Round {0}: rebooting Wi-Fi on {1} ({2}) so the phone can join the AltServer subnet...' -f `
            $round, $target.RouterIp, $target.Model) -ForegroundColor Cyan
        Write-Host ('[altserver-subnet] Running: {0}' -f $target.Script)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $py -3.12 $target.Script
            $rebootCode = 0
            if ($null -ne $LASTEXITCODE) { $rebootCode = [int]$LASTEXITCODE }
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($rebootCode -ne 0) {
            throw ("Reboot script failed (exit {0}): {1}" -f $rebootCode, $target.Script)
        }

        $previousIp = if ($probe.Ip) { $probe.Ip } else { '' }
        Write-Host ('[altserver-subnet] Waiting up to {0}s for a fresh phone LAN IP (poll {1}s)...' -f $WaitPhoneIpSec, $PollSec)
        $deadline = [datetime]::UtcNow.AddSeconds($WaitPhoneIpSec)
        $gotFresh = $false
        while ([datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds $PollSec
            $probe = Get-IphoneLanIpv4 -PyExe $py
            if (-not $probe.Ip) { continue }
            $changed = [string]::IsNullOrWhiteSpace($previousIp) -or ($probe.Ip -ne $previousIp)
            $match = Test-PhoneOnPcSubnet -PhoneIp $probe.Ip -PcLans $pcLans -PrefixOverride $PrefixLength
            Write-Host ('[altserver-subnet] Probe IP={0} changed={1} onPcSubnet={2}' -f `
                $probe.Ip, $changed, [bool]$match)
            if ($match) {
                Write-Host ('[altserver-subnet] OK — phone {0} now shares subnet with PC/AltServer {1}.' -f $probe.Ip, $match.Ip) -ForegroundColor Green
                Exit-WithEnter 0
            }
            if ($changed) { $gotFresh = $true }
        }
        if (-not $gotFresh) {
            Write-Warning '[altserver-subnet] Timed out waiting for a new phone IP — re-checking.'
        }
        $probe = Get-IphoneLanIpv4 -PyExe $py
        Show-PhoneProbe $probe
    }
} catch {
    Write-Host ""
    Write-Host ('[altserver-subnet] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Exit-WithEnter 1
}
