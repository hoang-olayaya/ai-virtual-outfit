import 'package:flutter/foundation.dart';

/// Standardized error codes matching `backend/app/core/errors.py` (`ErrorCode` enum),
/// plus client-side network/timeout classifications.
enum ApiErrorCode {
  // Request & Parameter Validation Errors (4xx)
  invalidRequest('INVALID_REQUEST'),
  invalidIdempotencyKey('INVALID_IDEMPOTENCY_KEY'),

  // Input & Image Validation Errors (4xx)
  missingInputImage('MISSING_INPUT_IMAGE'),
  fileTooLarge('FILE_TOO_LARGE'),
  unsupportedMediaType('UNSUPPORTED_MEDIA_TYPE'),
  corruptedImage('CORRUPTED_IMAGE'),
  invalidImageDimensions('INVALID_IMAGE_DIMENSIONS'),

  // Resource Lookup & State Conflict Errors (404 / 409)
  jobNotFound('JOB_NOT_FOUND'),
  imageNotFound('IMAGE_NOT_FOUND'),
  resultNotReady('RESULT_NOT_READY'),

  // Storage, Database, Queue & Worker Infrastructure Errors (5xx / Job errors)
  storagePathTraversal('STORAGE_PATH_TRAVERSAL'),
  storageUnavailable('STORAGE_UNAVAILABLE'),
  databaseError('DATABASE_ERROR'),
  queuePublishError('QUEUE_PUBLISH_ERROR'),
  aiProviderError('AI_PROVIDER_ERROR'),
  aiProviderTimeout('AI_PROVIDER_TIMEOUT'),
  aiProviderSubmitIndeterminate('AI_PROVIDER_SUBMIT_INDETERMINATE'),
  workerExecutionError('WORKER_EXECUTION_ERROR'),
  staleJobTimeout('STALE_JOB_TIMEOUT'),
  reconciliationAborted('RECONCILIATION_ABORTED'),

  // Client-side Transport / Connectivity Errors
  networkError('NETWORK_ERROR'),
  timeoutError('TIMEOUT_ERROR'),
  unknownError('UNKNOWN_ERROR');

  const ApiErrorCode(this.rawValue);

  final String rawValue;

  /// Parses raw `error_code` string from FastAPI JSON response into [ApiErrorCode].
  static ApiErrorCode fromRaw(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return ApiErrorCode.unknownError;
    }
    final normalized = raw.trim().toUpperCase();
    for (final code in ApiErrorCode.values) {
      if (code.rawValue == normalized) {
        return code;
      }
    }
    return ApiErrorCode.unknownError;
  }

  /// Provides a clear, user-friendly Vietnamese message for UI presentation (NFR-02).
  String get defaultUserMessage {
    switch (this) {
      case ApiErrorCode.missingInputImage:
        return 'Vui lòng chọn đầy đủ cả ảnh cá nhân và ảnh trang phục.';
      case ApiErrorCode.fileTooLarge:
        return 'Kích thước ảnh vượt quá giới hạn cho phép (tối đa 10 MB).';
      case ApiErrorCode.unsupportedMediaType:
        return 'Định dạng ảnh không được hỗ trợ. Vui lòng chọn ảnh JPEG, PNG hoặc WEBP.';
      case ApiErrorCode.corruptedImage:
        return 'Tệp ảnh bị lỗi hoặc không thể đọc được. Vui lòng chọn ảnh khác.';
      case ApiErrorCode.invalidImageDimensions:
        return 'Kích thước khung hình ảnh không hợp lệ (yêu cầu từ 64x64 đến 4096x4096 px).';
      case ApiErrorCode.invalidIdempotencyKey:
      case ApiErrorCode.invalidRequest:
        return 'Dữ liệu yêu cầu không hợp lệ. Vui lòng kiểm tra và thử lại.';
      case ApiErrorCode.jobNotFound:
        return 'Không tìm thấy yêu cầu thử trang phục này.';
      case ApiErrorCode.imageNotFound:
        return 'Không tìm thấy tệp hình ảnh trên máy chủ.';
      case ApiErrorCode.resultNotReady:
        return 'Ảnh kết quả hiện chưa sẵn sàng. Vui lòng đợi quá trình xử lý hoàn tất.';
      case ApiErrorCode.storageUnavailable:
      case ApiErrorCode.databaseError:
      case ApiErrorCode.queuePublishError:
        return 'Hệ thống máy chủ đang bận hoặc bảo trì. Vui lòng thử lại sau ít phút.';
      case ApiErrorCode.aiProviderError:
      case ApiErrorCode.aiProviderTimeout:
      case ApiErrorCode.aiProviderSubmitIndeterminate:
      case ApiErrorCode.workerExecutionError:
      case ApiErrorCode.staleJobTimeout:
        return 'Quá trình tạo ảnh AI gặp sự cố. Vui lòng thử lại.';
      case ApiErrorCode.networkError:
        return 'Không thể kết nối tới máy chủ. Vui lòng kiểm tra kết nối mạng.';
      case ApiErrorCode.timeoutError:
        return 'Kết nối tới máy chủ quá thời gian chờ. Vui lòng thử lại.';
      case ApiErrorCode.storagePathTraversal:
      case ApiErrorCode.reconciliationAborted:
      case ApiErrorCode.unknownError:
        return 'Đã xảy ra lỗi không xác định. Vui lòng thử lại.';
    }
  }
}

