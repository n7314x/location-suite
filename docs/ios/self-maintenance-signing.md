# Self-maintenance signing — Phase 1 physical-test candidate

Status: implemented and deterministically tested in CI scope; **not yet proven
on the physical iPhone**. Do not call profile-only renewal successful until the
device's misagent reading moves to a later expiration in Gate 2.

This milestone deliberately ends at account sign-in and profile-only renewal.
IPA signing, self-install, private GitHub releases, and maintenance App Intents
remain behind the physical gates in the project plan. SideStore is not required
by this Phase 1 path; iLoader remains the recovery route if the app expires.

## Profile-only pipeline

```text
trusted installed profile from misagent
  -> sign in through RemoteV3 anisette + Apple GrandSlam
  -> DeveloperSession::from_account
  -> select the installed profile's exact team
  -> ensure_device_registered(current iPhone)
  -> list_app_ids(team)
  -> require the installed portal App ID to already exist
  -> downloadTeamProvisioningProfile
  -> require the returned candidate expiry to be later
  -> misagent_install through an already-open RSD session
  -> misagent_copy_all from the phone
  -> PASS only if the phone reports a later expiry
```

The last read is authoritative. A successful HTTP response or a profile blob
is never recorded as success by itself. Failures update attempt/category data
but do not overwrite the last verified expiry or last successful refresh.

No certificate API is exposed by the Phase 1 Rust FFI. It cannot create,
replace, or revoke a certificate. `downloadTeamProvisioningProfile` lets Apple
bind the renewed profile to the team's existing usable development
certificate(s). Certificate creation and `MaxCertsBehavior::Error` belong to
the later full-signing milestone, after profile renewal is physically proven.

## Authentication and anisette

Swift owns the UI and asynchronous operation state. A serial account queue calls
a narrow Rust C ABI built on pinned isideload 0.3.17:

- `ls_apple_sign_in`
- `ls_account_select_team`
- `ls_refresh_profile`

The default v3 anisette endpoint is `https://ani.sidestore.io`; the default
fallback is current isideload's `https://ani.stikstore.app`. Both are editable,
more HTTPS fallbacks may be supplied, and each attempt has a 45-second timeout.
Only connectivity/anisette failures advance to the next endpoint. Invalid Apple
credentials, cancelled 2FA, and Apple GrandSlam outages do not fan out into
repeated login attempts.

The password is passed to isideload's Apple login and never to the anisette
endpoint. Rust logging has no subscriber, FFI errors are reduced to one line,
and Swift redacts known credentials and token-shaped values before exposing an
error. Logs contain only operation categories for refresh failures. The 2FA code
crosses a synchronous callback, is submitted to Apple, then is discarded; it is
not logged or persisted.

Current isideload does not expose a reusable authenticated Apple session/token
that survives process launch. The developer session therefore remains in memory
only. Routine foreground renewal after relaunch requires either password entry
or the explicit **Remember Password on This iPhone** option.

## Persisted state

| Value | Storage | Protection |
| --- | --- | --- |
| Apple Account email | UserDefaults | non-secret preference |
| Remember-password choice | UserDefaults | non-secret preference |
| Apple password, only when opted in | iOS Keychain generic password | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronizing, data-protection Keychain |
| Developer session | memory only | destroyed on sign-out/process exit |
| 2FA code | memory only for callback | immediately discarded |
| v3 anisette device identity/state | `Application Support/SelfMaintenancePrivate` | complete iOS file protection |
| selected team and endpoint configuration | UserDefaults | non-secret preferences |
| attempts, verified expiry before/after, failure category | UserDefaults | contains no credentials |

Turning Remember Password off immediately deletes the Keychain item. Sign Out
also deletes it. Anisette identity is retained on sign-out so a stable device
identity is not churned. No self-maintenance private files are part of an export,
and central in-memory log sanitization removes password/token/key/2FA/labelled
coordinate material.

## Device transport and warm-session safety

Phase 1 creates no maintenance RemotePairing connection. On the existing serial
`LocationSimulationCommandQueue`, it chooses:

