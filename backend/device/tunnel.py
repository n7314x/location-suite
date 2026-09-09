from __future__ import annotations

import socket

from backend.core.config import (
    TUNNELD_HOST,
    TUNNELD_PORT,
    TUNNEL_PROBE_TIMEOUT,
)
from backend.device.pymobiledevice import run_pmd3


def tunneld_running() -> bool:
    try:
        with socket.create_connection(
            (TUNNELD_HOST, TUNNELD_PORT),
            timeout=0.5,
        ):
            return True
    except OSError:
        return False


def probe_device_tunnel() -> tuple[bool, str | None]:
    if not tunneld_running():
        return False, "tunneld is not running"

    result = run_pmd3(
        [
            "developer",
            "dvt",
            "ls",
            "/",
            "--tunnel",
            "",
        ],
        timeout=TUNNEL_PROBE_TIMEOUT,
    )

    if result.timed_out:
        return False, "Developer tunnel probe timed out"

    if result.failed:
        return (
            False,
            result.combined or "Developer tunnel probe failed",
        )

    return True, None
