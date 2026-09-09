from fastapi import APIRouter, HTTPException, status

from backend.schemas.location import Location
from backend.simulation.manager import (
    SimulationBusy,
    simulation_manager,
)

router = APIRouter()


@router.get("/simulation")
def simulation_status():
    return simulation_manager.snapshot()


@router.post(
    "/simulation/teleport",
    status_code=status.HTTP_202_ACCEPTED,
)
def teleport(location: Location):
    try:
        operation_id = simulation_manager.teleport(
            location.latitude,
            location.longitude,
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
def legacy_set(location: Location):
    return teleport(location)


@router.post(
    "/location/clear",
    status_code=status.HTTP_202_ACCEPTED,
)
def legacy_clear():
    return clear()
