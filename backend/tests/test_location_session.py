from __future__ import annotations

import asyncio
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from backend.device.location_session import DirectDvtLocationSession
from backend.device.pymobiledevice import run_pmd3


class FakeRsd:
    udid = "test-udid"

    def __init__(self) -> None:
        self.close_count = 0

    async def close(self) -> None:
        self.close_count += 1


class FakeDtxConnection:
    def __init__(self) -> None:
        self.terminated = threading.Event()

    async def wait_disconnected(self) -> None:
        while not self.terminated.is_set():
            await asyncio.sleep(0.002)


class FakeDvt:
    def __init__(self) -> None:
        self.dtx = FakeDtxConnection()
        self.connect_count = 0
        self.close_count = 0

    async def connect(self) -> None:
        self.connect_count += 1

    async def close(self) -> None:
        self.close_count += 1
        self.dtx.terminated.set()


class FakeLocation:
    def __init__(self) -> None:
        self.connect_count = 0
        self.sets: list[tuple[float, float]] = []
        self.clear_count = 0

    async def connect(self) -> None:
        self.connect_count += 1

    async def set(self, latitude: float, longitude: float) -> None:
        self.sets.append((latitude, longitude))

    async def clear(self) -> None:
        self.clear_count += 1


class TestDirectSession(DirectDvtLocationSession):
    __test__ = False

    def __init__(self, on_terminated) -> None:
        super().__init__(on_terminated, command_timeout=1)
        self.rsd = FakeRsd()
        self.dvt = FakeDvt()
        self.location = FakeLocation()

    async def _discover_providers(self):
        return [self.rsd]

    def _create_dvt(self, rsd):
        self.assert_identity(rsd, self.rsd)
        return self.dvt

    def _create_location(self, dvt):
        self.assert_identity(dvt, self.dvt)
        return self.location

    @staticmethod
    def assert_identity(value, expected) -> None:
        if value is not expected:
            raise AssertionError("unexpected fake resource")


class DirectDvtLocationSessionTests(unittest.TestCase):
    def test_reuses_one_dvt_channel_for_coordinate_updates(self) -> None:
        terminated: list[str] = []
        session = TestDirectSession(terminated.append)
        self.addCleanup(session.shutdown)

        session.start(1.0, 2.0)
        self.assertTrue(session.active)
        session.update(3.0, 4.0)
        session.update(5.0, 6.0)

        self.assertEqual(session.dvt.connect_count, 1)
        self.assertEqual(session.location.connect_count, 1)
        self.assertEqual(
            session.location.sets,
            [(1.0, 2.0), (3.0, 4.0), (5.0, 6.0)],
        )

        session.clear()
        self.assertFalse(session.active)
        self.assertEqual(session.location.clear_count, 1)
        self.assertEqual(session.dvt.close_count, 1)
        self.assertEqual(session.rsd.close_count, 1)
        self.assertEqual(terminated, [])

    def test_shutdown_clears_session_and_stops_event_loop(self) -> None:
        session = TestDirectSession(lambda _: None)
        session.start(1.0, 2.0)
        thread = session._thread

        session.shutdown()

        self.assertFalse(session.active)
        self.assertEqual(session.location.clear_count, 1)
        self.assertEqual(session.dvt.close_count, 1)
        self.assertEqual(session.rsd.close_count, 1)
        self.assertIsNotNone(thread)
        self.assertFalse(thread.is_alive())

    def test_status_subprocess_can_run_while_session_is_active(self) -> None:
        session = TestDirectSession(lambda _: None)
        self.addCleanup(session.shutdown)
        session.start(1.0, 2.0)

        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "pymobiledevice3"
            executable.touch()
            completed = subprocess.CompletedProcess(
                [str(executable)],
                0,
                "[]",
                "",
            )
            with (
                patch("backend.device.pymobiledevice.PMD3", executable),
                patch(
                    "backend.device.pymobiledevice.subprocess.run",
                    return_value=completed,
                ) as subprocess_run,
            ):
                result = run_pmd3(["usbmux", "list"], timeout=1)

        self.assertFalse(result.failed)
        subprocess_run.assert_called_once()
        self.assertTrue(session.active)

    def test_reports_unexpected_dvt_disconnect_and_releases_resources(self) -> None:
        termination = threading.Event()
        messages: list[str] = []

        def on_terminated(message: str) -> None:
            messages.append(message)
            termination.set()

        session = TestDirectSession(on_terminated)
        self.addCleanup(session.shutdown)
        session.start(1.0, 2.0)

        session.dvt.dtx.terminated.set()
        self.assertTrue(termination.wait(1))
        deadline = time.monotonic() + 1
        while session.active and time.monotonic() < deadline:
            time.sleep(0.002)

        self.assertFalse(session.active)
        self.assertEqual(
            messages,
            ["Persistent DVT location session terminated unexpectedly"],
        )
        self.assertEqual(session.dvt.close_count, 1)
        self.assertEqual(session.rsd.close_count, 1)


if __name__ == "__main__":
    unittest.main()
