from pydantic import BaseModel


class SearchResultResponse(BaseModel):
    id: str
    displayName: str
    latitude: float
    longitude: float
    category: str | None = None
    type: str | None = None
    addressComponents: dict[str, str] | None = None


class SearchResponse(BaseModel):
    results: list[SearchResultResponse]


class FavoriteResponse(BaseModel):
    id: int
    name: str
    latitude: float
    longitude: float
    createdAt: str
    updatedAt: str


class FavoriteItemResponse(BaseModel):
    favorite: FavoriteResponse


class FavoritesResponse(BaseModel):
    favorites: list[FavoriteResponse]


class HistoryItemResponse(BaseModel):
    id: int
    name: str | None = None
    latitude: float
    longitude: float
    createdAt: str


class HistoryResponse(BaseModel):
    history: list[HistoryItemResponse]


class ClearHistoryResponse(BaseModel):
    cleared: int
