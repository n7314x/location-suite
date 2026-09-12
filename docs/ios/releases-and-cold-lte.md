# Releases, free signing, and cold LTE diagnostics

Implementation snapshot: 2026-09-10, with the Phase 1 self-maintenance addendum
below. This document covers unsigned release delivery, the legacy SideStore
handoff, signing-expiry guidance, and cold phone-local RemotePairing
observability/recovery. It does not change route or saved-location features.

## Release architecture

The canonical artifact stays unsigned:

```text
private location-suite source
  -> Xcode 27 deterministic tests
  -> scripts/build_unsigned_ipa.sh
  -> unsigned Payload/TLocation.app
  -> LocationSuite.ipa
  -> verified artifact-only public host
  -> SideStore signs and provisions locally
```

Both pull-request CI and the `v*` tag workflow invoke
`scripts/build_unsigned_ipa.sh`. The script archives once, requires an arm64
executable and `vn.truongkma.tlocation`, rejects a signature or embedded profile,
and packages exactly one `Payload/TLocation.app`. It derives version, build, and
minimum OS from the built app—not from duplicated workflow constants.

The checked-in target is prepared for `v1.5.0`: `MARKETING_VERSION=1.5.0` and
`CURRENT_PROJECT_VERSION=2`. Every later stable release must increment the build
number and use a tag whose `v`-stripped value exactly equals the built marketing
version. The generator rejects a repeated marketing version, a repeated
version/build pair, or a build number not greater than all published builds.

`scripts/release_feed.py` writes:

```text
public-release/
  source-staging.json
  assets/tlocation-icon.png
  v1.5.0/
    LocationSuite.ipa
    release-metadata.json
    SHA256SUMS
```

Promotion validates staging again before producing `source.json`. Historical
version entries keep immutable URLs such as
`<base>/v1.5.0/LocationSuite.ipa`; there is no mutable `latest` URL in a version
record.

The source follows the current **AltStore Classic AltSource** keys documented by
AltStore and supported by SideStore: `version`, `buildVersion`, ISO-8601 `date`,
`localizedDescription`, `downloadURL`, byte `size`, `minOSVersion`, and complete
`appPermissions`. The current schema does not document a SHA-256 version key, so
the hash is recorded in `release-metadata.json` and `SHA256SUMS` instead of an
invented source field.

- AltStore schema: <https://faq.altstore.io/developers/make-a-source>
- SideStore source compatibility: <https://docs.sidestore.io/docs/advanced/app-sources>
- SideStore URL scheme: <https://docs.sidestore.io/docs/advanced/url-schema>

## Public hosting boundary

No suitable public release host is currently configured. `n7314x/location-suite`
is private, GitHub Pages is disabled, and the related n9007314 Vercel application
uses a private Blob store. The removed legacy `ios/source.json` described a
different upstream repository and was not a valid Location Suite publication
path.

The tag workflow therefore refuses to run until all three settings exist:

- repository variable `LOCATION_SUITE_RELEASE_BASE_URL`, for example
  `https://releases.n9007314.xyz/location-suite`;
- repository variable `LOCATION_SUITE_RELEASE_PUBLIC_REPOSITORY`, naming a
  dedicated **public** repository containing only released artifacts/metadata;
- secret `LOCATION_SUITE_RELEASE_PUBLIC_REPOSITORY_TOKEN`, a fine-grained token
  with Contents write access only to that public artifact repository.

Configure the public repository's static host/custom domain so the repository
root maps exactly to the base URL. The host must serve `source.json`,
`source-staging.json`, `assets/tlocation-icon.png`, and every immutable `v*/`
directory over HTTPS without authentication. It must support an IPA response of
roughly the app's built size and ordinary GET requests from SideStore.

The release job verifies that the destination repository is public, refuses to
replace an existing version directory with different bytes, pushes only the
generated public tree, then downloads the public IPA and checks its byte count
and SHA-256 before creating the private repository's GitHub Release record. The
daily monitor repeats the production source -> latest entry -> metadata -> IPA
verification. A GitHub Actions artifact is used only between workflow jobs and
is never placed in the SideStore source.

Until those settings and DNS/static hosting exist, there is deliberately no
claimed stable or staging feed URL.

## In-app update and free-account signing behavior

A tagged build embeds `<base>/source.json` in its processed Info.plist. The
foreground `UpdateService` checks on activation at most once every six hours,
uses a five-second ephemeral request timeout, caps the source response at 512
KiB, and never blocks startup. A manual **Check for Updates** bypasses the cache
interval. It reports `upToDate`, `updateAvailable`, `checkFailed`, or `unknown`,
while retaining the last successfully parsed release and timestamp through a
later network or malformed-feed failure.

