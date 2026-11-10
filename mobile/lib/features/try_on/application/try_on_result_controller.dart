import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/network/api_error.dart';
import '../../../../core/services/image_share_service.dart';
import '../../history/application/history_controller.dart';
import '../../history/data/history_repository.dart';
import '../data/models/job_model.dart';
import '../data/try_on_repository.dart';
import 'try_on_draft_controller.dart';
import 'try_on_submission_controller.dart';

/// Visual comparison mode available on `ResultScreen` and `HistoryDetailScreen` (FR-08, FR-09).
enum ResultComparisonMode {
  /// Displays only the generated AI virtual try-on result image (`After`).
  resultOnly,

  /// Side-by-side comparison of the original Person photo (`Before`) and AI Result (`After`).
  beforeAfter,

  /// 3-panel comparison of Person (`Before`), Garment (`Outfit`), and AI Result (`After`).
  allThree,
}

/// Immutable state managed by [TryOnResultController] for `ResultScreen` (`/result/:jobId`).
///
/// Satisfies:
/// - **FR-08:** Loads and exposes generated try-on result image bytes ([resultImageBytes]).
/// - **FR-09:** Exposes [personImageBytes], [garmentImageBytes], and [comparisonMode]
///   for interactive Before/After comparison.
/// - **FR-11 & T11:** Tracks [isSaving], [isSaved], [savedAt], and [saveError] independently
///   for idempotent history saving (`POST /api/v1/try-ons/{id}/save`).
/// - **FR-15:** Tracks [isSharing], [lastSharedFilePath], and [shareErrorMessage] independently
///   for temporary file download + native OS share sheet (`share_plus`).
/// - **FR-16 & Architecture Rule (`Save != Share != Retry`):** Keeps media loading, saving,
///   sharing, and retry states isolated so a failure in one never breaks the others.
@immutable
class TryOnResultState {
  const TryOnResultState({
    required this.jobId,
    this.job,
    this.resultImageBytes,
    this.personImageBytes,
    this.garmentImageBytes,
    this.comparisonMode = ResultComparisonMode.beforeAfter,
    this.isLoadingResult = false,
    this.loadError,
    this.isSaving = false,
    this.isSaved = false,
    this.saveSuccessCount = 0,
    this.saveError,
    this.isSharing = false,
    this.lastSharedFilePath,
    this.lastShareStatus,
    this.shareErrorMessage,
  });

  final String jobId;
  final JobModel? job;
  final Uint8List? resultImageBytes;
  final Uint8List? personImageBytes;
  final Uint8List? garmentImageBytes;
  final ResultComparisonMode comparisonMode;

  /// True while fetching job metadata or downloading the result image bytes.
  final bool isLoadingResult;

  /// Structured error if loading the job or result image failed.
  final ApiException? loadError;

  /// True while `POST /api/v1/try-ons/{jobId}/save` is in-flight.
  final bool isSaving;

  /// True when the job has been marked `is_saved = true` on the Backend.
  final bool isSaved;

  /// Number of completed save operations in this session (useful for T11 idempotency checks).
  final int saveSuccessCount;

  /// Independent error if saving to history failed.
  final ApiException? saveError;

  /// True while writing temporary image file and opening the native share sheet.
  final bool isSharing;

  /// Path to the most recently written temporary share file on device storage.
  final String? lastSharedFilePath;

  /// Result status returned by the last `share_plus` invocation.
  final ShareResultStatus? lastShareStatus;

  /// Independent localized error message if sharing failed.
  final String? shareErrorMessage;

  /// True when the generated result image bytes are loaded and non-empty.
  bool get hasResultImage =>
      resultImageBytes != null && resultImageBytes!.isNotEmpty;

  /// True when the original person input image bytes are available for Before/After comparison.
  bool get hasPersonImage =>
      personImageBytes != null && personImageBytes!.isNotEmpty;

  /// True when the garment input image bytes are available for 3-panel comparison.
  bool get hasGarmentImage =>
      garmentImageBytes != null && garmentImageBytes!.isNotEmpty;

  /// Timestamp when the result was saved to history, if available.
  DateTime? get savedAt => job?.savedAt;

  /// User-friendly localized error message when loading the result image fails.
  String? get effectiveLoadErrorMessage => loadError?.userFriendlyMessage;

  /// User-friendly localized error message when saving to history fails.
  String? get effectiveSaveErrorMessage => saveError?.userFriendlyMessage;

