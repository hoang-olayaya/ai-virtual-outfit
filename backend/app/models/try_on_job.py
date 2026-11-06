import enum
import uuid
from datetime import datetime
from typing import Optional
from sqlalchemy import (
    Boolean,
    DateTime,
    Enum,
    Integer,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


class JobStatus(str, enum.Enum):
    QUEUED = "queued"
    PROCESSING = "processing"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


class TryOnJob(Base):
    __tablename__ = "try_on_jobs"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    idempotency_key: Mapped[Optional[str]] = mapped_column(
        String(255), unique=True, nullable=True, index=True
    )
    status: Mapped[JobStatus] = mapped_column(
        Enum(JobStatus, native_enum=False, length=32),
        default=JobStatus.QUEUED,
        nullable=False,
        index=True,
    )

    # Input image storage paths (relative to shared storage volume)
    person_image_path: Mapped[str] = mapped_column(String(512), nullable=False)
    garment_image_path: Mapped[str] = mapped_column(String(512), nullable=False)

    # Output image storage path (relative to shared storage volume)
    result_image_path: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)

    # External AI Provider tracking
    provider_name: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    provider_request_id: Mapped[Optional[str]] = mapped_column(
        String(255), nullable=True, index=True
    )

    # Error & Retry handling
    error_code: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    error_message: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    retry_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    # History / Saved state
    is_saved: Mapped[bool] = mapped_column(
        Boolean, default=False, nullable=False, index=True
    )
    saved_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    # Audit Timestamps
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
        index=True,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
    completed_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    def __init__(self, **kwargs):
        kwargs.setdefault("id", uuid.uuid4())
        kwargs.setdefault("status", JobStatus.QUEUED)
        kwargs.setdefault("retry_count", 0)
        kwargs.setdefault("is_saved", False)
        super().__init__(**kwargs)

    def __repr__(self) -> str:
        return f"<TryOnJob id={self.id} status={self.status} is_saved={self.is_saved}>"
