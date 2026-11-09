# AI Virtual Outfit Preview — Backend Subsystem

FastAPI REST API, Celery Background Worker, PostgreSQL (SQLAlchemy + Alembic), Redis Broker, and Local Media Storage for the AI Virtual Outfit Preview Monorepo.

---

## 1. Architecture Overview

The backend subsystem is built as a multi-container asynchronous distributed system:

```text
                  +----------------------------------------------+
                  |               FastAPI App (API)              |
                  |  - REST endpoints (/api/v1/...)              |
                  |  - Upload validation (Magic bytes + Pillow)  |
                  |  - Idempotent request management             |
                  +-------+-------------------+------------------+
                          |                   |
               (Persist job metadata)   (Publish job_id)
                          |                   |
                          v                   v
+-----------------------------+     +----------------------------+
|     PostgreSQL Database     |     |     Redis Message Broker   |
|  - try_on_jobs table        |     |  - Celery default queue    |
|  - Alembic schema migrations|     +--------------+-------------+
+-----------------------------+                    |
                          ^                        | (Consume task)
                          |                        v
                          |         +----------------------------+
                          |         |        Celery Worker       |
                          +---------+  - Atomic job claiming     |
                          (Update   |  - FakeAI / fal.ai adapter |
                           status)  |  - Result persistence      |
                                    +--------------+-------------+
                                                   |
                                            (Read/Write files)
                                                   v
                                    +----------------------------+
                                    |     Shared File Storage    |
                                    |  - inputs/{id}/person.*    |
                                    |  - inputs/{id}/garment.*   |
                                    |  - outputs/{id}/result.jpg |
                                    |  - tmp/*.part              |
                                    +----------------------------+
```

### Key Principles
1. **Separation of Concerns:** Binary images are stored exclusively in shared volume storage; only filesystem paths and metadata are stored in PostgreSQL.
2. **Lightweight Queue Payloads:** The Redis broker transports only `job_id` strings, never raw binary image data.
3. **Strict Privacy by Design (NFR-07):** All media endpoints (`/image`, `/inputs/{kind}`) enforce `Cache-Control: private, no-cache, no-store, must-revalidate` to prevent CDN or browser caching of personal photos.
4. **Idempotency & Re-entry Protection:** Supports `Idempotency-Key` headers on job creation and atomic SQL updates on history saves (`COALESCE(saved_at, func.now())`).
5. **Dual-Layer Secret Scrubbing:** Console/traceback logging uses `SecretMaskingFilter` and database persistence scrubs secrets via `FailureHandler`.

---

## 2. API Endpoints Reference (`/api/v1`)

| Method | Endpoint | Description | Status Code |
| :--- | :--- | :--- | :--- |
| `GET` | `/health` | Application liveness probe | `200 OK` |
| `GET` | `/api/v1/health/ready` | Readiness probe (checks DB, Redis & Storage) | `200 OK` / `503` |
| `POST` | `/api/v1/try-ons` | Submit person & garment photos with optional `Idempotency-Key` | `202 Accepted` |
| `GET` | `/api/v1/try-ons/{id}` | Poll try-on job lifecycle status | `200 OK` / `404` |
| `GET` | `/api/v1/try-ons/{id}/image` | Stream output outfit image (`Cache-Control: no-store`) | `200 OK` / `404` |
| `GET` | `/api/v1/try-ons/{id}/inputs/{kind}` | Stream input photo (`kind = person \| garment`) | `200 OK` / `404` |
| `POST` | `/api/v1/try-ons/{id}/save` | Save succeeded try-on result to user history (idempotent) | `200 OK` / `400` / `404` |
| `GET` | `/api/v1/history` | Paginated list of saved try-ons (`limit`, `offset`) | `200 OK` |
| `GET` | `/api/v1/history/{id}` | Detailed history item with input/output URLs | `200 OK` / `404` |
| `DELETE` | `/api/v1/history/{id}` | Remove result from history and trigger storage cleanup | `204 No Content` / `404` |

Interactive Swagger documentation is available at `http://localhost:8000/docs`.

---

## 3. Local Development Setup

### 3.1 Prerequisites
- Python 3.11+
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Docker Compose v2+)

