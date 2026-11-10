import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/features/try_on/presentation/screens/preview_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackendAdapter implements HttpClientAdapter {
  _FakeBackendAdapter({this.shouldFail = false});

  final bool shouldFail;

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

    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets(
    'App Shell renders UploadScreen, verifies Backend health, and navigates across all 6 go_router screens',
    (tester) async {
      const config = AppConfig(baseUrl: 'http://10.0.2.2:8000');
      final mockDio = Dio(BaseOptions(baseUrl: config.baseUrl))
        ..httpClientAdapter = _FakeBackendAdapter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(config),
            dioProvider.overrideWithValue(mockDio),
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

      // 2. Navigate to PreviewScreen (/preview)
      await tester.tap(find.byKey(const Key('nav_preview_button')));
      await tester.pumpAndSettle();
      expect(find.text('Xem trước ảnh đã chọn'), findsOneWidget);

      // 3. Navigate to ProcessingScreen (/processing/:jobId)
      // Note: ProcessingScreen contains an indeterminate CircularProgressIndicator,
      // so we advance frames explicitly with pump() instead of pumpAndSettle().
      await tester.tap(
        find.byKey(const Key('preview_start_processing_button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Đang tạo ảnh thử đồ'), findsOneWidget);
      expect(
        find.text('Job ID: ${PreviewScreen.sampleDemoJobId}'),
        findsOneWidget,
      );

      // 4. Navigate to ResultScreen (/result/:jobId)
      await tester.tap(find.byKey(const Key('processing_to_result_button')));
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

