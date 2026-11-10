import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/features/history/data/history_repository.dart';
import 'package:ai_virtual_outfit/features/try_on/data/models/job_model.dart';
import 'package:ai_virtual_outfit/features/try_on/data/try_on_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic in-memory [HttpClientAdapter] for testing [DioClient] and Repositories
/// without opening real network sockets.
class _MockHttpClientAdapter implements HttpClientAdapter {
  _MockHttpClientAdapter(this.handler);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options, requestStream);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(
  Map<String, dynamic> body, {
  int statusCode = 200,
}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  const testConfig = AppConfig(baseUrl: 'http://10.0.2.2:8000');

  group('TryOnRepository contract tests', () {
    test('checkHealth and checkReadiness call /health and /api/v1/health/ready', () async {
      final requestedPaths = <String>[];
      final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
      dio.httpClientAdapter = _MockHttpClientAdapter((options, _) async {
        requestedPaths.add(options.path);
        if (options.path == '/health') {
          return _jsonResponse({
            'status': 'ok',
            'app': 'AI Virtual Outfit Preview',
            'version': '0.1.0',
          });
        }
        if (options.path == '/api/v1/health/ready') {
          return _jsonResponse({
            'status': 'ready',
            'checks': {
              'redis': 'connected',
              'database': 'connected',
              'storage': 'writable',
            },
          });
        }
        return _jsonResponse({'error_code': 'INVALID_REQUEST'}, statusCode: 404);
      });

      final repo = TryOnRepository(
        dioClient: DioClient(config: testConfig, dio: dio),
      );

      final health = await repo.checkHealth();
      expect(health.isHealthy, isTrue);

      final ready = await repo.checkReadiness();
      expect(ready.isHealthy, isTrue);
      expect(ready.checks['database'], 'connected');
      expect(requestedPaths, ['/health', '/api/v1/health/ready']);
    });

    test('createTryOnJobFromBytes sends multipart POST with Idempotency-Key and returns queued JobModel', () async {
      String? capturedMethod;
      String? capturedPath;
      String? capturedIdempotencyKey;
      String? capturedContentType;

      final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
      dio.httpClientAdapter = _MockHttpClientAdapter((options, _) async {
        capturedMethod = options.method;
        capturedPath = options.path;
        capturedIdempotencyKey = options.headers['Idempotency-Key']?.toString();
        capturedContentType = options.contentType;

        return _jsonResponse(
          {
            'job_id': '307c143f-dbe7-4232-b2f1-5315fa5a18f6',
            'status': 'queued',
            'result_image_url': null,
            'person_image_url':
                '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/inputs/person',
            'garment_image_url':
                '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/inputs/garment',
            'error': null,
            'is_saved': false,
            'saved_at': null,
            'created_at': '2026-11-10T12:00:00Z',
            'updated_at': '2026-11-10T12:00:00Z',
            'completed_at': null,
          },
          statusCode: 202,
        );
      });

      final repo = TryOnRepository(
        dioClient: DioClient(config: testConfig, dio: dio),
      );

      final job = await repo.createTryOnJobFromBytes(
        personBytes: Uint8List.fromList([1, 2, 3, 4]),
        garmentBytes: Uint8List.fromList([5, 6, 7, 8]),
        idempotencyKey: 'idem-key-001',
      );

      expect(capturedMethod, 'POST');
      expect(capturedPath, '/api/v1/try-ons');
      expect(capturedIdempotencyKey, 'idem-key-001');
      expect(capturedContentType, contains('multipart/form-data'));
      expect(job.jobId, '307c143f-dbe7-4232-b2f1-5315fa5a18f6');
      expect(job.status, JobStatus.queued);
      expect(job.isActive, isTrue);
    });

    test('downloadResultImageBytes & downloadInputImageBytes stream binary bytes', () async {
      final sampleImageBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00]);
      final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
      dio.httpClientAdapter = _MockHttpClientAdapter((options, _) async {
        return ResponseBody.fromBytes(
          sampleImageBytes,
          200,
          headers: {
            Headers.contentTypeHeader: ['image/jpeg'],
          },
        );
      });

      final repo = TryOnRepository(
        dioClient: DioClient(config: testConfig, dio: dio),
      );

      final resultBytes = await repo.downloadResultImageBytes('job-123');
      expect(resultBytes, equals(sampleImageBytes));

      final personBytes = await repo.downloadInputImageBytes(
        'job-123',
        kind: 'person',
      );
      expect(personBytes, equals(sampleImageBytes));

      expect(
        () => repo.downloadInputImageBytes('job-123', kind: 'invalid_kind'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.errorCode,
            'errorCode',
            ApiErrorCode.invalidRequest,
          ),
        ),
      );
    });
  });

  group('HistoryRepository contract tests', () {
    test('saveJob, getHistoryList, getHistoryDetail, and deleteHistoryItem match Backend endpoints', () async {
      final calls = <String>[];
      final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
      dio.httpClientAdapter = _MockHttpClientAdapter((options, _) async {
        calls.add('${options.method} ${options.path}');

        if (options.method == 'POST' &&
            options.path == '/api/v1/try-ons/job-999/save') {
          return _jsonResponse({
            'job_id': 'job-999',
            'status': 'succeeded',
            'result_image_url': '/api/v1/try-ons/job-999/image',
            'person_image_url': '/api/v1/try-ons/job-999/inputs/person',
            'garment_image_url': '/api/v1/try-ons/job-999/inputs/garment',
            'error': null,
            'is_saved': true,
            'saved_at': '2026-11-10T15:00:00Z',
            'created_at': '2026-11-10T14:59:00Z',
            'updated_at': '2026-11-10T15:00:00Z',
            'completed_at': '2026-11-10T14:59:30Z',
          });
        }

        if (options.method == 'GET' && options.path == '/api/v1/history') {
          expect(options.queryParameters['limit'], 10);
          expect(options.queryParameters['offset'], 0);
          return _jsonResponse({
            'items': [
              {
                'job_id': 'job-999',
                'status': 'succeeded',
                'person_image_url': '/api/v1/try-ons/job-999/inputs/person',
                'garment_image_url': '/api/v1/try-ons/job-999/inputs/garment',
                'result_image_url': '/api/v1/try-ons/job-999/image',
                'is_saved': true,
                'saved_at': '2026-11-10T15:00:00Z',
                'created_at': '2026-11-10T14:59:00Z',
                'completed_at': '2026-11-10T14:59:30Z',
              },
            ],
            'total': 1,
            'limit': 10,
            'offset': 0,
          });
        }

        if (options.method == 'GET' &&
            options.path == '/api/v1/history/job-999') {
          return _jsonResponse({
            'job_id': 'job-999',
            'status': 'succeeded',
            'person_image_url': '/api/v1/try-ons/job-999/inputs/person',
            'garment_image_url': '/api/v1/try-ons/job-999/inputs/garment',
            'result_image_url': '/api/v1/try-ons/job-999/image',
            'is_saved': true,
            'saved_at': '2026-11-10T15:00:00Z',
            'created_at': '2026-11-10T14:59:00Z',
            'completed_at': '2026-11-10T14:59:30Z',
          });
        }

        if (options.method == 'DELETE' &&
            options.path == '/api/v1/history/job-999') {
          return ResponseBody.fromString('', 204);
        }

        return _jsonResponse({'error_code': 'JOB_NOT_FOUND'}, statusCode: 404);
      });

      final historyRepo = HistoryRepository(
        dioClient: DioClient(config: testConfig, dio: dio),
      );

      final savedJob = await historyRepo.saveJob('job-999');
      expect(savedJob.isSaved, isTrue);

      final list = await historyRepo.getHistoryList(limit: 10, offset: 0);
      expect(list.total, 1);
      expect(list.items.single.jobId, 'job-999');

      final detail = await historyRepo.getHistoryDetail('job-999');
      expect(detail.jobId, 'job-999');

      await historyRepo.deleteHistoryItem('job-999');

      expect(calls, [
        'POST /api/v1/try-ons/job-999/save',
        'GET /api/v1/history',
        'GET /api/v1/history/job-999',
        'DELETE /api/v1/history/job-999',
      ]);
    });
  });
}

