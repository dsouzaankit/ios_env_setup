# AltServer helpers

## Start AltServer if needed

`Get-AltServer.ps1` (dot-source) locates `AltServer.exe`, reports whether it is running, and can start it. Loop Segments companion / USB launch still call `windows\lib\Get-LoopSegmentsAltServer.ps1`, which wraps this file and adds Loop Segments-specific 7-day / Trust copy.

```powershell
pwsh -File .\Invoke-AltServerIfNeeded.ps1
```

Direct run waits for **Enter**. Child callers: `-NoWaitEnter`. Exit **0** running, **2** not installed, **1** start failed.

## Phone-subnet refresh

Uses **pymobiledevice3** to read the iPhone’s current Wi-Fi IPv4 and checks it against **this PC’s LAN** (the interfaces AltServer uses). Clash/TUN `198.18.0.0/16` is ignored.

Probe order (`Get-IphoneLanIpv4.py`):

1. USB `usbmux list` (identify the phone)
2. USB `com.apple.pcapd` on `en0` (~8s) — IPv4 from Wi-Fi packet headers; works across subnets without admin tunneld

Bonjour `mobdev2` is **not** used (mDNS is often empty on the same subnet).

It does **not** call `SetWiFiPowerState` (unsupervised phones typically return ErrorCode 14005 / `DMCTunnelErrorDomain`). It does not join an SSID for you.

If the phone is on another subnet, infers `telnet_reboot_wlan_*.py` from `P:\all_scripts\5g_router_reboot` (`wifi_dx_common_*.py` `ROUTER_IP` on the phone’s subnet) and runs that AP’s **WifiRestart** (not a full reboot). Then waits up to **25s** (`-WaitPhoneIpSec`) — WifiRestart is typically back in **<20s**. Stops on the **first** probe that shows the phone back on the **same off-subnet** (DHCP may change, e.g. `.95` → `.29`). A later pcapd miss (radio down during the bounce) still uses the **last known** phone IP to pick the AP. This PC must be able to **telnet** that `ROUTER_IP`. Rejoining the same SSID will not put the phone on the PC/AltServer subnet — forget that network or join the PC’s Wi-Fi.

```powershell
pwsh -File .\Invoke-AltServerPhoneSubnetIfNeeded.ps1
```

Direct run waits for **Enter**. In-process callers (Loop Segments recover): `-NoWaitEnter` throws `ALTSERVER_SUBNET_EXIT:<code>` instead of `exit`.

Exit codes: **0** same subnet, **2** no USB iPhone, **4** USB but no Wi-Fi IPv4 from pcapd (or no matching reboot script), **1** other failure.

Requires: PowerShell 7, Python 3.12 + `pymobiledevice3`, USB-trusted unlocked iPhone.

Loop Segments companion/rclone call `windows\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1` **in-process**. That wrapper **runs this script first**. If the phone is already on a PC/AltServer subnet, it still waits for `:8765` and does **not** reboot routers just because Loop Segments is down. If USB/pcapd cannot give a phone IP (exit 2 or 4), it falls back to LAN-page wait + off-subnet router reboots.
