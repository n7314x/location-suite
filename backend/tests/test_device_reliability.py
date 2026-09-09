from __future__ import annotations

import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from backend.device.manager import DeviceError, DeviceManager
from backend.device.pymobiledevice import CommandResult, run_pmd3


class DeviceEnumerationTests(unittest.TestCase):
    def test_enumeration_retries_transient_failures(self) -> None:
        results = iter(
            [
                CommandResult(1, "", "usbmux unavailable"),
                CommandResult(1, "", "connection reset"),
                CommandResult(0, '[{"DeviceName": "iPhone"}]', ""),
            ]
        )
        calls: list[tuple[list[str], int]] = []
        delays: list[float] = []

        def run_command(args: list[str], timeout: int) -> CommandResult:
            calls.append((args, timeout))
            return next(results)

        manager = DeviceManager(
            run_command=run_command,
            enumeration_attempts=3,
            enumeration_retry_delay=0.01,
            sleep=delays.append,
        )

        self.assertEqual(manager.devices(), [{"DeviceName": "iPhone"}])
        self.assertEqual(len(calls), 3)
        self.assertEqual(delays, [0.01, 0.01])

    def test_enumeration_exposes_persistent_failure(self) -> None:
        calls = 0

        def run_command(args: list[str], timeout: int) -> CommandResult:
            nonlocal calls
            calls += 1
            return CommandResult(1, "", f"persistent usbmux failure {calls}")

        manager = DeviceManager(
            run_command=run_command,
            enumeration_attempts=3,
            enumeration_retry_delay=0,
            sleep=lambda _: None,
        )

        with self.assertRaisesRegex(
            DeviceError,
            "Unable to enumerate devices: persistent usbmux failure 3",
        ):
            manager.devices()
        self.assertEqual(calls, 3)


class PymobiledeviceSerializationTests(unittest.TestCase):
    def test_subprocess_invocations_are_process_wide_serialized(self) -> None:
        active = 0
        maximum = 0
        state_lock = threading.Lock()
        start_barrier = threading.Barrier(3)

        def fake_run(*args, **kwargs):
            nonlocal active, maximum
            with state_lock:
                active += 1
                maximum = max(maximum, active)
            try:
                time.sleep(0.03)
                return subprocess.CompletedProcess(args[0], 0, "[]", "")
            finally:
                with state_lock:
                    active -= 1

        def invoke() -> None:
            start_barrier.wait()
            result = run_pmd3(["usbmux", "list"], timeout=1)
            self.assertFalse(result.failed)

        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "pymobiledevice3"
            executable.touch()
            with (
                patch("backend.device.pymobiledevice.PMD3", executable),
                patch(
                    "backend.device.pymobiledevice.subprocess.run",
                    side_effect=fake_run,
                ),
            ):
                threads = [threading.Thread(target=invoke) for _ in range(2)]
                for thread in threads:
                    thread.start()
                start_barrier.wait()
                for thread in threads:
                    thread.join(1)
                    self.assertFalse(thread.is_alive())

        self.assertEqual(maximum, 1)


if __name__ == "__main__":
    unittest.main()
