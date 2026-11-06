"""create try_on_jobs table

Revision ID: 0001
Revises:
Create Date: 2026-10-30 21:55:00.000000

"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "try_on_jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, nullable=False),
        sa.Column("idempotency_key", sa.String(length=255), nullable=True),
        sa.Column(
            "status",
            sa.String(length=32),
            nullable=False,
            server_default="queued",
        ),
        sa.Column("person_image_path", sa.String(length=512), nullable=False),
        sa.Column("garment_image_path", sa.String(length=512), nullable=False),
        sa.Column("result_image_path", sa.String(length=512), nullable=True),
        sa.Column("provider_name", sa.String(length=64), nullable=True),
        sa.Column("provider_request_id", sa.String(length=255), nullable=True),
        sa.Column("error_code", sa.String(length=64), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("retry_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_saved", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("saved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
    )

    op.create_index(
        "ix_try_on_jobs_idempotency_key",
        "try_on_jobs",
        ["idempotency_key"],
        unique=True,
    )
    op.create_index("ix_try_on_jobs_status", "try_on_jobs", ["status"], unique=False)
    op.create_index(
        "ix_try_on_jobs_provider_request_id",
        "try_on_jobs",
        ["provider_request_id"],
        unique=False,
    )
    op.create_index("ix_try_on_jobs_is_saved", "try_on_jobs", ["is_saved"], unique=False)
    op.create_index("ix_try_on_jobs_created_at", "try_on_jobs", ["created_at"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_try_on_jobs_created_at", table_name="try_on_jobs")
    op.drop_index("ix_try_on_jobs_is_saved", table_name="try_on_jobs")
    op.drop_index("ix_try_on_jobs_provider_request_id", table_name="try_on_jobs")
    op.drop_index("ix_try_on_jobs_status", table_name="try_on_jobs")
    op.drop_index("ix_try_on_jobs_idempotency_key", table_name="try_on_jobs")
    op.drop_table("try_on_jobs")
