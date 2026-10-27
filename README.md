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

### 5. Chạy kiểm thử tự động (Pytest)
```powershell
docker compose -f infrastructure/compose.yaml run --rm api pytest tests/unit
```

### 6. Dừng các dịch vụ
```powershell
docker compose -f infrastructure/compose.yaml down
```