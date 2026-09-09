from enum import StrEnum


class SimulationState(StrEnum):
    IDLE = "idle"
    QUEUED = "queued"
    TELEPORTING = "teleporting"
    ACTIVE = "active"
    CLEARING = "clearing"
    PLAYING = "playing"
    PAUSED = "paused"
    ERROR = "error"
