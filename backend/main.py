from __future__ import annotations

import json
import re
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field


PMD3 = Path.home() / ".pmd3" / "bin" / "pymobiledevice3"

TUNNELD_HOST = "127.0.0.1"
TUNNELD_PORT = 49151


app = FastAPI(
    title="Location Suite API",
    version="0.2.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class LocationRequest(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


@dataclass
class CommandResult:
    returncode: int | None
    stdout: str
    stderr: str
    timed_out: bool = False

    @property
    def combined(self) -> str:
        parts = [self.stdout.strip(), self.stderr.strip()]
        return "\n".join(part for part in parts if part)

    @property
    def failed(self) -> bool:
        if self.timed_out:
            return True

        if self.returncode != 0:
            return True

        text = self.combined

        if "Traceback (most recent call last)" in text:
            return True

        if "Unable to connect to Tunneld" in text:
            return True

        if "NoDeviceConnectedError" in text:
            return True

        # pymobiledevice3 sometimes logs a real failure but exits 0.
        if re.search(r"(^|\s)ERROR\s", text, flags=re.MULTILINE):
            return True

        return False


def run_command(
    args: list[str],
    timeout: int = 30,
) -> CommandResult:
    if not PMD3.exists():
        return CommandResult(
            returncode=None,
            stdout="",
            stderr=f"pymobiledevice3 not found at {PMD3}",
        )

    try:
        result = subprocess.run(
            [str(PMD3), *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""

        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")

        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")

        return CommandResult(
            returncode=None,
            stdout=stdout,
            stderr=stderr,
            timed_out=True,
        )

    return CommandResult(
        returncode=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )


def require_command(
    args: list[str],
    timeout: int = 30,
) -> CommandResult:
    result = run_command(args, timeout)

    if result.timed_out:
        raise HTTPException(
            status_code=504,
            detail={
                "error": "pymobiledevice3 timed out",
                "output": result.combined,
            },
        )

    if result.failed:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "pymobiledevice3 command failed",
                "returnCode": result.returncode,
                "output": result.combined,
            },
        )

    return result


def tunneld_running() -> bool:
    try:
        with socket.create_connection(
            (TUNNELD_HOST, TUNNELD_PORT),
            timeout=0.5,
        ):
            return True
    except OSError:
        return False


def get_devices() -> list[dict]:
    result = require_command(
        ["usbmux", "list"],
        timeout=10,
    )

    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "Unable to parse device list",
                "output": result.combined,
            },
        )

    if not isinstance(value, list):
        raise HTTPException(
            status_code=502,
            detail="Unexpected pymobiledevice3 device response",
        )

    return value


def probe_device_tunnel() -> tuple[bool, str | None]:
    if not tunneld_running():
        return False, "tunneld is not running"

    try:
        devices = get_devices()
    except HTTPException as exc:
        return False, str(exc.detail)

    if not devices:
        return False, "No iPhone is connected"

    result = run_command(
        [
            "developer",
            "dvt",
            "ls",
            "/",
            "--tunnel",
            "",
        ],
        timeout=10,
    )

    if result.timed_out:
        return False, "Developer tunnel probe timed out"

    if result.failed:
        return False, result.combined or "Developer tunnel probe failed"

    return True, None


@app.get("/api/health")
def health():
    return {
        "ok": True,
        "pymobiledevice3": PMD3.exists(),
        "tunneld": tunneld_running(),
    }


@app.get("/api/device")
def device():
    devices = get_devices()

    if not devices:
        return {
            "connected": False,
            "device": None,
        }

    d = devices[0]

    return {
        "connected": True,
        "device": {
            "name": d.get("DeviceName"),
            "productType": d.get("ProductType"),
            "productVersion": d.get("ProductVersion"),
            "connectionType": d.get("ConnectionType"),
        },
    }


@app.get("/api/tunnel")
def tunnel():
    ready, reason = probe_device_tunnel()

    return {
        "daemonRunning": tunneld_running(),
        "deviceTunnelReady": ready,
        "reason": reason,
    }


@app.post("/api/location/set")
def set_location(location: LocationRequest):
    ready, reason = probe_device_tunnel()

    if not ready:
        raise HTTPException(
            status_code=409,
            detail={
                "error": "Developer tunnel is not ready",
                "reason": reason,
            },
        )

    result = require_command(
        [
            "developer",
            "dvt",
            "simulate-location",
            "set",
            "--tunnel",
            "",
            "--",
            str(location.latitude),
            str(location.longitude),
        ],
        timeout=30,
    )

    return {
        "ok": True,
        "simulating": True,
        "latitude": location.latitude,
        "longitude": location.longitude,
        "output": result.combined or None,
    }


@app.post("/api/location/clear")
def clear_location():
    ready, reason = probe_device_tunnel()

    if not ready:
        raise HTTPException(
            status_code=409,
            detail={
                "error": "Developer tunnel is not ready",
                "reason": reason,
            },
        )

    result = require_command(
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

    return {
        "ok": True,
        "simulating": False,
        "output": result.combined or None,
    }
