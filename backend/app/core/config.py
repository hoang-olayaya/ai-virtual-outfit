from typing import List, Union
from pydantic import AnyHttpUrl, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )

    APP_NAME: str = "AI Virtual Outfit Preview"
    VERSION: str = "0.1.0"
    APP_ENV: str = "development"
    DEBUG: bool = True
    API_PORT: int = 8000
    API_V1_STR: str = "/api/v1"

    # CORS origins
    CORS_ORIGINS: List[str] = ["*"]

    # Database
    POSTGRES_USER: str = "postgres"
    POSTGRES_PASSWORD: str = "postgres_password_dev"
    POSTGRES_DB: str = "virtual_outfit_db"
    POSTGRES_HOST: str = "postgres"
    POSTGRES_PORT: int = 5432
    DATABASE_URL: str = (
        "postgresql+asyncpg://postgres:postgres_password_dev@postgres:5432/virtual_outfit_db"
    )

    # Redis Broker
    REDIS_HOST: str = "redis"
    REDIS_PORT: int = 6379
    REDIS_URL: str = "redis://redis:6379/0"

    # Local file storage
    STORAGE_LOCAL_PATH: str = "/app/data_storage"

    # Image Upload & Validation Limits
    UPLOAD_MAX_FILE_SIZE_BYTES: int = 10 * 1024 * 1024  # 10 MB
    UPLOAD_MIN_DIMENSION_PX: int = 64
    UPLOAD_MAX_DIMENSION_PX: int = 4096
    UPLOAD_MAX_PIXELS: int = 16_777_216  # 4096 * 4096 (~16 MP)
    UPLOAD_ALLOWED_FORMATS: List[str] = ["JPEG", "PNG", "WEBP"]

    # Task Queue & Worker Execution Settings
    TASK_PUBLISHER_BACKEND: str = "celery"  # "celery" | "fake"
    WORKER_MAX_RETRIES: int = 2
    WORKER_RETRY_BACKOFF_SECONDS: int = 2

    # AI Provider Settings ("fake" in B04; "fal" or "huggingface" from B05/B06)
    AI_PROVIDER: str = "fake"
    FAKE_AI_PROCESSING_DELAY_SECONDS: float = 0.0

    # External AI Provider (Hugging Face Spaces via gradio_client - Free ZeroGPU)
    HF_TOKEN: Union[str, None] = None
    HF_SPACE_ID: str = "yisol/IDM-VTON"
    HF_API_NAME: str = "/tryon"
    HF_GARMENT_DESCRIPTION: str = "Upper body garment"
    HF_AUTO_MASK: bool = True
    HF_AUTO_CROP: bool = False
    HF_DENOISE_STEPS: int = 30
    HF_SEED: int = 42
    HF_TIMEOUT_SECONDS: float = 180.0

    # External AI Provider (fal.ai) - Optional in bootstrap/B04; configured in B05/B06
    FAL_KEY: Union[str, None] = None
    FAL_MODEL_ID: str = "fal-ai/cat-vton"
    FAL_CLOTH_TYPE: str = "upper"
    FAL_QUEUE_BASE_URL: str = "https://queue.fal.run"
    FAL_STORAGE_UPLOAD_URL: str = (
        "https://rest.alpha.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"
    )
    FAL_HTTP_TIMEOUT_SECONDS: float = 30.0
    FAL_POLL_INTERVAL_SECONDS: float = 2.0
    FAL_POLL_TIMEOUT_SECONDS: float = 180.0
    FAL_DOWNLOAD_MAX_RETRIES: int = 3
    FAL_DOWNLOAD_RETRY_BACKOFF_SECONDS: float = 1.0

    # Reliability, Maintenance & Recovery Settings (B08)
    STALE_JOB_THRESHOLD_SECONDS: int = 300  # 5 minutes
    QUEUED_JOB_TIMEOUT_SECONDS: int = 600  # 10 minutes
    TMP_FILE_TTL_SECONDS: int = 3600  # 1 hour
    ORPHAN_DIR_GRACE_PERIOD_SECONDS: int = 900  # 15 minutes
    CELERY_TASK_TIME_LIMIT: int = 300  # 5 minutes hard limit
    CELERY_TASK_SOFT_TIME_LIMIT: int = 240  # 4 minutes soft limit


settings = Settings()
