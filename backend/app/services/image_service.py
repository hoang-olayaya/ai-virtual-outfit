import mimetypes
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple, Union

from app.core.config import settings
from app.core.logging import logger
from app.services.upload_validator import UploadValidator, ValidatedImage
from app.storage.local_storage import LocalStorageAdapter

_EXT_TO_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}


@dataclass(frozen=True)
class StoredInputImages:
    """Relative POSIX paths for stored person and garment input images."""

    job_id: uuid.UUID
    person_image_path: str
    garment_image_path: str


class ImageService:
    """
    Application service coordinating image validation, structured storage layout,
    safe media retrieval, and automatic cleanup on partial failure.

    Storage hierarchy inside Shared Volume:
    - inputs/{job_id}/person.{ext}
    - inputs/{job_id}/garment.{ext}
    - outputs/{job_id}/result.{ext}
    """

    def __init__(
        self,
        storage: Optional[LocalStorageAdapter] = None,
        validator: Optional[UploadValidator] = None,
    ) -> None:
        self.storage = storage or LocalStorageAdapter()
        self.validator = validator or UploadValidator()

    @staticmethod
    def _normalize_job_id(job_id: Union[uuid.UUID, str]) -> uuid.UUID:
        if isinstance(job_id, uuid.UUID):
            return job_id
        try:
            return uuid.UUID(str(job_id))
        except (ValueError, TypeError) as exc:
            raise ValueError(f"Invalid job_id UUID: {job_id}") from exc

    async def store_input_images(
        self,
        job_id: Union[uuid.UUID, str],
        person_image: ValidatedImage,
        garment_image: ValidatedImage,
    ) -> StoredInputImages:
        """
        Store both validated input images under 'inputs/{job_id}/'.
        If storing the second image fails, automatically cleans up 'inputs/{job_id}/'
        so no orphan files remain on disk.
        """
        normalized_id = self._normalize_job_id(job_id)
        person_rel_path = f"inputs/{normalized_id}/person{person_image.extension}"
        garment_rel_path = f"inputs/{normalized_id}/garment{garment_image.extension}"

        try:
            saved_person_path = await self.storage.save_bytes(
                person_rel_path, person_image.content
            )
            saved_garment_path = await self.storage.save_bytes(
                garment_rel_path, garment_image.content
            )
            logger.info(
                "Stored input images for job_id=%s (person=%s, garment=%s)",
                normalized_id,
                saved_person_path,
                saved_garment_path,
            )
            return StoredInputImages(
                job_id=normalized_id,
                person_image_path=saved_person_path,
                garment_image_path=saved_garment_path,
            )
        except Exception as exc:
            logger.error(
                "Error storing input images for job_id=%s; rolling back partial files: %s",
                normalized_id,
                exc,
            )
            await self.cleanup_input_images(normalized_id)
            raise

    def store_result_image_sync(
        self,
        job_id: Union[uuid.UUID, str],
        image_bytes: bytes,
        validate: bool = True,
        default_extension: str = ".jpg",
    ) -> str:
        """
        Synchronously validate and store AI result image under 'outputs/{job_id}/result.{ext}'.
        Designed for direct use by Celery Worker tasks as well as async wrappers.
        """
        normalized_id = self._normalize_job_id(job_id)
        if validate:
            validated = self.validator.validate_bytes_sync(
                image_bytes, field_name="result_image"
            )
            extension = validated.extension
        else:
            extension = (
                default_extension
                if default_extension.startswith(".")
                else f".{default_extension}"
            )

        result_rel_path = f"outputs/{normalized_id}/result{extension}"
        saved_path = self.storage.save_bytes_sync(result_rel_path, image_bytes)
        logger.info("Stored result image for job_id=%s at %s", normalized_id, saved_path)
        return saved_path

    async def store_result_image(
        self,
        job_id: Union[uuid.UUID, str],
        image_bytes: bytes,
        validate: bool = True,
        default_extension: str = ".jpg",
    ) -> str:
        """Asynchronously validate and store AI result image under 'outputs/{job_id}/result.{ext}'."""
        normalized_id = self._normalize_job_id(job_id)
        if validate:
            validated = await self.validator.validate_bytes(
                image_bytes, field_name="result_image"
            )
            extension = validated.extension
        else:
            extension = (
                default_extension
                if default_extension.startswith(".")
                else f".{default_extension}"
            )

        result_rel_path = f"outputs/{normalized_id}/result{extension}"
        saved_path = await self.storage.save_bytes(result_rel_path, image_bytes)
        logger.info("Stored result image for job_id=%s at %s", normalized_id, saved_path)
        return saved_path

    @staticmethod
    def detect_mime_type(relative_path: Union[str, Path]) -> str:
        ext = Path(str(relative_path)).suffix.lower()
        if ext in _EXT_TO_MIME:
            return _EXT_TO_MIME[ext]
        guessed, _ = mimetypes.guess_type(str(relative_path))
        return guessed or "application/octet-stream"

    def read_image_sync(self, relative_path: str) -> Tuple[bytes, str]:
        """Synchronously read image bytes and return (bytes, mime_type)."""
        content = self.storage.read_bytes_sync(relative_path)
        mime_type = self.detect_mime_type(relative_path)
        return content, mime_type

    async def read_image(self, relative_path: str) -> Tuple[bytes, str]:
        """Asynchronously read image bytes and return (bytes, mime_type)."""
        content = await self.storage.read_bytes(relative_path)
        mime_type = self.detect_mime_type(relative_path)
        return content, mime_type

    def resolve_image_path(self, relative_path: str) -> Path:
        """Verify and return the safe local Path for an existing image file."""
        return self.storage.get_file_path(relative_path)

    async def cleanup_input_images(self, job_id: Union[uuid.UUID, str]) -> bool:
        """Remove 'inputs/{job_id}' directory safely (ignores if already absent)."""
        normalized_id = self._normalize_job_id(job_id)
        try:
            return await self.storage.delete_directory(f"inputs/{normalized_id}")
        except Exception as exc:
            logger.warning(
                "Failed to cleanup input directory for job_id=%s: %s",
                normalized_id,
                exc,
            )
            return False

    async def cleanup_output_images(self, job_id: Union[uuid.UUID, str]) -> bool:
        """Remove 'outputs/{job_id}' directory safely."""
        normalized_id = self._normalize_job_id(job_id)
        return await self.storage.delete_directory(f"outputs/{normalized_id}")

    async def delete_job_images(self, job_id: Union[uuid.UUID, str]) -> Tuple[bool, bool]:
        """
        Delete both 'inputs/{job_id}' and 'outputs/{job_id}' directories for a job.
        Returns (inputs_deleted, outputs_deleted).
        """
        normalized_id = self._normalize_job_id(job_id)
        inputs_deleted = await self.storage.delete_directory(f"inputs/{normalized_id}")
        outputs_deleted = await self.storage.delete_directory(f"outputs/{normalized_id}")
        logger.info(
            "Deleted job images for job_id=%s (inputs_deleted=%s, outputs_deleted=%s)",
            normalized_id,
            inputs_deleted,
            outputs_deleted,
        )
        return inputs_deleted, outputs_deleted

    async def cleanup_expired_temp_files(self, max_age_seconds: Optional[int] = None) -> int:
        """Scan 'tmp/' directory and delete expired '.part' files."""
        ttl = max_age_seconds if max_age_seconds is not None else settings.TMP_FILE_TTL_SECONDS
        return await self.storage.cleanup_temp_files(ttl)

    async def list_stored_job_ids(self, kind: str = "inputs") -> List[uuid.UUID]:
        """
        List all job UUID directories stored under 'inputs/' or 'outputs/'.
        Non-UUID directory names are ignored.
        """
        if kind not in ("inputs", "outputs"):
            raise ValueError(f"Invalid kind '{kind}', must be 'inputs' or 'outputs'.")
        dir_names = await self.storage.list_subdirectories(kind)
        valid_uuids: List[uuid.UUID] = []
        for name in dir_names:
            try:
                valid_uuids.append(uuid.UUID(name))
            except (ValueError, TypeError):
                continue
        return valid_uuids

    def get_directory_mtime(self, relative_dir: str) -> float:
        """Get the modification time of a directory on storage."""
        return self.storage.get_directory_mtime_sync(relative_dir)