Settings retains its existing design and adds update rows. **Install Update**
opens the documented `sidestore://install?url=<encoded immutable IPA URL>`.
**Add Location Suite Source** opens
`sidestore://source?url=<encoded production source URL>`. The app never claims it
can silently install, sign, or refresh.

The existing `SigningExpiryMonitor` remains the only provisioning monitor. A
successful `misagent` read supplies the actual on-device profile expiration and
last-success timestamp; a failed read changes neither. Trustworthy readings are
presented as:

- more than 72 hours: normal;
- at or below 72 hours: subtle warning;
- at or below 48 hours: clear warning;
- at or below 24 hours: urgent warning and the existing foreground card;
- elapsed: explicit expired status.

The profile expiration includes date and time. PR #4's near-expiry action opened
SideStore because no direct refresh existed in Location Suite. Phase 1 now adds
an in-app profile-only attempt: it authenticates, requests a profile for the
installed team/App ID, installs it through misagent, and accepts success only
when a second device read reports a later expiry. This remains a physical-test
candidate; [the Phase 1 document](self-maintenance-signing.md) is authoritative
for its gates. SideStore remains only the older release-install handoff, not a
dependency of the new profile refresh.

If Apple GrandSlam returns 503 or anisette is unavailable, Location Suite leaves
the installed app, cached expiration, certificate, and profile untouched. The
already-issued profile remains usable until its displayed expiration. Retry
later; Phase 1 exposes no certificate create/revoke API.

With a free Apple Account, CI automates tests, unsigned archive/package,
metadata/hash/feed creation, publication after hosting is configured, daily feed
validation, update detection, expiry detection, and compilation of the direct
profile-refresh candidate. Background App Refresh is not assumed, so invisible
unattended renewal is not promised.

## Cold bootstrap state machine

Warm LocationSimulation is always checked first. A successful update on the
retained handle returns without a probe, new TCP connection, or cold diagnostic
mutation. The established Return/idle-warm/Disconnect meanings are unchanged.

True cold bootstrap records:

```text
LocalDevVPN route
  -> TCP connect
  -> RemotePairing
  -> RSD connect
  -> DVT LocationSimulation
  -> coordinate set
  -> Ready
```

For each stage it retains attempt number and elapsed time when upstream exposes
a boundary. `tunnel_create_rppairing` combines TCP connect and RemotePairing; on
success the TCP duration is marked `combined` rather than invented, while the
combined duration is attached to RemotePairing. On a socket error, the real
operation duration is attached to TCP connect.

Failures retain timestamp, target IP/port, underlying interface label, app
status code, FFI code/subcode, extracted errno, sanitized upstream detail,
per-stage measurements, retry count, and total duration. Categories are:

- `localVPNUnavailable`, `noRoute`, `connectionRefused`, `timeout`,
  `connectionReset`;
- `pairingRejected`, `remotePairingFailed`, `rsdFailed`, `dvtFailed`,
  `ddiUnavailable`, `coordinateSetFailed`;
- `invalidTarget`, `pairingFileUnreadable`, `unknown`.

An errno 61 message from `tunnel_create_rppairing` is therefore a TCP
`connectionRefused`, before RSD, DVT, DDI-dependent service opening, or the
coordinate. DDI is reported only when the LocationSimulation-channel error
actually mentions DDI/developer-image unavailability. A generic DVT failure is
not relabeled as DDI.

No disposable TCP pre-probe was added. The upstream listener is potentially
single-occupancy and exposes no contract that a connect-and-close probe is
harmless. The real RemotePairing attempt supplies the needed socket evidence
without a duplicate handshake.

The deterministic retry policy counts the first attempt as 0 ms:

- LocalDevVPN unavailable / no route / timeout: `0, 150, 300, 600, 1200 ms`;
- immediate refusal on cellular: `0, 150 ms`, then stop;
- refusal on other paths: `0, 150, 300 ms`;
- reset / RemotePairing / RSD transient failure: `0, 150, 300 ms`;
- pairing, DVT, DDI, coordinate, invalid target, or unknown: no automatic retry.

A network-path change clears the cellular-refusal automatic-retry gate. A
LocalDevVPN reconnect, meaningful foreground return, or explicit user Retry are
also modeled as valid new attempt boundaries. There is no indefinite timer and
no stored coordinate to replay automatically. Active/warm producers are never
torn down by readiness diagnostics; only a real operation on their retained
channel can still prove that channel stale, preserving the existing keeper
contract.

