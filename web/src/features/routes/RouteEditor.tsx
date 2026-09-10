import { useRef, useState } from 'react'
import type { ChangeEvent } from 'react'

import {
  documentFromDraft,
  downloadRouteDocument,
  draftFromDocument,
  estimatedTravelSeconds,
  iso8601Now,
  multiplierRange,
  parseRouteDocument,
  routeDistanceMeters,
} from './routeDocument'
import type {
  LocationRouteDocumentV1,
  RouteDraft,
  RouteMovementMode,
} from './routeDocument'

type Props = {
  draft: RouteDraft
  onChange: (draft: RouteDraft) => void
  onImport: (document: LocationRouteDocumentV1) => void
}

const movementModes: RouteMovementMode[] = ['walking', 'cycling', 'driving']

export function RouteEditor({ draft, onChange, onImport }: Props) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [error, setError] = useState<string | null>(null)
  const distance = routeDistanceMeters(draft)
  const eta = estimatedTravelSeconds(draft)
  const range = multiplierRange(draft.movementMode)

  function updateName(name: string) {
    onChange({ ...draft, name, modifiedAt: iso8601Now() })
  }

  function updateMode(movementMode: RouteMovementMode) {
    const nextRange = multiplierRange(movementMode)
    const defaultSpeedMultiplier = Math.min(
      Math.max(draft.defaultSpeedMultiplier, nextRange[0]),
      nextRange[1],
    )
    onChange({
      ...draft,
      movementMode,
      defaultSpeedMultiplier,
      modifiedAt: iso8601Now(),
      resolvedGeometry: undefined,
    })
  }

  function updateSpeed(defaultSpeedMultiplier: number) {
    onChange({ ...draft, defaultSpeedMultiplier, modifiedAt: iso8601Now() })
  }

  function removeAnchor(index: number) {
    onChange({
      ...draft,
      anchors: draft.anchors.filter((_, anchorIndex) => anchorIndex !== index),
      modifiedAt: iso8601Now(),
      resolvedGeometry: undefined,
    })
  }

  function reverseRoute() {
    onChange({
      ...draft,
      anchors: [...draft.anchors].reverse(),
      modifiedAt: iso8601Now(),
      resolvedGeometry: undefined,
    })
  }

  function clearRoute() {
    onChange({
      ...draft,
      anchors: [],
      modifiedAt: iso8601Now(),
      resolvedGeometry: undefined,
    })
  }

  function exportRoute() {
    setError(null)
    try {
      downloadRouteDocument(documentFromDraft(draft))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught))
    }
  }

  async function importRoute(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]
    event.target.value = ''
    if (!file) return
    setError(null)
    try {
      const document = parseRouteDocument(await file.text())
      onChange(draftFromDocument(document))
      onImport(document)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught))
    }
  }

  return (
    <div className="route-editor">
      <p className="route-help">
        Click the map to add anchors. The iPhone resolves road/path geometry with Apple Maps.
      </p>

      {error && <div className="error-message">{error}</div>}

      <section className="sidebar-section route-fields">
        <div className="section-heading">Route</div>
        <label>
          Name
          <input
            value={draft.name}
            maxLength={120}
            onChange={(event) => updateName(event.target.value)}
          />
        </label>

        <label>
          Movement mode
          <select
            value={draft.movementMode}
            onChange={(event) => updateMode(event.target.value as RouteMovementMode)}
          >
            {movementModes.map((mode) => (
              <option key={mode} value={mode}>
                {mode[0].toUpperCase() + mode.slice(1)}
              </option>
            ))}
          </select>
        </label>

        <label>
          Default speed ({draft.defaultSpeedMultiplier.toFixed(2)}x)
          <input
            type="range"
            min={range[0]}
            max={range[1]}
            step={0.25}
            value={draft.defaultSpeedMultiplier}
            onChange={(event) => updateSpeed(Number(event.target.value))}
          />
        </label>
      </section>

      <section className="sidebar-card route-summary">
        <span>{draft.anchors.length} anchors</span>
        <span>{formatDistance(distance)}</span>
        <span>{formatDuration(eta)}</span>
        {draft.resolvedGeometry && <strong>Cached geometry included</strong>}
      </section>

      <section className="sidebar-section">
        <div className="section-heading with-action">
          <span>Anchors</span>
          <button type="button" onClick={clearRoute} disabled={draft.anchors.length === 0}>
            Clear
          </button>
        </div>
        {draft.anchors.length === 0 ? (
          <div className="place-empty">No anchors yet. Click anywhere on the map.</div>
        ) : (
          <ol className="route-anchor-list">
            {draft.anchors.map((anchor, index) => (
              <li key={`${anchor.latitude}-${anchor.longitude}-${index}`}>
                <span>
                  {anchor.latitude.toFixed(6)}, {anchor.longitude.toFixed(6)}
                </span>
                <button type="button" onClick={() => removeAnchor(index)} aria-label={`Remove anchor ${index + 1}`}>
                  ×
                </button>
              </li>
            ))}
          </ol>
        )}
      </section>

      <section className="sidebar-section actions route-actions">
        <button
          type="button"
          className="secondary-button"
          onClick={reverseRoute}
          disabled={draft.anchors.length < 2}
        >
          Reverse
        </button>
        <button type="button" className="secondary-button" onClick={() => inputRef.current?.click()}>
          Import JSON
        </button>
        <button
          type="button"
          className="primary-button"
          onClick={exportRoute}
          disabled={draft.anchors.length < 2 || draft.name.trim().length === 0}
        >
          Export JSON
        </button>
        <input
          ref={inputRef}
          className="route-file-input"
          type="file"
          accept="application/json,.json"
          onChange={(event) => void importRoute(event)}
        />
      </section>
    </div>
  )
}

function formatDistance(meters: number): string {
  return meters < 1_000 ? `${Math.round(meters)} m` : `${(meters / 1_000).toFixed(2)} km`
}

function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return 'ETA —'
  const minutes = Math.max(Math.ceil(seconds / 60), 1)
  return minutes < 60 ? `ETA ${minutes} min` : `ETA ${Math.floor(minutes / 60)}h ${minutes % 60}m`
}
