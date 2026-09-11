# TLocation

A minimal iOS app that does one thing: **simulate your device's GPS location** — a single map screen where you drop a pin and your iPhone reports that position system-wide. No computer required after initial setup.

> **Origin & attribution:** TLocation is a **derivative work of [StikDebug](https://github.com/StikDebug/StikDebug)** by Stephen Bove (Stik) and the StikDebug contributors — not an original project. The entire device-communication core (pairing-file handling, loopback tunnel, Developer Disk Image mounting, the `idevice` FFI, background keep-alive, and the location-simulation engine itself) originates from StikDebug; this fork removes StikDebug's other features, adds two locate buttons, and rebrands the app. Licensed **AGPL-3.0**, same as upstream — see [LICENSE](LICENSE) (preserved unchanged from StikDebug).

## Features

- Drop a pin anywhere (tap, search, or coordinates) and simulate that location
- **Locate Me** button: centers the map on your real GPS position
- **Return to Real Location** button: clears the simulated location and restores your device's real GPS position (only enabled while a simulation is active)
- Bookmarks for frequent locations
- Keeps simulating in the background (low-accuracy background-location keep-alive plus periodic session resends)
- URL scheme: `tlocation://simulate-location?lat=37.3349&lon=-122.0090`, `tlocation://clear-location`

## Requirements

- iOS 17.4+ (on-device setup; no Mac/PC needed after you have a pairing file)
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) (free) — loopback VPN so the app can talk to the device it runs on
- A **pairing file** for your device — see the [pairing file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)
- LocalDevVPN connected. A Wi-Fi cold bootstrap is the known-good control. A
  retained warm session is proven to work on LTE; true cold LTE remains under
  packet-level investigation and is never reported as working without a trace.

## Install via SideStore

1. Download a verified `LocationSuite.ipa` from the configured public release
   feed once hosting is enabled (built unsigned by CI).
2. Open SideStore → **+** → pick the `.ipa`. SideStore signs it with your Apple ID and installs it.
3. Launch TLocation, import your pairing file, connect LocalDevVPN, wait for the status banner to turn green.

AltStore works the same way.

### SideStore source

The source URL is intentionally not hard-coded until the artifact-only public
host is configured. See
[`docs/ios/releases-and-cold-lte.md`](../docs/ios/releases-and-cold-lte.md) for
the required variables, immutable layout, and SideStore handoff. The private
source repository and temporary Actions artifact URLs are not valid feed hosts.

## Build from source

```bash
xcodebuild -project TLocation.xcodeproj -scheme TLocation -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Pushing a matching `v*` semantic-version tag runs the stable release workflow
only after the public feed boundary is configured. SideStore remains responsible
for local Apple Account signing and seven-day profile renewal.

## What was removed from StikDebug

JIT enabling, JavaScript scripting, console/syslog viewer, process inspector, device info, app-expiry viewer, App Intents. Only location simulation (and the infrastructure it needs) remains.

## Credits & License

- **[StikDebug](https://github.com/StikDebug/StikDebug)** — the upstream project TLocation is derived from, © Stephen Bove (Stik) and the StikDebug contributors. If TLocation is useful to you, star and support the original project. Setup guides live in [StikDebug-Guide](https://github.com/StikDebug/StikDebug-Guide).
- [idevice](https://github.com/jkcoxson/idevice) by jkcoxson — Rust library for Apple device services (bundled here as `libidevice_ffi.a`, unchanged)
- [LocalDevVPN / StosVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) — loopback VPN that makes on-device pairing possible
- App icon: original artwork for this fork (blue gradient from StikDebug's icon palette, pin glyph new)

**License: AGPL-3.0** — inherited from StikDebug and applying to this entire derivative; the complete corresponding source is this repository. See [LICENSE](LICENSE).
