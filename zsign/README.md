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
2. **Certificate:** SideStore → **Settings → Certificate Management** → long-press the certificate → **Export Certificate → Export Full (.p12)**. Choose a password and save the export to iCloud Drive, then `Copy-SideStoreSigningP12 -Source <export>` (Loop Segments: `Set-LoopSegmentsSigning.ps1 -P12 <export>`). **Delete the export from iCloud Drive afterwards:** it is your signing key.
3. **Password:** `Set-SideStoreSigningPassword` (cmdkey prompts for it, so it never appears on a command line).

## Use from an app repo

```powershell
. ..\env_setup\zsign\SideStoreSigning.ps1
$zsign = Find-SideStoreZsign
$cred  = Resolve-SideStoreSigningCredTarget
py -3.12 $SideStoreSignPy check $SideStoreSigningP12 $cred com.example.app 'Example'
py -3.12 $SideStoreSignPy sign-install <ipa> $zsign $SideStoreSigningP12 $cred <local work dir> com.example.app 'Example'
```

Results: `READY <installed id> <profile UUID> <profile expiry UTC> <cert expiry>`, or `NO_P12`, `NO_PASSWORD`, `BAD_P12`, `NOT_INSTALLED`, `NO_PROFILE <why>`, `NO_DEVICE`, `SIGN_FAILED`, `INSTALL_FAILED`, `INSTALLED <installed id>`. The app must already be installed by SideStore with this certificate, and the phone must be on USB. The script keeps SideStore's `<id>.TEAMID` bundle id and adds the Info.plist keys SideStore adds (the `sidestore-<id>` URL scheme, the `io.sidestore.Installed.<id>` exported type, `ALTBundleIdentifier`), so the app stays in SideStore's **My Apps**. It needs `pymobiledevice3` and `cryptography`.

Use a **local** work folder, not one on P:. pCloud holds new files while it uploads them, and that once hung the USB install.

## Keep the certificate valid

- When SideStore offers to **revoke** the certificate, for example after a failed sign-in, choose **Continue without revoking**. Revoking it invalidates `signing.p12` here.
- After SideStore makes a **new** certificate (a reinstall, or a reset certificate), export it again and replace `signing.p12`. Until then `check` says `NO_PROFILE … another certificate`.

## pCloud hang

If a USB install stalls right after the "phone has N" line, with no `Signing on this PC…` line and no Python child process, pCloud Drive is stuck on `zsign.exe` here. Even `Test-Path` on it never returns. To check, run this with a timeout:

```powershell
$j = Start-Job { Test-Path -LiteralPath $args[0] } -ArgumentList 'P:\all_scripts\iOS apps\env_setup\zsign\zsign.exe'; Wait-Job $j -Timeout 10
```

If it keeps hanging, copy zsign to a local folder and point the app's config at it (Loop Segments: `zsignExe` in `windows\loop-segments-windows.json`).

## USB install times out

If signing finishes (the `Signing on this PC…` line appears) but the install then times out or ends in `INSTALL_FAILED`, the phone's install service is usually stuck. Restart the iPhone, unlock it, keep it on USB, and run the install again.
