# Self-maintenance signing — Phase 1 physical-test status

Status: Apple Account/developer-session Gate 1 is physically confirmed; the app
reported `Apple developer session is ready.` Profile-renewal Gate 2 remains
unproven on the physical iPhone. Do not call profile-only renewal successful
until the device's misagent reading moves to a later expiration in Gate 2.

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
endpoint. Rust logging has no subscriber. Sign-in failures are reduced to a
bounded, sanitized chain of at most eight one-line contexts and 1,200 total
characters. Swift applies the same bounds and redaction again before exposing
the chain. A failed sign-in produces one safe log entry with its stage,
category, and the same sanitized chain; refresh-failure logs contain only the
category.
The 2FA code crosses a synchronous callback, is submitted to Apple, then is
discarded; it is not logged or persisted.

The first physical Gate 1 attempt on iOS 27 stopped in the Rust panic boundary.
The pinned isideload revision enables reqwest's `rustls-no-provider` feature, so
Location Suite now installs isideload's ring provider before constructing the
anisette client, as that revision's own example requires. A caught panic is
reported as `signingCorePanic` with the latest safe stage and a one-line,
redacted string payload. Non-string payloads report only the stage. Response
bodies and backtraces are never returned to the UI.

The second physical Gate 1 attempt confirmed that the provider panic is fixed,
then returned the ordinary category `developerSessionFailed`. The old path
converted the anisette-provider, Apple-login, developer-session, and team-list
errors into plain strings and applied one shared `developerSessionFailed`
fallback afterward. The diagnostic candidate now keeps the operation's stage,
sensible fallback category, and sanitized upstream message together through FFI
JSON and Swift. Account & Signing visibly shows the summary, expanded technical
detail, exact stage, and category. Gate 1 remains failed until a physical build
shows `Apple developer session is ready.` This describes that diagnostic build;
the later fixed build has now passed Gate 1 as recorded below.

The third physical Gate 1 attempt used `https://ani.stikstore.app` as the sole
endpoint and reached the same `appleLogin` / `appleAuthenticationFailed`
result, with no 2FA prompt, developer session, or team list. Provider creation
therefore succeeds with both tested v3 endpoints and the failure is inside
`AppleAccount::login`.

The resulting HTTP 503 has since been confirmed upstream as an Apple edge
rejection of an `X-MMe-Client-Info` value containing `com.apple.dt.Xcode`.
isideload PR #11 changes only that value to `com.apple.akd/1.0`, but its merge
commit `f2fd29ab` is on the `apple-codesign-quick` line, which diverged from the
Location Suite pin and includes unrelated dependency, authentication, 2FA,
storage, and signing changes. Location Suite therefore remains pinned to
isideload `b6d11137` and wraps `RemoteV3AnisetteProvider`: anisette data,
provisioning, storage, transport, and the existing User-Agent all delegate to
the pinned provider, while only `get_client_info` returns the fixed akd client
identity.

This is the value on the real request path. `AppleAccount::builder` stores the
wrapped provider in its `AnisetteDataGenerator`; `AppleAccount::new` asks that
generator for client info and passes it into `GrandSlam::new`; and
`GrandSlam::base_headers` writes its `client_info` into
`X-MMe-Client-Info`. `AppleAccount::login` then sends both SRP requests through
`GrandSlam::plist_request` to the URL bag's `gsService`,
`https://gsa.apple.com/grandslam/GsService2`. A deterministic Rust test creates
the wrapped provider and requires its effective client info to contain
`com.apple.akd/1.0`, exclude `com.apple.dt.Xcode`, and retain
`akd/1.0 CFNetwork/808.1.4` as the User-Agent.

Pinned `rootcause` 0.12.1 represents propagated context as report nodes.
`Report::iter_reports()` visits the root and descendants depth-first, and each
`ReportRef` exposes `format_current_context_unhooked()` plus
`current_context_error_source()` for an ordinary `Error::source()` chain.
`Report::to_string()` was not top-level-only: the default report formatter
includes the complete tree, but begins with a newline. The previous sanitizer
selected `lines().next()`, received that empty formatter header, and replaced
it with the stage fallback. The new extractor reads individual contexts and
ordinary sources only. It never visits report attachments (where isideload can
store response/plist material) and never uses Debug formatting.

SideInstaller's `format!("login failed: {e}")` interpolates that same full
`rootcause` 0.12.1 display tree; it is not a more precise typed diagnostic API.
It also has no equivalent attachment-exclusion and bounded-redaction boundary,
so copying its formatting would risk exposing response material. Location
Suite instead uses `iter_reports()`, `format_current_context_unhooked()`, typed
context downcasts, and `current_context_error_source()`/`Error::source()`.

SideInstaller `main` was checked again and remains `9272b907`; isideload `main`
likewise remains the Location Suite pin `b6d11137`. SideInstaller's wrapper
does go directly from `AppleAccount` login to `DeveloperSession::from_account`,
then lets `SideloaderBuilder::get_team` list teams, but its patched dependency is
a vendored isideload 0.2.22 snapshot at `e319d931`, not current 0.3.17. That
older RemoteV3 implementation fetches `/v3/client_info` from the anisette
server; current 0.3.17 hard-codes client metadata. It also uses the older sync
2FA callback and a different reqwest/TLS feature set. The provider inputs are
otherwise equivalent: selected endpoint, persistent filesystem storage, and
serial `"0"`. Its machine name is supplied only after login while building the
sideloader, so it cannot explain an `appleLogin` failure.

Current iLoader `348eefd7` uses isideload 0.3.17 from its
`apple-codesign-quick` lock revision `f6a4d5db`, while Location Suite uses later
main `b6d11137`. iLoader lowercases the account, uses persistent keyring (or
filesystem) storage, serial `"0"`, an async 2FA callback, AWS-LC as the rustls
provider, and no outer 45-second service budget. Its isideload revision sends
`com.apple.akd/1.0` client metadata and disables idle HTTP pooling; the Location
Suite pin originally supplied Xcode client metadata and no longer disables that
pool. The confirmed fix overrides only the blocked client identity; it does not
adopt the branch's HTTP pooling or other behavioral changes.

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

For a Gate 1 reproduction, install the newer IPA over the current app, stay on
Wi-Fi with LocalDevVPN connected, configure one v3 anisette endpoint, enter
credentials on-device, and tap **Sign In / Test Developer Session** once. The
expected progression is Apple login, a 2FA prompt if Apple requires it,
developer-session creation, team listing, then
`Apple developer session is ready.` Stop there; do not tap **Refresh Signing
Now** during Gate 1.

Gate 1 has been physically confirmed: the Apple Account connected and the app
reported `Apple developer session is ready.` This does not establish Gate 2;
profile-only renewal still requires the authoritative later-expiry check below.

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
