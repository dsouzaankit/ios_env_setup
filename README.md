# iOS PC env_setup

Shared Windows helpers for iOS sideloading / AltServer / phone LAN. Cloned once **next to** the apps that use it (e.g. `P:\all_scripts\iOS apps\env_setup` beside [ios_3d_loop_segments](https://github.com/dsouzaankit/ios_3d_loop_segments) and web_auto_parking); they find it as `..\env_setup`.

## Layout

| Path | Role |
|------|------|
| `lan/` | Phone Wi‑Fi IPv4 via USB pcapd; phone↔PC subnet align + WifiRestart ([lan/](lan/)) |
| `altserver_refresh/` | Locate/start AltServer; USB watch; Clash multicast drop. Layout: `lib/`, `sideload/`, `usb/`, `VpnMulticast/` ([altserver_refresh/README.md](altserver_refresh/README.md)). AltStore + AltServer install / refresh guide shared by the apps: [altserver_refresh/ALTSTORE.md](altserver_refresh/ALTSTORE.md) |
| `sidestore/` | SideStore setup + troubleshooting shared by the sideloaded apps: LocalDevVPN, iloader reinstall / pairing, 0.7.0 errors, the Nov 2026 sign-in 503 workaround, Shortcuts refresh ([sidestore/README.md](sidestore/README.md)). The iloader `.msi` kept there is gitignored. |
| `zsign/` | PC signing with SideStore's exported certificate, so an app installs over USB without a tap: `SideStoreSigning.ps1`, `sidestore_sign.py` ([zsign/README.md](zsign/README.md)). `zsign.exe` and `signing.p12` live there too and are gitignored. |
| `Clash/` | Clash Verge / mihomo profiles, plus `Set-ClashLanExceptions.ps1`, which keeps LAN subnets and `routerlogin.net` names out of TUN / fake-IP ([Clash/README.md](Clash/README.md)). Multicast drop is `altserver_refresh/VpnMulticast/`. |
| `ign/setup-ios-webview-debug.ps1` / `ign/start-ios-webview-debug.ps1` | WKWebView inspector helpers (kit is local under `ign/`, not in this repo) |

Apple iCloud/iTunes installers and `altinstaller/` stay on the machine only (gitignored).

Not a submodule: keep **one** checkout next to the app repos (`git clone https://github.com/dsouzaankit/ios_env_setup.git env_setup` in their parent folder). The apps look for `..\env_setup`, then `P:\all_scripts\iOS apps\env_setup`.

## Phone LAN (USB)

```powershell
pwsh -File .\lan\Invoke-PhonePcSubnetIfNeeded.ps1
# reads Wi-Fi IPv4: .\lan\Get-IphoneLanIpv4.py
```

Does **not** start AltServer. Direct runs wait for Enter. Child callers: `-NoWaitEnter`. Details: `altserver_refresh/README.md` (Phone-subnet section points here).

## AltServer

```powershell
pwsh -File .\altserver_refresh\sideload\Invoke-AltServerIfNeeded.ps1
```

Direct runs wait for Enter. Child callers: `-NoWaitEnter`. See `altserver_refresh/README.md`.

To run AltServer + phone-subnet helpers on each iPhone USB plug-in: `pwsh -File .\altserver_refresh\usb\Register-IphoneUsbAltServer.ps1` (creates `IosEnv-AltServer-UsbWatch` + `IosEnv-Vpn-RemoveMulticast`; AltServer tray start uses `IosEnv-AltServer-TrayKick`). **SideStore** users can unregister those — refresh does not need AltServer (`altserver_refresh/README.md` Scheduled tasks).

AltStore IPA neighbors (`ios_3d_loop_segments\deploy.ps1`, `web_auto_parking\deploy.ps1`) can opt into `altserver_refresh\lib\Join-AltStoreDeployPrep.ps1` via **`-EnsureAltStorePrep`** (default skips — SideStore). Phone-subnet check stays on USB plug-in. Pythonista zip deploys do not.
