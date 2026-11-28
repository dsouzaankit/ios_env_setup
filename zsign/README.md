# zsign: sign on the PC with SideStore's certificate

Shared kit for installing a sideloaded app over USB **without a tap in SideStore**: sign the IPA on this PC with the certificate SideStore uses, then install it with pymobiledevice3. Used by [ios_3d_loop_segments](https://github.com/dsouzaankit/ios_3d_loop_segments) (`deploy.ps1` → `windows\usb\Install-LoopSegmentsIpaViaUsb.ps1`); other app repos next to `env_setup` can call the same files.

**It installs; it cannot refresh.** zsign reuses the newest provisioning profile already on the phone for that app, so the 7-day expiry stays where SideStore last put it. Only a SideStore (or iloader) sign-in gets a new profile from Apple. See [../sidestore/README.md](../sidestore/README.md).

## Files

| File | In git | Role |
|------|--------|------|
| `SideStoreSigning.ps1` | yes | Dot-source: paths, pinned zsign version + SHA-256, `Find-SideStoreZsign`, `Install-SideStoreZsign`, the password credential helpers, `Copy-SideStoreSigningP12` |
| `sidestore_sign.py` | yes | `check` / `sign-install` for one app (bundle id + display name as arguments); prints one tab-separated result line |
| `zsign.exe` | no | [zsign](https://github.com/zhlynn/zsign) `v1.1.3` (Windows x64), downloaded by `Install-SideStoreZsign` |
| `signing.p12` | no (`*.p12`) | SideStore's exported certificate **with its private key**. It syncs with this folder (pCloud), so every PC on that folder has it |

The **.p12 password** is never in a file. Each PC keeps it in Windows Credential Manager as the generic credential **`SideStore-signing`**. Older setups used `LoopSegments-signing`, and `Resolve-SideStoreSigningCredTarget` still finds that one.

## Set up a PC

Loop Segments does all of this with `windows\setup\Set-LoopSegmentsSigning.ps1`. Setup runs it, and it skips each step that's already done.

1. **zsign:** `Install-SideStoreZsign` downloads the pinned zip from GitHub, checks the SHA-256, and unzips it here.
2. **Certificate:** SideStore → **Settings → Certificate Management** → long-press the certificate (named after the tool that made it, e.g. **iLoader (R)**) → **Export Certificate → Export Full (.p12)**. Pick **Full**: zsign needs the private key. Choose a password and save the export to **iCloud Drive → Downloads**; it's named `iPhone Developer_ <Apple ID> (<cert ID>).p12`. Older SideStore builds have **Export Signing Certificate...** near the bottom of Settings instead. Then `Copy-SideStoreSigningP12 -Source <export>` (Loop Segments: `Set-LoopSegmentsSigning.ps1 -P12 <export>`). **Delete the export from iCloud Drive afterwards:** it is your signing key.
   iloader gave SideStore this certificate when it installed SideStore, but iloader itself can't export it: it only keeps the private key in Windows Credential Manager (`<sha256 of Apple ID>/key.iloader`).
3. **Password:** `Set-SideStoreSigningPassword` (cmdkey prompts for it, so it never appears on a command line). By hand: `cmdkey /generic:SideStore-signing /user:p12 /pass`. Each PC needs its own; the folder syncs, the password doesn't.

**Not under `%LOCALAPPDATA%`:** the Microsoft Store Python (`py` from WindowsApps) sees its own private copy of `AppData\Local`, so it can't read files placed there from outside. That's why the certificate and zsign live here, and why apps should put the work folder in `%USERPROFILE%`.

## How it works

1. Reads the installed bundle id from the phone. SideStore installs apps as `<id>.TEAMID` (e.g. `com.loopsegments.app.<TEAMID>`); the script keeps that id.
2. Reads the phone's provisioning profiles over USB (misagent) and picks the **newest unexpired** one that is for that app id, lists the .p12's certificate, and lists this phone.
3. Adds the Info.plist keys SideStore adds when it signs: the URL scheme `sidestore-<id>`, the exported type `io.sidestore.Installed.<id>` (`UTExportedTypeDeclarations`), `ALTBundleIdentifier` (the original id), `ALTAppGroups` and `ALTPairingFile`. SideStore uses the URL scheme and the exported type to tell whether its apps are still installed; without them it treats the app as deleted and **drops it from My Apps** (the first PC-signed Loop Segments builds did). If an app is missing from My Apps, add it back once with **My Apps → +** and its IPA (data is kept); later PC installs keep it listed.
4. Signs with `zsign -k signing.p12 -m <profile> -b <bundle id>` (entitlements come from the profile) and installs with installation_proxy, giving up after **120 s** (`INSTALL_FAILED … restart the phone`).

Same certificate and bundle id as SideStore, so app data is kept and no new App ID is used.

## Check results

Free-account profiles last **7 days**, and every SideStore refresh puts a new one on the phone, so each run reads the current one. The **certificate** lasts a year (`READY` prints its expiry).

| Result | Meaning / fix |
|---|---|
| `NO_P12` / `NO_PASSWORD` | Put the export here (`Copy-SideStoreSigningP12`) / save the password on this PC |
| `BAD_P12` | Wrong password (save it again) or expired certificate |
| `NO_PROFILE … expired` | No SideStore refresh for 7 days: refresh the app in SideStore |
| `NO_PROFILE … another certificate` | SideStore's certificate changed (revoked, e.g. in iloader, or a new one made): export again |
| `NOT_INSTALLED` | Install the app once through SideStore first (it registers the app id and profile) |
| `NO_DEVICE` | No iPhone on USB |

## Use from an app repo

```powershell
. ..\env_setup\zsign\SideStoreSigning.ps1
$zsign = Find-SideStoreZsign
$cred  = Resolve-SideStoreSigningCredTarget
py -3.12 $SideStoreSignPy check $SideStoreSigningP12 $cred com.example.app 'Example'
py -3.12 $SideStoreSignPy sign-install <ipa> $zsign $SideStoreSigningP12 $cred <local work dir> com.example.app 'Example'
```

Results: `READY <installed id> <profile UUID> <profile expiry UTC> <cert expiry>`, or `NO_P12`, `NO_PASSWORD`, `BAD_P12`, `NOT_INSTALLED`, `NO_PROFILE <why>`, `NO_DEVICE`, `SIGN_FAILED`, `INSTALL_FAILED`, `INSTALLED <installed id>`. See [Check results](#check-results). The app must already be installed by SideStore with this certificate, and the phone must be on USB. It needs `pymobiledevice3` and `cryptography`.

Use a **local** work folder, not one on P:. pCloud holds new files while it uploads them, and that once hung the USB install.

## Keep the certificate valid

- When SideStore offers to **revoke** the certificate, for example after a failed sign-in, choose **Continue without revoking**. Revoking it invalidates `signing.p12` here.
- After SideStore makes a **new** certificate (a reinstall, or a reset certificate), export it again and replace `signing.p12`. Until then `check` says `NO_PROFILE … another certificate`.

## pCloud hang

If a USB install stalls right after the "phone has N" line, with no `Signing on this PC…` line and no Python child process, pCloud Drive is stuck on `zsign.exe` here. Even `Test-Path` on it never returns, and the processes stuck on it can't be killed (Task Manager / `Get-CimInstance` still list them, while `Stop-Process` says there is no such process). It looks like a USB wedge, but replugging or restarting the phone does not help. **Fix: restart pCloud Drive** (tray → Exit, start it again), then retry. To check, run this with a timeout:

```powershell
$j = Start-Job { Test-Path -LiteralPath $args[0] } -ArgumentList 'P:\all_scripts\iOS apps\env_setup\zsign\zsign.exe'; Wait-Job $j -Timeout 10
```

If it keeps hanging, copy zsign to a local folder and point the app's config at it (Loop Segments: `zsignExe` in `windows\loop-segments-windows.json`).

## USB install times out

If signing finishes (the `Signing on this PC…` line appears) but the install then times out or ends in `INSTALL_FAILED`, the phone's install service is usually stuck. Restart the iPhone, unlock it, keep it on USB, and run the install again.

To find out why, read `%TEMP%\sidestore-sign-install-trace.log` (moved to `.1` past 8 MB). Every install adds a block: each `STEP` with its time since the start (connect, copy the IPA to the phone, then every answer of the phone's installer: `Status` and `PercentComplete`), and `PHONE` lines, the phone's own log from the services that install, start and stop apps (installd, runningboardd, lsd, containermanagerd, SpringBoard, the app itself) from the start until 3 s after the result. The `INSTALL_FAILED` line names the last step reached:
- stuck at `copying the IPA to the phone`: the USB file copy hung, not the installer;
- stuck at `waiting for its first answer`: the installer never took the job;
- stuck at an `installer: <Status> <n>%` step: the installer stopped there; the `PHONE` lines just before the timeout say what it was waiting for (e.g. the running app to quit, or the phone to be unlocked).