Settings exposes the final stage/result, timestamp, total and per-stage elapsed
time, sanitized socket detail, errno, and retry count alongside the existing
network, DDI, simulation, producer, and warm-keeper rows. Coordinates, pairing
file paths/content, keys, Apple credentials, and saved routes are excluded.

## LocalDevVPN observation boundary

LocalDevVPN is not vendored and Location Suite gained no Network Extension.
`docs/localdevvpn/PacketTunnelProvider-diagnostics.patch` applies to upstream
commit `af3fd697803ada4ac2b8d518358f5ab0a534844c`. It logs only IPv4/TCP headers
involving port 49152, direction, flags, path/interface, and tunnel lifecycle.
See the adjacent README for build, collection, and SYN/RST interpretation.

No physical packet trace was available during this implementation. Thus the
current errno 61 remains **unproven** as either a listener-generated local RST or
a LocalDevVPN reflection/lifecycle fault. The structured app trace proves the
failure is at TCP connect; the instrumented VPN fork experiment is what decides
which side generated it.

## Physical iPhone 15 Pro Max matrix

Use the same current pairing file, target `10.7.0.1:49152`, cached DDI, and
instrumented LocalDevVPN build. Capture Location Suite's Connection Diagnostics
and LocalDevVPN `[TunnelProv]` header lines for every run.

| Case | Procedure | Required observation |
| --- | --- | --- |
| A Wi-Fi cold | Disconnect Session; Wi-Fi on; LocalDevVPN on; start Point, repeat toward 20 runs | success rate and complete stage timings |
| B warm Point LTE | bootstrap on Wi-Fi; switch to LTE; start a new Point | retained session used; no cold attempt |
| C warm Route LTE | bootstrap on Wi-Fi; switch to LTE; start Route | retained session used; no ownership regression |
| D idle 30 min | on LTE tap Return; wait 30 minutes; start Point | real GPS during idle, warm reuse afterward |
| E idle 3 h | Return on LTE; leave process alive three hours; start Point | keeper heartbeat and reuse result |
| F overnight | same as E overnight | keeper result and any iOS suspension evidence |
| G disconnect LTE | tap Disconnect Session; LTE only; start/Retry once | exact final stage, errno, SYN/RST flags |
| H force-close LTE | leave LocalDevVPN active; force-close Location Suite; relaunch and attempt Point | true process-cold trace |
| I reboot LTE | reboot; restore LocalDevVPN; LTE only; attempt cold simulation | tunnel lifecycle plus cold trace |
| J reboot Wi-Fi | same reboot control with Wi-Fi associated | known-good SYN/SYN-ACK and Ready |
| K VPN off | LocalDevVPN off; Retry once | LocalDevVPN/route or socket failure, never generic DDI |
| L bad pairing | use deliberately invalid pairing file on known-good Wi-Fi | TCP acceptance followed by pairing-specific failure |
| M DDI unavailable | remove/redownload DDI only after transport control succeeds | failure only at DVT/DDI stage |
| N rapid transitions | repeatedly switch Wi-Fi/LTE while point, route, Return, and retry boundaries are exercised | no duplicate handshake race, crash, or ownership corruption |

Do not use private coordinates in screenshots or issue attachments. The final
classification is:

- SYN absent from PacketTunnelProvider: route/tunnel lifecycle bug; fix the
  LocalDevVPN route/startup path;
- SYN reflected and readiness changes from refusal to acceptance after a short
  measured interval: tune the existing bounded schedule to that evidence;
- SYN reflected and immediate RST consistently on LTE while Wi-Fi cold produces
  SYN-ACK: report `fresh RemotePairing listener unavailable on cellular` and do
  not add NAT, STUN, TURN, TLS, IPv6, or random socket options;
- SYN-ACK followed by failure: investigate only the recorded higher protocol
  stage.

The LocalDevVPN-owned high-level RemotePairing/RSD/DVT proxy remains only a
future experiment if persistent cellular RST is physically proven. No raw TCP
proxy or large Network Extension rewrite was started without that gate evidence.

## Free-signing device matrix

After a real public feed is configured and `v1.5.0` is tagged from merged main:

1. add the source through Settings and install;
2. publish a later version/build and update over the installed app;
3. verify app data, settings, pairing file, bookmarks, and saved routes remain;
4. observe normal, 72-hour, 48-hour, 24-hour, and elapsed expiry states using
   actual profile readings (do not alter the phone clock as proof);
5. during an Apple auth outage, confirm the displayed current expiry remains and
   no certificate revocation is attempted;
6. test SideStore absent, source unavailable, malformed source, new release
   detection, and immutable install-link destination;
7. inspect GitHub logs and publication output to confirm no Apple credential,
   certificate, profile, pairing file, device identifier, coordinate, or route
   was uploaded.
