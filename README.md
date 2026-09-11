# Location Suite

Non-jailbroken iOS system-wide location simulation.

## Components

- ios/      Native iOS companion app
- web/      Chromebook/browser interface
- backend/  Local device-control API using pymobiledevice3
- docs/     Architecture and setup documentation

## Requirements

- iOS 17.4+
- Developer Mode
- Pairing file
- LocalDevVPN for on-device operation
- SideStore-compatible sideloading

## Backend configuration

Transient usbmux enumeration retries can be tuned with
`LOCATION_SUITE_DEVICE_ENUMERATION_ATTEMPTS` and
`LOCATION_SUITE_DEVICE_ENUMERATION_RETRY_DELAY`. If tunneld exposes more than
one device, set `PYMOBILEDEVICE3_UDID` to select the simulation target.

Favorites and the latest 100 successful teleports are stored in
`data/location-suite.sqlite3`. The schema is created automatically, and local
database files under `data/` are gitignored. Set
`LOCATION_SUITE_DATABASE_PATH` to use a different file.

Place search is proxied by the backend through Photon, using OpenStreetMap
data. The public Photon demo is suitable for moderate development use but has
no availability guarantee. Set `LOCATION_SUITE_SEARCH_BASE_URL` to switch to a
self-hosted or compatible Photon instance without changing the frontend.

## iOS IPA

The `Build iOS IPA` GitHub Actions workflow archives the existing TLocation-derived
device target without code signing, packages `Payload/TLocation.app` as
`LocationSuite.ipa`, validates the package, and uploads it in the
`LocationSuite-IPA` workflow artifact. SideStore supplies the personal-development
signature and provisioning profile during installation; no Apple credentials or
signing files are stored in this repository.

See [Mobile milestone 1](docs/ios/mobile-milestone-1.md) for the architecture,
build details, permissions, installation steps, and real-device test checklist.

Manual waypoint walking routes, their shared v1 JSON contract, playback
lifecycle, and background-execution boundary are documented in
[Route engine milestone 1](docs/ios/route-engine-milestone-1.md).

The endpoint-first cellular-runtime investigation, current upstream evidence,
and physical-device diagnostic matrix are documented in
[Mobile polish and cellular runtime](docs/ios/mobile-polish-cellular-runtime.md).
That document also records the iOS 27 warm-session result: a Wi-Fi-bootstrapped
simulation can continue and switch between point and route producers on LTE,
while a true cold LTE bootstrap may still require Wi-Fi.

Unsigned tagged releases, SideStore update handoff, free-profile expiry
warnings, structured cold-LTE stages, bounded recovery, and the exact next
physical-device experiments are documented in
[Releases and cold LTE diagnostics](docs/ios/releases-and-cold-lte.md). Public
feed publication remains disabled until the documented artifact-only host
variables are configured; private GitHub Release URLs are never used as a
SideStore feed.
