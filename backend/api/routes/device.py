from fastapi import APIRouter, HTTPException

from backend.device.manager import (
    DeviceError,
    device_manager,
)

router = APIRouter()


@router.get("/device")
def device():
    try:
        d = device_manager.first_device()
    except DeviceError as exc:
        raise HTTPException(
            status_code=502,
            detail=str(exc),
        )

    if d is None:
        return {
            "connected": False,
            "device": None,
        }

    return {
        "connected": True,
        "device": {
            "name": d.get("DeviceName"),
            "productType": d.get("ProductType"),
            "productVersion": d.get("ProductVersion"),
            "connectionType": d.get("ConnectionType"),
        },
    }
