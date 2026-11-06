from fastapi import APIRouter
from app.api.v1.health import router as health_router
from app.api.v1.history import router as history_router
from app.api.v1.jobs import router as jobs_router
from app.api.v1.media import router as media_router
from app.api.v1.try_ons import router as try_ons_router

api_v1_router = APIRouter()

# Attach health router under /api/v1
api_v1_router.include_router(health_router)

# Attach TryOn creation, Job status, Media, and History routers under /api/v1
api_v1_router.include_router(try_ons_router)
api_v1_router.include_router(jobs_router)
api_v1_router.include_router(media_router)
api_v1_router.include_router(history_router)
