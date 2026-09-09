import type {
  Coordinates,
  SimulationResponse,
} from '../../types/api'

type Props = {
  selected: Coordinates
  simulation: SimulationResponse | null
  enabled: boolean
  busy: boolean
  onChange: (coordinates: Coordinates) => void
  onTeleport: () => void
  onClear: () => void
}

export function PointPanel({
  selected,
  simulation,
  enabled,
  busy,
  onChange,
  onTeleport,
  onClear,
}: Props) {
  return (
    <div className="point-panel">
      <div className="mode-switcher">
        <button className="mode-button active">
          Point
        </button>

        <button
          className="mode-button"
          disabled
          title="Route mode is coming next"
        >
          Route
        </button>
      </div>

      <section className="sidebar-section">
        <div className="section-heading">
          Selected Location
        </div>

        <label>
          Latitude
          <input
            type="number"
            step="any"
            value={selected.latitude}
            onChange={(event) =>
              onChange({
                ...selected,
                latitude: Number(event.target.value),
              })
            }
          />
        </label>

        <label>
          Longitude
          <input
            type="number"
            step="any"
            value={selected.longitude}
            onChange={(event) =>
              onChange({
                ...selected,
                longitude: Number(event.target.value),
              })
            }
          />
        </label>
      </section>

      <section className="sidebar-section actions">
        <button
          className="primary-button"
          onClick={onTeleport}
          disabled={!enabled || busy}
        >
          {simulation?.state === 'teleporting'
            ? 'Setting Location...'
            : 'Set Location'}
        </button>

        <button
          className="secondary-button"
          onClick={onClear}
          disabled={
            busy ||
            simulation?.state !== 'active'
          }
        >
          Return to Real Location
        </button>
      </section>

      {simulation?.location && (
        <section className="sidebar-card">
          <span className="card-label">
            Active simulation
          </span>

          <strong>
            {simulation.location.latitude.toFixed(6)}
          </strong>

          <strong>
            {simulation.location.longitude.toFixed(6)}
          </strong>
        </section>
      )}
    </div>
  )
}
