import L from 'leaflet'
import {
  MapContainer,
  Marker,
  TileLayer,
  useMap,
  useMapEvents,
} from 'react-leaflet'
import { useEffect } from 'react'

import type { Coordinates } from '../../types/api'

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
  onSelect,
}: Props) {
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

      <ClickHandler onSelect={onSelect} />
      <FlyToSelection
        selected={selected}
        version={flyToVersion}
      />
    </MapContainer>
  )
}
