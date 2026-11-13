"""
Standalone local mock backend server for Windows desktop demonstration.
Implements the exact FastAPI contract for AI Virtual Outfit Preview.
Runs directly with Python & Pillow without needing Docker, PostgreSQL, or Redis.
"""

import io
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, List

import uvicorn
from fastapi import FastAPI, UploadFile, File, Header, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from PIL import Image, ImageOps

app = FastAPI(title="AI Virtual Outfit Preview - Standalone Local Demo")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

DATA_DIR = Path(__file__).resolve().parent / "local_demo_storage"
DATA_DIR.mkdir(parents=True, exist_ok=True)

# In-memory storage for jobs & idempotency keys
JOBS: Dict[str, Dict[str, Any]] = {}
IDEMPOTENCY_MAP: Dict[str, str] = {}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "app": "AI Virtual Outfit Preview",
        "version": "0.1.0",
        "environment": "standalone-local-demo",
    }


@app.get("/api/v1/health/ready")
def readiness():
    return {
        "status": "ready",
        "checks": {
            "database": "standalone-in-memory",
            "redis": "standalone-in-memory",
            "storage": f"writable ({DATA_DIR})",
        },
    }


@app.post("/api/v1/try-ons", status_code=status.HTTP_202_ACCEPTED)
async def create_try_on(
    person_image: UploadFile = File(...),
    garment_image: UploadFile = File(...),
    idempotency_key: str = Header(None, alias="Idempotency-Key"),
):
    if idempotency_key and idempotency_key in IDEMPOTENCY_MAP:
        existing_id = IDEMPOTENCY_MAP[idempotency_key]
        return JOBS[existing_id]

    job_id = str(uuid.uuid4())
    job_dir = DATA_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)

    person_bytes = await person_image.read()
    garment_bytes = await garment_image.read()

    (job_dir / "person.png").write_bytes(person_bytes)
    (job_dir / "garment.png").write_bytes(garment_bytes)

    # Generate composite image using Pillow (Fake AI Try-On)
    try:
        p_img = Image.open(io.BytesIO(person_bytes)).convert("RGBA")
        g_img = Image.open(io.BytesIO(garment_bytes)).convert("RGBA")

        p_img = ImageOps.exif_transpose(p_img)
        g_img = ImageOps.exif_transpose(g_img)

        # Scale garment to fit comfortably on the torso
        pw, ph = p_img.size
        target_gw = int(pw * 0.55)
        scale = target_gw / max(1, g_img.width)
        target_gh = int(g_img.height * scale)
        g_resized = g_img.resize((target_gw, target_gh), Image.Resampling.LANCZOS)

        pos_x = (pw - target_gw) // 2
        pos_y = int(ph * 0.28)

        composite = p_img.copy()
        composite.paste(g_resized, (pos_x, pos_y), g_resized)

        out_io = io.BytesIO()
        composite.convert("RGB").save(out_io, format="JPEG", quality=90)
        (job_dir / "result.jpg").write_bytes(out_io.getvalue())
    except Exception:
        # Fallback if image blending encounters issues
        (job_dir / "result.jpg").write_bytes(person_bytes)

    job_record = {
        "job_id": job_id,
        "status": "succeeded",
        "result_image_url": f"/api/v1/try-ons/{job_id}/image",
        "person_image_url": f"/api/v1/try-ons/{job_id}/inputs/person",
        "garment_image_url": f"/api/v1/try-ons/{job_id}/inputs/garment",
        "error": None,
        "is_saved": False,
        "saved_at": None,
        "created_at": now_iso(),
        "updated_at": now_iso(),
        "completed_at": now_iso(),
    }

    JOBS[job_id] = job_record
    if idempotency_key:
        IDEMPOTENCY_MAP[idempotency_key] = job_id

    return job_record


@app.get("/api/v1/try-ons/{job_id}")
def get_job(job_id: str):
    if job_id not in JOBS:
        raise HTTPException(status_code=404, detail="Job not found")
    return JOBS[job_id]


@app.get("/api/v1/try-ons/{job_id}/image")
def get_result_image(job_id: str):
    path = DATA_DIR / job_id / "result.jpg"
    if not path.exists():
        raise HTTPException(status_code=404, detail="Result image not found")
    return Response(
        content=path.read_bytes(),
        media_type="image/jpeg",
        headers={"Cache-Control": "private, no-cache, no-store, must-revalidate"},
    )


@app.get("/api/v1/try-ons/{job_id}/inputs/{kind}")
def get_input_image(job_id: str, kind: str):
    filename = "person.png" if kind == "person" else "garment.png"
    path = DATA_DIR / job_id / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="Input image not found")
    return Response(
        content=path.read_bytes(),
        media_type="image/png",
        headers={"Cache-Control": "private, no-cache, no-store, must-revalidate"},
    )


@app.post("/api/v1/try-ons/{job_id}/save")
def save_job(job_id: str):
    if job_id not in JOBS:
        raise HTTPException(status_code=404, detail="Job not found")
    job = JOBS[job_id]
    job["is_saved"] = True
    job["saved_at"] = job.get("saved_at") or now_iso()
    return job


@app.get("/api/v1/history")
def get_history(limit: int = 20, offset: int = 0):
    saved_jobs = [j for j in JOBS.values() if j.get("is_saved")]
    total = len(saved_jobs)
    items = saved_jobs[offset : offset + limit]
    return {
        "items": items,
        "total": total,
        "limit": limit,
        "offset": offset,
    }


@app.get("/api/v1/history/{job_id}")
def get_history_detail(job_id: str):
    if job_id not in JOBS or not JOBS[job_id].get("is_saved"):
        raise HTTPException(status_code=404, detail="Saved job not found")
    return JOBS[job_id]


@app.delete("/api/v1/history/{job_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_history_item(job_id: str):
    if job_id not in JOBS or not JOBS[job_id].get("is_saved"):
        raise HTTPException(status_code=404, detail="Saved job not found")
    JOBS.pop(job_id, None)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


if __name__ == "__main__":
    uvicorn.run("mock_server:app", host="127.0.0.1", port=8000, reload=False)

