import type {
  DeviceResponse,
  SimulationResponse,
  TunnelResponse,
} from '../../types/api'

type Props = {
  device: DeviceResponse | null
  tunnel: TunnelResponse | null
  simulation: SimulationResponse | null
}

function Status({
  good,
  label,
}: {
  good: boolean
  label: string
}) {
  return (
    <span className={`status-pill ${good ? 'good' : 'bad'}`}>
      <span className="status-dot" />
      {label}
    </span>
  )
}

export function StatusPills({
  device,
  tunnel,
  simulation,
}: Props) {
  const simulationGood =
    simulation?.state === 'active' ||
    simulation?.state === 'idle'

  return (
    <div className="status-list">
      <Status
        good={Boolean(device?.connected)}
        label={
          device?.connected
            ? device.device?.name ?? 'iPhone'
            : 'No iPhone'
        }
      />

      <Status
        good={Boolean(tunnel?.deviceTunnelReady)}
        label={
          tunnel?.deviceTunnelReady
            ? 'Tunnel Ready'
            : 'Tunnel Offline'
        }
      />

      <Status
        good={simulationGood}
        label={
          simulation?.state
            ? `Simulation: ${simulation.state}`
            : 'Simulation: unknown'
        }
      />
    </div>
  )
}
