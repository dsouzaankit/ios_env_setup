# iOS PC env_setup

Shared Windows helpers for iOS sideloading / AltServer / phone LAN. Used as a Git submodule from apps such as [ios_3d_loop_segments](https://github.com/dsouzaankit/ios_3d_loop_segments).

## Layout

| Path | Role |
|------|------|
| `altserver_refresh_script/` | Locate/start AltServer; put the iPhone on the same LAN subnet as this PC |
| `setup-ios-webview-debug.ps1` / `start-ios-webview-debug.ps1` | WKWebView inspector helpers (kit is local, not in this repo) |
| `app_refresh_script/` | Placeholder |

Apple iCloud/iTunes installers and `altinstaller/` stay on the machine only (gitignored).

## AltServer

```powershell
pwsh -File .\altserver_refresh_script\Invoke-AltServerIfNeeded.ps1
pwsh -File .\altserver_refresh_script\Invoke-AltServerPhoneSubnetIfNeeded.ps1
```

Direct runs wait for Enter. Child callers: `-NoWaitEnter`. See `altserver_refresh_script/README.md`.
