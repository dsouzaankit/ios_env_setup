<#
.SYNOPSIS
  Keep LAN traffic and router DNS names out of Clash Verge Rev's TUN / fake-IP.

.DESCRIPTION
  Clash Verge Rev's own config.yaml holds the TUN settings and overrides the profile's
  tun: section, so the profile's route-exclude-address never reaches the running core
  (clash-verge.yaml showed route-exclude-address: []). This script:

  1. config.yaml (Verge TUN settings): sets tun.route-exclude-address to the LAN ranges
     below, so 192.168.2.x / 10.0.100.x traffic and multicast stay on Wi-Fi.
  2. The current profile's Merge enhancement file: adds router domains to
     dns.fake-ip-filter (real answers, not 198.18.x.x), and a nameserver-policy that sends
     them to the Wi-Fi adapter's DHCP DNS server (the router), not 1.1.1.1 / 8.8.8.8.
     That also works when Windows has a manual 8.8.8.8 on the Wi-Fi profile.

  Clash Verge is quit before editing (it rewrites config.yaml from memory) and restarted
  after. Each edited file is backed up next to itself as *.bak-<timestamp>.

  The OS multicast route is a separate problem: see ..\altserver_refresh\VpnMulticast\.

.PARAMETER ExcludeAddress
  CIDRs to keep out of the TUN.

.PARAMETER RouterDomain
  DNS domains served by the LAN routers (Netgear MR6500 / MR5100: routerlogin.net).

.PARAMETER DhcpInterface
  Adapter whose DHCP-provided DNS answers RouterDomain (mihomo dhcp://<name>).

.PARAMETER NoRestart
  Edit the files but don't quit or start Clash Verge (it must already be closed).

.EXAMPLE
  pwsh -File .\Set-ClashLanExceptions.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$ExcludeAddress = @('224.0.0.0/4', 'ff02::/16', '10.0.100.0/24', '192.168.2.0/24'),
    [string[]]$RouterDomain = @('routerlogin.net'),
    [string]$DhcpInterface = 'Wi-Fi',
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'

$vergeDir = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$configPath = Join-Path $vergeDir 'config.yaml'
$profilesPath = Join-Path $vergeDir 'profiles.yaml'
$runtimePath = Join-Path $vergeDir 'clash-verge.yaml'
foreach ($p in $configPath, $profilesPath) {
    if (-not (Test-Path $p)) { throw "Clash Verge Rev file not found: $p" }
}

function Backup-ClashFile([string]$Path) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $Path "$Path.bak-$stamp" -Force
}

