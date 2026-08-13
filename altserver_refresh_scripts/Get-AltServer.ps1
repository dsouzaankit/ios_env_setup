#Requires -Version 5.1
<#
.SYNOPSIS
  Locate / start / status helpers for AltServer on this PC.

.DESCRIPTION
  Dot-source only. For a direct run with Enter wait, use
  Invoke-AltServerIfNeeded.ps1.

  Finds AltServer.exe, reports whether it is running, and can start it.
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

function Test-AltServerRunning {
    return [bool]@(Get-Process -Name 'AltServer' -ErrorAction SilentlyContinue).Count
}

function Start-AltServer {
    param(
        [int] $WaitSeconds = 3
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

    if (Test-AltServerRunning) {
        Write-Host "[altserver] Already running: $path"
        return [pscustomobject]@{
            Installed = $true
            Running   = $true
            Path      = $path
            Started   = $false
        }
    }

    Write-Host "[altserver] Starting AltServer: $path"
    try {
        Start-Process -FilePath $path | Out-Null
    } catch {
        Write-Warning "[altserver] Start failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            Installed = $true
            Running   = $false
            Path      = $path
            Started   = $false
        }
    }

    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $WaitSeconds))
    while ([datetime]::UtcNow -lt $deadline) {
        if (Test-AltServerRunning) { break }
        Start-Sleep -Milliseconds 400
    }
    $running = Test-AltServerRunning
    if ($running) {
        Write-Host '[altserver] Started OK'
    } else {
        Write-Warning '[altserver] Process not seen yet; continuing anyway'
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
        [switch] $EnsureStarted
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
    if ($EnsureStarted -and -not $running) {
        $startResult = Start-AltServer -WaitSeconds 4
        $running = [bool]$startResult.Running
        $started = [bool]$startResult.Started
    }

    if ($AlwaysStatus) {
        if ($running) {
            if ($started) {
                Write-Host "[altserver] Started: $path"
            } else {
                Write-Host "[altserver] Running: $path"
            }
        } else {
            Write-Host "[altserver] Installed but not running: $path" -ForegroundColor DarkYellow
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
