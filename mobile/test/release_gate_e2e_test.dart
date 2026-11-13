import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/core/services/image_picker_service.dart';
import 'package:ai_virtual_outfit/core/services/image_share_service.dart';
import 'package:ai_virtual_outfit/features/history/application/history_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/job_status_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_draft_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_result_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_submission_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/data/models/job_model.dart';
import 'package:ai_virtual_outfit/features/try_on/data/try_on_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

/// Minimal valid 1x1 transparent PNG bytes used for deterministic UI rendering.
final Uint8List _kValidPngBytes = Uint8List.fromList(<int>[
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

ResponseBody _bytesResponse(
  Uint8List bytes, {
  int statusCode = 200,
  String contentType = 'image/png',
}) {
  return ResponseBody.fromBytes(
    bytes,
    statusCode,
    headers: {
      Headers.contentTypeHeader: [contentType],
      'cache-control': ['private, no-cache, no-store, must-revalidate'],
    },
  );
}

class _ProgrammableAdapter implements HttpClientAdapter {
  _ProgrammableAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// In-memory queue-based fake [ImagePickerService] using [XFile.fromData]
/// so `testWidgets` (`FakeAsync`) never deadlocks on native `dart:io` async streams.
class _FakeQueueImagePickerService extends ImagePickerService {
  final List<Future<XFile?> Function(ImageSource source)> _queue = [];
  int callCount = 0;

  void enqueueMemoryFile(
    String name, {
    Uint8List? bytes,
  }) {
    final data = bytes ?? _kValidPngBytes;
    _queue.add((_) async {
      return XFile.fromData(
        data,
        name: name,
        path: '/mock/$name',
        mimeType: 'image/png',
      );
    });
  }

  @override
  Future<XFile?> pickImage({
    ImageSource source = ImageSource.gallery,
    double? maxWidth = ImagePickerService.defaultMaxDimension,
    double? maxHeight = ImagePickerService.defaultMaxDimension,
    int? imageQuality = ImagePickerService.defaultImageQuality,
  }) {
    callCount++;
    if (_queue.isEmpty) {
      return Future<XFile?>.value(null);
    }
    final next = _queue.removeAt(0);
    return next(source);
  }
}

void main() {
  const testConfig = AppConfig(
    baseUrl: 'http://10.0.2.2:8000',
    pollingInterval: Duration(milliseconds: 40),
    maxPollingDuration: Duration(seconds: 10),
  );

  group('RELEASE GATE (G2 / GATE-FE) — E2E & Failure Scenarios Suite', () {
    testWidgets(
      'E2E-01: Full 6-screen happy path journey (Upload -> Preview -> Processing -> Result -> Save/Share -> History -> Detail -> Delete) covering FR-01..FR-15, T01, T11, T12',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final tempDir = Directory.systemTemp.createTempSync('rg_e2e_01_');
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        final fakePicker = _FakeQueueImagePickerService()
          ..enqueueMemoryFile('person.png')
          ..enqueueMemoryFile('garment_v1.png')
          ..enqueueMemoryFile(
            'garment_v2.png',
            bytes: Uint8List.fromList(<int>[..._kValidPngBytes, 0x00]),
          );

        final sharedPaths = <String>[];
        final fakeShareService = ImageShareService(
          tempDirectoryProvider: () async => tempDir,
          shareLauncher: (ShareParams params) async {
            final files = params.files ?? const <XFile>[];
            sharedPaths.addAll(files.map((f) => f.path));
            return const ShareResult(
              'mock_share_id',
              ShareResultStatus.success,
            );
          },
        );

        const jobId = 'e2e-job-happy-001';
        const fixedSavedAt = '2026-11-12T02:00:00Z';
        var pollCallCount = 0;
        var saveCallCount = 0;
        var isJobSaved = false;
        var isJobDeleted = false;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          final path = options.path;
          final method = options.method;

          if (method == 'GET' && path == '/health') {
            return _jsonResponse({
              'status': 'ok',
              'app': 'AI Virtual Outfit Preview',
              'version': '0.1.0',
              'environment': 'test',
            });
          }
          if (method == 'GET' && path == '/api/v1/health/ready') {
            return _jsonResponse({
              'status': 'ready',
              'checks': {
                'database': 'connected',
                'redis': 'connected',
                'storage': 'writable',
              },
            });
          }
          if (method == 'POST' && path == '/api/v1/try-ons') {
            return _jsonResponse(
              {
                'job_id': jobId,
                'status': 'queued',
                'result_image_url': null,
                'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
                'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
                'error': null,
                'is_saved': false,
                'saved_at': null,
                'created_at': '2026-11-12T01:59:00Z',
                'updated_at': '2026-11-12T01:59:00Z',
                'completed_at': null,
              },
              statusCode: 202,
            );
          }
          if (method == 'GET' && path == '/api/v1/try-ons/$jobId') {
            pollCallCount++;
            final status = pollCallCount == 1 ? 'processing' : 'succeeded';
            return _jsonResponse({
              'job_id': jobId,
              'status': status,
              'result_image_url': status == 'succeeded'
                  ? '/api/v1/try-ons/$jobId/image'
                  : null,
              'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
              'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
              'error': null,
              'is_saved': isJobSaved,
              'saved_at': isJobSaved ? fixedSavedAt : null,
              'created_at': '2026-11-12T01:59:00Z',
              'updated_at': '2026-11-12T01:59:10Z',
              'completed_at':
                  status == 'succeeded' ? '2026-11-12T01:59:10Z' : null,
            });
          }
          if (method == 'GET' &&
              (path == '/api/v1/try-ons/$jobId/image' ||
                  path == '/api/v1/try-ons/$jobId/inputs/person' ||
                  path == '/api/v1/try-ons/$jobId/inputs/garment')) {
            return _bytesResponse(_kValidPngBytes);
          }
          if (method == 'POST' && path == '/api/v1/try-ons/$jobId/save') {
            saveCallCount++;
            isJobSaved = true;
            return _jsonResponse({
              'job_id': jobId,
              'status': 'succeeded',
              'result_image_url': '/api/v1/try-ons/$jobId/image',
              'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
              'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
              'error': null,
              'is_saved': true,
              'saved_at': fixedSavedAt,
              'created_at': '2026-11-12T01:59:00Z',
              'updated_at': fixedSavedAt,
              'completed_at': '2026-11-12T01:59:10Z',
            });
          }
          if (method == 'GET' && path == '/api/v1/history') {
            final items = (isJobSaved && !isJobDeleted)
                ? <Map<String, dynamic>>[
                    {
                      'job_id': jobId,
                      'status': 'succeeded',
                      'person_image_url':
                          '/api/v1/try-ons/$jobId/inputs/person',
                      'garment_image_url':
                          '/api/v1/try-ons/$jobId/inputs/garment',
                      'result_image_url': '/api/v1/try-ons/$jobId/image',
                      'is_saved': true,
                      'saved_at': fixedSavedAt,
                      'created_at': '2026-11-12T01:59:00Z',
                      'completed_at': '2026-11-12T01:59:10Z',
                    },
                  ]
                : <Map<String, dynamic>>[];
            return _jsonResponse({
              'items': items,
              'total': items.length,
              'limit': 20,
              'offset': 0,
            });
          }
          if (method == 'GET' && path == '/api/v1/history/$jobId') {
            if (isJobDeleted || !isJobSaved) {
              return _jsonResponse(
                {
                  'error_code': 'JOB_NOT_FOUND',
                  'message': 'Saved item not found',
                },
                statusCode: 404,
              );
            }
            return _jsonResponse({
              'job_id': jobId,
              'status': 'succeeded',
              'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
              'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
              'result_image_url': '/api/v1/try-ons/$jobId/image',
              'is_saved': true,
              'saved_at': fixedSavedAt,
              'created_at': '2026-11-12T01:59:00Z',
              'completed_at': '2026-11-12T01:59:10Z',
            });
          }
          if (method == 'DELETE' && path == '/api/v1/history/$jobId') {
            isJobDeleted = true;
            return ResponseBody.fromString('', 204);
          }

          return _jsonResponse({}, statusCode: 404);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(testConfig),
              dioProvider.overrideWithValue(dio),
              imagePickerServiceProvider.overrideWithValue(fakePicker),
              imageShareServiceProvider.overrideWithValue(fakeShareService),
            ],
            child: const VirtualOutfitApp(),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Screen 1: UploadScreen (`/`) — Verify FR-05 readiness gate when 0/2 selected
        expect(find.byKey(const Key('backend_status_ok_text')), findsOneWidget);
        final previewBtnInitial = tester.widget<FilledButton>(
          find.byKey(const Key('nav_preview_button')),
        );
        expect(previewBtnInitial.onPressed, isNull);
        expect(find.textContaining('Đã chọn 0/2'), findsOneWidget);

        // FR-01: Pick Person Image
        await tester.tap(find.byKey(const Key('pick_person_gallery_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('person_image_preview')), findsOneWidget);
        expect(find.textContaining('Đã chọn 1/2'), findsOneWidget);

        // FR-02: Pick Garment Image
        await tester.tap(find.byKey(const Key('pick_garment_gallery_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('garment_image_preview')), findsOneWidget);
        expect(find.textContaining('Sẵn sàng thử đồ'), findsOneWidget);

        // Navigate to Screen 2: PreviewScreen (`/preview`)
        await tester.tap(find.byKey(const Key('nav_preview_button')));
        await tester.pumpAndSettle();

        // 2. Screen 2: PreviewScreen — Verify FR-03 side-by-side preview & FR-04 replace image
        expect(find.byKey(const Key('preview_person_image')), findsOneWidget);
        expect(find.byKey(const Key('preview_garment_image')), findsOneWidget);
        expect(find.textContaining('garment_v1.png'), findsOneWidget);

        // FR-04: Replace Garment image on PreviewScreen via bottom sheet
        await tester.tap(
          find.byKey(const Key('preview_replace_garment_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('sheet_pick_gallery_option')));
        await tester.pumpAndSettle();
        expect(find.textContaining('garment_v2.png'), findsOneWidget);

        // FR-06: Submit Try-On job -> Navigates to Screen 3 (`ProcessingScreen`)
        await tester.tap(
          find.byKey(const Key('preview_start_processing_button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));

        // 3. Screen 3: ProcessingScreen (`/processing/:jobId`) — FR-07 status feedback
        // Pump through polling ticks until status == succeeded and auto-navigation to ResultScreen
        await tester.pumpAndSettle(const Duration(milliseconds: 100));

        // 4. Screen 4: ResultScreen (`/result/:jobId`) — FR-08, FR-09, FR-11, FR-15
        expect(
          find.byKey(const Key('comparison_before_after_view')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('result_before_person_image')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);

        // FR-09: Switch comparison modes (`Kết quả AI` & `Đầy đủ (3 ảnh)`)
        await tester.tap(
          find.byKey(const Key('compare_mode_result_only_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('comparison_result_only_view')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('compare_mode_all_three_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('comparison_all_three_view')),
          findsOneWidget,
        );

        // FR-15: Share result image via temp file + share_plus
        await tester.tap(find.byKey(const Key('result_share_button')));
        await tester.pumpAndSettle();
        expect(sharedPaths, hasLength(1));
        expect(File(sharedPaths.first).existsSync(), isTrue);

        // FR-11 & T11: Save result to History twice (verify idempotency)
        await tester.tap(find.byKey(const Key('result_save_button')));
        await tester.pumpAndSettle();
        expect(find.text('Đã lưu Lịch sử'), findsOneWidget);
        expect(saveCallCount, 1);

        await tester.tap(find.byKey(const Key('result_save_button')));
        await tester.pumpAndSettle();
        expect(saveCallCount, 2);

        // Navigate to Screen 5: HistoryScreen (`/history` — FR-12)
        await tester.tap(find.byKey(const Key('result_nav_history_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('history_total_count_badge')),
          findsOneWidget,
        );
        expect(find.text('1 mục'), findsOneWidget);
        expect(
          find.byKey(const Key('history_item_card_$jobId')),
          findsOneWidget,
        );

        // Navigate to Screen 6: HistoryDetailScreen (`/history/:jobId` — FR-13)
        await tester.tap(
          find.byKey(const Key('history_open_detail_button_$jobId')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Chi tiết kết quả đã lưu'), findsOneWidget);
        expect(
          find.byKey(const Key('comparison_before_after_view')),
          findsOneWidget,
        );

        // FR-14 & T12: Delete from HistoryDetailScreen with confirmation dialog
        await tester.tap(find.byKey(const Key('history_detail_delete_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('history_delete_confirm_dialog')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('history_delete_confirm_button')),
        );
        await tester.pumpAndSettle();

        // Automatically pops back to HistoryScreen with empty state (0 mục)
        expect(find.text('0 mục'), findsOneWidget);
      },
    );

    testWidgets(
      'E2E-02: Failure & recovery scenarios (Oversized file T04, Queue 503 T05, Idempotency key reuse T10, Network drop during polling T09, Terminal AI failure + Try Again FR-10/FR-16/NFR-05)',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final fakePicker = _FakeQueueImagePickerService()
          ..enqueueMemoryFile('person.png')
          ..enqueueMemoryFile(
            'oversized.jpg',
            bytes: Uint8List(10 * 1024 * 1024 + 1024), // T04: > 10 MB
          )
          ..enqueueMemoryFile('garment.png');

        final recordedIdempotencyKeys = <String?>[];
        var postAttempt = 0;
        var pollAttemptForFailedJob = 0;
        var pollAttemptForRecoveredJob = 0;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          final path = options.path;
          final method = options.method;

          if (method == 'GET' && path == '/health') {
            return _jsonResponse({
              'status': 'ok',
              'app': 'AI Virtual Outfit Preview',
              'version': '0.1.0',
              'environment': 'test',
            });
          }
          if (method == 'GET' && path == '/api/v1/health/ready') {
            return _jsonResponse({'status': 'ready', 'checks': {}});
          }

          if (method == 'POST' && path == '/api/v1/try-ons') {
            postAttempt++;
            recordedIdempotencyKeys.add(
              options.headers['Idempotency-Key'] as String?,
            );

            // Attempt 1: Simulate T05 (Redis / Queue publish outage -> 503)
            if (postAttempt == 1) {
              return _jsonResponse(
                {
                  'error_code': 'QUEUE_PUBLISH_ERROR',
                  'message': 'Task queue temporarily unavailable.',
                },
                statusCode: 503,
              );
            }

            // Attempt 2: Succeeds with job-fail-01 (which will fail during AI processing)
            if (postAttempt == 2) {
              return _jsonResponse(
                {
                  'job_id': 'job-fail-01',
                  'status': 'queued',
                  'created_at': '2026-11-12T02:00:00Z',
                  'updated_at': '2026-11-12T02:00:00Z',
                },
                statusCode: 202,
              );
            }

            // Attempt 3 (After Try Again): Succeeds with job-recover-02
            return _jsonResponse(
              {
                'job_id': 'job-recover-02',
                'status': 'queued',
                'created_at': '2026-11-12T02:01:00Z',
                'updated_at': '2026-11-12T02:01:00Z',
              },
              statusCode: 202,
            );
          }

          // Polling for job-fail-01:
          // Tick 1 -> Transient network drop (T09)
          // Tick 2 -> Terminal AI_PROVIDER_FAILURE (FR-16)
          if (method == 'GET' && path == '/api/v1/try-ons/job-fail-01') {
            pollAttemptForFailedJob++;
            if (pollAttemptForFailedJob == 1) {
              throw DioException.connectionError(
                requestOptions: options,
                reason: 'Simulated Wi-Fi disconnect during polling (T09)',
              );
            }
            return _jsonResponse({
              'job_id': 'job-fail-01',
              'status': 'failed',
              'error': {
                'error_code': 'AI_PROVIDER_FAILURE',
                'message': 'AI model failed to process garment.',
              },
              'is_saved': false,
              'created_at': '2026-11-12T02:00:00Z',
              'updated_at': '2026-11-12T02:00:10Z',
            });
          }

          // Polling for job-recover-02: Succeeds
          if (method == 'GET' && path == '/api/v1/try-ons/job-recover-02') {
            pollAttemptForRecoveredJob++;
            return _jsonResponse({
              'job_id': 'job-recover-02',
              'status': 'succeeded',
              'result_image_url': '/api/v1/try-ons/job-recover-02/image',
              'person_image_url':
                  '/api/v1/try-ons/job-recover-02/inputs/person',
              'garment_image_url':
                  '/api/v1/try-ons/job-recover-02/inputs/garment',
              'is_saved': false,
              'created_at': '2026-11-12T02:01:00Z',
              'updated_at': '2026-11-12T02:01:05Z',
              'completed_at': '2026-11-12T02:01:05Z',
            });
          }

          if (method == 'GET' &&
              path.contains('/api/v1/try-ons/job-recover-02/')) {
            return _bytesResponse(_kValidPngBytes);
          }

          return _jsonResponse({}, statusCode: 404);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(
                const AppConfig(
                  baseUrl: 'http://10.0.2.2:8000',
                  pollingInterval: Duration(seconds: 30),
                ),
              ),
              dioProvider.overrideWithValue(dio),
              imagePickerServiceProvider.overrideWithValue(fakePicker),
            ],
            child: const VirtualOutfitApp(),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Pick valid Person image
        await tester.tap(find.byKey(const Key('pick_person_gallery_button')));
        await tester.pumpAndSettle();

        // 2. T04: Pick oversized Garment image (> 10 MB) -> Rejected with error banner
        await tester.tap(find.byKey(const Key('pick_garment_gallery_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('draft_error_banner')), findsOneWidget);
        expect(
          find.textContaining('vượt quá giới hạn tối đa 10 MB'),
          findsOneWidget,
        );
        // Readiness gate still locked (1/2)
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('nav_preview_button')))
              .onPressed,
          isNull,
        );

        // 3. Pick valid Garment image -> Ready (2/2) -> Open PreviewScreen
        await tester.tap(find.byKey(const Key('pick_garment_gallery_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav_preview_button')));
        await tester.pumpAndSettle();

        // 4. T05 & T10: First submit hits 503 QUEUE_PUBLISH_ERROR -> Shows banner on PreviewScreen
        await tester.tap(
          find.byKey(const Key('preview_start_processing_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('preview_submission_error_banner')),
          findsOneWidget,
        );

        // Retry submit with same draft images -> Reuses identical Idempotency-Key (T10)!
        await tester.tap(
          find.byKey(const Key('preview_start_processing_button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));

        expect(recordedIdempotencyKeys, hasLength(2));
        expect(recordedIdempotencyKeys[0], isNotNull);
        expect(recordedIdempotencyKeys[1], equals(recordedIdempotencyKeys[0]));

        // 5. T09: On ProcessingScreen (`job-fail-01`), first poll tick hits connection error
        // Verify `network failure != job failed`: warning banner shown, job NOT failed
        expect(
          find.byKey(const Key('processing_network_warning_banner')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('processing_error_card')), findsNothing);

        // 6. Tap "Thử kết nối lại ngay" -> Second poll tick returns terminal `status == failed` (FR-16)
        await tester.tap(
          find.byKey(const Key('processing_retry_poll_button')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('processing_error_card')), findsOneWidget);
        expect(
          find.byKey(const Key('processing_error_code_text')),
          findsOneWidget,
        );
        expect(find.textContaining('AI_PROVIDER_FAILURE'), findsOneWidget);

        // 7. FR-10 & NFR-05: Tap "Thử lại với ảnh đã chọn" -> Returns to PreviewScreen with images intact
        await tester.tap(
          find.byKey(const Key('processing_back_to_preview_button')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('preview_person_image')), findsOneWidget);
        expect(find.byKey(const Key('preview_garment_image')), findsOneWidget);

        // Submit again -> Receives fresh Idempotency-Key and completes `job-recover-02` -> ResultScreen!
        await tester.tap(
          find.byKey(const Key('preview_start_processing_button')),
        );
        await tester.pumpAndSettle();

        expect(recordedIdempotencyKeys, hasLength(3));
        expect(
          recordedIdempotencyKeys[2],
          isNot(equals(recordedIdempotencyKeys[0])),
        );
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);
        expect(pollAttemptForRecoveredJob, greaterThanOrEqualTo(1));
      },
    );

    test(
      'E2E-03: Cold app restart persistence (T11) restores saved History list and all 3 Before/After images in a brand-new ProviderContainer with empty draft state',
      () async {
        const savedJobId = 'persisted-job-t11';
        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' && options.path == '/api/v1/history') {
            return _jsonResponse({
              'items': [
                {
                  'job_id': savedJobId,
                  'status': 'succeeded',
                  'person_image_url':
                      '/api/v1/try-ons/$savedJobId/inputs/person',
                  'garment_image_url':
                      '/api/v1/try-ons/$savedJobId/inputs/garment',
                  'result_image_url': '/api/v1/try-ons/$savedJobId/image',
                  'is_saved': true,
                  'saved_at': '2026-11-12T02:10:00Z',
                  'created_at': '2026-11-12T02:09:00Z',
                  'completed_at': '2026-11-12T02:09:30Z',
                },
              ],
              'total': 1,
              'limit': 20,
              'offset': 0,
            });
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/history/$savedJobId') {
            return _jsonResponse({
              'job_id': savedJobId,
              'status': 'succeeded',
              'person_image_url': '/api/v1/try-ons/$savedJobId/inputs/person',
              'garment_image_url':
                  '/api/v1/try-ons/$savedJobId/inputs/garment',
              'result_image_url': '/api/v1/try-ons/$savedJobId/image',
              'is_saved': true,
              'saved_at': '2026-11-12T02:10:00Z',
              'created_at': '2026-11-12T02:09:00Z',
              'completed_at': '2026-11-12T02:09:30Z',
            });
          }
          if (options.method == 'GET' &&
              options.path.startsWith('/api/v1/try-ons/$savedJobId/')) {
            return _bytesResponse(_kValidPngBytes);
          }
          return _jsonResponse({}, statusCode: 404);
        });

        // Simulate Session 1 disposal (app closed)
        final session1 = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(testConfig),
            dioProvider.overrideWithValue(dio),
          ],
        );
        session1.dispose();

        // Simulate Session 2 (cold app restart with zero RAM state)
        final coldStartContainer = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(testConfig),
            dioProvider.overrideWithValue(dio),
          ],
        );
        addTearDown(coldStartContainer.dispose);

        // Draft state is completely empty after restart
        expect(
          coldStartContainer.read(tryOnDraftControllerProvider).selectedCount,
          0,
        );

        final histSub = coldStartContainer.listen(
          historyControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(histSub.close);

        await coldStartContainer
            .read(historyControllerProvider.notifier)
            .loadInitial();
        final listState = coldStartContainer.read(historyControllerProvider);
        expect(listState.total, 1);
        expect(listState.items.single.jobId, savedJobId);

        final detailSub = coldStartContainer.listen(
          historyDetailControllerProvider(savedJobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(detailSub.close);

        await coldStartContainer
            .read(historyDetailControllerProvider(savedJobId).notifier)
            .loadDetail();
        final detailState = coldStartContainer.read(
          historyDetailControllerProvider(savedJobId),
        );

        expect(detailState.hasResultImage, isTrue);
        expect(detailState.hasPersonImage, isTrue);
        expect(detailState.hasGarmentImage, isTrue);
      },
    );

    test(
      'E2E-04: Architecture & Security Guardrail Audit — UI screens/widgets never import Dio directly and zero secrets exist in mobile/lib/',
      () {
        final libDir = Directory('lib');
        expect(libDir.existsSync(), isTrue);

        final dartFiles = libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();
        expect(dartFiles, isNotEmpty);

        final forbiddenSecretPatterns = <RegExp>[
          RegExp(r'FAL_KEY', caseSensitive: false),
          RegExp(r'sk-[a-zA-Z0-9]{20,}'),
          RegExp(r'postgres_password_dev'),
        ];

        for (final file in dartFiles) {
          final normalizedPath = file.path.replaceAll('\\', '/');
          final rawContent = file.readAsStringSync();
          // Strip comment lines before checking for secret identifiers
          final executableCode = rawContent
              .split('\n')
              .where((line) => !line.trimLeft().startsWith('//'))
              .join('\n');

          // 1. Security check: No secrets or backend credentials in mobile code (NFR-07)
          for (final pattern in forbiddenSecretPatterns) {
            expect(
              pattern.hasMatch(executableCode),
              isFalse,
              reason:
                  'Forbidden secret pattern ${pattern.pattern} found in $normalizedPath',
            );
          }

          // 2. Architecture rule: Presentation layer (screens/widgets) must NEVER import Dio directly
          if (normalizedPath.contains('/presentation/')) {
            expect(
              executableCode.contains("import 'package:dio/dio.dart'"),
              isFalse,
              reason:
                  'Presentation file $normalizedPath must not import Dio directly (violates UI -> Controller -> Repository -> Dio)',
            );
          }
        }
      },
    );

    test(
      'E2E-05: Real TCP Socket Full-Lifecycle E2E (Riverpod Controllers <-> Dio IOHttpClientAdapter <-> Stateful V2 API / Live Backend)',
      () async {
        // Restore real OS socket HttpClient (TestWidgetsFlutterBinding overrides HttpOverrides.global to return 400)
        final previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = previousHttpOverrides;
        });

        HttpServer? loopbackServer;
        late final String targetBaseUrl;

        final configuredLiveUrl =
            Platform.environment['LIVE_API_BASE_URL']?.trim() ?? '';
        if (configuredLiveUrl.isNotEmpty) {
          targetBaseUrl = configuredLiveUrl;
        } else {
          // Spin up a real OS TCP socket server implementing the V2 Backend API contract
          // so Dio's real IOHttpClientAdapter sends actual multipart, JSON, and binary HTTP traffic over TCP.
          loopbackServer = await _startStatefulV2LoopbackServer();
          targetBaseUrl = 'http://127.0.0.1:${loopbackServer.port}';
        }
        addTearDown(() async {
          await loopbackServer?.close(force: true);
        });

        final liveConfig = AppConfig(
          baseUrl: targetBaseUrl,
          pollingInterval: const Duration(milliseconds: 80),
          maxPollingDuration: const Duration(seconds: 30),
        );

        // Create two valid >=64x64 PNG images in memory
        // (Backend UploadValidator requires minimum 64x64 px dimensions).
        final valid64x64Png = _createValidSolidPngBytes(width: 96, height: 128);

        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(liveConfig),
          ],
        );
        addTearDown(container.dispose);

        // 1. Check live Backend health & readiness via TryOnRepository
        final tryOnRepo = container.read(tryOnRepositoryProvider);
        final health = await tryOnRepo.checkHealth();
        expect(health.isHealthy, isTrue);
        final readiness = await tryOnRepo.checkReadiness();
        expect(readiness.isHealthy, isTrue);

        // 2. Populate TryOnDraftController with 2 valid images (FR-01, FR-02, FR-05)
        final draftController = container.read(
          tryOnDraftControllerProvider.notifier,
        );
        draftController.setDraftImage(
          TryOnImageSlot.person,
          SelectedDraftImage(
            file: XFile.fromData(
              valid64x64Png,
              name: 'live_person.png',
              path: '/live/live_person.png',
              mimeType: 'image/png',
            ),
            bytes: valid64x64Png,
            fileName: 'live_person.png',
            sizeBytes: valid64x64Png.length,
          ),
        );
        draftController.setDraftImage(
          TryOnImageSlot.garment,
          SelectedDraftImage(
            file: XFile.fromData(
              valid64x64Png,
              name: 'live_garment.png',
              path: '/live/live_garment.png',
              mimeType: 'image/png',
            ),
            bytes: valid64x64Png,
            fileName: 'live_garment.png',
            sizeBytes: valid64x64Png.length,
          ),
        );
        expect(container.read(tryOnDraftControllerProvider).isReady, isTrue);

        // 3. Submit Try-On job via TryOnSubmissionController (POST /api/v1/try-ons -> 202)
        final submittedJob = await container
            .read(tryOnSubmissionControllerProvider.notifier)
            .submitDraft();
        expect(submittedJob, isNotNull);
        final jobId = submittedJob!.jobId;
        expect(jobId, isNotEmpty);

        // 4. Poll via JobStatusController until Celery Worker completes the job (`succeeded`)
        final pollSub = container.listen(
          jobStatusControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(pollSub.close);

        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (DateTime.now().isBefore(deadline)) {
          final statusState = container.read(jobStatusControllerProvider(jobId));
          if (statusState.isTerminal) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        final finalStatus = container.read(jobStatusControllerProvider(jobId));
        expect(
          finalStatus.isSucceeded,
          isTrue,
          reason:
              'Expected live job $jobId to succeed, got status=${finalStatus.effectiveStatus} error=${finalStatus.effectiveErrorMessage}',
        );
        expect(finalStatus.job?.status, JobStatus.succeeded);

        // 5. Load Result & Before/After images via TryOnResultController + Save Idempotently (T11)
        final resultSub = container.listen(
          tryOnResultControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(resultSub.close);

        await container
            .read(tryOnResultControllerProvider(jobId).notifier)
            .loadResult();
        final resultState = container.read(tryOnResultControllerProvider(jobId));
        expect(resultState.hasResultImage, isTrue);
        expect(resultState.hasPersonImage, isTrue);
        expect(resultState.hasGarmentImage, isTrue);

        final savedFirst = await container
            .read(tryOnResultControllerProvider(jobId).notifier)
            .saveToHistory();
        expect(savedFirst, isNotNull);
        expect(savedFirst!.isSaved, isTrue);
        expect(savedFirst.savedAt, isNotNull);

        final savedSecond = await container
            .read(tryOnResultControllerProvider(jobId).notifier)
            .saveToHistory();
        expect(savedSecond, isNotNull);
        expect(savedSecond!.savedAt, equals(savedFirst.savedAt));

        // 6. Cold Restart Simulation: New ProviderContainer fetches History & Detail from live PostgreSQL
        final coldContainer = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(liveConfig),
          ],
        );
        addTearDown(coldContainer.dispose);

        final histSub = coldContainer.listen(
          historyControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(histSub.close);

        await coldContainer
            .read(historyControllerProvider.notifier)
            .loadInitial();
        final historyList = coldContainer.read(historyControllerProvider);
        expect(
          historyList.items.any((item) => item.jobId == jobId),
          isTrue,
        );

        final detailSub = coldContainer.listen(
          historyDetailControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(detailSub.close);

        await coldContainer
            .read(historyDetailControllerProvider(jobId).notifier)
            .loadDetail();
        final detailState = coldContainer.read(
          historyDetailControllerProvider(jobId),
        );
        expect(detailState.hasResultImage, isTrue);
        expect(detailState.hasPersonImage, isTrue);
        expect(detailState.hasGarmentImage, isTrue);

        // 7. Delete from History via HistoryDetailController (DELETE /api/v1/history/{id} -> 204)
        final deleted = await coldContainer
            .read(historyDetailControllerProvider(jobId).notifier)
            .deleteFromHistory();
        expect(deleted, isTrue);
        expect(
          coldContainer
              .read(historyControllerProvider)
              .items
              .any((item) => item.jobId == jobId),
          isFalse,
        );
      },
    );
  });
}

/// Generates a valid PNG image of [width] x [height] (>= 64x64 px) in memory
/// using standard zlib-compressed IDAT chunks so Backend Pillow `UploadValidator`
/// accepts it without external native dependencies.
Uint8List _createValidSolidPngBytes({
  required int width,
  required int height,
}) {
  // Each scanline starts with filter byte 0, followed by RGB (3 bytes per pixel)
  final rawScanlines = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    rawScanlines.addByte(0); // Filter type 0 (None)
    for (var x = 0; x < width; x++) {
      rawScanlines.addByte(79); // R
      rawScanlines.addByte(70); // G
      rawScanlines.addByte(229); // B
    }
  }
  final compressedIdat = zlib.encode(rawScanlines.toBytes());

  final png = BytesBuilder(copy: false);
  // PNG Signature
  png.add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  // IHDR chunk (13 bytes)
  final ihdr = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8) // bit depth 8
    ..setUint8(9, 2) // color type 2 (Truecolor RGB)
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter
    ..setUint8(12, 0); // interlace
  _writePngChunk(png, 'IHDR', ihdr.buffer.asUint8List());

  // IDAT chunk
  _writePngChunk(png, 'IDAT', Uint8List.fromList(compressedIdat));

  // IEND chunk
  _writePngChunk(png, 'IEND', Uint8List(0));

  return png.toBytes();
}

void _writePngChunk(BytesBuilder out, String type, Uint8List data) {
  final lenBytes = ByteData(4)..setUint32(0, data.length, Endian.big);
  out.add(lenBytes.buffer.asUint8List());

  final typeBytes = ascii.encode(type);
  out.add(typeBytes);
  out.add(data);

  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  final crc = _crc32(crcInput);
  final crcBytes = ByteData(4)..setUint32(0, crc, Endian.big);
  out.add(crcBytes.buffer.asUint8List());
}

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      if ((crc & 1) != 0) {
        crc = (crc >>> 1) ^ 0xEDB88320;
      } else {
        crc = crc >>> 1;
      }
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Starts a real OS TCP loopback [HttpServer] implementing the stateful V2 Backend API contract
/// so `DioClient` (`IOHttpClientAdapter`) executes real socket HTTP requests across the full
/// 10-step E2E lifecycle.
Future<HttpServer> _startStatefulV2LoopbackServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final idempotencyToJobId = <String, String>{};
  final jobs = <String, Map<String, dynamic>>{};
  final pollCounts = <String, int>{};
  var jobCounter = 0;

  server.listen((HttpRequest request) async {
    final method = request.method;
    final path = request.uri.path;

    // Drain request body bytes (including multipart uploads)
    await request.drain<void>();

    void sendJson(int statusCode, Map<String, dynamic> body) {
      request.response
        ..statusCode = statusCode
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
    }

    if (method == 'GET' && path == '/health') {
      sendJson(HttpStatus.ok, {
        'status': 'ok',
        'app': 'AI Virtual Outfit Preview',
        'version': '0.1.0',
        'environment': 'test',
      });
      await request.response.close();
      return;
    }

    if (method == 'GET' && path == '/api/v1/health/ready') {
      sendJson(HttpStatus.ok, {
        'status': 'ready',
        'checks': {
          'database': 'connected',
          'redis': 'connected',
          'storage': 'writable',
        },
      });
      await request.response.close();
      return;
    }

    if (method == 'POST' && path == '/api/v1/try-ons') {
      final idempKey = request.headers.value('Idempotency-Key') ?? '';
      if (idempKey.isNotEmpty && idempotencyToJobId.containsKey(idempKey)) {
        final existingId = idempotencyToJobId[idempKey]!;
        sendJson(HttpStatus.accepted, jobs[existingId]!);
        await request.response.close();
        return;
      }

      jobCounter++;
      final jobId = 'tcp-live-job-000$jobCounter';
      final nowIso = DateTime.now().toUtc().toIso8601String();
      final jobRecord = <String, dynamic>{
        'job_id': jobId,
        'status': 'queued',
        'result_image_url': null,
        'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
        'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
        'error': null,
        'is_saved': false,
        'saved_at': null,
        'created_at': nowIso,
        'updated_at': nowIso,
        'completed_at': null,
      };
      jobs[jobId] = jobRecord;
      pollCounts[jobId] = 0;
      if (idempKey.isNotEmpty) {
        idempotencyToJobId[idempKey] = jobId;
      }
      sendJson(HttpStatus.accepted, jobRecord);
      await request.response.close();
      return;
    }

    final jobMatch = RegExp(r'^/api/v1/try-ons/([^/]+)$').firstMatch(path);
    if (method == 'GET' && jobMatch != null) {
      final jobId = jobMatch.group(1)!;
      final job = jobs[jobId];
      if (job == null) {
        sendJson(HttpStatus.notFound, {
          'error_code': 'JOB_NOT_FOUND',
          'message': 'Job not found',
        });
        await request.response.close();
        return;
      }

      final count = (pollCounts[jobId] ?? 0) + 1;
      pollCounts[jobId] = count;
      if (count == 1) {
        job['status'] = 'processing';
      } else {
        job['status'] = 'succeeded';
        job['result_image_url'] = '/api/v1/try-ons/$jobId/image';
        job['completed_at'] ??= DateTime.now().toUtc().toIso8601String();
      }
      job['updated_at'] = DateTime.now().toUtc().toIso8601String();

      sendJson(HttpStatus.ok, job);
      await request.response.close();
      return;
    }

    final mediaMatch = RegExp(
      r'^/api/v1/try-ons/([^/]+)/(image|inputs/person|inputs/garment)$',
    ).firstMatch(path);
    if (method == 'GET' && mediaMatch != null) {
      final jobId = mediaMatch.group(1)!;
      if (!jobs.containsKey(jobId)) {
        sendJson(HttpStatus.notFound, {
          'error_code': 'JOB_NOT_FOUND',
          'message': 'Job not found',
        });
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('image', 'png')
        ..headers.set(
          'cache-control',
          'private, no-cache, no-store, must-revalidate',
        )
        ..add(_kValidPngBytes);
      await request.response.close();
      return;
    }

    final saveMatch = RegExp(r'^/api/v1/try-ons/([^/]+)/save$').firstMatch(path);
    if (method == 'POST' && saveMatch != null) {
      final jobId = saveMatch.group(1)!;
      final job = jobs[jobId];
      if (job == null) {
        sendJson(HttpStatus.notFound, {
          'error_code': 'JOB_NOT_FOUND',
          'message': 'Job not found',
        });
        await request.response.close();
        return;
      }
      job['is_saved'] = true;
      job['saved_at'] ??= '2026-11-12T03:00:00Z';
      sendJson(HttpStatus.ok, job);
      await request.response.close();
      return;
    }

    if (method == 'GET' && path == '/api/v1/history') {
      final savedList = jobs.values
          .where((j) => j['is_saved'] == true)
          .toList();
      sendJson(HttpStatus.ok, {
        'items': savedList,
        'total': savedList.length,
        'limit': 20,
        'offset': 0,
      });
      await request.response.close();
      return;
    }

    final histDetailMatch =
        RegExp(r'^/api/v1/history/([^/]+)$').firstMatch(path);
    if (histDetailMatch != null) {
      final jobId = histDetailMatch.group(1)!;
      final job = jobs[jobId];
      if (method == 'GET') {
        if (job == null || job['is_saved'] != true) {
          sendJson(HttpStatus.notFound, {
            'error_code': 'JOB_NOT_FOUND',
            'message': 'Saved item not found',
          });
        } else {
          sendJson(HttpStatus.ok, job);
        }
        await request.response.close();
        return;
      }
      if (method == 'DELETE') {
        if (job == null || job['is_saved'] != true) {
          sendJson(HttpStatus.notFound, {
            'error_code': 'JOB_NOT_FOUND',
            'message': 'Saved item not found',
          });
        } else {
          jobs.remove(jobId);
          request.response.statusCode = HttpStatus.noContent;
        }
        await request.response.close();
        return;
      }
    }

    sendJson(HttpStatus.notFound, {
      'error_code': 'INVALID_REQUEST',
      'message': 'Endpoint not found',
    });
    await request.response.close();
  });

  return server;
}
