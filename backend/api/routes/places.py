from fastapi import APIRouter, HTTPException, Query, status

from backend.schemas.location import FavoriteCreate, FavoriteRename
from backend.schemas.places import (
    ClearHistoryResponse,
    FavoriteItemResponse,
    FavoritesResponse,
    HistoryResponse,
)
from backend.storage.database import (
    DuplicateFavorite,
    FavoriteNotFound,
    location_store,
)

router = APIRouter()


@router.get("/favorites", response_model=FavoritesResponse)
def favorites():
    return {"favorites": location_store.list_favorites()}


@router.post(
    "/favorites",
    status_code=status.HTTP_201_CREATED,
    response_model=FavoriteItemResponse,
)
def create_favorite(favorite: FavoriteCreate):
    try:
        created = location_store.create_favorite(
            favorite.latitude,
            favorite.longitude,
            favorite.name,
        )
    except DuplicateFavorite as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"favorite": created}


@router.patch(
    "/favorites/{favorite_id}",
    response_model=FavoriteItemResponse,
)
def rename_favorite(favorite_id: int, update: FavoriteRename):
    try:
        favorite = location_store.rename_favorite(favorite_id, update.name)
    except FavoriteNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"favorite": favorite}


@router.delete(
    "/favorites/{favorite_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
def delete_favorite(favorite_id: int):
    try:
        location_store.delete_favorite(favorite_id)
    except FavoriteNotFound as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@router.get("/history", response_model=HistoryResponse)
def history(limit: int = Query(default=50, ge=1, le=100)):
    return {"history": location_store.list_history(limit=limit)}


@router.delete("/history", response_model=ClearHistoryResponse)
def clear_history():
    return {"cleared": location_store.clear_history()}
