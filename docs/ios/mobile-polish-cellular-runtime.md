# Mobile polish and cellular runtime

Research and implementation snapshot: 2026-09-09. The requested runtime is an
already-installed Location Suite build on iOS 27 using a pairing file, cached
personalized DDI, and LocalDevVPN. SideStore installation and refresh are out of
scope.

## Executive result

Route Stop and GPS clearing are now separate operations. Stop Route freezes
progress and keeps the exact last accepted fake coordinate alive. Return to Real
Location is the only route operation that calls the clear lifecycle. Route speed
is selectable from 0.5x through 3.0x, changes under an acceleration limit, and
includes deterministic, velocity-only human pace variation.

Location Suite no longer treats the underlying interface as a readiness policy.
It attempts the real `10.7.0.1:49152` RemotePairing connection on Wi-Fi,
cellular, other, and apparently-offline paths. `NWPathMonitor` supplies only a
diagnostic label and a network-change retry trigger. The actual RemotePairing
handshake is the authority.

That removes the app-level restriction, but it does not make true LTE/5G-active
runtime a proven platform capability. The current upstream evidence consistently
places the remaining restriction below Location Suite and LocalDevVPN: the iOS
RemotePairing endpoint is described as Wi-Fi-only, while the currently documented
no-Wi-Fi workaround deliberately enables Airplane Mode after starting
LocalDevVPN.[^pmd3-tunnels] [^stikjit-integration] Current TLocation reports the
same observation more directly: recent cellular-only tricks do not expose the
service.[^tlocation-readme] Because Apple does not publish a supported contract
for this private on-device service, the final iOS 27 verdict must be established
by the physical A/B test below rather than inferred from `NWPath` alone.

## Layer-by-layer findings

### A. Location Suite / upstream app policy

The inherited source did not contain a `guard` rejecting `.cellular`. Its actual
tunnel startup already called the RemotePairing stack directly. The apparent
Wi-Fi requirement was an app-level explanation in the readiness and error UI,
mirroring current TLocation's README and source guidance.[^tlocation-readme]

This milestone replaces that assumption with `PhoneLocalConnectionPolicy`:

- A pairing file permits an attempt regardless of interface type.
- A successful endpoint/RemotePairing connection determines readiness.
- An unreachable endpoint produces a categorized diagnostic rather than a
  fabricated “Wi-Fi required” result.
- A path change retries bootstrap when no simulation owns the connection.
- An active point or route simulation keeps its existing maintenance owner; it
  never clears GPS merely because the underlying path changed.

### B. LocalDevVPN

LocalDevVPN does not check Wi-Fi or cellular. Its packet-tunnel provider creates
a point-to-point IPv4 interface, installs only the configured peer route,
explicitly excludes the default route, and reflects IPv4 packets by swapping
their source and destination addresses.[^localdevvpn-provider] Its source also
notes that `tunnelRemoteAddress` is UI metadata, not routing. This makes the
transport local and independent of Internet carriage; no external VPN server is
involved.[^localdevvpn-readme]

Consequently, LocalDevVPN can route packets to `10.7.0.1`, but it cannot itself
make iOS start listening on TCP 49152. Adding a Network Extension entitlement to
Location Suite would duplicate the already working LocalDevVPN role without
solving an absent RemotePairing listener. No capability or entitlement was added.

### C. RemotePairing clients and discovery

The bundled `idevice` implementation labels `tunnel_create_rppairing` as raw
network RemotePairing and performs a direct `TcpStream::connect` to the supplied
socket before pair verification, tunnel setup, and RSD negotiation. It contains
no interface-type policy.[^idevice-provider]

Current Minimuxer follows the same useful separation: `NWPathMonitor` notices a
path change, while a real nonblocking TCP probe decides whether the candidate
service endpoint is reachable. Its current constant identifies 49152 as the
RemotePairing daemon port.[^minimuxer-observer] [^minimuxer-probe]

Current pymobiledevice3 documentation distinguishes the native USB
CoreDeviceProxy path from the RemotePairing route and explicitly calls the
latter Wi-Fi-only.[^pmd3-tunnels] Its implementation can connect to an address
that has already been discovered, but a client library cannot publish the
server-side service on iOS.

### D. iOS platform behavior

The lowest layer indicated by current source and upstream operating guidance is
iOS service exposure: when LTE/5G remains active with Wi-Fi off, TCP 49152 is not
expected to be published to the reflected peer. Current StikJIT guidance is an
important distinction: it says to enable cellular, connect LocalDevVPN, and then
turn on Airplane Mode.[^stikjit-integration] That is a phone-local offline mode,
not cellular data runtime.

This is an evidence-backed inference, not a public Apple API guarantee. Apple's
`NWPathMonitor` describes and monitors available network paths; it does not state
that a private RemotePairing listener exists on a given path.[^apple-nwpath]
There is no public Apple iOS 27 document promising cellular exposure of this
service. The app therefore reports both facts separately: underlying interface
and actual endpoint/handshake result.

## Route lifecycle and connection transitions

The playback states are `idle`, `ready`, `starting`, `playing`, `paused`,
`stopped`, `connectionInterrupted`, `completed`, `clearing`, and `error`.

- Pause and Stop set effective speed to zero without changing traveled distance,
  elapsed playback time, or coordinate.
- Stop invalidates the movement generation and queues an exact hold behind any
  older device command. It does not call `clear()`.
- Completed and stopped share one four-second maintenance path; there cannot be
  duplicate maintenance timers.
- A failed route update does not advance metrics. The route enters
  `connectionInterrupted`, retries only the held coordinate, and recovers to a
  paused/held state rather than silently resuming movement.
