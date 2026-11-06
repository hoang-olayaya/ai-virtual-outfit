from pathlib import Path
from unittest.mock import patch
import pytest

from app.core.errors import (
    ErrorCode,
    ImageNotFoundError,
    PathTraversalError,
    StorageError,
)
from app.storage.local_storage import LocalStorageAdapter


@pytest.mark.asyncio
async def test_save_read_and_delete_file_lifecycle(
    storage_adapter: LocalStorageAdapter,
    temp_storage_dir: Path,
):
    """Verify atomic write, read, and delete operations and clean 'tmp/' directory."""
    payload = b"\xff\xd8\xff\xe0sample-jpeg-binary"
    rel_path = "inputs/job-123/person.jpg"

    saved_rel = await storage_adapter.save_bytes(rel_path, payload)
    assert saved_rel == rel_path

    # Physical file must exist at expected path, and tmp/ must have no leftover .part files
    expected_file = temp_storage_dir / "inputs" / "job-123" / "person.jpg"
    assert expected_file.exists()
    assert list((temp_storage_dir / "tmp").glob("*.part")) == []

    # Read back bytes
    read_back = await storage_adapter.read_bytes(rel_path)
    assert read_back == payload

    # Delete file
    deleted = await storage_adapter.delete_file(rel_path)
    assert deleted is True
    assert not expected_file.exists()

    # Deleting again is idempotent and returns False
    deleted_again = await storage_adapter.delete_file(rel_path)
    assert deleted_again is False


@pytest.mark.parametrize(
    "malicious_path",
    [
        "",
        "   ",
        ".",
        "..",
        "../secret.txt",
        "inputs/../../etc/passwd",
        "inputs/job-1/../../../outside.jpg",
        "/etc/passwd",
        "\\Windows\\System32\\cmd.exe",
        "C:/Windows/win.ini",
        "D:\\secret\\key.pem",
        "inputs/job-1/file\x00.jpg",
    ],
)
def test_reject_path_traversal_attacks(
    storage_adapter: LocalStorageAdapter,
    malicious_path: str,
):
    """All path traversal, absolute paths, drive letters, and null-byte patterns must be blocked."""
    with pytest.raises(PathTraversalError) as exc_info:
        storage_adapter.resolve_safe_path(malicious_path)
    assert exc_info.value.error_code == ErrorCode.STORAGE_PATH_TRAVERSAL
    assert exc_info.value.status_code == 400


def test_reject_symlink_escape(
    storage_adapter: LocalStorageAdapter,
    temp_storage_dir: Path,
    tmp_path: Path,
):
    """Symlinks inside storage pointing outside the storage root must be rejected."""
    outside_file = tmp_path / "outside_secret.txt"
    outside_file.write_bytes(b"top-secret")

    symlink_path = temp_storage_dir / "inputs" / "evil_link.jpg"
    symlink_created = False
    try:
        symlink_path.symlink_to(outside_file)
        symlink_created = True
    except OSError:
        pass

    if symlink_created:
        with pytest.raises(PathTraversalError) as exc_info:
            storage_adapter.resolve_safe_path("inputs/evil_link.jpg")
        assert exc_info.value.error_code == ErrorCode.STORAGE_PATH_TRAVERSAL
    else:
        with patch.object(Path, "is_symlink", return_value=True):
            with pytest.raises(PathTraversalError) as exc_info:
                storage_adapter.resolve_safe_path("inputs/evil_link.jpg")
            assert exc_info.value.error_code == ErrorCode.STORAGE_PATH_TRAVERSAL


@pytest.mark.asyncio
async def test_read_nonexistent_file_raises_not_found(storage_adapter: LocalStorageAdapter):
    """Reading a missing image raises ImageNotFoundError (404)."""
    with pytest.raises(ImageNotFoundError) as exc_info:
        await storage_adapter.read_bytes("inputs/missing-job/person.jpg")

    assert exc_info.value.error_code == ErrorCode.IMAGE_NOT_FOUND
    assert exc_info.value.status_code == 404


def test_protect_root_subdirectories_from_directory_deletion(
    storage_adapter: LocalStorageAdapter,
):
    """Deleting top-level 'inputs', 'outputs', or 'tmp' directly is prohibited."""
    with pytest.raises(PathTraversalError):
        storage_adapter.delete_directory_sync("inputs")

    with pytest.raises(PathTraversalError):
        storage_adapter.delete_directory_sync("outputs")


@pytest.mark.asyncio
async def test_storage_unavailable_on_io_error(
    storage_adapter: LocalStorageAdapter,
    temp_storage_dir: Path,
):
    """Simulate disk write failure (OSError) and verify StorageError + temporary file cleanup."""
    with patch("os.replace", side_effect=OSError("Disk full or read-only filesystem")):
        with pytest.raises(StorageError) as exc_info:
            await storage_adapter.save_bytes("inputs/job-err/person.jpg", b"image-data")

        assert exc_info.value.error_code == ErrorCode.STORAGE_UNAVAILABLE
        assert exc_info.value.status_code == 503

    # Ensure temporary .part file was cleaned up despite os.replace failure
    assert list((temp_storage_dir / "tmp").glob("*.part")) == []

