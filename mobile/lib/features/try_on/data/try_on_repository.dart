import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/dio_client.dart';
import 'models/health_status_model.dart';
import 'models/job_model.dart';

/// Repository responsible for Try-On creation, job status polling,
/// input/result media retrieval, and Backend health checks.
///
/// Architecture Rule: Widgets and Controllers never call [Dio] directly;
/// all Try-On HTTP interactions flow through [TryOnRepository].
class TryOnRepository {
  TryOnRepository({
    required this.dioClient,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final DioClient dioClient;
  final Uuid _uuid;

  AppConfig get config => dioClient.config;

  /// Checks Backend liveness probe (`GET /health`).
  Future<HealthStatusModel> checkHealth({CancelToken? cancelToken}) async {
    final json = await dioClient.getJson(
      '/health',
      cancelToken: cancelToken,
    );
    return HealthStatusModel.fromJson(json);
  }

  /// Checks Backend readiness probe (`GET /api/v1/health/ready`),
  /// verifying PostgreSQL, Redis, and Shared Volume Storage connectivity.
  Future<HealthStatusModel> checkReadiness({CancelToken? cancelToken}) async {
    final json = await dioClient.getJson(
      '${config.apiV1Prefix}/health/ready',
      cancelToken: cancelToken,
    );
    return HealthStatusModel.fromJson(json);
  }

  /// Submits a new Virtual Try-On job (`POST /api/v1/try-ons`) with two local image paths
  /// (`person_image` and `garment_image`) and an `Idempotency-Key` header.
  Future<JobModel> createTryOnJobFromPaths({
    required String personImagePath,
    required String garmentImagePath,
    String? personFileName,
    String? garmentFileName,
    String? idempotencyKey,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    final personMultipart = await MultipartFile.fromFile(
      personImagePath,
      filename: personFileName ?? _extractFileName(personImagePath, 'person.jpg'),
    );
    final garmentMultipart = await MultipartFile.fromFile(
      garmentImagePath,
      filename:
          garmentFileName ?? _extractFileName(garmentImagePath, 'garment.png'),
    );

    return createTryOnJobFromMultipart(
      personMultipart: personMultipart,
      garmentMultipart: garmentMultipart,
      idempotencyKey: idempotencyKey,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );
  }

  /// Submits a new Virtual Try-On job (`POST /api/v1/try-ons`) using in-memory bytes
  /// or pre-built [MultipartFile] objects.
  Future<JobModel> createTryOnJobFromBytes({
    required Uint8List personBytes,
    required Uint8List garmentBytes,
    String personFileName = 'person.jpg',
    String garmentFileName = 'garment.png',
    String? idempotencyKey,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) {
    final personMultipart = MultipartFile.fromBytes(
      personBytes,
      filename: personFileName,
    );
    final garmentMultipart = MultipartFile.fromBytes(
      garmentBytes,
      filename: garmentFileName,
    );

    return createTryOnJobFromMultipart(
      personMultipart: personMultipart,
      garmentMultipart: garmentMultipart,
      idempotencyKey: idempotencyKey,
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );
  }

  /// Core multipart submission method (`POST /api/v1/try-ons`).
  Future<JobModel> createTryOnJobFromMultipart({
    required MultipartFile personMultipart,
    required MultipartFile garmentMultipart,
    String? idempotencyKey,
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
  }) async {
    final effectiveKey = (idempotencyKey != null && idempotencyKey.trim().isNotEmpty)
        ? idempotencyKey.trim()
        : _uuid.v4();

    if (effectiveKey.length > 255) {
      throw const ApiException(
        errorCode: ApiErrorCode.invalidIdempotencyKey,
        rawCode: 'INVALID_IDEMPOTENCY_KEY',
        message: 'Idempotency-Key header must not exceed 255 characters.',
        statusCode: 400,
      );
    }

    final formData = FormData.fromMap(<String, dynamic>{
      'person_image': personMultipart,
      'garment_image': garmentMultipart,
    });

    final json = await dioClient.postJson(
      '${config.apiV1Prefix}/try-ons',
      data: formData,
      options: Options(
        headers: <String, dynamic>{
          'Idempotency-Key': effectiveKey,
        },
      ),
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );

    return JobModel.fromJson(json);
  }

  /// Retrieves the current status and metadata of a try-on job (`GET /api/v1/try-ons/{job_id}`).
  Future<JobModel> getJobStatus(
    String jobId, {
    CancelToken? cancelToken,
  }) async {
    final normalizedId = jobId.trim();
    final json = await dioClient.getJson(
      '${config.apiV1Prefix}/try-ons/$normalizedId',
      cancelToken: cancelToken,
    );
    return JobModel.fromJson(json);
  }

  /// Downloads the generated result image bytes (`GET /api/v1/try-ons/{job_id}/image`).
  Future<Uint8List> downloadResultImageBytes(
    String jobId, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) {
    final normalizedId = jobId.trim();
    return dioClient.getBytes(
      '${config.apiV1Prefix}/try-ons/$normalizedId/image',
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// Downloads input image bytes (`GET /api/v1/try-ons/{job_id}/inputs/{kind}`)
  /// where [kind] is `'person'` or `'garment'`.
  Future<Uint8List> downloadInputImageBytes(
    String jobId, {
    required String kind,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) {
    final normalizedId = jobId.trim();
    final normalizedKind = kind.trim().toLowerCase();
    if (normalizedKind != 'person' && normalizedKind != 'garment') {
      throw const ApiException(
        errorCode: ApiErrorCode.invalidRequest,
        rawCode: 'INVALID_REQUEST',
        message: 'Input image kind must be "person" or "garment".',
        statusCode: 400,
      );
    }
    return dioClient.getBytes(
      '${config.apiV1Prefix}/try-ons/$normalizedId/inputs/$normalizedKind',
      cancelToken: cancelToken,
      onReceiveProgress: onReceiveProgress,
    );
  }

  /// Builds the full absolute URL for a job's result image.
  String buildResultImageUrl(String jobId) {
    return config.resolveUrl('${config.apiV1Prefix}/try-ons/${jobId.trim()}/image');
  }

  /// Builds the full absolute URL for a job's input image (`person` or `garment`).
  String buildInputImageUrl(String jobId, {required String kind}) {
    return config.resolveUrl(
      '${config.apiV1Prefix}/try-ons/${jobId.trim()}/inputs/${kind.trim().toLowerCase()}',
    );
  }

  static String _extractFileName(String path, String fallback) {
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/');
    final last = segments.isNotEmpty ? segments.last.trim() : '';
    return last.isNotEmpty ? last : fallback;
  }
}

/// Riverpod provider for [TryOnRepository].
final tryOnRepositoryProvider = Provider<TryOnRepository>((ref) {
  final dioClient = ref.watch(dioClientProvider);
  return TryOnRepository(dioClient: dioClient);
});

