# Phone LAN (USB pcapd)

USB-connected iPhone Wi‑Fi IPv4 and phone↔PC subnet alignment. Does **not** start AltServer.

| Script | Role |
|--------|------|
| `Get-IphoneLanIpv4.py` | pymobiledevice3 USB pcapd → phone Wi‑Fi IPv4 JSON |
| `Invoke-PhonePcSubnetIfNeeded.ps1` | Compare phone IP to this PC’s LAN; WifiRestart if off-subnet |

```powershell
pwsh -File .\Invoke-PhonePcSubnetIfNeeded.ps1
```

Direct run waits for **Enter**. In-process callers: `-NoWaitEnter` throws `PHONE_PC_SUBNET_EXIT:<code>`; `pwsh -File -NoWaitEnter` exits with that code.

Exit codes: **0** same subnet, **2** no USB iPhone, **4** USB but no Wi‑Fi IPv4 (or no matching reboot script), **1** other failure.

Requires: PowerShell 7, Python 3.12 + `pymobiledevice3`, USB-trusted unlocked iPhone.

Used by Loop Segments (`windows\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`, `Discover-LoopSegmentsLanHost.ps1`) and optional AltStore USB watch / deploy prep under `..\altserver_refresh\`.
