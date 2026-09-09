from __future__ import annotations

import threading
import time
import unittest
from collections.abc import Callable

from backend.device.location_session import LocationSessionError
from backend.simulation.manager import SimulationBusy, SimulationManager


def wait_for(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.002)
    raise AssertionError("condition was not reached before timeout")


class FakePersistentSession:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._active = False
        self._on_terminated: Callable[[str], None] = lambda _: None
        self.starts: list[tuple[float, float]] = []
        self.updates: list[tuple[float, float]] = []
        self.clear_count = 0
        self.close_count = 0
        self.shutdown_count = 0

    @property
    def active(self) -> bool:
        with self._lock:
            return self._active

    def set_termination_callback(
        self,
        callback: Callable[[str], None],
    ) -> None:
        self._on_terminated = callback

    def start(self, latitude: float, longitude: float) -> None:
        with self._lock:
            self.starts.append((latitude, longitude))
            self._active = True

    def update(self, latitude: float, longitude: float) -> None:
        with self._lock:
            if not self._active:
                raise LocationSessionError("session is closed")
            self.updates.append((latitude, longitude))

    def clear(self) -> None:
        with self._lock:
            self.clear_count += 1
            self._active = False

    def close(self) -> None:
        with self._lock:
            self.close_count += 1
            self._active = False

    def shutdown(self) -> None:
        with self._lock:
            self.shutdown_count += 1
            if self._active:
                self.clear_count += 1
            self._active = False

    def terminate_unexpectedly(self) -> None:
        with self._lock:
            self._active = False
        self._on_terminated("test session disconnected")


class SimulationManagerTests(unittest.TestCase):
    def test_long_lived_session_stays_active_during_status_polling(self) -> None:
        session = FakePersistentSession()
        manager = SimulationManager(session=session)
        self.addCleanup(manager.shutdown)

        operation_id = manager.teleport(40.6892, -74.0445)
        wait_for(lambda: manager.snapshot()["state"] == "active")

        for _ in range(100):
            snapshot = manager.snapshot()
            self.assertEqual(snapshot["state"], "active")
            self.assertTrue(snapshot["maintenanceActive"])

        time.sleep(0.05)
        self.assertEqual(session.starts, [(40.6892, -74.0445)])
        self.assertEqual(session.updates, [])
        self.assertEqual(snapshot["operationId"], operation_id)
        self.assertEqual(
            snapshot["location"],
            {"latitude": 40.6892, "longitude": -74.0445},
        )
        self.assertIsNotNone(snapshot["lastSuccessfulUpdate"])

    def test_replacement_uses_same_persistent_session(self) -> None:
        session = FakePersistentSession()
        manager = SimulationManager(session=session)
        self.addCleanup(manager.shutdown)

        first_operation = manager.teleport(1.0, 2.0)
        wait_for(lambda: manager.snapshot()["state"] == "active")

        second_operation = manager.teleport(3.0, 4.0)
        wait_for(
            lambda: manager.snapshot()["state"] == "active"
            and manager.snapshot()["operationId"] == second_operation
        )

        self.assertNotEqual(first_operation, second_operation)
        self.assertEqual(session.starts, [(1.0, 2.0)])
        self.assertEqual(session.updates, [(3.0, 4.0)])
        self.assertEqual(session.clear_count, 0)
        self.assertEqual(
            manager.snapshot()["location"],
            {"latitude": 3.0, "longitude": 4.0},
        )

    def test_clear_closes_active_session_and_returns_to_idle(self) -> None:
        class BlockingClearSession(FakePersistentSession):
            def __init__(self) -> None:
                super().__init__()
                self.clear_started = threading.Event()
                self.release_clear = threading.Event()

            def clear(self) -> None:
                self.clear_started.set()
                if not self.release_clear.wait(2):
                    raise AssertionError("test did not release clear")
                super().clear()

        session = BlockingClearSession()
        manager = SimulationManager(session=session)
        self.addCleanup(manager.shutdown)

        manager.teleport(10.0, 20.0)
        wait_for(lambda: manager.snapshot()["state"] == "active")
        manager.clear()
        self.assertTrue(session.clear_started.wait(1))

        clearing = manager.snapshot()
        self.assertEqual(clearing["state"], "clearing")
        self.assertTrue(clearing["maintenanceActive"])

        session.release_clear.set()
        wait_for(lambda: manager.snapshot()["state"] == "idle")
        cleared = manager.snapshot()
        self.assertFalse(cleared["maintenanceActive"])
        self.assertIsNone(cleared["location"])
        self.assertIsNone(cleared["lastSuccessfulUpdate"])
        self.assertEqual(session.clear_count, 1)

    def test_unexpected_session_termination_enters_error(self) -> None:
        session = FakePersistentSession()
        manager = SimulationManager(session=session)
        self.addCleanup(manager.shutdown)

        manager.teleport(10.0, 20.0)
        wait_for(lambda: manager.snapshot()["state"] == "active")
        session.terminate_unexpectedly()

        snapshot = manager.snapshot()
        self.assertEqual(snapshot["state"], "error")
        self.assertEqual(snapshot["error"], "test session disconnected")
        self.assertFalse(snapshot["maintenanceActive"])
        self.assertEqual(snapshot["consecutiveFailures"], 1)

    def test_start_failure_is_reported_without_becoming_active(self) -> None:
        class FailingSession(FakePersistentSession):
            def start(self, latitude: float, longitude: float) -> None:
                raise LocationSessionError("unable to open DVT")

        session = FailingSession()
        manager = SimulationManager(session=session)
        self.addCleanup(manager.shutdown)

        manager.teleport(1.0, 2.0)
        wait_for(lambda: manager.snapshot()["state"] == "error")
        snapshot = manager.snapshot()
        self.assertEqual(snapshot["error"], "unable to open DVT")
        self.assertFalse(snapshot["maintenanceActive"])
        self.assertIsNone(snapshot["location"])

    def test_shutdown_clears_and_releases_session(self) -> None:
        session = FakePersistentSession()
        manager = SimulationManager(session=session)

        manager.teleport(1.0, 2.0)
        wait_for(lambda: manager.snapshot()["state"] == "active")
        manager.shutdown()

        snapshot = manager.snapshot()
        self.assertEqual(snapshot["state"], "idle")
        self.assertFalse(snapshot["maintenanceActive"])
        self.assertEqual(session.shutdown_count, 1)
        self.assertEqual(session.clear_count, 1)

    def test_transitional_operation_rejects_another_operation(self) -> None:
        class BlockingStartSession(FakePersistentSession):
            def __init__(self) -> None:
                super().__init__()
                self.started = threading.Event()
                self.release = threading.Event()

            def start(self, latitude: float, longitude: float) -> None:
                self.started.set()
                if not self.release.wait(2):
                    raise AssertionError("test did not release start")
                super().start(latitude, longitude)

        session = BlockingStartSession()
        manager = SimulationManager(session=session)
        self.addCleanup(manager.shutdown)

        manager.teleport(1.0, 2.0)
        self.assertTrue(session.started.wait(1))
        self.assertEqual(manager.snapshot()["state"], "teleporting")
        with self.assertRaises(SimulationBusy):
            manager.clear()
        session.release.set()
        wait_for(lambda: manager.snapshot()["state"] == "active")


if __name__ == "__main__":
    unittest.main()
