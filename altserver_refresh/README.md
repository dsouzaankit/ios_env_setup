# AltServer helpers

Role folders match Loop Segments `windows\`: shared helpers in **`lib\`**, USB watch in **`usb\`**, phone subnet in **`lan\`**, tray start in **`sideload\`**, multicast drop in **`VpnMulticast\`**.

| Folder | Role |
|--------|------|
| `lib/` | `Get-AltServer.ps1`, `Join-AltStoreDeployPrep.ps1` |
| `sideload/` | `Invoke-AltServerIfNeeded.ps1` |
| `usb/` | USB plug-in watch + logon task |
| `lan/` | Phone Wi-Fi IPv4 / subnet + WifiRestart |
| `VpnMulticast/` | Drop TUN/VPN `224.0.0.0/4` so Bonjour stays on Wi-Fi |

## Start AltServer if needed

`Get-AltServer.ps1` (dot-source) locates `AltServer.exe`, reports whether it is **usable in the tray**, and can start (or restart) it. A process in Task Manager is not enough — extra/stale `AltServer.exe` instances often have no notification-area icon. Loop Segments companion / USB launch still call `windows\lib\Get-LoopSegmentsAltServer.ps1`, which wraps this file and adds Loop Segments-specific 7-day / Trust copy.

```powershell
pwsh -File .\sideload\Invoke-AltServerIfNeeded.ps1
```

Direct run waits for **Enter**. Child callers: `-NoWaitEnter`. Exit **0** running (tray-usable), **2** not installed, **1** start failed. If Task Manager shows `AltServer.exe` but there is no icon, this helper **restarts** it (Explorer restart or a second instance drops the tray). Start uses scheduled task **`IosEnv-AltServer-TrayKick`** (interactive, same desktop as a Start Menu launch); a plain `Start-Process` from a script/agent does not create the tray icon. The old name `LoopSegments-AltServer-TrayKick` is unregistered on the next successful kick.

## Phone-subnet refresh

Uses **pymobiledevice3** to read the iPhone’s current Wi-Fi IPv4 and checks it against **this PC’s LAN** (the interfaces AltServer uses). Clash/TUN `198.18.0.0/16` is ignored.

Probe order (`Get-IphoneLanIpv4.py`):

1. USB `usbmux list` (identify the phone)
2. USB `com.apple.pcapd` on the IORegistry Wi-Fi iface (usually `en0`; up to two captures) — IPv4 from Wi-Fi packet headers; works across subnets without admin tunneld. First window is ~8s. If that window is empty while the radio is associated (idle phones often send nothing), or packets are only on cellular (`pdp_ip*`), a second ~16s capture runs. Skip the retry only when IORegistry shows Wi-Fi is not associated. pcapd is only used to find the **phone host IPv4** (this PC’s own LAN addresses are excluded — idle phones often only show the PC as a peer). Which AP to WifiRestart comes from `wifi_dx_common_*.py` `ROUTER_IP` (phone host /24, else this PC’s gateway) — not from sniffing `.1` / `.2` / `.254` / multicast. Associated radio but no phone host IP still **tcp/23-probes this PC’s gateway** via dx_common. On a miss, stderr includes `ifaces=pdp_ip0:55,en0:2` so you can see which BSD names pcapd used.

Bonjour `mobdev2` is **not** used (mDNS is often empty on the same subnet).

It does **not** call `SetWiFiPowerState` (unsupervised phones typically return ErrorCode 14005 / `DMCTunnelErrorDomain`). It does not join an SSID for you.

If the phone is on another subnet, picks `telnet_reboot_wlan_*.py` **only** from `P:\all_scripts\5g_router_reboot` `wifi_dx_common_*.py` `ROUTER_IP` (phone host /24 preferred, then this PC’s gateway). Before telnet it **probes tcp/23 (~1.5s)** on those APs the same way (ICMP ping is not used; a dead `ROUTER_IP` otherwise sits ~60s on WinError 10060). Telnet failure tries the other reachable dx_common AP. Then waits up to **20s** (`-WaitPhoneIpSec`) — the WifiRestart script itself is **~10s**. Same off-subnet after a bounce (DHCP may change, e.g. `.95` → `.29`) **stops that wait early** and retries (up to **3** rounds). A later pcapd miss still uses the **last known phone host IP** (if any) to match dx_common. Rejoining the same SSID often will not put the phone on the PC/AltServer subnet — forget that network or join the PC’s Wi-Fi if rounds are exhausted.

```powershell
pwsh -File .\lan\Invoke-AltServerPhoneSubnetIfNeeded.ps1
```

Direct run waits for **Enter**. In-process callers (Loop Segments recover): `-NoWaitEnter` throws `ALTSERVER_SUBNET_EXIT:<code>` instead of `exit`. `pwsh -File -NoWaitEnter` (deploy prep) **exits** with that code.

Exit codes: **0** same subnet, **2** no USB iPhone, **4** USB but no Wi-Fi IPv4 from pcapd / no PC LAN IPv4 to compare / no matching reboot script, **1** other failure (subnet still wrong after MaxRounds).

Requires: PowerShell 7, Python 3.12 + `pymobiledevice3`, USB-trusted unlocked iPhone.

Loop Segments companion/rclone call `windows\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1` **in-process**. That wrapper **runs this script first**. If the phone is already on a PC/AltServer subnet, it still waits for `:8765` and does **not** reboot routers just because Loop Segments is down. If USB/pcapd cannot finish the check (exit 2 or 4) or subnet refresh fails (exit 1), it falls back to LAN-page wait + off-subnet router reboots.

## AltStore IPA deploy (neighbor apps)

`Join-AltStoreDeployPrep.ps1` (dot-source) starts AltServer and drops Mihomo/Surfshark `224.0.0.0/4`. It does **not** run the phone-subnet check (USB plug-in already does that). Pass `-CheckPhoneSubnet` to run pcapd here. Missing USB only warns. Used by:

- `ios_3d_loop_segments\deploy.ps1` / `copy-to-icloud.ps1`
- `web_auto_parking\deploy.ps1`

```powershell
$join = @(
    (Join-Path $ProjectRoot 'env_setup\altserver_refresh\lib\Join-AltStoreDeployPrep.ps1')
    'P:\all_scripts\iOS apps\env_setup\altserver_refresh\lib\Join-AltStoreDeployPrep.ps1'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($join) { . $join; Invoke-AltStoreDeployPrep }
# Optional: Invoke-AltStoreDeployPrep -CheckPhoneSubnet
```

`-EnsureAltStorePrep` on those deploy scripts runs this (default skips for SideStore). `-SkipAltStorePrep` remains a no-op alias for the default. Pythonista zip deploys (`bike_train_transit`, `quick_open_apps`, `iOS-SOCKS-Server`) do not use AltStore.

## Scheduled tasks (this repo)

All names use the **`IosEnv-`** prefix (not Loop Segments). Loop Segments may still register its own `LoopSegments-AltServer` logon task via `windows\sideload\Register-AltServerAtLogon.ps1`; that is a different repo.

**SideStore (no AltServer):** refresh is on-device over Wi‑Fi with LocalDevVPN — no PC Bonjour, no USB, no AltServer tray. Unregister the logon/USB tasks (done on this PC when SideStore Wi‑Fi refresh was confirmed):

```powershell
pwsh -File .\usb\Register-IphoneUsbAltServer.ps1 -Unregister
# UsbWatch (IosEnv-AltServer-UsbWatch) + IosEnv-Vpn-RemoveMulticast
pwsh -File ..\..\ios_3d_loop_segments\windows\sideload\Register-AltServerAtLogon.ps1 -Unregister
# LoopSegments-AltServer logon tray — not UsbWatch
```

Re-register UsbWatch only if you still want automatic AltServer + WifiRestart on cable plug-in (AltStore, or Loop Segments LAN without companion). `lan\` helpers stay; they are not startup tasks. `TrayKick` is on-demand, not logon.

| Task | Created by | Privileges | When it runs | What it does |
|------|------------|------------|--------------|--------------|
| `IosEnv-AltServer-TrayKick` | `lib\Get-AltServer.ps1` on start (dummy 2099 trigger; `Start-ScheduledTask`) | Interactive, Limited | On demand when AltServer must appear in the tray | Launches `AltServer.exe` the same way as Start Menu / double-click. Replaces leftover `LoopSegments-AltServer-TrayKick`. |
| `IosEnv-AltServer-UsbWatch` | `usb\Register-IphoneUsbAltServer.ps1` | Interactive, Limited | At logon, immediately, and every **2 min** if it died (`IgnoreNew` if already running) | Hidden `usb\Watch-IphoneUsbAltServer.ps1` via `wscript` (no console). Task stays **Running** while that watcher is up; **Ready** means the last start exited. |
| `IosEnv-Vpn-RemoveMulticast` | Same register script (one **UAC** via `VpnMulticast\Register-VpnMulticastRouteTask.ps1`) | Interactive, **Highest** | On demand each USB plug-in (`Start-ScheduledTask`) | `VpnMulticast\Remove-VpnMulticastRoute.ps1`: drop `224.0.0.0/4` on Mihomo and Surfshark, raise those metrics, restart Bonjour. |

```powershell
Get-ScheduledTask -TaskName 'IosEnv-*' | Select-Object TaskName, State
pwsh -File .\usb\Register-IphoneUsbAltServer.ps1 -Unregister   # UsbWatch + VPN multicast; not TrayKick (also stops leftover Watch processes)
```

`TrayKick` is recreated the next time AltServer is started from these helpers. It does not need to sit in Task Scheduler until then.

## Run on iPhone USB plug-in

`Watch-IphoneUsbAltServer.ps1` polls PnP for Apple USB. On each **plug-in** (not while the cable stays in) it starts AltServer and runs the phone-subnet check (WifiRestart if the phone Wi-Fi is off this PC's subnet — useful for Loop Segments LAN / Wi-Fi AltServer). It does **not** tap AltStore Refresh All. **USB Refresh All** still works when the phone and PC are on different gateways; you tap it in AltStore with the cable in.

One-shot test (phone already plugged in):

```powershell
pwsh -File .\usb\Watch-IphoneUsbAltServer.ps1 -Once
```

Register a logon task (starts the watcher now, no console). Same user, interactive, no admin. Task Scheduler also kicks it every 2 minutes if it died (`IgnoreNew` if already running). Direct `pwsh.exe` from an Interactive task always shows a window; the default action is `wscript` + `Start-IphoneUsbAltServerWatchHidden.vbs` (WMI hidden process, wait until Watch exits) so keep-alive starts stay hidden and the task stays **Running**. Re-registering stops leftover Watch `pwsh` so the task owns the process (otherwise keep-alive hits the mutex, exits 0, and you only ever see **Ready**).

```powershell
pwsh -File .\usb\Register-IphoneUsbAltServer.ps1
pwsh -File .\usb\Register-IphoneUsbAltServer.ps1 -Unregister
```

There is no console while it runs. Confirm it is actually in the background:

```powershell
Get-ScheduledTask -TaskName 'IosEnv-AltServer-UsbWatch' | Select-Object TaskName, State
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'Watch-IphoneUsbAltServer|Start-IphoneUsbAltServerWatchHidden' } |
  Select-Object ProcessId, Name, CommandLine
