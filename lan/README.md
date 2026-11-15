# Phone LAN (USB network monitor, pcapd fallback)

USB-connected iPhone Wi‑Fi IPv4 and phone↔PC subnet alignment. Does **not** start AltServer.

| Script | Role |
|--------|------|
| `Get-IphoneLanIpv4.py` | pymobiledevice3 over USB → phone Wi‑Fi IPv4 JSON: first the phone's own address on its **TCP** connections over `en0` (DVT network monitor, exact, `source: usb-dvt-netmon`; UDP sockets are skipped because they can keep a previous Wi‑Fi's address); no Wi‑Fi TCP (idle, or a Wi‑Fi with no gateway where internet goes over cellular) → pcapd sniffing (`source: usb-pcapd`) |
| `Invoke-PhonePcSubnetIfNeeded.ps1` | Compare phone IP to this PC’s LAN; WifiRestart if **off-subnet**. If Wi‑Fi is associated but pcapd sees no host IPv4 (idle phone), **soft exit 4** — does **not** WifiRestart the PC gateway |

```powershell
pwsh -File .\Invoke-PhonePcSubnetIfNeeded.ps1
```

Direct run waits for **Enter**. In-process callers: `-NoWaitEnter` throws `PHONE_PC_SUBNET_EXIT:<code>`; `pwsh -File -NoWaitEnter` exits with that code.

Exit codes: **0** same subnet, **2** no USB iPhone, **4** USB but no Wi‑Fi IPv4 / idle pcapd / no matching reboot script (recover may wait on `:8765`), **1** other failure.

Requires: PowerShell 7, Python 3.12 + `pymobiledevice3`, USB-trusted unlocked iPhone.

Used by Loop Segments (`windows\lan\Invoke-LoopSegmentsPhoneLanRecoverIfNeeded.ps1`, `Discover-LoopSegmentsLanHost.ps1`) and optional AltStore USB watch / deploy prep under `..\altserver_refresh\`.
