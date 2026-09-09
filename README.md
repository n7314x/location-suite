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
