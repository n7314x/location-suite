# LocalDevVPN RemotePairing diagnostics

Location Suite does not contain a Network Extension target. LocalDevVPN remains
the separate owner of the phone-local route.

The header-only diagnostic patch in this directory is based on upstream
[`jkcoxson/LocalDevVPN`](https://github.com/jkcoxson/LocalDevVPN) commit
`af3fd697803ada4ac2b8d518358f5ab0a534844c` (observed 2026-09-10). It changes
only `TunnelProv/PacketTunnelProvider.swift` and is intended for a temporary
diagnostic fork/build:

```bash
git clone https://github.com/jkcoxson/LocalDevVPN.git ../LocalDevVPN-diagnostics
cd ../LocalDevVPN-diagnostics
git checkout af3fd697803ada4ac2b8d518358f5ab0a534844c
git switch -c diagnostics/remotepairing-49152
git apply ../location-suite/docs/localdevvpn/PacketTunnelProvider-diagnostics.patch
```

Configure the fork's signing through its documented `CodeSigning.xcconfig`
flow, build it on the Xcode runner, and install it independently. Do not copy its
Network Extension entitlement into Location Suite.

## What the patch records

For IPv4 TCP packets where either port is `49152`, the patch emits only:

- ISO-8601 timestamp
- captured or reinjected direction
- virtual source and destination IPv4 addresses
- source and destination TCP ports
- TCP flags
- current `NWPath` status/interface names
- tunnel lifecycle transitions

It never reads or logs TCP payload bytes. It does not log pairing data, keys,
coordinates, device identifiers, or Location Suite data. The existing upstream
logger is compiled only for a Debug build; collect the messages from the device
Console using the `[TunnelProv]` filter.

## Decisive experiment

For every run, first tap **Disconnect Session** in Location Suite so no warm DVT
channel survives. Keep the same target (`10.7.0.1:49152`) and pairing file.

1. Start the instrumented LocalDevVPN and wait for `lifecycle=running`.
2. With Wi-Fi associated, trigger one Location Suite Retry and preserve all
   header lines through either Ready or final failure.
3. Disconnect Session, disable Wi-Fi, confirm cellular data is active, and
   trigger one Retry. Preserve the same span.
4. Repeat both controls after a reboot and after a LocalDevVPN reconnect.

Interpret the flags rather than inferring from interface type:

- no captured SYN: the included route/extension lifecycle is failing;
- captured SYN, reinjected SYN, immediate captured RST: the reflected phone-local
  stack is actively refusing the listener;
- captured/reinjected SYN and no response: black-hole/timeout;
- SYN followed by SYN-ACK: TCP succeeded, so use Location Suite's structured
  RemotePairing/RSD/DVT stages for the higher-layer failure.

A packet trace from a physical device is still required before labeling errno 61
as a LocalDevVPN fault or a listener-generated RST.
