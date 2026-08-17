#Requires -Version 5.1
<#
.SYNOPSIS
  Dot-source from neighboring AltStore IPA deploy.ps1 scripts.

.DESCRIPTION
  Invoke-AltStoreDeployPrep starts AltServer (tray / interactive desktop) and
  clears Clash TUN multicast so AltStore can see AltServer. It does **not** run
  the USB pcapd phone-subnet check by default — Watch-IphoneUsbAltServer already
  does that on plug-in. Pass -CheckPhoneSubnet to run it here. Missing USB /
  no Wi-Fi IP only warns - iCloud AltStore install can still proceed. Sideload
  needs AltServer + same subnet (USB connect, or -CheckPhoneSubnet).

  Safe to call from Windows PowerShell 5.1 deploy.ps1 with $ErrorActionPreference
  Stop: AltServer start and Clash multicast run in a child pwsh so a 5.1 parse
  error cannot abort the IPA copy. Phone-subnet check is USB plug-in unless
  -CheckPhoneSubnet.

.EXAMPLE
  $join = @(
      (Join-Path $ProjectRoot 'env_setup\altserver_refresh\Join-AltStoreDeployPrep.ps1')
      'P:\all_scripts\iOS apps\env_setup\altserver_refresh\Join-AltStoreDeployPrep.ps1'
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
  if ($join) { . $join; Invoke-AltStoreDeployPrep }
  # Optional: Invoke-AltStoreDeployPrep -CheckPhoneSubnet
#>

# $PSScriptRoot is this file when dotted (PS 3+). $MyInvocation.MyCommand.Path
# is often the *caller* (deploy.ps1) and would miss Get-AltServer.ps1.
$script:IosAltRefreshDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Get-IosAltStorePrepPwsh {
    $cmd = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }
    foreach ($path in @(
            (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
            (Join-Path ${env:ProgramFiles(x86)} 'PowerShell\7\pwsh.exe')
            (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7\pwsh.exe')
        )) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

function Invoke-IosAltStorePrepChild {
    param(
        [Parameter(Mandatory = $true)][string] $PwshExe,
        [Parameter(Mandatory = $true)][string] $ScriptPath
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        # Write-Host so child stdout is not part of this function's return value
        # (otherwise "$code = Invoke-..." becomes the 'Running (tray): ...' line).
        & $PwshExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -NoWaitEnter 2>&1 |
            ForEach-Object { Write-Host ([string]$_) }
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match 'ALTSERVER_SUBNET_EXIT:(\d+)') {
            return [int]$Matches[1]
        }
        if ($msg -match 'ALTSERVER_EXIT:(\d+)') {
            return [int]$Matches[1]
        }
        Write-Warning ("[altserver] {0} threw: {1}" -f (Split-Path -Leaf $ScriptPath), $msg)
        return 1
    } finally {
        $ErrorActionPreference = $prev
    }
    return [int]$code
}

function Get-IosAltStorePrepExitCode {
    param($Value)
    $last = @($Value) | Select-Object -Last 1
    if ($last -is [int]) { return [int]$last }
    $s = [string]$last
    if ($s -match '^-?\d+$') { return [int]$s }
    return 1
}

function Get-IosAltStoreClashCore {
    $root = Split-Path -Parent $script:IosAltRefreshDir
    $core = Join-Path $root 'Clash\Get-Clash.ps1'
    if ($core -and (Test-Path -LiteralPath $core)) { return $core }
    return $null
}

function Invoke-IosAltStoreClashMdns {
    $core = Get-IosAltStoreClashCore
    if (-not $core) { return }
    . $core
    if (-not (Test-ClashRunning)) { return }
    Write-Host '[altserver] Clash/mihomo is running. Dropping TUN 224.0.0.0/4 so AltStore can find AltServer (Bonjour).'
    if (Test-ClashProcessElevated) {
        [void](Invoke-ClashFixBonjourAfterMulticast)
        return
    }
    $started = $false
    if (Get-Command Start-ClashRemoveMulticastRouteTask -ErrorAction SilentlyContinue) {
        $started = [bool](Start-ClashRemoveMulticastRouteTask)
    }
    if (-not $started -and (Get-Command Register-ClashRemoveMulticastRouteTask -ErrorAction SilentlyContinue)) {
        try {
            $mdnsName = Register-ClashRemoveMulticastRouteTask
            Write-Host ("[altserver] Registered elevated task {0}" -f $mdnsName)
            $started = [bool](Start-ClashRemoveMulticastRouteTask)
        } catch {
            Write-Warning ("[altserver] Could not register elevated multicast task: {0}" -f $_.Exception.Message)
        }
    }
    if ($started) {
        Start-Sleep -Seconds 2
        if (Test-ClashMulticastRoutePresent) {
            Write-Warning '[altserver] Elevated multicast task ran; 224.0.0.0/4 is still on Mihomo.'
        } else {
            Write-Host '[altserver] Mihomo multicast route clear. Retry AltStore Refresh All if it said AltServer not found.'
        }
        return
    }
    Write-Host '[altserver] Need elevation to drop Mihomo 224.0.0.0/4 (approve UAC)...'
    [void](Start-ClashRemoveMulticastRouteElevated)
    if (Test-ClashMulticastRoutePresent) {
        $script = Get-ClashRemoveMulticastRouteScript
        Write-Warning ("[altserver] AltStore will say AltServer not found until you run elevated: pwsh -File `"{0}`"" -f $script)
    } else {
        Write-Host '[altserver] Mihomo multicast route removed. Retry AltStore Refresh All.'
    }
}

function Invoke-AltStoreDeployPrep {
    param(
        [switch] $SkipPhoneSubnet,
        [switch] $CheckPhoneSubnet
    )

    Write-Host '==> AltStore deploy prep (AltServer tray; subnet is USB plug-in)'
    $dir = $script:IosAltRefreshDir
    $ifNeeded = Join-Path $dir 'Invoke-AltServerIfNeeded.ps1'
    $subnet = Join-Path $dir 'Invoke-AltServerPhoneSubnetIfNeeded.ps1'
    if (-not (Test-Path -LiteralPath $ifNeeded)) {
        Write-Warning "[altserver] Missing $ifNeeded (Join loaded from '$dir')"
        return
    }

    $pwsh = Get-IosAltStorePrepPwsh
    if (-not $pwsh) {
        Write-Warning '[altserver] pwsh (PowerShell 7) not found - skip AltStore prep. Install https://aka.ms/powershell'
        return
    }

    Write-Host '[altserver] Ensuring AltServer tray (child pwsh)...'
    $altCode = Get-IosAltStorePrepExitCode (Invoke-IosAltStorePrepChild -PwshExe $pwsh -ScriptPath $ifNeeded)
    if ($altCode -eq 0) {
        Write-Host '[altserver] AltServer is usable (tray / this desktop).'
    } elseif ($altCode -eq 2) {
        Write-Host '[altserver] AltServer is not installed - iCloud AltStore install still works.' -ForegroundColor DarkYellow
    } else {
        Write-Warning ("[altserver] Tray start did not confirm usable (exit {0}). Check the notification area / hidden icons (^)." -f $altCode)
    }

    Invoke-IosAltStoreClashMdns

    $wantSubnet = $CheckPhoneSubnet -and -not $SkipPhoneSubnet
    if (-not $wantSubnet) {
        if ($SkipPhoneSubnet) {
            Write-Host '[altserver] Skipping phone-subnet check (-SkipPhoneSubnet).'
        } else {
            Write-Host '[altserver] Skipping phone-subnet check (USB plug-in already does this; -CheckPhoneSubnet to run).'
        }
        return
    }
    if (-not (Test-Path -LiteralPath $subnet)) {
        Write-Warning "[altserver] Missing $subnet"
        return
    }

    Write-Host '[altserver] Phone LAN vs PC/AltServer subnet (USB pcapd)...'
    $code = Get-IosAltStorePrepExitCode (Invoke-IosAltStorePrepChild -PwshExe $pwsh -ScriptPath $subnet)
    if ($code -eq 0) {
        Write-Host '[altserver] Phone and PC/AltServer share a subnet (Wi-Fi sideload/refresh possible).'
        return
    }
    if ($code -eq 2 -or $code -eq 4) {
        Write-Host ("[altserver] Phone subnet not confirmed (exit {0}). iCloud AltStore install still works. USB sideload needs the phone on this PC's Wi-Fi." -f $code) -ForegroundColor DarkYellow
        return
    }
    Write-Warning ("[altserver] Phone-subnet refresh failed (exit {0})." -f $code)
}
