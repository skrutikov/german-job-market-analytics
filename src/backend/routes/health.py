"""
Health-check route for the Liora Job Market API.

This module provides an endpoint for verifying that the API is running
and able to respond to HTTP requests.
"""

from typing import Literal

from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter(
    prefix="/health",
    tags=["Health"],
)


class HealthResponse(BaseModel):
    """Response returned by the health-check endpoint."""

    status: Literal["ok"]


@router.get(
    "",
    summary="Check API health",
    response_description="The current status of the API",
    response_model=HealthResponse,
)
def get_health() -> HealthResponse:
    """
    Check whether the API is running.

    This basic health check confirms that the application can receive
    and respond to requests.
    """
    return HealthResponse(status="ok")
