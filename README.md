# AI Virtual Outfit Preview

Ứng dụng di động và nền tảng backend cho phép xem trước hình ảnh bản thân khi mặc một trang phục bất kỳ, sử dụng AI sinh hình ảnh.

## Kiến trúc hệ thống

Dự án được tổ chức theo mô hình Monorepo:
- `backend/`: FastAPI REST API và Celery Worker (xử lý tác vụ nền).
- `infrastructure/`: Docker Compose và cấu hình môi trường hạ tầng.
- `docs/`: Tài liệu kiến trúc và hướng dẫn vận hành.
- `mobile/`: Ứng dụng di động Flutter (sẽ triển khai từ Phase F01).

---

## Hướng dẫn khởi động nhanh (Local Development)

### 1. Yêu cầu môi trường
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Docker Engine >= 24, Docker Compose v2+)

### 2. Thiết lập biến môi trường
Sao chép file cấu hình mẫu `.env.example` thành `.env`:
```powershell
Copy-Item .env.example .env
```

### 3. Khởi động các dịch vụ
Sử dụng Docker Compose để khởi chạy cụm 4 containers:
```powershell
docker compose --env-file .env -f infrastructure/compose.yaml up -d --build
```

Cụm container bao gồm:
- `virtual_outfit_api`: FastAPI server tại `http://localhost:8000` (Swagger UI: `http://localhost:8000/docs`)
- `virtual_outfit_worker`: Celery Worker tiếp nhận tác vụ qua Redis
- `virtual_outfit_postgres`: Cơ sở dữ liệu PostgreSQL (port 5432)
- `virtual_outfit_redis`: Broker / cache Redis (port 6379)

### 4. Kiểm tra sức khỏe hệ thống (Health Check)
```powershell
# Liveness probe
curl http://localhost:8000/health

# Readiness probe
curl http://localhost:8000/api/v1/health/ready
```

### 5. Cấu hình Lưu trữ & Kiểm tra Ảnh (Image Storage - B02)
Ảnh đầu vào và ảnh kết quả được lưu trên Docker Volume dùng chung (`STORAGE_LOCAL_PATH`, mặc định `/app/data_storage`) với cấu trúc:
- `inputs/{job_id}/person.<ext>` và `inputs/{job_id}/garment.<ext>`: Ảnh đầu vào đã xác thực.
- `outputs/{job_id}/result.<ext>`: Ảnh kết quả sinh từ AI.
- `tmp/`: Thư mục chứa file tạm `.part` phục vụ cơ chế ghi nguyên tử (atomic write).

Các giới hạn kiểm tra ảnh mặc định (cấu hình qua `.env`):
- Định dạng cho phép: `JPEG`, `PNG`, `WEBP` (kiểm tra bằng magic bytes & Pillow full decode).
- Kích thước file tối đa: `10 MB` (`UPLOAD_MAX_FILE_SIZE_BYTES=10485760`).
- Kích thước khung hình: `64x64 px` đến `4096x4096 px`, tối đa `16 MP` (`UPLOAD_MAX_PIXELS=16777216`).

### 6. Tạo Job Thử Đồ & Kiểm tra Trạng thái (Create/Status API - B03)
```powershell
# 1. Tạo job thử đồ (POST /api/v1/try-ons -> 202 Accepted)
curl -X POST "http://localhost:8000/api/v1/try-ons" `
  -H "Idempotency-Key: demo-request-001" `
  -F "person_image=@path/to/person.jpg" `
  -F "garment_image=@path/to/garment.png"

# 2. Lấy trạng thái job (GET /api/v1/try-ons/{job_id} -> 200 OK)
curl "http://localhost:8000/api/v1/try-ons/<job_id>"
# 3. Tải ảnh kết quả đã sinh (GET /api/v1/try-ons/{job_id}/image -> 200 OK binary)
curl "http://localhost:8000/api/v1/try-ons/<job_id>/image" --output result.jpg
```

### 7. Cấu hình AI Provider (B04 Fake vs B06 Real fal.ai)
Hệ thống hỗ trợ chuyển đổi linh hoạt qua biến môi trường `AI_PROVIDER`:
- `AI_PROVIDER=fake` (Mặc định cho dev/CI): Sử dụng `FakeAIProvider`, ghép ảnh tổng hợp trong bộ nhớ, không gọi ra ngoài và tốn 0 VNĐ.
- `AI_PROVIDER=fal`: Kích hoạt pipeline thực tế `FalAdapter`, tự động upload ảnh lên CDN `fal.ai`, submit inference queue, polling kết quả và tải ảnh về Docker Volume.

Các cơ chế phòng vệ then chốt trong Worker Pipeline (B06):
- **Idempotent Resume (T07):** Lưu `provider_request_id` ngay khi queue tiếp nhận. Khi Worker retry do timeout mạng, hệ thống tự động bỏ qua bước upload và submit lại, loại trừ việc tốn chi phí trùng lặp.
- **Decoupled CDN Download Retry (T08):** Tách biệt việc tải file từ CDN với suy luận model. Lỗi mạng khi tải ảnh được retry độc lập tại chỗ mà không chạy lại model AI.
- **Atomic Resume Lease:** Sử dụng SQL nguyên tử ngăn chặn 2 worker cùng xử lý một job trên hàng đợi.
- **Dual-Layer Secret Scrubbing:** Lọc bỏ `FAL_KEY` ở cả tầng Console Logging lẫn cột `error_message` trong PostgreSQL.
- **Safe Transaction Cleanup:** Dọn dẹp an toàn các file kết quả mồ côi nếu DB transaction gặp sự cố mà không che lấp ngoại lệ gốc.

### 8. Chạy kiểm thử tự động (Pytest)
```powershell
# Chạy toàn bộ test (Unit + Integration + Contract) trong container:
docker compose -f infrastructure/compose.yaml run --rm api pytest tests/unit tests/integration tests/contract -v

# Chạy Unit, Integration & Contract tests trực tiếp trên môi trường local (uv/python):
uv run pytest backend/tests/unit backend/tests/integration backend/tests/contract -v

# Chạy kiểm thử tích hợp riêng cho Real Worker Pipeline (B06 - MockTransport, 0 VNĐ):
uv run pytest backend/tests/integration/test_real_worker_pipeline.py -v

# Chạy Opt-in Paid Smoke Test với fal.ai thật (chỉ chạy 1 request khi đã cấu hình FAL_KEY trong .env):
$env:RUN_FAL_SMOKE="1"; uv run pytest backend/tests/external/test_fal_smoke.py -v -s; Remove-Item Env:\RUN_FAL_SMOKE
```

### 9. Dừng các dịch vụ
```powershell
docker compose -f infrastructure/compose.yaml down
```