import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import 'api_error.dart';

/// Centralized HTTP client wrapper around [Dio] configured for the FastAPI Backend.
///
/// Responsibilities:
/// - Applies base URL and timeouts from [AppConfig].
/// - Normalizes all [DioException] errors into structured [ApiException] instances,
///   including JSON error responses returned as `Map`, `String`, or binary `Uint8List`
///   (e.g., when a `ResponseType.bytes` media download returns HTTP 404/409).
class DioClient {
  DioClient({
    required this.config,
    Dio? dio,
  }) : _dio = dio ?? _createDefaultDio(config);

  final AppConfig config;
  final Dio _dio;

  /// Underlying [Dio] instance (exposed for testing or advanced multipart configuration).
  Dio get rawDio => _dio;

  static Dio _createDefaultDio(AppConfig config) {
    return Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        sendTimeout: config.sendTimeout,
        headers: const {
          'Accept': 'application/json',
        },
      ),
    );
  }

  /// Performs a GET request and returns a JSON object map.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        path,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
      return _ensureJsonMap(response.data, statusCode: response.statusCode);
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  /// Performs a POST request (JSON or Multipart [FormData]) and returns a JSON object map.
  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
        onSendProgress: onSendProgress,
      );
      return _ensureJsonMap(response.data, statusCode: response.statusCode);
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  /// Performs a DELETE request (expects 204 No Content or empty body).
  Future<void> delete(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      await _dio.delete<dynamic>(
        path,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  /// Downloads raw binary bytes (e.g. `GET /api/v1/try-ons/{id}/image`).
  Future<Uint8List> getBytes(
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    try {
      final response = await _dio.get<List<int>>(
        path,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {
            'Accept': 'image/*, application/json',
          },
        ),
      );
      final bytes = response.data;
      if (bytes == null) {
        throw const ApiException(
          errorCode: ApiErrorCode.imageNotFound,
          rawCode: 'IMAGE_NOT_FOUND',
          message: 'Empty image payload returned by server.',
        );
      }
      return Uint8List.fromList(bytes);
    } on DioException catch (e) {
      throw mapDioException(e);
    }
  }

  /// Maps any [DioException] into a strongly-typed [ApiException].
  static ApiException mapDioException(DioException exception) {
    final statusCode = exception.response?.statusCode;
    final responseData = exception.response?.data;

    // 1. If the server returned an HTTP response payload, try parsing FastAPI ErrorResponse JSON.
    if (responseData != null) {
      final parsedMap = _tryExtractJsonMap(responseData);
      if (parsedMap != null) {
        if (parsedMap.containsKey('error_code') ||
            parsedMap.containsKey('message')) {
          return ApiException.fromJson(parsedMap, statusCode: statusCode);
        }
        // Fallback if server returned a readiness check payload on HTTP 503:
        // e.g. {"status": "not_ready", "checks": {...}}
        if (parsedMap.containsKey('status') && parsedMap.containsKey('checks')) {
          return ApiException(
            errorCode: ApiErrorCode.storageUnavailable,
            rawCode: 'SERVICE_NOT_READY',
            message: 'Backend readiness check returned not_ready.',
            statusCode: statusCode,
            details: parsedMap,
            isNetworkError: false,
          );
        }
      }
    }

    // 2. Check timeout categories.
    if (exception.type == DioExceptionType.connectionTimeout ||
        exception.type == DioExceptionType.sendTimeout ||
        exception.type == DioExceptionType.receiveTimeout) {
      return ApiException(
        errorCode: ApiErrorCode.timeoutError,
        rawCode: ApiErrorCode.timeoutError.rawValue,
        message: exception.message ??
            'Request timed out while communicating with Backend.',
        statusCode: statusCode,
        isNetworkError: true,
      );
    }

    // 3. Check connection / socket errors (no HTTP status code received).
    if (exception.type == DioExceptionType.connectionError ||
        (exception.type == DioExceptionType.unknown && statusCode == null)) {
      return ApiException(
        errorCode: ApiErrorCode.networkError,
        rawCode: ApiErrorCode.networkError.rawValue,
        message: exception.message ??
            'Unable to reach Backend server. Check connection or IP address.',
        statusCode: statusCode,
        isNetworkError: true,
      );
    }

    // 4. Fallback HTTP status code mapping when body is non-JSON.
    return _mapByStatusCode(
      statusCode: statusCode,
      fallbackMessage: exception.message ?? 'Unexpected HTTP error.',
    );
  }

  static Map<String, dynamic> _ensureJsonMap(
    dynamic data, {
    int? statusCode,
  }) {
    final map = _tryExtractJsonMap(data);
    if (map != null) {
      return map;
    }
    throw ApiException(
      errorCode: ApiErrorCode.unknownError,
      rawCode: 'INVALID_JSON_PAYLOAD',
      message: 'Expected a JSON object response from server.',
      statusCode: statusCode,
    );
  }

  static Map<String, dynamic>? _tryExtractJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {
        return null;
      }
    }
    if (data is List<int> && data.isNotEmpty) {
      try {
        final utf8String = utf8.decode(data, allowMalformed: true);
        final decoded = jsonDecode(utf8String);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static ApiException _mapByStatusCode({
    required int? statusCode,
    required String fallbackMessage,
  }) {
    switch (statusCode) {
      case 400:
      case 422:
        return ApiException(
          errorCode: ApiErrorCode.invalidRequest,
          rawCode: ApiErrorCode.invalidRequest.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
      case 404:
        return ApiException(
          errorCode: ApiErrorCode.jobNotFound,
          rawCode: ApiErrorCode.jobNotFound.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
      case 409:
        return ApiException(
          errorCode: ApiErrorCode.resultNotReady,
          rawCode: ApiErrorCode.resultNotReady.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
      case 413:
        return ApiException(
          errorCode: ApiErrorCode.fileTooLarge,
          rawCode: ApiErrorCode.fileTooLarge.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
      case 415:
        return ApiException(
          errorCode: ApiErrorCode.unsupportedMediaType,
          rawCode: ApiErrorCode.unsupportedMediaType.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
      case 502:
      case 503:
      case 504:
        return ApiException(
          errorCode: ApiErrorCode.storageUnavailable,
          rawCode: ApiErrorCode.storageUnavailable.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
      default:
        return ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: fallbackMessage,
          statusCode: statusCode,
        );
    }
  }
}

/// Riverpod provider for the underlying [Dio] instance.
final dioProvider = Provider<Dio>((ref) {
  final config = ref.watch(appConfigProvider);
  return DioClient(config: config).rawDio;
});

/// Riverpod provider for [DioClient].
final dioClientProvider = Provider<DioClient>((ref) {
  final config = ref.watch(appConfigProvider);
  final dio = ref.watch(dioProvider);
  return DioClient(config: config, dio: dio);
});

