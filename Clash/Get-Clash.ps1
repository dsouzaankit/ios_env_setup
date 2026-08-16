#Requires -Version 5.1
<#
.SYNOPSIS
  Detect Clash / mihomo and drop its TUN 224.0.0.0/4 route (Bonjour/mDNS).

.DESCRIPTION
  Dot-source from Loop Segments companion or run Remove-MihomoMulticastRoute.ps1.
  Clash Verge / mihomo TUN often installs an on-link 224.0.0.0/4 on the Mihomo
  NIC (198.18.0.1) with a better metric than Wi-Fi, so mobdev2 stays empty.
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

function Get-ClashDir {
    $PSScriptRoot
}

function Get-ClashRemoveMulticastRouteScript {
    Join-Path $PSScriptRoot 'Remove-MihomoMulticastRoute.ps1'
}

function Get-ClashRemoveMulticastRouteTaskName {
    'IosEnv-Clash-RemoveMihomoMulticast'
}

function Get-ClashRegisterMulticastTaskScript {
    Join-Path $PSScriptRoot 'Register-ClashRemoveMulticastRouteTask.ps1'
}

function Start-ClashRegisterMulticastTaskElevated {
    param([switch] $Unregister)
    $reg = Get-ClashRegisterMulticastTaskScript
    if (-not (Test-Path -LiteralPath $reg)) {
        throw "Missing $reg"
    }
    if (Test-ClashProcessElevated) {
        if ($Unregister) {
            [void](Unregister-ClashRemoveMulticastRouteTask)
            return $null
        }
        return Register-ClashRemoveMulticastRouteTask
    }
    Write-Host '[clash] UAC once to register IosEnv-Clash-RemoveMihomoMulticast (highest; not every USB plug-in)...'
    $pwsh = Get-ClashPwshExe
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$reg`""
    if ($Unregister) { $arg = "$arg -Unregister" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh
    $psi.Arguments = $arg
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $p) { throw 'elevated process did not start' }
        if (-not $p.WaitForExit(120000)) {
            throw 'elevated register still running after 120s'
        }
        if ($p.ExitCode -ne 0) {
            throw ("elevated register exit {0}" -f $p.ExitCode)
        }
    } catch {
        throw $_
    }
    if ($Unregister) { return $null }
    $name = Get-ClashRemoveMulticastRouteTaskName
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) {
        throw 'elevated multicast task was not created (UAC canceled?)'
    }
    return $name
}

function Register-ClashRemoveMulticastRouteTask {
    $script = Get-ClashRemoveMulticastRouteScript
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing $script"
    }
    $pwsh = Get-ClashPwshExe
    $name = Get-ClashRemoveMulticastRouteTaskName
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg -WorkingDirectory (Get-ClashDir)
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date -Year 2099 -Month 1 -Day 1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    try { $settings.MultipleInstances = 'IgnoreNew' } catch {}
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    return $name
}

function Unregister-ClashRemoveMulticastRouteTask {
    $name = Get-ClashRemoveMulticastRouteTaskName
    $existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        return $true
    }
    return $false
}

function Start-ClashRemoveMulticastRouteTask {
    $name = Get-ClashRemoveMulticastRouteTaskName
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
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

function Get-ClashMihomoTunAddresses {
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

function Get-ClashMihomoTunInterfaceIndexes {
    $idxs = [System.Collections.Generic.List[int]]::new()
    foreach ($a in @(Get-ClashMihomoTunAddresses)) {
        if ($null -eq $a) { continue }
        $prop = $a.PSObject.Properties['InterfaceIndex']
        if ($null -eq $prop -or $null -eq $prop.Value) { continue }
        $idx = [int]$prop.Value
        if ($idx -gt 0 -and -not ($idxs -contains $idx)) { [void]$idxs.Add($idx) }
    }
    return @($idxs.ToArray())
}

function Test-ClashMulticastRoutePresent {
    foreach ($idx in @(Get-ClashMihomoTunInterfaceIndexes)) {
        $r = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $idx -ErrorAction SilentlyContinue)
        if ($r.Count -gt 0) { return $true }
    }
    return $false
}

function Test-ClashProcessElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = [Security.Principal.WindowsPrincipal]$id
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-ClashPwshExe {
    if (Get-Command Get-LoopSegmentsPwshExe -ErrorAction SilentlyContinue) {
        try { return Get-LoopSegmentsPwshExe } catch {}
    }
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Start-ClashRemoveMulticastRouteElevated {
    $script = Get-ClashRemoveMulticastRouteScript
    if (-not (Test-Path -LiteralPath $script)) {
        Write-Warning "[clash] Missing $script"
        return [pscustomobject]@{ Removed = 0; Present = $true; Elevated = $false }
    }
    if (Test-ClashProcessElevated) {
        return Invoke-ClashRemoveMulticastRoute
    }
    if (-not (Test-ClashMulticastRoutePresent)) {
        Write-Host '[clash] No 224.0.0.0/4 on Mihomo - skip elevation'
        return [pscustomobject]@{ Removed = 0; Present = $false; Elevated = $false }
    }
    Write-Host '[clash] UAC for Remove-MihomoMulticastRoute.ps1 only (companion stays unelevated)...'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-ClashPwshExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    $psi.UseShellExecute = $true
    $psi.Verb = 'runas'
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $p) { throw 'elevated process did not start' }
        if (-not $p.WaitForExit(60000)) {
            Write-Warning '[clash] Elevated route fix still running after 60s'
        }
    } catch {
        Write-Warning ("[clash] Elevation canceled or failed: {0}" -f $_.Exception.Message)
        Write-Warning "[clash] Run elevated: pwsh -File `"$script`""
    }
    return [pscustomobject]@{
        Removed  = 0
        Present  = (Test-ClashMulticastRoutePresent)
        Elevated = $true
    }
}

