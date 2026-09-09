# Mobile milestone 1: GitHub-built IPA

This milestone preserves the vendored TLocation/StikDebug phone-local design and
adds a reproducible, credential-free IPA build for SideStore. It does not depend
on the Chromebook backend after setup and does not require a jailbreak.

## Runtime architecture

1. `PairingFileStore` imports a user-selected `.mobiledevicepairing`,
   `.mobiledevicepair`, or property-list pairing record. The app keeps its working
   copy under Application Support and never bundles one in the IPA.
2. The separately installed LocalDevVPN app exposes the phone's RemotePairing
   endpoint at `10.7.0.1:49152` by default. Location Suite has no Network
   Extension target or VPN entitlement of its own.
3. `TunnelManager` and `JITEnableContext` use the bundled arm64
   `libidevice_ffi.a` to create the RPPairing tunnel from that endpoint and the
   imported pairing record.
4. `DeveloperDiskImageService` downloads Apple's personalized Developer Disk
   Image artifacts from the public `doronz88/DeveloperDiskImage` mirror into the
   app's Documents directory. `MountingProgress` mounts the image through the
   developer image-mounter service.
5. `simulate_location` opens the remote developer service and retains a
   `LocationSimulationHandle`. The map sends coordinate changes through the same
   open session and resends the selected coordinate every four seconds. Stop
   calls `location_simulation_clear`, waits briefly for the clear to settle, and
   tears the session down.
6. `BackgroundLocationManager` requests low-accuracy Core Location updates while
   a simulation is active. The `location` background mode, disabled automatic
   pausing, and **Always** authorization keep the process eligible for background
   execution so the resend loop can continue. The finite UIKit background task
   is supplemental; there is no silent-audio keep-alive in this source tree.

The app target has no extension or App Group. Its committed entitlements are the
upstream app-sandbox and user-selected-file entries. The pairing record,
Developer Disk Image, bookmarks, and logs are runtime data and are not packaged
by CI.

## Project and signing choices

- Project: `ios/TLocation.xcodeproj`
- Shared scheme and application target: `TLocation`
- Configuration: `Release`
- Device destination: generic iOS device (`iphoneos`, arm64)
- Minimum deployment target: iOS 17.4
- Product bundle identifier: `vn.truongkma.tlocation` (unchanged for this first
  proof build)
- Product/target name and payload directory: `TLocation.app` (unchanged)
- Springboard display name: `Location Suite`
- URL scheme: `tlocation` (unchanged)
- Upstream development team setting: left in the Xcode project for upstream
  compatibility, but overridden to empty in CI
- CI signing: `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, empty signing
  identity, and empty development team

The unsigned `.app` is copied into `Payload/TLocation.app` and zipped as
`LocationSuite.ipa`. SideStore accepts an IPA as input, creates a free-account
development certificate/profile as needed, and signs the app on the phone. The
workflow therefore needs no certificate, provisioning profile, Apple Account,
password, anisette data, SideStore credential, or repository secret.

SideStore may rewrite the installed application identifier as part of its normal
free-account signing. No special entitlement is required by this app: LocalDevVPN
owns the VPN capability, while location background mode and privacy descriptions
are Info.plist declarations.

## GitHub Actions build

The root workflow is `.github/workflows/build-ios-ipa.yml`. (The upstream
workflow retained under `ios/.github` is vendored metadata and is not discovered
by GitHub in this monorepo.) The root workflow:

1. Runs on GitHub's `xcode-27` arm64 macOS image and records the exact macOS,
   Xcode, and iOS SDK versions in the log.
2. Lints the source plist, entitlements, and Icon Composer JSON; verifies the
   bundled static library has an arm64 slice; and lists the Xcode targets and
   schemes.
3. Creates an unsigned Release `.xcarchive` for a generic iOS device.
4. Verifies the built app's identifier, display name, deployment target,
   executable architecture, absence of a signature, and absence of an embedded
   provisioning profile.
5. Creates and extracts `LocationSuite.ipa`, verifies exactly one app exists at
   `Payload/TLocation.app`, lints its packaged Info.plist, and records its size
   and SHA-256.
6. Uploads `LocationSuite.ipa` as the `LocationSuite-IPA` artifact for 90 days.
   A failed build uploads its Xcode log as a short-lived diagnostics artifact.

The Xcode 27 runner currently uses the iOS 27 SDK, so CI is a compile/link check
against the target phone's major OS release. It cannot prove on-device behavior,
and iOS permits newer device OS releases to install applications linked with an
older minimum deployment target.

## Download and install with SideStore

1. Open the successful **Build iOS IPA** run in GitHub Actions.
2. Download the `LocationSuite-IPA` artifact and unzip the GitHub artifact once.
   The file to install is `LocationSuite.ipa`; do not unzip the IPA itself.
3. Save `LocationSuite.ipa` in the iPhone Files app (or transfer it there).
4. Connect LocalDevVPN and confirm iOS shows the VPN as active.
5. Open SideStore, go to **My Apps**, tap **+**, select
   `LocationSuite.ipa`, and allow SideStore to sign/install it with the already
   configured free Apple Account.
6. If iOS asks, trust the developer app under **Settings > General > VPN & Device
   Management**. Keep Developer Mode enabled.
7. Launch **Location Suite**. Import the pairing file when the readiness card
   asks for it. Do not rename its contents; selecting either the pairing-specific
   extension or the original plist is supported.
8. Keep Wi-Fi joined to a network and LocalDevVPN connected. The network does not
   need internet after the one-time DDI files have downloaded, but iOS must expose
   the on-device pairing service.
9. Wait for all three readiness rows to complete: pairing file imported, device
   connected, and Developer Disk Image mounted.
10. When location permission is requested, grant it. Then open iOS
    **Settings > Privacy & Security > Location Services > Location Suite** and
    select **Always**. Leave **Background Location** enabled in the app's Settings.

## Physical-device acceptance test

1. Drop a pin and tap **Simulate Location**. Confirm another location-aware app
   reports the selected coordinate.
2. Lock the screen or background Location Suite for at least five minutes while
   LocalDevVPN remains connected. Confirm the simulated position remains active.
3. Change the selected coordinate and simulate again. Confirm the phone moves
   directly to the new coordinate without briefly returning to real GPS.
4. Disconnect the Chromebook entirely. It is not part of this runtime path;
   confirm simulation remains active.
5. Tap **Stop** or **Return to Real Location**. Confirm a location-aware app and
   the map return to the real GPS position.
6. Before the free signature expires, connect LocalDevVPN, open SideStore, and
   refresh Location Suite. A free Apple Account normally requires periodic
   refresh and has Apple's active-app limits.

If the readiness card cannot connect, first reconnect LocalDevVPN, verify Wi-Fi
is joined, wake/unlock the phone, and tap **Retry**. If pairing is rejected after
an iOS update or reset, generate a fresh pairing file outside the app and use
**Replace Pairing File**; pairing records are device-specific secrets and must
never be committed or shared.
