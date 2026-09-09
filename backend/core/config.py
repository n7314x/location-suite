import os
from pathlib import Path

PMD3 = Path.home() / ".pmd3" / "bin" / "pymobiledevice3"

TUNNELD_HOST = "127.0.0.1"
TUNNELD_PORT = 49151

DEVICE_COMMAND_TIMEOUT = 30
TUNNEL_PROBE_TIMEOUT = 10


def _positive_float(name: str, default: float) -> float:
    try:
        value = float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default

    return value if value > 0 else default


def _positive_int(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default

    return value if value > 0 else default


DEVICE_ENUMERATION_ATTEMPTS = _positive_int(
    "LOCATION_SUITE_DEVICE_ENUMERATION_ATTEMPTS",
    3,
)
DEVICE_ENUMERATION_RETRY_DELAY = _positive_float(
    "LOCATION_SUITE_DEVICE_ENUMERATION_RETRY_DELAY",
    0.25,
)
