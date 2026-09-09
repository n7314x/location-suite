from __future__ import annotations

import json
import time
from collections.abc import Callable

from backend.core.config import (
    DEVICE_ENUMERATION_ATTEMPTS,
    DEVICE_ENUMERATION_RETRY_DELAY,
)
from backend.device.pymobiledevice import CommandResult, run_pmd3
from backend.device.tunnel import probe_device_tunnel


class DeviceError(RuntimeError):
    pass


class DeviceManager:
    def __init__(
        self,
        *,
        run_command: Callable[..., CommandResult] = run_pmd3,
        probe_tunnel: Callable[[], tuple[bool, str | None]] = (
            probe_device_tunnel
        ),
        enumeration_attempts: int = DEVICE_ENUMERATION_ATTEMPTS,
        enumeration_retry_delay: float = DEVICE_ENUMERATION_RETRY_DELAY,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if enumeration_attempts < 1:
            raise ValueError("enumeration_attempts must be at least 1")
        if enumeration_retry_delay < 0:
            raise ValueError("enumeration_retry_delay cannot be negative")

        self._run_command = run_command
        self._probe_tunnel = probe_tunnel
        self._enumeration_attempts = enumeration_attempts
        self._enumeration_retry_delay = enumeration_retry_delay
        self._sleep = sleep

    def devices(self) -> list[dict]:
        last_error = "Unable to enumerate devices"

        for attempt in range(self._enumeration_attempts):
            result = self._run_command(
                ["usbmux", "list"],
                timeout=10,
            )

            if result.failed:
                detail = result.combined
                last_error = "Unable to enumerate devices"
                if detail:
                    last_error = f"{last_error}: {detail}"
            else:
                try:
                    value = json.loads(result.stdout)
                except json.JSONDecodeError:
                    last_error = (
                        "Unable to parse pymobiledevice3 device output"
                    )
                else:
                    if isinstance(value, list):
                        return value
                    last_error = (
                        "Unexpected pymobiledevice3 device response"
                    )

            if attempt + 1 < self._enumeration_attempts:
                self._sleep(self._enumeration_retry_delay)

        raise DeviceError(last_error)

    def first_device(self) -> dict | None:
        devices = self.devices()
        return devices[0] if devices else None

    def require_ready(self) -> None:
        if self.first_device() is None:
            raise DeviceError("No iPhone is connected")

        ready, reason = self._probe_tunnel()

        if not ready:
            raise DeviceError(
                reason or "Developer tunnel is not ready"
            )

device_manager = DeviceManager()
