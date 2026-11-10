import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/features/history/data/models/history_item_model.dart';
import 'package:ai_virtual_outfit/features/try_on/data/models/health_status_model.dart';
import 'package:ai_virtual_outfit/features/try_on/data/models/job_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig platform & IP resolution tests', () {
    test('selects 10.0.2.2:8000 on Android when no override is provided', () {
      final config = AppConfig.fromEnvironment(
        overrideBaseUrl: '',
        platformOverride: TargetPlatform.android,
        isWebOverride: false,
      );
      expect(config.baseUrl, 'http://10.0.2.2:8000');
      expect(config.apiV1BaseUrl, 'http://10.0.2.2:8000/api/v1');
    });

    test('selects localhost:8000 on iOS/Windows when no override is provided', () {
      final iosConfig = AppConfig.fromEnvironment(
        overrideBaseUrl: '',
        platformOverride: TargetPlatform.iOS,
        isWebOverride: false,
      );
      expect(iosConfig.baseUrl, 'http://localhost:8000');

      final windowsConfig = AppConfig.fromEnvironment(
        overrideBaseUrl: '',
        platformOverride: TargetPlatform.windows,
        isWebOverride: false,
      );
      expect(windowsConfig.baseUrl, 'http://localhost:8000');
    });

    test('uses custom LAN IP override and strips trailing slashes', () {
      final phoneConfig = AppConfig.fromEnvironment(
        overrideBaseUrl: 'http://192.168.1.50:8000///',
        platformOverride: TargetPlatform.android,
      );
      expect(phoneConfig.baseUrl, 'http://192.168.1.50:8000');
      expect(
        phoneConfig.resolveUrl('/api/v1/try-ons/abc/image'),
        'http://192.168.1.50:8000/api/v1/try-ons/abc/image',
      );
      expect(
        phoneConfig.resolveUrl('https://cdn.fal.ai/result.jpg'),
        'https://cdn.fal.ai/result.jpg',
      );
    });
  });

  group('HealthStatusModel serialization tests', () {
    test('parses GET /health and GET /api/v1/health/ready payloads', () {
      final liveness = HealthStatusModel.fromJson(const {
        'status': 'ok',
        'app': 'AI Virtual Outfit Preview',
        'version': '0.1.0',
        'environment': 'development',
      });
      expect(liveness.isHealthy, isTrue);
      expect(liveness.app, 'AI Virtual Outfit Preview');

      final readiness = HealthStatusModel.fromJson(const {
        'status': 'ready',
        'checks': {
          'redis': 'connected',
          'storage': 'writable (/app/data_storage)',
          'database': 'connected',
        },
      });
      expect(readiness.isHealthy, isTrue);
      expect(readiness.checks['database'], 'connected');
      expect(readiness.checks['redis'], 'connected');
    });
  });

  group('JobModel & JobStatus serialization tests', () {
    test('parses succeeded JobResponse JSON from Backend', () {
      final json = <String, dynamic>{
        'job_id': '307c143f-dbe7-4232-b2f1-5315fa5a18f6',
        'status': 'succeeded',
        'result_image_url':
            '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/image',
        'person_image_url':
            '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/inputs/person',
        'garment_image_url':
            '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/inputs/garment',
        'error': null,
        'is_saved': true,
        'saved_at': '2026-11-09T18:39:06.872316Z',
        'created_at': '2026-11-09T18:38:00.000000Z',
        'updated_at': '2026-11-09T18:39:06.872316Z',
        'completed_at': '2026-11-09T18:39:00.000000Z',
      };

      final job = JobModel.fromJson(json);
      expect(job.jobId, '307c143f-dbe7-4232-b2f1-5315fa5a18f6');
      expect(job.status, JobStatus.succeeded);
      expect(job.isSucceeded, isTrue);
      expect(job.isTerminal, isTrue);
      expect(job.isActive, isFalse);
      expect(job.isSaved, isTrue);
      expect(job.error, isNull);
      expect(
        job.resultImageUrl,
        '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/image',
      );

      final roundTrip = JobModel.fromJson(job.toJson());
      expect(roundTrip, equals(job));
    });

    test('parses failed JobResponse with nested JobErrorDetail', () {
      final json = <String, dynamic>{
        'job_id': '11111111-2222-3333-4444-555555555555',
        'status': 'failed',
        'result_image_url': null,
        'person_image_url':
            '/api/v1/try-ons/11111111-2222-3333-4444-555555555555/inputs/person',
        'garment_image_url':
            '/api/v1/try-ons/11111111-2222-3333-4444-555555555555/inputs/garment',
        'error': {
          'error_code': 'AI_PROVIDER_TIMEOUT',
          'message': 'Inference timed out after 120 seconds.',
        },
        'is_saved': false,
        'saved_at': null,
        'created_at': '2026-11-10T10:00:00Z',
        'updated_at': '2026-11-10T10:02:00Z',
        'completed_at': '2026-11-10T10:02:00Z',
      };

      final job = JobModel.fromJson(json);
      expect(job.isFailed, isTrue);
      expect(job.isTerminal, isTrue);
      expect(job.error, isNotNull);
      expect(job.error!.errorCode, 'AI_PROVIDER_TIMEOUT');
      expect(job.error!.apiErrorCode, ApiErrorCode.aiProviderTimeout);
      expect(job.error!.userFriendlyMessage, contains('AI'));
    });
  });

  group('HistoryItemModel & HistoryListModel serialization tests', () {
    test('parses paginated HistoryListResponse and computes hasMore', () {
      final json = <String, dynamic>{
        'items': [
          {
            'job_id': '307c143f-dbe7-4232-b2f1-5315fa5a18f6',
            'status': 'succeeded',
            'person_image_url':
                '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/inputs/person',
            'garment_image_url':
                '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/inputs/garment',
            'result_image_url':
                '/api/v1/try-ons/307c143f-dbe7-4232-b2f1-5315fa5a18f6/image',
            'is_saved': true,
            'saved_at': '2026-11-09T18:39:06.872316Z',
            'created_at': '2026-11-09T18:38:00.000000Z',
            'completed_at': '2026-11-09T18:39:00.000000Z',
          },
        ],
        'total': 5,
        'limit': 1,
        'offset': 0,
      };

      final historyList = HistoryListModel.fromJson(json);
      expect(historyList.items.length, 1);
      expect(historyList.total, 5);
      expect(historyList.hasMore, isTrue);
      expect(
        historyList.items.first.jobId,
        '307c143f-dbe7-4232-b2f1-5315fa5a18f6',
      );

      final roundTrip = HistoryListModel.fromJson(historyList.toJson());
      expect(roundTrip, equals(historyList));
    });
  });
}

