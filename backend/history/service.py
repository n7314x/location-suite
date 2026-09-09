from __future__ import annotations

from collections.abc import Callable

from backend.simulation.manager import TeleportSucceeded
from backend.storage.database import LocationStore


class SimulationHistoryService:
    """Turns successful simulation events into persisted history entries."""

    def __init__(self, store: LocationStore) -> None:
        self._store = store

    def success_callback(
        self,
        name: str | None,
    ) -> Callable[[TeleportSucceeded], None]:
        normalized_name = name.strip() if name and name.strip() else None

        def record(event: TeleportSucceeded) -> None:
            self._store.add_history(
                event.latitude,
                event.longitude,
                normalized_name,
                created_at=event.completed_at,
            )

        return record
