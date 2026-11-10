import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/network/api_error.dart';
import '../data/models/job_model.dart';
import '../data/try_on_repository.dart';
import 'try_on_submission_controller.dart';

/// Clock function signature for deterministic timeout testing.
typedef NowFn = DateTime Function();

/// Injectable clock provider (defaults to [DateTime.now]).
final nowProvider = Provider<NowFn>((ref) => DateTime.now);

/// Immutable state managed by [JobStatusController] for `ProcessingScreen` (`/processing/:jobId`).
///
/// Satisfies:
/// - **FR-07:** Clearly communicates active processing states (`queued` -> `processing`).
/// - **FR-08:** Signals completion when `status == succeeded` so UI navigates to `ResultScreen`.
/// - **FR-16 & NFR-02:** Exposes structured failure details when `status == failed` or a
///   terminal lookup error (`404 JOB_NOT_FOUND`) occurs.
/// - **T09 (`network failure != job failed`):** Preserves [jobId] and last known [job]
///   when transient network/5xx errors occur, surfacing [transientError] while continuing to poll.
@immutable
class JobStatusState {
  const JobStatusState({
    required this.jobId,
    this.job,
    this.isPolling = false,
    this.isFetching = false,
    this.isPausedByLifecycle = false,
    this.pollAttemptCount = 0,
    this.consecutiveTransientErrors = 0,
    this.transientError,
    this.fatalError,
  });

  /// Target job UUID being tracked.
  final String jobId;

  /// Latest [JobModel] snapshot received from Backend.
  final JobModel? job;

  /// True while the single polling loop is active for [jobId].
  final bool isPolling;

  /// True while an HTTP `GET /api/v1/try-ons/{jobId}` request is currently in-flight.
  final bool isFetching;

  /// True when polling is temporarily paused because the app moved to background.
  final bool isPausedByLifecycle;

  /// Total number of status poll requests attempted.
  final int pollAttemptCount;

  /// Number of consecutive transient network/5xx errors encountered.
  final int consecutiveTransientErrors;

  /// Non-fatal connectivity/5xx error encountered during polling (T09).
  /// Does NOT mark the job as failed.
  final ApiException? transientError;

  /// Terminal client/HTTP error that stopped polling (e.g., 404 Not Found or polling timeout).
  final ApiException? fatalError;

  /// Current lifecycle status of the job (defaults to [JobStatus.queued] before first response).
  JobStatus get effectiveStatus => job?.status ?? JobStatus.queued;

  /// True when the job is waiting in the queue (`queued` or initial fetch).
  bool get isQueued =>
      !isTerminal && (job == null || job!.status == JobStatus.queued);

  /// True when the Celery Worker has claimed the job and is actively running AI inference.
  bool get isProcessing =>
      !isTerminal && job?.status == JobStatus.processing;

  /// True when the job completed successfully (`status == succeeded`).
  bool get isSucceeded => job?.status == JobStatus.succeeded;

  /// True when the job reached terminal `failed` status on Backend OR encountered a [fatalError].
  bool get isFailed => job?.status == JobStatus.failed || fatalError != null;

  /// True when polling has reached a terminal state ([isSucceeded] or [isFailed]).
  bool get isTerminal => isSucceeded || isFailed;

  /// True when a temporary network drop occurred during active polling (Scenario T09).
  bool get hasTransientNetworkIssue => transientError != null && !isTerminal;

  /// Raw error code from Backend `job.error` or client [fatalError], if any.
  String? get effectiveErrorCode {
    if (job?.error != null) {
      return job!.error!.errorCode;
    }
    if (fatalError != null) {
      return fatalError!.rawCode.isNotEmpty
          ? fatalError!.rawCode
          : fatalError!.errorCode.rawValue;
    }
    return null;
  }

  /// User-friendly Vietnamese error message for terminal failure presentation (FR-16, NFR-02).
  String? get effectiveErrorMessage {
    if (job?.status == JobStatus.failed) {
      return job?.error?.userFriendlyMessage ??
          ApiErrorCode.aiProviderError.defaultUserMessage;
    }
    if (fatalError != null) {
      return fatalError!.userFriendlyMessage;
    }
    return null;
  }

  JobStatusState copyWith({
    String? jobId,
    JobModel? job,
    bool? isPolling,
    bool? isFetching,
    bool? isPausedByLifecycle,
    int? pollAttemptCount,
    int? consecutiveTransientErrors,
    ApiException? transientError,
    bool clearTransientError = false,
    ApiException? fatalError,
    bool clearFatalError = false,
  }) {
    return JobStatusState(
      jobId: jobId ?? this.jobId,
      job: job ?? this.job,
      isPolling: isPolling ?? this.isPolling,
      isFetching: isFetching ?? this.isFetching,
      isPausedByLifecycle: isPausedByLifecycle ?? this.isPausedByLifecycle,
      pollAttemptCount: pollAttemptCount ?? this.pollAttemptCount,
      consecutiveTransientErrors:
          consecutiveTransientErrors ?? this.consecutiveTransientErrors,
      transientError:
          clearTransientError ? null : (transientError ?? this.transientError),
      fatalError: clearFatalError ? null : (fatalError ?? this.fatalError),
    );
  }
}

