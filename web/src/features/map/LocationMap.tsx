import L from 'leaflet'
import {
  CircleMarker,
  MapContainer,
  Marker,
  Polyline,
  TileLayer,
  Tooltip,
  useMap,
  useMapEvents,
} from 'react-leaflet'
import { useEffect } from 'react'

import type { Coordinates } from '../../types/api'
import type { RoutePoint } from '../routes/routeDocument'

const locationIcon = L.divIcon({
  className: 'location-pin-wrapper',
  html: `
    <div class="location-pin">
      <div class="location-pin-center"></div>
    </div>
  `,
  iconSize: [30, 30],
  iconAnchor: [15, 15],
})

type Props = {
  selected: Coordinates
  flyToVersion: number
  editingRoute: boolean
  routeAnchors: RoutePoint[]
  routeGeometry?: RoutePoint[]
  routeFitVersion: number
  onSelect: (coordinates: Coordinates) => void
}

function FlyToSelection({
  selected,
  version,
}: {
  selected: Coordinates
  version: number
}) {
  const map = useMap()

  useEffect(() => {
    if (version > 0) {
      map.flyTo(
        [selected.latitude, selected.longitude],
        Math.max(map.getZoom(), 13),
        { duration: 0.8 },
      )
    }
  }, [map, selected.latitude, selected.longitude, version])

  return null
}

function FitRoute({ points, version }: { points: RoutePoint[]; version: number }) {
  const map = useMap()

  useEffect(() => {
    if (version > 0 && points.length >= 2) {
      map.fitBounds(
        L.latLngBounds(
          points.map((point): L.LatLngTuple => [point.latitude, point.longitude]),
        ),
        { padding: [44, 44], maxZoom: 16 },
      )
    }
  }, [map, points, version])

  return null
}

function ClickHandler({
  onSelect,
}: {
  onSelect: Props['onSelect']
}) {
  useMapEvents({
    click(event) {
      onSelect({
        latitude: event.latlng.lat,
        longitude: event.latlng.lng,
      })
    },
  })

  return null
}

export function LocationMap({
  selected,
  flyToVersion,
  editingRoute,
  routeAnchors,
  routeGeometry,
  routeFitVersion,
  onSelect,
}: Props) {
  const routePoints = routeGeometry ?? routeAnchors

  return (
    <MapContainer
      center={[
        selected.latitude,
        selected.longitude,
      ]}
      zoom={13}
      className="location-map"
      zoomControl
    >
      <TileLayer
        attribution="&copy; OpenStreetMap contributors"
        url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
      />

      {!editingRoute && (
        <Marker
          icon={locationIcon}
          draggable
          position={[
            selected.latitude,
            selected.longitude,
          ]}
          eventHandlers={{
            dragend(event) {
              const marker = event.target as L.Marker
              const point = marker.getLatLng()

              onSelect({
                latitude: point.lat,
                longitude: point.lng,
              })
            },
          }}
        />
      )}

      {editingRoute && routePoints.length >= 2 && (
        <Polyline
          positions={routePoints.map(
            (point): L.LatLngTuple => [point.latitude, point.longitude],
          )}
          pathOptions={{
            color: '#2387ff',
            weight: 4,
            opacity: 0.9,
            dashArray: routeGeometry ? undefined : '7 7',
          }}
        />
      )}

      {editingRoute && routeAnchors.map((anchor, index) => (
        <CircleMarker
          key={`${anchor.latitude}-${anchor.longitude}-${index}`}
          center={[anchor.latitude, anchor.longitude]}
          radius={11}
          pathOptions={{ color: '#ffffff', weight: 2, fillColor: '#2387ff', fillOpacity: 1 }}
        >
          <Tooltip permanent direction="center" className="route-anchor-label">
            {index + 1}
          </Tooltip>
        </CircleMarker>
      ))}

      <ClickHandler onSelect={onSelect} />
      <FlyToSelection
        selected={selected}
        version={flyToVersion}
      />
      <FitRoute points={routePoints} version={routeFitVersion} />
    </MapContainer>
  )
}
