# Clash / mihomo (PC)

Helpers and profiles for **Clash Verge Rev** (mihomo core) on this Windows PC. Loop Segments companion uses these when Clash is running so TUN does not steal multicast (`.local` / other mDNS). Phone LAN IPv4 is USB `pcapd` only — it does not need Bonjour.

Dreamacro **Clash Premium** is discontinued. Current core: [mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta). GUI used here: [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev).

## Why Bonjour dies with TUN

mihomo Fake-IP/TUN installs an **on-link** `224.0.0.0/4` on the **Mihomo** NIC (`198.18.0.1`) with a better metric than Wi-Fi. mDNS (`224.0.0.251:5353`) goes into the tunnel, so `.local` names and other Bonjour stay empty even when the phone is on `10.0.100.x`. Phone-IP probe (`Get-IphoneLanIpv4.py`) uses USB `pcapd` and does not depend on this. Closing Clash or deleting that route puts multicast back on Wi-Fi.

`IP-CIDR,224.0.0.0/4,DIRECT` in the profile is **not** enough. `tun.route-exclude-address` is a **mihomo** key (Premium ignores it) and on Windows it often does not remove the OS multicast route — **gvisor or system**, same issue. Keep **gvisor** if you want; run `Remove-MihomoMulticastRoute.ps1` (elevated) after TUN is up. That delete is independent of stack.

Check:

```text
route print | findstr "224.0.0.0"
```

Bad: `224.0.0.0  240.0.0.0  On-link  198.18.0.1` with a lower metric than Wi-Fi.  
Other `findstr 224` hits (`10.0.64.0`, `32.0.0.0`, …) are Fake-IP unicast — ignore them.

On-link delete (gateway is `0.0.0.0`, index is not always 40):

```powershell
pwsh -File .\Remove-MihomoMulticastRoute.ps1
```

Run **elevated** after enabling TUN, or register `IosEnv-Clash-RemoveMihomoMulticast` via `altserver_refresh\Register-IphoneUsbAltServer.ps1` (USB plug-in starts that task with highest privileges, no UAC per cable). Loop Segments companion can UAC-launch **only this script** and stay unelevated. Clash may re-add the route the next time TUN comes up.

## Profiles

Import in Verge: **Profiles → New → Local** → pick a file under `profiles\`.

| File | Role |
|------|------|
| `profiles/proxy profile config - verge-mihomo.yml` | **Use this** — phone SOCKS fallback, LAN/`192.168.2.0/24` DIRECT, `route-exclude-address` for multicast |
| `profiles/proxy profile config - fallback.yml` | Older Premium-style fallback (no TUN exclude) |
| `profiles/proxy profile config.yml` | Manual select (SOCKS / HTTP / DIRECT) |

Verge owns mixed-port (often **7897**) and TUN on/off. After import: select the profile, enable **TUN**, then run `Remove-MihomoMulticastRoute.ps1` if Bonjour is still empty.

Phone SOCKS is `10.0.100.10:9876` (Loop Segments / iOS SOCKS). If that IP changed, edit the profile.

## Scripts

| File | Role |
|------|------|
| `Get-Clash.ps1` | Dot-source: detect Clash, drop multicast, register/start `IosEnv-Clash-RemoveMihomoMulticast` |
| `Remove-MihomoMulticastRoute.ps1` | Elevated entry: drop `224.0.0.0/4`, raise Mihomo metric, restart Bonjour |
| `Register-ClashRemoveMulticastRouteTask.ps1` | Elevated: create/remove `IosEnv-Clash-RemoveMihomoMulticast` (UAC once from USB register) |

Loop Segments companion (`windows\pcloud_web_companion`) dotsources `windows\lib\Get-LoopSegmentsClash.ps1`. If Clash/mihomo is running, it prints this folder’s script path and tries the route fix (warns if not elevated). `-SkipClashMdnsRoute` to skip.
