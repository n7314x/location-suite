import { useEffect, useRef, useState } from 'react'
import 'leaflet/dist/leaflet.css'

import {
  clearHistory,
  clearSimulation,
  createFavorite,
  deleteFavorite,
  getDevice,
  getFavorites,
  getHistory,
  getSimulation,
  getTunnel,
  renameFavorite,
  teleport,
} from './api/client'

import { StatusPills } from './features/device/StatusPills'
import { LocationMap } from './features/map/LocationMap'
import { RouteEditor } from './features/routes/RouteEditor'
import { iso8601Now, newRouteDraft } from './features/routes/routeDocument'
import { PointPanel } from './features/simulation/PointPanel'

import type {
  Coordinates,
  DeviceResponse,
  Favorite,
  HistoryItem,
  SearchResult,
  SimulationResponse,
  TunnelResponse,
} from './types/api'
import type {
  LocationRouteDocumentV1,
  RouteDraft,
} from './features/routes/routeDocument'

import './App.css'

const DEFAULT_LOCATION: Coordinates = {
  latitude: 40.6892,
  longitude: -74.0445,
}

function App() {
  const [appMode, setAppMode] = useState<'point' | 'route'>('point')
  const [selected, setSelected] =
    useState<Coordinates>(DEFAULT_LOCATION)
  const [selectedName, setSelectedName] =
    useState<string | null>('Statue of Liberty')
  const [flyToVersion, setFlyToVersion] = useState(0)
  const [routeFitVersion, setRouteFitVersion] = useState(0)
  const [routeDraft, setRouteDraft] = useState<RouteDraft>(() => newRouteDraft())

  const [favorites, setFavorites] = useState<Favorite[]>([])
  const [history, setHistory] = useState<HistoryItem[]>([])
  const refreshedHistoryOperation = useRef<string | null>(null)

  const [device, setDevice] =
    useState<DeviceResponse | null>(null)

  const [tunnel, setTunnel] =
    useState<TunnelResponse | null>(null)

  const [simulation, setSimulation] =
    useState<SimulationResponse | null>(null)

  const [error, setError] =
    useState<string | null>(null)

  async function refreshSimulation() {
    try {
      const value = await getSimulation()
      setSimulation(value)
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : String(err),
      )
    }
  }

  async function refreshConnection() {
    try {
      const [deviceValue, tunnelValue] =
        await Promise.all([
          getDevice(),
          getTunnel(),
        ])

      setDevice(deviceValue)
      setTunnel(tunnelValue)
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : String(err),
      )
    }
  }

  async function refreshFavorites() {
    try {
      const value = await getFavorites()
      setFavorites(value.favorites)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function refreshHistory() {
    try {
      const value = await getHistory()
      setHistory(value.history)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  useEffect(() => {
    const initialRefresh = window.setTimeout(() => {
      void refreshSimulation()
      void refreshConnection()
      void refreshFavorites()
      void refreshHistory()
    }, 0)

    const simulationTimer = window.setInterval(
      () => void refreshSimulation(),
      700,
    )

    const connectionTimer = window.setInterval(
      () => void refreshConnection(),
      15000,
    )

    return () => {
      window.clearTimeout(initialRefresh)
      window.clearInterval(simulationTimer)
      window.clearInterval(connectionTimer)
    }
  }, [])

  useEffect(() => {
    const operationId = simulation?.operationId
    if (
      simulation?.state === 'active' &&
      operationId &&
      refreshedHistoryOperation.current !== operationId
    ) {
      refreshedHistoryOperation.current = operationId
      void refreshHistory()
    }
  }, [simulation?.operationId, simulation?.state])

  async function handleTeleport() {
    setError(null)

    try {
      await teleport(selected, selectedName)
      await refreshSimulation()
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : String(err),
      )
    }
  }

  function selectPlace(result: SearchResult) {
    setSelected({
      latitude: result.latitude,
      longitude: result.longitude,
    })
    setSelectedName(result.displayName)
    setFlyToVersion((version) => version + 1)
  }

  function selectSavedPlace(
    coordinates: Coordinates,
    name: string | null,
  ) {
    setSelected({
      latitude: coordinates.latitude,
      longitude: coordinates.longitude,
    })
    setSelectedName(name)
    setFlyToVersion((version) => version + 1)
  }

  function changeCoordinates(coordinates: Coordinates) {
    setSelected(coordinates)
    setSelectedName(null)
  }

  function handleMapSelection(coordinates: Coordinates) {
    changeCoordinates(coordinates)
    if (appMode !== 'route') return
    if (routeDraft.anchors.length >= 500) {
      setError('A route can contain at most 500 anchors.')
      return
    }
    setRouteDraft((current) => {
      return {
        ...current,
        anchors: [...current.anchors, coordinates],
        modifiedAt: iso8601Now(),
        resolvedGeometry: undefined,
      }
    })
  }

  function handleRouteImport(document: LocationRouteDocumentV1) {
    const first = document.anchors[0]
    setSelected(first)
    setSelectedName(document.name)
    setRouteFitVersion((version) => version + 1)
  }

  async function handleSaveFavorite(name: string | null) {
    setError(null)
    try {
      await createFavorite(selected, name)
      await refreshFavorites()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function handleRenameFavorite(id: number, name: string) {
    setError(null)
    try {
      const { favorite } = await renameFavorite(id, name)
      setFavorites((current) =>
        current.map((item) => (item.id === id ? favorite : item)),
      )
      if (
        selected.latitude === favorite.latitude &&
        selected.longitude === favorite.longitude
      ) {
        setSelectedName(favorite.name)
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function handleDeleteFavorite(id: number) {
    setError(null)
    try {
      await deleteFavorite(id)
      setFavorites((current) => current.filter((item) => item.id !== id))
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function handleClearHistory() {
    if (!window.confirm('Clear all location history?')) {
      return
    }
    setError(null)
    try {
      await clearHistory()
      setHistory([])
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  async function handleClear() {
    setError(null)

    try {
      await clearSimulation()
      await refreshSimulation()
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : String(err),
      )
    }
  }

  const busy =
    simulation?.state === 'queued' ||
    simulation?.state === 'teleporting' ||
    simulation?.state === 'clearing'

  const ready =
    Boolean(device?.connected) &&
    Boolean(tunnel?.deviceTunnelReady)

  return (
    <main className="app">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark">
            L
          </div>

          <div>
            <h1>Location Suite</h1>
            <span>
              iOS location simulation
            </span>
          </div>
        </div>

        <StatusPills
          device={device}
          tunnel={tunnel}
          simulation={simulation}
        />
      </header>

      <div className="workspace">
        <aside className="sidebar">
          {(error || simulation?.error) && (
            <div className="error-message">
              {error ?? simulation?.error}
            </div>
          )}

          <div className="mode-switcher app-mode-switcher">
            <button
              type="button"
              className={`mode-button ${appMode === 'point' ? 'active' : ''}`}
              onClick={() => setAppMode('point')}
            >
              Point
            </button>
            <button
              type="button"
              className={`mode-button ${appMode === 'route' ? 'active' : ''}`}
              onClick={() => setAppMode('route')}
            >
              Route
            </button>
          </div>

          {appMode === 'point' ? (
            <PointPanel
              selected={selected}
              selectedName={selectedName}
              favorites={favorites}
              history={history}
              simulation={simulation}
              enabled={ready}
              busy={busy}
              onChange={changeCoordinates}
              onPlaceSelect={selectPlace}
              onSavedPlaceSelect={selectSavedPlace}
              onSaveFavorite={(name) => void handleSaveFavorite(name)}
              onRenameFavorite={(id, name) =>
                void handleRenameFavorite(id, name)
              }
              onDeleteFavorite={(id) => void handleDeleteFavorite(id)}
              onClearHistory={() => void handleClearHistory()}
              onTeleport={() => void handleTeleport()}
              onClear={() => void handleClear()}
            />
          ) : (
            <RouteEditor
              draft={routeDraft}
              onChange={setRouteDraft}
              onImport={handleRouteImport}
            />
          )}
        </aside>

        <section className="map-area">
          <LocationMap
            selected={selected}
            flyToVersion={flyToVersion}
            editingRoute={appMode === 'route'}
            routeAnchors={routeDraft.anchors}
            routeGeometry={routeDraft.resolvedGeometry?.points}
            routeFitVersion={routeFitVersion}
            onSelect={handleMapSelection}
          />

          <div className="map-coordinate-pill">
            {selected.latitude.toFixed(6)}
            {' , '}
            {selected.longitude.toFixed(6)}
          </div>

          {!ready && (
            <div className="connection-warning">
              <strong>
                iPhone connection unavailable
              </strong>

              <span>
                Connect the iPhone and make sure
                the developer tunnel is ready.
              </span>
            </div>
          )}
        </section>
      </div>
    </main>
  )
}

export default App
