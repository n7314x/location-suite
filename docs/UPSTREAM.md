# Upstream

The iOS implementation began as a derivative of TLocation:

https://github.com/truongkma/t-location

TLocation is itself derived from StikDebug:

https://github.com/StikDebug/StikDebug

The inherited code is licensed under AGPL-3.0.

## Self-maintenance research pins (2026-09-11)

Phase 1 was implemented against exact upstream snapshots instead of a moving
branch:

- SideStore `develop` at
  [`6032424a0e56c1c319762e786099bdd9186a238b`](https://github.com/SideStore/SideStore/commit/6032424a0e56c1c319762e786099bdd9186a238b).
  `FetchProvisioningProfilesOperation` requests a team provisioning profile and
  `RefreshAppOperation` installs the returned profile with misagent without
  reinstalling the app. The historical change that removed installation from
  ordinary refresh is `332f5632` (`[Refresh]: Remove install stuffs from
  refresh since in refresh should only renew provisioning profiles`).
- SideInstaller `main` at
  [`9272b9079a8d45570d34a9ca16a9760bc5eeab21`](https://github.com/FrizzleM/SideInstaller/commit/9272b9079a8d45570d34a9ca16a9760bc5eeab21).
  Its `rust-core/src/account.rs` demonstrates v3 anisette, Apple sign-in,
  developer sessions, device registration before provisioning, and
  `MaxCertsBehavior::Error`. Its `ios-app/DeviceConnection.swift` demonstrates
  both RemotePairing and classic-pairing/CoreDeviceProxy routes, AFC
  `PublicStaging`, and installation_proxy.
- isideload `0.3.17` at
  [`b6d111376657a59207ac26c8ef8be5cca8793cba`](https://github.com/nab138/isideload/commit/b6d111376657a59207ac26c8ef8be5cca8793cba).
  This is the exact revision in `SelfMaintenanceCore/Cargo.toml` and
  `Cargo.lock`; it is not a floating Git dependency. Location Suite wraps its
  RemoteV3 provider to apply isideload PR #11's one-field GrandSlam client-info
  fix without taking that branch's unrelated changes.
- iLoader `main` at
  [`348eefd7de78e9bc612c9d619b8b1e7a80ba3ba0`](https://github.com/nab138/iloader/commit/348eefd7de78e9bc612c9d619b8b1e7a80ba3ba0).
  Its lockfile resolves the `apple-codesign-quick` isideload branch to
  `f6a4d5dba717d72fc2af63eaba26b27ba44116be`, which predates and differs from
  Location Suite's isideload `main` pin.

SideInstaller and SideStore are research references, not runtime dependencies.
Location Suite's Phase 1 runtime dependency remains LocalDevVPN plus Apple and
the selected anisette service.

At the SideInstaller pin, `[patch]` redirects isideload to a vendored 0.2.22
snapshot based on `e319d931`, with one unrelated app-extension signing patch.
Its authentication implementation obtains client metadata from the anisette
server. Location Suite's 0.3.17 pin instead supplies fixed Xcode/AuthKit client
metadata. Current iLoader's `f6a4d5db` snapshot supplies fixed `akd` metadata,
lowercases the account, disables idle HTTP pooling, and installs AWS-LC rather
than ring as its explicit rustls provider. Apple has since been confirmed to
reject the Xcode identifier before credential validation. Location Suite's
wrapper now supplies `com.apple.akd/1.0` while preserving the pinned provider's
other behavior.

## libidevice FFI ownership

The bundled `location_simulation_new` ABI was checked against upstream
`ffi/src/dvt/location_simulation.rs`. It borrows the `RemoteServerHandle`
(`&mut (*server).0`) and does not consume its `Box`.
`location_simulation_clear` sends `stopLocationSimulation`, reads the reply, and
leaves the handle reusable. Location Suite retains both handles while the warm
session is idle and frees them exactly once, child before parent, only on a real
service failure or explicit **Disconnect Session**.

The profile-only Rust core is a second static library. isideload's `install`
feature is enabled because its current crate imports `idevice` unconditionally;
Location Suite never calls isideload's install path. Cargo therefore builds
isideload's crates.io `idevice` 0.1.65 beside the existing pinned idevice FFI.
Their Rust symbols are versioned/mangled and the unused path is dead-stripped;
the existing C ABI remains the sole owner of RSD, misagent, and location
simulation. This separation must be rechecked when either pin changes.
