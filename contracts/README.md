# Shared contracts

`route-v1.schema.json` is the canonical, platform-neutral representation of a
Location Suite route. Producers must emit camel-case JSON keys and consumers
must reject unsupported versions, non-finite/out-of-range coordinates, and
routes with fewer than two geographically distinct usable points.

Version 1 intentionally supports only manually selected, straight-line walking
routes with the `natural` speed profile. Directions, road snapping, freehand
geometry, persistence, loops, reverse playback, and custom speeds are future
contract versions or backward-compatible additions; they are not implied by
the v1 values.

Example:

```json
{
  "version": 1,
  "id": "route_8f28a5a5b2574fe2a7fa83bedf871a1d",
  "name": "Morning Walk",
  "mode": "walking",
  "points": [
    { "latitude": 40.0001, "longitude": -79.0001 },
    { "latitude": 40.0005, "longitude": -79.0007 }
  ],
  "speedProfile": "natural",
  "metadata": {
    "createdAt": "2026-09-09T13:00:00Z",
    "source": "waypoint"
  }
}
```

The schema's `minItems: 2` is the transport-level minimum. Runtime geometry also
removes consecutive points less than 5 cm apart and requires at least two points
after that normalization, preventing duplicate-only routes from playing.
