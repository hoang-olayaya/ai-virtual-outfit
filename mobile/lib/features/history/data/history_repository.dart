import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/dio_client.dart';
import '../../try_on/data/models/job_model.dart';
import 'models/history_item_model.dart';

/// Repository responsible for saving completed Try-On results to history,
/// listing saved history items, fetching history item details, and deleting items.
///
/// Architecture Rule: History data is always fetched from the PostgreSQL Backend,
/// never relying solely on ephemeral in-memory state across app restarts.
class HistoryRepository {
  const HistoryRepository({
    required this.dioClient,
  });

  final DioClient dioClient;

  AppConfig get config => dioClient.config;

  /// Marks a succeeded try-on job as saved in user history (`POST /api/v1/try-ons/{job_id}/save`).
  /// Idempotent: calling multiple times returns the same saved [JobModel].
  Future<JobModel> saveJob(
    String jobId, {
    CancelToken? cancelToken,
  }) async {
    final normalizedId = jobId.trim();
    final json = await dioClient.postJson(
      '${config.apiV1Prefix}/try-ons/$normalizedId/save',
      cancelToken: cancelToken,
    );
    return JobModel.fromJson(json);
  }

  /// Retrieves a paginated list of saved history items (`GET /api/v1/history`).
  Future<HistoryListModel> getHistoryList({
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final json = await dioClient.getJson(
      '${config.apiV1Prefix}/history',
      queryParameters: <String, dynamic>{
        'limit': limit,
        'offset': offset,
      },
      cancelToken: cancelToken,
    );
    return HistoryListModel.fromJson(json);
  }

  /// Retrieves full metadata and image URLs for a single saved item (`GET /api/v1/history/{job_id}`).
  Future<HistoryItemModel> getHistoryDetail(
    String jobId, {
    CancelToken? cancelToken,
  }) async {
    final normalizedId = jobId.trim();
    final json = await dioClient.getJson(
      '${config.apiV1Prefix}/history/$normalizedId',
      cancelToken: cancelToken,
    );
    return HistoryItemModel.fromJson(json);
  }

  /// Deletes a saved item from history and cleans up its stored files (`DELETE /api/v1/history/{job_id}`).
  Future<void> deleteHistoryItem(
    String jobId, {
    CancelToken? cancelToken,
  }) {
    final normalizedId = jobId.trim();
    return dioClient.delete(
      '${config.apiV1Prefix}/history/$normalizedId',
      cancelToken: cancelToken,
    );
  }
}

/// Riverpod provider for [HistoryRepository].
final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  final dioClient = ref.watch(dioClientProvider);
  return HistoryRepository(dioClient: dioClient);
});

