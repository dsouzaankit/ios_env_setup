#!/usr/bin/env python3
"""Print the USB-connected iPhone's current LAN IPv4.

Uses pymobiledevice3 over USB to identify the phone, then browses Wi-Fi lockdown
(mobdev2 / Bonjour) for the matching device's IPv4. Bonjour is mDNS / link-local:
it only works when the phone and this PC share a subnet.

If Bonjour is empty, falls back to USB ``com.apple.pcapd`` (no admin tunneld)
and reads IPv4 from Wi-Fi (en0) packet headers — works across subnets.

If Wi-Fi lockdown (EnableWifiConnections) is off, turns it on over USB and
retries Bonjour before the USB fallback. Does not call SetWiFiPowerState.

Stdout (success): JSON {"ok": true, "ip": "10.0.100.10", "source": "...", ...}
Exit:
  0  got IPv4
  2  no USB iPhone
  4  USB present but no Wi-Fi IPv4 from Bonjour or USB fallback
  1  other error
"""

from __future__ import annotations

import asyncio
import ipaddress
import json
import subprocess
import sys
import time
from collections import Counter
from typing import Any


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


def _wifi_records(entries: Any) -> list[dict[str, str]]:
    if not isinstance(entries, list):
        return []
    out: list[dict[str, str]] = []
    for item in entries:
        if not isinstance(item, dict):
            continue
        ip = str(item.get("ip") or item.get("Identifier") or "").strip()
        if not ip or ":" in ip:
            continue  # skip empty / IPv6
        parts = ip.split(".")
        if len(parts) != 4 or not all(p.isdigit() for p in parts):
            continue
        out.append(
            {
                "ip": ip,
                "name": str(item.get("DeviceName") or "").strip(),
                "product": str(item.get("ProductType") or "").strip(),
            }
        )
    return out


def _names_match(a: str, b: str) -> bool:
    if not a or not b:
        return False
    return a.casefold() == b.casefold()


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _browse_mobdev2(browse_timeout: float = 3.0) -> tuple[list[dict[str, str]], str]:
    _log(f"Bonjour mobdev2 ({int(browse_timeout)}s)...")
    code, out, err = _run_pymd(
        ["bonjour", "mobdev2", "--timeout", str(int(browse_timeout))],
        timeout=browse_timeout + 5.0,
    )
    records = _wifi_records(_parse_json_payload(out)) if code == 0 else []
    return records, (err or out or "").strip()


def _wifi_lockdown_enabled() -> bool | None:
    code, out, err = _run_pymd(["lockdown", "wifi-connections"], timeout=8.0)
    payload = _parse_json_payload(out)
    if isinstance(payload, dict) and "EnableWifiConnections" in payload:
        return bool(payload["EnableWifiConnections"])
    combined = f"{out}\n{err}"
    if "true" in combined.lower() and "enablewificonnections" in combined.lower():
        return "true" in combined.lower().split("enablewificonnections", 1)[-1][:40]
    if code != 0:
        return None
    return None


def _set_wifi_lockdown(on: bool) -> tuple[bool, str]:
    state = "on" if on else "off"
    code, out, err = _run_pymd(
        ["lockdown", "wifi-connections", "--state", state],
        timeout=8.0,
    )
    if code == 0:
        return True, ""
    code2, out2, err2 = _run_pymd(["lockdown", "wifi-connections", state], timeout=8.0)
    if code2 == 0:
        return True, ""
    return False, (err or out or err2 or out2 or f"exit {code}").strip()


def _ensure_wifi_lockdown_on() -> bool:
    """Return True if we just turned lockdown on."""
    enabled = _wifi_lockdown_enabled()
    if enabled is True:
        _log("Wi-Fi lockdown already on.")
        return False
    if enabled is False:
        _log(
            "Wi-Fi lockdown is off; enabling over USB (lockdown wifi-connections --state on)..."
        )
    else:
        _log("Could not read Wi-Fi lockdown state; trying enable anyway...")
    ok, err = _set_wifi_lockdown(True)
    if not ok:
        print(f"WIFI_LOCKDOWN_ENABLE_FAILED: {err[:300]}", file=sys.stderr, flush=True)
        return False
    time.sleep(1)
    return True


def _pick_record(
    phone: dict[str, str], records: list[dict[str, str]]
) -> dict[str, str] | None:
    for rec in records:
        if _names_match(rec["name"], phone["name"]) or (
            rec["product"] and rec["product"] == phone["product"]
        ):
            return rec
    if len(records) == 1:
        return records[0]
    return None


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


def _is_wifi_iface(name: str, unit: int) -> bool:
    """True for the infrastructure Wi-Fi NIC (en0). pcapd often splits prefix/unit."""
    n = (name or "").strip().lower()
    if n in ("en0", "en0:0"):
        return True
    if n == "en" and int(unit) == 0:
        return True
    return False


def _mac_bytes(value: Any) -> bytes | None:
    if isinstance(value, (bytes, bytearray)) and len(value) >= 6:
        return bytes(value[:6])
    if isinstance(value, str):
        hexish = value.replace(":", "").replace("-", "").replace(".", "").strip()
        if len(hexish) == 12:
            try:
                return bytes.fromhex(hexish)
            except ValueError:
                return None
    return None


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
    if src_to_public:
        return src_to_public.most_common(1)[0][0]
    both = [ip for ip in src_private if ip in dst_private]
    pool = both or list(src_private) or list(dst_private)
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


