from __future__ import annotations

import threading
import uuid
from concurrent.futures import Future, ThreadPoolExecutor

from backend.device.manager import DeviceError, device_manager
from backend.simulation.state import SimulationState


class SimulationBusy(RuntimeError):
    pass


class SimulationManager:
    def __init__(self) -> None:
        self._lock = threading.RLock()

        self._executor = ThreadPoolExecutor(
            max_workers=1,
            thread_name_prefix="location-simulation",
        )

        self._future: Future | None = None
        self._state = SimulationState.IDLE
        self._operation_id: str | None = None

        self._latitude: float | None = None
        self._longitude: float | None = None

        self._error: str | None = None

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

            return {
                "state": self._state.value,
                "operationId": self._operation_id,
                "location": location,
                "error": self._error,
            }

    def _busy(self) -> bool:
        return (
            self._future is not None
            and not self._future.done()
        )

    def teleport(
        self,
        latitude: float,
        longitude: float,
    ) -> str:
        with self._lock:
            if self._busy():
                raise SimulationBusy(
                    "A simulation operation is already running"
                )

            operation_id = uuid.uuid4().hex[:12]

            self._state = SimulationState.QUEUED
            self._operation_id = operation_id
            self._error = None

            self._future = self._executor.submit(
                self._teleport_worker,
                operation_id,
                latitude,
                longitude,
            )

            return operation_id

    def clear(self) -> str:
        with self._lock:
            if self._busy():
                raise SimulationBusy(
                    "A simulation operation is already running"
                )

            operation_id = uuid.uuid4().hex[:12]

            self._state = SimulationState.QUEUED
            self._operation_id = operation_id
            self._error = None

            self._future = self._executor.submit(
                self._clear_worker,
                operation_id,
            )

            return operation_id

    def _teleport_worker(
        self,
        operation_id: str,
        latitude: float,
        longitude: float,
    ) -> None:
        with self._lock:
            self._state = SimulationState.TELEPORTING

        try:
            device_manager.set_location(
                latitude,
                longitude,
            )
        except DeviceError as exc:
            self._fail(operation_id, str(exc))
            return
        except Exception as exc:
            self._fail(operation_id, repr(exc))
            return

        with self._lock:
            if self._operation_id != operation_id:
                return

            self._latitude = latitude
            self._longitude = longitude
            self._state = SimulationState.ACTIVE
            self._error = None

    def _clear_worker(
        self,
        operation_id: str,
    ) -> None:
        with self._lock:
            self._state = SimulationState.CLEARING

        try:
            device_manager.clear_location()
        except DeviceError as exc:
            self._fail(operation_id, str(exc))
            return
        except Exception as exc:
            self._fail(operation_id, repr(exc))
            return

        with self._lock:
            if self._operation_id != operation_id:
                return

            self._latitude = None
            self._longitude = None
            self._state = SimulationState.IDLE
            self._error = None

    def _fail(
        self,
        operation_id: str,
        message: str,
    ) -> None:
        with self._lock:
            if self._operation_id != operation_id:
                return

            self._state = SimulationState.ERROR
            self._error = message


simulation_manager = SimulationManager()
