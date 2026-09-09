from fastapi import APIRouter, HTTPException, Query

from backend.routing.search import SearchProviderError, search_provider
from backend.schemas.places import SearchResponse

router = APIRouter()


@router.get("/search", response_model=SearchResponse)
def search(
    q: str = Query(min_length=2, max_length=200),
    limit: int = Query(default=6, ge=1, le=10),
):
    query = " ".join(q.split())
    if len(query) < 2:
        raise HTTPException(status_code=422, detail="Search query is too short")
    try:
        results = search_provider.search(query, limit=limit)
    except SearchProviderError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"results": [result.as_dict() for result in results]}
