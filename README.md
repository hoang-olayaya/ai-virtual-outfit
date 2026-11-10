# AI Virtual Outfit Preview

Ứng dụng di động và nền tảng backend cho phép xem trước hình ảnh bản thân khi mặc một trang phục bất kỳ, sử dụng AI sinh hình ảnh.

## Kiến trúc hệ thống

Dự án được tổ chức theo mô hình Monorepo:
- `backend/`: FastAPI REST API và Celery Worker (xử lý tác vụ nền).
- `infrastructure/`: Docker Compose và cấu hình môi trường hạ tầng.
- `docs/`: Tài liệu kiến trúc và hướng dẫn vận hành.
- `mobile/`: Ứng dụng di động Flutter (Riverpod + go_router + Dio + DTOs & Repositories).

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

### 8. Quản lý Lịch sử & Tải ảnh So sánh (History & Input Media - B07)
```powershell
# 1. Lưu kết quả thử đồ vào lịch sử (POST /api/v1/try-ons/{id}/save -> 200 OK idempotent)
curl -X POST "http://localhost:8000/api/v1/try-ons/<job_id>/save"

# 2. Xem danh sách lịch sử phân trang (GET /api/v1/history?limit=10&offset=0 -> 200 OK)
curl "http://localhost:8000/api/v1/history?limit=10&offset=0"

# 3. Xem chi tiết một mục lịch sử (GET /api/v1/history/{job_id} -> 200 OK)
curl "http://localhost:8000/api/v1/history/<job_id>"

# 4. Tải ảnh đầu vào để so sánh Trước / Sau (GET /api/v1/try-ons/{job_id}/inputs/{kind})
curl "http://localhost:8000/api/v1/try-ons/<job_id>/inputs/person" --output person.jpg
curl "http://localhost:8000/api/v1/try-ons/<job_id>/inputs/garment" --output garment.png

# 5. Xóa một mục khỏi lịch sử (DELETE /api/v1/history/{job_id} -> 204 No Content)
curl -X DELETE "http://localhost:8000/api/v1/history/<job_id>"
```

### 9. Công cụ Vận hành & Tự phục hồi (Reliability & Sweeper - B08)
```powershell
# 1. Tự động đối soát và cứu hộ các job bị treo (Reconciler CLI):
docker compose -f infrastructure/compose.yaml exec api python -m app.maintenance.reconcile_jobs

# 2. Dọn dẹp file tạm .part và thư mục ảnh mồ côi kèm Grace Period 15 phút (Sweeper CLI):
docker compose -f infrastructure/compose.yaml exec api python -m app.maintenance.cleanup_files
```

### 10. Chạy kiểm thử tự động (Pytest) & Repeatable E2E Smoke Test
```powershell
# Chạy toàn bộ 135 tests (Unit + Integration + Contract) trong container api (Target: 135 passed, 0 skipped, 0 failed):
docker compose -f infrastructure/compose.yaml run --rm -e DATABASE_URL=postgresql+asyncpg://postgres:postgres_password_dev@postgres:5432/virtual_outfit_test_db api pytest tests/unit tests/integration tests/contract -v

# Chạy test suite trên môi trường host với test database cô lập:
$env:DATABASE_URL="postgresql+asyncpg://postgres:postgres_password_dev@localhost:5432/virtual_outfit_test_db"
pytest backend/tests/unit backend/tests/integration backend/tests/contract -v
Remove-Item Env:\DATABASE_URL

# Chạy kịch bản kiểm thử End-to-End tự động lặp lại (10 bước hoàn chỉnh, 0 VNĐ):
powershell -ExecutionPolicy Bypass -File scripts/smoke_e2e_backend.ps1

# Chạy Opt-in Paid Smoke Test với fal.ai thật (khi đã cấu hình FAL_KEY trong .env):
$env:RUN_FAL_SMOKE="1"; pytest backend/tests/external/test_fal_smoke.py -v -s; Remove-Item Env:\RUN_FAL_SMOKE
```

