# iOS PC env_setup

Shared Windows helpers for iOS sideloading / AltServer / phone LAN. Used as a Git submodule from apps such as [ios_3d_loop_segments](https://github.com/dsouzaankit/ios_3d_loop_segments).

## Layout

| Path | Role |
|------|------|
| `altserver_refresh/` | Locate/start AltServer; phone Wi-Fi IPv4 via USB + USB pcapd; WifiRestart if off-subnet. Layout: `lib/`, `sideload/`, `usb/`, `lan/`, `VpnMulticast/` ([altserver_refresh/README.md](altserver_refresh/README.md)) |
| `Clash/` | Clash Verge / mihomo **profiles** only ([Clash/README.md](Clash/README.md)). Multicast drop is `altserver_refresh/VpnMulticast/`. |
| `ign/setup-ios-webview-debug.ps1` / `ign/start-ios-webview-debug.ps1` | WKWebView inspector helpers (kit is local under `ign/`, not in this repo) |

Apple iCloud/iTunes installers and `altinstaller/` stay on the machine only (gitignored).

Clone into Loop Segments as submodule **`env_setup/`** (`git clone --recurse-submodules` / `git submodule update --init`). A sibling checkout at `P:\all_scripts\iOS apps\env_setup` is the fallback if the submodule is missing.

## AltServer

```powershell
pwsh -File .\altserver_refresh\sideload\Invoke-AltServerIfNeeded.ps1
pwsh -File .\altserver_refresh\lan\Invoke-AltServerPhoneSubnetIfNeeded.ps1
```

Direct runs wait for Enter. Child callers: `-NoWaitEnter`. See `altserver_refresh/README.md`.

To run those helpers on each iPhone USB plug-in: `pwsh -File .\altserver_refresh\usb\Register-IphoneUsbAltServer.ps1` (creates `IosEnv-AltServer-UsbWatch` + `IosEnv-Vpn-RemoveMulticast`; AltServer tray start uses `IosEnv-AltServer-TrayKick`). Task list: `altserver_refresh/README.md` (Scheduled tasks).

AltStore IPA neighbors (`ios_3d_loop_segments\deploy.ps1`, `web_auto_parking\deploy.ps1`) dot-source `altserver_refresh\lib\Join-AltStoreDeployPrep.ps1` so deploy starts AltServer (phone-subnet check stays on USB plug-in). Pythonista zip deploys do not.
