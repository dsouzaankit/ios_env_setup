# Clash / mihomo (PC)

Helpers and profiles for **Clash Verge Rev** (mihomo core) on this Windows PC. TUN still steals Bonjour unless you drop `224.0.0.0/4` — that drop lives in **`../altserver_refresh/VpnMulticast/`** (also covers Surfshark). Phone LAN IPv4 is USB `pcapd` only — it does not need Bonjour.

Dreamacro **Clash Premium** is discontinued. Current core: [mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta). GUI used here: [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev).

## Why Bonjour dies with TUN

mihomo Fake-IP/TUN installs an **on-link** `224.0.0.0/4` on the **Mihomo** NIC (`198.18.0.1`) with a better metric than Wi-Fi. mDNS (`224.0.0.251:5353`) goes into the tunnel, so `.local` names and other Bonjour stay empty even when the phone is on `10.0.100.x`. Phone-IP probe (`lan\Get-IphoneLanIpv4.py`) uses USB `pcapd` and does not depend on this. Closing Clash or deleting that route puts multicast back on Wi-Fi.

`IP-CIDR,224.0.0.0/4,DIRECT` in the profile is **not** enough. `tun.route-exclude-address` is a **mihomo** key (Premium ignores it). The earlier note that it "often does not remove the OS multicast route" was written while Clash Verge's own `config.yaml` replaced the profile's list with `[]`, so the exclusion never reached the core. With `224.0.0.0/4` applied there by [`Set-ClashLanExceptions.ps1`](#lan-and-router-dns-exceptions), TUN on (gvisor) showed no `224.0.0.0/4` on Mihomo, only on Wi-Fi and loopback (2026-11-22, one check). Still run `..\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1` (elevated) if the route shows up: the delete is independent of stack and also covers Surfshark.

**Why the companion checks this at every start, while the LAN exceptions are one-off:** the multicast route is live routing-table state, not config. Clash adds it again whenever TUN comes up (TUN toggle, core or service restart, reboot), and Surfshark whenever it reconnects. The LAN exceptions live in Clash Verge's config files, which persist. The check is cheap: it asks for UAC only when Mihomo or Surfshark actually has the route (`No 224.0.0.0/4 on Mihomo or Surfshark - skip elevation` otherwise).

Check:

```text
route print | findstr "224.0.0.0"
```

Bad: `224.0.0.0  240.0.0.0  On-link  198.18.0.1` (or Surfshark `10.11.11.3`) with a lower metric than Wi-Fi.  
Other `findstr 224` hits (`10.0.64.0`, `32.0.0.0`, …) are Fake-IP unicast — ignore them.

On-link delete (gateway is `0.0.0.0`, index is not always 40):

```powershell
pwsh -File ..\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1
```

Run **elevated** after enabling TUN, or register `IosEnv-Vpn-RemoveMulticast` via `altserver_refresh\usb\Register-IphoneUsbAltServer.ps1` (USB plug-in starts that task with highest privileges, no UAC per cable). Loop Segments companion can UAC-launch **only that script** and stay unelevated. Clash or Surfshark may re-add the route the next time TUN/VPN comes up.

## LAN and router DNS exceptions

Clash Verge Rev's own `config.yaml` (in `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\`) holds the TUN settings and **overrides the profile's `tun:` section**. With `route-exclude-address: []` there, the profile's LAN excludes never reach the running core (`clash-verge.yaml`). The tunnel then takes `192.168.2.x` / `10.0.100.x` traffic and even DNS sent straight to the router (`dns-hijack: any:53`), and router names like `iphone.routerlogin.net` get fake `198.18.x.x` answers.

```powershell
pwsh -File .\Set-ClashLanExceptions.ps1
```

It quits the Clash Verge GUI, edits two files (backing each up as `*.bak-<timestamp>`), restarts the GUI, and checks the running config:

| File | Change |
|------|--------|
| Verge `config.yaml` | `tun.route-exclude-address`: `224.0.0.0/4`, `ff02::/16`, `10.0.100.0/24`, `192.168.2.0/24` |
| Active profile's Merge enhancement (`profiles\<merge uid>.yaml`) | `dns.fake-ip-filter` += `+.routerlogin.net`; `dns.nameserver-policy`: `+.routerlogin.net` → `dhcp://Wi-Fi` (the router's DNS from DHCP, even when Windows has a manual `8.8.8.8`) |

The excludes cover whole subnets, so a different phone IP in the same `10.0.100.x` / `192.168.2.x` needs no rerun. If the app setup puts the phone LAN on another subnet, pass it: `-ExcludeAddress 224.0.0.0/4,ff02::/16,<subnet>/24,...`. The core (`verge-mihomo`) runs elevated under `clash_verge_service`; the script leaves it running, and the GUI sends it the new config on start. Options: `-ExcludeAddress`, `-RouterDomain`, `-DhcpInterface`, `-NoRestart` (Verge already closed), `-WhatIf`. Changing the TUN settings in Verge's GUI later rewrites `config.yaml`; rerun the script after that.

Check (TUN on):

```powershell
Find-NetRoute -RemoteIPAddress 10.0.100.2 | Select-Object -Last 1 InterfaceAlias   # Wi-Fi, not Mihomo
Resolve-DnsName ANKIT-S5406S.routerlogin.net                                     # real 10.0.100.x / 192.168.2.x
```

The OS multicast route (Bonjour) is separate; see below.

## Profiles

Import in Verge: **Profiles → New → Local** → pick a file under `profiles\`.

| File | Role |
|------|------|
| `profiles/proxy profile config - verge-mihomo.yml` | **Use this** — phone SOCKS fallback, LAN/`192.168.2.0/24` DIRECT, `route-exclude-address` for multicast |
| `profiles/proxy profile config - fallback.yml` | Older Premium-style fallback (no TUN exclude) |
| `profiles/proxy profile config.yml` | Manual select (SOCKS / HTTP / DIRECT) |

Verge owns mixed-port (often **7897**) and TUN on/off. After import: select the profile, enable **TUN**, then run `..\altserver_refresh\VpnMulticast\Remove-VpnMulticastRoute.ps1` if Bonjour is still empty.

Phone SOCKS is `10.0.100.10:9876` (Loop Segments / iOS SOCKS). If that IP changed, edit the profile.

## Multicast drop (not in this folder)

Scripts: `../altserver_refresh/VpnMulticast/`. Loop Segments companion (`windows\pcloud_web_companion`) dotsources `windows\lib\Get-LoopSegmentsClash.ps1`, which loads that folder. `-SkipClashMdnsRoute` to skip.
