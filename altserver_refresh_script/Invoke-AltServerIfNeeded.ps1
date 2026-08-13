# Entry may start under Windows PowerShell 5.1; re-launch with pwsh.
#Requires -Version 5.1
<#
.SYNOPSIS
  Start AltServer on this PC if it is installed but not running.

.DESCRIPTION
  Dotsources Get-AltServer.ps1. Prints status and starts AltServer when idle.

  Direct run waits for Enter. Pass -NoWaitEnter when invoked as a child.

.EXAMPLE
  pwsh -File .\Invoke-AltServerIfNeeded.ps1
#>
[CmdletBinding()]
param(
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
    Write-Host ('[altserver] {0}' -f $_.Exception.Message) -ForegroundColor Red
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
$Core = Join-Path $ScriptDir 'Get-AltServer.ps1'
if (-not (Test-Path -LiteralPath $Core)) {
    throw "Missing $Core"
}
. $Core

try {
    $notice = Write-AltServerNotice -AlwaysStatus -EnsureStarted
    if (-not $notice.Installed) {
        Exit-WithEnter 2
    }
    if (-not $notice.Running) {
        Exit-WithEnter 1
    }
    Exit-WithEnter 0
} catch {
    Write-Host ""
    Write-Host ('[altserver] {0}' -f $_.Exception.Message) -ForegroundColor Red
    Exit-WithEnter 1
}
