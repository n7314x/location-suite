from fastapi import APIRouter

from backend.device.tunnel import (
    probe_device_tunnel,
    tunneld_running,
)

router = APIRouter()


@router.get("/tunnel")
def tunnel():
    ready, reason = probe_device_tunnel()

    return {
        "daemonRunning": tunneld_running(),
        "deviceTunnelReady": ready,
        "reason": reason,
    }