### 11. Khởi chạy & Kiểm thử Ứng dụng Mobile Flutter (Phase F01)
Ứng dụng Flutter nằm tại thư mục `mobile/` và sử dụng `AppConfig` để tự động nhận diện địa chỉ Backend:
- **Android Emulator:** Tự động kết nối tới `http://10.0.2.2:8000` (ánh xạ sang `localhost:8000` của máy chủ).
- **iOS Simulator / Host Test:** Tự động kết nối tới `http://localhost:8000`.
- **Điện thoại thật (cùng mạng Wi-Fi/LAN):** Truyền địa chỉ IP LAN của máy tính qua `--dart-define`:

```powershell
cd mobile

# 1. Cài đặt dependencies
flutter pub get

# 2. Phân tích mã nguồn tĩnh (Target: No issues found!)
flutter analyze

# 3. Chạy toàn bộ Unit, Widget & TCP Socket Connectivity Tests (Target: 38/38 passed)
flutter test --reporter expanded

# 4. Chạy ứng dụng trên Android Emulator (mặc định dùng http://10.0.2.2:8000)
flutter run

# 5. Chạy ứng dụng trên Điện thoại thật qua mạng LAN
flutter run --dart-define=API_BASE_URL=http://<LAN_IP_CUA_MAY_TINH>:8000
```

### 12. Trạng thái Milestone
- **BACKEND GATE (G1):** **PASSED** (135/135 tests pass, 0 fail, 0 skip; 4 containers healthy; E2E smoke 10/10 pass; secret scan clean).
- **Phase F01 — Flutter Shell, go_router, Dio & DTOs:** **DONE** (`flutter analyze` 0 issues; 19/19 Flutter unit/widget/socket tests PASS; 6 màn hình khung + `TryOnRepository` + `HistoryRepository` + `ApiException` mapping hoàn chỉnh).
- **Phase F02 — UploadScreen, PreviewScreen, image_picker & TryOnDraftController:** **DONE** (`TryOnDraftController` quản lý trạng thái nháp bất biến, đóng picker không mất ảnh cũ, kiểm tra sớm dung lượng/file rỗng, xem trước song song trên `PreviewScreen`).
- **Phase F03 — Submit + Processing + Polling:** **DONE** (`flutter analyze` 0 issues; 27/27 Flutter tests PASS; `TryOnSubmissionController` chống double-submit & bảo toàn `Idempotency-Key` theo fingerprint (T10); `JobStatusController` chạy single-flight polling loop, chịu lỗi mạng tạm thời T09 `network failure != job failed`, tạm dừng/tiếp tục theo `AppLifecycleState`, và tự động điều hướng sang `ResultScreen` khi `succeeded`).
- **Phase F04 — ResultScreen, Before/After Compare, Save & Share:** **DONE** (`flutter analyze` 0 issues; 33/33 Flutter tests PASS; `TryOnResultController` tải byte ảnh kết quả & input, `TryOnComparisonView` 3 chế độ đối chiếu, `ImageShareService` dò magic header ghi file tạm + `share_plus`, lưu lịch sử idempotent T11 và cô lập hoàn toàn `Save != Share != Retry`).
- **Phase F05 — History / List / Detail / Delete:** **DONE** (`flutter analyze` 0 issues; 38/38 Flutter tests PASS; `HistoryController` & `HistoryDetailController` quản lý danh sách lịch sử phân trang từ Backend, khôi phục đầy đủ danh sách và bộ 3 ảnh đối chiếu Trước/Sau sau khi restart app theo Kịch bản T11, xử lý 404 Not Found, chia sẻ và xóa có hộp thoại xác nhận kèm phục hồi lỗi).
- **Tiếp theo:** Mở khóa **GATE-FE — Kiểm thử End-to-End & Nghiệm thu tổng thể**.

### 13. Dừng các dịch vụ
```powershell
docker compose -f infrastructure/compose.yaml down
```
