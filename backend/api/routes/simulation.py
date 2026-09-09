from fastapi import APIRouter, HTTPException, status

from backend.history.service import SimulationHistoryService
from backend.schemas.location import TeleportRequest
from backend.simulation.manager import (
    SimulationBusy,
    simulation_manager,
)
from backend.storage.database import location_store

router = APIRouter()
history_service = SimulationHistoryService(location_store)


@router.get("/simulation")
def simulation_status():
    return simulation_manager.snapshot()


@router.post(
    "/simulation/teleport",
    status_code=status.HTTP_202_ACCEPTED,
)
def teleport(location: TeleportRequest):
    try:
        operation_id = simulation_manager.teleport(
            location.latitude,
            location.longitude,
            on_success=history_service.success_callback(location.name),
        )
    except SimulationBusy as exc:
        raise HTTPException(
            status_code=409,
            detail=str(exc),
        )

    return {
        "accepted": True,
        "operationId": operation_id,
    }


@router.post(
    "/simulation/clear",
    status_code=status.HTTP_202_ACCEPTED,
)
def clear():
    try:
        operation_id = simulation_manager.clear()
    except SimulationBusy as exc:
        raise HTTPException(
            status_code=409,
            detail=str(exc),
        )

    return {
        "accepted": True,
        "operationId": operation_id,
    }


@router.post(
    "/location/set",
    status_code=status.HTTP_202_ACCEPTED,
)
def legacy_set(location: TeleportRequest):
    return teleport(location)


@router.post(
    "/location/clear",
    status_code=status.HTTP_202_ACCEPTED,
)
def legacy_clear():
    return clear()
