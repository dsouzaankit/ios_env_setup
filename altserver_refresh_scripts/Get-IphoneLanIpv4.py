#!/usr/bin/env python3
"""Print the USB-connected iPhone's current LAN IPv4 (Bonjour mobdev2).

Uses pymobiledevice3 over USB to identify the phone, then browses Wi-Fi lockdown
(mobdev2) for the matching device's IPv4.

If Wi-Fi lockdown (EnableWifiConnections) is off, turns it on over USB and
retries Bonjour. If Bonjour is still empty, tries MCInstall SetWiFiPowerState
(Wi-Fi radio on) over USB — often fails on unsupervised phones — and retries.

Stdout (success): JSON {"ok": true, "ip": "10.0.100.10", ...}
Exit:
  0  got IPv4
  2  no USB iPhone
  4  USB present but no Wi-Fi IPv4 advertised
  1  other error
"""

from __future__ import annotations

import asyncio
import json
import re
import subprocess
import sys
import time
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


def _browse_mobdev2(browse_timeout: float = 6.0) -> tuple[list[dict[str, str]], str]:
    code, out, err = _run_pymd(
        ["bonjour", "mobdev2", "--timeout", str(int(browse_timeout))],
        timeout=browse_timeout + 14.0,
    )
    records = _wifi_records(_parse_json_payload(out)) if code == 0 else []
    return records, (err or out or "").strip()


def _wifi_lockdown_enabled() -> bool | None:
    code, out, err = _run_pymd(["lockdown", "wifi-connections"], timeout=20.0)
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
        timeout=20.0,
    )
    if code == 0:
        return True, ""
    code2, out2, err2 = _run_pymd(["lockdown", "wifi-connections", state], timeout=20.0)
    if code2 == 0:
        return True, ""
    return False, (err or out or err2 or out2 or f"exit {code}").strip()


_ERR_LOC_RE = re.compile(r"'LocalizedDescription':\s*'([^']+)'")
_ERR_CODE_RE = re.compile(r"'ErrorCode':\s*(\d+)")
_ERR_DOMAIN_RE = re.compile(r"'ErrorDomain':\s*'([^']+)'")


def _short_wifi_power_error(exc: BaseException) -> str:
    """One-line reason; never dump a traceback or MCInstall binary archive."""
    if isinstance(exc, asyncio.TimeoutError):
        return "timeout"
    raw = str(exc).replace("\n", " ").strip()
    loc = _ERR_LOC_RE.search(raw)
    code = _ERR_CODE_RE.search(raw)
    domain = _ERR_DOMAIN_RE.search(raw)
    bits: list[str] = []
    if loc:
        bits.append(loc.group(1).rstrip("."))
    if code:
        bits.append(f"ErrorCode {code.group(1)}")
    if domain:
        bits.append(domain.group(1))
    if bits:
        return "; ".join(bits)
    name = type(exc).__name__
    compact = re.sub(r"b['\"].{12,}['\"]", "(binary)", raw)
    compact = re.sub(r"\s+", " ", compact).strip()
    if len(compact) > 180:
        compact = compact[:177] + "..."
    return f"{name}: {compact}" if compact else name


def _set_wifi_power_on(udid: str = "") -> tuple[bool, str]:
    """Turn Wi-Fi radio on via MCInstall (same as profile set-wifi-power --state on).

    In-process so typer/CLI tracebacks never become the user-facing error.
    Always requests power *on* (CLI default is off).
    """
    try:
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.services.mobile_config import MobileConfigService
    except ImportError as exc:
        return False, f"pymobiledevice3 missing: {exc}"

    async def _run() -> None:
        async with await create_using_usbmux(
            serial=udid or None,
            connection_type="USB",
        ) as lockdown:
            async with MobileConfigService(lockdown=lockdown) as mc:
                await mc.set_wifi_power_state(True)

    try:
        asyncio.run(asyncio.wait_for(_run(), timeout=25.0))
        return True, ""
    except Exception as exc:
        return False, _short_wifi_power_error(exc)


def _ensure_wifi_lockdown_on() -> bool:
    """Return True if we just turned lockdown on."""
    enabled = _wifi_lockdown_enabled()
    if enabled is True:
        return False
    if enabled is False:
        print(
            "Wi-Fi lockdown is off; enabling over USB (lockdown wifi-connections --state on)...",
            file=sys.stderr,
        )
    else:
        print(
            "Could not read Wi-Fi lockdown state; trying enable anyway...",
            file=sys.stderr,
        )
    ok, err = _set_wifi_lockdown(True)
    if not ok:
        print(f"WIFI_LOCKDOWN_ENABLE_FAILED: {err[:300]}", file=sys.stderr)
        return False
    time.sleep(3)
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


def main() -> int:
    usb_code, usb_out, usb_err = _run_pymd(["usbmux", "list"], timeout=15.0)
    if usb_code != 0:
        print(usb_err or usb_out or "usbmux list failed", file=sys.stderr)
        return 2 if "no device" in (usb_err + usb_out).lower() else 1

    phones = _usb_phones(_parse_json_payload(usb_out))
    if not phones:
        print("NO_USB_IPHONE", file=sys.stderr)
        return 2

    phone = phones[0]
    records, wifi_err = _browse_mobdev2(6.0)
    chosen = _pick_record(phone, records) if records else None
    wifi_lockdown_just_set = False
    wifi_power_just_set = False

    if chosen is None:
        wifi_lockdown_just_set = _ensure_wifi_lockdown_on()
        if wifi_lockdown_just_set:
            records, wifi_err = _browse_mobdev2(8.0)
            chosen = _pick_record(phone, records) if records else None
        elif not records:
            time.sleep(2)
            records, wifi_err = _browse_mobdev2(8.0)
            chosen = _pick_record(phone, records) if records else None

    if chosen is None:
        print(
            "Bonjour still empty; trying Wi-Fi radio on over USB (SetWiFiPowerState)...",
            file=sys.stderr,
        )
        ok, err = _set_wifi_power_on(phone.get("udid") or "")
        if not ok:
            print(
                "WIFI_POWER_ON_FAILED (often needs supervised/MDM; turn Wi-Fi on in Control Center): "
                f"{err[:200]}",
                file=sys.stderr,
            )
        else:
            wifi_power_just_set = True
            time.sleep(10)
            records, wifi_err = _browse_mobdev2(8.0)
            chosen = _pick_record(phone, records) if records else None

    if chosen is None:
        print(
            "NO_WIFI_IP: USB iPhone visible but Bonjour mobdev2 advertised no IPv4 "
            f"(usb={phone.get('name')}; phone Wi-Fi off / not associated? {wifi_err[:200]})",
            file=sys.stderr,
        )
        return 4

    payload = {
        "ok": True,
        "ip": chosen["ip"],
        "deviceName": chosen["name"] or phone["name"],
        "udid": phone["udid"],
        "source": "bonjour-mobdev2",
        "wifiLockdownJustSet": wifi_lockdown_just_set,
        "wifiPowerJustSet": wifi_power_just_set,
    }
    print(json.dumps(payload, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