  TryOnResultState copyWith({
    String? jobId,
    JobModel? job,
    Uint8List? resultImageBytes,
    Uint8List? personImageBytes,
    Uint8List? garmentImageBytes,
    ResultComparisonMode? comparisonMode,
    bool? isLoadingResult,
    ApiException? loadError,
    bool clearLoadError = false,
    bool? isSaving,
    bool? isSaved,
    int? saveSuccessCount,
    ApiException? saveError,
    bool clearSaveError = false,
    bool? isSharing,
    String? lastSharedFilePath,
    ShareResultStatus? lastShareStatus,
    String? shareErrorMessage,
    bool clearShareError = false,
  }) {
    return TryOnResultState(
      jobId: jobId ?? this.jobId,
      job: job ?? this.job,
      resultImageBytes: resultImageBytes ?? this.resultImageBytes,
      personImageBytes: personImageBytes ?? this.personImageBytes,
      garmentImageBytes: garmentImageBytes ?? this.garmentImageBytes,
      comparisonMode: comparisonMode ?? this.comparisonMode,
      isLoadingResult: isLoadingResult ?? this.isLoadingResult,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      isSaving: isSaving ?? this.isSaving,
      isSaved: isSaved ?? this.isSaved,
      saveSuccessCount: saveSuccessCount ?? this.saveSuccessCount,
      saveError: clearSaveError ? null : (saveError ?? this.saveError),
      isSharing: isSharing ?? this.isSharing,
      lastSharedFilePath: lastSharedFilePath ?? this.lastSharedFilePath,
      lastShareStatus: lastShareStatus ?? this.lastShareStatus,
      shareErrorMessage: clearShareError
          ? null
          : (shareErrorMessage ?? this.shareErrorMessage),
    );
  }
}

/// Riverpod [Notifier] that coordinates loading result/input media, switching Before/After
/// comparison modes, saving to History, sharing via temporary file + `share_plus`,
/// and preparing Try Again flows on `ResultScreen` (`/result/:jobId`).
class TryOnResultController extends Notifier<TryOnResultState> {
  TryOnResultController(this.jobId);

  final String jobId;

  CancelToken? _activeCancelToken;
  Future<void>? _inFlightLoadFuture;
  bool _isDisposed = false;

  @override
  TryOnResultState build() {
    final normalizedId = jobId.trim();
    _isDisposed = false;
    _inFlightLoadFuture = null;
    _activeCancelToken?.cancel('Controller rebuilt');
    _activeCancelToken = null;

    ref.onDispose(_disposeResources);

    // Seed initial job metadata if available from the recent submission flow.
    final submitted = ref.read(tryOnSubmissionControllerProvider).submittedJob;
    final initialJob = (submitted != null && submitted.jobId == normalizedId)
        ? submitted
        : null;

    // Seed person & garment input bytes from TryOnDraftController if present in RAM
    // for instant Before/After rendering while server media loads.
    final draft = ref.read(tryOnDraftControllerProvider);
    final initialPersonBytes = draft.personImage?.bytes;
    final initialGarmentBytes = draft.garmentImage?.bytes;

    Future<void>.microtask(loadResult);

    return TryOnResultState(
      jobId: normalizedId,
      job: initialJob,
      personImageBytes: initialPersonBytes,
      garmentImageBytes: initialGarmentBytes,
      isSaved: initialJob?.isSaved ?? false,
      isLoadingResult: true,
    );
  }

  /// Loads (or reloads) the job metadata, result image bytes, and input comparison images
  /// from [TryOnRepository].
  ///
  /// If a load request is already in-flight, returns the active [Future] so callers
  /// can deterministically await completion without duplicate requests.
  Future<void> loadResult() {
    final existing = _inFlightLoadFuture;
    if (existing != null) {
      return existing;
    }

    final future = _performLoadResult();
    _inFlightLoadFuture = future;
    return future;
  }