async def _usb_wifi_probe(udid: str, capture_sec: float = 8.0) -> tuple[str | None, dict[str, Any], str]:
    """Return (ipv4 or None, assoc info, error/status). USB only; no Bonjour."""
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.diagnostics import DiagnosticsService
        from pymobiledevice3.services.pcapd import PcapdService
    except ImportError as exc:
        return None, {}, f"pymobiledevice3 missing: {exc}"

    assoc: dict[str, Any] = {}
    pcap_note = ""

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
        src_private: Counter[str] = Counter()
        src_to_public: Counter[str] = Counter()
        dst_private: Counter[str] = Counter()
        mac_src: Counter[str] = Counter()
        wifi_packets = 0
        total_packets = 0

        try:
            _log(f"USB pcapd capture up to {int(capture_sec)}s...")
            async with PcapdService(lockdown=lockdown) as pcap:

                async def _capture() -> str | None:
                    nonlocal wifi_packets, total_packets
                    async for pkt in pcap.watch(packets_count=120):
                        total_packets += 1
                        name = str(getattr(pkt, "interface_name", "") or "")
                        unit = int(getattr(pkt, "unit", 0) or 0)
                        if not _is_wifi_iface(name, unit):
                            if mac_src or (src_to_public and wifi_packets >= 4):
                                return (mac_src.most_common(1)[0][0] if mac_src else None) or _pick_phone_ip(
                                    src_private, src_to_public, dst_private
                                )
                            continue
                        hints = _hints_from_frame(bytes(pkt.data or b""))
                        if not hints:
                            continue
                        wifi_packets += 1
                        for src, dst, src_mac in hints:
                            mac_known = bool(phone_mac and src_mac)
                            if mac_known and src_mac == phone_mac and _is_lan_unicast(src):
                                mac_src[src] += 1
                                return src
                            if mac_known and src_mac != phone_mac:
                                # Another station (often the AP). ARP target may be the phone.
                                if _is_lan_unicast(dst):
                                    dst_private[dst] += 1
                                continue
                            if _is_lan_unicast(src):
                                src_private[src] += 1
                                if _is_public_unicast(dst):
                                    src_to_public[src] += 1
                            if _is_lan_unicast(dst):
                                dst_private[dst] += 1
                        if mac_src:
                            return mac_src.most_common(1)[0][0]
                        chosen = _pick_phone_ip(src_private, src_to_public, dst_private)
                        if chosen and not phone_mac and (src_to_public[chosen] >= 2 or wifi_packets >= 8):
                            return chosen
                    if mac_src:
                        return mac_src.most_common(1)[0][0]
                    return _pick_phone_ip(src_private, src_to_public, dst_private)

                ip = await asyncio.wait_for(_capture(), timeout=capture_sec)
        except TimeoutError:
            ip = (mac_src.most_common(1)[0][0] if mac_src else None) or _pick_phone_ip(
                src_private, src_to_public, dst_private
            )
            pcap_note = f"pcapd timeout after {total_packets} packets ({wifi_packets} on en0)"
        except Exception as exc:
            return (
                None,
                assoc,
                f"pcapd failed ({type(exc).__name__}: {str(exc)[:180]})",
            )

    if ip:
        return ip, assoc, pcap_note
    bits = [pcap_note or f"pcapd saw {total_packets} packets ({wifi_packets} on en0)"]
    if not src_private:
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


def main() -> int:
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
    records, wifi_err = _browse_mobdev2(3.0)
    chosen = _pick_record(phone, records) if records else None
    wifi_lockdown_just_set = False

    if chosen is None:
        _log("Bonjour empty (typical when the phone is on another subnet). Checking Wi-Fi lockdown...")
        wifi_lockdown_just_set = _ensure_wifi_lockdown_on()
        if wifi_lockdown_just_set:
            records, wifi_err = _browse_mobdev2(3.0)
            chosen = _pick_record(phone, records) if records else None

    if chosen is not None:
        payload = {
            "ok": True,
            "ip": chosen["ip"],
            "deviceName": chosen["name"] or phone["name"],
            "udid": phone["udid"],
            "source": "bonjour-mobdev2",
            "wifiLockdownJustSet": wifi_lockdown_just_set,
            "wifiPowerJustSet": False,
        }
        print(json.dumps(payload, ensure_ascii=True))
        return 0

    _log(
        "Bonjour mobdev2 advertised no IPv4 (unseen from this PC - likely another "
        "subnet / mDNS not crossing routers). USB pcapd on en0 (~8s)..."
    )
    usb_ip, assoc, usb_note = _usb_wifi_ipv4(phone.get("udid") or "")
    if usb_ip:
        payload = {
            "ok": True,
            "ip": usb_ip,
            "deviceName": phone["name"],
            "udid": phone["udid"],
            "source": "usb-pcapd",
            "wifiLockdownJustSet": wifi_lockdown_just_set,
            "wifiPowerJustSet": False,
            "wifiAssociated": assoc.get("associated"),
        }
        print(json.dumps(payload, ensure_ascii=True))
        return 0

    bonjour_bit = (wifi_err or "").strip().replace("\n", " ")[:180]
    if bonjour_bit in ("[]", "{}", "null"):
        bonjour_bit = ""
    print(
        "NO_WIFI_IP: USB iPhone present but no Wi-Fi IPv4. Bonjour mobdev2 unseen "
        f"(likely other subnet / mDNS; usb={phone.get('name')}"
        f"{'; ' + bonjour_bit if bonjour_bit else ''}). "
        f"USB fallback found no IPv4 ({_assoc_brief(assoc)}"
        f"{'; ' + usb_note if usb_note else ''}).",
        file=sys.stderr,
        flush=True,
    )
    return 4


if __name__ == "__main__":
    raise SystemExit(main())
