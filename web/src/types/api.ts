export type Coordinates = {
  latitude: number
  longitude: number
}

export type SearchResult = Coordinates & {
  id: string
  displayName: string
  category?: string
  type?: string
  addressComponents?: Record<string, string>
}

export type Favorite = Coordinates & {
  id: number
  name: string
  createdAt: string
  updatedAt: string
}

export type HistoryItem = Coordinates & {
  id: number
  name: string | null
  createdAt: string
}

export type DeviceInfo = {
  name: string | null
  productType: string | null
  productVersion: string | null
  connectionType: string | null
}

export type DeviceResponse = {
  connected: boolean
  device: DeviceInfo | null
}

export type TunnelResponse = {
  daemonRunning: boolean
  deviceTunnelReady: boolean
  reason: string | null
}

export type SimulationState =
  | 'idle'
  | 'queued'
  | 'teleporting'
  | 'active'
  | 'clearing'
  | 'playing'
  | 'paused'
  | 'error'

export type SimulationResponse = {
  state: SimulationState
  operationId: string | null
  location: Coordinates | null
  error: string | null
  maintenanceActive: boolean
  consecutiveFailures: number
  lastSuccessfulUpdate: string | null
}
