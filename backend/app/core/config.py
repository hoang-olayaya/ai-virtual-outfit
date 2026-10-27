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

    # External AI Provider (fal.ai) - Optional in bootstrap phase
    FAL_KEY: Union[str, None] = None


settings = Settings()
