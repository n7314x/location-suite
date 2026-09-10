# Shared contracts

`location-route-document-v1.schema.json` is the canonical, platform-neutral
saved-route and mobile/web interchange representation. `route-v1.schema.json`
is retained as the legacy playback-route contract for compatibility with the
first route milestone.

The document separates user-selected `anchors` from optional cached
`resolvedGeometry`. Walking, cycling, and driving documents can therefore move
between clients without MapKit types; mobile resolves missing geometry with
Apple Maps and can replay saved geometry offline. Consumers reject unknown
versions and invalid coordinates. Optional metadata may grow without changing
the v1 playback fields.

Example:

```json
{
  "version": 1,
  "id": "route_8f28a5a5b2574fe2a7fa83bedf871a1d",
  "name": "Morning Walk",
  "createdAt": "2026-09-09T13:00:00Z",
  "modifiedAt": "2026-09-09T13:00:00Z",
  "movementMode": "walking",
  "anchors": [
    { "latitude": 40.0001, "longitude": -79.0001 },
    { "latitude": 40.0005, "longitude": -79.0007 }
  ],
  "defaultSpeedMultiplier": 1.0,
  "source": {
    "client": "web"
  }
}
```

The schema's `minItems: 2` is the transport-level minimum. Runtime geometry also
removes consecutive points less than 5 cm apart and requires at least two points
after normalization. Pairing data, device identifiers, credentials, and real
or simulated session state never belong in this document.
