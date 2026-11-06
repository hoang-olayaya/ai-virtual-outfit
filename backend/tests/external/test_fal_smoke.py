import io
import os
import uuid
import pytest
from PIL import Image, ImageDraw
from app.core.config import settings
from app.integrations.fal_adapter import FalAdapter
from app.services.upload_validator import UploadValidator


def _build_smoke_person_image_bytes() -> bytes:
    """Create a clean 512x768 RGB person silhouette sample image for smoke testing."""
    img = Image.new("RGB", (512, 768), color=(240, 240, 245))
    draw = ImageDraw.Draw(img)
    # Head
    draw.ellipse((206, 80, 306, 180), fill=(210, 170, 140))
    # Torso / shirt area
    draw.rectangle((166, 190, 346, 460), fill=(60, 100, 170))
    # Legs
    draw.rectangle((176, 460, 246, 720), fill=(40, 50, 70))
    draw.rectangle((266, 460, 336, 720), fill=(40, 50, 70))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=92)
    return buf.getvalue()


def _build_smoke_garment_image_bytes() -> bytes:
    """Create a clean 512x512 RGB garment flat-lay sample image for smoke testing."""
    img = Image.new("RGB", (512, 512), color=(255, 255, 255))
    draw = ImageDraw.Draw(img)
    # Shirt body & sleeves
    draw.rectangle((140, 100, 372, 420), fill=(190, 50, 60))
    draw.polygon([(140, 100), (70, 200), (110, 240), (140, 180)], fill=(190, 50, 60))
    draw.polygon([(372, 100), (442, 200), (402, 240), (372, 180)], fill=(190, 50, 60))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=92)
    return buf.getvalue()


@pytest.mark.skipif(
    os.getenv("RUN_FAL_SMOKE") != "1" or not (settings.FAL_KEY or "").strip(),
    reason=(
        "Opt-in paid fal.ai smoke test. Set RUN_FAL_SMOKE=1 and configure a valid "
        "FAL_KEY in environment/.env to execute a single live fal.ai request."
    ),
)
def test_fal_adapter_live_paid_smoke_single_request():
    """
    Manual opt-in paid smoke test (Phase B05):
    Executes exactly ONE live request against fal.ai (`settings.FAL_MODEL_ID`),
    validates that the returned image bytes decode cleanly via UploadValidator,
    and prints provider tracking metadata without exposing `FAL_KEY`.
    """
    adapter = FalAdapter()
    validator = UploadValidator()
    job_id = uuid.uuid4()

    person_bytes = _build_smoke_person_image_bytes()
    garment_bytes = _build_smoke_garment_image_bytes()

    result = adapter.generate_try_on(
        job_id=job_id,
        person_image_bytes=person_bytes,
        garment_image_bytes=garment_bytes,
    )

    assert result.provider_name == "fal"
    assert bool(result.provider_request_id.strip())
    assert len(result.image_bytes) > 0

    validated = validator.validate_bytes_sync(
        result.image_bytes,
        field_name="smoke_result",
    )
    assert validated.width >= settings.UPLOAD_MIN_DIMENSION_PX
    assert validated.height >= settings.UPLOAD_MIN_DIMENSION_PX
    print(
        f"\n[FAL SMOKE PASS] model={adapter.model_id} "
        f"request_id={result.provider_request_id} "
        f"format={validated.format} size={validated.width}x{validated.height} "
        f"bytes={len(result.image_bytes)}"
    )


@pytest.mark.asyncio
@pytest.mark.skipif(
    os.getenv("RUN_FAL_SMOKE") != "1" or not (settings.FAL_KEY or "").strip(),
    reason=(
        "Opt-in paid fal.ai smoke test. Set RUN_FAL_SMOKE=1 and configure a valid "
        "FAL_KEY in environment/.env to execute a single live fal.ai request."
    ),
)
async def test_real_worker_pipeline_live_smoke(
    async_api_client,
    api_job_repository,
    image_service,
    temp_storage_dir,
):
    """
    Manual opt-in paid smoke test for full Worker Pipeline (Phase B06):
    POST job -> execute_try_on_job with live FalAdapter -> store result -> verify GET /image.
    """
    person_bytes = _build_smoke_person_image_bytes()
    garment_bytes = _build_smoke_garment_image_bytes()

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.jpg", garment_bytes, "image/jpeg"),
        },
    )
    assert post_resp.status_code == 202
    job_id = uuid.UUID(post_resp.json()["job_id"])

    live_adapter = FalAdapter()
    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=live_adapter,
    )

    assert outcome.status == "succeeded"
    assert outcome.provider_name == "fal"
    assert bool(outcome.provider_request_id)

    media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert media_resp.status_code == 200
    assert media_resp.headers["content-type"] in ("image/jpeg", "image/png", "image/webp")
    assert len(media_resp.content) > 0
    print(
        f"\n[PIPELINE FAL SMOKE PASS] job_id={job_id} "
        f"request_id={outcome.provider_request_id} result={outcome.result_image_path}"
    )

