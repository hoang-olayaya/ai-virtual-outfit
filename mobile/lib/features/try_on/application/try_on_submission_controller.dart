import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/api_error.dart';
import '../data/models/job_model.dart';
import '../data/try_on_repository.dart';
import 'try_on_draft_controller.dart';

/// Immutable state managed by [TryOnSubmissionController] when submitting
/// a Virtual Try-On request (`POST /api/v1/try-ons`).
///
/// Satisfies:
/// - **FR-05:** Verifies both input images are ready before submitting.
/// - **FR-06:** Submits person + garment images to create a try-on job.
/// - **FR-16 & NFR-05:** Captures structured [ApiException] errors while preserving
///   draft images so the user can retry immediately.
/// - **T10 (Double-Submit & Idempotency Protection):** Blocks concurrent submissions
///   ([isSubmitting]) and preserves [idempotencyKey] across transient network retries
///   for the same draft image pair.
@immutable
class TryOnSubmissionState {
  const TryOnSubmissionState({
    this.isSubmitting = false,
    this.submittedJob,
    this.error,
    this.idempotencyKey,
    this.draftFingerprint,
  });

  /// True while `POST /api/v1/try-ons` is in flight.
  final bool isSubmitting;

  /// Most recently created [JobModel] returned by `POST /api/v1/try-ons` (202 Accepted).
  final JobModel? submittedJob;

  /// Structured error if the last submission attempt failed.
  final ApiException? error;

  /// Active idempotency key bound to [draftFingerprint] for safe retry after transient errors.
  final String? idempotencyKey;

  /// Fingerprint of the `(personImage, garmentImage)` pair associated with [idempotencyKey].
  final String? draftFingerprint;

  /// True if there is an active submission error to display.
  bool get hasError => error != null;

  /// User-friendly localized Vietnamese error message if [error] is present.
  String? get errorMessage => error?.userFriendlyMessage;

  /// Job ID of the most recently submitted job, if any.
  String? get activeJobId => submittedJob?.jobId;

  TryOnSubmissionState copyWith({
    bool? isSubmitting,
    JobModel? submittedJob,
    bool clearSubmittedJob = false,
    ApiException? error,
    bool clearError = false,
    String? idempotencyKey,
    bool clearIdempotencyKey = false,
    String? draftFingerprint,
    bool clearDraftFingerprint = false,
  }) {
    return TryOnSubmissionState(
      isSubmitting: isSubmitting ?? this.isSubmitting,
      submittedJob:
          clearSubmittedJob ? null : (submittedJob ?? this.submittedJob),
      error: clearError ? null : (error ?? this.error),
      idempotencyKey:
          clearIdempotencyKey ? null : (idempotencyKey ?? this.idempotencyKey),
      draftFingerprint: clearDraftFingerprint
          ? null
          : (draftFingerprint ?? this.draftFingerprint),
    );
  }
}

/// Riverpod [Notifier] that coordinates Virtual Try-On job creation from [TryOnDraftState].
class TryOnSubmissionController extends Notifier<TryOnSubmissionState> {
  static const Uuid _uuid = Uuid();

  @override
  TryOnSubmissionState build() {
    return const TryOnSubmissionState();
  }

  /// Submits the currently selected Person and Garment images in [TryOnDraftController]
  /// to `POST /api/v1/try-ons`.
  ///
  /// Guarantees:
  /// - **No double-submit:** Returns `null` immediately if [state.isSubmitting] is `true`.
  /// - **Readiness check (FR-05):** Rejects with [ApiErrorCode.missingInputImage] if either
  ///   image is missing.
  /// - **Idempotency key reuse (T10):** Reuses the same `Idempotency-Key` when retrying
  ///   the exact same draft pair after a network/5xx failure so the Backend never creates
  ///   duplicate jobs for a retried request.
  Future<JobModel?> submitDraft() async {
    if (state.isSubmitting) {
      return null;
    }

    final draft = ref.read(tryOnDraftControllerProvider);
    final person = draft.personImage;
    final garment = draft.garmentImage;

    if (!draft.isReady || person == null || garment == null) {
      state = state.copyWith(
        isSubmitting: false,
        error: ApiException(
          errorCode: ApiErrorCode.missingInputImage,
          rawCode: ApiErrorCode.missingInputImage.rawValue,
          message: ApiErrorCode.missingInputImage.defaultUserMessage,
          statusCode: 400,
        ),
      );
      return null;
    }

    final fingerprint = _computeDraftFingerprint(person, garment);
    final effectiveKey = (state.draftFingerprint == fingerprint &&
            state.idempotencyKey != null &&
            state.idempotencyKey!.isNotEmpty)
        ? state.idempotencyKey!
        : _uuid.v4();

    state = state.copyWith(
      isSubmitting: true,
      clearError: true,
      idempotencyKey: effectiveKey,
      draftFingerprint: fingerprint,
    );

    final repository = ref.read(tryOnRepositoryProvider);

    try {
      final job = await repository.createTryOnJobFromBytes(
        personBytes: person.bytes,
        garmentBytes: garment.bytes,
        personFileName: person.fileName,
        garmentFileName: garment.fileName,
        idempotencyKey: effectiveKey,
      );

      // Submission succeeded (202 Accepted): store the job and clear the pending
      // retry key so a subsequent fresh "Try Again" submission gets a new key.
      state = state.copyWith(
        isSubmitting: false,
        submittedJob: job,
        clearError: true,
        clearIdempotencyKey: true,
        clearDraftFingerprint: true,
      );
      return job;
    } on ApiException catch (apiError) {
      final shouldPreserveKey = _isRetryableSubmissionError(apiError);
      state = state.copyWith(
        isSubmitting: false,
        error: apiError,
        clearIdempotencyKey: !shouldPreserveKey,
        clearDraftFingerprint: !shouldPreserveKey,
      );
      return null;
    } catch (unexpected) {
      state = state.copyWith(
        isSubmitting: false,
        error: ApiException(
          errorCode: ApiErrorCode.unknownError,
          rawCode: ApiErrorCode.unknownError.rawValue,
          message: unexpected.toString(),
        ),
      );
      return null;
    }
  }

  /// Clears any active submission error banner.
  void clearError() {
    if (state.error != null) {
      state = state.copyWith(clearError: true);
    }
  }

  /// Resets the submission controller state.
  void reset() {
    state = const TryOnSubmissionState();
  }

  static bool _isRetryableSubmissionError(ApiException error) {
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

  static String _computeDraftFingerprint(
    SelectedDraftImage person,
    SelectedDraftImage garment,
  ) {
    final pHead = person.bytes.isNotEmpty ? person.bytes.first : 0;
    final pTail = person.bytes.isNotEmpty ? person.bytes.last : 0;
    final gHead = garment.bytes.isNotEmpty ? garment.bytes.first : 0;
    final gTail = garment.bytes.isNotEmpty ? garment.bytes.last : 0;
    return '${person.fileName}:${person.sizeBytes}:$pHead:$pTail|'
        '${garment.fileName}:${garment.sizeBytes}:$gHead:$gTail';
  }
}

/// Riverpod provider for [TryOnSubmissionController].
final tryOnSubmissionControllerProvider =
    NotifierProvider<TryOnSubmissionController, TryOnSubmissionState>(
      TryOnSubmissionController.new,
    );