1. the retained LocationSimulation adapter/RSD handshake, only while idle; or
2. `JITEnableContext`'s already-established adapter/RSD handshake.

It opens lockdownd and misagent as additional services on that selected RSD
session. It never calls `ensureTunnel`, never disconnects the warm session, and
rechecks simulation activity on the device queue immediately before touching a
handle. An active simulation wins.

If there is no reusable transport, the ordinary app connection flow may build
one through LocalDevVPN. Phase 1 does not perform its own handshake. In
particular, an LTE cold state with no reusable session stops and requires Wi-Fi;
it does not sacrifice or rebuild an overnight-valid warm simulation session.

SideInstaller's CoreDeviceProxy route was reviewed at its pinned commit. It is
not copied into Phase 1 because reusing an existing RSD session is smaller and
avoids changing the proven LocationSimulation lifecycle. CoreDeviceProxy remains
a candidate for the isolated self-sign/install transport after Gate 2; it is not
a reason to resume the cold-LTE investigation.

## Foreground policy and reminders

Auto Refresh Signing defaults on. A foreground event attempts renewal when the
trusted device expiry has at most 72 hours remaining, an in-memory session or
remembered password exists, a safe existing device transport exists, and no
simulation/maintenance operation conflicts. Failures cool down for six hours;
successful attempts cool down for twelve. Credential or LocalDevVPN needs show
one clear foreground prompt rather than retrying in a loop.

Local notifications are scheduled for approximately 72, 48, and 24 hours before
the device-reported expiry and are cancelled/rescheduled after a verified
success. They are reminders only. The implementation does not use or promise
Background App Refresh.

## Physical gates

### Gate 1 — account and 2FA

1. Install the PR's unsigned IPA with iLoader using the same effective bundle
   identifier as the current installation; do not uninstall first.
2. Launch LocalDevVPN, then Location Suite.
3. Open **Settings → Self Maintenance → Account Settings**.
4. Leave Remember Password off for the first pass. Enter the Apple Account and
   password, then tap **Sign In / Test Developer Session**.
5. Enter the six-digit Apple code if prompted. Select the team whose identifier
   matches the installed profile if the app cannot select it uniquely.

Pass evidence:

- a screenshot of Account & Signing showing `Apple developer session is ready`,
  the selected team identifier, and the active anisette server;
- a sanitized Location Suite log screenshot covering the attempt (no Apple ID,
  password, 2FA code, session token, or response body);
- Apple portal/device evidence that no certificate was revoked or newly created.

### Gate 2 — authoritative expiry increase

1. Capture **Settings → Self Maintenance** before refresh, including **Signing
   expires**, **Last checked**, and the current team.
2. Ensure no point/route simulation is active. Preserve an idle warm session if
   one exists.
3. Tap **Refresh Signing Now** once.
4. Wait for `Signing renewed and verified on this iPhone.`
5. Capture the same section after refresh plus the sanitized log lines.
6. Force-quit and relaunch Location Suite to confirm it still launches and the
   later expiry remains visible.

Pass requires the after value read through `misagent_copy_all` to be strictly
later than the before value. The expected state is roughly seven days remaining,
`Last Refresh` set to the attempt time, no failure category, app data unchanged,
and the warm LocationSimulation session/configuration not deliberately torn
down. If the date is unchanged, the gate fails even if Apple returned a profile.

Stop after recording Gate 2. Gate 3 repeats renewal and checks certificate/App ID
stability. Only after those gates should local IPA signing and self-install code
be added.

## Failure boundaries

- If the app fully expires, it cannot launch or repair itself; reinstall with
  iLoader and preserve the same bundle ID for an over-install recovery.
- Apple/anisette 503 or transport failure leaves the installed profile,
  certificate, account configuration, anisette identity, and cached good expiry
  untouched. Retry on a later foreground event.
- Without LocalDevVPN or an existing RSD transport, renewal cannot reach
  lockdownd/misagent. The UI offers **Open LocalDevVPN**.
- Foreground execution, notification delivery, Apple service availability, 2FA,
  iOS process lifetime, and a user opening the app before expiry cannot be
  guaranteed. No Background App Refresh claim is made.
