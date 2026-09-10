import type {
  Coordinates,
  Favorite,
  HistoryItem,
  SearchResult,
  SimulationResponse,
} from '../../types/api'
import { SavedPlaces } from '../places/SavedPlaces'
import { SearchBox } from '../places/SearchBox'

type Props = {
  selected: Coordinates
  selectedName: string | null
  favorites: Favorite[]
  history: HistoryItem[]
  simulation: SimulationResponse | null
  enabled: boolean
  busy: boolean
  onChange: (coordinates: Coordinates) => void
  onPlaceSelect: (result: SearchResult) => void
  onSavedPlaceSelect: (
    coordinates: Coordinates,
    name: string | null,
  ) => void
  onSaveFavorite: (name: string | null) => void
  onRenameFavorite: (id: number, name: string) => void
  onDeleteFavorite: (id: number) => void
  onClearHistory: () => void
  onTeleport: () => void
  onClear: () => void
}

export function PointPanel({
  selected,
  selectedName,
  favorites,
  history,
  simulation,
  enabled,
  busy,
  onChange,
  onPlaceSelect,
  onSavedPlaceSelect,
  onSaveFavorite,
  onRenameFavorite,
  onDeleteFavorite,
  onClearHistory,
  onTeleport,
  onClear,
}: Props) {
  return (
    <div className="point-panel">
      <SearchBox onSelect={onPlaceSelect} />

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

        {selectedName && (
          <div className="selected-name">{selectedName}</div>
        )}
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

      <SavedPlaces
        selectedName={selectedName}
        favorites={favorites}
        history={history}
        onSave={onSaveFavorite}
        onSelect={onSavedPlaceSelect}
        onRename={onRenameFavorite}
        onDelete={onDeleteFavorite}
        onClearHistory={onClearHistory}
      />
    </div>
  )
}
