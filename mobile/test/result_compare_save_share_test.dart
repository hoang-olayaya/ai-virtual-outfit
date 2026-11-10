import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/core/router/app_router.dart';
import 'package:ai_virtual_outfit/core/services/image_share_service.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_draft_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_result_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

/// Minimal valid 1x1 transparent PNG bytes.
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

SelectedDraftImage _makeDraftImage(String name, {int seed = 1}) {
  final bytes = Uint8List.fromList([..._kSamplePngBytes, seed]);
  return SelectedDraftImage(
    file: XFile.fromData(
      bytes,
      name: name,
      path: '/mock/$name',
      mimeType: 'image/png',
    ),
    bytes: bytes,
    fileName: name,
    sizeBytes: bytes.length,
  );
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

Map<String, dynamic> _jobPayload({
  required String jobId,
  String status = 'succeeded',
  bool isSaved = false,
  String? savedAt,
  Map<String, dynamic>? error,
}) {
  return <String, dynamic>{
    'job_id': jobId,
    'status': status,
    'result_image_url': status == 'succeeded'
        ? '/api/v1/try-ons/$jobId/image'
        : null,
    'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
    'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
    'error': error,
    'is_saved': isSaved,
    'saved_at': savedAt,
    'created_at': '2026-11-11T00:00:00Z',
    'updated_at': '2026-11-11T00:00:05Z',
    'completed_at': status == 'succeeded' ? '2026-11-11T00:00:05Z' : null,
  };
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

void main() {
  const testConfig = AppConfig(
    baseUrl: 'http://10.0.2.2:8000',
    pollingInterval: Duration(milliseconds: 50),
  );

  group('ImageShareService unit & temporary file disk tests (F04 / FR-15)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('f04_share_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test(
      'detects PNG/WebP/JPEG magic headers, writes temp file to disk, and invokes ShareLauncher with local XFile',
      () async {
        // 1. Magic byte format detection
        expect(ImageShareService.detectFormat(_kSamplePngBytes).extension, 'png');
        expect(
          ImageShareService.detectFormat(_kSamplePngBytes).mimeType,
          'image/png',
        );

        final webpBytes = Uint8List.fromList(<int>[
          0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, // RIFF....
          0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x20, // WEBP...
        ]);
        expect(ImageShareService.detectFormat(webpBytes).extension, 'webp');
        expect(ImageShareService.detectFormat(webpBytes).mimeType, 'image/webp');

        final jpegBytes = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0]);
        expect(ImageShareService.detectFormat(jpegBytes).extension, 'jpg');
        expect(ImageShareService.detectFormat(jpegBytes).mimeType, 'image/jpeg');

        // 2. Write temp file and launch share sheet
        ShareParams? capturedParams;
        final service = ImageShareService(
          tempDirectoryProvider: () async => tempRoot,
          shareLauncher: (params) async {
            capturedParams = params;
            return const ShareResult(
              'mock_share_target',
              ShareResultStatus.success,
            );
          },
        );

        final result = await service.shareResultImageBytes(
          _kSamplePngBytes,
          jobId: 'job-share-001',
          text: 'Thử đồ ảo AI',
        );

        expect(result.status, ShareResultStatus.success);
        expect(capturedParams, isNotNull);
        expect(capturedParams!.text, 'Thử đồ ảo AI');
        expect(capturedParams!.files, isNotNull);
        expect(capturedParams!.files!.length, 1);

        final sharedXFile = capturedParams!.files!.first;
        expect(sharedXFile.path, endsWith('try_on_job-share-001.png'));
        expect(sharedXFile.mimeType, 'image/png');

        final diskFile = File(sharedXFile.path);
        expect(diskFile.existsSync(), isTrue);
        expect(diskFile.readAsBytesSync(), equals(_kSamplePngBytes));
      },
    );

    test(
      'throws ImageShareException when image bytes are empty or share sheet fails',
      () async {
        final service = ImageShareService(
          tempDirectoryProvider: () async => tempRoot,
          shareLauncher: (_) async => throw Exception('Platform share error'),
        );

        await expectLater(
          () => service.writeTempResultImage(Uint8List(0), jobId: 'empty-job'),
          throwsA(
            isA<ImageShareException>().having(
              (e) => e.code,
              'code',
              'EMPTY_IMAGE_BYTES',
            ),
          ),
        );

        await expectLater(
          () => service.shareResultImageBytes(
            _kSamplePngBytes,
            jobId: 'fail-share-job',
          ),
          throwsA(
            isA<ImageShareException>().having(
              (e) => e.code,
              'code',
              'SHARE_SHEET_ERROR',
            ),
          ),
        );
      },
    );
  });

  group('TryOnResultController unit tests (F04 & Scenario T11)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('f04_controller_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test(
      'loads result and input comparison images, switches comparison modes, and supports idempotent Save (Scenario T11)',
      () async {
        const jobId = 'f04-unit-job-101';
        var saveCallCount = 0;
        var isSavedOnServer = false;
        Completer<ResponseBody>? pendingSaveCompleter;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId') {
            return _jsonResponse(
              _jobPayload(jobId: jobId, isSaved: isSavedOnServer),
            );
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId/image') {
            return _bytesResponse(_kSamplePngBytes);
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId/inputs/person') {
            return _bytesResponse(Uint8List.fromList([..._kSamplePngBytes, 1]));
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId/inputs/garment') {
            return _bytesResponse(Uint8List.fromList([..._kSamplePngBytes, 2]));
          }
          if (options.method == 'POST' &&
              options.path == '/api/v1/try-ons/$jobId/save') {
            saveCallCount++;
            isSavedOnServer = true;
            final completer = pendingSaveCompleter;
            if (completer != null) {
              return completer.future;
            }
            return _jsonResponse(
              _jobPayload(
                jobId: jobId,
                isSaved: true,
                savedAt: '2026-11-11T00:01:00Z',
              ),
            );
          }
          return _jsonResponse({}, statusCode: 404);
        });

        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(testConfig),
            dioProvider.overrideWithValue(dio),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen(
          tryOnResultControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(sub.close);

        final notifier = container.read(
          tryOnResultControllerProvider(jobId).notifier,
        );
        await notifier.loadResult();

        final loadedState = container.read(tryOnResultControllerProvider(jobId));
        expect(loadedState.isLoadingResult, isFalse);
        expect(loadedState.loadError, isNull);
        expect(loadedState.hasResultImage, isTrue);
        expect(loadedState.hasPersonImage, isTrue);
        expect(loadedState.hasGarmentImage, isTrue);
        expect(loadedState.isSaved, isFalse);

        // Switch comparison modes (FR-09)
        expect(loadedState.comparisonMode, ResultComparisonMode.beforeAfter);
        notifier.setComparisonMode(ResultComparisonMode.resultOnly);
        expect(
          container.read(tryOnResultControllerProvider(jobId)).comparisonMode,
          ResultComparisonMode.resultOnly,
        );
        notifier.setComparisonMode(ResultComparisonMode.allThree);
        expect(
          container.read(tryOnResultControllerProvider(jobId)).comparisonMode,
          ResultComparisonMode.allThree,
        );

        // Save #1 with in-flight double-tap guard
        pendingSaveCompleter = Completer<ResponseBody>();
        final saveFuture1 = notifier.saveToHistory();
        final concurrentSaveFuture = notifier.saveToHistory();
        expect(await concurrentSaveFuture, isNull);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(saveCallCount, 1);

        pendingSaveCompleter.complete(
          _jsonResponse(
            _jobPayload(
              jobId: jobId,
              isSaved: true,
              savedAt: '2026-11-11T00:01:00Z',
            ),
          ),
        );
        pendingSaveCompleter = null;

        final savedJob1 = await saveFuture1;
        expect(savedJob1, isNotNull);
        expect(savedJob1!.isSaved, isTrue);
        expect(
          container.read(tryOnResultControllerProvider(jobId)).isSaved,
          isTrue,
        );
        expect(
          container.read(tryOnResultControllerProvider(jobId)).saveSuccessCount,
          1,
        );

        // Scenario T11: Second save call is idempotent and returns the same saved record
        final savedJob2 = await notifier.saveToHistory();
        expect(savedJob2, isNotNull);
        expect(savedJob2!.isSaved, isTrue);
        expect(savedJob2.savedAt, equals(savedJob1.savedAt));
        expect(saveCallCount, 2);
        expect(
          container.read(tryOnResultControllerProvider(jobId)).saveSuccessCount,
          2,
        );
      },
    );

    test(
      'keeps Save, Share, and Try Again strictly independent when errors occur (Save != Share != Retry)',
      () async {
        const jobId = 'f04-independent-job-202';
        var shouldFailSave = true;
        var shouldFailShare = true;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId') {
            return _jsonResponse(_jobPayload(jobId: jobId));
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId/image') {
            return _bytesResponse(_kSamplePngBytes);
          }
          if (options.method == 'POST' &&
              options.path == '/api/v1/try-ons/$jobId/save') {
            if (shouldFailSave) {
              return _jsonResponse(
                {
                  'error_code': 'DATABASE_ERROR',
                  'message': 'Temporary DB error while saving.',
                },
                statusCode: 503,
              );
            }
            return _jsonResponse(
              _jobPayload(
                jobId: jobId,
                isSaved: true,
                savedAt: '2026-11-11T00:02:00Z',
              ),
            );
          }
          return _jsonResponse({}, statusCode: 404);
        });

        final shareService = ImageShareService(
          tempDirectoryProvider: () async => tempRoot,
          shareLauncher: (_) async {
            if (shouldFailShare) {
              throw const ImageShareException(
                code: 'SHARE_FAILED',
                message: 'Không thể mở bảng chia sẻ thiết bị.',
              );
            }
            return const ShareResult('ok', ShareResultStatus.success);
          },
        );

        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(testConfig),
            dioProvider.overrideWithValue(dio),
            imageShareServiceProvider.overrideWithValue(shareService),
          ],
        );
        addTearDown(container.dispose);

        // Seed draft images to verify Try Again preserves them (FR-10)
        final draftNotifier = container.read(
          tryOnDraftControllerProvider.notifier,
        );
        draftNotifier.setDraftImage(
          TryOnImageSlot.person,
          _makeDraftImage('person_valid.png', seed: 11),
        );
        draftNotifier.setDraftImage(
          TryOnImageSlot.garment,
          _makeDraftImage('garment_valid.png', seed: 22),
        );

        final sub = container.listen(
          tryOnResultControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(sub.close);

        final notifier = container.read(
          tryOnResultControllerProvider(jobId).notifier,
        );
        await notifier.loadResult();

        // 1. Save fails -> sets saveError, but resultImageBytes & fallback draft images remain intact
        final failedSave = await notifier.saveToHistory();
        expect(failedSave, isNull);
        var state = container.read(tryOnResultControllerProvider(jobId));
        expect(state.saveError?.errorCode, ApiErrorCode.databaseError);
        expect(state.hasResultImage, isTrue);
        expect(state.hasPersonImage, isTrue);
        expect(state.shareErrorMessage, isNull);

        // 2. Share fails -> sets shareErrorMessage independently without clearing saveError
        final failedShare = await notifier.shareResult();
        expect(failedShare, isFalse);
        state = container.read(tryOnResultControllerProvider(jobId));
        expect(
          state.shareErrorMessage,
          contains('Không thể mở bảng chia sẻ thiết bị'),
        );
        expect(state.saveError, isNotNull);

        // 3. Share succeeds on retry -> clears shareErrorMessage and writes temp file
        shouldFailShare = false;
        final okShare = await notifier.shareResult();
        expect(okShare, isTrue);
        state = container.read(tryOnResultControllerProvider(jobId));
        expect(state.shareErrorMessage, isNull);
        expect(state.lastSharedFilePath, isNotNull);
        expect(File(state.lastSharedFilePath!).existsSync(), isTrue);

        // 4. Save succeeds on retry -> clears saveError and sets isSaved = true
        shouldFailSave = false;
        final okSave = await notifier.saveToHistory();
        expect(okSave, isNotNull);
        state = container.read(tryOnResultControllerProvider(jobId));
        expect(state.isSaved, isTrue);
        expect(state.saveError, isNull);

        // 5. prepareTryAgain(clearDraft: false) keeps valid draft inputs ready
        notifier.prepareTryAgain(clearDraft: false);
        final draftState = container.read(tryOnDraftControllerProvider);
        expect(draftState.isReady, isTrue);
        expect(draftState.personImage?.fileName, 'person_valid.png');
        expect(draftState.garmentImage?.fileName, 'garment_valid.png');
      },
    );
  });

  group('ResultScreen widget tests (F04 UI, error recovery & navigation)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('f04_widget_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'displays load error card when /image fails, recovers on retry, switches comparison modes, saves, shares, and navigates on Try Again',
      (tester) async {
        const jobId = 'f04-widget-job-303';
        var shouldFailImageDownload = true;
        var isSavedOnServer = false;
        ShareParams? capturedShareParams;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.path == '/health') {
            return _jsonResponse({'status': 'ok', 'app': 'AI Virtual Outfit'});
          }
          if (options.path == '/api/v1/health/ready') {
            return _jsonResponse({
              'status': 'ready',
              'checks': <String, dynamic>{},
            });
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId') {
            return _jsonResponse(
              _jobPayload(jobId: jobId, isSaved: isSavedOnServer),
            );
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId/image') {
            if (shouldFailImageDownload) {
              return _jsonResponse(
                {
                  'error_code': 'IMAGE_NOT_FOUND',
                  'message': 'Result image missing on storage.',
                },
                statusCode: 404,
              );
            }
            return _bytesResponse(_kSamplePngBytes);
          }
          if (options.method == 'GET' &&
              options.path.startsWith('/api/v1/try-ons/$jobId/inputs/')) {
            return _bytesResponse(_kSamplePngBytes);
          }
          if (options.method == 'POST' &&
              options.path == '/api/v1/try-ons/$jobId/save') {
            isSavedOnServer = true;
            return _jsonResponse(
              _jobPayload(
                jobId: jobId,
                isSaved: true,
                savedAt: '2026-11-11T00:05:00Z',
              ),
            );
          }
          return _jsonResponse({}, statusCode: 404);
        });

        final shareService = ImageShareService(
          tempDirectoryProvider: () async => tempRoot,
          shareLauncher: (params) async {
            capturedShareParams = params;
            return const ShareResult('shared_ok', ShareResultStatus.success);
          },
        );

        final router = createAppRouter(
          initialLocation: AppRoutes.resultPath(jobId),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(testConfig),
              dioProvider.overrideWithValue(dio),
              imageShareServiceProvider.overrideWithValue(shareService),
              appRouterProvider.overrideWithValue(router),
            ],
            child: const VirtualOutfitApp(),
          ),
        );

        // Pre-populate draft images in TryOnDraftController to verify Try Again preserves them
        final element = tester.element(find.byType(VirtualOutfitApp));
        final container = ProviderScope.containerOf(element);
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.person,
              _makeDraftImage('keep_person.png', seed: 5),
            );
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.garment,
              _makeDraftImage('keep_garment.png', seed: 6),
            );

        await tester.pumpAndSettle();

        // 1. Initial image download failed -> shows error card with retry button
        expect(find.byKey(const Key('result_load_error_card')), findsOneWidget);
        expect(
          find.textContaining('Mã lỗi: IMAGE_NOT_FOUND'),
          findsOneWidget,
        );

        // 2. Fix image endpoint and tap "Tải lại ảnh kết quả"
        shouldFailImageDownload = false;
        await tester.ensureVisible(
          find.byKey(const Key('result_retry_load_button')),
        );
        await tester.tap(find.byKey(const Key('result_retry_load_button')));
        await tester.pumpAndSettle();

        // 3. Default Before/After comparison view renders both Person (Before) and Result (After)
        expect(
          find.byKey(const Key('comparison_before_after_view')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('result_before_person_image')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);

        // 4. Switch to "Kết quả AI" (Result Only) mode
        await tester.tap(
          find.byKey(const Key('compare_mode_result_only_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('comparison_result_only_view')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);

        // 5. Switch to "Đầy đủ (3 ảnh)" mode
        await tester.tap(
          find.byKey(const Key('compare_mode_all_three_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('comparison_all_three_view')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('result_before_person_image')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('result_input_garment_image')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);

        // 6. Tap "Lưu kết quả" -> shows saved badge & snackbar
        await tester.tap(find.byKey(const Key('result_save_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('result_saved_badge')), findsOneWidget);
        expect(find.text('Đã lưu vào Lịch sử'), findsOneWidget);

        // 7. Tap "Chia sẻ ảnh" -> writes temp file and invokes SharePlus launcher
        await tester.tap(find.byKey(const Key('result_share_button')));
        await tester.pumpAndSettle();
        expect(capturedShareParams, isNotNull);
        expect(capturedShareParams!.files!.single.path, endsWith('.png'));

        // 8. Tap "Thử lại bộ trang phục khác" -> navigates to UploadScreen with valid draft preserved
        await tester.tap(find.byKey(const Key('result_try_again_button')));
        await tester.pumpAndSettle();
        expect(find.text('Chọn ảnh đầu vào'), findsOneWidget);
        expect(find.textContaining('keep_person.png'), findsOneWidget);
        expect(find.textContaining('keep_garment.png'), findsOneWidget);
      },
    );

    testWidgets(
      'displays and dismisses independent Save and Share error banners and supports quick return to PreviewScreen',
      (tester) async {
        const jobId = 'f04-widget-job-404';

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId') {
            return _jsonResponse(_jobPayload(jobId: jobId));
          }
          if (options.method == 'GET' &&
              (options.path == '/api/v1/try-ons/$jobId/image' ||
                  options.path.startsWith('/api/v1/try-ons/$jobId/inputs/'))) {
            return _bytesResponse(_kSamplePngBytes);
          }
          if (options.method == 'POST' &&
              options.path == '/api/v1/try-ons/$jobId/save') {
            return _jsonResponse(
              {
                'error_code': 'STORAGE_UNAVAILABLE',
                'message': 'Storage is temporarily unavailable.',
              },
              statusCode: 503,
            );
          }
          return _jsonResponse({}, statusCode: 404);
        });

        final failingShareService = ImageShareService(
          tempDirectoryProvider: () async => tempRoot,
          shareLauncher: (_) async => throw const ImageShareException(
            code: 'SHARE_ERROR',
            message: 'Thiết bị không hỗ trợ mở bảng chia sẻ lúc này.',
          ),
        );

        final router = createAppRouter(
          initialLocation: AppRoutes.resultPath(jobId),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(testConfig),
              dioProvider.overrideWithValue(dio),
              imageShareServiceProvider.overrideWithValue(failingShareService),
              appRouterProvider.overrideWithValue(router),
            ],
            child: const VirtualOutfitApp(),
          ),
        );

        final element = tester.element(find.byType(VirtualOutfitApp));
        final container = ProviderScope.containerOf(element);
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.person,
              _makeDraftImage('preview_person.png', seed: 7),
            );
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.garment,
              _makeDraftImage('preview_garment.png', seed: 8),
            );

        await tester.pumpAndSettle();

        // 1. Tap Save -> fails with 503 -> displays Save error banner while image remains visible
        await tester.tap(find.byKey(const Key('result_save_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('result_save_error_banner')), findsOneWidget);
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);

        // 2. Tap Share -> fails -> displays Share error banner alongside Save error banner
        await tester.tap(find.byKey(const Key('result_share_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('result_share_error_banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Thiết bị không hỗ trợ mở bảng chia sẻ'),
          findsOneWidget,
        );

        // 3. Dismiss both error banners independently
        await tester.tap(
          find.byKey(const Key('dismiss_result_save_error_button')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('result_save_error_banner')), findsNothing);
        expect(
          find.byKey(const Key('result_share_error_banner')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('dismiss_result_share_error_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('result_share_error_banner')),
          findsNothing,
        );

        // 4. Tap quick Preview swap button in AppBar -> navigates directly to PreviewScreen (/preview)
        await tester.tap(
          find.byKey(const Key('result_try_again_preview_button')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Xem trước ảnh đã chọn'), findsOneWidget);
        expect(find.textContaining('preview_person.png'), findsOneWidget);
        expect(find.textContaining('preview_garment.png'), findsOneWidget);
      },
    );
  });
}

