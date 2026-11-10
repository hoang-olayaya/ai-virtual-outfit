import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/network/api_error.dart';
import '../../../core/services/image_share_service.dart';
import '../../try_on/application/try_on_result_controller.dart';
import '../../try_on/data/try_on_repository.dart';
import '../data/history_repository.dart';
import '../data/models/history_item_model.dart';

/// Immutable state managed by [HistoryController] for `HistoryScreen` (`/history`).
///
/// Satisfies:
/// - **FR-12 (View History):** Holds paginated saved items retrieved from the Backend
///   (`GET /api/v1/history`), along with `total`, `limit`, `offset`, and [hasMore].
/// - **FR-14 (Delete Result):** Tracks [deletingJobIds] and [deleteError] independently
///   so a failed deletion preserves existing items in the list and allows retrying.
/// - **FR-16 & NFR-02 (Clear States):** Separates initial loading ([isLoadingInitial],
///   [loadError]), pull-to-refresh ([isRefreshing]), next-page pagination ([isLoadingMore],
///   [loadMoreError]), and thumbnail byte loading ([thumbnailBytesByJobId]).
@immutable
class HistoryListState {
  const HistoryListState({
    this.items = const <HistoryItemModel>[],
    this.total = 0,
    this.limit = defaultPageSize,
    this.offset = 0,
    this.isLoadingInitial = false,
    this.isRefreshing = false,
    this.isLoadingMore = false,
    this.loadError,
    this.loadMoreError,
    this.deletingJobIds = const <String>{},
    this.deleteError,
    this.thumbnailBytesByJobId = const <String, Uint8List>{},
    this.loadingThumbnailJobIds = const <String>{},
  });

  /// Default number of history records requested per page.
  static const int defaultPageSize = 20;

  final List<HistoryItemModel> items;
  final int total;
  final int limit;
  final int offset;

  /// True while fetching the first page of history items.
  final bool isLoadingInitial;

  /// True while refreshing the history list from offset 0.
  final bool isRefreshing;

  /// True while fetching the next page of history items (`offset > 0`).
  final bool isLoadingMore;

  /// Error encountered during initial list load or full refresh when list is empty.
  final ApiException? loadError;

  /// Error encountered while loading a subsequent page (`loadMore`), keeping existing [items] intact.
  final ApiException? loadMoreError;

  /// Set of `jobId`s currently undergoing `DELETE /api/v1/history/{jobId}`.
  final Set<String> deletingJobIds;

  /// Error encountered if deleting a history item failed.
  final ApiException? deleteError;

  /// Cached result image thumbnail bytes keyed by `jobId`, downloaded via [TryOnRepository].
  final Map<String, Uint8List> thumbnailBytesByJobId;

  /// Set of `jobId`s whose thumbnail bytes are currently being downloaded.
  final Set<String> loadingThumbnailJobIds;

  /// True if there are additional saved items on the Backend beyond [items].
  bool get hasMore => items.length < total;

  /// True when not loading initially, no load error occurred, and no saved items exist.
  bool get isEmpty => !isLoadingInitial && loadError == null && items.isEmpty;

  /// Checks whether a specific `jobId` is currently being deleted.
  bool isDeletingJob(String jobId) => deletingJobIds.contains(jobId.trim());

  /// Checks whether thumbnail bytes are currently loading for `jobId`.
  bool isLoadingThumbnail(String jobId) =>
      loadingThumbnailJobIds.contains(jobId.trim());

  /// Retrieves cached thumbnail bytes for `jobId`, if loaded.
  Uint8List? thumbnailFor(String jobId) => thumbnailBytesByJobId[jobId.trim()];

  /// User-friendly localized error message for initial list loading failures.
  String? get effectiveLoadErrorMessage => loadError?.userFriendlyMessage;

  /// User-friendly localized error message for pagination (`loadMore`) failures.
  String? get effectiveLoadMoreErrorMessage =>
      loadMoreError?.userFriendlyMessage;

