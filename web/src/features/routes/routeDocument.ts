export type RouteMovementMode = 'walking' | 'cycling' | 'driving'

export type RoutePoint = {
  latitude: number
  longitude: number
}

export type ResolvedRouteGeometry = {
  points: RoutePoint[]
  distance: number
  expectedTravelTime?: number
  provider: string
  resolvedAt: string
}

export type RouteSourceMetadata = {
  client?: string
  originalIdentifier?: string
  [key: string]: unknown
}

export type LocationRouteDocumentV1 = {
  version: 1
  id: string
  name: string
  createdAt: string
  modifiedAt: string
  movementMode: RouteMovementMode
  anchors: RoutePoint[]
  resolvedGeometry?: ResolvedRouteGeometry
  defaultSpeedMultiplier: number
  source?: RouteSourceMetadata
}

export type RouteDraft = Omit<LocationRouteDocumentV1, 'version'>

const identifierPattern = /^route_[A-Za-z0-9_-]+$/
const modes: RouteMovementMode[] = ['walking', 'cycling', 'driving']

export class RouteDocumentValidationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'RouteDocumentValidationError'
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

function validateDate(value: unknown, field: string): asserts value is string {
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new RouteDocumentValidationError(`${field} must be an ISO-8601 date.`)
  }
}

function validatePoint(value: unknown, field: string): asserts value is RoutePoint {
  if (!isRecord(value)) {
    throw new RouteDocumentValidationError(`${field} must be a coordinate object.`)
  }
  const { latitude, longitude } = value
  if (!isFiniteNumber(latitude) || latitude < -90 || latitude > 90) {
    throw new RouteDocumentValidationError(`${field}.latitude must be between -90 and 90.`)
  }
  if (!isFiniteNumber(longitude) || longitude < -180 || longitude > 180) {
    throw new RouteDocumentValidationError(`${field}.longitude must be between -180 and 180.`)
  }
}

function validatePoints(
  value: unknown,
  field: string,
  maximum: number,
): asserts value is RoutePoint[] {
  if (!Array.isArray(value) || value.length < 2 || value.length > maximum) {
    throw new RouteDocumentValidationError(`${field} must contain 2–${maximum} coordinates.`)
  }
  value.forEach((point, index) => validatePoint(point, `${field}[${index}]`))
}

export function validateRouteDocument(value: unknown): asserts value is LocationRouteDocumentV1 {
  if (!isRecord(value)) {
    throw new RouteDocumentValidationError('The route document must be a JSON object.')
  }
  if (value.version !== 1) {
    throw new RouteDocumentValidationError(
      typeof value.version === 'number'
        ? `Route document version ${value.version} is not supported.`
        : 'Route document version is missing.',
    )
  }
  if (
    typeof value.id !== 'string' ||
    value.id.length > 100 ||
    !identifierPattern.test(value.id)
  ) {
    throw new RouteDocumentValidationError('id must be a valid route_ identifier.')
  }
  if (
    typeof value.name !== 'string' ||
    value.name.trim().length === 0 ||
    value.name.length > 120
  ) {
    throw new RouteDocumentValidationError('name must contain 1–120 characters.')
  }
  validateDate(value.createdAt, 'createdAt')
  validateDate(value.modifiedAt, 'modifiedAt')
  if (!modes.includes(value.movementMode as RouteMovementMode)) {
    throw new RouteDocumentValidationError('movementMode must be walking, cycling, or driving.')
  }
  validatePoints(value.anchors, 'anchors', 500)

  const range = multiplierRange(value.movementMode as RouteMovementMode)
  if (
    !isFiniteNumber(value.defaultSpeedMultiplier) ||
    value.defaultSpeedMultiplier < range[0] ||
    value.defaultSpeedMultiplier > range[1]
  ) {
    throw new RouteDocumentValidationError(
      `defaultSpeedMultiplier must be between ${range[0]} and ${range[1]} for ${value.movementMode}.`,
    )
  }

  if (value.resolvedGeometry !== undefined) {
    const geometry = value.resolvedGeometry
    if (!isRecord(geometry)) {
      throw new RouteDocumentValidationError('resolvedGeometry must be an object.')
    }
    validatePoints(geometry.points, 'resolvedGeometry.points', 20_000)
    if (!isFiniteNumber(geometry.distance) || geometry.distance <= 0) {
      throw new RouteDocumentValidationError('resolvedGeometry.distance must be positive.')
    }
    if (
      geometry.expectedTravelTime !== undefined &&
      (!isFiniteNumber(geometry.expectedTravelTime) || geometry.expectedTravelTime < 0)
    ) {
      throw new RouteDocumentValidationError('resolvedGeometry.expectedTravelTime must not be negative.')
    }
    if (typeof geometry.provider !== 'string' || geometry.provider.trim().length === 0) {
      throw new RouteDocumentValidationError('resolvedGeometry.provider is required.')
    }
    validateDate(geometry.resolvedAt, 'resolvedGeometry.resolvedAt')
  }

  if (value.source !== undefined && !isRecord(value.source)) {
    throw new RouteDocumentValidationError('source must be an object when provided.')
  }
}

