import 'package:flutter/foundation.dart';

import '../../../try_on/data/models/job_model.dart';

/// DTO representing a single saved virtual try-on item in user history,
/// matching `HistoryItemResponse` in `backend/app/schemas/history.py`.
@immutable
class HistoryItemModel {
  const HistoryItemModel({
    required this.jobId,
    required this.status,
    required this.personImageUrl,
    required this.garmentImageUrl,
    required this.resultImageUrl,
    required this.createdAt,
    this.isSaved = true,
    this.savedAt,
    this.completedAt,
  });

  final String jobId;
  final JobStatus status;
  final String personImageUrl;
  final String garmentImageUrl;
  final String resultImageUrl;
  final bool isSaved;
  final DateTime? savedAt;
  final DateTime createdAt;
  final DateTime? completedAt;

  factory HistoryItemModel.fromJson(Map<String, dynamic> json) {
    final rawJobId = json['job_id']?.toString();
    if (rawJobId == null || rawJobId.trim().isEmpty) {
      throw const FormatException(
        'Missing required field "job_id" in HistoryItemModel',
      );
    }

    final personUrl = json['person_image_url']?.toString() ?? '';
    final garmentUrl = json['garment_image_url']?.toString() ?? '';
    final resultUrl = json['result_image_url']?.toString() ?? '';

    final rawCreatedAt = json['created_at']?.toString();
    if (rawCreatedAt == null || rawCreatedAt.isEmpty) {
      throw const FormatException(
        'Missing required field "created_at" in HistoryItemModel',
      );
    }

    final rawSavedAt = json['saved_at']?.toString();
    final rawCompletedAt = json['completed_at']?.toString();

    return HistoryItemModel(
      jobId: rawJobId,
      status: JobStatus.fromRaw(json['status']?.toString()),
      personImageUrl: personUrl,
      garmentImageUrl: garmentUrl,
      resultImageUrl: resultUrl,
      isSaved: json['is_saved'] != false,
      savedAt: (rawSavedAt != null && rawSavedAt.isNotEmpty)
          ? DateTime.parse(rawSavedAt)
          : null,
      createdAt: DateTime.parse(rawCreatedAt),
      completedAt: (rawCompletedAt != null && rawCompletedAt.isNotEmpty)
          ? DateTime.parse(rawCompletedAt)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'status': status.rawValue,
      'person_image_url': personImageUrl,
      'garment_image_url': garmentImageUrl,
      'result_image_url': resultImageUrl,
      'is_saved': isSaved,
      'saved_at': savedAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HistoryItemModel &&
        other.jobId == jobId &&
        other.status == status &&
        other.personImageUrl == personImageUrl &&
        other.garmentImageUrl == garmentImageUrl &&
        other.resultImageUrl == resultImageUrl &&
        other.isSaved == isSaved &&
        other.savedAt == savedAt &&
        other.createdAt == createdAt &&
        other.completedAt == completedAt;
  }

  @override
  int get hashCode => Object.hash(
    jobId,
    status,
    personImageUrl,
    garmentImageUrl,
    resultImageUrl,
    isSaved,
    savedAt,
    createdAt,
    completedAt,
  );
}

/// Paginated collection of saved history items,
/// matching `HistoryListResponse` in `backend/app/schemas/history.py`.
@immutable
class HistoryListModel {
  const HistoryListModel({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<HistoryItemModel> items;
  final int total;
  final int limit;
  final int offset;

  /// True if there are more items available on subsequent pages.
  bool get hasMore => offset + items.length < total;

  factory HistoryListModel.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final parsedItems = <HistoryItemModel>[];
    if (rawItems is List) {
      for (final element in rawItems) {
        if (element is Map<String, dynamic>) {
          parsedItems.add(HistoryItemModel.fromJson(element));
        } else if (element is Map) {
          parsedItems.add(
            HistoryItemModel.fromJson(
              element.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
    }

    return HistoryListModel(
      items: List<HistoryItemModel>.unmodifiable(parsedItems),
      total: _parseInt(json['total'], fallback: parsedItems.length),
      limit: _parseInt(json['limit'], fallback: 20),
      offset: _parseInt(json['offset'], fallback: 0),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'items': items.map((e) => e.toJson()).toList(),
      'total': total,
      'limit': limit,
      'offset': offset,
    };
  }

  static int _parseInt(dynamic value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value != null) {
      return int.tryParse(value.toString()) ?? fallback;
    }
    return fallback;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HistoryListModel &&
        listEquals(other.items, items) &&
        other.total == total &&
        other.limit == limit &&
        other.offset == offset;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(items),
    total,
    limit,
    offset,
  );
}

