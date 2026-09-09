from __future__ import annotations

import tempfile
import threading
import time
import unittest
from collections.abc import Callable
from pathlib import Path

from backend.device.location_session import LocationSessionError
from backend.history.service import SimulationHistoryService
from backend.simulation.manager import SimulationManager
from backend.storage.database import LocationStore


def wait_for(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.002)
    raise AssertionError("condition was not reached before timeout")


class FakeSession:
    def __init__(self, *, fail: bool = False) -> None:
        self._active = False
        self._lock = threading.Lock()
        self._callback: Callable[[str], None] = lambda _: None
        self._fail = fail

    @property
    def active(self) -> bool:
        with self._lock:
            return self._active

    def set_termination_callback(self, callback: Callable[[str], None]) -> None:
        self._callback = callback

    def start(self, latitude: float, longitude: float) -> None:
        if self._fail:
            raise LocationSessionError("simulated DVT failure")
        with self._lock:
            self._active = True

    def update(self, latitude: float, longitude: float) -> None:
        self.start(latitude, longitude)

    def clear(self) -> None:
        with self._lock:
            self._active = False

    def close(self) -> None:
        self.clear()

    def shutdown(self) -> None:
        self.clear()


class HistoryRecordingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.store = LocationStore(
            Path(self.temporary_directory.name) / "history.sqlite3"
        )
        self.history = SimulationHistoryService(self.store)

    def test_records_only_after_a_successful_teleport(self) -> None:
        manager = SimulationManager(session=FakeSession())
        self.addCleanup(manager.shutdown)

        manager.teleport(
            51.5007,
            -0.1246,
            on_success=self.history.success_callback("Big Ben"),
        )
        wait_for(lambda: manager.snapshot()["state"] == "active")

        entries = self.store.list_history()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["name"], "Big Ben")
        self.assertEqual(entries[0]["latitude"], 51.5007)
        self.assertEqual(entries[0]["longitude"], -0.1246)

        second_operation = manager.teleport(
            51.5014,
            -0.1419,
            on_success=self.history.success_callback("Buckingham Palace"),
        )
        wait_for(
            lambda: manager.snapshot()["state"] == "active"
            and manager.snapshot()["operationId"] == second_operation
        )

        entries = self.store.list_history()
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[0]["name"], "Buckingham Palace")

    def test_does_not_record_a_failed_teleport(self) -> None:
        manager = SimulationManager(session=FakeSession(fail=True))
        self.addCleanup(manager.shutdown)

        manager.teleport(
            51.5007,
            -0.1246,
            on_success=self.history.success_callback("Big Ben"),
        )
        wait_for(lambda: manager.snapshot()["state"] == "error")

        self.assertEqual(self.store.list_history(), [])


if __name__ == "__main__":
    unittest.main()