  Future<void> _performLoadResult() async {
    if (_isDisposed) {
      _inFlightLoadFuture = null;
      return;
    }

    final normalizedId = state.jobId.trim();
    if (normalizedId.isEmpty) {
      _inFlightLoadFuture = null;
      state = state.copyWith(
        isLoadingResult: false,
        loadError: ApiException(
          errorCode: ApiErrorCode.invalidRequest,
          rawCode: 'EMPTY_JOB_ID',
          message: ApiErrorCode.invalidRequest.defaultUserMessage,
          statusCode: 400,
        ),
      );
      return;
    }

    _activeCancelToken?.cancel('Reloading result');
    final cancelToken = CancelToken();
    _activeCancelToken = cancelToken;

    state = state.copyWith(
      isLoadingResult: true,
      clearLoadError: true,
    );

    final tryOnRepository = ref.read(tryOnRepositoryProvider);

    try {
      // 1. Fetch latest job metadata (`GET /api/v1/try-ons/{jobId}`).
      final fetchedJob = await tryOnRepository.getJobStatus(
        normalizedId,
        cancelToken: cancelToken,
      );

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      if (!fetchedJob.isSucceeded) {
        final errorCode = fetchedJob.isFailed
            ? (fetchedJob.error?.apiErrorCode ?? ApiErrorCode.aiProviderError)
            : ApiErrorCode.resultNotReady;
        final rawCode = fetchedJob.isFailed
            ? (fetchedJob.error?.errorCode ??
                  ApiErrorCode.aiProviderError.rawValue)
            : ApiErrorCode.resultNotReady.rawValue;
        final message = fetchedJob.isFailed
            ? (fetchedJob.error?.userFriendlyMessage ??
                  ApiErrorCode.aiProviderError.defaultUserMessage)
            : ApiErrorCode.resultNotReady.defaultUserMessage;

        state = state.copyWith(
          job: fetchedJob,
          isSaved: fetchedJob.isSaved,
          isLoadingResult: false,
          loadError: ApiException(
            errorCode: errorCode,
            rawCode: rawCode,
            message: message,
            statusCode: fetchedJob.isFailed ? 400 : 409,
          ),
        );
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

      // 3. Best-effort fetch of server-stored input images (`person` and `garment`)
      // for Before/After comparison (FR-09), falling back to seeded draft bytes if unavailable.
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
        // Keep existing draft fallback bytes if `/inputs/person` is unavailable.
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
        // Keep existing draft fallback bytes if `/inputs/garment` is unavailable.
      }

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      state = state.copyWith(
        job: fetchedJob,
        resultImageBytes: resultBytes,
        personImageBytes: personBytes,
        garmentImageBytes: garmentBytes,
        isSaved: fetchedJob.isSaved,
        isLoadingResult: false,
        clearLoadError: true,
      );
    } on ApiException catch (apiError) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        isLoadingResult: false,
        loadError: apiError,
      );
    } catch (unexpected) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        isLoadingResult: false,
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

  /// Saves the completed try-on result to History (`POST /api/v1/try-ons/{jobId}/save`)
  /// via [HistoryRepository.saveJob] (FR-11, Scenario T11).
  ///
  /// Idempotent: calling multiple times safely returns the single saved record on Backend.
  /// Concurrent calls while [state.isSaving] is `true` are ignored.
  Future<JobModel?> saveToHistory() async {
    if (_isDisposed || state.isSaving) {
      return null;
    }

    final normalizedId = state.jobId.trim();
    if (normalizedId.isEmpty) {
      return null;
    }

    state = state.copyWith(
      isSaving: true,
      clearSaveError: true,
    );

    final historyRepository = ref.read(historyRepositoryProvider);

    try {
      final savedJob = await historyRepository.saveJob(normalizedId);
      if (_isDisposed) {
        return null;
      }

      state = state.copyWith(
        job: savedJob,
        isSaving: false,
        isSaved: savedJob.isSaved,
        saveSuccessCount: state.saveSuccessCount + 1,
        clearSaveError: true,
      );
      ref.invalidate(historyControllerProvider);
      return savedJob;
    } on ApiException catch (apiError) {
      if (_isDisposed) {
        return null;
      }
      state = state.copyWith(
        isSaving: false,
        saveError: apiError,
      );
      return null;
    } catch (unexpected) {
      if (_isDisposed) {
        return null;
      }
      state = state.copyWith(
        isSaving: false,
        saveError: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
      return null;
    }
  }

  /// Writes the result image bytes to a local temporary file and opens the native OS
  /// share sheet via [ImageShareService] (`share_plus` — FR-15).
  ///
  /// Independent from Save and Try Again (`Save != Share != Retry`).
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

  /// Clears any active Save error banner.
  void clearSaveError() {
    if (state.saveError != null) {
      state = state.copyWith(clearSaveError: true);
    }
  }

  /// Clears any active Share error banner.
  void clearShareError() {
    if (state.shareErrorMessage != null) {
      state = state.copyWith(clearShareError: true);
    }
  }

  /// Prepares application state for a "Try Again" workflow (FR-10):
  /// - Resets [TryOnSubmissionController] so the next submission generates a fresh `Idempotency-Key`.
  /// - Preserves valid input images in [TryOnDraftController] by default (`clearDraft == false`)
  ///   so the user can quickly swap either the garment or person photo, or clears both when
  ///   `clearDraft == true`.
  void prepareTryAgain({bool clearDraft = false}) {
    ref.read(tryOnSubmissionControllerProvider.notifier).reset();
    if (clearDraft) {
      ref.read(tryOnDraftControllerProvider.notifier).clearDraft();
    }
  }

  void _disposeResources() {
    _isDisposed = true;
    _activeCancelToken?.cancel('TryOnResultController disposed');
    _activeCancelToken = null;
  }
}

/// Family provider for [TryOnResultController], keyed by `jobId`.
final tryOnResultControllerProvider = NotifierProvider.autoDispose
    .family<TryOnResultController, TryOnResultState, String>(
      TryOnResultController.new,
    );

