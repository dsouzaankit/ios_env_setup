#!/usr/bin/env python3
"""Sign an IPA on this PC with SideStore's exported certificate and install it over USB (no tap).

Shared by the sideloaded app repos next to env_setup (Loop Segments: windows/usb/Install-LoopSegmentsIpaViaUsb.ps1,
before it falls back to the SideStore link). Prints one result line (tab separated) as the last line of output.

  check <p12> <cred target> <bundle id> [display name]
      -> READY <installed bundle id> <profile UUID> <profile expiry, UTC> <cert expiry, UTC>
       | NO_P12 | NO_PASSWORD | BAD_P12 <why> | NOT_INSTALLED | NO_PROFILE <why> | NO_DEVICE <why> | ERROR <why>
  sign-install <ipa> <zsign.exe> <p12> <cred target> <work dir> <bundle id> [display name]
      -> INSTALLED <installed bundle id> | (any of the above) | SIGN_FAILED <why> | INSTALL_FAILED <why>

<bundle id> is the app's own id (e.g. com.loopsegments.app); SideStore installs it as <bundle id>.TEAMID, and
[display name] finds it when the id differs. The certificate: SideStore -> Settings -> Certificate Management ->
Export (.p12); its password lives in Windows Credential Manager as a generic credential (cmdkey /generic:<target>).
The profile: the newest unexpired one on the phone for the installed bundle id (SideStore renews it on every
refresh, so it is read from the phone each time) that lists this certificate and this phone. The installed
bundle id is kept, and the Info.plist gets the keys SideStore adds when it signs (sidestore-<bundle id> URL
scheme, io.sidestore.Installed.<bundle id> exported type, ALTBundleIdentifier, ...), so SideStore still sees
the app as its own and keeps it in My Apps. Needs pymobiledevice3 and cryptography.
"""

from __future__ import annotations

import asyncio
import ctypes
import datetime as dt
import os
import re
import subprocess
import sys
import time
import uuid
from ctypes import wintypes


INSTALL_TIMEOUT_S = 120
# Install trace: each step of the USB install with its time, plus the phone's own log lines from the
# services that install, start and stop apps while it runs. A timeout names the last step reached.
TRACE_PATH = os.path.join(os.environ.get("TEMP") or os.path.expanduser("~"), "sidestore-sign-install-trace.log")
TRACE_MAX_BYTES = 8 * 1024 * 1024  # then it is moved to .1 and started fresh
# Lines are "<date> <phone> <process>(<subsystem>)[<pid>] <Level>: <text>": match the process, or the app's
# bundle id anywhere (other processes mention SpringBoard on every screen change, so not the bare name).
SYSLOG_RE = re.compile(
    r" (installd|installcoordinationd|appinstalld|mobile_installation_proxy|runningboardd|lsd|containermanagerd|SpringBoard"
    r"|LoopSegments|SideStore)[\[(]|com\.loopsegments|MobileInstallation",
    re.IGNORECASE)


class InstallTrace:
    """Timed lines in TRACE_PATH. Never raises: tracing must not break an install."""

    def __init__(self, ipa: str):
        self.t0 = time.monotonic()
        self.last = "not started"
        self.fh = None
        try:
            if os.path.getsize(TRACE_PATH) > TRACE_MAX_BYTES:
                os.replace(TRACE_PATH, TRACE_PATH + ".1")
        except OSError:
            pass
        try:
            self.fh = open(TRACE_PATH, "a", encoding="utf-8")
        except OSError:
            pass
        self.write("=" * 20 + f" install {os.path.basename(ipa)} ({os.path.getsize(ipa) / 1048576:.1f} MB)")

    def elapsed(self) -> float:
        return time.monotonic() - self.t0

    def write(self, text: str) -> None:
        if not self.fh:
            return
        try:
            now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
            self.fh.write(f"{now} +{self.elapsed():6.1f}s {text}\n")
            self.fh.flush()
        except OSError:
            pass

    def step(self, text: str) -> None:
        self.last = f"{text} (at {self.elapsed():.0f} s)"
        self.write("STEP " + text)

    def close(self) -> None:
        if self.fh:
            try:
                self.fh.close()
            except OSError:
                pass
            self.fh = None


