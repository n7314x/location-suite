import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]

PMD3 = Path.home() / ".pmd3" / "bin" / "pymobiledevice3"

DATABASE_PATH = Path(
    os.environ.get(
        "LOCATION_SUITE_DATABASE_PATH",
        PROJECT_ROOT / "data" / "location-suite.sqlite3",
    )
)

SEARCH_BASE_URL = os.environ.get(
    "LOCATION_SUITE_SEARCH_BASE_URL",
    "https://photon.komoot.io",
).rstrip("/")
SEARCH_TIMEOUT = 8
SEARCH_CACHE_SECONDS = 300
SEARCH_CACHE_ENTRIES = 128
HISTORY_LIMIT = 100

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
