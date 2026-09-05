#!/usr/bin/env python3
"""Print the USB-connected iPhone's current LAN IPv4.

Uses pymobiledevice3 over USB to identify the phone, then USB
``com.apple.pcapd`` on en0 (up to two captures; second window is longer if the
first saw no packets). Idle associated radios often emit nothing in the first
8s. Gateway-shaped addresses (``.1`` / ``.2`` / ``.254``) are not the phone
host. AP identity for WifiRestart comes from wifi_dx_common ROUTER_IP, not
pcapd. Works across subnets; no admin tunneld. Does not use Bonjour/mobdev2.

Stdout: JSON {"ok": true, "ip": "10.0.100.10", "source": "usb-pcapd", ...}
Pass ``--exclude-ip <addr>`` (repeatable) or ``LOOP_SEGMENTS_EXCLUDE_LAN_IPS`` so this
PC's LAN addresses are never chosen (pcapd often sees the PC as a peer).
Exit:
  0  got IPv4
  2  no USB iPhone
  4  USB present but no Wi-Fi IPv4 from pcapd
  1  other error
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import os
import subprocess
import sys
from collections import Counter
from typing import Any

# Filled from --exclude-ip / LOOP_SEGMENTS_EXCLUDE_LAN_IPS (this PC's LAN addresses).
# pcapd on the phone often sees the PC as dst/src; that must not be reported as the phone.
_EXCLUDE_IPS: set[str] = set()


def _run_pymd(args: list[str], timeout: float = 20.0) -> tuple[int, str, str]:
    cmd = [sys.executable, "-m", "pymobiledevice3", *args]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        print("pymobiledevice3 / python not found", file=sys.stderr)
        return 1, "", "python missing"
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    return proc.returncode, proc.stdout or "", proc.stderr or ""


def _parse_json_payload(stdout: str) -> Any:
    text = stdout.strip()
    if not text:
        return None
    # CLI may prefix logs; take the last JSON array/object.
    for start_char in ("[", "{"):
        idx = text.rfind(start_char)
        if idx < 0:
            continue
        snippet = text[idx:]
        try:
            return json.loads(snippet)
        except json.JSONDecodeError:
            continue
    return None


def _usb_phones(entries: Any) -> list[dict[str, str]]:
    if not isinstance(entries, list):
        return []
    out: list[dict[str, str]] = []
    for item in entries:
        if not isinstance(item, dict):
            continue
        conn = str(item.get("ConnectionType") or "")
        if conn and conn.upper() != "USB":
            continue
        cls = str(item.get("DeviceClass") or "")
        if cls and cls.lower() != "iphone":
            continue
        out.append(
            {
                "name": str(item.get("DeviceName") or "").strip(),
                "udid": str(item.get("UniqueDeviceID") or item.get("Identifier") or "").strip(),
                "product": str(item.get("ProductType") or "").strip(),
            }
        )
    return out


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _is_network_or_broadcast(ip: str) -> bool:
    parts = ip.split(".")
    if len(parts) != 4 or not all(p.isdigit() for p in parts):
        return True
    last = int(parts[3])
    return last in (0, 255)


def _is_likely_router_ip(ip: str) -> bool:
    """RFC1918 .1 / .2 / .254. MR5100 is 10.0.100.2; 224.0.0.1 multicast is not an AP."""
    if not _is_lan_unicast(ip):
        return False
    parts = ip.split(".")
    return int(parts[3]) in (1, 2, 254)


def _is_lan_unicast(ip: str) -> bool:
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return False
    return bool(
        addr.is_private
        and not addr.is_loopback
        and not addr.is_link_local
        and not addr.is_multicast
        and not addr.is_reserved
        and ip != "0.0.0.0"
        and not _is_network_or_broadcast(ip)
    )


def _is_public_unicast(ip: str) -> bool:
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return False
    return not (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_reserved
        or addr.is_unspecified
    )


_FAKE_ETHER = b"\xbe\xef" * 6 + b"\x08\x00"
_SKIP_IFACE_PREFIX = (
    "pdp_ip",
    "utun",
    "ipsec",
    "lo",
    "awdl",
    "ap",
    "llw",
    "anpi",
    "xhc",
    "gif",
    "stf",
)


def _pkt_iface_name(raw: Any) -> str:
    if isinstance(raw, (bytes, bytearray)):
        return raw.split(b"\x00", 1)[0].decode("ascii", "ignore").strip()
    return str(raw or "").strip()


def _iface_key(name: str, unit: int) -> str:
    n = (name or "").strip().lower()
    if not n:
        return f"?{int(unit)}"
    if n[-1].isdigit():
        return n
    return f"{n}{int(unit)}"


def _is_skipped_iface(key: str) -> bool:
    k = (key or "").lower()
    return k.startswith(_SKIP_IFACE_PREFIX)


def _is_wifi_iface(name: str, unit: int, expected: str = "en0") -> bool:
    """True for the infrastructure Wi-Fi NIC. pcapd often splits prefix/unit (en + 0)."""
    key = _iface_key(name, unit)
    exp = (expected or "en0").strip().lower() or "en0"
    if key == exp:
        return True
    n = (name or "").strip().lower()
    if n in (exp, "en0", "en0:0"):
        return True
    if n == "en" and int(unit) == 0 and exp in ("en0", "en"):
        return True
    return False


def _is_wifi_like_iface(name: str, unit: int, expected: str, type_name: str) -> bool:
    if _is_wifi_iface(name, unit, expected):
        return True
    key = _iface_key(name, unit)
    if _is_skipped_iface(key):
        return False
    t = (type_name or "").lower()
    if t in ("ethernetcsmacd", "ieee80211", "gigabitethernet", "fastether"):
        # iOS 26 pcapd may label en0 as "en" + nonzero unit, or omit the name.
        if key.startswith("en") or key.startswith("?"):
            return True
    return False


def _mac_bytes(value: Any) -> bytes | None:
    if isinstance(value, (bytes, bytearray)) and len(value) >= 6:
        return bytes(value[:6])
    if isinstance(value, (list, tuple)) and len(value) >= 6:
        try:
            return bytes(int(x) & 0xFF for x in value[:6])
        except (TypeError, ValueError):
            return None
    if isinstance(value, str):
        hexish = value.replace(":", "").replace("-", "").replace(".", "").strip()
        if len(hexish) == 12:
            try:
                return bytes.fromhex(hexish)
            except ValueError:
                return None
    return None


def _as_phone_ip(ip: str | None) -> str | None:
    if not ip or not _is_lan_unicast(ip) or _is_likely_router_ip(ip):
        return None
    if ip in _EXCLUDE_IPS:
        return None
    return ip


def _parse_ipv4_header(iph: bytes) -> tuple[str, str] | None:
    if len(iph) < 20 or (iph[0] >> 4) != 4:
        return None
    ihl = (iph[0] & 0x0F) * 4
    if ihl < 20 or len(iph) < ihl:
        return None
    src = ".".join(str(b) for b in iph[12:16])
    dst = ".".join(str(b) for b in iph[16:20])
    return src, dst


def _iter_ethernet_payloads(data: bytes) -> list[bytes]:
    """pcapd prepends a fake Ethernet/IPv4 header when frame_pre_length is 0."""
    frames = [data]
    if len(data) >= 28 and data[:14] == _FAKE_ETHER:
        frames.append(data[14:])
    return frames


def _hints_from_ethernet(frame: bytes) -> list[tuple[str, str, bytes | None]]:
    """Return (src_ip, dst_ip, src_mac) from IPv4 or ARP Ethernet frames."""
    if len(frame) < 14:
        return []
    ethertype = int.from_bytes(frame[12:14], "big")
    off = 14
    if ethertype == 0x8100 and len(frame) >= 18:
        ethertype = int.from_bytes(frame[16:18], "big")
        off = 18
    src_mac = bytes(frame[6:12])
    if ethertype == 0x0800:
        pair = _parse_ipv4_header(frame[off:])
        if pair:
            return [(pair[0], pair[1], src_mac)]
        return []
    if ethertype == 0x0806:
        arp = frame[off:]
        if len(arp) < 28:
            return []
        if int.from_bytes(arp[2:4], "big") != 0x0800 or arp[4] != 6 or arp[5] != 4:
            return []
        sha = bytes(arp[8:14])
        spa_ip = ".".join(str(b) for b in arp[14:18])
        tpa_ip = ".".join(str(b) for b in arp[24:28])
        return [(spa_ip, tpa_ip, sha)]
    return []


def _hints_from_raw_ipv4(data: bytes) -> list[tuple[str, str, bytes | None]]:
    """IPv4 at common L2 offsets (Ethernet, VLAN, 802.11+LLC/SNAP)."""
    for off in (0, 14, 18, 24, 26, 30, 32, 34):
        if off >= len(data):
            continue
        pair = _parse_ipv4_header(data[off:])
        if not pair:
            continue
        src, dst = pair
        if (
            _is_lan_unicast(src)
            or _is_lan_unicast(dst)
            or _is_likely_router_ip(src)
            or _is_likely_router_ip(dst)
            or _is_public_unicast(src)
            or _is_public_unicast(dst)
        ):
            return [(src, dst, None)]
    return []


def _pkt_protocol_family(pkt: Any) -> int:
    fam = getattr(pkt, "protocol_family", 0)
    try:
        return int(fam)
    except (TypeError, ValueError):
        return 0


def _hints_from_pcapd_packet(pkt: Any) -> list[tuple[str, str, bytes | None]]:
    data = bytes(pkt.data or b"")
    hints = _hints_from_frame(data)
    if hints:
        return hints
    fam = _pkt_protocol_family(pkt)
    # Apple AF_INET=2; fake Ethernet claims IPv4 even when the payload is IPv6.
    if fam == 2:
        raw = data[14:] if len(data) >= 34 and data[:14] == _FAKE_ETHER else data
        pair = _parse_ipv4_header(raw)
        if pair:
            return [(pair[0], pair[1], None)]
    return _hints_from_raw_ipv4(data)


def _hints_from_frame(data: bytes) -> list[tuple[str, str, bytes | None]]:
    out: list[tuple[str, str, bytes | None]] = []
    for frame in _iter_ethernet_payloads(data):
        out.extend(_hints_from_ethernet(frame))
        if not out:
            pair = _parse_ipv4_header(frame)
            if pair:
                out.append((pair[0], pair[1], None))
    return out


def _pick_phone_ip(src_private: Counter[str], src_to_public: Counter[str], dst_private: Counter[str]) -> str | None:
    """Never returns .1/.254 — those are the AP, not the phone."""
    def _hosts(counter: Counter[str]) -> list[str]:
        return [ip for ip in counter if _as_phone_ip(ip)]

    host_public = _hosts(src_to_public)
    if host_public:
        return max(host_public, key=lambda ip: src_to_public[ip])
    both = [ip for ip in src_private if ip in dst_private]
    host_both = [ip for ip in both if _as_phone_ip(ip)]
    host_src = _hosts(src_private)
    host_dst = _hosts(dst_private)
    pool = host_both or host_src or host_dst
    if not pool:
        return None
    counts = src_private if src_private else dst_private
    return max(pool, key=lambda ip: counts[ip])


def _summarize_wifi_assoc(raw: Any) -> dict[str, Any]:
    """IORegistry Wi-Fi dump has association/radio keys, not IPv4."""
    info: dict[str, Any] = {"associated": None, "iface": "", "channel": None, "band": "", "mac": None}
    if not isinstance(raw, dict):
        return info
    iface = str(raw.get("IOInterfaceName") or raw.get("BSD Name") or "").strip()
    info["iface"] = iface
    info["mac"] = _mac_bytes(raw.get("IOMACAddress"))
    ch = raw.get("IO80211Channel")
    if isinstance(ch, int) and ch > 0:
        info["channel"] = ch
    band = str(raw.get("IO80211Band") or "").strip()
    info["band"] = band
    ssid = raw.get("IO80211SSID")
    has_ssid = bool(ssid) and str(ssid) not in ("", "<SSID Redacted>")
    # Redacted SSID still means associated if a channel/band is present.
    info["associated"] = bool((isinstance(ch, int) and ch > 0) or band or has_ssid)
    role = str(raw.get("IO80211InterfaceRole") or "")
    if role:
        info["role"] = role
    return info


def _best_mac_src(mac_src: Counter[str]) -> str | None:
    if not mac_src:
        return None
    return _as_phone_ip(mac_src.most_common(1)[0][0])


async def _usb_wifi_probe(udid: str, capture_sec: float = 8.0) -> tuple[str | None, dict[str, Any], str]:
    """Return (ipv4 or None, assoc info, error/status). USB only; no Bonjour."""
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.diagnostics import DiagnosticsService
        from pymobiledevice3.services.pcapd import PcapdService
    except ImportError as exc:
        return None, {}, f"pymobiledevice3 missing: {exc}"

    assoc: dict[str, Any] = {}
    notes: list[str] = []

    async with await create_using_usbmux(
        serial=udid or None,
        connection_type="USB",
    ) as lockdown:
        try:
            async with DiagnosticsService(lockdown=lockdown) as diag:
                assoc = _summarize_wifi_assoc(await diag.get_wifi())
        except Exception as exc:
            assoc = {"associated": None, "error": f"{type(exc).__name__}: {exc}"[:180]}

        phone_mac = assoc.get("mac") if isinstance(assoc.get("mac"), (bytes, bytearray)) else None
        expected_iface = str(assoc.get("iface") or "en0").strip() or "en0"
        ip: str | None = None
        src_private: Counter[str] = Counter()
        src_to_public: Counter[str] = Counter()
        dst_private: Counter[str] = Counter()
        wifi_packets = 0
        wifi_iface_packets = 0
        total_packets = 0
        iface_hits: Counter[str] = Counter()

        for attempt in range(1, 3):
            src_private = Counter()
            src_to_public = Counter()
            dst_private = Counter()
            mac_src: Counter[str] = Counter()
            wifi_packets = 0
            wifi_iface_packets = 0
            total_packets = 0
            iface_hits = Counter()
            pcap_note = ""

            try:
                _log(f"USB pcapd capture up to {int(capture_sec)}s (attempt {attempt}/2)...")
                async with PcapdService(lockdown=lockdown) as pcap:

                    async def _capture() -> str | None:
                        nonlocal wifi_packets, wifi_iface_packets, total_packets
                        async for pkt in pcap.watch(packets_count=-1):
                            total_packets += 1
                            name = _pkt_iface_name(getattr(pkt, "interface_name", ""))
                            unit = int(getattr(pkt, "unit", 0) or 0)
                            type_raw = getattr(pkt, "interface_type", None)
                            type_name = str(getattr(type_raw, "name", type_raw) or "")
                            key = _iface_key(name, unit)
                            iface_hits[key] += 1
                            on_wifi = _is_wifi_like_iface(name, unit, expected_iface, type_name)
                            if on_wifi:
                                wifi_iface_packets += 1
                            if not on_wifi:
                                best = _best_mac_src(mac_src) or _pick_phone_ip(
                                    src_private, src_to_public, dst_private
                                )
                                if best and (mac_src or wifi_packets >= 4):
                                    return best
                                continue
                            hints = _hints_from_pcapd_packet(pkt)
                            if not hints:
                                continue
                            wifi_packets += 1
                            for src, dst, src_mac in hints:
                                mac_known = bool(phone_mac and src_mac)
                                if mac_known and src_mac == phone_mac:
                                    if _as_phone_ip(src):
                                        mac_src[src] += 1
                                        return src
                                    continue
                                if mac_known and src_mac != phone_mac:
                                    # Another station (often the AP). ARP target may be the phone.
                                    if _as_phone_ip(dst):
                                        dst_private[dst] += 1
                                    elif _is_likely_router_ip(dst):
                                        dst_private[dst] += 1
                                    if _is_likely_router_ip(src):
                                        src_private[src] += 1
                                    continue
                                if _is_lan_unicast(src):
                                    src_private[src] += 1
                                    if _is_public_unicast(dst):
                                        src_to_public[src] += 1
                                if _is_lan_unicast(dst):
                                    dst_private[dst] += 1
                            best = _best_mac_src(mac_src)
                            if best:
                                return best
                            chosen = _pick_phone_ip(src_private, src_to_public, dst_private)
                            if not chosen:
                                continue
                            if phone_mac:
                                if wifi_packets >= 4:
                                    return chosen
                            elif src_to_public[chosen] >= 2 or wifi_packets >= 8:
                                return chosen
                        return _best_mac_src(mac_src) or _pick_phone_ip(
                            src_private, src_to_public, dst_private
                        )

                    ip = _as_phone_ip(await asyncio.wait_for(_capture(), timeout=capture_sec))
            except TimeoutError:
                ip = _best_mac_src(mac_src) or _pick_phone_ip(
                    src_private, src_to_public, dst_private
                )
                pcap_note = (
                    f"pcapd timeout after {total_packets} packets "
                    f"({wifi_packets} IPv4 / {wifi_iface_packets} frames on {expected_iface}) "
                    f"attempt {attempt}/2"
                )
                if iface_hits:
                    top = ", ".join(f"{k}:{n}" for k, n in iface_hits.most_common(6))
                    pcap_note += f"; ifaces={top}"
            except Exception as exc:
                assoc["pcapdError"] = f"{type(exc).__name__}: {str(exc)[:180]}"
                return (
                    None,
                    assoc,
                    f"pcapd failed ({type(exc).__name__}: {str(exc)[:180]})",
                )

            if pcap_note:
                notes.append(pcap_note)
            if ip:
                break
            if attempt == 1:
                associated = assoc.get("associated") is True
                radio_down = assoc.get("associated") is False
                if radio_down and total_packets == 0:
                    notes.append("wifi not associated; not retrying an empty capture")
                    break
                if total_packets == 0 or wifi_iface_packets == 0:
                    _log("pcapd attempt 1 saw no Wi-Fi frames; retrying with a longer window...")
                    capture_sec = max(float(capture_sec), 16.0)
                elif associated or src_private or dst_private:
                    _log("pcapd attempt 1 had no phone host IP; retrying...")
                else:
                    _log("pcapd attempt 1 empty; retrying...")
                await asyncio.sleep(1.5)

    if ip:
        return ip, assoc, "; ".join(notes)
    bits = notes or [
        f"pcapd saw {total_packets} packets "
        f"({wifi_packets} IPv4 / {wifi_iface_packets} frames on {assoc.get('iface') or 'en0'})"
    ]
    if not src_private and not dst_private:
        bits.append("no private IPv4 on Wi-Fi frames")
    return None, assoc, "; ".join(b for b in bits if b)


def _usb_wifi_ipv4(udid: str) -> tuple[str | None, dict[str, Any], str]:
    try:
        return asyncio.run(_usb_wifi_probe(udid))
    except Exception as exc:
        return None, {}, f"{type(exc).__name__}: {str(exc)[:200]}"


def _assoc_brief(assoc: dict[str, Any]) -> str:
    if not assoc:
        return "wifi-ioregistry=unread"
    if assoc.get("associated") is True:
        ch = assoc.get("channel")
        band = assoc.get("band") or ""
        iface = assoc.get("iface") or "en0"
        extra = f" ch{ch}" if ch else ""
        if band:
            extra += f" {band}"
        return f"wifi-associated {iface}{extra}"
    if assoc.get("associated") is False:
        return "wifi-ioregistry shows no association (SSID/channel missing)"
    err = assoc.get("error")
    if err:
        return f"wifi-ioregistry error: {err}"
    return "wifi-ioregistry=unknown"


def _load_exclude_ips(cli: list[str] | None = None) -> set[str]:
    out: set[str] = set()
    for raw in cli or []:
        ip = (raw or "").strip()
        if ip:
            out.add(ip)
    env = (os.environ.get("LOOP_SEGMENTS_EXCLUDE_LAN_IPS") or "").strip()
    if env:
        for part in env.replace(";", ",").split(","):
            ip = part.strip()
            if ip:
                out.add(ip)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="USB iPhone Wi-Fi IPv4 via pcapd")
    parser.add_argument(
        "--exclude-ip",
        action="append",
        default=[],
        help="IPv4 to never treat as the phone (pass each PC LAN address)",
    )
    args = parser.parse_args()
    global _EXCLUDE_IPS
    _EXCLUDE_IPS = _load_exclude_ips(list(args.exclude_ip or []))
    if _EXCLUDE_IPS:
        _log("Excluding PC/other LAN IPs from pcapd phone pick: " + ", ".join(sorted(_EXCLUDE_IPS)))

    _log("USB usbmux list...")
    usb_code, usb_out, usb_err = _run_pymd(["usbmux", "list"], timeout=8.0)
    if usb_code != 0:
        print(usb_err or usb_out or "usbmux list failed", file=sys.stderr)
        return 2 if "no device" in (usb_err + usb_out).lower() else 1

    phones = _usb_phones(_parse_json_payload(usb_out))
    if not phones:
        print("NO_USB_IPHONE", file=sys.stderr)
        return 2

    phone = phones[0]
    _log(f"USB iPhone: {phone.get('name') or phone.get('udid') or '?'}")
    _log("USB pcapd on en0 (up to two ~8s captures)...")
    usb_ip, assoc, usb_note = _usb_wifi_ipv4(phone.get("udid") or "")
    payload = {
        "ok": bool(usb_ip),
        "ip": usb_ip,
        "deviceName": phone["name"],
        "udid": phone["udid"],
        "source": "usb-pcapd",
        "wifiLockdownJustSet": False,
        "wifiPowerJustSet": False,
        "wifiAssociated": assoc.get("associated"),
    }
    print(json.dumps(payload, ensure_ascii=True))
    if usb_ip:
        return 0

    print(
        "NO_WIFI_IP: USB iPhone present but no Wi-Fi IPv4 from pcapd "
        f"(usb={phone.get('name')}; {_assoc_brief(assoc)}"
        f"{'; ' + usb_note if usb_note else ''}).",
        file=sys.stderr,
        flush=True,
    )
    return 4


if __name__ == "__main__":
    raise SystemExit(main())