async def capture_syslog(trace: InstallTrace) -> None:
    """Copy the phone's install-related log lines into the trace until cancelled."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.syslog import SyslogService

    lockdown = None
    try:
        lockdown = await create_using_usbmux()
        async with SyslogService(lockdown) as syslog:
            trace.write("phone log capture started")
            async for line in syslog.watch():
                if SYSLOG_RE.search(line):
                    trace.write("PHONE " + line.strip())
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # noqa: BLE001
        trace.write(f"phone log capture stopped: {type(exc).__name__}: {exc}")
    finally:
        if lockdown is not None:
            try:
                await asyncio.wait_for(lockdown.close(), 5)
            except BaseException:  # noqa: BLE001
                pass


def is_no_device(message: str) -> bool:
    return "NoDevice" in message or "DeviceNotFound" in message or "MuxException" in message


async def resolve_bundle_id(want: str, display_name: str = "") -> str | None:
    """Installed bundle id for want (SideStore / AltStore may append .TEAMID), else None."""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    lockdown = await create_using_usbmux()
    try:
        async with InstallationProxyService(lockdown=lockdown) as iproxy:
            apps = await iproxy.get_apps(application_type="User")
    finally:
        try:
            await lockdown.close()
        except Exception:  # noqa: BLE001
            pass
    if want in apps:
        return want
    for bid in apps:
        if bid.startswith(want + "."):
            return bid
    if display_name:
        for bid, info in apps.items():
            if (info.get("CFBundleDisplayName") or info.get("CFBundleName") or "") == display_name:
                return bid
    return None


def read_credential(target: str) -> str | None:
    """Password of a generic credential in Windows Credential Manager (cmdkey stores UTF-16)."""

    class CREDENTIAL(ctypes.Structure):
        _fields_ = [
            ("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
            ("Comment", wintypes.LPWSTR), ("LastWritten", wintypes.FILETIME),
            ("CredentialBlobSize", wintypes.DWORD), ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
            ("Persist", wintypes.DWORD), ("AttributeCount", wintypes.DWORD),
            ("Attributes", ctypes.c_void_p), ("TargetAlias", wintypes.LPWSTR),
            ("UserName", wintypes.LPWSTR),
        ]

    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    pcred = ctypes.POINTER(CREDENTIAL)()
    if not advapi.CredReadW(target, 1, 0, ctypes.byref(pcred)):  # 1 = CRED_TYPE_GENERIC
        return None
    try:
        blob = ctypes.string_at(pcred.contents.CredentialBlob, pcred.contents.CredentialBlobSize)
    finally:
        advapi.CredFree(pcred)
    try:
        return blob.decode("utf-16-le")
    except UnicodeDecodeError:
        return blob.decode("utf-8", "replace")


def load_p12(path: str, password: str):
    """-> (cert DER, team id, cert expiry). Raises ValueError on a wrong password or a bad file."""
    from cryptography.hazmat.primitives.serialization import Encoding, pkcs12
    from cryptography.x509.oid import NameOID

    with open(path, "rb") as f:
        data = f.read()
    _key, cert, _extra = pkcs12.load_key_and_certificates(data, password.encode("utf-8"))
    if cert is None:
        raise ValueError("no certificate in the .p12")
    ou = cert.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME)
    team = ou[0].value if ou else ""
    return cert.public_bytes(Encoding.DER), team, cert.not_valid_after_utc


def utc(value) -> dt.datetime:
    return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)


async def prepare(p12: str, target: str, want: str, display_name: str = ""):
    """-> (result line, context dict or None). Context: bundle, team, profile bytes, password."""
    if not os.path.isfile(p12):
        return f"NO_P12\t{p12}", None
    password = read_credential(target)
    if password is None:
        return f"NO_PASSWORD\t{target}", None
    try:
        cert_der, team, cert_exp = load_p12(p12, password)
    except Exception as exc:  # noqa: BLE001
        return f"BAD_P12\t{type(exc).__name__}: {exc}", None
    now = dt.datetime.now(dt.timezone.utc)
    if cert_exp <= now:
        return f"BAD_P12\tcertificate expired {cert_exp:%Y-%m-%d}", None

    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.misagent import MisagentService

    try:
        bundle = await resolve_bundle_id(want, display_name)
        if not bundle:
            return "NOT_INSTALLED", None
        lockdown = await create_using_usbmux()
        try:
            udid = lockdown.udid
            async with MisagentService(lockdown) as mis:
                profiles = await mis.copy_all()
        finally:
            try:
                await lockdown.close()
            except Exception:  # noqa: BLE001
                pass
    except Exception as exc:  # noqa: BLE001
        msg = f"{type(exc).__name__}: {exc}"
        return ("NO_DEVICE\t" if is_no_device(msg) else "ERROR\t") + msg, None

    want_app_id = f"{team}.{bundle}"
    for_app = [p for p in profiles
               if (p.plist.get("Entitlements") or {}).get("application-identifier") == want_app_id]
    if not for_app:
        return f"NO_PROFILE\tnone on the phone for {want_app_id} (is the .p12 from this SideStore?)", None
    with_cert = [p for p in for_app if cert_der in (p.plist.get("DeveloperCertificates") or [])]
    if not with_cert:
        return ("NO_PROFILE\tthe phone's profiles for this app list another certificate "
                "(export it again from SideStore)"), None
    usable = [p for p in with_cert
              if utc(p.plist["ExpirationDate"]) > now + dt.timedelta(hours=1)
              and udid in (p.plist.get("ProvisionedDevices") or [])]
    if not usable:
        return f"NO_PROFILE\tthe profile has expired - refresh {display_name or want} in SideStore first", None
    best = max(usable, key=lambda p: utc(p.plist["ExpirationDate"]))
    exp = utc(best.plist["ExpirationDate"])
    line = (f"READY\t{bundle}\t{best.plist.get('UUID', '')}\t{exp:%Y-%m-%d %H:%M}"
            f"\t{cert_exp:%Y-%m-%d}")
    return line, {"bundle": bundle, "profile": best.buf, "password": password}


def add_sidestore_markers(ipa: str, bundle: str, work: str) -> str:
    """Unpack the IPA to work/Payload/<app> with the Info.plist keys SideStore adds when it signs, and
    return the .app path (zsign signs the folder). Without the `sidestore-<bundle id>` URL scheme,
    SideStore's installed check (canOpenURL) treats the app as deleted and drops it from My Apps."""
    import plistlib
    import shutil
    import zipfile

    root = os.path.join(work, "unpacked")
    shutil.rmtree(root, ignore_errors=True)
    with zipfile.ZipFile(ipa) as z:
        z.extractall(root)
    payload = os.path.join(root, "Payload")
    apps = [d for d in os.listdir(payload) if d.endswith(".app")]
    if len(apps) != 1:
        raise ValueError(f"expected one .app in Payload, found {apps}")
    app = os.path.join(payload, apps[0])
    info_path = os.path.join(app, "Info.plist")
    with open(info_path, "rb") as f:
        raw = f.read()
    fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
    info = plistlib.loads(raw)
    original = info.get("CFBundleIdentifier", "")
    if original and original != bundle:
        info["ALTBundleIdentifier"] = original
    info.setdefault("ALTAppGroups", [])
    info.setdefault("ALTPairingFile", "<insert pairing file here>")
    scheme = f"sidestore-{bundle}"
    types = list(info.get("CFBundleURLTypes") or [])
    if not any(scheme in (t.get("CFBundleURLSchemes") or []) for t in types):
        types.append({"CFBundleTypeRole": "Editor", "CFBundleURLName": bundle,
                      "CFBundleURLSchemes": [scheme]})
    info["CFBundleURLTypes"] = types
    # Newer SideStore checks this exported type (not just the URL scheme) to see the app installed.
    ut_id = f"io.sidestore.Installed.{bundle}"
    uts = list(info.get("UTExportedTypeDeclarations") or [])
    if not any(t.get("UTTypeIdentifier") == ut_id for t in uts):
        uts.append({"UTTypeConformsTo": [], "UTTypeDescription": "AltStore Installed App",
                    "UTTypeIconFiles": [], "UTTypeIdentifier": ut_id, "UTTypeTagSpecification": {}})
    info["UTExportedTypeDeclarations"] = uts
    with open(info_path, "wb") as f:
        plistlib.dump(info, f, fmt=fmt)
    return app


