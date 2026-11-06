import asyncio
import os
import re
import shutil
import uuid
from pathlib import Path, PurePosixPath
from typing import Union

from app.core.config import settings
from app.core.errors import (
    ErrorCode,
    ImageNotFoundError,
    PathTraversalError,
    StorageError,
)
from app.core.logging import logger

_WINDOWS_DRIVE_RE = re.compile(r"^[a-zA-Z]:")


class LocalStorageAdapter:
    """
    Adapter for local filesystem / shared Docker volume storage.

    Guarantees:
    - Strict path traversal protection (rejects '..', absolute paths, drive letters, null bytes, symlinks).
    - Atomic file writes via temporary '.part' files in 'tmp/' before os.replace().
    - Safe directory layout: 'inputs/', 'outputs/', 'tmp/'.
    """

    SUBDIRS = ("inputs", "outputs", "tmp")

    def __init__(self, base_path: Union[str, Path, None] = None) -> None:
        raw_base = base_path if base_path is not None else settings.STORAGE_LOCAL_PATH
        self._base_path = Path(raw_base)

    @property
    def base_path(self) -> Path:
        return self._base_path

    def ensure_base_dirs(self) -> Path:
        """Ensure root storage directory and standard subdirectories ('inputs', 'outputs', 'tmp') exist."""
        try:
            self._base_path.mkdir(parents=True, exist_ok=True)
            resolved_root = self._base_path.resolve()
            for subdir in self.SUBDIRS:
                (resolved_root / subdir).mkdir(parents=True, exist_ok=True)
            return resolved_root
        except OSError as exc:
            logger.error("Failed to initialize storage directories at %s: %s", self._base_path, exc)
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Storage directory is unavailable or not writable.",
            ) from exc

    def _validate_relative_path_Input(
        self, relative_path: Union[str, Path, PurePosixPath]
    ) -> PurePosixPath:
        """Validate raw string/Path input before joining with base_path."""
        if relative_path is None:
            raise PathTraversalError("Storage path cannot be None.")

        raw_str = str(relative_path).strip()
        if not raw_str:
            raise PathTraversalError("Storage path cannot be empty.")

        if "\x00" in raw_str:
            raise PathTraversalError("Null bytes are not allowed in storage paths.")

        if raw_str.startswith(("/", "\\")) or _WINDOWS_DRIVE_RE.match(raw_str):
            raise PathTraversalError("Absolute paths or drive letters are not allowed.")

        # Normalize backslashes to forward slashes for uniform checking across OSes
        normalized_str = raw_str.replace("\\", "/")
        segments = [seg for seg in normalized_str.split("/") if seg != ""]
        if not segments:
            raise PathTraversalError("Storage path must contain a valid relative target.")

        for seg in segments:
            if seg in (".", ".."):
                raise PathTraversalError("Relative path traversal segments ('.' or '..') are forbidden.")

        return PurePosixPath(*segments)

    def resolve_safe_path(self, relative_path: Union[str, Path, PurePosixPath]) -> Path:
        """
        Resolve a relative path safely within the storage root directory.
        Raises PathTraversalError if the path escapes the base directory or traverses a symlink.
        """
        posix_rel = self._validate_relative_path_Input(relative_path)

        try:
            resolved_root = self._base_path.resolve()
        except OSError as exc:
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Failed to resolve base storage directory.",
            ) from exc

        candidate = resolved_root.joinpath(*posix_rel.parts)

        # Reject symlinks along any existing part of the path
        current = resolved_root
        for part in posix_rel.parts:
            current = current / part
            if current.is_symlink():
                raise PathTraversalError("Symbolic links are not permitted inside storage.")

        try:
            resolved_target = candidate.resolve()
        except OSError as exc:
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Failed to resolve target storage path.",
            ) from exc

        if not resolved_target.is_relative_to(resolved_root):
            raise PathTraversalError("Resolved path escapes the storage root directory.")

        if resolved_target == resolved_root:
            raise PathTraversalError("Target path cannot be the storage root itself.")

        return resolved_target

    def save_bytes_sync(self, relative_path: Union[str, Path], data: bytes) -> str:
        """
        Atomically write bytes to relative_path using a temporary file in 'tmp/'.
        Returns the normalized POSIX relative path string.
        """
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise ValueError("Data to store must be bytes-like.")

        posix_rel = self._validate_relative_path_Input(relative_path)
        resolved_root = self.ensure_base_dirs()
        target_path = self.resolve_safe_path(posix_rel)

        tmp_dir = resolved_root / "tmp"
        tmp_file = tmp_dir / f"{uuid.uuid4().hex}.part"

        try:
            target_path.parent.mkdir(parents=True, exist_ok=True)
            with open(tmp_file, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp_file, target_path)
            return posix_rel.as_posix()
        except PathTraversalError:
            raise
        except OSError as exc:
            logger.error("Failed to write file to storage path '%s': %s", posix_rel, exc)
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Failed to write file to storage.",
            ) from exc
        finally:
            if tmp_file.exists():
                try:
                    tmp_file.unlink()
                except OSError:
                    pass

    async def save_bytes(self, relative_path: Union[str, Path], data: bytes) -> str:
        """Asynchronously write bytes atomically to relative_path."""
        return await asyncio.to_thread(self.save_bytes_sync, relative_path, data)

    def read_bytes_sync(self, relative_path: Union[str, Path]) -> bytes:
        """Synchronously read bytes from a safe relative path."""
        target_path = self.get_file_path(relative_path)
        try:
            return target_path.read_bytes()
        except OSError as exc:
            logger.error("Failed to read file from storage path '%s': %s", relative_path, exc)
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Failed to read image from storage.",
            ) from exc

    async def read_bytes(self, relative_path: Union[str, Path]) -> bytes:
        """Asynchronously read bytes from a safe relative path."""
        return await asyncio.to_thread(self.read_bytes_sync, relative_path)

    def get_file_path(self, relative_path: Union[str, Path]) -> Path:
        """
        Verify that relative_path is safe, exists, and is a regular file.
        Returns the resolved Path object.
        """
        target_path = self.resolve_safe_path(relative_path)
        try:
            if not target_path.exists() or not target_path.is_file():
                raise ImageNotFoundError(
                    message=f"Image file not found: {PurePosixPath(str(relative_path).replace(chr(92), '/'))}",
                )
        except OSError as exc:
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Storage unavailable while checking file existence.",
            ) from exc
        return target_path

    def delete_file_sync(self, relative_path: Union[str, Path]) -> bool:
        """
        Synchronously delete a single file if it exists.
        Returns True if a file was deleted, False if it did not exist.
        """
        target_path = self.resolve_safe_path(relative_path)
        try:
            if not target_path.exists():
                return False
            if target_path.is_dir():
                raise StorageError(
                    error_code=ErrorCode.STORAGE_UNAVAILABLE,
                    message="Expected a file path to delete, but found a directory.",
                )
            target_path.unlink()
            return True
        except PathTraversalError:
            raise
        except StorageError:
            raise
        except OSError as exc:
            logger.error("Failed to delete file '%s': %s", relative_path, exc)
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Failed to delete file from storage.",
            ) from exc

    async def delete_file(self, relative_path: Union[str, Path]) -> bool:
        """Asynchronously delete a single file if it exists."""
        return await asyncio.to_thread(self.delete_file_sync, relative_path)

    def delete_directory_sync(self, relative_dir: Union[str, Path]) -> bool:
        """
        Synchronously delete a subdirectory (e.g., 'inputs/<job_id>') and all its contents.
        Refuses to delete the root subdirectories ('inputs', 'outputs', 'tmp') themselves.
        """
        posix_rel = self._validate_relative_path_Input(relative_dir)
        if len(posix_rel.parts) < 2 or posix_rel.parts[0] not in self.SUBDIRS:
            raise PathTraversalError(
                "Only nested job directories inside 'inputs/', 'outputs/', or 'tmp/' can be deleted."
            )

        target_dir = self.resolve_safe_path(posix_rel)
        try:
            if not target_dir.exists():
                return False
            shutil.rmtree(target_dir)
            return True
        except OSError as exc:
            logger.error("Failed to delete directory '%s': %s", posix_rel, exc)
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Failed to delete directory from storage.",
            ) from exc

    async def delete_directory(self, relative_dir: Union[str, Path]) -> bool:
        """Asynchronously delete a nested directory inside storage."""
        return await asyncio.to_thread(self.delete_directory_sync, relative_dir)

