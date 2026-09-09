import { useState } from 'react'

import type {
  Coordinates,
  Favorite,
  HistoryItem,
} from '../../types/api'

type Props = {
  selectedName: string | null
  favorites: Favorite[]
  history: HistoryItem[]
  onSave: (name: string | null) => void
  onSelect: (coordinates: Coordinates, name: string | null) => void
  onRename: (id: number, name: string) => void
  onDelete: (id: number) => void
  onClearHistory: () => void
}

function coordinateLabel(item: Coordinates) {
  return `${item.latitude.toFixed(4)}, ${item.longitude.toFixed(4)}`
}

function historyTime(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'short',
    timeStyle: 'short',
  }).format(new Date(value))
}

export function SavedPlaces({
  selectedName,
  favorites,
  history,
  onSave,
  onSelect,
  onRename,
  onDelete,
  onClearHistory,
}: Props) {
  const [favoriteName, setFavoriteName] = useState('')
  const [editingId, setEditingId] = useState<number | null>(null)
  const [editingName, setEditingName] = useState('')

  function saveFavorite() {
    onSave(favoriteName.trim() || selectedName)
    setFavoriteName('')
  }

  return (
    <>
      <section className="sidebar-section">
        <div className="section-heading">Favorites</div>

        <div className="favorite-save-row">
          <input
            value={favoriteName}
            maxLength={120}
            placeholder={selectedName ?? 'Optional custom name'}
            aria-label="Favorite name"
            onChange={(event) => setFavoriteName(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                saveFavorite()
              }
            }}
          />
          <button type="button" onClick={saveFavorite}>
            Save
          </button>
        </div>

        <div className="place-list">
          {favorites.length === 0 && (
            <div className="place-empty">No favorites saved</div>
          )}

          {favorites.map((favorite) => (
            <div className="place-row" key={favorite.id}>
              {editingId === favorite.id ? (
                <div className="favorite-editor">
                  <input
                    autoFocus
                    value={editingName}
                    maxLength={120}
                    aria-label={`Rename ${favorite.name}`}
                    onChange={(event) => setEditingName(event.target.value)}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter' && editingName.trim()) {
                        onRename(favorite.id, editingName.trim())
                        setEditingId(null)
                      } else if (event.key === 'Escape') {
                        setEditingId(null)
                      }
                    }}
                  />
                  <button
                    type="button"
                    disabled={!editingName.trim()}
                    onClick={() => {
                      onRename(favorite.id, editingName.trim())
                      setEditingId(null)
                    }}
                  >
                    Done
                  </button>
                </div>
              ) : (
                <>
                  <button
                    type="button"
                    className="place-main"
                    onClick={() =>
                      onSelect(favorite, favorite.name)
                    }
                  >
                    <strong>{favorite.name}</strong>
                    <span>{coordinateLabel(favorite)}</span>
                  </button>
                  <div className="place-actions">
                    <button
                      type="button"
                      title="Rename favorite"
                      onClick={() => {
                        setEditingId(favorite.id)
                        setEditingName(favorite.name)
                      }}
                    >
                      Rename
                    </button>
                    <button
                      type="button"
                      title="Delete favorite"
                      onClick={() => onDelete(favorite.id)}
                    >
                      Delete
                    </button>
                  </div>
                </>
              )}
            </div>
          ))}
        </div>
      </section>

      <section className="sidebar-section">
        <div className="section-heading with-action">
          <span>History</span>
          {history.length > 0 && (
            <button type="button" onClick={onClearHistory}>
              Clear
            </button>
          )}
        </div>

        <div className="place-list history-list">
          {history.length === 0 && (
            <div className="place-empty">No successful teleports yet</div>
          )}

          {history.map((item) => (
            <button
              type="button"
              className="history-row"
              key={item.id}
              onClick={() => onSelect(item, item.name)}
            >
              <strong>{item.name ?? coordinateLabel(item)}</strong>
              <span>
                {coordinateLabel(item)} · {historyTime(item.createdAt)}
              </span>
            </button>
          ))}
        </div>
      </section>
    </>
  )
}
