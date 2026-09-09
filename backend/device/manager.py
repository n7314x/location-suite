from __future__ import annotations

import json

from backend.device.pymobiledevice import run_pmd3
from backend.device.tunnel import probe_device_tunnel


class DeviceError(RuntimeError):
    pass


class DeviceManager:
    def devices(self) -> list[dict]:
        result = run_pmd3(
            ["usbmux", "list"],
            timeout=10,
        )

        if result.failed:
            raise DeviceError(
                result.combined or "Unable to enumerate devices"
            )

        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise DeviceError(
                "Unable to parse pymobiledevice3 device output"
            ) from exc

        if not isinstance(value, list):
            raise DeviceError(
                "Unexpected pymobiledevice3 device response"
            )

        return value

    def first_device(self) -> dict | None:
        devices = self.devices()
        return devices[0] if devices else None

    def require_ready(self) -> None:
        if self.first_device() is None:
            raise DeviceError("No iPhone is connected")

        ready, reason = probe_device_tunnel()

        if not ready:
            raise DeviceError(
                reason or "Developer tunnel is not ready"
            )

    def set_location(
        self,
        latitude: float,
        longitude: float,
    ) -> str:
        self.require_ready()

        result = run_pmd3(
            [
                "developer",
                "dvt",
                "simulate-location",
                "set",
                "--tunnel",
                "",
                "--",
                str(latitude),
                str(longitude),
            ],
            timeout=30,
        )

        if result.failed:
            raise DeviceError(
                result.combined or "Failed to set location"
            )

        return result.combined

    def clear_location(self) -> str:
        self.require_ready()

        result = run_pmd3(
            [
                "developer",
                "dvt",
                "simulate-location",
                "clear",
                "--tunnel",
                "",
            ],
            timeout=30,
        )

        if result.failed:
            raise DeviceError(
                result.combined or "Failed to clear location"
            )

        return result.combined


device_manager = DeviceManager()