function Invoke-ClashRemoveMulticastRoute {
    if (-not (Test-ClashProcessElevated)) {
        return [pscustomobject]@{ Removed = 0; Present = (Test-ClashMulticastRoutePresent); NeedElevation = $true }
    }
    $idxs = @(Get-ClashMihomoTunInterfaceIndexes)
    if ($idxs.Count -eq 0) {
        Write-Host '[clash] No Mihomo/Clash TUN IPv4 found (TUN off?).'
        return [pscustomobject]@{ Removed = 0; Present = $false }
    }
    $removed = 0
    foreach ($idx in $idxs) {
        $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '224.0.0.0/4' -InterfaceIndex $idx -ErrorAction SilentlyContinue)
        foreach ($r in $routes) {
            try {
                Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -InterfaceIndex $idx -Confirm:$false -ErrorAction Stop
                $removed++
                Write-Host ("[clash] Removed 224.0.0.0/4 on if {0} ({1})" -f $idx, $r.InterfaceAlias)
            } catch {
                Write-Warning ("[clash] Could not remove 224.0.0.0/4 on if {0}: {1}" -f $idx, $_.Exception.Message)
            }
        }
    }
    $still = Test-ClashMulticastRoutePresent
    if ($removed -eq 0 -and -not $still) {
        Write-Host '[clash] No 224.0.0.0/4 route on Mihomo (already clear).'
    }
    return [pscustomobject]@{ Removed = $removed; Present = $still }
}

function Invoke-ClashFixBonjourAfterMulticast {
    $route = Invoke-ClashRemoveMulticastRoute
    $metricSet = $false
    try {
        $ifs = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
                [string]$_.InterfaceAlias -match '(?i)mihomo'
            })
        foreach ($i in $ifs) {
            try {
                Set-NetIPInterface -InterfaceIndex $i.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric 9999 -ErrorAction Stop
                $metricSet = $true
                Write-Host ("[clash] Mihomo if {0} metric -> 9999 (Bonjour prefers Wi-Fi)" -f $i.InterfaceIndex)
            } catch {
                Write-Warning ("[clash] Could not set Mihomo metric: {0}" -f $_.Exception.Message)
            }
        }
    } catch {}
    $bonjour = $false
    try {
        $svc = Get-Service -Name 'Bonjour Service' -ErrorAction Stop
        if ($svc) {
            Restart-Service -Name 'Bonjour Service' -Force -ErrorAction Stop
            $bonjour = $true
            Write-Host '[clash] Restarted Bonjour Service so mDNSResponder rebinds off 198.18.0.1'
        }
    } catch {
        Write-Warning ("[clash] Could not restart Bonjour Service: {0}" -f $_.Exception.Message)
    }
    return [pscustomobject]@{
        Removed     = $route.Removed
        Present     = (Test-ClashMulticastRoutePresent)
        MetricSet   = $metricSet
        BonjourRestarted = $bonjour
    }
}

function Write-ClashMdnsNotice {
    param([switch] $FixRoute)

    if (-not (Test-ClashRunning)) { return $false }
    $script = Get-ClashRemoveMulticastRouteScript
    Write-Host "[clash] Clash/mihomo is running. TUN can steal Bonjour (224.0.0.0/4 on Mihomo)."
    Write-Host "[clash] Fix script (UAC this file only): $script"
    if ($FixRoute) {
        $r = Start-ClashRemoveMulticastRouteElevated
        if ($r.Present) {
            Write-Warning '[clash] Multicast still on Mihomo after elevation attempt.'
        }
    }
    return $true
}