### 3.2 Virtual Environment Setup
```powershell
# Create and activate virtual environment
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# Install package dependencies with development tools
pip install -e ".[dev]"
```

### 3.3 Environment Variables
Copy `.env.example` to `.env` in the repository root:
```powershell
Copy-Item ..\.env.example ..\.env
```

Key environment configurations:
- `AI_PROVIDER`: `"fake"` (for zero-cost development/CI) or `"fal"` (for production inference).
- `DATABASE_URL`: `postgresql+asyncpg://postgres:postgres_password_dev@localhost:5432/virtual_outfit_db` (or test DB).
- `REDIS_URL`: `redis://localhost:6379/0`.
- `STORAGE_LOCAL_PATH`: Directory path for image storage.

---

## 4. Running Infrastructure with Docker Compose

Start the full 4-container stack from the repository root:
```powershell
docker compose -f infrastructure/compose.yaml up -d --build
```

Container services:
- `virtual_outfit_postgres` (Port 5432)
- `virtual_outfit_redis` (Port 6379)
- `virtual_outfit_api` (Port 8000)
- `virtual_outfit_worker` (Celery background worker)

Inspect container status and health:
```powershell
docker compose -f infrastructure/compose.yaml ps
```

---

## 5. Database Migrations (Alembic)

Database schema migrations are managed via Alembic:
```powershell
# Upgrade database to head revision
alembic upgrade head

# Downgrade one revision
alembic downgrade -1

# Generate new migration after editing SQLAlchemy models
alembic revision --autogenerate -m "describe_changes"
```

---

## 6. Automated Testing

The backend test suite is partitioned into 3 isolated testing tiers:
- **Unit Tests (`tests/unit`):** 82 isolated in-memory tests (mocking external dependencies, fast execution).
- **Contract Tests (`tests/contract`):** 3 tests validating OpenAPI schema parity and error contract formats.
- **Integration Tests (`tests/integration`):** 50 tests executing real PostgreSQL transactions, Alembic migrations lifecycle, repository atomic locks, and Worker pipelines.

### Running Tests Locally (against isolated test database)
```powershell
# Ensure test DB exists
docker compose -f infrastructure/compose.yaml exec postgres psql -U postgres -c "CREATE DATABASE virtual_outfit_test_db;"

# Run full test suite (135 tests)
$env:DATABASE_URL="postgresql+asyncpg://postgres:postgres_password_dev@localhost:5432/virtual_outfit_test_db"
pytest tests/unit tests/integration tests/contract -v
Remove-Item Env:\DATABASE_URL
```

### Running Tests Inside API Container
```powershell
docker compose -f infrastructure/compose.yaml run --rm -e DATABASE_URL=postgresql+asyncpg://postgres:postgres_password_dev@postgres:5432/virtual_outfit_test_db api pytest tests/unit tests/integration tests/contract -v
```

### Opt-in Live fal.ai Smoke Test
```powershell
$env:RUN_FAL_SMOKE="1"
pytest tests/external/test_fal_smoke.py -v -s
Remove-Item Env:\RUN_FAL_SMOKE
```

---

## 7. Repeatable End-to-End Smoke Test

Run the automated 10-step E2E smoke test script against the running Docker stack:
```powershell
powershell -ExecutionPolicy Bypass -File ..\scripts\smoke_e2e_backend.ps1
```

This validates:
1. Health & readiness checks
2. Job creation (202 Accepted)
3. Idempotent re-submission
4. Polling until `succeeded`
5. Media download & strict `Cache-Control` header check
6. Input media compare endpoint availability
7. Save to history
8. Save idempotency
9. History listing and detail
10. History deletion (204 No Content & subsequent 404)

---

## 8. Maintenance CLI Tools

Two self-healing maintenance tools are provided under `app.maintenance`:

### 8.1 Reconcile Stale Jobs
Detects jobs stuck in `processing` due to worker crashes or stuck in `queued` due to broker issues, automatically requeuing or failing them after timeouts:
```powershell
python -m app.maintenance.reconcile_jobs
```

### 8.2 Clean Storage & Orphan Directories
Removes stale `.part` temporary files (> 1 hour TTL) and identifies orphan storage directories (directories with no corresponding PostgreSQL record, protected by a 15-minute Grace Period):
```powershell
python -m app.maintenance.cleanup_files
```