  /// User-friendly localized error message for deletion failures.
  String? get effectiveDeleteErrorMessage => deleteError?.userFriendlyMessage;

  HistoryListState copyWith({
    List<HistoryItemModel>? items,
    int? total,
    int? limit,
    int? offset,
    bool? isLoadingInitial,
    bool? isRefreshing,
    bool? isLoadingMore,
    ApiException? loadError,
    bool clearLoadError = false,
    ApiException? loadMoreError,
    bool clearLoadMoreError = false,
    Set<String>? deletingJobIds,
    ApiException? deleteError,
    bool clearDeleteError = false,
    Map<String, Uint8List>? thumbnailBytesByJobId,
    Set<String>? loadingThumbnailJobIds,
  }) {
    return HistoryListState(
      items: items != null
          ? List<HistoryItemModel>.unmodifiable(items)
          : this.items,
      total: total ?? this.total,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
      isLoadingInitial: isLoadingInitial ?? this.isLoadingInitial,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      loadMoreError: clearLoadMoreError
          ? null
          : (loadMoreError ?? this.loadMoreError),
      deletingJobIds: deletingJobIds != null
          ? Set<String>.unmodifiable(deletingJobIds)
          : this.deletingJobIds,
      deleteError: clearDeleteError ? null : (deleteError ?? this.deleteError),
      thumbnailBytesByJobId: thumbnailBytesByJobId != null
          ? Map<String, Uint8List>.unmodifiable(thumbnailBytesByJobId)
          : this.thumbnailBytesByJobId,
      loadingThumbnailJobIds: loadingThumbnailJobIds != null
          ? Set<String>.unmodifiable(loadingThumbnailJobIds)
          : this.loadingThumbnailJobIds,
    );
  }
}

/// Riverpod [Notifier] that manages the paginated saved History list (`GET /api/v1/history`)
/// and coordinates item deletion (`DELETE /api/v1/history/{jobId}`).
///
/// Architecture Rule: Always fetches persisted history from the PostgreSQL Backend,
/// never relying on ephemeral RAM from previous sessions (Scenario T11).
class HistoryController extends Notifier<HistoryListState> {
  CancelToken? _listCancelToken;
  Future<void>? _inFlightInitialFuture;
  Future<bool>? _inFlightLoadMoreFuture;
  bool _isDisposed = false;

  @override
  HistoryListState build() {
    _isDisposed = false;
    _inFlightInitialFuture = null;
    _inFlightLoadMoreFuture = null;
    _listCancelToken?.cancel('HistoryController rebuilt');
    _listCancelToken = null;

    ref.onDispose(_disposeResources);

    Future<void>.microtask(loadInitial);

    return const HistoryListState(
      isLoadingInitial: true,
    );
  }

  /// Loads the first page (`offset: 0`) of saved history items from [HistoryRepository].
  ///
  /// Single-flight: if an initial load is already running and [pageSize] is unchanged,
  /// returns the active [Future].
  Future<void> loadInitial({int? pageSize}) {
    final targetLimit = pageSize ?? state.limit;
    final existing = _inFlightInitialFuture;
    if (existing != null && targetLimit == state.limit) {
      return existing;
    }

    final future = _performLoadFirstPage(
      limit: targetLimit,
      isRefresh: false,
    );
    _inFlightInitialFuture = future;
    return future;
  }

  /// Refreshes the history list from `offset: 0`.
  Future<void> refresh({int? pageSize}) {
    final targetLimit = pageSize ?? state.limit;
    final future = _performLoadFirstPage(
      limit: targetLimit,
      isRefresh: true,
    );
    _inFlightInitialFuture = future;
    return future;
  }

