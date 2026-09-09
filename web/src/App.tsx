import { useEffect, useState } from 'react'
import 'leaflet/dist/leaflet.css'

import {
  clearSimulation,
  getDevice,
  getSimulation,
  getTunnel,
  teleport,
} from './api/client'

import { StatusPills } from './features/device/StatusPills'
import { LocationMap } from './features/map/LocationMap'
import { PointPanel } from './features/simulation/PointPanel'

import type {
  Coordinates,
  DeviceResponse,
  SimulationResponse,
  TunnelResponse,
} from './types/api'

import './App.css'

const DEFAULT_LOCATION: Coordinates = {
  latitude: 40.6892,
  longitude: -74.0445,
}

function App() {
  const [selected, setSelected] =
    useState<Coordinates>(DEFAULT_LOCATION)

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

  useEffect(() => {
    void refreshSimulation()
    void refreshConnection()

    const simulationTimer = window.setInterval(
      () => void refreshSimulation(),
      700,
    )

    const connectionTimer = window.setInterval(
      () => void refreshConnection(),
      15000,
    )

    return () => {
      window.clearInterval(simulationTimer)
      window.clearInterval(connectionTimer)
    }
  }, [])

  async function handleTeleport() {
    setError(null)

    try {
      await teleport(selected)
      await refreshSimulation()
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : String(err),
      )
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
          <PointPanel
            selected={selected}
            simulation={simulation}
            enabled={ready}
            busy={busy}
            onChange={setSelected}
            onTeleport={() => void handleTeleport()}
            onClear={() => void handleClear()}
          />

          {(error || simulation?.error) && (
            <div className="error-message">
              {error ?? simulation?.error}
            </div>
          )}
        </aside>

        <section className="map-area">
          <LocationMap
            selected={selected}
            onSelect={setSelected}
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
