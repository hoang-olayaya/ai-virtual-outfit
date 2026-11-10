import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../application/history_controller.dart';
import '../../data/models/history_item_model.dart';

/// History Screen (`/history`): Displays the paginated list of saved virtual try-on results
/// retrieved from the PostgreSQL Backend (`GET /api/v1/history`).
///
/// Implements FR-12, FR-13, FR-14, FR-16, NFR-02, NFR-03, and Scenario T11 in Phase F05:
/// - Always fetches persisted history from the Backend via [HistoryController] -> `HistoryRepository`.
/// - Loads result thumbnail bytes through [HistoryController] -> `TryOnRepository`
///   (Widgets never make direct HTTP calls).
/// - Supports pagination (`loadMore`), pull-to-refresh (`refresh`), opening `HistoryDetailScreen`,
///   and deleting items with a confirmation dialog and error recovery.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  /// Default sample UUID used in router shell tests.
  static const String sampleHistoryJobId =
      '00000000-0000-0000-0000-000000000001';

  Future<void> _confirmAndDeleteItem(
    BuildContext context,
    HistoryController controller,
    HistoryItemModel item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('history_delete_confirm_dialog'),
        title: const Text('Xóa kết quả đã lưu?'),
        content: Text(
          'Kết quả thử trang phục (Job ID: ${item.jobId}) sẽ bị xóa vĩnh viễn khỏi Lịch sử.',
        ),
        actions: [
          TextButton(
            key: const Key('history_delete_cancel_button'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            key: const Key('history_delete_confirm_button'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xóa kết quả'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) {
      return;
    }

    final deleted = await controller.deleteItem(item.jobId);
    if (deleted && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            key: Key('history_delete_success_snackbar'),
            content: Text('Đã xóa kết quả khỏi Lịch sử.'),
            duration: Duration(seconds: 2),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyState = ref.watch(historyControllerProvider);
    final controller = ref.read(historyControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử đã lưu'),
        actions: [
          if (!historyState.isLoadingInitial && historyState.loadError == null)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Container(
                  key: const Key('history_total_count_badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${historyState.total} mục',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            key: const Key('history_refresh_button'),
            tooltip: 'Làm mới lịch sử',
            onPressed: historyState.isLoadingInitial
                ? null
                : () => controller.refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (historyState.effectiveDeleteErrorMessage != null) ...[
                _HistoryActionErrorBanner(
                  bannerKey: const Key('history_delete_error_banner'),
                  textKey: const Key('history_delete_error_text'),
                  dismissButtonKey: const Key(
                    'dismiss_history_delete_error_button',
                  ),
                  message: historyState.effectiveDeleteErrorMessage!,
                  onDismiss: controller.clearDeleteError,
                ),
                const SizedBox(height: 10),
              ],
              Expanded(
                child: _buildMainBody(
                  context,
                  historyState: historyState,
                  controller: controller,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainBody(
    BuildContext context, {
    required HistoryListState historyState,
    required HistoryController controller,
  }) {
    if (historyState.isLoadingInitial && historyState.items.isEmpty) {
      return const _HistoryLoadingCard();
    }

    if (historyState.loadError != null && historyState.items.isEmpty) {
      final error = historyState.loadError!;
      return _HistoryLoadErrorCard(
        errorMessage:
            historyState.effectiveLoadErrorMessage ??
            'Không thể tải danh sách lịch sử đã lưu.',
        errorCode: error.rawCode.isNotEmpty
            ? error.rawCode
            : error.errorCode.rawValue,
        onRetry: () => controller.loadInitial(),
      );
    }

    if (historyState.items.isEmpty) {
      return _HistoryEmptyCard(
        onTryNow: () => context.go(AppRoutes.upload),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 160 &&
            historyState.hasMore &&
            !historyState.isLoadingMore &&
            historyState.loadMoreError == null) {
          controller.loadMore();
        }
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => controller.refresh(),
        child: ListView.separated(
          key: const Key('history_list_view'),
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount:
              historyState.items.length +
              ((historyState.hasMore ||
                      historyState.isLoadingMore ||
                      historyState.loadMoreError != null)
                  ? 1
                  : 0),
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            if (index >= historyState.items.length) {
              return _HistoryPaginationFooter(
                isLoadingMore: historyState.isLoadingMore,
                errorMessage: historyState.effectiveLoadMoreErrorMessage,
                onLoadMore: controller.loadMore,
              );
            }

            final item = historyState.items[index];
            final thumbnailBytes = historyState.thumbnailFor(item.jobId);
            final isLoadingThumb = historyState.isLoadingThumbnail(item.jobId);
            final isDeleting = historyState.isDeletingJob(item.jobId);

            return _HistoryItemCard(
              item: item,
              isFirstItem: index == 0,
              thumbnailBytes: thumbnailBytes,
              isLoadingThumbnail: isLoadingThumb,
              isDeleting: isDeleting,
              onOpenDetail: () => context.push(
                AppRoutes.historyDetailPath(item.jobId),
              ),
              onDelete: () => _confirmAndDeleteItem(
                context,
                controller,
                item,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HistoryItemCard extends StatelessWidget {
  const _HistoryItemCard({
    required this.item,
    required this.isFirstItem,
    required this.thumbnailBytes,
    required this.isLoadingThumbnail,
    required this.isDeleting,
    required this.onOpenDetail,
    required this.onDelete,
  });

  final HistoryItemModel item;
  final bool isFirstItem;
  final Uint8List? thumbnailBytes;
  final bool isLoadingThumbnail;
  final bool isDeleting;
  final VoidCallback onOpenDetail;
  final VoidCallback onDelete;

  static String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final year = local.year;
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayTime = item.savedAt ?? item.completedAt ?? item.createdAt;

    return Card(
      key: Key('history_item_card_${item.jobId}'),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: InkWell(
        key: isFirstItem ? const Key('history_open_detail_button') : null,
        borderRadius: BorderRadius.circular(14),
        onTap: isDeleting ? null : onOpenDetail,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 84,
                  height: 104,
                  color: colorScheme.surfaceContainerHighest,
                  child: _buildThumbnail(colorScheme),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.green),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.bookmark_added_rounded,
                                size: 12,
                                color: Colors.green,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Đã lưu',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Colors.green.shade800,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _formatTimestamp(displayTime),
                            key: Key('history_item_timestamp_${item.jobId}'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Kết quả thử trang phục AI',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Job ID: ${item.jobId}',
                      key: Key('history_item_job_id_${item.jobId}'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            key: Key(
                              'history_open_detail_button_${item.jobId}',
                            ),
                            onPressed: isDeleting ? null : onOpenDetail,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 16,
                            ),
                            label: const Text('Xem chi tiết'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          key: Key('history_delete_button_${item.jobId}'),
                          tooltip: 'Xóa khỏi lịch sử',
                          onPressed: isDeleting ? null : onDelete,
                          icon: isDeleting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.delete_outline_rounded,
                                  color: colorScheme.error,
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme colorScheme) {
    final bytes = thumbnailBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        key: Key('history_item_thumbnail_${item.jobId}'),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => Icon(
          Icons.broken_image_outlined,
          color: colorScheme.error,
        ),
      );
    }

    if (isLoadingThumbnail) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return Center(
      child: Icon(
        Icons.checkroom_rounded,
        size: 32,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _HistoryPaginationFooter extends StatelessWidget {
  const _HistoryPaginationFooter({
    required this.isLoadingMore,
    required this.errorMessage,
    required this.onLoadMore,
  });

  final bool isLoadingMore;
  final String? errorMessage;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (isLoadingMore) {
      return const Padding(
        key: Key('history_load_more_indicator'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }

    if (errorMessage != null) {
      return Container(
        key: const Key('history_load_more_error_banner'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              errorMessage!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onErrorContainer,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('history_load_more_retry_button'),
              onPressed: onLoadMore,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Thử tải thêm lại'),
            ),
          ],
        ),
      );
    }

    return Center(
      child: OutlinedButton.icon(
        key: const Key('history_load_more_button'),
        onPressed: onLoadMore,
        icon: const Icon(Icons.expand_more_rounded),
        label: const Text('Tải thêm lịch sử'),
      ),
    );
  }
}

class _HistoryLoadingCard extends StatelessWidget {
  const _HistoryLoadingCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('history_loading_indicator'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: 16),
              Text(
                'Đang tải danh sách lịch sử đã lưu từ máy chủ...',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryEmptyCard extends StatelessWidget {
  const _HistoryEmptyCard({
    required this.onTryNow,
  });

  final VoidCallback onTryNow;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('history_empty_state'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.collections_bookmark_outlined,
                size: 52,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Chưa có kết quả nào được lưu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Sau khi tạo ảnh thử trang phục, hãy nhấn "Lưu kết quả" để lưu trữ và xem lại tại đây bất cứ lúc nào.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('history_empty_try_now_button'),
                onPressed: onTryNow,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Thử trang phục ngay'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryLoadErrorCard extends StatelessWidget {
  const _HistoryLoadErrorCard({
    required this.errorMessage,
    required this.errorCode,
    required this.onRetry,
  });

  final String errorMessage;
  final String errorCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('history_error_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.error),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 42,
                color: colorScheme.error,
              ),
              const SizedBox(height: 10),
              Text(
                'Không thể tải danh sách Lịch sử',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                errorMessage,
                key: const Key('history_error_message_text'),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (errorCode.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Mã lỗi: $errorCode',
                  key: const Key('history_error_code_text'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('history_retry_button'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Thử tải lại'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryActionErrorBanner extends StatelessWidget {
  const _HistoryActionErrorBanner({
    required this.bannerKey,
    required this.textKey,
    required this.dismissButtonKey,
    required this.message,
    required this.onDismiss,
  });

  final Key bannerKey;
  final Key textKey;
  final Key dismissButtonKey;
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      key: bannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              key: textKey,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onErrorContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            key: dismissButtonKey,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(
              Icons.close_rounded,
              size: 16,
              color: colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}
