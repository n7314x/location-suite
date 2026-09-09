from __future__ import annotations

import threading
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from typing import Protocol

from backend.device.location_session import (
    DirectDvtLocationSession,
    LocationSessionError,
)
from backend.simulation.state import SimulationState


class SimulationBusy(RuntimeError):
    pass


class SimulationClosed(RuntimeError):
    pass


class PersistentLocationSession(Protocol):
    @property
    def active(self) -> bool: ...

    def set_termination_callback(
        self,
        callback: Callable[[str], None],
    ) -> None: ...

    def start(self, latitude: float, longitude: float) -> None: ...

    def update(self, latitude: float, longitude: float) -> None: ...

    def clear(self) -> None: ...

    def close(self) -> None: ...

    def shutdown(self) -> None: ...


class SimulationManager:
    """Owns simulation state and one reusable location-session command lane."""

    _TRANSITIONAL_STATES = {
        SimulationState.QUEUED,
        SimulationState.TELEPORTING,
        SimulationState.CLEARING,
    }

    def __init__(
        self,
        *,
        session: PersistentLocationSession | None = None,
    ) -> None:
        self._lock = threading.RLock()
        self._session = session or DirectDvtLocationSession(
            self._session_terminated
        )
        if session is not None:
            session.set_termination_callback(self._session_terminated)

        # start/update/clear are short operations on one long-lived DVT
        # session. Keeping them in one worker preserves ordering while leaving
        # the session itself open between commands.
        self._executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="location-simulation",
        )
        self._closed = False

        self._state = SimulationState.IDLE
        self._operation_id: str | None = None

        self._latitude: float | None = None
        self._longitude: float | None = None

        self._error: str | None = None
        self._consecutive_failures = 0
        self._last_successful_update: datetime | None = None

    def snapshot(self) -> dict:
        with self._lock:
            location = None
            if (
                self._latitude is not None
                and self._longitude is not None
            ):
                location = {
                    "latitude": self._latitude,
                    "longitude": self._longitude,
                }

            last_successful_update = None
            if self._last_successful_update is not None:
                last_successful_update = (
                    self._last_successful_update.isoformat()
                )

            return {
                "state": self._state.value,
                "operationId": self._operation_id,
                "location": location,
                "error": self._error,
                # Kept for API compatibility. It now means that the persistent
                # DVT location session is open and maintaining the simulation.
                "maintenanceActive": self._session.active,
                "consecutiveFailures": self._consecutive_failures,
                "lastSuccessfulUpdate": last_successful_update,
            }

    def teleport(self, latitude: float, longitude: float) -> str:
        with self._lock:
            self._ensure_open()
            self._ensure_not_transitioning()

            operation_id = uuid.uuid4().hex[:12]
            update_existing = self._session.active

            self._state = SimulationState.QUEUED
            self._operation_id = operation_id
            self._error = None
            self._consecutive_failures = 0

            self._executor.submit(
                self._teleport_worker,
                operation_id,
                latitude,
                longitude,
                update_existing,
            )
            return operation_id

    def clear(self) -> str:
        with self._lock:
            self._ensure_open()
            self._ensure_not_transitioning()

            operation_id = uuid.uuid4().hex[:12]
            self._state = SimulationState.QUEUED
            self._operation_id = operation_id
            self._error = None

            self._executor.submit(self._clear_worker, operation_id)
            return operation_id

    def shutdown(self, *, wait: bool = True) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True

        self._executor.submit(self._shutdown_worker)
        self._executor.shutdown(wait=wait, cancel_futures=False)

    def _ensure_open(self) -> None:
        if self._closed:
            raise SimulationClosed("The simulation manager is closed")

    def _ensure_not_transitioning(self) -> None:
        if self._state in self._TRANSITIONAL_STATES:
            raise SimulationBusy(
                "A simulation operation is already running"
            )

    def _teleport_worker(
        self,
        operation_id: str,
        latitude: float,
        longitude: float,
        update_existing: bool,
    ) -> None:
        with self._lock:
            if self._operation_id != operation_id:
                return
            self._state = SimulationState.TELEPORTING

        try:
            if update_existing:
                self._session.update(latitude, longitude)
            else:
                self._session.start(latitude, longitude)
        except LocationSessionError as exc:
            self._close_failed_session()
            self._fail(operation_id, str(exc))
            return
        except Exception as exc:
            self._close_failed_session()
            self._fail(operation_id, repr(exc))
            return

        with self._lock:
            if self._operation_id != operation_id:
                return

            if not self._session.active:
                if self._state != SimulationState.ERROR:
                    self._state = SimulationState.ERROR
                    self._error = (
                        "Persistent DVT location session terminated "
                        "unexpectedly"
                    )
                    self._consecutive_failures = 1
                return

            self._latitude = latitude
            self._longitude = longitude
            self._state = SimulationState.ACTIVE
            self._error = None
            self._consecutive_failures = 0
            self._last_successful_update = datetime.now(UTC)

    def _clear_worker(self, operation_id: str) -> None:
        with self._lock:
            if self._operation_id != operation_id:
                return
            self._state = SimulationState.CLEARING

        try:
            self._session.clear()
        except LocationSessionError as exc:
            self._close_failed_session()
            self._fail(operation_id, str(exc))
            return
        except Exception as exc:
            self._close_failed_session()
            self._fail(operation_id, repr(exc))
            return

        with self._lock:
            if self._operation_id != operation_id:
                return
            self._mark_idle()

    def _close_failed_session(self) -> None:
        try:
            self._session.close()
        except Exception:
            # Preserve the original start/update/clear error in API telemetry.
            pass

    def _session_terminated(self, message: str) -> None:
        with self._lock:
            if self._closed or self._state in {
                SimulationState.IDLE,
                SimulationState.CLEARING,
            }:
                return

            self._state = SimulationState.ERROR
            self._error = message
            self._consecutive_failures = 1

    def _fail(self, operation_id: str, message: str) -> None:
        with self._lock:
            if self._operation_id != operation_id:
                return
            self._state = SimulationState.ERROR
            self._error = message
            self._consecutive_failures = 1

    def _shutdown_worker(self) -> None:
        try:
            self._session.shutdown()
        finally:
            with self._lock:
                self._mark_idle()

    def _mark_idle(self) -> None:
        self._latitude = None
        self._longitude = None
        self._state = SimulationState.IDLE
        self._error = None
        self._consecutive_failures = 0
        self._last_successful_update = None


simulation_manager = SimulationManager()