  Future<void> _performLoadFirstPage({
    required int limit,
    required bool isRefresh,
  }) async {
    if (_isDisposed) {
      _inFlightInitialFuture = null;
      return;
    }

    _listCancelToken?.cancel('Reloading history first page');
    final cancelToken = CancelToken();
    _listCancelToken = cancelToken;

    state = state.copyWith(
      limit: limit,
      isLoadingInitial: !isRefresh || state.items.isEmpty,
      isRefreshing: isRefresh && state.items.isNotEmpty,
      isLoadingMore: false,
      clearLoadError: true,
      clearLoadMoreError: true,
    );

    final historyRepository = ref.read(historyRepositoryProvider);

    try {
      final page = await historyRepository.getHistoryList(
        limit: limit,
        offset: 0,
        cancelToken: cancelToken,
      );

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      state = state.copyWith(
        items: page.items,
        total: page.total,
        limit: page.limit,
        offset: page.offset,
        isLoadingInitial: false,
        isRefreshing: false,
        isLoadingMore: false,
        clearLoadError: true,
        clearLoadMoreError: true,
      );

      _prefetchThumbnailsForItems(page.items);
    } on ApiException catch (apiError) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        isLoadingInitial: false,
        isRefreshing: false,
        loadError: apiError,
      );
    } catch (unexpected) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        isLoadingInitial: false,
        isRefreshing: false,
        loadError: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
    } finally {
      _inFlightInitialFuture = null;
    }
  }

  /// Fetches the next page of saved history items (`offset: state.items.length`)
  /// when [HistoryListState.hasMore] is `true`.
  ///
  /// Preserves already loaded [HistoryListState.items] if an error occurs during pagination.
  Future<bool> loadMore() {
    final existing = _inFlightLoadMoreFuture;
    if (existing != null) {
      return existing;
    }

    if (_isDisposed ||
        state.isLoadingInitial ||
        state.isRefreshing ||
        !state.hasMore) {
      return Future<bool>.value(false);
    }

    final future = _performLoadMore();
    _inFlightLoadMoreFuture = future;
    return future;
  }

  Future<bool> _performLoadMore() async {
    final nextOffset = state.items.length;
    final pageLimit = state.limit;

    state = state.copyWith(
      isLoadingMore: true,
      clearLoadMoreError: true,
    );

    final historyRepository = ref.read(historyRepositoryProvider);

    try {
      final nextPage = await historyRepository.getHistoryList(
        limit: pageLimit,
        offset: nextOffset,
        cancelToken: _listCancelToken,
      );

      if (_isDisposed) {
        return false;
      }

      final existingIds = state.items.map((item) => item.jobId).toSet();
      final mergedItems = <HistoryItemModel>[
        ...state.items,
        for (final item in nextPage.items)
          if (!existingIds.contains(item.jobId)) item,
      ];

      state = state.copyWith(
        items: mergedItems,
        total: nextPage.total,
        limit: nextPage.limit,
        offset: nextPage.offset,
        isLoadingMore: false,
        clearLoadMoreError: true,
      );

      _prefetchThumbnailsForItems(nextPage.items);
      return true;
    } on ApiException catch (apiError) {
      if (_isDisposed) {
        return false;
      }
      state = state.copyWith(
        isLoadingMore: false,
        loadMoreError: apiError,
      );
      return false;
    } catch (unexpected) {
      if (_isDisposed) {
        return false;
      }
      state = state.copyWith(
        isLoadingMore: false,
        loadMoreError: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
      return false;
    } finally {
      _inFlightLoadMoreFuture = null;
    }
  }

  /// Downloads thumbnail bytes for a history item via [TryOnRepository.downloadResultImageBytes]
  /// if not already cached or in-flight.
  Future<Uint8List?> ensureThumbnailLoaded(String jobId) async {
    final normalizedId = jobId.trim();
    if (_isDisposed || normalizedId.isEmpty) {
      return null;
    }

    final cached = state.thumbnailBytesByJobId[normalizedId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    if (state.loadingThumbnailJobIds.contains(normalizedId)) {
      return null;
    }

    state = state.copyWith(
      loadingThumbnailJobIds: <String>{
        ...state.loadingThumbnailJobIds,
        normalizedId,
      },
    );

    final tryOnRepository = ref.read(tryOnRepositoryProvider);

    try {
      final bytes = await tryOnRepository.downloadResultImageBytes(
        normalizedId,
        cancelToken: _listCancelToken,
      );
      if (_isDisposed) {
        return null;
      }

      final nextLoading = <String>{...state.loadingThumbnailJobIds}
        ..remove(normalizedId);

      if (bytes.isNotEmpty) {
        state = state.copyWith(
          thumbnailBytesByJobId: <String, Uint8List>{
            ...state.thumbnailBytesByJobId,
            normalizedId: bytes,
          },
          loadingThumbnailJobIds: nextLoading,
        );
        return bytes;
      } else {
        state = state.copyWith(loadingThumbnailJobIds: nextLoading);
        return null;
      }
    } catch (_) {
      if (!_isDisposed) {
        final nextLoading = <String>{...state.loadingThumbnailJobIds}
          ..remove(normalizedId);
        state = state.copyWith(loadingThumbnailJobIds: nextLoading);
      }
      return null;
    }
  }

  /// Deletes a saved history item (`DELETE /api/v1/history/{jobId}`) via [HistoryRepository] (FR-14).
  ///
  /// - Guards against concurrent duplicate delete calls on the same `jobId`.
  /// - On `204 No Content` success: removes the item from [HistoryListState.items],
  ///   decrements [HistoryListState.total], cleans up cached thumbnail bytes, and returns `true`.
  /// - On error: records [HistoryListState.deleteError] while keeping the item in the list
  ///   so the user can retry, and returns `false`.
  Future<bool> deleteItem(String jobId) async {
    final normalizedId = jobId.trim();
    if (_isDisposed ||
        normalizedId.isEmpty ||
        state.deletingJobIds.contains(normalizedId)) {
      return false;
    }

    state = state.copyWith(
      deletingJobIds: <String>{...state.deletingJobIds, normalizedId},
      clearDeleteError: true,
    );

    final historyRepository = ref.read(historyRepositoryProvider);

    try {
      await historyRepository.deleteHistoryItem(normalizedId);
      if (_isDisposed) {
        return false;
      }

      final hadItemInList = state.items.any(
        (item) => item.jobId == normalizedId,
      );
      final updatedItems = state.items
          .where((item) => item.jobId != normalizedId)
          .toList(growable: false);
      final updatedDeleting = <String>{...state.deletingJobIds}
        ..remove(normalizedId);
      final updatedThumbnails = <String, Uint8List>{
        ...state.thumbnailBytesByJobId,
      }..remove(normalizedId);
      final nextTotal = hadItemInList
          ? (state.total > 0 ? state.total - 1 : 0)
          : (state.total > updatedItems.length
                ? state.total - 1
                : updatedItems.length);

      state = state.copyWith(
        items: updatedItems,
        total: nextTotal < 0 ? 0 : nextTotal,
        deletingJobIds: updatedDeleting,
        thumbnailBytesByJobId: updatedThumbnails,
        clearDeleteError: true,
      );
      return true;
    } on ApiException catch (apiError) {
      if (_isDisposed) {
        return false;
      }
      final updatedDeleting = <String>{...state.deletingJobIds}
        ..remove(normalizedId);
      state = state.copyWith(
        deletingJobIds: updatedDeleting,
        deleteError: apiError,
      );
      return false;
    } catch (unexpected) {
      if (_isDisposed) {
        return false;
      }
      final updatedDeleting = <String>{...state.deletingJobIds}
        ..remove(normalizedId);
      state = state.copyWith(
        deletingJobIds: updatedDeleting,
        deleteError: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
      return false;
    }
  }

  /// Clears any active delete error banner on `HistoryScreen`.
  void clearDeleteError() {
    if (state.deleteError != null) {
      state = state.copyWith(clearDeleteError: true);
    }
  }

  /// Clears any active pagination (`loadMore`) error banner on `HistoryScreen`.
  void clearLoadMoreError() {
    if (state.loadMoreError != null) {
      state = state.copyWith(clearLoadMoreError: true);
    }
  }

  void _prefetchThumbnailsForItems(List<HistoryItemModel> items) {
    for (final item in items) {
      unawaited(ensureThumbnailLoaded(item.jobId));
    }
  }

  void _disposeResources() {
    _isDisposed = true;
    _listCancelToken?.cancel('HistoryController disposed');
    _listCancelToken = null;
  }
}

/// Provider for [HistoryController].
///
/// Uses `autoDispose` so entering `HistoryScreen` after app restarts or new saves
/// always fetches fresh, authoritative state from the Backend.
final historyControllerProvider =
    NotifierProvider.autoDispose<HistoryController, HistoryListState>(
      HistoryController.new,
    );

/// Immutable state managed by [HistoryDetailController] for `HistoryDetailScreen` (`/history/:jobId`).
///
/// Satisfies:
/// - **FR-13 (View History Detail):** Holds [item] (`GET /api/v1/history/{jobId}`) and
///   generated [resultImageBytes] (`GET /api/v1/try-ons/{jobId}/image`).
/// - **FR-09 (Compare Before/After Across Restarts — Scenario T11):** Holds [personImageBytes]
///   and [garmentImageBytes] downloaded from `GET /api/v1/try-ons/{jobId}/inputs/{kind}`,
///   plus [comparisonMode] for interactive `Result Only`, `Before / After`, and `3-Panel` views.
/// - **FR-14 (Delete Result):** Tracks [isDeleting], [isDeleted], and [deleteError].
/// - **FR-15 (Share Result):** Tracks [isSharing], [lastSharedFilePath], [lastShareStatus],
///   and [shareErrorMessage] independently (`Load != Share != Delete`).
@immutable
class HistoryDetailState {
  const HistoryDetailState({
    required this.jobId,
    this.item,
    this.resultImageBytes,
    this.personImageBytes,
    this.garmentImageBytes,
    this.comparisonMode = ResultComparisonMode.beforeAfter,
    this.isLoadingDetail = false,
    this.loadError,
    this.isDeleting = false,
    this.isDeleted = false,
    this.deleteError,
    this.isSharing = false,
    this.lastSharedFilePath,
    this.lastShareStatus,
    this.shareErrorMessage,
  });

  final String jobId;
  final HistoryItemModel? item;
  final Uint8List? resultImageBytes;
  final Uint8List? personImageBytes;
  final Uint8List? garmentImageBytes;
  final ResultComparisonMode comparisonMode;

  /// True while fetching history detail metadata or downloading image bytes.
  final bool isLoadingDetail;

  /// Structured error if fetching history detail (e.g., `404 JOB_NOT_FOUND`) or result image failed.
  final ApiException? loadError;

  /// True while `DELETE /api/v1/history/{jobId}` is in-flight.
  final bool isDeleting;

  /// True once the item has been deleted from the Backend.
  final bool isDeleted;

  /// Structured error if deleting the item failed.
  final ApiException? deleteError;

  /// True while writing temporary image file and opening the native share sheet.
  final bool isSharing;

  /// Path to the most recently written temporary share file on device storage.
  final String? lastSharedFilePath;

  /// Status returned by the last `share_plus` invocation.
  final ShareResultStatus? lastShareStatus;

  /// Independent localized error message if sharing failed.
  final String? shareErrorMessage;

  /// True when the generated result image bytes are loaded and non-empty.
  bool get hasResultImage =>
      resultImageBytes != null && resultImageBytes!.isNotEmpty;

  /// True when the person input image bytes are loaded from the Backend for Before/After compare.
  bool get hasPersonImage =>
      personImageBytes != null && personImageBytes!.isNotEmpty;

  /// True when the garment input image bytes are loaded from the Backend for 3-panel compare.
  bool get hasGarmentImage =>
      garmentImageBytes != null && garmentImageBytes!.isNotEmpty;

  /// True when [loadError] represents a `404 JOB_NOT_FOUND` response.
  bool get isNotFoundError =>
      loadError?.errorCode == ApiErrorCode.jobNotFound ||
      loadError?.statusCode == 404;

  /// User-friendly localized error message when loading detail fails.
  String? get effectiveLoadErrorMessage => loadError?.userFriendlyMessage;

  /// User-friendly localized error message when deleting fails.
  String? get effectiveDeleteErrorMessage => deleteError?.userFriendlyMessage;

  HistoryDetailState copyWith({
    String? jobId,
    HistoryItemModel? item,
    Uint8List? resultImageBytes,
    Uint8List? personImageBytes,
    Uint8List? garmentImageBytes,
    ResultComparisonMode? comparisonMode,
    bool? isLoadingDetail,
    ApiException? loadError,
    bool clearLoadError = false,
    bool? isDeleting,
    bool? isDeleted,
    ApiException? deleteError,
    bool clearDeleteError = false,
    bool? isSharing,
    String? lastSharedFilePath,
    ShareResultStatus? lastShareStatus,
    String? shareErrorMessage,
    bool clearShareError = false,
  }) {
    return HistoryDetailState(
      jobId: jobId ?? this.jobId,
      item: item ?? this.item,
      resultImageBytes: resultImageBytes ?? this.resultImageBytes,
      personImageBytes: personImageBytes ?? this.personImageBytes,
      garmentImageBytes: garmentImageBytes ?? this.garmentImageBytes,
      comparisonMode: comparisonMode ?? this.comparisonMode,
      isLoadingDetail: isLoadingDetail ?? this.isLoadingDetail,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      isDeleting: isDeleting ?? this.isDeleting,
      isDeleted: isDeleted ?? this.isDeleted,
      deleteError: clearDeleteError ? null : (deleteError ?? this.deleteError),
      isSharing: isSharing ?? this.isSharing,
      lastSharedFilePath: lastSharedFilePath ?? this.lastSharedFilePath,
      lastShareStatus: lastShareStatus ?? this.lastShareStatus,
      shareErrorMessage: clearShareError
          ? null
          : (shareErrorMessage ?? this.shareErrorMessage),
    );
  }
}

/// Riverpod [Notifier] that coordinates loading a saved history item's detail metadata,
/// fetching result + input comparison images (`person` & `garment`) from the Backend,
/// switching comparison modes, sharing via `share_plus`, and deleting the item on
/// `HistoryDetailScreen` (`/history/:jobId`).
class HistoryDetailController extends Notifier<HistoryDetailState> {
  HistoryDetailController(this.jobId);

  final String jobId;

  CancelToken? _detailCancelToken;
  Future<void>? _inFlightLoadFuture;
  bool _isDisposed = false;

  @override
  HistoryDetailState build() {
    final normalizedId = jobId.trim();
    _isDisposed = false;
    _inFlightLoadFuture = null;
    _detailCancelToken?.cancel('HistoryDetailController rebuilt');
    _detailCancelToken = null;

    ref.onDispose(_disposeResources);

    Future<void>.microtask(loadDetail);

    return HistoryDetailState(
      jobId: normalizedId,
      isLoadingDetail: true,
    );
  }

  /// Loads (or reloads) the saved history item metadata (`GET /api/v1/history/{jobId}`),
  /// generated result image bytes (`GET /api/v1/try-ons/{jobId}/image`), and both input
  /// comparison images (`GET /api/v1/try-ons/{jobId}/inputs/person` & `garment`) from the Backend.
  Future<void> loadDetail() {
    final existing = _inFlightLoadFuture;
    if (existing != null) {
      return existing;
    }

    final future = _performLoadDetail();
    _inFlightLoadFuture = future;
    return future;
  }

  Future<void> _performLoadDetail() async {
    if (_isDisposed) {
      _inFlightLoadFuture = null;
      return;
    }

    final normalizedId = state.jobId.trim();
    if (normalizedId.isEmpty) {
      _inFlightLoadFuture = null;
      state = state.copyWith(
        isLoadingDetail: false,
        loadError: ApiException(
          errorCode: ApiErrorCode.invalidRequest,
          rawCode: 'EMPTY_JOB_ID',
          message: ApiErrorCode.invalidRequest.defaultUserMessage,
          statusCode: 400,
        ),
      );
      return;
    }

    _detailCancelToken?.cancel('Reloading history detail');
    final cancelToken = CancelToken();
    _detailCancelToken = cancelToken;

    state = state.copyWith(
      isLoadingDetail: true,
      clearLoadError: true,
    );

    final historyRepository = ref.read(historyRepositoryProvider);
    final tryOnRepository = ref.read(tryOnRepositoryProvider);

    try {
      // 1. Fetch saved history detail (`GET /api/v1/history/{jobId}`).
      // Returns 404 JOB_NOT_FOUND if the job does not exist or is not marked saved.
      final detailItem = await historyRepository.getHistoryDetail(
        normalizedId,
        cancelToken: cancelToken,
      );

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      // 2. Download generated result image bytes (`GET /api/v1/try-ons/{jobId}/image`).
      final resultBytes = await tryOnRepository.downloadResultImageBytes(
        normalizedId,
        cancelToken: cancelToken,
      );

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      if (resultBytes.isEmpty) {
        throw ApiException(
          errorCode: ApiErrorCode.corruptedImage,
          rawCode: 'EMPTY_RESULT_IMAGE',
          message: ApiErrorCode.corruptedImage.defaultUserMessage,
        );
      }

      // 3. Download input images (`person` and `garment`) stored on the Backend
      // so Before/After and 3-panel comparison work across app restarts (FR-09, FR-13, Scenario T11).
      Uint8List? personBytes = state.personImageBytes;
      Uint8List? garmentBytes = state.garmentImageBytes;

      try {
        final downloadedPerson = await tryOnRepository.downloadInputImageBytes(
          normalizedId,
          kind: 'person',
          cancelToken: cancelToken,
        );
        if (downloadedPerson.isNotEmpty) {
          personBytes = downloadedPerson;
        }
      } catch (_) {
        // Non-fatal: allow viewing result image even if person input is unavailable.
      }

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      try {
        final downloadedGarment = await tryOnRepository.downloadInputImageBytes(
          normalizedId,
          kind: 'garment',
          cancelToken: cancelToken,
        );
        if (downloadedGarment.isNotEmpty) {
          garmentBytes = downloadedGarment;
        }
      } catch (_) {
        // Non-fatal: allow viewing result image even if garment input is unavailable.
      }

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      state = state.copyWith(
        item: detailItem,
        resultImageBytes: resultBytes,
        personImageBytes: personBytes,
        garmentImageBytes: garmentBytes,
        isLoadingDetail: false,
        clearLoadError: true,
      );
    } on ApiException catch (apiError) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        isLoadingDetail: false,
        loadError: apiError,
      );
    } catch (unexpected) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        isLoadingDetail: false,
        loadError: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
    } finally {
      _inFlightLoadFuture = null;
    }
  }

  /// Switches the active visual comparison mode (FR-09) without re-downloading images.
  void setComparisonMode(ResultComparisonMode mode) {
    if (_isDisposed || state.comparisonMode == mode) {
      return;
    }
    state = state.copyWith(comparisonMode: mode);
  }

  /// Writes the result image bytes to a local temporary file and opens the native OS
  /// share sheet via [ImageShareService] (`share_plus` — FR-15).
  ///
  /// Strictly isolated from [deleteFromHistory] (`Share != Delete`).
  Future<bool> shareResult({String? text}) async {
    if (_isDisposed || state.isSharing) {
      return false;
    }

    final normalizedId = state.jobId.trim();
    if (normalizedId.isEmpty) {
      return false;
    }

    state = state.copyWith(
      isSharing: true,
      clearShareError: true,
    );

    final tryOnRepository = ref.read(tryOnRepositoryProvider);
    final shareService = ref.read(imageShareServiceProvider);

    try {
      Uint8List? bytes = state.resultImageBytes;
      if (bytes == null || bytes.isEmpty) {
        bytes = await tryOnRepository.downloadResultImageBytes(normalizedId);
        if (_isDisposed) {
          return false;
        }
      }

      final tempFile = await shareService.writeTempResultImage(
        bytes,
        jobId: normalizedId,
      );
      if (_isDisposed) {
        return false;
      }

      final format = ImageShareService.detectFormat(bytes);
      final shareResult = await shareService.shareLocalImageFile(
        tempFile.path,
        mimeType: format.mimeType,
        text: text ?? 'Kết quả thử trang phục ảo từ AI Virtual Outfit Preview',
      );
      if (_isDisposed) {
        return false;
      }

      state = state.copyWith(
        resultImageBytes: bytes,
        isSharing: false,
        lastSharedFilePath: tempFile.path,
        lastShareStatus: shareResult.status,
        clearShareError: true,
      );
      return true;
    } on ImageShareException catch (shareError) {
      if (_isDisposed) {
        return false;
      }
      state = state.copyWith(
        isSharing: false,
        shareErrorMessage: shareError.message,
      );
      return false;
    } on ApiException catch (apiError) {
      if (_isDisposed) {
        return false;
      }
      state = state.copyWith(
        isSharing: false,
        shareErrorMessage: apiError.userFriendlyMessage,
      );
      return false;
    } catch (_) {
      if (_isDisposed) {
        return false;
      }
      state = state.copyWith(
        isSharing: false,
        shareErrorMessage:
            'Không thể chia sẻ ảnh kết quả lúc này. Vui lòng thử lại.',
      );
      return false;
    }
  }

  /// Deletes this item from History (`DELETE /api/v1/history/{jobId}`) and synchronizes
  /// with [HistoryController] (FR-14).
  ///
  /// - Blocks duplicate taps while [state.isDeleting] is `true`.
  /// - On success: sets [state.isDeleted] to `true` and returns `true`.
  /// - On failure: sets [state.deleteError] while keeping [state.resultImageBytes]
  ///   and comparison images intact so the user can retry.
  Future<bool> deleteFromHistory() async {
    if (_isDisposed || state.isDeleting || state.isDeleted) {
      return false;
    }

    final normalizedId = state.jobId.trim();
    if (normalizedId.isEmpty) {
      return false;
    }

    state = state.copyWith(
      isDeleting: true,
      clearDeleteError: true,
    );

    final historyListNotifier = ref.read(historyControllerProvider.notifier);
    final deleted = await historyListNotifier.deleteItem(normalizedId);

    if (_isDisposed) {
      return false;
    }

    if (deleted) {
      state = state.copyWith(
        isDeleting: false,
        isDeleted: true,
        clearDeleteError: true,
      );
      return true;
    }

    final listError = ref.read(historyControllerProvider).deleteError;
    state = state.copyWith(
      isDeleting: false,
      deleteError:
          listError ??
          ApiException(
            errorCode: ApiErrorCode.unknownError,
            rawCode: ApiErrorCode.unknownError.rawValue,
            message: ApiErrorCode.unknownError.defaultUserMessage,
          ),
    );
    return false;
  }

  /// Clears any active delete error banner on `HistoryDetailScreen`.
  void clearDeleteError() {
    if (state.deleteError != null) {
      state = state.copyWith(clearDeleteError: true);
    }
    ref.read(historyControllerProvider.notifier).clearDeleteError();
  }

  /// Clears any active share error banner on `HistoryDetailScreen`.
  void clearShareError() {
    if (state.shareErrorMessage != null) {
      state = state.copyWith(clearShareError: true);
    }
  }

  void _disposeResources() {
    _isDisposed = true;
    _detailCancelToken?.cancel('HistoryDetailController disposed');
    _detailCancelToken = null;
  }
}

/// Family provider for [HistoryDetailController], keyed by `jobId`.
final historyDetailControllerProvider = NotifierProvider.autoDispose
    .family<HistoryDetailController, HistoryDetailState, String>(
      HistoryDetailController.new,
    );

