import argparse
import asyncio
from dataclasses import dataclass, field
import sys
import time
from typing import List, Optional, Set
import uuid

from app.core.config import settings
from app.core.logging import logger, setup_logging
from app.db.session import create_worker_session
from app.repositories.job_repository import JobRepository
from app.storage.local_storage import LocalStorageAdapter


@dataclass
class CleanupReport:
    """Structured summary of storage cleanup and orphan directory sweep."""

    temp_files_deleted: int = 0
    orphan_dirs_scanned: int = 0
    orphan_dirs_deleted: int = 0
    preserved_by_grace_period: int = 0
    errors: List[str] = field(default_factory=list)

    @property
    def total_cleaned(self) -> int:
        return self.temp_files_deleted + self.orphan_dirs_deleted


async def cleanup_storage_files(
    storage: LocalStorageAdapter,
    job_repository: JobRepository,
    grace_period_seconds: Optional[int] = None,
    temp_ttl_seconds: Optional[int] = None,
    dry_run: bool = False,
) -> CleanupReport:
    """
    Perform deep cleanup of shared storage volume:
    1. Scan 'tmp/' and purge stale '.part' files older than temp_ttl_seconds.
    2. Scan 'inputs/' and 'outputs/' subdirectories:
       - Preserve any directory whose creation/modification is within grace_period_seconds
         (protects active, in-flight multipart uploads).
       - Cross-reference with PostgreSQL: delete any directory whose UUID does not exist
         in the database (reclaims orphan storage after failed uploads or uncompleted deletions).
    """
    grace_period = (
        grace_period_seconds
        if grace_period_seconds is not None
        else settings.ORPHAN_DIR_GRACE_PERIOD_SECONDS
    )
    temp_ttl = (
        temp_ttl_seconds
        if temp_ttl_seconds is not None
        else settings.TMP_FILE_TTL_SECONDS
    )

    report = CleanupReport()
    now = time.time()

    # 1. Clean up temporary files in 'tmp/'
    try:
        if dry_run:
            resolved_root = storage.ensure_base_dirs()
            tmp_dir = resolved_root / "tmp"
            part_count = 0
            if tmp_dir.exists():
                for entry in tmp_dir.iterdir():
                    if entry.is_file() and entry.name.endswith(".part"):
                        if (now - entry.stat().st_mtime) >= temp_ttl:
                            part_count += 1
            report.temp_files_deleted = part_count
            logger.info("[Dry Run] Would delete %d expired .part files from tmp/", part_count)
        else:
            deleted_tmp = await storage.cleanup_temp_files(temp_ttl)
            report.temp_files_deleted = deleted_tmp
            logger.info("Purged %d expired .part files from tmp/", deleted_tmp)
    except Exception as exc:
        err_msg = f"Failed during tmp file cleanup: {exc}"
        logger.error(err_msg)
        report.errors.append(err_msg)

    # 2. Sweep orphan directories in 'inputs/' and 'outputs/'
    for kind in ("inputs", "outputs"):
        try:
            subdirs = await storage.list_subdirectories(kind)
        except Exception as exc:
            err_msg = f"Failed listing directories in '{kind}': {exc}"
            logger.error(err_msg)
            report.errors.append(err_msg)
            continue

        candidates: List[tuple[str, uuid.UUID]] = []
        for dirname in subdirs:
            try:
                job_uuid = uuid.UUID(dirname)
            except (ValueError, TypeError):
                logger.warning("Skipping non-UUID folder in '%s': %s", kind, dirname)
                continue

            # Check modification time against grace period
            rel_dir = f"{kind}/{dirname}"
            try:
                mtime = storage.get_directory_mtime_sync(rel_dir)
                age = now - mtime
                if age < grace_period:
                    report.preserved_by_grace_period += 1
                    logger.debug(
                        "Preserving recently active directory '%s' (age=%.1fs < grace=%.1fs)",
                        rel_dir,
                        age,
                        grace_period,
                    )
                    continue
            except Exception as stat_err:
                logger.warning("Could not stat directory '%s': %s", rel_dir, stat_err)
                continue

            candidates.append((dirname, job_uuid))

        if not candidates:
            continue

        candidate_uuids = [c[1] for c in candidates]
        try:
            existing_job_ids: Set[uuid.UUID] = await job_repository.get_existing_job_ids(
                candidate_uuids
            )
        except Exception as db_err:
            err_msg = f"Failed querying existing job IDs for '{kind}': {db_err}"
            logger.error(err_msg)
            report.errors.append(err_msg)
            continue

        for dirname, job_uuid in candidates:
            if job_uuid not in existing_job_ids:
                report.orphan_dirs_scanned += 1
                rel_path = f"{kind}/{dirname}"
                if dry_run:
                    logger.info("[Dry Run] Would purge orphan directory: %s", rel_path)
                else:
                    try:
                        deleted = await storage.delete_directory(rel_path)
                        if deleted:
                            report.orphan_dirs_deleted += 1
                            logger.warning(
                                "Volume Sweeper successfully purged orphan directory: %s",
                                rel_path,
                            )
                    except Exception as del_err:
                        err_msg = f"Failed deleting orphan directory '{rel_path}': {del_err}"
                        logger.error(err_msg)
                        report.errors.append(err_msg)

    logger.info(
        "Storage cleanup completed: temp_files_deleted=%d, orphan_dirs_scanned=%d, "
        "orphan_dirs_deleted=%d, preserved_by_grace=%d, errors=%d",
        report.temp_files_deleted,
        report.orphan_dirs_scanned,
        report.orphan_dirs_deleted,
        report.preserved_by_grace_period,
        len(report.errors),
    )
    return report


async def _run_cli(dry_run: bool = False) -> int:
    setup_logging()
    logger.info("Starting storage cleanup CLI (dry_run=%s)...", dry_run)
    storage = LocalStorageAdapter()
    async with create_worker_session() as session:
        repo = JobRepository(session)
        report = await cleanup_storage_files(
            storage=storage,
            job_repository=repo,
            dry_run=dry_run,
        )
        logger.info("Storage cleanup CLI finished: %s", report)
        return 1 if report.errors else 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Volume Sweeper and temporary storage cleaner.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Scan and report without deleting files or directories.",
    )
    args = parser.parse_args()
    code = asyncio.run(_run_cli(dry_run=args.dry_run))
    sys.exit(code)


if __name__ == "__main__":
    main()

