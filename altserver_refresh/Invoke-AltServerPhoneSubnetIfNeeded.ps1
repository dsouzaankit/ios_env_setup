# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Ensure the USB iPhone's Wi-Fi IPv4 is on the same subnet as AltServer (this PC).

.DESCRIPTION
  Uses pymobiledevice3 (USB identify, then USB pcapd on en0) for the phone LAN IP.
  Compares it to this PC's LAN IPv4(s) - AltServer binds those interfaces.

  If subnets differ, infers telnet_reboot_wlan_*.py from
  P:\all_scripts\5g_router_reboot (wifi_dx_common_*.py ROUTER_IP). Probes
  tcp/23 (~1.5s) on the phone's AP and on this PC's gateway the same way
  before telnet (~60s on WinError 10060). Uses the first that answers
  (phone AP, then PC gateway); no assumption that either direction can
  reach the other. Telnet failure tries the other reachable AP.
  Same off-subnet after a bounce stops that wait early and retries (up to
  MaxRounds), matching the PC gateway loop.

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
    # WifiRestart script is ~10s (telnet + device sleep 5). 20s after that fits
    # one USB pcapd probe (~8s) plus PollSec; same off-subnet stops the wait
    # early, then the next round WifiRestarts that AP again.
    [ValidateRange(15, 3600)]
    [int] $WaitPhoneIpSec = 20,
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

function Test-AltServerSubnetInProcessCaller {
    foreach ($frame in @(Get-PSCallStack)) {
        if ($frame.ScriptName -and ($frame.ScriptName -ne $PSCommandPath)) {
            return $true
        }
    }
    return $false
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    # In-process (& / dot-source from recover): throw so the caller is not killed.
    # pwsh -File -NoWaitEnter (deploy prep): exit so LASTEXITCODE is the real code.
    if ($NoWaitEnter -and (Test-AltServerSubnetInProcessCaller)) {
        throw "ALTSERVER_SUBNET_EXIT:$ExitCode"
    }
    exit $ExitCode
}

