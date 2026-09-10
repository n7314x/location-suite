# Route engine milestone 1

This milestone adds manual waypoint walking routes to the verified phone-only
Location Suite runtime. It does not change pairing, LocalDevVPN, RemotePairing,
Developer Disk Image mounting, or the underlying location-simulation handle.

## Architecture

The platform-neutral JSON representation is
`contracts/route-v1.schema.json`. The corresponding Swift value types contain
only JSON-compatible route data: ID, optional name, version, ordered points,
movement mode, speed profile, and optional metadata.

The iOS route layer is split into four responsibilities:

1. `LocationRoute` and `RoutePoint` validate portable data.
2. `RouteGeometry` normalizes duplicate/near-duplicate points, calculates
   haversine segment distances, and performs great-circle interpolation.
3. `WalkingSpeedModel` and `RoutePlaybackEngine` advance testable route metrics
   without importing SwiftUI, MapKit, UIKit, or the device FFI.
4. `RoutePlaybackController` owns the explicit playback state machine and one
   timer. `DeviceRouteLocationSimulationSink` is the narrow adapter from route
   coordinates to the existing serial `LocationSimulationCommandQueue` and
   `simulate_location` function.

On the healthy path, `simulate_location` sees the existing
`LocationSimulationHandle` and calls `location_simulation_set` on it. It does
not reconnect or create a new DVT/location session for each route coordinate.
The legacy point resend path remains unchanged and route mode cannot be entered
while a point simulation is active.

## Playback behavior

Route updates are scheduled at 3 Hz. Only one device update may be in flight;
timer ticks are skipped while the serial device command is outstanding, so a
slow connection cannot create an unbounded update backlog. Elapsed advancement
per accepted tick is capped at one second, preventing an app suspension or slow
reconnect from turning into a large location jump.

Natural walking targets 1.4 m/s at 1.0x. The compact route control offers
0.5x, 1.0x, 1.5x, 2.0x, and 3.0x presets, including while the route is moving.
Acceleration and deceleration limits make a new setting take effect smoothly.
A seeded, deterministic-in-tests pace profile combines low-frequency drift with
several-second slowdown and speedup envelopes. Randomness affects velocity only,
never coordinates. The engine also slows over the last six metres; a small
nonzero crawl plus a five-centimetre completion threshold guarantees exact
completion rather than an asymptotic stall.

Pause freezes distance, elapsed playback time, segment, and route coordinate.
Stop Route also freezes those values, enters the explicit `stopped`/Holding
state, and deliberately retains the fake coordinate and simulation handle.
While paused, stopped, connection-interrupted, or completed, the controller
resends only the held coordinate every four seconds through the same open
session. Completion leaves the fake location at the destination. Only the
separate Return to Real Location action calls the proven
`location_simulation_clear` lifecycle and returns the phone to real GPS.

The controller is main-actor isolated. A generation number invalidates stale
async results, only one timer exists, and device sets and clears are serialized
on `LocationSimulationCommandQueue`. Stop's final exact hold is ordered after
any older update; Return to Real Location's clear is ordered after every older
set. Thus an old route cannot update the device after the clear or mutate a
newer playback run.

## Background execution boundary

Route playback reuses the working `BackgroundLocationManager`: background Core
Location is requested while a route owns the simulation, automatic pausing
remains disabled, and the existing `location` background mode and Always
authorization flow are unchanged. The UIKit background task is supplemental;
there is no silent audio or unrelated background capability.

iOS, not the app, ultimately decides whether and for how long a process remains
runnable in the background. When Always authorization and Background Location
are enabled, the 3 Hz timer continues whenever iOS keeps the process executing,
matching the already device-verified point-resend design. If iOS suspends the
process, route time does not advance off-clock and playback resumes smoothly
without teleporting when execution returns. Continuous locked-screen movement
must therefore be verified on the physical target OS/device; CI cannot prove
background scheduling or GPS effects.

## Scope intentionally deferred

No road directions, snapping, traffic, driving/cycling/running modes, freehand
drawing, loops, reverse playback, saving, or web route UI are included. The
versioned model and speed abstraction leave room for those additions without
putting iOS runtime objects into the shared contract.
