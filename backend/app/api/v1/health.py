from typing import Any, Dict
from fastapi import APIRouter, status
from fastapi.responses import JSONResponse
import redis.asyncio as aioredis
from app.core.config import settings
from app.core.logging import logger

router = APIRouter(tags=["health"])


@router.get("/health", status_code=status.HTTP_200_OK)
async def liveness_check() -> Dict[str, Any]:
    """Basic liveness probe checking if application server is running."""
    return {
        "status": "ok",
        "app": settings.APP_NAME,
        "version": settings.VERSION,
        "environment": settings.APP_ENV,
    }


@router.get("/health/ready")
async def readiness_check() -> JSONResponse:
    """Readiness probe checking connectivity to dependent services (Redis, PostgreSQL)."""
    checks: Dict[str, str] = {
        "redis": "unknown",
        "storage": "unknown",
        "database": "unknown",
    }
    is_ready = True

    # 1. Check Redis connectivity
    try:
        r = aioredis.from_url(settings.REDIS_URL, socket_connect_timeout=2)
        await r.ping()
        await r.aclose()
        checks["redis"] = "connected"
    except Exception as e:
        logger.warning("Readiness probe Redis check failed: %s", str(e))
        checks["redis"] = f"unreachable: {str(e)}"
        is_ready = False

    # 2. Check storage directory accessibility
    import os
    try:
        os.makedirs(settings.STORAGE_LOCAL_PATH, exist_ok=True)
        checks["storage"] = f"writable ({settings.STORAGE_LOCAL_PATH})"
    except Exception as e:
        logger.warning("Readiness probe Storage check failed: %s", str(e))
        checks["storage"] = f"error: {str(e)}"
        is_ready = False

    # 3. Check PostgreSQL database connectivity
    from app.db.session import ping_database
    try:
        db_ok = await ping_database()
        if db_ok:
            checks["database"] = "connected"
        else:
            checks["database"] = "unreachable"
            is_ready = False
    except Exception as e:
        logger.warning("Readiness probe Database check failed: %s", str(e))
        checks["database"] = f"unreachable: {str(e)}"
        is_ready = False

    status_code = status.HTTP_200_OK if is_ready else status.HTTP_503_SERVICE_UNAVAILABLE
    return JSONResponse(
        status_code=status_code,
        content={
            "status": "ready" if is_ready else "not_ready",
            "checks": checks,
        },
    )