trap {
    if ("$($_.Exception.Message)" -match '^ALTSERVER_SUBNET_EXIT:') { throw $_ }
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
                $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '198.18.*'
            }
            foreach ($v4 in $v4s) {
                $adapter = [string]$cfg.NetAdapter.Name
                if ($adapter -match '(?i)clash|meta|tun|wintun|tap-windows') {
                    continue
                }
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
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        # -u so stderr progress is not buffered; stream so the minute-long probe is not silent.
        & $PyExe -3.12 -u $GetIpPy 2>&1 | ForEach-Object {
            $s = [string]$_
            if ([string]::IsNullOrWhiteSpace($s)) { return }
            [void]$lines.Add($s)
            if (-not $s.Trim().StartsWith('{')) {
                Write-Host $s
            }
        }
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $prev
    }
    $jsonLine = @($lines | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    $errText = (@($lines | Where-Object { $_ -notmatch '^\s*\{' })) -join "`n"
    $ip = $null
    $source = $null
    $gatewayHint = $null
    if ($jsonLine) {
        try {
            $obj = $jsonLine | ConvertFrom-Json
            if ($obj.ip) { $ip = [string]$obj.ip }
            if ($obj.source) { $source = [string]$obj.source }
            if ($obj.PSObject.Properties['gatewayHint'] -and $obj.gatewayHint) {
                $gatewayHint = [string]$obj.gatewayHint
            }
        } catch {}
    }
    return [pscustomobject]@{
        ExitCode    = $code
        Ip          = $ip
        Source      = $source
        GatewayHint = $gatewayHint
        Error       = $errText
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

function Test-RouterTcp23 {
    param(
        [Parameter(Mandatory = $true)][string] $Ip,
        [int] $TimeoutMs = 1500
    )
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($Ip.Trim(), 23, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($null -ne $client) {
            try { $client.Close() } catch {}
        }
    }
}

function Test-WifiRestartTargetReachable {
    param(
        [Parameter(Mandatory = $true)] $Target,
        [int] $TimeoutMs = 1500
    )
    $ok = Test-RouterTcp23 -Ip $Target.RouterIp -TimeoutMs $TimeoutMs
    if ($ok) {
        Write-Host ('[altserver-subnet] tcp/23 {0} ({1}) open.' -f $Target.RouterIp, $Target.Model)
    } else {
        Write-Host ('[altserver-subnet] tcp/23 {0} ({1}) no reply in {2}ms; skip telnet (would wait ~60s).' -f `
            $Target.RouterIp, $Target.Model, $TimeoutMs) -ForegroundColor Yellow
    }
    return $ok
}

function Find-RebootScriptForPcGateway {
    param(
        [Parameter(Mandatory = $true)] $PcLans,
        [Parameter(Mandatory = $true)][string] $ScriptsRoot,
        [int] $PrefixLen = 24
    )
    $ordered = @($PcLans | Sort-Object {
            if ($_.Adapter -match '(?i)wi-?fi|wlan|wireless') { 0 } else { 1 }
        })
    foreach ($lan in $ordered) {
        foreach ($ip in @($lan.Gateway, $lan.Ip)) {
            if ([string]::IsNullOrWhiteSpace([string]$ip)) { continue }
            $hit = Find-RebootScriptForIp -PhoneIp $ip -ScriptsRoot $ScriptsRoot -PrefixLen $PrefixLen
            if ($hit) { return $hit }
        }
    }
    return $null
}

function Invoke-RouterWifiRestart {
    param(
        [Parameter(Mandatory = $true)] $Target,
        [Parameter(Mandatory = $true)][string] $PyExe
    )
    Write-Host ('[altserver-subnet] Running: {0}' -f $Target.Script)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $PyExe -3.12 $Target.Script
        $code = 0
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
        return $code
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-KnownRouterIps {
    param([Parameter(Mandatory = $true)][string] $ScriptsRoot)
    $ips = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $ScriptsRoot)) { return @() }
    foreach ($common in @(Get-ChildItem -LiteralPath $ScriptsRoot -Filter 'wifi_dx_common_*.py' -File -ErrorAction SilentlyContinue)) {
        $text = Get-Content -LiteralPath $common.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '(?m)^ROUTER_IP\s*=\s*"([^"]+)"') {
            [void]$ips.Add($Matches[1].Trim())
        }
    }
    return @($ips.ToArray())
}

function Test-IsKnownRouterIp {
    param(
        [Parameter(Mandatory = $true)][string] $Ip,
        [Parameter(Mandatory = $true)][string[]] $RouterIps
    )
    foreach ($r in $RouterIps) {
        if ($r -and ($Ip.Trim() -eq $r.Trim())) { return $true }
    }
    return $false
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
    $knownRouterIps = @(Get-KnownRouterIps -ScriptsRoot $RebootScriptsRoot)
    $pcLans = @(Get-PcLanIdentities)
    if ($pcLans.Count -eq 0) {
        throw 'No PC LAN IPv4 found (AltServer has nothing to share a subnet with).'
    }
    Write-Host '[altserver-subnet] PC / AltServer LAN:' -ForegroundColor Cyan
    foreach ($lan in $pcLans) {
        Write-Host ('  {0}/{1} gw={2} ({3})' -f $lan.Ip, $lan.PrefixLength, $(if ($lan.Gateway) { $lan.Gateway } else { '(none)' }), $lan.Adapter)
    }

    Write-Host '[altserver-subnet] Probing phone LAN IP (USB identify, then pcapd on en0)...'

    function Show-PhoneProbe([object] $Probe) {
        if ($Probe.Ip) {
            $src = if ($Probe.Source) { $Probe.Source } else { 'unknown' }
            Write-Host ('[altserver-subnet] Phone LAN IP: {0} (source={1})' -f $Probe.Ip, $src) -ForegroundColor Cyan
        } else {
            $gw = [string]$Probe.GatewayHint
            if (-not [string]::IsNullOrWhiteSpace($gw)) {
                Write-Host ('[altserver-subnet] Phone LAN IP: (none) exit={0}; AP hint {1}' -f $Probe.ExitCode, $gw)
            } else {
                Write-Host ('[altserver-subnet] Phone LAN IP: (none) exit={0}' -f $Probe.ExitCode)
            }
            if ($Probe.Error) {
                Write-Host $Probe.Error -ForegroundColor DarkGray
            }
        }
    }

    function Resolve-PhoneProbe([object] $Raw) {
        if ($Raw.Ip -and (Test-IsKnownRouterIp -Ip $Raw.Ip -RouterIps $knownRouterIps)) {
            Write-Host ('[altserver-subnet] Ignoring pcapd IP {0} (that is an AP/gateway ROUTER_IP, not the phone).' -f $Raw.Ip) -ForegroundColor DarkGray
            if ([string]::IsNullOrWhiteSpace([string]$Raw.GatewayHint)) {
                $Raw.GatewayHint = $Raw.Ip
            }
            $Raw.Ip = $null
        }
        return $Raw
    }

    function Get-ApHintIp([object] $Probe, [string] $Fallback = '') {
        if ($Probe.Ip) { return [string]$Probe.Ip }
        if (-not [string]::IsNullOrWhiteSpace([string]$Probe.GatewayHint)) { return [string]$Probe.GatewayHint }
        return $Fallback
    }

    $probe = Resolve-PhoneProbe (Get-IphoneLanIpv4 -PyExe $py)
    Show-PhoneProbe $probe
    if ($probe.ExitCode -eq 2) {
        Write-Host '[altserver-subnet] No USB iPhone (plug in, Trust This Computer, unlock).' -ForegroundColor Yellow
        Exit-WithEnter 2
    }
    if (-not $probe.Ip -and [string]::IsNullOrWhiteSpace([string]$probe.GatewayHint) -and ($probe.ExitCode -eq 4 -or $probe.ExitCode -eq 0)) {
        Write-Host '[altserver-subnet] USB iPhone present but no Wi-Fi IPv4 from pcapd (no AP hint either).' -ForegroundColor Yellow
        Exit-WithEnter 4
    }

    $round = 0
    $lastKnownIp = Get-ApHintIp $probe
    while ($true) {
        if ($probe.Ip) {
            $lastKnownIp = [string]$probe.Ip
            $match = Test-PhoneOnPcSubnet -PhoneIp $probe.Ip -PcLans $pcLans -PrefixOverride $PrefixLength
            if ($match) {
                Write-Host ('[altserver-subnet] OK - phone {0} shares subnet with PC/AltServer {1}/{2} ({3}).' -f `
                    $probe.Ip, $match.Ip, $match.PrefixLength, $match.Adapter) -ForegroundColor Green
                Exit-WithEnter 0
            }
            Write-Host ('[altserver-subnet] Phone {0} is NOT on a PC/AltServer subnet.' -f $probe.Ip) -ForegroundColor Yellow
        } else {
            Write-Host '[altserver-subnet] Phone has no Wi-Fi IPv4 yet (USB ok; pcapd empty).' -ForegroundColor Yellow
            $lastKnownIp = Get-ApHintIp $probe $lastKnownIp
            if ($lastKnownIp) {
                Write-Host ('[altserver-subnet] Using {0} to pick the AP (phone host IP missing; AP/.1 from pcapd is enough).' -f $lastKnownIp)
            }
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
        $ipForAp = Get-ApHintIp $probe $lastKnownIp
        $phoneTarget = $null
        if ($ipForAp) {
            $phoneTarget = Find-RebootScriptForIp -PhoneIp $ipForAp -ScriptsRoot $RebootScriptsRoot -PrefixLen $prefixForMatch
        }
        $pcTarget = Find-RebootScriptForPcGateway -PcLans $pcLans -ScriptsRoot $RebootScriptsRoot -PrefixLen $prefixForMatch

        $candidates = [System.Collections.Generic.List[object]]::new()
        if ($phoneTarget) {
            [void]$candidates.Add([pscustomobject]@{
                    RouterIp = $phoneTarget.RouterIp
                    Model    = $phoneTarget.Model
                    Script   = $phoneTarget.Script
                    Role     = 'phone-ap'
                })
        }
        if ($pcTarget -and (-not $phoneTarget -or ($pcTarget.RouterIp -ne $phoneTarget.RouterIp))) {
            [void]$candidates.Add([pscustomobject]@{
                    RouterIp = $pcTarget.RouterIp
                    Model    = $pcTarget.Model
                    Script   = $pcTarget.Script
                    Role     = 'pc-gateway'
                })
        }

        $reachable = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $candidates) {
            if (Test-WifiRestartTargetReachable -Target $c) {
                [void]$reachable.Add($c)
            }
        }
        if ($reachable.Count -eq 0) {
            Write-Warning @"
[altserver-subnet] No tcp/23 answer from phone AP or this PC's gateway under $RebootScriptsRoot
(need wifi_dx_common_*.py ROUTER_IP -> telnet_reboot_wlan_*.py).
Phone IP: $(if ($ipForAp) { $ipForAp } else { '(unknown)' })
"@
            # Let Loop Segments recover fall back to LAN-page wait + off-subnet reboots.
            Exit-WithEnter 4
        }

        $idx = 0
        $target = $reachable[$idx]
        $why = if ($target.Role -eq 'pc-gateway') { 'PC gateway' } else { 'phone AP' }
        Write-Host ('[altserver-subnet] Round {0}: WifiRestart {1} ({2}) via {3} so phone and PC/AltServer share a subnet...' -f `
            $round, $target.RouterIp, $target.Model, $why) -ForegroundColor Cyan
        $rebootCode = Invoke-RouterWifiRestart -Target $target -PyExe $py
        while ($rebootCode -ne 0 -and ($idx + 1) -lt $reachable.Count) {
            $idx++
            $next = $reachable[$idx]
            Write-Host ('[altserver-subnet] WifiRestart {0} ({1}) failed (exit {2}); trying {3} ({4}) the same way.' -f `
                $target.RouterIp, $target.Model, $rebootCode, $next.RouterIp, $next.Model) -ForegroundColor Yellow
            $target = $next
            $rebootCode = Invoke-RouterWifiRestart -Target $target -PyExe $py
        }
        if ($rebootCode -ne 0) {
            throw ("Reboot script failed (exit {0}): {1}" -f $rebootCode, $target.Script)
        }

        $pcLans = @(Get-PcLanIdentities)
        $previousIp = if ($probe.Ip) { $probe.Ip } elseif ($lastKnownIp) { $lastKnownIp } else { '' }
        $pcHint = @($pcLans | ForEach-Object { '{0}/{1}' -f $_.Ip, $_.PrefixLength }) -join ', '
        Write-Host ('[altserver-subnet] Waiting up to {0}s after WifiRestart for the phone to leave {1} and join a PC/AltServer subnet ({2}); each poll is USB pcapd (~8s). Same off-subnet stops this wait early, then the next round can bounce that AP again.' -f `
            $WaitPhoneIpSec, $(if ($previousIp) { $previousIp } else { '(no ip)' }), $pcHint)
        $deadline = [datetime]::UtcNow.AddSeconds($WaitPhoneIpSec)
        $gotFresh = $false
        $rejoinedSameAp = $false
        while ([datetime]::UtcNow -lt $deadline) {
            $left = [int][Math]::Max(0, [Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalSeconds))
            Write-Host ('[altserver-subnet] Re-probe ({0}s left; last {1}; want PC subnet)...' -f $left, $(if ($previousIp) { $previousIp } else { '(none)' }))
            Start-Sleep -Seconds $PollSec
            $pcLans = @(Get-PcLanIdentities)
            $probe = Resolve-PhoneProbe (Get-IphoneLanIpv4 -PyExe $py)
            if (-not $probe.Ip) {
                $hint = Get-ApHintIp $probe $lastKnownIp
                if ($hint) { $lastKnownIp = $hint }
                continue
            }
            $changed = [string]::IsNullOrWhiteSpace($previousIp) -or ($probe.Ip -ne $previousIp)
            $match = Test-PhoneOnPcSubnet -PhoneIp $probe.Ip -PcLans $pcLans -PrefixOverride $PrefixLength
            $stillOnOldAp = $false
            if ($previousIp) {
                $stillOnOldAp = Test-SameIpv4Subnet -IpA $probe.Ip -IpB $previousIp -PrefixLen $prefixForMatch
            }
            Write-Host ('[altserver-subnet] Probe IP={0} changed={1} onPcSubnet={2} sameOffSubnet={3}' -f `
                $probe.Ip, $changed, [bool]$match, $stillOnOldAp)
            if ($match) {
                Write-Host ('[altserver-subnet] OK - phone {0} now shares subnet with PC/AltServer {1}.' -f $probe.Ip, $match.Ip) -ForegroundColor Green
                Exit-WithEnter 0
            }
            if ($stillOnOldAp) {
                Write-Host '[altserver-subnet] Phone is back on the same off-subnet AP (WifiRestart does not change iOS SSID).' -ForegroundColor Yellow
                $rejoinedSameAp = $true
                $lastKnownIp = [string]$probe.Ip
                break
            } elseif ($changed) {
                $gotFresh = $true
            }
            $lastKnownIp = [string]$probe.Ip
        }
        if ($rejoinedSameAp) {
            Write-Host @"
[altserver-subnet] Phone stayed on $($probe.Ip) after WifiRestart of $($target.RouterIp) ($($target.Model)).
iOS rejoined that SSID (DHCP may change, e.g. .95 -> .29). Stopping this wait and retrying that AP.
"@ -ForegroundColor Yellow
        }
        if (-not $gotFresh) {
            Write-Warning '[altserver-subnet] Timed out waiting for a new phone IP - re-checking.'
        }
        $probe = Resolve-PhoneProbe (Get-IphoneLanIpv4 -PyExe $py)
        Show-PhoneProbe $probe
        $lastKnownIp = Get-ApHintIp $probe $lastKnownIp
    }
} catch {
    if ("$($_.Exception.Message)" -match '^ALTSERVER_SUBNET_EXIT:') { throw }
    Write-Host ""
    Write-Host ('[altserver-subnet] {0}' -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Exit-WithEnter 1
}
