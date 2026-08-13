# AltServer helpers

## Start AltServer if needed

`Get-AltServer.ps1` (dot-source) locates `AltServer.exe`, reports whether it is running, and can start it. Loop Segments companion / USB launch still call `windows\lib\Get-LoopSegmentsAltServer.ps1`, which wraps this file and adds Loop Segments-specific 7-day / Trust copy.

```powershell
pwsh -File .\Invoke-AltServerIfNeeded.ps1
```

Direct run waits for **Enter**. Child callers: `-NoWaitEnter`. Exit **0** running, **2** not installed, **1** start failed.

## Phone-subnet refresh

Uses **pymobiledevice3** (USB + Bonjour `mobdev2`) to read the iPhone’s current Wi-Fi IPv4 and checks it against **this PC’s LAN** (the interfaces AltServer uses).

If the phone is on another subnet, infers `telnet_reboot_wlan_*.py` from `P:\all_scripts\5g_router_reboot` (`wifi_dx_common_*.py` `ROUTER_IP` on the phone’s subnet), reboots that AP, waits for a new phone IP, and checks again.

```powershell
pwsh -File .\Invoke-AltServerPhoneSubnetIfNeeded.ps1
```

Direct run waits for **Enter**. Child callers: `-NoWaitEnter`.

Exit codes: **0** same subnet, **2** no USB iPhone, **4** USB but no advertised Wi-Fi IPv4, **1** other failure.

Requires: PowerShell 7, Python 3.12 + `pymobiledevice3`, USB-trusted unlocked iPhone, Wi-Fi lockdown enabled (`pymobiledevice3 lockdown wifi-connections on`).

Loop Segments companion/rclone still call `windows\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`. That wrapper **runs this script first**. If the phone is already on a PC/AltServer subnet, it still waits for `:8765` and does **not** reboot routers just because Loop Segments is down. If USB/Bonjour cannot give a phone IP (exit 2 or 4), it falls back to LAN-page wait + off-subnet router reboots.