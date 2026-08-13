#!/usr/bin/env python3
"""Print the USB-connected iPhone's current LAN IPv4 (Bonjour mobdev2).

Uses pymobiledevice3 over USB to identify the phone, then browses Wi-Fi lockdown
(mobdev2) for the matching device's IPv4.

Stdout (success): JSON {"ok": true, "ip": "10.0.100.10", ...}
Exit:
  0  got IPv4
  2  no USB iPhone
  4  USB present but no Wi-Fi IPv4 advertised
  1  other error
"""

from __future__ import annotations

import json
import subprocess
import sys
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


def main() -> int:
    usb_code, usb_out, usb_err = _run_pymd(["usbmux", "list"], timeout=15.0)
    if usb_code != 0:
        print(usb_err or usb_out or "usbmux list failed", file=sys.stderr)
        return 2 if "no device" in (usb_err + usb_out).lower() else 1

    phones = _usb_phones(_parse_json_payload(usb_out))
    if not phones:
        print("NO_USB_IPHONE", file=sys.stderr)
        return 2

    wifi_code, wifi_out, wifi_err = _run_pymd(
        ["bonjour", "mobdev2", "--timeout", "6"],
        timeout=20.0,
    )
    records = _wifi_records(_parse_json_payload(wifi_out)) if wifi_code == 0 else []
    if not records:
        print(
            "NO_WIFI_IP: USB iPhone visible but Bonjour mobdev2 advertised no IPv4 "
            f"(usb={phones[0].get('name')}; {wifi_err.strip()[:200]})",
            file=sys.stderr,
        )
        return 4

    chosen = None
    phone = phones[0]
    for rec in records:
        if _names_match(rec["name"], phone["name"]) or (
            rec["product"] and rec["product"] == phone["product"]
        ):
            chosen = rec
            break
    if chosen is None and len(records) == 1:
        chosen = records[0]
    if chosen is None:
        print(f"NO_WIFI_MATCH usb={phone} wifi={records}", file=sys.stderr)
        return 4

    payload = {
        "ok": True,
        "ip": chosen["ip"],
        "deviceName": chosen["name"] or phone["name"],
        "udid": phone["udid"],
        "source": "bonjour-mobdev2",
    }
    print(json.dumps(payload, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
