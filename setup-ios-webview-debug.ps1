<#
.SYNOPSIS
  One-time (or update) generate for ios-safari-remote-debug-kit WebInspector files.

.PARAMETER FetchWebInspector
  Pass $true to force re-download WebKit inspector sources.
#>
[CmdletBinding()]
param(
    [object] $FetchWebInspector = $null,
    [string] $iOSVersion = "latest"
)

$ErrorActionPreference = "Stop"
$generate = Join-Path $PSScriptRoot "ios-safari-remote-debug-kit\src\generate.ps1"
if (-not (Test-Path $generate)) {
    Write-Host "Missing kit. Clone into env_setup\ios-safari-remote-debug-kit first."
    exit 1
}

Write-Host "Running generate.ps1 (iOSVersion=$iOSVersion)..."
$params = @{
    NoPause    = $true
    iOSVersion = $iOSVersion
}
if ($null -ne $FetchWebInspector) {
    $params.FetchWebInspector = [bool]$FetchWebInspector
}

& $generate @params
$code = $LASTEXITCODE
if ($code -ne 0 -and $null -eq $FetchWebInspector) {
    # Default generate exits 1 when WebKit already exists — that is OK.
    if (Test-Path (Join-Path $PSScriptRoot "ios-safari-remote-debug-kit\src\WebKit")) {
        Write-Host "WebKit already present. Use -FetchWebInspector `$true to refresh."
        exit 0
    }
    exit $code
}
if ($code -ne 0) { exit $code }

Write-Host "Done. Start with: .\start-ios-webview-debug.ps1"
