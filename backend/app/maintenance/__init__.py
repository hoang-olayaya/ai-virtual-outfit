"""Maintenance subsystem for AI Virtual Outfit Preview backend."""
from typing import Any

__all__ = [
    "CleanupReport",
    "cleanup_storage_files",
    "ReconcileReport",
    "reconcile_stale_jobs",
]


def __getattr__(name: str) -> Any:
    if name in ("CleanupReport", "cleanup_storage_files"):
        from app.maintenance import cleanup_files
        return getattr(cleanup_files, name)
    if name in ("ReconcileReport", "reconcile_stale_jobs"):
        from app.maintenance import reconcile_jobs
        return getattr(reconcile_jobs, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
