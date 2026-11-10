import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/api_error.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/core/router/app_router.dart';
import 'package:ai_virtual_outfit/core/services/image_share_service.dart';
import 'package:ai_virtual_outfit/features/history/application/history_controller.dart';
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

Map<String, dynamic> _historyItemPayload({
  required String jobId,
  String savedAt = '2026-11-11T01:00:00Z',
}) {
  return <String, dynamic>{
    'job_id': jobId,
    'status': 'succeeded',
    'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
    'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
    'result_image_url': '/api/v1/try-ons/$jobId/image',
    'is_saved': true,
    'saved_at': savedAt,
    'created_at': '2026-11-11T00:59:00Z',
    'completed_at': '2026-11-11T00:59:30Z',
  };
}

Map<String, dynamic> _jobPayload({
  required String jobId,
  bool isSaved = false,
  String? savedAt,
}) {
  return <String, dynamic>{
    'job_id': jobId,
    'status': 'succeeded',
    'result_image_url': '/api/v1/try-ons/$jobId/image',
    'person_image_url': '/api/v1/try-ons/$jobId/inputs/person',
    'garment_image_url': '/api/v1/try-ons/$jobId/inputs/garment',
    'error': null,
    'is_saved': isSaved,
    'saved_at': savedAt,
    'created_at': '2026-11-11T00:59:00Z',
    'updated_at': '2026-11-11T01:00:00Z',
    'completed_at': '2026-11-11T00:59:30Z',
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
  const testConfig = AppConfig(baseUrl: 'http://10.0.2.2:8000');

  group('HistoryController & HistoryDetailController unit tests (F05)', () {
    test(
      'supports paginated loading (limit/offset/hasMore), loadMore error recovery, and thumbnail caching',
      () async {
        final serverItems = <Map<String, dynamic>>[
          _historyItemPayload(
            jobId: 'hist-job-001',
            savedAt: '2026-11-11T01:03:00Z',
          ),
          _historyItemPayload(
            jobId: 'hist-job-002',
            savedAt: '2026-11-11T01:02:00Z',
          ),
          _historyItemPayload(
            jobId: 'hist-job-003',
            savedAt: '2026-11-11T01:01:00Z',
          ),
        ];
        var shouldFailPageTwo = true;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' && options.path == '/api/v1/history') {
            final limit = (options.queryParameters['limit'] as int?) ?? 20;
            final offset = (options.queryParameters['offset'] as int?) ?? 0;

            if (offset > 0 && shouldFailPageTwo) {
              return _jsonResponse(
                {
                  'error_code': 'DATABASE_ERROR',
                  'message': 'Temporary DB timeout on page 2.',
                },
                statusCode: 503,
              );
            }

            final pageSlice = serverItems.skip(offset).take(limit).toList();
            return _jsonResponse({
              'items': pageSlice,
              'total': serverItems.length,
              'limit': limit,
              'offset': offset,
            });
          }

          if (options.method == 'GET' && options.path.endsWith('/image')) {
            return _bytesResponse(_kSamplePngBytes);
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
          historyControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(sub.close);

        final notifier = container.read(historyControllerProvider.notifier);

        // 1. Load first page with pageSize = 2
        await notifier.loadInitial(pageSize: 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        var state = container.read(historyControllerProvider);
        expect(state.isLoadingInitial, isFalse);
        expect(state.items.length, 2);
        expect(state.total, 3);
        expect(state.limit, 2);
        expect(state.offset, 0);
        expect(state.hasMore, isTrue);
        expect(state.thumbnailFor('hist-job-001'), isNotNull);
        expect(state.thumbnailFor('hist-job-002'), isNotNull);

        // 2. Load page 2 while server fails -> preserves page 1 items and sets loadMoreError
        final failedLoadMore = await notifier.loadMore();
        expect(failedLoadMore, isFalse);
        state = container.read(historyControllerProvider);
        expect(state.items.length, 2);
        expect(state.loadMoreError?.errorCode, ApiErrorCode.databaseError);
        expect(state.hasMore, isTrue);

        // 3. Retry loadMore when server recovers -> appends 3rd item and clears loadMoreError
        shouldFailPageTwo = false;
        final succeededLoadMore = await notifier.loadMore();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(succeededLoadMore, isTrue);
        state = container.read(historyControllerProvider);
        expect(state.loadMoreError, isNull);
        expect(state.items.map((e) => e.jobId).toList(), [
          'hist-job-001',
          'hist-job-002',
          'hist-job-003',
        ]);
        expect(state.hasMore, isFalse);
        expect(state.thumbnailFor('hist-job-003'), isNotNull);
      },
    );

    test(
      'Scenario T11: saving twice on ResultScreen and restarting app (new ProviderContainer) retrieves 1 saved record and restores Before/After comparison images from Backend',
      () async {
        const jobId = 't11-persisted-job-777';
        final savedRecordsById = <String, Map<String, dynamic>>{};
        final serverResultBytes = Uint8List.fromList([..._kSamplePngBytes, 99]);
        final serverPersonBytes = Uint8List.fromList([..._kSamplePngBytes, 11]);
        final serverGarmentBytes = Uint8List.fromList([
          ..._kSamplePngBytes,
          22,
        ]);

        HttpClientAdapter buildServerAdapter() {
          return _ProgrammableAdapter((options) async {
            if (options.method == 'GET' &&
                options.path == '/api/v1/try-ons/$jobId') {
              final isSaved = savedRecordsById.containsKey(jobId);
              return _jsonResponse(
                _jobPayload(
                  jobId: jobId,
                  isSaved: isSaved,
                  savedAt: isSaved ? '2026-11-11T01:10:00Z' : null,
                ),
              );
            }

            if (options.method == 'POST' &&
                options.path == '/api/v1/try-ons/$jobId/save') {
              savedRecordsById[jobId] = _historyItemPayload(
                jobId: jobId,
                savedAt: '2026-11-11T01:10:00Z',
              );
              return _jsonResponse(
                _jobPayload(
                  jobId: jobId,
                  isSaved: true,
                  savedAt: '2026-11-11T01:10:00Z',
                ),
              );
            }

            if (options.method == 'GET' && options.path == '/api/v1/history') {
              final items = savedRecordsById.values.toList();
              return _jsonResponse({
                'items': items,
                'total': items.length,
                'limit': 20,
                'offset': 0,
              });
            }

            if (options.method == 'GET' &&
                options.path == '/api/v1/history/$jobId') {
              final item = savedRecordsById[jobId];
              if (item == null) {
                return _jsonResponse(
                  {
                    'error_code': 'JOB_NOT_FOUND',
                    'message': 'History item not found.',
                  },
                  statusCode: 404,
                );
              }
              return _jsonResponse(item);
            }

            if (options.method == 'GET' &&
                options.path == '/api/v1/try-ons/$jobId/image') {
              return _bytesResponse(serverResultBytes);
            }

            if (options.method == 'GET' &&
                options.path == '/api/v1/try-ons/$jobId/inputs/person') {
              return _bytesResponse(serverPersonBytes);
            }

            if (options.method == 'GET' &&
                options.path == '/api/v1/try-ons/$jobId/inputs/garment') {
              return _bytesResponse(serverGarmentBytes);
            }

            return _jsonResponse({}, statusCode: 404);
          });
        }

        // --- SESSION 1: User views ResultScreen and taps Save twice ---
        final dioSession1 = Dio(BaseOptions(baseUrl: testConfig.baseUrl))
          ..httpClientAdapter = buildServerAdapter();
        final containerSession1 = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(testConfig),
            dioProvider.overrideWithValue(dioSession1),
          ],
        );

        final resultSub = containerSession1.listen(
          tryOnResultControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        final resultNotifier = containerSession1.read(
          tryOnResultControllerProvider(jobId).notifier,
        );
        await resultNotifier.loadResult();

        final save1 = await resultNotifier.saveToHistory();
        final save2 = await resultNotifier.saveToHistory();
        expect(save1?.isSaved, isTrue);
        expect(save2?.isSaved, isTrue);
        expect(savedRecordsById.length, 1);

        // Dispose Session 1 completely (simulating app termination / cold restart)
        resultSub.close();
        containerSession1.dispose();

        // --- SESSION 2: Fresh ProviderContainer with empty RAM ---
        final dioSession2 = Dio(BaseOptions(baseUrl: testConfig.baseUrl))
          ..httpClientAdapter = buildServerAdapter();
        final containerSession2 = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(testConfig),
            dioProvider.overrideWithValue(dioSession2),
          ],
        );
        addTearDown(containerSession2.dispose);

        final histSub = containerSession2.listen(
          historyControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(histSub.close);

        final detailSub = containerSession2.listen(
          historyDetailControllerProvider(jobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(detailSub.close);

        await containerSession2
            .read(historyControllerProvider.notifier)
            .loadInitial();
        await containerSession2
            .read(historyDetailControllerProvider(jobId).notifier)
            .loadDetail();

        final listState = containerSession2.read(historyControllerProvider);
        expect(listState.total, 1);
        expect(listState.items.single.jobId, jobId);

        final detailState = containerSession2.read(
          historyDetailControllerProvider(jobId),
        );
        expect(detailState.isLoadingDetail, isFalse);
        expect(detailState.loadError, isNull);
        expect(detailState.item?.jobId, jobId);
        expect(detailState.resultImageBytes, equals(serverResultBytes));
        expect(detailState.personImageBytes, equals(serverPersonBytes));
        expect(detailState.garmentImageBytes, equals(serverGarmentBytes));
      },
    );

    test(
      'handles 404 Not Found on detail load and preserves item on delete failure before succeeding on retry',
      () async {
        const existingJobId = 'hist-delete-job-500';
        const missingJobId = 'hist-missing-job-404';
        var shouldFailDelete = true;
        var isDeletedOnServer = false;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' && options.path == '/api/v1/history') {
            final items = isDeletedOnServer
                ? <Map<String, dynamic>>[]
                : <Map<String, dynamic>>[
                    _historyItemPayload(jobId: existingJobId),
                  ];
            return _jsonResponse({
              'items': items,
              'total': items.length,
              'limit': 20,
              'offset': 0,
            });
          }

          if (options.method == 'GET' &&
              options.path == '/api/v1/history/$existingJobId') {
            if (isDeletedOnServer) {
              return _jsonResponse(
                {
                  'error_code': 'JOB_NOT_FOUND',
                  'message': 'History item was already deleted.',
                },
                statusCode: 404,
              );
            }
            return _jsonResponse(_historyItemPayload(jobId: existingJobId));
          }

          if (options.method == 'GET' &&
              options.path == '/api/v1/history/$missingJobId') {
            return _jsonResponse(
              {
                'error_code': 'JOB_NOT_FOUND',
                'message': 'History item does not exist.',
              },
              statusCode: 404,
            );
          }

          if (options.method == 'GET' &&
              (options.path.endsWith('/image') ||
                  options.path.contains('/inputs/'))) {
            return _bytesResponse(_kSamplePngBytes);
          }

          if (options.method == 'DELETE' &&
              options.path == '/api/v1/history/$existingJobId') {
            if (shouldFailDelete) {
              return _jsonResponse(
                {
                  'error_code': 'STORAGE_UNAVAILABLE',
                  'message': 'Cannot delete history item right now.',
                },
                statusCode: 503,
              );
            }
            isDeletedOnServer = true;
            return ResponseBody.fromString('', 204);
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

        final listSub = container.listen(
          historyControllerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(listSub.close);

        final missingSub = container.listen(
          historyDetailControllerProvider(missingJobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(missingSub.close);

        final detailSub = container.listen(
          historyDetailControllerProvider(existingJobId),
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(detailSub.close);

        // 1. Missing item returns 404 JOB_NOT_FOUND
        await container
            .read(historyDetailControllerProvider(missingJobId).notifier)
            .loadDetail();
        final missingState = container.read(
          historyDetailControllerProvider(missingJobId),
        );
        expect(missingState.isNotFoundError, isTrue);
        expect(missingState.loadError?.errorCode, ApiErrorCode.jobNotFound);

        // 2. Load existing item list & detail
        await container.read(historyControllerProvider.notifier).loadInitial();
        await container
            .read(historyDetailControllerProvider(existingJobId).notifier)
            .loadDetail();

        // 3. Delete fails with 503 -> item remains in list & detail images stay intact
        final detailNotifier = container.read(
          historyDetailControllerProvider(existingJobId).notifier,
        );
        final failedDelete = await detailNotifier.deleteFromHistory();
        expect(failedDelete, isFalse);

        var listState = container.read(historyControllerProvider);
        var detailState = container.read(
          historyDetailControllerProvider(existingJobId),
        );
        expect(listState.items.length, 1);
        expect(
          listState.deleteError?.errorCode,
          ApiErrorCode.storageUnavailable,
        );
        expect(
          detailState.deleteError?.errorCode,
          ApiErrorCode.storageUnavailable,
        );
        expect(detailState.isDeleted, isFalse);
        expect(detailState.hasResultImage, isTrue);
        expect(detailState.hasPersonImage, isTrue);

        // 4. Delete succeeds on retry -> item removed from list, total = 0, isDeleted = true
        shouldFailDelete = false;
        final succeededDelete = await detailNotifier.deleteFromHistory();
        expect(succeededDelete, isTrue);

        listState = container.read(historyControllerProvider);
        detailState = container.read(
          historyDetailControllerProvider(existingJobId),
        );
        expect(listState.items, isEmpty);
        expect(listState.total, 0);
        expect(listState.deleteError, isNull);
        expect(detailState.isDeleted, isTrue);
        expect(detailState.deleteError, isNull);
      },
    );
  });

  group('HistoryScreen & HistoryDetailScreen widget tests (F05 UI & E2E flows)', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('f05_widget_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'renders paginated HistoryScreen, loads more items, opens HistoryDetailScreen, compares Before/After, shares, handles delete failure, and deletes item on confirm',
      (tester) async {
        final serverItems = <Map<String, dynamic>>[
          _historyItemPayload(
            jobId: 'ui-hist-101',
            savedAt: '2026-11-11T02:02:00Z',
          ),
          _historyItemPayload(
            jobId: 'ui-hist-102',
            savedAt: '2026-11-11T02:01:00Z',
          ),
        ];
        var shouldFailDelete = true;
        ShareParams? capturedShareParams;

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' && options.path == '/api/v1/history') {
            final offset = (options.queryParameters['offset'] as int?) ?? 0;
            // Simulate 1 item per page to test pagination button in UI
            final slice = serverItems.skip(offset).take(1).toList();
            return _jsonResponse({
              'items': slice,
              'total': serverItems.length,
              'limit': 1,
              'offset': offset,
            });
          }

          if (options.method == 'GET' &&
              options.path.startsWith('/api/v1/history/')) {
            final id = options.path.split('/').last;
            final match = serverItems
                .where((item) => item['job_id'] == id)
                .toList();
            if (match.isEmpty) {
              return _jsonResponse(
                {
                  'error_code': 'JOB_NOT_FOUND',
                  'message': 'History item not found.',
                },
                statusCode: 404,
              );
            }
            return _jsonResponse(match.first);
          }

          if (options.method == 'GET' &&
              (options.path.endsWith('/image') ||
                  options.path.contains('/inputs/'))) {
            return _bytesResponse(_kSamplePngBytes);
          }

          if (options.method == 'DELETE' &&
              options.path.startsWith('/api/v1/history/')) {
            final id = options.path.split('/').last;
            if (shouldFailDelete) {
              return _jsonResponse(
                {
                  'error_code': 'DATABASE_ERROR',
                  'message': 'Database busy while deleting.',
                },
                statusCode: 503,
              );
            }
            serverItems.removeWhere((item) => item['job_id'] == id);
            return ResponseBody.fromString('', 204);
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

        final router = createAppRouter(initialLocation: AppRoutes.history);

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

        await tester.pumpAndSettle();

        // 1. Page 1 renders 'ui-hist-101' and shows "2 mục" badge + "Tải thêm lịch sử" button
        expect(find.text('Lịch sử đã lưu'), findsOneWidget);
        expect(find.text('2 mục'), findsOneWidget);
        expect(
          find.byKey(const Key('history_item_card_ui-hist-101')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('history_item_card_ui-hist-102')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('history_load_more_button')),
          findsOneWidget,
        );

        // 2. Tap "Tải thêm lịch sử" -> appends 'ui-hist-102'
        await tester.tap(find.byKey(const Key('history_load_more_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('history_item_card_ui-hist-102')),
          findsOneWidget,
        );

        // 3. Open detail for 'ui-hist-101'
        await tester.tap(
          find.byKey(const Key('history_open_detail_button_ui-hist-101')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Chi tiết kết quả đã lưu'), findsOneWidget);
        expect(find.text('Job ID: ui-hist-101'), findsOneWidget);
        expect(
          find.byKey(const Key('comparison_before_after_view')),
          findsOneWidget,
        );

        // 4. Switch comparison modes (FR-09)
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

        // 5. Share result image (FR-15)
        await tester.tap(find.byKey(const Key('history_detail_share_button')));
        await tester.pumpAndSettle();
        expect(capturedShareParams, isNotNull);
        expect(
          capturedShareParams!.files!.single.path,
          endsWith('try_on_ui-hist-101.png'),
        );

        // 6. Attempt delete while server fails -> shows confirmation dialog, then displays delete error banner
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

        expect(
          find.byKey(const Key('history_detail_delete_error_banner')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('result_after_image')), findsOneWidget);

        // 7. Fix server delete and confirm deletion again -> navigates back to HistoryScreen with 'ui-hist-101' removed
        shouldFailDelete = false;
        await tester.tap(find.byKey(const Key('history_detail_delete_button')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('history_delete_confirm_button')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Lịch sử đã lưu'), findsOneWidget);
        expect(find.text('1 mục'), findsOneWidget);
        expect(
          find.byKey(const Key('history_item_card_ui-hist-101')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('history_item_card_ui-hist-102')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'displays 404 Not Found card on HistoryDetailScreen and Empty State on HistoryScreen when no items exist',
      (tester) async {
        const missingId = 'missing-history-404';

        final dio = Dio(BaseOptions(baseUrl: testConfig.baseUrl));
        dio.httpClientAdapter = _ProgrammableAdapter((options) async {
          if (options.method == 'GET' && options.path == '/api/v1/history') {
            return _jsonResponse({
              'items': <Map<String, dynamic>>[],
              'total': 0,
              'limit': 20,
              'offset': 0,
            });
          }

          if (options.method == 'GET' &&
              options.path == '/api/v1/history/$missingId') {
            return _jsonResponse(
              {
                'error_code': 'JOB_NOT_FOUND',
                'message': 'History item was not found.',
              },
              statusCode: 404,
            );
          }

          return _jsonResponse({}, statusCode: 404);
        });

        final router = createAppRouter(
          initialLocation: AppRoutes.historyDetailPath(missingId),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(testConfig),
              dioProvider.overrideWithValue(dio),
              appRouterProvider.overrideWithValue(router),
            ],
            child: const VirtualOutfitApp(),
          ),
        );

        await tester.pumpAndSettle();

        // 1. 404 Error Card is shown on HistoryDetailScreen
        expect(
          find.byKey(const Key('history_detail_error_card')),
          findsOneWidget,
        );
        expect(
          find.text('Mục lịch sử không tồn tại hoặc đã bị xóa'),
          findsOneWidget,
        );
        expect(find.textContaining('Mã lỗi: JOB_NOT_FOUND'), findsOneWidget);

        // 2. Tap "Quay lại Lịch sử" -> navigates to HistoryScreen showing Empty State
        await tester.tap(find.byKey(const Key('history_detail_back_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('history_empty_state')), findsOneWidget);
        expect(find.text('Chưa có kết quả nào được lưu'), findsOneWidget);
      },
    );
  });
}

