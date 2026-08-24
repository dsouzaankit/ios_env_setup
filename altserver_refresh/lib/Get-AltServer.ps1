#Requires -Version 5.1
<#
.SYNOPSIS
  Locate / start / status helpers for AltServer on this PC.

.DESCRIPTION
  Dot-source only. For a direct run with Enter wait, use
  Invoke-AltServerIfNeeded.ps1.

  Finds AltServer.exe and treats it as running only when a single instance
  is in this desktop session and was started after Explorer. A process in
  Task Manager is not enough: Explorer restarts drop the tray icon, and a
  second AltServer.exe often never shows one.
#>

function Get-AltServerPath {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'AltServer\AltServer.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'AltServer\AltServer.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs\AltServer\AltServer.exe')
        (Join-Path $env:LOCALAPPDATA 'AltServer\AltServer.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    $roots = @($env:LOCALAPPDATA, ${env:ProgramFiles})
    if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $found = Get-ChildItem -Path $root -Filter 'AltServer.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-AltServerProcess {
    return @(Get-Process -Name 'AltServer' -ErrorAction SilentlyContinue)
}

function Get-CurrentSessionId {
    try { return [int](Get-Process -Id $PID).SessionId } catch { return $null }
}

function Get-AltServerUnhealthyReason {
    $procs = @(Get-AltServerProcess)
    if ($procs.Count -eq 0) { return 'not running' }
    $session = Get-CurrentSessionId
    $otherSession = @($procs | Where-Object { $null -ne $session -and [int]$_.SessionId -ne $session })
    if ($otherSession.Count -gt 0) {
        return ("process in session {0}, this desktop is {1}" -f $otherSession[0].SessionId, $session)
    }
    if ($procs.Count -gt 1) {
        return ("{0} AltServer.exe processes (stale extra instance; tray often missing)" -f $procs.Count)
    }
    $explorer = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
        Where-Object { $null -eq $session -or [int]$_.SessionId -eq $session } |
        Sort-Object StartTime)
    if ($explorer.Count -gt 0 -and $procs[0].StartTime -lt $explorer[0].StartTime) {
        return 'started before this Explorer session (tray icon dies when Explorer restarts)'
    }
    return $null
}

function Test-AltServerRunning {
    return [string]::IsNullOrWhiteSpace((Get-AltServerUnhealthyReason))
}

function Stop-AltServer {
    param([int] $WaitSeconds = 5)
    $procs = @(Get-AltServerProcess)
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
        } catch {}
    }
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $WaitSeconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (@(Get-AltServerProcess).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return (@(Get-AltServerProcess).Count -eq 0)
}

function Start-AltServerInteractive {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath
    )
    # Start-Process from a script/agent/hidden console does not create the
    # notification-area icon (process shows in Task Manager only). Kick a
    # "run only when user is logged on" task so Explorer gets the same
    # interactive launch as a Start Menu / double-click.
    $taskName = 'IosEnv-AltServer-TrayKick'
    $workDir = Split-Path -Parent $FilePath
    $action = New-ScheduledTaskAction -Execute $FilePath -WorkingDirectory $workDir
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    try {
        $settings.MultipleInstances = 'IgnoreNew'
    } catch {}
    # PS 5.1 cannot parse ISO '2099-01-01T00:00:00' (throws under $ErrorActionPreference Stop).
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date -Year 2099 -Month 1 -Day 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $old = Get-ScheduledTask -TaskName 'LoopSegments-AltServer-TrayKick' -ErrorAction SilentlyContinue
        if ($old) {
            Unregister-ScheduledTask -TaskName 'LoopSegments-AltServer-TrayKick' -Confirm:$false -ErrorAction SilentlyContinue
        }
        return 'interactive-task'
    } catch {
        Write-Host ("[altserver] Interactive task launch failed ({0}); trying Explorer ShellExecute." -f $_.Exception.Message) -ForegroundColor DarkYellow
    } finally {
        $ErrorActionPreference = $prev
    }

    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.ShellExecute($FilePath)
        return 'shell-execute'
    } catch {
        Start-Process -FilePath $FilePath -WorkingDirectory $workDir | Out-Null
        return 'start-process'
    }
}

