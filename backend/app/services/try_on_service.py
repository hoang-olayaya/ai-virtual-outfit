from typing import Optional
import uuid
from fastapi import UploadFile
from sqlalchemy.exc import IntegrityError
from app.core.errors import (
    AppError,
    DatabaseOperationError,
    ErrorCode,
    InvalidIdempotencyKeyError,
    QueuePublishError,
)
from app.core.logging import logger
from app.models.try_on_job import TryOnJob
from app.queue.publisher import TaskPublisher
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService

_MAX_IDEMPOTENCY_KEY_LENGTH = 255


class TryOnService:
    """
    Application service orchestrating the creation of virtual try-on jobs:
    1. Idempotency check (returns existing job if Idempotency-Key already processed).
    2. Strict validation of both uploaded images (person_image + garment_image).
    3. Atomic file persistence under 'inputs/{job_id}/' on the shared volume.
    4. Database insertion of TryOnJob with status='queued' (with file cleanup on DB failure).
    5. Task publishing of 'job_id' to queue (marks job 'failed' if enqueue fails so it never hangs).
    """

    def __init__(
        self,
        job_repository: JobRepository,
        image_service: ImageService,
        publisher: TaskPublisher,
    ) -> None:
        self.job_repository = job_repository
        self.image_service = image_service
        self.publisher = publisher

    @staticmethod
    def _normalize_idempotency_key(idempotency_key: Optional[str]) -> Optional[str]:
        if idempotency_key is None:
            return None
        cleaned = idempotency_key.strip()
        if not cleaned:
            return None
        if "\x00" in cleaned or any(ord(c) < 32 for c in cleaned):
            raise InvalidIdempotencyKeyError(
                message="Idempotency-Key header contains invalid control characters.",
                details={"key": "contains_control_characters"},
            )
        if len(cleaned) > _MAX_IDEMPOTENCY_KEY_LENGTH:
            raise InvalidIdempotencyKeyError(
                message=f"Idempotency-Key header must not exceed {_MAX_IDEMPOTENCY_KEY_LENGTH} characters.",
                details={
                    "max_length": _MAX_IDEMPOTENCY_KEY_LENGTH,
                    "actual_length": len(cleaned),
                },
            )
        return cleaned

    async def create_try_on_job(
        self,
        person_image: Optional[UploadFile],
        garment_image: Optional[UploadFile],
        idempotency_key: Optional[str] = None,
    ) -> TryOnJob:
        """Validate inputs, store files, create DB record, and publish background task."""
        normalized_key = self._normalize_idempotency_key(idempotency_key)

        # 1. Pre-check Idempotency-Key before decoding or storing images
        if normalized_key is not None:
            existing_job = await self.job_repository.get_by_idempotency_key(normalized_key)
            if existing_job is not None:
                logger.info(
                    "Idempotent request matched existing job_id=%s for key=%s",
                    existing_job.id,
                    normalized_key,
                )
                return existing_job

        # 2. Validate both uploaded images before touching disk or DB
        validated_person, validated_garment = (
            await self.image_service.validator.validate_try_on_inputs(
                person_image=person_image,
                garment_image=garment_image,
            )
        )

        # 3. Store validated input images on shared storage volume
        job_id = uuid.uuid4()
        stored_inputs = await self.image_service.store_input_images(
            job_id=job_id,
            person_image=validated_person,
            garment_image=validated_garment,
        )

        # 4. Persist TryOnJob in PostgreSQL; compensate by cleaning up files on failure
        try:
            job = await self.job_repository.create_job(
                person_image_path=stored_inputs.person_image_path,
                garment_image_path=stored_inputs.garment_image_path,
                idempotency_key=normalized_key,
                job_id=job_id,
            )
            await self.job_repository.session.commit()
            await self.job_repository.session.refresh(job)
        except IntegrityError as exc:
            await self.job_repository.session.rollback()
            await self.image_service.cleanup_input_images(job_id)

            if normalized_key is not None:
                existing_job = await self.job_repository.get_by_idempotency_key(normalized_key)
                if existing_job is not None:
                    logger.info(
                        "Resolved concurrent idempotency collision for key=%s -> job_id=%s",
                        normalized_key,
                        existing_job.id,
                    )
                    return existing_job

            logger.error("Database integrity error creating job_id=%s: %s", job_id, exc)
            raise DatabaseOperationError(
                message="Could not create try-on job due to a database constraint conflict.",
            ) from exc
        except Exception as exc:
            await self.job_repository.session.rollback()
            await self.image_service.cleanup_input_images(job_id)
            logger.error(
                "Database failure creating job_id=%s; rolled back input files: %s",
                job_id,
                exc,
            )
            if isinstance(exc, AppError):
                raise
            raise DatabaseOperationError(
                message="Failed to persist try-on job in database.",
            ) from exc

        # 5. Publish job_id to message broker; record failure state in DB if publish fails
        try:
            await self.publisher.publish_try_on_job(job.id)
        except Exception as exc:
            error_msg = exc.message if isinstance(exc, AppError) else str(exc)
            logger.error(
                "Queue publish failed for job_id=%s; marking job as failed: %s",
                job.id,
                error_msg,
            )
            try:
                await self.job_repository.mark_failed(
                    job_id=job.id,
                    error_code=ErrorCode.QUEUE_PUBLISH_ERROR.value,
                    error_message=error_msg or "Failed to enqueue try-on job to message broker.",
                    increment_retry=False,
                    terminal=True,
                )
                await self.job_repository.session.commit()
            except Exception as db_exc:
                await self.job_repository.session.rollback()
                logger.error(
                    "Failed to record QUEUE_PUBLISH_ERROR in database for job_id=%s: %s",
                    job.id,
                    db_exc,
                )

            if isinstance(exc, QueuePublishError):
                raise
            raise QueuePublishError(
                message=error_msg or "Failed to enqueue try-on job for background processing.",
                details={"job_id": str(job.id)},
            ) from exc

        logger.info("Created and enqueued try-on job_id=%s (status=%s)", job.id, job.status)
        return job

