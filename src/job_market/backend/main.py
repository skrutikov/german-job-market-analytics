"""
Application entry point for the Liora Job Market API.

Run from the project root with:
    python -m uvicorn job_market.backend.main:api --reload

Run in Docker with:
    exec python -m uvicorn job_market.backend.main:api --host 0.0.0.0 --port 8000

Swagger UI is available at:
    http://127.0.0.1:8000/docs
"""

from fastapi import FastAPI
from prometheus_client import make_asgi_app

from job_market.backend.routes.jobs import router as jobs_router
from job_market.backend.routes.health import router as health_router
from job_market.backend.routes.statistics import router as statistics_router

api = FastAPI(
    title="Liora Job Market API",
    version="0.1.0",
)

api.include_router(health_router)
api.include_router(jobs_router)
api.include_router(statistics_router)

metrics_app = make_asgi_app()
api.mount("/metrics", metrics_app)
