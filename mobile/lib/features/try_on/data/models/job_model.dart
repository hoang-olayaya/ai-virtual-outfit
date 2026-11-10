import 'package:flutter/foundation.dart';

import '../../../../core/network/api_error.dart';

/// Lifecycle states of a Virtual Try-On job, matching `JobStatus` in `backend/app/models/try_on_job.py`.
enum JobStatus {
  queued('queued'),
  processing('processing'),
  succeeded('succeeded'),
  failed('failed');

  const JobStatus(this.rawValue);

  final String rawValue;

  /// True when the job is still active and requires status polling.
  bool get isActive => this == JobStatus.queued || this == JobStatus.processing;

  /// True when the job has reached a terminal state and polling must stop.
  bool get isTerminal =>
      this == JobStatus.succeeded || this == JobStatus.failed;

  static JobStatus fromRaw(String? raw) {
    final normalized = raw?.trim().toLowerCase();
    for (final value in JobStatus.values) {
      if (value.rawValue == normalized) {
        return value;
      }
    }
    throw FormatException('Unknown JobStatus value: $raw');
  }
}

/// Structured error information attached to a failed or retried job,
/// matching `JobErrorDetail` in `backend/app/schemas/job.py`.
@immutable
class JobErrorDetailModel {
  const JobErrorDetailModel({
    required this.errorCode,
    required this.message,
  });

  final String errorCode;
  final String message;

  /// Strongly-typed enum representation of [errorCode].
  ApiErrorCode get apiErrorCode => ApiErrorCode.fromRaw(errorCode);

  /// User-friendly localized message in Vietnamese.
  String get userFriendlyMessage => apiErrorCode.defaultUserMessage;

  factory JobErrorDetailModel.fromJson(Map<String, dynamic> json) {
    return JobErrorDetailModel(
      errorCode: json['error_code']?.toString() ?? 'UNKNOWN_ERROR',
      message:
          json['message']?.toString() ??
          'Job failed with an unspecified error.',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'error_code': errorCode,
      'message': message,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is JobErrorDetailModel &&
        other.errorCode == errorCode &&
        other.message == message;
  }

  @override
  int get hashCode => Object.hash(errorCode, message);
}

/// Unified DTO matching `JobResponse` returned by:
/// - `POST /api/v1/try-ons` (202 Accepted)
/// - `GET /api/v1/try-ons/{job_id}` (200 OK)
/// - `POST /api/v1/try-ons/{job_id}/save` (200 OK)
@immutable
class JobModel {
  const JobModel({
    required this.jobId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.resultImageUrl,
    this.personImageUrl,
    this.garmentImageUrl,
    this.error,
    this.isSaved = false,
    this.savedAt,
    this.completedAt,
  });

  final String jobId;
  final JobStatus status;
  final String? resultImageUrl;
  final String? personImageUrl;
  final String? garmentImageUrl;
  final JobErrorDetailModel? error;
  final bool isSaved;
  final DateTime? savedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  bool get isSucceeded => status == JobStatus.succeeded;
  bool get isFailed => status == JobStatus.failed;
  bool get isActive => status.isActive;
  bool get isTerminal => status.isTerminal;

  factory JobModel.fromJson(Map<String, dynamic> json) {
    final rawId = json['job_id']?.toString();
    if (rawId == null || rawId.trim().isEmpty) {
      throw const FormatException('Missing required field "job_id" in JobModel');
    }

    final rawError = json['error'];
    JobErrorDetailModel? parsedError;
    if (rawError is Map<String, dynamic>) {
      parsedError = JobErrorDetailModel.fromJson(rawError);
    } else if (rawError is Map) {
      parsedError = JobErrorDetailModel.fromJson(
        rawError.map((key, value) => MapEntry(key.toString(), value)),
      );
    }

    return JobModel(
      jobId: rawId,
      status: JobStatus.fromRaw(json['status']?.toString()),
      resultImageUrl: json['result_image_url']?.toString(),
      personImageUrl: json['person_image_url']?.toString(),
      garmentImageUrl: json['garment_image_url']?.toString(),
      error: parsedError,
      isSaved: json['is_saved'] == true,
      savedAt: _parseNullableDateTime(json['saved_at']),
      createdAt: _parseRequiredDateTime(json['created_at'], 'created_at'),
      updatedAt: _parseRequiredDateTime(json['updated_at'], 'updated_at'),
      completedAt: _parseNullableDateTime(json['completed_at']),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'status': status.rawValue,
      'result_image_url': resultImageUrl,
      'person_image_url': personImageUrl,
      'garment_image_url': garmentImageUrl,
      'error': error?.toJson(),
      'is_saved': isSaved,
      'saved_at': savedAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
    };
  }

  JobModel copyWith({
    String? jobId,
    JobStatus? status,
    String? resultImageUrl,
    String? personImageUrl,
    String? garmentImageUrl,
    JobErrorDetailModel? error,
    bool? isSaved,
    DateTime? savedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? completedAt,
  }) {
    return JobModel(
      jobId: jobId ?? this.jobId,
      status: status ?? this.status,
      resultImageUrl: resultImageUrl ?? this.resultImageUrl,
      personImageUrl: personImageUrl ?? this.personImageUrl,
      garmentImageUrl: garmentImageUrl ?? this.garmentImageUrl,
      error: error ?? this.error,
      isSaved: isSaved ?? this.isSaved,
      savedAt: savedAt ?? this.savedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  static DateTime _parseRequiredDateTime(dynamic value, String fieldName) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) {
      throw FormatException('Missing required DateTime field "$fieldName"');
    }
    return DateTime.parse(raw);
  }

  static DateTime? _parseNullableDateTime(dynamic value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return DateTime.parse(raw);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is JobModel &&
        other.jobId == jobId &&
        other.status == status &&
        other.resultImageUrl == resultImageUrl &&
        other.personImageUrl == personImageUrl &&
        other.garmentImageUrl == garmentImageUrl &&
        other.error == error &&
        other.isSaved == isSaved &&
        other.savedAt == savedAt &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt &&
        other.completedAt == completedAt;
  }

  @override
  int get hashCode => Object.hash(
    jobId,
    status,
    resultImageUrl,
    personImageUrl,
    garmentImageUrl,
    error,
    isSaved,
    savedAt,
    createdAt,
    updatedAt,
    completedAt,
  );
}

