from pydantic import BaseModel, Field


class Location(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class TeleportRequest(Location):
    name: str | None = Field(default=None, max_length=300)


class FavoriteCreate(Location):
    name: str | None = Field(default=None, max_length=120)


class FavoriteRename(BaseModel):
    name: str = Field(min_length=1, max_length=120)
