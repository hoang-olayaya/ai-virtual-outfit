import 'dart:convert';
import 'dart:io';

import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/features/history/data/history_repository.dart';
import 'package:ai_virtual_outfit/features/try_on/data/try_on_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Real TCP Socket HTTP Connectivity & Error Parsing Tests', () {
    late HttpServer server;
    late String baseUrl;
    late TryOnRepository tryOnRepo;
    late HistoryRepository historyRepo;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
      final config = AppConfig(baseUrl: baseUrl);
      final dioClient = DioClient(config: config);
      tryOnRepo = TryOnRepository(dioClient: dioClient);
      historyRepo = HistoryRepository(dioClient: dioClient);

      server.listen((HttpRequest request) async {
        final path = request.uri.path;
        request.response.headers.contentType = ContentType.json;

        if (request.method == 'GET' && path == '/health') {
          request.response
            ..statusCode = HttpStatus.ok
            ..write(
              jsonEncode({
                'status': 'ok',
                'app': 'AI Virtual Outfit Preview',
                'version': '0.1.0',
                'environment': 'development',
              }),
            );
        } else if (request.method == 'GET' && path == '/api/v1/health/ready') {
          request.response
            ..statusCode = HttpStatus.ok
            ..write(
              jsonEncode({
                'status': 'ready',
                'checks': {
                  'redis': 'connected',
                  'storage': 'writable (/app/data_storage)',
                  'database': 'connected',
                },
              }),
            );
        } else if (request.method == 'GET' && path == '/api/v1/history') {
          request.response
            ..statusCode = HttpStatus.ok
            ..write(
              jsonEncode({
                'items': <Map<String, dynamic>>[],
                'total': 0,
                'limit': 5,
                'offset': 0,
              }),
            );
        } else if (request.method == 'GET' &&
            path == '/api/v1/try-ons/00000000-0000-0000-0000-000000000000') {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write(
              jsonEncode({
                'error_code': 'JOB_NOT_FOUND',
                'message': 'Requested try-on job was not found.',
              }),
            );
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write(
              jsonEncode({
                'error_code': 'INVALID_REQUEST',
                'message': 'Endpoint not found',
              }),
            );
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'executes real TCP HTTP calls via DioClient for GET /health, /api/v1/health/ready, /api/v1/history, and 404 JOB_NOT_FOUND',
      () async {
        final health = await tryOnRepo.checkHealth();
        expect(health.isHealthy, isTrue);
        expect(health.status, 'ok');
        expect(health.app, 'AI Virtual Outfit Preview');

        final readiness = await tryOnRepo.checkReadiness();
        expect(readiness.isHealthy, isTrue);
        expect(readiness.status, 'ready');
        expect(readiness.checks['database'], 'connected');
        expect(readiness.checks['redis'], 'connected');

        final history = await historyRepo.getHistoryList(limit: 5, offset: 0);
        expect(history.total, 0);
        expect(history.limit, 5);

        await expectLater(
          () => tryOnRepo.getJobStatus('00000000-0000-0000-0000-000000000000'),
          throwsA(
            isA<ApiException>()
                .having(
                  (e) => e.errorCode,
                  'errorCode',
                  ApiErrorCode.jobNotFound,
                )
                .having((e) => e.statusCode, 'statusCode', 404)
                .having((e) => e.isNetworkError, 'isNetworkError', isFalse),
          ),
        );
      },
    );

    test(
      'maps real TCP connection refused error to ApiException with isNetworkError = true',
      () async {
        // Close the server first to guarantee port is closed and refuses connections
        final closedPort = server.port;
        await server.close(force: true);

        final offlineRepo = TryOnRepository(
          dioClient: DioClient(
            config: AppConfig(
              baseUrl: 'http://127.0.0.1:$closedPort',
              connectTimeout: const Duration(milliseconds: 300),
            ),
          ),
        );

        await expectLater(
          () => offlineRepo.checkHealth(),
          throwsA(
            isA<ApiException>()
                .having(
                  (e) => e.errorCode,
                  'errorCode',
                  isIn([ApiErrorCode.networkError, ApiErrorCode.timeoutError]),
                )
                .having((e) => e.isNetworkError, 'isNetworkError', isTrue),
          ),
        );
      },
    );
  });
}
