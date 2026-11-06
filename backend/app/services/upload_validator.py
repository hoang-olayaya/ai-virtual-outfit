import asyncio
import io
import warnings
from dataclasses import dataclass
from typing import Dict, Iterable, Optional, Tuple
from fastapi import UploadFile
from PIL import Image, UnidentifiedImageError

from app.core.config import settings
from app.core.errors import ErrorCode, ImageValidationError

_FORMAT_TO_MIME_AND_EXT: Dict[str, Tuple[str, str]] = {
    "JPEG": ("image/jpeg", ".jpg"),
    "PNG": ("image/png", ".png"),
    "WEBP": ("image/webp", ".webp"),
}

_CHUNK_SIZE = 64 * 1024  # 64 KB


@dataclass(frozen=True)
class ValidatedImage:
    """Immutable value object representing a verified, decoded input or output image."""

    field_name: str
    content: bytes
    format: str
    mime_type: str
    extension: str
    width: int
    height: int
    size_bytes: int
    original_filename: Optional[str] = None


class UploadValidator:
    """
    Validates uploaded images for presence, byte size, real format (magic bytes / Pillow decode),
    decompression bomb safety, and pixel dimensions.
    """

    def __init__(
        self,
        max_file_size_bytes: Optional[int] = None,
        min_dimension_px: Optional[int] = None,
        max_dimension_px: Optional[int] = None,
        max_pixels: Optional[int] = None,
        allowed_formats: Optional[Iterable[str]] = None,
    ) -> None:
        self.max_file_size_bytes = (
            max_file_size_bytes
            if max_file_size_bytes is not None
            else settings.UPLOAD_MAX_FILE_SIZE_BYTES
        )
        self.min_dimension_px = (
            min_dimension_px
            if min_dimension_px is not None
            else settings.UPLOAD_MIN_DIMENSION_PX
        )
        self.max_dimension_px = (
            max_dimension_px
            if max_dimension_px is not None
            else settings.UPLOAD_MAX_DIMENSION_PX
        )
        self.max_pixels = (
            max_pixels if max_pixels is not None else settings.UPLOAD_MAX_PIXELS
        )
        raw_formats = (
            allowed_formats
            if allowed_formats is not None
            else settings.UPLOAD_ALLOWED_FORMATS
        )
        self.allowed_formats = {fmt.upper() for fmt in raw_formats}

    def validate_bytes_sync(
        self,
        data: Optional[bytes],
        field_name: str = "image",
        original_filename: Optional[str] = None,
    ) -> ValidatedImage:
        """
        Synchronously validate raw image bytes.
        Checks non-empty, max size, real image format, decompression bomb limits,
        full pixel decode integrity, and dimension bounds.
        """
        if data is None or len(data) == 0:
            raise ImageValidationError(
                error_code=ErrorCode.MISSING_INPUT_IMAGE,
                message=f"Missing or empty image file for '{field_name}'.",
                status_code=400,
                details={"field": field_name},
            )

        size_bytes = len(data)
        if size_bytes > self.max_file_size_bytes:
            raise ImageValidationError(
                error_code=ErrorCode.FILE_TOO_LARGE,
                message=(
                    f"Image '{field_name}' exceeds maximum allowed size of "
                    f"{self.max_file_size_bytes} bytes."
                ),
                status_code=413,
                details={
                    "field": field_name,
                    "max_file_size_bytes": self.max_file_size_bytes,
                },
            )

        # Decode and inspect image safely with Pillow
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(data)) as img:
                    detected_format = (img.format or "").upper()
                    if (
                        detected_format not in self.allowed_formats
                        or detected_format not in _FORMAT_TO_MIME_AND_EXT
                    ):
                        raise ImageValidationError(
                            error_code=ErrorCode.UNSUPPORTED_MEDIA_TYPE,
                            message=(
                                f"Unsupported image format for '{field_name}'. "
                                f"Allowed formats: {', '.join(sorted(self.allowed_formats))}."
                            ),
                            status_code=415,
                            details={
                                "field": field_name,
                                "detected_format": detected_format or "UNKNOWN",
                                "allowed_formats": sorted(self.allowed_formats),
                            },
                        )

                    width, height = img.size
                    total_pixels = width * height
                    if total_pixels <= 0 or total_pixels > self.max_pixels:
                        raise ImageValidationError(
                            error_code=ErrorCode.CORRUPTED_IMAGE,
                            message=(
                                f"Image '{field_name}' exceeds maximum pixel count limit "
                                f"({self.max_pixels} pixels)."
                            ),
                            status_code=400,
                            details={
                                "field": field_name,
                                "width": width,
                                "height": height,
                                "max_pixels": self.max_pixels,
                            },
                        )

                    if (
                        width < self.min_dimension_px
                        or height < self.min_dimension_px
                        or width > self.max_dimension_px
                        or height > self.max_dimension_px
                    ):
                        raise ImageValidationError(
                            error_code=ErrorCode.INVALID_IMAGE_DIMENSIONS,
                            message=(
                                f"Image '{field_name}' dimensions ({width}x{height}) must be between "
                                f"{self.min_dimension_px}x{self.min_dimension_px} and "
                                f"{self.max_dimension_px}x{self.max_dimension_px} pixels."
                            ),
                            status_code=400,
                            details={
                                "field": field_name,
                                "width": width,
                                "height": height,
                                "min_dimension_px": self.min_dimension_px,
                                "max_dimension_px": self.max_dimension_px,
                            },
                        )

                    # Verify structural integrity
                    img.verify()

                # Re-open and force full pixel decoding to catch truncated/corrupted payloads
                with Image.open(io.BytesIO(data)) as img_decode:
                    img_decode.load()

        except ImageValidationError:
            raise
        except (Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            raise ImageValidationError(
                error_code=ErrorCode.CORRUPTED_IMAGE,
                message=f"Image '{field_name}' triggered decompression bomb protection.",
                status_code=400,
                details={"field": field_name},
            ) from exc
        except UnidentifiedImageError as exc:
            raise ImageValidationError(
                error_code=ErrorCode.UNSUPPORTED_MEDIA_TYPE,
                message=f"File provided for '{field_name}' is not a valid supported image.",
                status_code=415,
                details={"field": field_name},
            ) from exc
        except (OSError, SyntaxError, ValueError, TypeError, EOFError) as exc:
            raise ImageValidationError(
                error_code=ErrorCode.CORRUPTED_IMAGE,
                message=f"Image file for '{field_name}' is corrupted or truncated.",
                status_code=400,
                details={"field": field_name},
            ) from exc

        mime_type, extension = _FORMAT_TO_MIME_AND_EXT[detected_format]
        return ValidatedImage(
            field_name=field_name,
            content=data,
            format=detected_format,
            mime_type=mime_type,
            extension=extension,
            width=width,
            height=height,
            size_bytes=size_bytes,
            original_filename=original_filename,
        )

    async def validate_bytes(
        self,
        data: Optional[bytes],
        field_name: str = "image",
        original_filename: Optional[str] = None,
    ) -> ValidatedImage:
        """Asynchronously validate raw image bytes in a worker thread."""
        return await asyncio.to_thread(
            self.validate_bytes_sync,
            data,
            field_name,
            original_filename,
        )

    async def validate_upload_file(
        self,
        upload_file: Optional[UploadFile],
        field_name: str,
    ) -> ValidatedImage:
        """
        Validate a FastAPI UploadFile using bounded chunked reads so oversized uploads
        are rejected immediately without exhausting memory.
        """
        if upload_file is None:
            raise ImageValidationError(
                error_code=ErrorCode.MISSING_INPUT_IMAGE,
                message=f"Required image field '{field_name}' was not provided.",
                status_code=400,
                details={"field": field_name},
            )

        filename = (upload_file.filename or "").strip()
        if not filename:
            raise ImageValidationError(
                error_code=ErrorCode.MISSING_INPUT_IMAGE,
                message=f"No file selected for '{field_name}'.",
                status_code=400,
                details={"field": field_name},
            )

        buffer = bytearray()
        try:
            await upload_file.seek(0)
        except Exception:
            pass

        while True:
            chunk = await upload_file.read(_CHUNK_SIZE)
            if not chunk:
                break
            buffer.extend(chunk)
            if len(buffer) > self.max_file_size_bytes:
                raise ImageValidationError(
                    error_code=ErrorCode.FILE_TOO_LARGE,
                    message=(
                        f"Image '{field_name}' exceeds maximum allowed size of "
                        f"{self.max_file_size_bytes} bytes."
                    ),
                    status_code=413,
                    details={
                        "field": field_name,
                        "max_file_size_bytes": self.max_file_size_bytes,
                    },
                )

        if len(buffer) == 0:
            raise ImageValidationError(
                error_code=ErrorCode.MISSING_INPUT_IMAGE,
                message=f"Uploaded file for '{field_name}' is empty.",
                status_code=400,
                details={"field": field_name},
            )

        return await self.validate_bytes(
            bytes(buffer),
            field_name=field_name,
            original_filename=filename,
        )

    async def validate_try_on_inputs(
        self,
        person_image: Optional[UploadFile],
        garment_image: Optional[UploadFile],
    ) -> Tuple[ValidatedImage, ValidatedImage]:
        """
        Validate both required try-on inputs ('person_image' and 'garment_image').
        Returns (validated_person, validated_garment).
        """
        validated_person = await self.validate_upload_file(
            person_image, field_name="person_image"
        )
        validated_garment = await self.validate_upload_file(
            garment_image, field_name="garment_image"
        )
        return validated_person, validated_garment

