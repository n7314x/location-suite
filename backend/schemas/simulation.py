from pydantic import BaseModel

from backend.schemas.location import Location


class SimulationSnapshot(BaseModel):
    state: str
    operationId: str | None = None
    location: Location | None = None
    error: str | None = None
