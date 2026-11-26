# SideStore (free Apple ID sideloading)

Shared setup and troubleshooting for the sideloaded apps that use this repo ([ios_3d_loop_segments](https://github.com/dsouzaankit/ios_3d_loop_segments), web_auto_parking). Each app's own docs keep only its install steps (where its IPA comes from, app-specific hangs) and link here.

[SideStore](https://sidestore.io) signs and refreshes on the phone (no AltServer). Official setup: [Prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) → [Install](https://docs.sidestore.io/docs/installation/install). The iloader installer is kept on the PC in this folder (`iloader-windows-x64.msi`, gitignored).

**Confirmed here:** SideStore **stable** showed the same **incorrect data format** as AltStore when installing/refreshing; **nightly** succeeded. Prefer **nightly** until stable catches up (but see [Pairing file not found](#reinstall-or-update-sidestore-with-iloader), where stable was the fix).

| Need | Notes |
|------|--------|
| **iloader** (PC, once) | USB install SideStore; later: pairing repair ([pairing file](https://docs.sidestore.io/docs/advanced/pairing-file)) |
| **LocalDevVPN** (App Store) | **Connected** for every install / refresh / update in SideStore |
| **Wi‑Fi** | Required (not cellular-only) while using SideStore |
| **Apple ID** | Free ID limits: **3** apps, **~7-day** provisioning profiles |
| **Developer Mode** | Settings → Privacy & Security → on (after Trust) |

**Free 3-app slots:** SideStore counts as **1**. Example that blocks a 4th install: AltStore + Web Auto Parking + Loop Segments. **Delete AltStore** if you switch to SideStore (do not keep both on a free ID). Keep apps that need background / LAN / Keep Alive as normal sideloaded apps, not LiveContainer guests.

**Install an app:** fully local IPA on the phone (wait out iCloud stubs) → LocalDevVPN **Connect** → **SideStore → My Apps → +** → pick the IPA (or Files → Share → SideStore) → Trust the developer if prompted.

**Refresh:** LocalDevVPN on → tap the **7 DAYS** counter / **Refresh All**. No PC needed, also after expiry. PC only if the pairing file dies (iloader). Optional: [Shortcuts auto-refresh](#sidestore-shortcuts-auto-refresh-optional).

**Refresh vs PC signing:** only a SideStore (or iloader) sign-in gets Apple to issue a new 7-day profile. A PC-side re-sign (e.g. zsign with SideStore's exported certificate) reuses the newest profile already on the phone, so it cannot extend an app's expiry. An app whose profile lapses just stops opening (data kept); the next successful refresh brings it back.

## Troubleshooting

**incorrect data format:** (1) partial iCloud IPA, (2) bad anisette. Fix IPA locality first; then SideStore Settings → change **Anisette** server / sign out+in / re-place pairing with iloader. If stable still fails, use **nightly**. On Apple ID login: **User Customizations** → turn off **On-Device Anisette** (or switch anisette server).

**Refresh fails: “Device Reachability (Ping): Unreachable”** (Settings → **Health Check**; LocalDevVPN shows Connected). LocalDevVPN **1.3.0** (Sep 2026) changed its tunnel addresses to `10.7.1.x`; SideStore builds older than about Sep 3, 2026 can't reach the device on them ([SideStore #1464](https://github.com/SideStore/SideStore/issues/1464)).

1. **Fix:** [reinstall SideStore with iloader](#reinstall-or-update-sidestore-with-iloader) — nightly has the LocalDevVPN 1.3.0 fix; if nightly then shows **Pairing file not found**, install **stable** instead (what worked here, Sep 2026).
2. **Stopgap** (can't reinstall yet, or ping still fails on stable): LocalDevVPN settings → **Tunnel IP** `10.7.0.2/30`, **Device IP** `10.7.0.1/32` → disconnect/reconnect. Restore the defaults once SideStore works with them.
3. Still red: pairing not verified → re-place pairing with iloader; other VPN (Surfshark / Clash) connected on the phone → disconnect it; Wi‑Fi on.

**SideStore 0.7.0 refresh errors** (seen here Oct 2026, iOS 26):

| Error | Fix |
|-------|-----|
| **`DeviceEndpointNotInitialized`** (“unable to reach the device endpoint”; Connection Config shows Tunnel/Device IP **N/A**) | **Restart the iPhone**, reconnect LocalDevVPN, refresh — fixed it here ([SideStore #1621](https://github.com/SideStore/SideStore/issues/1621)). Otherwise: On-Device Anisette off, re-place pairing with iloader, reinstall LocalDevVPN, or downgrade SideStore to 0.6.4. |
| **`NSURLErrorDomain` code `-1001`** (request timed out on install / +) | **Restart the iPhone**, reconnect LocalDevVPN (Wi‑Fi), wait until the IPA is fully local (no iCloud badge), then **My Apps → +** again — fixed it here. |
| **`VerifyCertificateOperation`** → **`targetAppBundle is missing in context`** | Not a certificate problem: SideStore lost its stored copy of the app. LocalDevVPN on → **My Apps → +** → pick that app’s fully local IPA (each app repo's `copy-to-icloud.ps1`) → Refresh All. Same Apple ID ⇒ app data kept. Do this for every app the error names ([SideStore #1575](https://github.com/SideStore/SideStore/issues/1575)). |

### Apple ID sign-in fails with HTTP 503 (since 2026-11-20)

**Symptom:** SideStore sign-in → **503 Service Temporarily Unavailable** on **every** anisette server (seen here Nov 26, 2026). Switching servers does not help: the 503 comes from Apple, not anisette.

**Cause:** Since 2026-11-20 Apple's sign-in server (`gsa.apple.com/grandslam/GsService2`) answers 503 to any request whose `X-MMe-Client-Info` header says `macOS;`, before it checks the password. SideStore 0.7.0 / nightly still sends `macOS;`. With `Mac OS X;` instead, the old `10.12.6` identity is then refused (`-22410` / `-23782`, "macOS 10.13 or later required"), so the version must change too ([SideStore #1745](https://github.com/SideStore/SideStore/issues/1745)).

**Workaround** (confirmed by several users in #1745; **worked here Nov 26, 2026**: signed in, Refresh gave a new 7-day profile, same certificate kept):

1. **Settings → User Customizations →** **On-Device Anisette** off (on gives `-45063`) → force-quit and reopen SideStore.
2. **Settings → Anisette Servers →** **jkcoxson** (`https://mac-ani.jkcoxson.com`, a Mac-based server) → **Auto Rotation** off.
3. **User Customizations → Anisette Client Configuration → Remote Server Sync → Fetch → Save as Overrides.**
4. **Client Info** → `<MacBookPro13,3> <Mac OS X;26.6;25F84> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`; keep the fetched User Agent → **Save Overrides**.
5. **Reset adi.pb** with **keep headers** ticked → force-quit → LocalDevVPN on → sign in.

| Watch out for | Why |
|---|---|
| **Reset to Defaults** in Anisette Client Configuration | Puts `macOS;` back → 503 again. Never tap it. |
| Retrying again and again | Each failure is another Apple request; it can add a rate limit on top. |
| SideStore offers to **revoke** the certificate (after closing a failed login page) | Choose **Continue without revoking**. A certificate exported from SideStore for PC signing (Loop Segments: `windows\signing\signing.p12`) is that same certificate. |
| `-45061` / `-22410` after the change | **Reset adi.pb** again (keep headers) → reopen → sign in. |
| Refresh: **Could not locate signing certificate** | Long-press the app in **My Apps** → reset its certificate → **Refresh All**. |

### Reinstall or update SideStore with iloader

Use **iloader** over USB — it works even when on-device refresh is broken and places a fresh pairing file. Check the installed version afterward: SideStore **Settings** tab → bottom of the page (or iOS **Settings → General → iPhone Storage → SideStore**).

1. [iloader](https://github.com/nab138/iloader/releases) **2.1.0+** on the PC.
2. USB + keep the phone **unlocked** (passcode must be set) → **Trust** on the phone; select the device in iloader (trust again if asked).
3. Sign in with the **same Apple ID** SideStore uses.
4. **Installers** → **SideStore (Nightly)** or **SideStore (Stable)** (LiveContainer users: the matching **LiveContainer + SideStore** entry).
5. Phone: LocalDevVPN → Connect → SideStore → **Health Check**.

**iloader Apple ID sign-in / signing keeps failing** (auth, provisioning, “incorrect format”): try another anisette server in iloader, then iloader Settings → **Reset Anisette State**. That deletes iloader’s saved Apple device identity (stored in the Windows credential store) so the next sign-in sets it up fresh — expect a **2FA code** again. It does not touch the phone, SideStore, apps, pairing files, or SideStore’s own anisette settings (those are in SideStore Settings: anisette server / reset adi.pb / On-Device Anisette). iloader 2.4.2 `-23782` is the [503 incident](#apple-id-sign-in-fails-with-http-503-since-2026-11-20)'s old-identity refusal: Reset Anisette State, then quit and reopen iloader.

**Pairing file not found** (seen here after iloader **nightly**): iloader → **Delete Stored Pairing** → select device → Trust → **Manage Pairing File** → **Place** next to SideStore (expect green “placed successfully”). Restart phone + PC and retry if needed. **Resolved here by installing SideStore (Stable) via iloader** instead of nightly.

**My Apps is empty after the reinstall** (only SideStore listed): SideStore’s installed-app list was reset; the apps are still on the phone with their data. Re-add each one through SideStore — **do not delete the apps first**:

1. Put a **fully local** IPA on the phone (each app repo's `copy-to-icloud.ps1` → iCloud Downloads; wait for full size in Files).
2. LocalDevVPN on → **SideStore → My Apps → +** → pick the IPA.
3. Same Apple ID ⇒ installs over the existing app (data kept) and the **7 DAYS** counter returns. A **second** icon means a different Apple ID/team signed it — delete the new copy, not the original.

Also make sure only **one** SideStore icon remains (each copy uses one of the 3 free slots).

**No PC:** apply the LocalDevVPN stopgap above first, then download the [nightly SideStore.ipa](https://github.com/SideStore/SideStore/releases/download/nightly/SideStore.ipa) in Safari (wait until fully saved) → **SideStore → My Apps → +** → pick it. If the self-update seems to hang near the end, go to the Home screen to let it finish ([SideStore troubleshooting](https://docs.sidestore.io/docs/troubleshooting)).

### SideStore Shortcuts auto-refresh (optional)

SideStore registers a Shortcuts action (**Refresh All Apps**). Community setup (also discussed on SideStore GitHub):

1. **Shortcuts** → new shortcut → **Apps → SideStore → Refresh All Apps** (optional: connect **LocalDevVPN** / WireGuard first, **Wait** 10–20s, then refresh; some people run refresh twice or disconnect VPN in a second automation a few minutes later).
2. Run the shortcut once manually; grant **Always Allow** on every permission prompt.
3. **Automation** → **Personal Automation** → e.g. **Time of Day** (daily or 2×/week) or **Is Charging** → **Run Shortcut** → pick that shortcut → **Run Immediately** (Ask Before Running **off**).

Official SideStore docs still say: Wi‑Fi + LocalDevVPN on, then tap **7 DAYS** / refresh in My Apps ([install](https://docs.sidestore.io/docs/installation/install), [FAQ](https://docs.sidestore.io/docs/faq) — background refresh is mentioned; Shortcuts scheduling is not the primary guide).

| Caveat | Detail |
|--------|--------|
| **Wi‑Fi + LocalDevVPN** | Required for refresh. Cellular-only fails. VPN on-demand helps if WireGuard/LocalDevVPN drops. |
| **Not 100% reliable** | Timeouts, “file doesn’t exist” (bad/missing pairing — fix with [iloader pairing](https://docs.sidestore.io/docs/advanced/pairing-file)), VPN detection races in Shortcuts. |
| **Locked phone** | Often fails on newer iOS when the screen is locked / no UI context; unlocked is more reliable. |
| **Trust still manual** | Automation does **not** tap Trust / Allow & Restart — Apple blocks that. |
| **First-run permissions** | Without **Always Allow**, Automation stops for prompts. |
| **Still check weekly** | If the shortcut fails for a few days, certs expire — open SideStore and refresh manually. |
