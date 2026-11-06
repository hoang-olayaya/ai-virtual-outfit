import pytest
from sqlalchemy import inspect
from app.db.session import engine
from tests.conftest import is_postgres_available


@pytest.mark.asyncio
async def test_alembic_migrations_lifecycle():
    """Verify that Alembic can successfully upgrade to head, downgrade to base, and re-upgrade."""
    if not await is_postgres_available():
        pytest.skip("PostgreSQL database is not reachable; skipping Alembic migration lifecycle test.")

    try:
        from alembic import command
        from alembic.config import Config
    except ImportError:
        pytest.skip("Alembic package is not installed in this Python environment.")

    alembic_cfg = Config("alembic.ini")

    # 1. Upgrade to latest migration head
    command.upgrade(alembic_cfg, "head")

    # 2. Inspect table schema and verify all required columns and constraints
    async with engine.connect() as conn:
        def check_tables(sync_conn):
            inspector = inspect(sync_conn)
            tables = inspector.get_table_names()
            assert "try_on_jobs" in tables, "Table 'try_on_jobs' must exist after upgrade"

            columns = {col["name"]: col for col in inspector.get_columns("try_on_jobs")}
            expected_columns = [
                "id",
                "idempotency_key",
                "status",
                "person_image_path",
                "garment_image_path",
                "result_image_path",
                "provider_name",
                "provider_request_id",
                "error_code",
                "error_message",
                "retry_count",
                "is_saved",
                "saved_at",
                "created_at",
                "updated_at",
                "completed_at",
            ]
            for col_name in expected_columns:
                assert col_name in columns, f"Column '{col_name}' missing from try_on_jobs table"

            # Check indexes
            indexes = {idx["name"]: idx for idx in inspector.get_indexes("try_on_jobs")}
            assert "ix_try_on_jobs_idempotency_key" in indexes
            assert indexes["ix_try_on_jobs_idempotency_key"]["unique"] is True
            assert "ix_try_on_jobs_status" in indexes
            assert "ix_try_on_jobs_provider_request_id" in indexes
            assert "ix_try_on_jobs_is_saved" in indexes

        await conn.run_sync(check_tables)

    # 3. Downgrade to base
    command.downgrade(alembic_cfg, "base")

    async with engine.connect() as conn:
        def check_downgrade(sync_conn):
            inspector = inspect(sync_conn)
            tables = inspector.get_table_names()
            assert "try_on_jobs" not in tables, "Table 'try_on_jobs' must be dropped after downgrade"

        await conn.run_sync(check_downgrade)

    # 4. Re-upgrade to leave database in clean ready state
    command.upgrade(alembic_cfg, "head")
