import {
  useEffect,
  useId,
  useState,
} from 'react'

import { searchPlaces } from '../../api/client'
import type { SearchResult } from '../../types/api'

type Props = {
  onSelect: (result: SearchResult) => void
}

export function SearchBox({ onSelect }: Props) {
  const listId = useId()
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<SearchResult[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(-1)

  useEffect(() => {
    const normalizedQuery = query.trim()
    if (normalizedQuery.length < 2) {
      return
    }

    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      setLoading(true)
      setError(null)

      void searchPlaces(normalizedQuery, controller.signal)
        .then(({ results: nextResults }) => {
          setResults(nextResults)
          setOpen(true)
          setActiveIndex(nextResults.length > 0 ? 0 : -1)
        })
        .catch((reason: unknown) => {
          if (
            reason instanceof DOMException &&
            reason.name === 'AbortError'
          ) {
            return
          }
          setResults([])
          setOpen(true)
          setError(
            reason instanceof Error
              ? reason.message
              : String(reason),
          )
        })
        .finally(() => setLoading(false))
    }, 350)

    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [query])

  function choose(result: SearchResult) {
    onSelect(result)
    setOpen(false)
    setActiveIndex(-1)
  }

  function handleKeyDown(
    event: React.KeyboardEvent<HTMLInputElement>,
  ) {
    if (event.key === 'Escape') {
      setOpen(false)
      return
    }

    if (results.length === 0) {
      return
    }

    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setOpen(true)
      setActiveIndex((current) =>
        current < results.length - 1 ? current + 1 : 0,
      )
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setOpen(true)
      setActiveIndex((current) =>
        current > 0 ? current - 1 : results.length - 1,
      )
    } else if (event.key === 'Enter' && activeIndex >= 0) {
      event.preventDefault()
      choose(results[activeIndex])
    }
  }

  return (
    <section className="sidebar-section search-section">
      <div className="section-heading">Find a place</div>

      <div className="search-control">
        <input
          type="search"
          value={query}
          placeholder="Address, landmark, or city"
          aria-label="Search for a place"
          aria-autocomplete="list"
          aria-controls={listId}
          aria-expanded={open}
          aria-activedescendant={
            activeIndex >= 0
              ? `${listId}-${activeIndex}`
              : undefined
          }
          role="combobox"
          onChange={(event) => {
            setQuery(event.target.value)
            setResults([])
            setLoading(false)
            setError(null)
            setOpen(false)
            setActiveIndex(-1)
          }}
          onFocus={() => {
            if (results.length > 0 || error) {
              setOpen(true)
            }
          }}
          onBlur={() => setOpen(false)}
          onKeyDown={handleKeyDown}
        />

        {loading && (
          <span className="search-loading" aria-label="Searching">
            Searching…
          </span>
        )}

        {open && (
          <div className="search-results" id={listId} role="listbox">
            {error && <div className="search-empty">{error}</div>}

            {!error && !loading && results.length === 0 && (
              <div className="search-empty">No places found</div>
            )}

            {results.map((result, index) => (
              <button
                id={`${listId}-${index}`}
                key={result.id}
                type="button"
                role="option"
                aria-selected={activeIndex === index}
                className={
                  activeIndex === index
                    ? 'search-result active'
                    : 'search-result'
                }
                onMouseDown={(event) => event.preventDefault()}
                onMouseEnter={() => setActiveIndex(index)}
                onClick={() => choose(result)}
              >
                <span>{result.displayName}</span>
                {(result.type || result.category) && (
                  <small>{result.type ?? result.category}</small>
                )}
              </button>
            ))}

            <div className="search-attribution">
              Search by Photon · © OpenStreetMap contributors
            </div>
          </div>
        )}
      </div>
    </section>
  )
}