async def install_steps(lockdown, ipa: str, trace: InstallTrace) -> None:
    """installation_proxy's install_from_local, one step at a time so the trace shows where it stops:
    the copy to the phone (AFC), then every answer of the phone's installer (Status, PercentComplete)."""
    from pymobiledevice3.exceptions import AppInstallError
    from pymobiledevice3.services.afc import AfcService
    from pymobiledevice3.services.installation_proxy import TEMP_REMOTE_BASEDIR, InstallationProxyService

    with open(ipa, "rb") as f:
        data = f.read()
    trace.step("connecting to the installer")
    async with InstallationProxyService(lockdown=lockdown) as iproxy:
        trace.step("connecting to the phone's file service")
        async with AfcService(lockdown) as afc:
            remote = f"{TEMP_REMOTE_BASEDIR}/{uuid.uuid4()}.ipa"
            try:
                trace.step(f"copying the IPA to the phone ({len(data) / 1048576:.1f} MB)")
                await afc.makedirs(TEMP_REMOTE_BASEDIR)
                await afc.set_file_contents(remote, data)
                trace.step("copied; asked the installer to install, waiting for its first answer")
                await iproxy.service.send_plist({"Command": "Install", "ClientOptions": {}, "PackagePath": remote})
                while True:
                    r = await iproxy.service.recv_plist()
                    if not r:
                        trace.step("the installer closed the connection")
                        raise AppInstallError("the installer closed the connection without finishing")
                    if r.get("Error"):
                        trace.step(f"installer error: {r.get('Error')}: {r.get('ErrorDescription')}")
                        raise AppInstallError(f"{r.get('Error')}: {r.get('ErrorDescription')}")
                    status, pct = r.get("Status"), r.get("PercentComplete")
                    trace.step("installer: " + (status or "?") + (f" {pct}%" if pct is not None else ""))
                    if status == "Complete":
                        return
            finally:
                try:
                    await asyncio.wait_for(afc.rm_single(remote, force=True), 5)
                except BaseException:  # noqa: BLE001
                    pass


