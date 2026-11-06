import pytest
from PIL import Image

from app.core.errors import ErrorCode, ImageValidationError
from app.services.upload_validator import UploadValidator
from tests.conftest import create_synthetic_image_bytes, make_upload_file


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "fmt,expected_mime,expected_ext",
    [
        ("JPEG", "image/jpeg", ".jpg"),
        ("PNG", "image/png", ".png"),
        ("WEBP", "image/webp", ".webp"),
    ],
)
async def test_validate_supported_image_formats(
    upload_validator: UploadValidator,
    fmt: str,
    expected_mime: str,
    expected_ext: str,
):
    """Valid JPEG, PNG, and WEBP images should pass validation with accurate metadata."""
    raw_bytes = create_synthetic_image_bytes(fmt=fmt, size=(300, 400))
    upload = make_upload_file(raw_bytes, filename=f"test_input{expected_ext}")

    validated = await upload_validator.validate_upload_file(upload, field_name="person_image")

    assert validated.field_name == "person_image"
    assert validated.format == fmt
    assert validated.mime_type == expected_mime
    assert validated.extension == expected_ext
    assert validated.width == 300
    assert validated.height == 400
    assert validated.size_bytes == len(raw_bytes)
    assert validated.content == raw_bytes


@pytest.mark.asyncio
async def test_validate_try_on_inputs_success(upload_validator: UploadValidator):
    """Both person_image and garment_image pass when valid."""
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 512))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))

    person_file = make_upload_file(person_bytes, filename="person.jpg")
    garment_file = make_upload_file(garment_bytes, filename="garment.png")

    v_person, v_garment = await upload_validator.validate_try_on_inputs(
        person_file, garment_file
    )

    assert v_person.field_name == "person_image"
    assert v_person.extension == ".jpg"
    assert v_garment.field_name == "garment_image"
    assert v_garment.extension == ".png"


@pytest.mark.asyncio
async def test_reject_missing_input_files(upload_validator: UploadValidator):
    """Scenario T02: Missing person_image or garment_image raises MISSING_INPUT_IMAGE."""
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG")
    valid_upload = make_upload_file(valid_bytes, filename="valid.jpg")

    with pytest.raises(ImageValidationError) as exc_info:
        await upload_validator.validate_try_on_inputs(None, valid_upload)
    assert exc_info.value.error_code == ErrorCode.MISSING_INPUT_IMAGE
    assert exc_info.value.status_code == 400
    assert exc_info.value.details["field"] == "person_image"

    with pytest.raises(ImageValidationError) as exc_info2:
        await upload_validator.validate_try_on_inputs(valid_upload, None)
    assert exc_info2.value.error_code == ErrorCode.MISSING_INPUT_IMAGE
    assert exc_info2.value.details["field"] == "garment_image"


@pytest.mark.asyncio
async def test_reject_empty_file_and_blank_filename(upload_validator: UploadValidator):
    """Zero-byte file or empty filename must be rejected with MISSING_INPUT_IMAGE."""
    empty_upload = make_upload_file(b"", filename="empty.jpg")
    with pytest.raises(ImageValidationError) as exc_info:
        await upload_validator.validate_upload_file(empty_upload, field_name="person_image")
    assert exc_info.value.error_code == ErrorCode.MISSING_INPUT_IMAGE

    blank_name_upload = make_upload_file(b"123", filename="   ")
    with pytest.raises(ImageValidationError) as exc_info2:
        await upload_validator.validate_upload_file(blank_name_upload, field_name="garment_image")
    assert exc_info2.value.error_code == ErrorCode.MISSING_INPUT_IMAGE


@pytest.mark.asyncio
async def test_reject_spoofed_extension_and_mime_type(upload_validator: UploadValidator):
    """
    Scenario T03: Non-image payload or unsupported image format disguised with .jpg extension
    and image/jpeg Content-Type must be rejected with UNSUPPORTED_MEDIA_TYPE.
    """
    fake_jpg = make_upload_file(
        b"This is plain text pretending to be a JPEG file.",
        filename="spoofed.jpg",
        content_type="image/jpeg",
    )
    with pytest.raises(ImageValidationError) as exc_info:
        await upload_validator.validate_upload_file(fake_jpg, field_name="person_image")
    assert exc_info.value.error_code == ErrorCode.UNSUPPORTED_MEDIA_TYPE
    assert exc_info.value.status_code == 415

    # Valid BMP image renamed to .png must also be rejected
    bmp_bytes = create_synthetic_image_bytes(fmt="BMP", size=(128, 128))
    spoofed_bmp = make_upload_file(
        bmp_bytes,
        filename="disguised.png",
        content_type="image/png",
    )
    with pytest.raises(ImageValidationError) as exc_info2:
        await upload_validator.validate_upload_file(spoofed_bmp, field_name="garment_image")
    assert exc_info2.value.error_code == ErrorCode.UNSUPPORTED_MEDIA_TYPE
    assert exc_info2.value.status_code == 415


