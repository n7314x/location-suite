from fastapi import APIRouter

from backend.core.config import PMD3
from backend.device.tunnel import tunneld_running

router = APIRouter()


@router.get("/health")
def health():
    return {
        "ok": True,
        "pymobiledevice3": PMD3.exists(),
        "tunneld": tunneld_running(),
    }
