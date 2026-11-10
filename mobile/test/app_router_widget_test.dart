import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/core/services/image_picker_service.dart';
import 'package:ai_virtual_outfit/features/try_on/presentation/screens/preview_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Minimal valid 1x1 transparent PNG bytes for deterministic widget tests.
final Uint8List _kSamplePngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

class _FakeImagePickerService extends ImagePickerService {
  int _counter = 0;

  @override
  Future<XFile?> pickImage({
    ImageSource source = ImageSource.gallery,
    double? maxWidth = ImagePickerService.defaultMaxDimension,
    double? maxHeight = ImagePickerService.defaultMaxDimension,
    int? imageQuality = ImagePickerService.defaultImageQuality,
  }) async {
    _counter++;
    final fileName = 'sample_$_counter.png';
    return XFile.fromData(
      _kSamplePngBytes,
      name: fileName,
      path: '/mock/$fileName',
      mimeType: 'image/png',
    );
  }
}

class _FakeBackendAdapter implements HttpClientAdapter {
  _FakeBackendAdapter({this.shouldFail = false});

  final bool shouldFail;
  int _statusPollCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (shouldFail) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection refused',
      );
    }

    if (options.path == '/health') {
      return ResponseBody.fromString(
        jsonEncode({
          'status': 'ok',
          'app': 'AI Virtual Outfit Preview',
          'version': '0.1.0',
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    if (options.path == '/api/v1/health/ready') {
      return ResponseBody.fromString(
        jsonEncode({
          'status': 'ready',
          'checks': {
            'redis': 'connected',
            'database': 'connected',
            'storage': 'writable',
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    if (options.method == 'POST' && options.path == '/api/v1/try-ons') {
      return ResponseBody.fromString(
        jsonEncode({
          'job_id': PreviewScreen.sampleDemoJobId,
          'status': 'queued',
          'result_image_url': null,
          'person_image_url':
              '/api/v1/try-ons/${PreviewScreen.sampleDemoJobId}/inputs/person',
          'garment_image_url':
              '/api/v1/try-ons/${PreviewScreen.sampleDemoJobId}/inputs/garment',
          'error': null,
          'is_saved': false,
          'saved_at': null,
          'created_at': '2026-11-11T00:00:00Z',
          'updated_at': '2026-11-11T00:00:00Z',
          'completed_at': null,
        }),
        202,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    if (options.method == 'GET' &&
        options.path == '/api/v1/try-ons/${PreviewScreen.sampleDemoJobId}') {
      _statusPollCount++;
      final isSucceeded = _statusPollCount >= 2;
      return ResponseBody.fromString(
        jsonEncode({
          'job_id': PreviewScreen.sampleDemoJobId,
          'status': isSucceeded ? 'succeeded' : 'processing',
          'result_image_url': isSucceeded
              ? '/api/v1/try-ons/${PreviewScreen.sampleDemoJobId}/image'
              : null,
          'person_image_url':
              '/api/v1/try-ons/${PreviewScreen.sampleDemoJobId}/inputs/person',
          'garment_image_url':
              '/api/v1/try-ons/${PreviewScreen.sampleDemoJobId}/inputs/garment',
          'error': null,
          'is_saved': false,
          'saved_at': null,
          'created_at': '2026-11-11T00:00:00Z',
          'updated_at': '2026-11-11T00:00:02Z',
          'completed_at': isSucceeded ? '2026-11-11T00:00:04Z' : null,
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets(
    'App Shell renders UploadScreen, verifies Backend health, and navigates across all 6 go_router screens',
    (tester) async {
      const config = AppConfig(
        baseUrl: 'http://10.0.2.2:8000',
        pollingInterval: Duration(milliseconds: 200),
      );
      final mockDio = Dio(BaseOptions(baseUrl: config.baseUrl))
        ..httpClientAdapter = _FakeBackendAdapter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(config),
            dioProvider.overrideWithValue(mockDio),
            imagePickerServiceProvider.overrideWithValue(
              _FakeImagePickerService(),
            ),
          ],
          child: const VirtualOutfitApp(),
        ),
      );

      await tester.pumpAndSettle();

      // 1. UploadScreen is shown with healthy Backend status
      expect(find.text('AI Virtual Outfit Preview'), findsOneWidget);
      expect(find.byKey(const Key('backend_status_ok_text')), findsOneWidget);
      expect(
        find.textContaining('Trạng thái: OK • Readiness: ready'),
        findsOneWidget,
      );

      // Select both Person and Garment images so FR-05 readiness gate unlocks
      await tester.ensureVisible(
        find.byKey(const Key('pick_person_gallery_button')),
      );
      await tester.tap(find.byKey(const Key('pick_person_gallery_button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('pick_garment_gallery_button')),
      );
      await tester.tap(find.byKey(const Key('pick_garment_gallery_button')));
      await tester.pumpAndSettle();

      // 2. Navigate to PreviewScreen (/preview)
      await tester.ensureVisible(find.byKey(const Key('nav_preview_button')));
      await tester.tap(find.byKey(const Key('nav_preview_button')));
      await tester.pumpAndSettle();
      expect(find.text('Xem trước ảnh đã chọn'), findsOneWidget);

      // 3. Submit on PreviewScreen -> navigates to ProcessingScreen (/processing/:jobId)
      await tester.tap(
        find.byKey(const Key('preview_start_processing_button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Đang tạo ảnh thử đồ'), findsOneWidget);
      expect(
        find.text('Job ID: ${PreviewScreen.sampleDemoJobId}'),
        findsOneWidget,
      );

      // 4. Advance polling timer -> automatically transitions to ResultScreen (/result/:jobId)
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Kết quả thử trang phục'), findsOneWidget);
      expect(
        find.text('Job ID: ${PreviewScreen.sampleDemoJobId}'),
        findsOneWidget,
      );

      // 5. Tap "Try Again" to return to UploadScreen (/)
      await tester.tap(find.byKey(const Key('result_try_again_button')));
      await tester.pumpAndSettle();
      expect(find.text('Chọn ảnh đầu vào'), findsOneWidget);

      // 6. Navigate to HistoryScreen (/history)
      await tester.tap(find.byKey(const Key('nav_history_button')));
      await tester.pumpAndSettle();
      expect(find.text('Lịch sử đã lưu'), findsOneWidget);

      // 7. Navigate to HistoryDetailScreen (/history/:jobId)
      await tester.tap(find.byKey(const Key('history_open_detail_button')));
      await tester.pumpAndSettle();
      expect(find.text('Chi tiết kết quả đã lưu'), findsOneWidget);

      // 8. Pop back to HistoryScreen
      await tester.tap(find.byKey(const Key('history_detail_back_button')));
      await tester.pumpAndSettle();
      expect(find.text('Lịch sử đã lưu'), findsOneWidget);
    },
  );

  testWidgets(
    'UploadScreen displays user-friendly error message when Backend is unreachable',
    (tester) async {
      const config = AppConfig(baseUrl: 'http://10.0.2.2:8000');
      final failingDio = Dio(BaseOptions(baseUrl: config.baseUrl))
        ..httpClientAdapter = _FakeBackendAdapter(shouldFail: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(config),
            dioProvider.overrideWithValue(failingDio),
          ],
          child: const VirtualOutfitApp(),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('backend_status_error_text')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Không thể kết nối tới máy chủ'),
        findsOneWidget,
      );
    },
  );
}