/// Structured exception thrown by `DioClient` and Repositories when an API call fails.
///
/// Distinguishes transport/network failures ([isNetworkError] == true) from
/// application/HTTP errors returned by FastAPI ([isNetworkError] == false),
/// fulfilling the Architecture V2 rule: "network failure != job failed".
@immutable
class ApiException implements Exception {
  const ApiException({
    required this.errorCode,
    required this.message,
    String? rawCode,
    this.statusCode,
    this.details,
    this.isNetworkError = false,
  }) : rawCode = rawCode ?? '';

  /// Parsed enum error code.
  final ApiErrorCode errorCode;

  /// Raw error code string returned by Backend (e.g., `MISSING_INPUT_IMAGE`).
  final String rawCode;

  /// Server-provided or client-mapped diagnostic message.
  final String message;

  /// HTTP status code if a response was received (e.g., 400, 404, 409, 413, 415, 422, 503).
  final int? statusCode;

  /// Optional structured error details map from Backend `ErrorResponse.details`.
  final Map<String, dynamic>? details;

  /// True when the error was caused by connectivity loss, DNS failure, or socket timeout
  /// rather than an HTTP error payload from the Backend.
  final bool isNetworkError;

  /// Parses FastAPI `ErrorResponse` JSON map:
  /// `{"error_code": "...", "message": "...", "details": {...}}`
  factory ApiException.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final rawErrorCode = json['error_code']?.toString() ?? 'UNKNOWN_ERROR';
    final parsedCode = ApiErrorCode.fromRaw(rawErrorCode);
    final rawMessage = json['message']?.toString();
    final rawDetails = json['details'];

    return ApiException(
      errorCode: parsedCode,
      rawCode: rawErrorCode,
      message: (rawMessage != null && rawMessage.trim().isNotEmpty)
          ? rawMessage
          : parsedCode.defaultUserMessage,
      statusCode: statusCode,
      details: rawDetails is Map<String, dynamic>
          ? Map<String, dynamic>.from(rawDetails)
          : null,
      isNetworkError: false,
    );
  }

  /// User-facing localized message suitable for Snackbars, Banners, and Error Screens.
  String get userFriendlyMessage => errorCode.defaultUserMessage;

  @override
  String toString() {
    final codeLabel = rawCode.isNotEmpty ? rawCode : errorCode.rawValue;
    return 'ApiException(statusCode: $statusCode, errorCode: $codeLabel, '
        'isNetworkError: $isNetworkError, message: $message)';
  }
}

