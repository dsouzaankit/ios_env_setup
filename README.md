# iOS PC env_setup

Shared Windows helpers for iOS sideloading / AltServer / phone LAN. Used as a Git submodule from apps such as [ios_3d_loop_segments](https://github.com/dsouzaankit/ios_3d_loop_segments).

## Layout

| Path | Role |
|------|------|
| `altserver_refresh_scripts/` | Locate/start AltServer; phone Wi-Fi IPv4 via USB + USB pcapd; reboot the phone’s AP if it is off the PC/AltServer subnet |
| `Clash/` | Clash Verge / mihomo profiles + optional elevated drop of TUN `224.0.0.0/4` for `.local` / other mDNS ([Clash/README.md](Clash/README.md)). Phone-IP probe does not need this. |
| `setup-ios-webview-debug.ps1` / `start-ios-webview-debug.ps1` | WKWebView inspector helpers (kit is local under `ign/`, not in this repo) |

Apple iCloud/iTunes installers and `altinstaller/` stay on the machine only (gitignored).

Clone into Loop Segments as submodule **`env_setup/`** (`git clone --recurse-submodules` / `git submodule update --init`). A sibling checkout at `P:\all_scripts\iOS apps\env_setup` is the fallback if the submodule is missing.

## AltServer

```powershell
pwsh -File .\altserver_refresh_scripts\Invoke-AltServerIfNeeded.ps1
pwsh -File .\altserver_refresh_scripts\Invoke-AltServerPhoneSubnetIfNeeded.ps1
```

Direct runs wait for Enter. Child callers: `-NoWaitEnter`. See `altserver_refresh_scripts/README.md`.

To run those helpers on each iPhone USB plug-in: `pwsh -File .\altserver_refresh_scripts\Register-IphoneUsbAltServer.ps1` (creates `IosEnv-AltServer-UsbWatch` + `IosEnv-Clash-RemoveMihomoMulticast`; AltServer tray start uses `IosEnv-AltServer-TrayKick`). Task list: `altserver_refresh_scripts/README.md` (Scheduled tasks).

AltStore IPA neighbors (`ios_3d_loop_segments\deploy.ps1`, `web_auto_parking\deploy.ps1`) dot-source `altserver_refresh_scripts\Join-AltStoreDeployPrep.ps1` so deploy starts AltServer and checks the phone subnet. Pythonista zip deploys do not.