@pytest.mark.asyncio
async def test_reject_oversized_file(
    
):
    """Scenario T04: File exceeding max_file_size_bytes raises FILE_TOO_LARGE (413)."""
    small_limit_validator = UploadValidator(max_file_size_bytes=1024)  # 1 KB limit
    large_image = create_synthetic_image_bytes(fmt="PNG", size=(512, 512))
    assert len(large_image) > 1024

    upload = make_upload_file(large_image, filename="too_big.png")
    with pytest.raises(ImageValidationError) as exc_info:
        await small_limit_validator.validate_upload_file(upload, field_name="person_image")

    assert exc_info.value.error_code == ErrorCode.FILE_TOO_LARGE
    assert exc_info.value.status_code == 413


@pytest.mark.asyncio
async def test_reject_corrupted_or_truncated_image(upload_validator: UploadValidator):
    """Truncated or corrupted image stream must be caught by full decode verification."""
    valid_png = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    # Cut off the second half of the PNG data stream
    truncated_png = valid_png[: len(valid_png) // 2]

    upload = make_upload_file(truncated_png, filename="broken.png", content_type="image/png")
    with pytest.raises(ImageValidationError) as exc_info:
        await upload_validator.validate_upload_file(upload, field_name="person_image")

    assert exc_info.value.error_code == ErrorCode.CORRUPTED_IMAGE
    assert exc_info.value.status_code == 400


@pytest.mark.asyncio
async def test_reject_decompression_bomb():
    """Images exceeding max_pixels or triggering Pillow DecompressionBomb protection are rejected."""
    strict_pixel_validator = UploadValidator(
        min_dimension_px=64,
        max_dimension_px=4096,
        max_pixels=100_000,  # 100k pixels max (e.g. > 316x316 is blocked)
    )
    img_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(400, 400))  # 160,000 pixels
    upload = make_upload_file(img_bytes, filename="bomb.jpg")

    with pytest.raises(ImageValidationError) as exc_info:
        await strict_pixel_validator.validate_upload_file(upload, field_name="person_image")

    assert exc_info.value.error_code == ErrorCode.CORRUPTED_IMAGE

    # Also test Pillow's built-in DecompressionBombWarning escalation
    original_max = Image.MAX_IMAGE_PIXELS
    try:
        Image.MAX_IMAGE_PIXELS = 10_000
        validator = UploadValidator()
        with pytest.raises(ImageValidationError) as bomb_exc:
            await validator.validate_upload_file(
                make_upload_file(img_bytes, filename="pillow_bomb.jpg"),
                field_name="person_image",
            )
        assert bomb_exc.value.error_code == ErrorCode.CORRUPTED_IMAGE
    finally:
        Image.MAX_IMAGE_PIXELS = original_max


@pytest.mark.asyncio
async def test_reject_invalid_image_dimensions():
    """Images smaller than min_dimension_px or larger than max_dimension_px are rejected."""
    validator = UploadValidator(
        min_dimension_px=64,
        max_dimension_px=512,
        max_pixels=1_000_000,
    )

    # Too small (32x32)
    tiny_bytes = create_synthetic_image_bytes(fmt="PNG", size=(32, 32))
    with pytest.raises(ImageValidationError) as small_exc:
        await validator.validate_upload_file(
            make_upload_file(tiny_bytes, filename="tiny.png"),
            field_name="person_image",
        )
    assert small_exc.value.error_code == ErrorCode.INVALID_IMAGE_DIMENSIONS

    # Too wide (600x200 > 512 max)
    wide_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(600, 200))
    with pytest.raises(ImageValidationError) as wide_exc:
        await validator.validate_upload_file(
            make_upload_file(wide_bytes, filename="wide.jpg"),
            field_name="garment_image",
        )
    assert wide_exc.value.error_code == ErrorCode.INVALID_IMAGE_DIMENSIONS