function Start-AltServer {
    param(
        [int] $WaitSeconds = 10,
        [switch] $ForceRestart
    )

    $path = Get-AltServerPath
    if (-not $path) {
        Write-Host ""
        Write-Host '[altserver] NOT INSTALLED - cannot start it.' -ForegroundColor Yellow
        Write-Host 'Install AltServer: https://altstore.io' -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    if ($ForceRestart -and (@(Get-AltServerProcess).Count -gt 0)) {
        Write-Host '[altserver] Restarting so Bonjour re-advertises this PC Wi-Fi address...'
        if (-not (Stop-AltServer)) {
            Write-Warning '[altserver] Could not exit the existing AltServer process(es).'
            return [pscustomobject]@{
                Installed = $true
                Running   = $false
                Path      = $path
                Started   = $false
            }
        }
    }

    if (-not $ForceRestart -and (Test-AltServerRunning)) {
        Write-Host "[altserver] Already running (tray): $path"
        Write-Host '[altserver] If the icon is missing, check the hidden-icons overflow (^).' -ForegroundColor DarkGray
        return [pscustomobject]@{
            Installed = $true
            Running   = $true
            Path      = $path
            Started   = $false
        }
    }

    $reason = Get-AltServerUnhealthyReason
    $hadProcess = @(Get-AltServerProcess).Count -gt 0
    if ($hadProcess) {
        Write-Host ("[altserver] {0} - stopping and relaunching so the tray icon appears." -f $reason) -ForegroundColor Yellow
        if (-not (Stop-AltServer)) {
            Write-Warning '[altserver] Could not exit the existing AltServer process(es).'
            return [pscustomobject]@{
                Installed = $true
                Running   = $false
                Path      = $path
                Started   = $false
            }
        }
    }

    Write-Host "[altserver] Starting AltServer on this desktop (interactive): $path"
    $how = $null
    try {
        $how = Start-AltServerInteractive -FilePath $path
    } catch {
        Write-Warning "[altserver] Start failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            Installed = $true
            Running   = $false
            Path      = $path
            Started   = $false
        }
    }
    Write-Host ("[altserver] Launch method: {0}" -f $how) -ForegroundColor DarkGray

    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(2, $WaitSeconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-AltServerRunning) { break }
        Start-Sleep -Milliseconds 400
    }
    $running = Test-AltServerRunning
    if ($running) {
        Write-Host '[altserver] Started OK. Tray icon may be in the notification area or hidden-icons overflow (^).'
    } else {
        $left = @(Get-AltServerProcess).Count
        if ($left -gt 0) {
            Write-Warning ("[altserver] Process present but not usable ({0})." -f (Get-AltServerUnhealthyReason))
        } else {
            Write-Warning '[altserver] Process not seen yet; continuing anyway'
        }
    }
    return [pscustomobject]@{
        Installed = $true
        Running   = $running
        Path      = $path
        Started   = $true
    }
}

function Write-AltServerNotice {
    param(
        [switch] $AlwaysStatus,
        [switch] $EnsureStarted,
        [switch] $ForceRestart
    )

    $path = Get-AltServerPath
    if (-not $path) {
        Write-Host ""
        Write-Host '[altserver] NOT INSTALLED on this PC.' -ForegroundColor Yellow
        Write-Host 'Install AltServer: https://altstore.io' -ForegroundColor Yellow
        return [pscustomobject]@{
            Installed = $false
            Running   = $false
            Path      = $null
            Started   = $false
        }
    }

    $running = Test-AltServerRunning
    $started = $false
    if ($ForceRestart -or ($EnsureStarted -and -not $running)) {
        $startResult = Start-AltServer -WaitSeconds 10 -ForceRestart:$ForceRestart
        $running = [bool]$startResult.Running
        $started = [bool]$startResult.Started
    }

    if ($AlwaysStatus) {
        if ($running) {
            if ($started) {
                Write-Host "[altserver] Started (tray): $path"
            } else {
                Write-Host "[altserver] Running (tray): $path"
            }
            Write-Host '[altserver] If the icon is missing, check the hidden-icons overflow (^).' -ForegroundColor DarkGray
        } else {
            $reason = Get-AltServerUnhealthyReason
            Write-Host ("[altserver] Installed but not usable: {0}" -f $path) -ForegroundColor DarkYellow
            if ($reason) {
                Write-Host ("[altserver] {0}" -f $reason) -ForegroundColor DarkYellow
            }
            Write-Host '[altserver] Needed for AltStore refresh (free / Personal Team installs expire in ~7 days).' -ForegroundColor DarkYellow
        }
    }
    return [pscustomobject]@{
        Installed = $true
        Running   = $running
        Path      = $path
        Started   = $started
    }
}