/// Riverpod [Notifier] that runs a strictly single-flight status polling loop
/// for a specific `jobId` (`GET /api/v1/try-ons/{jobId}`).
///
/// Key architecture guarantees:
/// 1. **Single-loop per job:** Never schedules overlapping `Timer` instances or concurrent
///    HTTP GET requests for the same job. The next timer is scheduled *only after* the
///    current GET request completes.
/// 2. **Immediate stop on terminal state:** Stops polling as soon as `succeeded`, `failed`,
///    or HTTP `404` is observed.
/// 3. **Network failure != job failed (T09):** Connection errors, timeouts, and HTTP 502/503/504
///    keep the `jobId` and last known status intact, set [JobStatusState.transientError], and
///    automatically continue polling.
/// 4. **Lifecycle-aware:** Pauses timer when the app is backgrounded and resumes immediately
///    when foregrounded.
class JobStatusController extends Notifier<JobStatusState> {
  JobStatusController(this.jobId);

  final String jobId;

  Timer? _scheduledTimer;
  CancelToken? _activeCancelToken;
  bool _isTickInFlight = false;
  bool _isDisposed = false;
  late DateTime _pollingStartedAt;

  @override
  JobStatusState build() {
    final normalizedId = jobId.trim();
    _isDisposed = false;
    _isTickInFlight = false;
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _activeCancelToken?.cancel('Controller rebuilt');
    _activeCancelToken = null;
    _pollingStartedAt = ref.read(nowProvider)();

    ref.onDispose(_disposeResources);

    // Seed initial job snapshot if it was just created by TryOnSubmissionController.
    final lastSubmitted = ref.read(tryOnSubmissionControllerProvider).submittedJob;
    final initialJob =
        (lastSubmitted != null && lastSubmitted.jobId == normalizedId)
            ? lastSubmitted
            : null;

    if (initialJob != null && initialJob.isTerminal) {
      return JobStatusState(
        jobId: normalizedId,
        job: initialJob,
        isPolling: false,
      );
    }

    Future<void>.microtask(_executePollTick);

    return JobStatusState(
      jobId: normalizedId,
      job: initialJob,
      isPolling: true,
    );
  }

  /// Pauses the polling loop when the application moves to the background.
  void pausePolling() {
    if (_isDisposed || state.isTerminal || state.isPausedByLifecycle) {
      return;
    }
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _activeCancelToken?.cancel('App backgrounded');
    _activeCancelToken = null;
    _isTickInFlight = false;

    state = state.copyWith(
      isPausedByLifecycle: true,
      isPolling: false,
      isFetching: false,
    );
  }

  /// Resumes polling immediately when the application returns to the foreground.
  Future<void> resumePolling() async {
    if (_isDisposed || state.isTerminal || !state.isPausedByLifecycle) {
      return;
    }
    state = state.copyWith(
      isPausedByLifecycle: false,
      isPolling: true,
    );
    await _executePollTick();
  }

  /// Manually triggers an immediate status check (e.g., when user taps "Thử kết nối lại ngay"
  /// during a transient network drop or "Kiểm tra lại trạng thái" after a polling timeout).
  Future<void> refreshNow() async {
    if (_isDisposed || state.isSucceeded || state.job?.isFailed == true) {
      return;
    }
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _pollingStartedAt = ref.read(nowProvider)();

    state = state.copyWith(
      isPolling: true,
      isPausedByLifecycle: false,
      clearFatalError: true,
    );

    if (!_isTickInFlight) {
      await _executePollTick();
    }
  }

  /// Explicitly stops polling.
  void stopPolling() {
    if (_isDisposed) {
      return;
    }
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _activeCancelToken?.cancel('Polling stopped');
    _activeCancelToken = null;
    _isTickInFlight = false;

    if (state.isPolling || state.isFetching) {
      state = state.copyWith(
        isPolling: false,
        isFetching: false,
      );
    }
  }