Get-Content .\iphone-usb-altserver.log -Tail 15
```

**Running** plus both `wscript` and a Watch `pwsh` means the hidden watcher is up. **Ready** with no Watch `pwsh` means it is not. **Ready** with a leftover Watch `pwsh` is an orphan (re-run Register so the task owns the process). Plug/unplug USB: a new `==== USB connect` line in the log is the functional check.

`-ShowWindow` keeps a console; `-SkipPhoneSubnet` only ensures AltServer. Log: `altserver_refresh\iphone-usb-altserver.log` (gitignored; keeps the last **5** USB-connect sessions). Unlock and Trust This Computer or usbmux is empty (retries a few times). Off-subnet still runs **WifiRestart** on that plug-in.

Each USB plug-in also runs `VpnMulticast\Remove-VpnMulticastRoute.ps1` via scheduled task `IosEnv-Vpn-RemoveMulticast` (**Run with highest privileges**, no UAC per cable). That drop covers **Mihomo TUN and Surfshark OpenVPN** (`224.0.0.0/4` with a better metric than Wi-Fi), plus leftover `224.0.0.0/4` on **disconnected** Wi-Fi adapters. Re-run `usb\Register-IphoneUsbAltServer.ps1` once to create that task (replaces the old `IosEnv-Clash-RemoveMihomoMulticast` name).

After the subnet check (WifiRestart can move this PC to another LAN), the watcher **restarts AltServer** so Bonjour advertises the current Wi-Fi address. A tray process left running from `10.0.100.x` will not be found once the PC is on `192.168.2.x`.

AltStore **Refresh All** saying **AltServer not found** with AltServer already in the tray is usually a VPN/TUN stealing multicast (`224.0.0.0/4` on Mihomo `198.18.0.1` or Surfshark OpenVPN, better metric than Wi-Fi), **or** a stale AltServer advertisement after the PC LAN changed. Same subnet is not enough if Bonjour is in the tunnel or still publishing an old IP. Manual (UAC; does not disconnect Surfshark), then restart AltServer:

```powershell
pwsh -File .\VpnMulticast\Remove-VpnMulticastRoute.ps1
pwsh -File .\sideload\Invoke-AltServerIfNeeded.ps1 -NoWaitEnter -ForceRestart
```

**Refresh All** saying **AltServer could not establish connection to AltStore** is not the same as “not found.” Discovery already worked; the TCP hop to AltStore on the phone failed. Tap **Refresh All** again a few times — that has cleared it here. USB is still the fallback if retries do not.
