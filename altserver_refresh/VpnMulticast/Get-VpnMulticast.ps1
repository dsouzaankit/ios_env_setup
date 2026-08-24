#Requires -Version 5.1
<#
.SYNOPSIS
  Drop TUN/VPN 224.0.0.0/4 routes so Bonjour/mDNS stays on Wi-Fi.

.DESCRIPTION
  Dot-source from AltStore USB helpers or Loop Segments companion, or run
  Remove-VpnMulticastRoute.ps1 elevated.
  Clash Verge / mihomo TUN and Surfshark OpenVPN both install on-link
  224.0.0.0/4 with a better metric than Wi-Fi. Both are dropped without
  disconnecting the VPN. Clash process detection stays in Test-ClashRunning.
#>

function Test-ClashRunning {
    foreach ($n in @(
            'clash-verge'
            'verge-mihomo'
            'mihomo'
            'Clash for Windows'
            'clash-win64'
            'clash-core-service'
        )) {
        if (@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

function Get-VpnMulticastDir {
    $PSScriptRoot
}

function Get-VpnMulticastRouteScript {
    Join-Path $PSScriptRoot 'Remove-VpnMulticastRoute.ps1'
}

function Get-VpnMulticastRouteTaskName {
    'IosEnv-Vpn-RemoveMulticast'
}

function Get-VpnMulticastLegacyTaskNames {
    @('IosEnv-Clash-RemoveMihomoMulticast')
}

function Get-VpnMulticastRegisterTaskScript {
    Join-Path $PSScriptRoot 'Register-VpnMulticastRouteTask.ps1'
}

function Test-VpnProcessElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = [Security.Principal.WindowsPrincipal]$id
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-VpnMulticastPwshExe {
    if (Get-Command Get-LoopSegmentsPwshExe -ErrorAction SilentlyContinue) {
        try { return Get-LoopSegmentsPwshExe } catch {}
    }
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Start-VpnMulticastRegisterTaskElevated {
    param([switch] $Unregister)
    $reg = Get-VpnMulticastRegisterTaskScript
    if (-not (Test-Path -LiteralPath $reg)) {
        throw "Missing $reg"
    }
    if (Test-VpnProcessElevated) {
        if ($Unregister) {
            [void](Unregister-VpnMulticastRouteTask)
            return $null
        }
        return Register-VpnMulticastRouteTask
    }
    Write-Host '[mdns] UAC once to register IosEnv-Vpn-RemoveMulticast (highest; not every USB plug-in)...'
    $pwsh = Get-VpnMulticastPwshExe
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$reg`""
    if ($Unregister) { $arg = "$arg -Unregister" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $psi.Arguments = $arg
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $p) { throw 'elevated process did not start' }
    if (-not $p.WaitForExit(120000)) {
        throw 'elevated register still running after 120s'
    }
    if ($p.ExitCode -ne 0) {
        throw ("elevated register exit {0}" -f $p.ExitCode)
    }
    if ($Unregister) { return $null }
    $name = Get-VpnMulticastRouteTaskName
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) {
        throw 'elevated multicast task was not created (UAC canceled?)'
    }
    return $name
}

function Unregister-VpnMulticastRouteTask {
    $removed = $false
    foreach ($name in @((Get-VpnMulticastRouteTaskName) + @(Get-VpnMulticastLegacyTaskNames))) {
        $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            $removed = $true
        }
    }
    return $removed
}

function Register-VpnMulticastRouteTask {
    $script = Get-VpnMulticastRouteScript
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing $script"
    }
    foreach ($legacy in @(Get-VpnMulticastLegacyTaskNames)) {
        $old = Get-ScheduledTask -TaskName $legacy -ErrorAction SilentlyContinue
        if ($old) {
            Unregister-ScheduledTask -TaskName $legacy -Confirm:$false
        }
    }
    $pwsh = Get-VpnMulticastPwshExe
    $name = Get-VpnMulticastRouteTaskName
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg -WorkingDirectory (Get-VpnMulticastDir)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date -Year 2099 -Month 1 -Day 1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    try { $settings.MultipleInstances = 'IgnoreNew' } catch {}
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    return $name
}

function Start-VpnMulticastRouteTask {
    foreach ($name in @((Get-VpnMulticastRouteTaskName) + @(Get-VpnMulticastLegacyTaskNames))) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        Start-ScheduledTask -TaskName $name
        $deadline = [datetime]::UtcNow.AddSeconds(45)
        while ([datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $st = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($null -eq $st) { break }
            if ([string]$st.State -ne 'Running') { break }
        }
        return $true
    }
    return $false
}

function Get-MihomoTunAddresses {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ($null -eq $a) { continue }
        $ip = [string]$a.IPAddress
        $alias = [string]$a.InterfaceAlias
        if ($ip -eq '198.18.0.1' -or $alias -match '(?i)mihomo') {
            [void]$out.Add($a)
        }
    }
    return @($out.ToArray())
}

function Get-MihomoTunInterfaceIndexes {
    $idxs = [System.Collections.Generic.List[int]]::new()
    foreach ($a in @(Get-MihomoTunAddresses)) {
        if ($null -eq $a) { continue }
        $prop = $a.PSObject.Properties['InterfaceIndex']
        if ($null -eq $prop -or $null -eq $prop.Value) { continue }
        $idx = [int]$prop.Value
        if ($idx -gt 0 -and -not ($idxs -contains $idx)) { [void]$idxs.Add($idx) }
    }
    return @($idxs.ToArray())
}

function Test-MihomoMulticastRoutePresent {
    foreach ($idx in @(Get-MihomoTunInterfaceIndexes)) {
        $r = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $idx -ErrorAction SilentlyContinue)
        if ($r.Count -gt 0) { return $true }
    }
    return $false
}

function Get-SurfsharkInterfaceIndexes {
    $idxs = [System.Collections.Generic.List[int]]::new()
    try {
        $ifs = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                [string]$_.InterfaceAlias -match '(?i)surfshark'
            })
        foreach ($i in $ifs) {
            if ($null -eq $i) { continue }
            $idx = [int]$i.InterfaceIndex
            if ($idx -gt 0 -and -not ($idxs -contains $idx)) { [void]$idxs.Add($idx) }
        }
    } catch {}
    return @($idxs.ToArray())
}

function Test-SurfsharkMulticastRoutePresent {
    foreach ($idx in @(Get-SurfsharkInterfaceIndexes)) {
        $r = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $idx -ErrorAction SilentlyContinue)
        if ($r.Count -gt 0) { return $true }
    }
    return $false
}

function Test-LanMulticastHijackPresent {
    return (Test-MihomoMulticastRoutePresent) -or (Test-SurfsharkMulticastRoutePresent)
}

function Start-VpnMulticastRouteElevated {
    $script = Get-VpnMulticastRouteScript
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Warning "[mdns] Missing $script"
        return [pscustomobject]@{ Removed = 0; Present = $true; Elevated = $false }
    }
    if (Test-VpnProcessElevated) {
        return Invoke-VpnFixBonjourAfterMulticast
    }
    if (-not (Test-LanMulticastHijackPresent)) {
        Write-Host '[mdns] No 224.0.0.0/4 on Mihomo or Surfshark - skip elevation'
        return [pscustomobject]@{ Removed = 0; Present = $false; Elevated = $false }
    }
    Write-Host '[mdns] UAC for Remove-VpnMulticastRoute.ps1 only (companion stays unelevated)...'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-VpnMulticastPwshExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $p) { throw 'elevated process did not start' }
        if (-not $p.WaitForExit(60000)) {
            Write-Warning '[mdns] Elevated route fix still running after 60s'
        }
    } catch {
        Write-Warning ("[mdns] Elevation canceled or failed: {0}" -f $_.Exception.Message)
        Write-Warning "[mdns] Run elevated: pwsh -File `"$script`""
    }
    return [pscustomobject]@{
        Removed  = 0
        Present  = (Test-LanMulticastHijackPresent)
        Elevated = $true
    }
}

function Invoke-MihomoRemoveMulticastRoute {
    if (-not (Test-VpnProcessElevated)) {
        return [pscustomobject]@{ Removed = 0; Present = (Test-MihomoMulticastRoutePresent); NeedElevation = $true }
    }
    $idxs = @(Get-MihomoTunInterfaceIndexes)
    if ($idxs.Count -eq 0) {
        Write-Host '[mdns] No Mihomo/Clash TUN IPv4 found (TUN off?).'
        return [pscustomobject]@{ Removed = 0; Present = $false }
    }
    $removed = 0
    foreach ($idx in $idxs) {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $idx -ErrorAction SilentlyContinue)
        foreach ($r in $routes) {
            try {
                Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $idx -Confirm:$false -ErrorAction Stop
                $removed++
                Write-Host ("[mdns] Removed 224.0.0.0/4 on if {0} ({1})" -f $idx, $r.InterfaceAlias)
            } catch {
                Write-Warning ("[mdns] Could not remove 224.0.0.0/4 on if {0}: {1}" -f $idx, $_.Exception.Message)
            }
        }
    }
    $still = Test-MihomoMulticastRoutePresent
    if ($removed -eq 0 -and -not $still) {
        Write-Host '[mdns] No 224.0.0.0/4 route on Mihomo (already clear).'
    }
    return [pscustomobject]@{ Removed = $removed; Present = $still }
}

function Invoke-SurfsharkRemoveMulticastRoute {
    if (-not (Test-VpnProcessElevated)) {
        return [pscustomobject]@{ Removed = 0; Present = (Test-SurfsharkMulticastRoutePresent); NeedElevation = $true }
    }
    $idxs = @(Get-SurfsharkInterfaceIndexes)
    if ($idxs.Count -eq 0) {
        Write-Host '[mdns] No Surfshark IPv4 adapter (VPN off?).'
        return [pscustomobject]@{ Removed = 0; Present = $false }
    }
    $removed = 0
    foreach ($idx in $idxs) {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $idx -ErrorAction SilentlyContinue)
        foreach ($r in $routes) {
            try {
                Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $idx -Confirm:$false -ErrorAction Stop
                $removed++
                Write-Host ("[mdns] Removed 224.0.0.0/4 on Surfshark if {0} ({1})" -f $idx, $r.InterfaceAlias)
            } catch {
                Write-Warning ("[mdns] Could not remove Surfshark 224.0.0.0/4 on if {0}: {1}" -f $idx, $_.Exception.Message)
            }
        }
    }
    $still = Test-SurfsharkMulticastRoutePresent
    if ($removed -eq 0 -and -not $still) {
        Write-Host '[mdns] No 224.0.0.0/4 route on Surfshark (already clear).'
    }
    return [pscustomobject]@{ Removed = $removed; Present = $still }
}

function Invoke-VpnDropDisconnectedMulticastRoutes {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -ErrorAction SilentlyContinue)
    foreach ($r in $routes) {
        $alias = [string]$r.InterfaceAlias
        if ($alias -match '(?i)loopback') { continue }
        $ipif = @(Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $connected = @($ipif | Where-Object { [string]$_.ConnectionState -eq 'Connected' })
        if ($connected.Count -gt 0) { continue }
        try {
            Remove-NetRoute -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $r.InterfaceIndex -Confirm:$false -ErrorAction Stop
            Write-Host ("[mdns] Removed 224.0.0.0/4 on disconnected {0} (if {1})" -f $alias, $r.InterfaceIndex)
        } catch {
            Write-Warning ("[mdns] Could not remove 224.0.0.0/4 on disconnected {0}: {1}" -f $alias, $_.Exception.Message)
        }
    }
}

function Invoke-VpnFixBonjourAfterMulticast {
    $route = Invoke-MihomoRemoveMulticastRoute
    $surf = Invoke-SurfsharkRemoveMulticastRoute
    Invoke-VpnDropDisconnectedMulticastRoutes
    $metricSet = $false
    try {
        $ifs = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                [string]$_.InterfaceAlias -match '(?i)mihomo|surfshark'
            })
        foreach ($i in $ifs) {
            try {
                Set-NetIPInterface -InterfaceIndex $i.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric 9999 -ErrorAction Stop
                $metricSet = $true
                Write-Host ("[mdns] if {0} ({1}) metric -> 9999 (Bonjour prefers Wi-Fi)" -f $i.InterfaceIndex, $i.InterfaceAlias)
            } catch {
                Write-Warning ("[mdns] Could not set metric on {0}: {1}" -f $i.InterfaceAlias, $_.Exception.Message)
            }
        }
    } catch {}
    $bonjour = $false
    try {
        $svc = Get-Service -Name 'Bonjour Service' -ErrorAction Stop
        if ($svc) {
            Restart-Service -Name 'Bonjour Service' -Force -ErrorAction Stop
            $bonjour = $true
            Write-Host '[mdns] Restarted Bonjour Service so mDNSResponder rebinds off TUN/VPN'
        }
    } catch {
        Write-Warning ("[mdns] Could not restart Bonjour Service: {0}" -f $_.Exception.Message)
    }
    return [pscustomobject]@{
        Removed          = ([int]$route.Removed + [int]$surf.Removed)
        Present          = (Test-LanMulticastHijackPresent)
        MetricSet        = $metricSet
        BonjourRestarted = $bonjour
    }
}

function Write-VpnMdnsNotice {
    param([switch] $FixRoute)

    $hijack = Test-LanMulticastHijackPresent
    if (-not (Test-ClashRunning) -and -not $hijack) { return $false }
    $script = Get-VpnMulticastRouteScript
    Write-Host "[mdns] TUN/VPN can steal Bonjour (224.0.0.0/4 on Mihomo or Surfshark)."
    Write-Host "[mdns] Fix script (UAC this file only): $script"
    if ($FixRoute) {
        $r = Start-VpnMulticastRouteElevated
        if ($r.Present) {
            Write-Warning '[mdns] Multicast still on Mihomo or Surfshark after elevation attempt.'
        }
    }
    return $true
}