  Future<void> _executePollTick() async {
    if (_isDisposed ||
        state.isPausedByLifecycle ||
        state.isTerminal ||
        !state.isPolling ||
        _isTickInFlight) {
      return;
    }

    _scheduledTimer?.cancel();
    _scheduledTimer = null;

    final config = ref.read(appConfigProvider);
    final now = ref.read(nowProvider)();

    if (state.pollAttemptCount > 0 &&
        now.difference(_pollingStartedAt) >= config.maxPollingDuration) {
      _handlePollingTimeout();
      return;
    }

    if (state.jobId.isEmpty) {
      state = state.copyWith(
        isPolling: false,
        isFetching: false,
        fatalError: ApiException(
          errorCode: ApiErrorCode.invalidRequest,
          rawCode: 'EMPTY_JOB_ID',
          message: ApiErrorCode.invalidRequest.defaultUserMessage,
          statusCode: 400,
        ),
      );
      return;
    }

    _isTickInFlight = true;
    final cancelToken = CancelToken();
    _activeCancelToken = cancelToken;

    state = state.copyWith(
      isFetching: true,
      pollAttemptCount: state.pollAttemptCount + 1,
    );

    final repository = ref.read(tryOnRepositoryProvider);

    try {
      final fetchedJob = await repository.getJobStatus(
        state.jobId,
        cancelToken: cancelToken,
      );

      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      _isTickInFlight = false;
      _activeCancelToken = null;

      if (fetchedJob.isTerminal) {
        state = state.copyWith(
          job: fetchedJob,
          isPolling: false,
          isFetching: false,
          consecutiveTransientErrors: 0,
          clearTransientError: true,
          clearFatalError: true,
        );
        return;
      }

      // Job is still active (`queued` or `processing`).
      final afterFetchNow = ref.read(nowProvider)();
      if (afterFetchNow.difference(_pollingStartedAt) >=
          config.maxPollingDuration) {
        state = state.copyWith(
          job: fetchedJob,
          isPolling: false,
          isFetching: false,
          clearTransientError: true,
          fatalError: _buildTimeoutException(),
        );
        return;
      }

      state = state.copyWith(
        job: fetchedJob,
        isPolling: true,
        isFetching: false,
        consecutiveTransientErrors: 0,
        clearTransientError: true,
        clearFatalError: true,
      );

      _scheduleNextTick(config.pollingInterval);
    } on ApiException catch (apiError) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      _isTickInFlight = false;
      _activeCancelToken = null;

      if (_isTransientPollingError(apiError)) {
        final afterErrorNow = ref.read(nowProvider)();
        if (afterErrorNow.difference(_pollingStartedAt) >=
            config.maxPollingDuration) {
          _handlePollingTimeout();
          return;
        }

        // Scenario T09: Network failure != job failed.
        // Preserve jobId and last known job state, expose transientError, and keep polling.
        state = state.copyWith(
          isPolling: true,
          isFetching: false,
          consecutiveTransientErrors: state.consecutiveTransientErrors + 1,
          transientError: apiError,
        );
        _scheduleNextTick(config.pollingInterval);
        return;
      }

      // Terminal error (e.g., 404 JOB_NOT_FOUND or 400/422 INVALID_REQUEST): stop polling.
      state = state.copyWith(
        isPolling: false,
        isFetching: false,
        clearTransientError: true,
        fatalError: apiError,
      );
    } catch (unexpected) {
      if (_isDisposed || cancelToken.isCancelled) {
        return;
      }

      _isTickInFlight = false;
      _activeCancelToken = null;

      state = state.copyWith(
        isPolling: false,
        isFetching: false,
        clearTransientError: true,
        fatalError: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
    }
  }

  void _scheduleNextTick(Duration delay) {
    if (_isDisposed ||
        state.isPausedByLifecycle ||
        state.isTerminal ||
        !state.isPolling) {
      return;
    }
    _scheduledTimer?.cancel();
    _scheduledTimer = Timer(delay, _executePollTick);
  }

  void _handlePollingTimeout() {
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    state = state.copyWith(
      isPolling: false,
      isFetching: false,
      clearTransientError: true,
      fatalError: _buildTimeoutException(),
    );
  }

  static ApiException _buildTimeoutException() {
    return ApiException(
      errorCode: ApiErrorCode.timeoutError,
      rawCode: 'POLLING_TIMEOUT',
      message: ApiErrorCode.timeoutError.defaultUserMessage,
      isNetworkError: true,
    );
  }

  static bool _isTransientPollingError(ApiException error) {
    if (error.isNetworkError) {
      return true;
    }
    final status = error.statusCode;
    return status == 408 ||
        status == 429 ||
        status == 500 ||
        status == 502 ||
        status == 503 ||
        status == 504;
  }

  void _disposeResources() {
    _isDisposed = true;
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _activeCancelToken?.cancel('JobStatusController disposed');
    _activeCancelToken = null;
    _isTickInFlight = false;
  }
}

/// Family provider for [JobStatusController], keyed by `jobId`.
///
/// Uses `autoDispose` so leaving `ProcessingScreen` automatically cancels timers
/// and in-flight HTTP requests for that job.
final jobStatusControllerProvider = NotifierProvider.autoDispose
    .family<JobStatusController, JobStatusState, String>(
      JobStatusController.new,
    );

