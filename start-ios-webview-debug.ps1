<#
.SYNOPSIS
  Start ios-safari-remote-debug-kit for inspecting WKWebView (e.g. Web Auto Parking).

.DESCRIPTION
  Requires USB, trusted device (Apple Devices / iTunes), and on the phone:
    Settings → Safari → Advanced → Web Inspector = ON

  Web Auto Parking opts in with WKWebView.isInspectable (rebuild/redeploy after that change).

  After start:
    1. Unlock the phone and open the in-app WebView page to inspect
    2. Open http://localhost:9222/ to list pages
    3. Open http://localhost:8080/Main.html?ws=localhost:9222/devtools/page/N
       (replace N with the Parking / WebView page id)

  Network/XHR panel usually fails on Windows iwdp ("Network domain was not found").
  Prefer the app LAN endpoint http://<phone-ip>:8765/xhr.txt for fetch/XHR bodies.

.NOTES
  Kit lives in: env_setup\ios-safari-remote-debug-kit
  First-time generate: .\setup-ios-webview-debug.ps1
#>
$ErrorActionPreference = "Stop"
Write-Host "Note: Web Inspector Network/XHR is often broken on Windows. Use phone:8765/xhr.txt instead."
$kitSrc = Join-Path $PSScriptRoot "ios-safari-remote-debug-kit\src"
$start = Join-Path $kitSrc "start.ps1"

if (-not (Test-Path (Join-Path $kitSrc "WebKit"))) {
    Write-Host "WebKit inspector not generated yet. Run setup-ios-webview-debug.ps1 first."
    exit 1
}

# Prefer real Python over Windows Store stub; start.ps1 looks for python3.exe.
if (-not (Get-Command python3.exe -ErrorAction SilentlyContinue)) {
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($py -and -not $py.Source.StartsWith([Environment]::GetFolderPath("LocalApplicationData") + "\Microsoft\WindowsApps\")) {
        $shimDir = Join-Path $env:TEMP "wap-python3-shim"
        New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
        $shim = Join-Path $shimDir "python3.exe"
        if (-not (Test-Path $shim)) {
            cmd /c mklink "$shim" "$($py.Source)" | Out-Null
        }
        $env:Path = "$shimDir;$env:Path"
        Write-Host "Using python.exe as python3 via temp shim"
    }
}

Set-Location $kitSrc
& $start @args
