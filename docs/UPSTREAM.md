# Upstream

The iOS implementation began as a derivative of TLocation:

https://github.com/truongkma/t-location

TLocation is itself derived from StikDebug:

https://github.com/StikDebug/StikDebug

The inherited code is licensed under AGPL-3.0.

## libidevice FFI ownership

The bundled `location_simulation_new` ABI was checked against upstream
`ffi/src/dvt/location_simulation.rs`. It borrows the `RemoteServerHandle`
(`&mut (*server).0`) and does not consume its `Box`.
`location_simulation_clear` sends `stopLocationSimulation`, reads the reply, and
leaves the handle reusable. Location Suite retains both handles while the warm
session is idle and frees them exactly once, child before parent, only on a real
service failure or explicit **Disconnect Session**.