export function parseRouteDocument(json: string): LocationRouteDocumentV1 {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    throw new RouteDocumentValidationError('The selected file is not valid JSON.')
  }
  validateRouteDocument(value)
  return value
}

export function stringifyRouteDocument(document: LocationRouteDocumentV1): string {
  validateRouteDocument(document)
  return `${JSON.stringify(document, null, 2)}\n`
}

export function newRouteDraft(): RouteDraft {
  const now = iso8601Now()
  return {
    id: makeRouteIdentifier(),
    name: 'Untitled Route',
    createdAt: now,
    modifiedAt: now,
    movementMode: 'walking',
    anchors: [],
    defaultSpeedMultiplier: 1,
    source: { client: 'web' },
  }
}

export function documentFromDraft(draft: RouteDraft): LocationRouteDocumentV1 {
  const document: LocationRouteDocumentV1 = {
    ...draft,
    version: 1,
    name: draft.name.trim(),
    modifiedAt: iso8601Now(),
  }
  validateRouteDocument(document)
  return document
}

export function draftFromDocument(document: LocationRouteDocumentV1): RouteDraft {
  return {
    id: document.id,
    name: document.name,
    createdAt: document.createdAt,
    modifiedAt: document.modifiedAt,
    movementMode: document.movementMode,
    anchors: document.anchors,
    resolvedGeometry: document.resolvedGeometry,
    defaultSpeedMultiplier: document.defaultSpeedMultiplier,
    source: document.source,
  }
}

export function routeDistanceMeters(draft: RouteDraft): number {
  if (draft.resolvedGeometry) return draft.resolvedGeometry.distance
  return polylineDistance(draft.anchors)
}

export function estimatedTravelSeconds(draft: RouteDraft): number {
  if (draft.resolvedGeometry?.expectedTravelTime) {
    return draft.resolvedGeometry.expectedTravelTime / draft.defaultSpeedMultiplier
  }
  const baseline = draft.movementMode === 'walking'
    ? 1.4
    : draft.movementMode === 'cycling'
      ? 5.5
      : 13.9
  return routeDistanceMeters(draft) / (baseline * draft.defaultSpeedMultiplier)
}

export function multiplierRange(mode: RouteMovementMode): readonly [number, number] {
  return mode === 'driving' ? [0.25, 2] : [0.5, 3]
}

export function iso8601Now(): string {
  return new Date(Math.floor(Date.now() / 1000) * 1000)
    .toISOString()
    .replace('.000Z', 'Z')
}

export function makeRouteIdentifier(): string {
  return `route_${crypto.randomUUID().replaceAll('-', '')}`
}

export function downloadRouteDocument(document: LocationRouteDocumentV1): void {
  const blob = new Blob([stringifyRouteDocument(document)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const link = window.document.createElement('a')
  const filename = document.name.replaceAll(/[/\\:]/g, '-').trim() || 'location-route'
  link.href = url
  link.download = `${filename}.json`
  link.click()
  URL.revokeObjectURL(url)
}

function polylineDistance(points: RoutePoint[]): number {
  let total = 0
  for (let index = 1; index < points.length; index += 1) {
    total += pointDistance(points[index - 1], points[index])
  }
  return total
}

function pointDistance(start: RoutePoint, end: RoutePoint): number {
  const radians = (degrees: number) => degrees * Math.PI / 180
  const latitudeDelta = radians(end.latitude - start.latitude)
  const longitudeDelta = radians(end.longitude - start.longitude)
  const latitude1 = radians(start.latitude)
  const latitude2 = radians(end.latitude)
  const a = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(latitude1) * Math.cos(latitude2) * Math.sin(longitudeDelta / 2) ** 2
  return 6_371_008.8 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}