- Return to Real Location invalidates older generations before its serialized
  clear. A stale tick cannot run after that clear and recreate the simulation.
- Wi-Fi/cellular/VPN changes do not themselves clear the fake location.

## Speed and natural variation

At 1.0x the long-term target is 1.4 m/s. Presets are 0.5x, 1.0x, 1.5x, 2.0x,
and 3.0x and can be selected during playback. The engine approaches changing
targets at no more than 0.45 m/s² acceleration or 0.55 m/s² deceleration.

The pace profile combines two low-frequency sine components (4.5% total nominal
amplitude) with one smooth event per 22-second cycle. Each event lasts 6–9
seconds, alternates between a 12–20% slowdown and speedup, and uses a
zero-slope sine-squared envelope. The combined factor is hard-limited to
0.72–1.28 and speed is always finite and nonnegative. A per-controller random
seed varies production walks; tests inject a fixed seed. No random value is ever
added to latitude or longitude.

ETA uses remaining distance divided by the selected long-term target speed.
That makes an intentional multiplier change update ETA immediately while
preventing every natural pace event from making the display jump.

## iOS 27 physical diagnostic matrix

Run each row with the same pairing file, cached DDI, target `10.7.0.1:49152`, and
LocalDevVPN configuration. In Location Suite open Settings and capture the five
Connection Diagnostics rows after tapping Retry.

| Case | Wi-Fi | Cellular data | Airplane Mode | Expected diagnostic value |
| --- | --- | --- | --- | --- |
| Control | Associated | Either | Off | Endpoint Yes; RemotePairing Yes |
| Requested target | Off | LTE/5G active | Off | The decisive iOS 27 measurement |
| Documented offline workaround | Off | Disabled by Airplane Mode | On after VPN setup | Compare with current StikJIT guidance |
| VPN negative control | Off | LTE/5G active | Off, LocalDevVPN disconnected | Endpoint No |

Interpretation:

- Cellular + Endpoint Yes proves true LTE/5G-only runtime and Location Suite will
  accept it; test point and route modes immediately.
- Cellular + Endpoint No, followed by Wi-Fi + Endpoint Yes with no other changes,
  isolates the failure below app policy and credentials. If the VPN negative
  control is also No and the offline workaround is Yes, the remaining variable
  is iOS RemotePairing service exposure under an active cellular path.
- Endpoint Yes + RemotePairing No points instead to pairing authentication.
- RemotePairing Yes + DDI No points to the developer service/image layer, not
  networking.

## Limitations

CI can prove state semantics, deterministic speed behavior, the endpoint-first
policy, compilation, and IPA hygiene. It cannot toggle an iPhone's radios,
observe the private iOS listener, verify system-wide Core Location output, or
guarantee background scheduling. No claim of LTE/5G-active success should be
made until the requested-target row passes on the iPhone 15 Pro Max running
iOS 27.0.

## Sources

[^tlocation-readme]: TLocation, “Requirements,” current source at research time, commit `5e57f815`: [README](https://github.com/truongkma/t-location/blob/5e57f815e5958f133dfbaae8252473054adeccf0/README.md).

[^localdevvpn-provider]: LocalDevVPN, packet-tunnel routing and local packet reflection, commit `af3fd697`: [PacketTunnelProvider.swift](https://github.com/jkcoxson/LocalDevVPN/blob/af3fd697803ada4ac2b8d518358f5ab0a534844c/TunnelProv/PacketTunnelProvider.swift).

[^localdevvpn-readme]: LocalDevVPN, on-device isolated tunnel description, commit `af3fd697`: [README](https://github.com/jkcoxson/LocalDevVPN/blob/af3fd697803ada4ac2b8d518358f5ab0a534844c/README.md).

[^idevice-provider]: idevice FFI, raw RemotePairing direct TCP connection, commit `7a1cca39`: [tunnel_provider.rs](https://github.com/jkcoxson/idevice/blob/7a1cca397a79589e177de163d888ba761a137ce5/ffi/src/tunnel_provider.rs).

[^minimuxer-observer]: Minimuxer, path-change observation separated from endpoint refresh, commit `2e72b199`: [NetworkObserverService.swift](https://github.com/SideStore/Minimuxer/blob/2e72b199801de268e2169d24ccc90357cf9ab692/Sources/Services/NetworkObserverService.swift).

[^minimuxer-probe]: Minimuxer, nonblocking TCP reachability and RemotePairing port, commit `2e72b199`: [NetworkUtils.swift](https://github.com/SideStore/Minimuxer/blob/2e72b199801de268e2169d24ccc90357cf9ab692/Common/NetworkUtils.swift) and [MinimuxerConstants.swift](https://github.com/SideStore/Minimuxer/blob/2e72b199801de268e2169d24ccc90357cf9ab692/Common/MinimuxerConstants.swift).

[^pmd3-tunnels]: pymobiledevice3, iOS tunnel transport guide, commit `28220678`: [iOS 17+ tunnels](https://github.com/doronz88/pymobiledevice3/blob/2822067824a9add150805f62158ba0d7c4e22c26/docs/guides/ios17-tunnels.md).

[^stikjit-integration]: StikJIT integration requirements and Airplane Mode procedure, commit `3623e725`: [INTEGRATION.md](https://github.com/StikDebug/StikJIT/blob/3623e725876f76aecb0520582ad6194bacb15d39/INTEGRATION.md).

[^apple-nwpath]: Apple Developer Documentation: [`NWPathMonitor`](https://developer.apple.com/documentation/network/nwpathmonitor).