function Get-YamlScalar([string[]]$Lines, [string]$Key) {
    foreach ($l in $Lines) {
        if ($l -match "^$Key\s*:\s*(\S+)\s*$") { return $Matches[1].Trim("'`"") }
    }
    return $null
}

# Lines under `  <key>:` inside the top-level `<block>:` section (its list items or nested map).
function Get-YamlBlockText([string[]]$Lines, [string]$Block, [string]$Key) {
    $inBlock = $false; $inKey = $false
    foreach ($l in $Lines) {
        if ($l -match '^\S' -and $l -notmatch '^-') { $inBlock = ($l -match "^${Block}:"); $inKey = $false; continue }
        if (-not $inBlock) { continue }
        if ($l -match "^\s{2}${Key}\s*:") { $inKey = $true; continue }
        if ($inKey) {
            if ($l -match '^\s{2}-\s|^\s{4,}\S') { $l } else { $inKey = $false }
        }
    }
}

function Get-YamlBlockList([string[]]$Lines, [string]$Block, [string]$Key) {
    Get-YamlBlockText $Lines $Block $Key | Where-Object { $_ -match '^\s+-\s*(.+?)\s*$' } | ForEach-Object {
        ($_ -replace '^\s+-\s*', '').Trim().Trim("'`"")
    }
}

# Replace (or add) `  <key>:` plus its list items inside the top-level `<block>:` section.
function Set-YamlBlockList([string[]]$Lines, [string]$Block, [string]$Key, [string[]]$Items) {
    $out = [System.Collections.Generic.List[string]]::new()
    $newLines = @("  ${Key}:") + ($Items | ForEach-Object { "  - $_" })
    $blockStart = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match "^${Block}:\s*$") { $blockStart = $i; break } }
    if ($blockStart -lt 0) {
        $out.AddRange([string[]]$Lines)
        $out.Add("${Block}:")
        $out.AddRange([string[]]$newLines)
        return , $out.ToArray()
    }
    $blockEnd = $Lines.Count
    for ($i = $blockStart + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\S' -and $Lines[$i] -notmatch '^-') { $blockEnd = $i; break }
    }
    $keyAt = -1
    for ($i = $blockStart + 1; $i -lt $blockEnd; $i++) { if ($Lines[$i] -match "^\s{2}${Key}\s*:") { $keyAt = $i; break } }
    if ($keyAt -lt 0) {
        $out.AddRange([string[]]$Lines[0..$blockStart])
        $out.AddRange([string[]]$newLines)
        if ($blockStart + 1 -lt $Lines.Count) { $out.AddRange([string[]]$Lines[($blockStart + 1)..($Lines.Count - 1)]) }
        return , $out.ToArray()
    }
    # Old value: the key line plus following list items (`  - x` or deeper-indented lines).
    $skipTo = $keyAt + 1
    while ($skipTo -lt $blockEnd -and $Lines[$skipTo] -match '^\s{2}-\s|^\s{4,}\S') { $skipTo++ }
    if ($keyAt -gt 0) { $out.AddRange([string[]]$Lines[0..($keyAt - 1)]) }
    $out.AddRange([string[]]$newLines)
    if ($skipTo -lt $Lines.Count) { $out.AddRange([string[]]$Lines[$skipTo..($Lines.Count - 1)]) }
    return , $out.ToArray()
}

# --- which profile is active, and its Merge enhancement file ---
$profileLines = Get-Content $profilesPath
$current = Get-YamlScalar $profileLines 'current'
if (-not $current) { throw "No 'current' profile in $profilesPath" }
$mergeUid = $null
$inCurrent = $false
foreach ($l in $profileLines) {
    if ($l -match '^- uid:\s*(\S+)') { $inCurrent = ($Matches[1] -eq $current); continue }
    if ($inCurrent -and $l -match '^\s+merge:\s*(\S+)') { $mergeUid = $Matches[1]; break }
}
if (-not $mergeUid) { throw "Profile $current has no Merge enhancement in $profilesPath (open it once in Verge → Profiles → Extend Config)" }
$mergePath = Join-Path $vergeDir "profiles\$mergeUid.yaml"
$profilePath = Join-Path $vergeDir "profiles\$current.yaml"
Write-Host "[clash] profile $current, merge file $mergeUid.yaml"

# Merge replaces lists, so carry the profile's own fake-ip-filter entries over.
$filter = [System.Collections.Generic.List[string]]::new()
if (Test-Path $profilePath) {
    $inDns = $false; $inFilter = $false
    foreach ($l in Get-Content $profilePath) {
        if ($l -match '^\S') { $inDns = ($l -match '^dns:'); $inFilter = $false; continue }
        if ($inDns -and $l -match '^\s{2}fake-ip-filter:') { $inFilter = $true; continue }
        if ($inFilter) {
            if ($l -match '^\s+-\s*(.+?)\s*$') { $filter.Add($Matches[1].Trim("'`"")) } else { $inFilter = $false }
        }
    }
}
foreach ($d in '*.local', '+.local', '+.lan', 'localhost') { if (-not $filter.Contains($d)) { $filter.Add($d) } }
foreach ($d in $RouterDomain) { $e = "+.$d"; if (-not $filter.Contains($e)) { $filter.Add($e) } }

$mergeText = @(
    '# Profile Enhancement Merge Template for Clash Verge'
    '# Written by env_setup\Clash\Set-ClashLanExceptions.ps1: router names resolve via the router.'
    ''
    'dns:'
    '  fake-ip-filter:'
    ($filter | ForEach-Object { "    - '$_'" })
    '  nameserver-policy:'
    ($RouterDomain | ForEach-Object { "    '+.$_': 'dhcp://$DhcpInterface'" })
) -join "`n"

# --- quit Clash Verge so it doesn't overwrite config.yaml ---
$exe = $null
if (-not $NoRestart) {
    $gui = Get-Process clash-verge -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gui) { $exe = $gui.Path }
    if (-not $exe) { $exe = Join-Path $env:ProgramFiles 'Clash Verge\clash-verge.exe' }
    # Only the GUI writes config.yaml. The core (verge-mihomo) runs elevated under
    # clash_verge_service, can't be stopped from here, and gets the new config when the GUI starts.
    if ($PSCmdlet.ShouldProcess('Clash Verge', 'Quit')) {
        Get-Process clash-verge -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        if (Get-Process clash-verge -ErrorAction SilentlyContinue) {
            throw 'Clash Verge is still running (elevated?). Quit it from the tray, then rerun with -NoRestart.'
        }
    }
} elseif (Get-Process clash-verge -ErrorAction SilentlyContinue) {
    throw 'Clash Verge is running; quit it from the tray first (it rewrites config.yaml on exit).'
}

if ($PSCmdlet.ShouldProcess($configPath, "tun.route-exclude-address = $($ExcludeAddress -join ', ')")) {
    Backup-ClashFile $configPath
    $lines = Set-YamlBlockList (Get-Content $configPath) 'tun' 'route-exclude-address' $ExcludeAddress
    Set-Content -Path $configPath -Value $lines -Encoding utf8NoBOM
    Write-Host "[clash] config.yaml: tun.route-exclude-address = $($ExcludeAddress -join ', ')"
}
if ($PSCmdlet.ShouldProcess($mergePath, "dns fake-ip-filter + nameserver-policy for $($RouterDomain -join ', ')")) {
    if (Test-Path $mergePath) { Backup-ClashFile $mergePath }
    Set-Content -Path $mergePath -Value $mergeText -Encoding utf8NoBOM
    Write-Host "[clash] $mergeUid.yaml: fake-ip-filter + nameserver-policy dhcp://$DhcpInterface for $($RouterDomain -join ', ')"
}

if (-not $NoRestart -and $PSCmdlet.ShouldProcess('Clash Verge', 'Start')) {
    if (-not (Test-Path $exe)) { throw "Clash Verge executable not found: $exe — start it yourself." }
    Start-Process $exe
    Write-Host '[clash] Started Clash Verge; waiting for the running config...'
    $deadline = (Get-Date).AddSeconds(30)
    $started = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if ((Test-Path $runtimePath) -and (Get-Item $runtimePath).LastWriteTime -gt $started) { break }
    }
}

if (Test-Path $runtimePath) {
    $rtLines = Get-Content $runtimePath
    $rtExclude = Get-YamlBlockList $rtLines 'tun' 'route-exclude-address'
    $rtFilter = Get-YamlBlockList $rtLines 'dns' 'fake-ip-filter'
    $rtPolicy = (Get-YamlBlockText $rtLines 'dns' 'nameserver-policy') -join "`n"
    $okRoute = $ExcludeAddress | Where-Object { $rtExclude -notcontains $_ }
    $okDns = $RouterDomain | Where-Object { $rtFilter -notcontains "+.$_" -or $rtPolicy -notmatch [regex]::Escape("+.$_") }
    if ($okRoute -or $okDns) {
        Write-Warning "[clash] Running config (clash-verge.yaml) is missing: $((@($okRoute) + @($okDns)) -join ', '). Check Verge → Settings → TUN, and that the profile's Merge is enabled."
    } else {
        Write-Host '[clash] Running config has the LAN excludes and router DNS policy.'
    }
}
Write-Host '[clash] Multicast route (Bonjour) is separate: ..\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1 (elevated).'