async def install(ipa: str) -> str:
    from pymobiledevice3.lockdown import create_using_usbmux

    trace = InstallTrace(ipa)
    syslog_task = asyncio.create_task(capture_syslog(trace))
    try:
        lockdown = await create_using_usbmux()
        try:
            # A stuck installd (it never answered until the phone was restarted) must not hang the deploy.
            await asyncio.wait_for(install_steps(lockdown, ipa, trace), INSTALL_TIMEOUT_S)
            trace.step("installed")
        finally:
            try:
                await asyncio.wait_for(lockdown.close(), 5)
            except BaseException:  # noqa: BLE001
                pass
    except asyncio.TimeoutError:
        trace.write(f"TIMEOUT after {INSTALL_TIMEOUT_S} s; last step: {trace.last}")
        return (f"INSTALL_FAILED\tthe phone's installer did not finish within {INSTALL_TIMEOUT_S} s "
                f"(last step: {trace.last}; trace {TRACE_PATH}) (restart the phone)")
    except Exception as exc:  # noqa: BLE001
        trace.write(f"FAILED {type(exc).__name__}: {exc}; last step: {trace.last}")
        return f"INSTALL_FAILED\t{type(exc).__name__}: {exc} (trace {TRACE_PATH})"
    finally:
        # A few more seconds of the phone's log: what the installer did right after the result.
        await asyncio.sleep(3)
        syslog_task.cancel()
        try:
            await syslog_task
        except BaseException:  # noqa: BLE001
            pass
        trace.close()
    return ""


async def sign_install(ipa: str, zsign: str, p12: str, target: str, work: str, want: str,
                       display_name: str = "") -> int:
    line, ctx = await prepare(p12, target, want, display_name)
    if ctx is None:
        print(line)
        return 1
    print(line)
    os.makedirs(work, exist_ok=True)
    prov = os.path.join(work, "app.mobileprovision")
    out = os.path.join(work, "signed.ipa")
    for f in (prov, out):
        if os.path.exists(f):
            os.remove(f)
    with open(prov, "wb") as f:
        f.write(ctx["profile"])
    try:
        app = add_sidestore_markers(ipa, ctx["bundle"], work)
    except Exception as exc:  # noqa: BLE001
        print(f"SIGN_FAILED\tInfo.plist: {type(exc).__name__}: {exc}")
        return 1
    try:
        # -b keeps SideStore's bundle id; entitlements come from the profile.
        proc = subprocess.run(
            [zsign, "-q", "-k", p12, "-p", ctx["password"], "-m", prov, "-b", ctx["bundle"],
             "-o", out, app],
            # cwd: zsign writes .zsign_cache/ into the current folder.
            capture_output=True, text=True, timeout=300, cwd=work)
    except Exception as exc:  # noqa: BLE001
        print(f"SIGN_FAILED\t{type(exc).__name__}: {exc}")
        return 1
    if proc.returncode != 0 or not os.path.isfile(out):
        why = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip().splitlines()
        print(f"SIGN_FAILED\t{why[-1] if why else proc.returncode}")
        return 1
    err = await install(out)
    try:
        os.remove(out)
    except OSError:
        pass
    if err:
        print(err)
        return 1
    print(f"INSTALLED\t{ctx['bundle']}")
    return 0


def main() -> int:
    a = sys.argv[1:]
    if len(a) in (4, 5) and a[0] == "check":
        line, ctx = asyncio.run(prepare(*a[1:]))
        print(line)
        return 0 if ctx else 1
    if len(a) in (7, 8) and a[0] == "sign-install":
        return asyncio.run(sign_install(*a[1:]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
