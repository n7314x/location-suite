import type {
  Coordinates,
  DeviceResponse,
  SimulationResponse,
  TunnelResponse,
} from '../types/api'

const API =
  import.meta.env.VITE_API_BASE ??
  'http://127.0.0.1:8787/api'

async function request<T>(
  path: string,
  options?: RequestInit,
): Promise<T> {
  const response = await fetch(`${API}${path}`, options)

  let data: unknown

  try {
    data = await response.json()
  } catch {
    throw new Error(
      `API returned an invalid response (${response.status})`,
    )
  }

  if (!response.ok) {
    const body = data as {
      detail?: unknown
    }

    let message = `Request failed (${response.status})`

    if (typeof body.detail === 'string') {
      message = body.detail
    } else if (body.detail !== undefined) {
      message = JSON.stringify(body.detail)
    }

    throw new Error(message)
  }

  return data as T
}

export function getDevice() {
  return request<DeviceResponse>('/device')
}

export function getTunnel() {
  return request<TunnelResponse>('/tunnel')
}

export function getSimulation() {
  return request<SimulationResponse>('/simulation')
}

export function teleport(location: Coordinates) {
  return request<{
    accepted: boolean
    operationId: string
  }>('/simulation/teleport', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(location),
  })
}

export function clearSimulation() {
  return request<{
    accepted: boolean
    operationId: string
  }>('/simulation/clear', {
    method: 'POST',
  })
}
