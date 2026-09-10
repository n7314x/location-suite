import assert from 'node:assert/strict'
import test from 'node:test'

import {
  draftFromDocument,
  parseRouteDocument,
  routeDistanceMeters,
  stringifyRouteDocument,
} from '../src/features/routes/routeDocument.ts'
import type { LocationRouteDocumentV1 } from '../src/features/routes/routeDocument.ts'

function document(): LocationRouteDocumentV1 {
  return {
    version: 1,
    id: 'route_web_test',
    name: 'Web Test',
    createdAt: '2026-09-09T12:00:00Z',
    modifiedAt: '2026-09-09T12:00:00Z',
    movementMode: 'cycling',
    anchors: [
      { latitude: 40, longitude: -79 },
      { latitude: 40.001, longitude: -78.999 },
    ],
    resolvedGeometry: {
      points: [
        { latitude: 40, longitude: -79 },
        { latitude: 40.0005, longitude: -78.9997 },
        { latitude: 40.001, longitude: -78.999 },
      ],
      distance: 143,
      expectedTravelTime: 30,
      provider: 'mapKit',
      resolvedAt: '2026-09-09T12:00:00Z',
    },
    defaultSpeedMultiplier: 1.5,
    source: { client: 'ios' },
  }
}

test('v1 JSON round trip preserves cached mobile geometry and movement settings', () => {
  const value = document()
  const encoded = stringifyRouteDocument(value)
  assert.ok(encoded.endsWith('\n'))
  assert.deepEqual(parseRouteDocument(encoded), value)
  assert.equal(routeDistanceMeters(draftFromDocument(value)), 143)
})

test('future schema versions are rejected with a useful error', () => {
  const value = { ...document(), version: 2 }
  assert.throws(
    () => parseRouteDocument(JSON.stringify(value)),
    /version 2 is not supported/,
  )
})

test('malformed JSON and invalid coordinates are rejected', () => {
  assert.throws(() => parseRouteDocument('{'), /not valid JSON/)
  const value = document()
  value.anchors[0] = { latitude: 91, longitude: 0 }
  assert.throws(
    () => parseRouteDocument(JSON.stringify(value)),
    /latitude must be between -90 and 90/,
  )
})

test('movement-specific speed bounds are enforced', () => {
  const value = { ...document(), movementMode: 'driving' as const, defaultSpeedMultiplier: 3 }
  assert.throws(
    () => parseRouteDocument(JSON.stringify(value)),
    /between 0.25 and 2 for driving/,
  )
})
