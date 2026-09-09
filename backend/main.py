from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from backend.api.routes import (
    device,
    health,
    places,
    search,
    simulation,
    tunnel,
)
from backend.simulation.manager import simulation_manager
from backend.storage.database import location_store


@asynccontextmanager
async def lifespan(_app: FastAPI):
    location_store.initialize()
    try:
        yield
    finally:
        simulation_manager.shutdown()


app = FastAPI(
    title="Location Suite API",
    version="0.4.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(
    health.router,
    prefix="/api",
    tags=["health"],
)

app.include_router(
    device.router,
    prefix="/api",
    tags=["device"],
)

app.include_router(
    tunnel.router,
    prefix="/api",
    tags=["tunnel"],
)

app.include_router(
    simulation.router,
    prefix="/api",
    tags=["simulation"],
)

app.include_router(
    search.router,
    prefix="/api",
    tags=["search"],
)

app.include_router(
    places.router,
    prefix="/api",
    tags=["places"],
)


@app.get("/")
def root():
    return {
        "name": "Location Suite",
        "version": "0.4.0",
    }
