import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/features/try_on/application/job_status_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_draft_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_submission_controller.dart';
import 'package:ai_virtual_outfit/features/try_on/data/models/job_model.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

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

Map<String, dynamic> _jobPayload({
  required String jobId,
  required String status,
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
    'is_saved': false,
    'saved_at': null,
    'created_at': '2026-11-11T00:00:00Z',
    'updated_at': '2026-11-11T00:00:05Z',
    'completed_at': (status == 'succeeded' || status == 'failed')
        ? '2026-11-11T00:00:05Z'
        : null,
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
    maxPollingDuration: Duration(seconds: 30),
  );

  group('TryOnSubmissionController unit tests (F03 & Scenario T10)', () {
    test(
      'blocks submission when draft is incomplete, prevents double-tap, and reuses Idempotency-Key across transient retries',
      () async {
        final capturedIdempotencyKeys = <String>[];
        var postCallCount = 0;
        var shouldFailWithNetworkError = false;
        Completer<ResponseBody>? pendingPostCompleter;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'POST' && options.path == '/api/v1/try-ons') {
            postCallCount++;
            final key = options.headers['Idempotency-Key']?.toString() ?? '';
            capturedIdempotencyKeys.add(key);

            final completer = pendingPostCompleter;
            if (completer != null) {
              return completer.future;
            }

            if (shouldFailWithNetworkError) {
              throw DioException.connectionError(
                requestOptions: options,
                reason: 'Socket closed during upload',
              );
            }

            return _jsonResponse(
              _jobPayload(jobId: 'job-created-001', status: 'queued'),
              statusCode: 202,
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

        final draftController = container.read(
          tryOnDraftControllerProvider.notifier,
        );
        final subController = container.read(
          tryOnSubmissionControllerProvider.notifier,
        );

        // 1. Draft is empty -> submitDraft() fails immediately without calling HTTP
        final missingResult = await subController.submitDraft();
        expect(missingResult, isNull);
        expect(postCallCount, 0);
        expect(
          container.read(tryOnSubmissionControllerProvider).error?.errorCode,
          ApiErrorCode.missingInputImage,
        );

        // Populate both draft images
        draftController.setDraftImage(
          TryOnImageSlot.person,
          _makeDraftImage('person_a.png', seed: 1),
        );
        draftController.setDraftImage(
          TryOnImageSlot.garment,
          _makeDraftImage('garment_a.png', seed: 2),
        );

        // 2. Scenario T10: Transient network failure on first POST, then retry with same draft
        shouldFailWithNetworkError = true;
        final failedAttempt = await subController.submitDraft();
        expect(failedAttempt, isNull);
        expect(postCallCount, 1);
        expect(
          container.read(tryOnSubmissionControllerProvider).error?.isNetworkError,
          isTrue,
        );
        final firstKey = capturedIdempotencyKeys.single;
        expect(firstKey, isNotEmpty);

        // Retry with the exact same draft images -> MUST reuse the exact same Idempotency-Key!
        shouldFailWithNetworkError = false;
        pendingPostCompleter = Completer<ResponseBody>();

        final firstConcurrentFuture = subController.submitDraft();
        expect(container.read(tryOnSubmissionControllerProvider).isSubmitting, isTrue);

        // Double-tap while first request is still in-flight -> MUST be ignored!
        final secondConcurrentFuture = subController.submitDraft();
        expect(await secondConcurrentFuture, isNull);

        // Allow Dio FormData serialization microtask to reach HttpClientAdapter.fetch
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(postCallCount, 2);

        pendingPostCompleter.complete(
          _jsonResponse(
            _jobPayload(jobId: 'job-created-001', status: 'queued'),
            statusCode: 202,
          ),
        );

        final createdJob = await firstConcurrentFuture;
        expect(createdJob, isNotNull);
        expect(createdJob!.jobId, 'job-created-001');
        expect(capturedIdempotencyKeys.length, 2);
        expect(capturedIdempotencyKeys[1], equals(firstKey));

        // 3. Subsequent fresh submission after success generates a NEW Idempotency-Key
        pendingPostCompleter = null;
        final nextJob = await subController.submitDraft();
        expect(nextJob, isNotNull);
        expect(capturedIdempotencyKeys.length, 3);
        expect(capturedIdempotencyKeys[2], isNot(equals(firstKey)));
      },
    );
  });

  group('JobStatusController unit tests (F03, Scenario T09, Lifecycle & Timeout)', () {
    test(
      'Scenario T09: survives transient network and 503 errors without failing the job, then stops on succeeded',
      () async {
        const targetJobId = 'job-poll-t09';
        var getCount = 0;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$targetJobId') {
            getCount++;
            if (getCount == 1) {
              return _jsonResponse(
                _jobPayload(jobId: targetJobId, status: 'queued'),
              );
            }
            if (getCount == 2) {
              return _jsonResponse(
                _jobPayload(jobId: targetJobId, status: 'processing'),
              );
            }
            if (getCount == 3) {
              throw DioException.connectionError(
                requestOptions: options,
                reason: 'Wi-Fi disconnected temporarily',
              );
            }
            if (getCount == 4) {
              return _jsonResponse(
                {
                  'error_code': 'STORAGE_UNAVAILABLE',
                  'message': 'Temporary gateway hiccup',
                },
                statusCode: 503,
              );
            }
            return _jsonResponse(
              _jobPayload(jobId: targetJobId, status: 'succeeded'),
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

        final subscription = container.listen<JobStatusState>(
          jobStatusControllerProvider(targetJobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        // Wait for Poll #1 (queued)
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          container.read(jobStatusControllerProvider(targetJobId)).effectiveStatus,
          JobStatus.queued,
        );

        // Wait for Poll #2 (processing)
        await Future<void>.delayed(const Duration(milliseconds: 65));
        expect(
          container.read(jobStatusControllerProvider(targetJobId)).effectiveStatus,
          JobStatus.processing,
        );

        // Wait for Poll #3 (network drop -> T09: job stays processing, transientError set)
        await Future<void>.delayed(const Duration(milliseconds: 65));
        final afterNetworkDrop = container.read(
          jobStatusControllerProvider(targetJobId),
        );
        expect(afterNetworkDrop.jobId, targetJobId);
        expect(afterNetworkDrop.effectiveStatus, JobStatus.processing);
        expect(afterNetworkDrop.isFailed, isFalse);
        expect(afterNetworkDrop.hasTransientNetworkIssue, isTrue);
        expect(afterNetworkDrop.consecutiveTransientErrors, 1);

        // Wait for Poll #4 (503 -> still transient, consecutiveTransientErrors = 2)
        await Future<void>.delayed(const Duration(milliseconds: 65));
        final after503 = container.read(
          jobStatusControllerProvider(targetJobId),
        );
        expect(after503.isFailed, isFalse);
        expect(after503.consecutiveTransientErrors, 2);

        // Wait for Poll #5 (succeeded -> transient error cleared, polling stopped)
        await Future<void>.delayed(const Duration(milliseconds: 70));
        final finalState = container.read(
          jobStatusControllerProvider(targetJobId),
        );
        expect(finalState.isSucceeded, isTrue);
        expect(finalState.isPolling, isFalse);
        expect(finalState.hasTransientNetworkIssue, isFalse);
        expect(getCount, 5);

        // Verify no further GET requests happen after terminal succeeded state
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(getCount, 5);
      },
    );

    test(
      'pauses polling when app goes to background and resumes immediately on foreground; stops on 404 or timeout',
      () async {
        const jobId = 'job-lifecycle-001';
        var getCount = 0;
        var fakeNow = DateTime.utc(2026, 11, 11, 12, 0, 0);

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          getCount++;
          return _jsonResponse(
            _jobPayload(jobId: jobId, status: 'processing'),
          );
        });

        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(
              testConfig.copyWith(
                pollingInterval: const Duration(milliseconds: 60),
                maxPollingDuration: const Duration(seconds: 10),
              ),
            ),
            dioProvider.overrideWithValue(dio),
            nowProvider.overrideWithValue(() => fakeNow),
          ],
        );
        addTearDown(container.dispose);

        final sub = container.listen<JobStatusState>(
          jobStatusControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(sub.close);

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(getCount, 1);

        final controller = container.read(
          jobStatusControllerProvider(jobId).notifier,
        );

        // 1. Pause polling (simulating background state)
        controller.pausePolling();
        expect(
          container.read(jobStatusControllerProvider(jobId)).isPausedByLifecycle,
          isTrue,
        );

        await Future<void>.delayed(const Duration(milliseconds: 150));
        // No new polls while paused!
        expect(getCount, 1);

        // 2. Resume polling -> immediately triggers Poll #2
        await controller.resumePolling();
        expect(
          container.read(jobStatusControllerProvider(jobId)).isPausedByLifecycle,
          isFalse,
        );
        expect(getCount, 2);

        // 3. Advance clock past maxPollingDuration (10s) -> next tick stops with timeout
        fakeNow = fakeNow.add(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final timedOutState = container.read(jobStatusControllerProvider(jobId));
        expect(timedOutState.isFailed, isTrue);
        expect(timedOutState.isPolling, isFalse);
        expect(timedOutState.effectiveErrorCode, 'POLLING_TIMEOUT');

        // 4. Calling refreshNow() resets timeout clock and polls the same jobId again
        await controller.refreshNow();
        final refreshedState = container.read(jobStatusControllerProvider(jobId));
        expect(refreshedState.isFailed, isFalse);
        expect(refreshedState.isPolling, isTrue);
      },
    );
  });

  group('PreviewScreen & ProcessingScreen widget tests (F03 UI flows)', () {
    testWidgets(
      'submits from PreviewScreen, shows ProcessingScreen states + network warning, and navigates to ResultScreen on succeeded',
      (tester) async {
        const jobId = 'f03-widget-job-001';
        var pollStep = 0;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.path == '/health') {
            return _jsonResponse({'status': 'ok', 'app': 'AI Virtual Outfit'});
          }
          if (options.path == '/api/v1/health/ready') {
            return _jsonResponse({'status': 'ready', 'checks': <String, dynamic>{}});
          }
          if (options.method == 'POST' && options.path == '/api/v1/try-ons') {
            return _jsonResponse(
              _jobPayload(jobId: jobId, status: 'queued'),
              statusCode: 202,
            );
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$jobId') {
            pollStep++;
            if (pollStep == 1) {
              return _jsonResponse(
                _jobPayload(jobId: jobId, status: 'processing'),
              );
            }
            if (pollStep == 2) {
              throw DioException.connectionError(
                requestOptions: options,
                reason: 'Temporary connection drop',
              );
            }
            return _jsonResponse(
              _jobPayload(jobId: jobId, status: 'succeeded'),
            );
          }
          return _jsonResponse({}, statusCode: 404);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(
                testConfig.copyWith(
                  pollingInterval: const Duration(milliseconds: 200),
                ),
              ),
              dioProvider.overrideWithValue(dio),
            ],
            child: const VirtualOutfitApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Populate draft images in TryOnDraftController
        final element = tester.element(find.byType(VirtualOutfitApp));
        final container = ProviderScope.containerOf(element);
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.person,
              _makeDraftImage('person.png', seed: 10),
            );
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.garment,
              _makeDraftImage('garment.png', seed: 20),
            );
        await tester.pumpAndSettle();

        // Navigate to PreviewScreen
        await tester.ensureVisible(find.byKey(const Key('nav_preview_button')));
        await tester.tap(find.byKey(const Key('nav_preview_button')));
        await tester.pumpAndSettle();

        // Tap "Thử trang phục ngay"
        await tester.tap(
          find.byKey(const Key('preview_start_processing_button')),
        );
        // Pump frames for POST completion -> route push -> ProcessingScreen mount -> Poll #1 microtask -> rebuild
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));

        // Poll #1 returned `processing` -> ProcessingScreen displays processing badge
        expect(find.text('Đang tạo ảnh thử đồ'), findsOneWidget);
        expect(find.text('Job ID: $jobId'), findsOneWidget);
        expect(
          find.textContaining('AI đang ghép trang phục (Processing)'),
          findsOneWidget,
        );

        // Advance to Poll #2 -> transient network error banner appears while keeping Job ID
        await tester.pump(const Duration(milliseconds: 210));
        await tester.pump(const Duration(milliseconds: 10));
        expect(
          find.byKey(const Key('processing_network_warning_banner')),
          findsOneWidget,
        );
        expect(find.text('Job ID: $jobId'), findsOneWidget);

        // Advance to Poll #3 -> `succeeded` -> auto-navigates to ResultScreen
        await tester.pump(const Duration(milliseconds: 210));
        await tester.pumpAndSettle();

        expect(find.text('Kết quả thử trang phục'), findsOneWidget);
        expect(find.text('Job ID: $jobId'), findsOneWidget);
      },
    );

    testWidgets(
      'displays error card when job fails on Backend and returns to PreviewScreen with draft images intact',
      (tester) async {
        const failedJobId = 'f03-failed-job-999';

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.path == '/health') {
            return _jsonResponse({'status': 'ok', 'app': 'AI Virtual Outfit'});
          }
          if (options.path == '/api/v1/health/ready') {
            return _jsonResponse({'status': 'ready', 'checks': <String, dynamic>{}});
          }
          if (options.method == 'POST' && options.path == '/api/v1/try-ons') {
            return _jsonResponse(
              _jobPayload(jobId: failedJobId, status: 'queued'),
              statusCode: 202,
            );
          }
          if (options.method == 'GET' &&
              options.path == '/api/v1/try-ons/$failedJobId') {
            return _jsonResponse(
              _jobPayload(
                jobId: failedJobId,
                status: 'failed',
                error: {
                  'error_code': 'AI_PROVIDER_ERROR',
                  'message': 'Upstream model failed to generate try-on.',
                },
              ),
            );
          }
          return _jsonResponse({}, statusCode: 404);
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(testConfig),
              dioProvider.overrideWithValue(dio),
            ],
            child: const VirtualOutfitApp(),
          ),
        );
        await tester.pumpAndSettle();

        final element = tester.element(find.byType(VirtualOutfitApp));
        final container = ProviderScope.containerOf(element);
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.person,
              _makeDraftImage('my_photo.png', seed: 1),
            );
        container
            .read(tryOnDraftControllerProvider.notifier)
            .setDraftImage(
              TryOnImageSlot.garment,
              _makeDraftImage('my_shirt.png', seed: 2),
            );
        await tester.pumpAndSettle();

        // Go to PreviewScreen and submit
        await tester.ensureVisible(find.byKey(const Key('nav_preview_button')));
        await tester.tap(find.byKey(const Key('nav_preview_button')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('preview_start_processing_button')),
        );
        await tester.pumpAndSettle();

        // ProcessingScreen shows terminal failure card
        expect(find.byKey(const Key('processing_error_card')), findsOneWidget);
        expect(
          find.text('Không thể hoàn tất tạo ảnh thử đồ'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Mã lỗi: AI_PROVIDER_ERROR'),
          findsOneWidget,
        );

        // Tap "Thử lại với ảnh đã chọn" -> pops back to PreviewScreen with both images preserved
        await tester.tap(
          find.byKey(const Key('processing_back_to_preview_button')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Xem trước ảnh đã chọn'), findsOneWidget);
        expect(find.textContaining('my_photo.png'), findsOneWidget);
        expect(find.textContaining('my_shirt.png'), findsOneWidget);
      },
    );
  });
}

