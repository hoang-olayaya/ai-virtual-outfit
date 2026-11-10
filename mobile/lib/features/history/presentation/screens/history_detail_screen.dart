import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../try_on/presentation/widgets/try_on_comparison_view.dart';
import '../../application/history_controller.dart';

/// History Detail Screen (`/history/:jobId`): Displays full details, interactive Before/After
/// and 3-Panel comparison, Share via native share sheet, and Delete actions for a saved result.
///
/// Implements FR-09, FR-13, FR-14, FR-15, FR-16, NFR-02, NFR-03, and Scenario T11 in Phase F05:
/// - Fetches saved item metadata (`GET /api/v1/history/{jobId}`), result image bytes
///   (`GET /api/v1/try-ons/{jobId}/image`), and input comparison images
///   (`GET /api/v1/try-ons/{jobId}/inputs/person` & `garment`) from the Backend.
/// - Reuses [TryOnComparisonView] so users can compare Before/After even after an app restart.
/// - Keeps Share (`share_plus`) and Delete (`DELETE /api/v1/history/{jobId}`) strictly isolated.
class HistoryDetailScreen extends ConsumerWidget {
  const HistoryDetailScreen({
    required this.jobId,
    super.key,
  });

  final String jobId;

  void _navigateBackToHistory(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.history);
    }
  }

  Future<void> _handleShare(
    BuildContext context,
    HistoryDetailController controller,
  ) async {
    await controller.shareResult();
  }

  Future<void> _handleConfirmAndDelete(
    BuildContext context,
    HistoryDetailController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('history_delete_confirm_dialog'),
        title: const Text('Xóa kết quả khỏi Lịch sử?'),
        content: Text(
          'Bạn có chắc chắn muốn xóa kết quả này (Job ID: $jobId) khỏi danh sách Lịch sử đã lưu?',
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

    final deleted = await controller.deleteFromHistory();
    if (!context.mounted) {
      return;
    }

    if (deleted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            key: Key('history_detail_delete_success_snackbar'),
            content: Text('Đã xóa kết quả khỏi Lịch sử.'),
            duration: Duration(seconds: 2),
          ),
        );
      _navigateBackToHistory(context);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailState = ref.watch(historyDetailControllerProvider(jobId));
    final controller = ref.read(
      historyDetailControllerProvider(jobId).notifier,
    );
    final canActOnDetail =
        !detailState.isLoadingDetail &&
        detailState.loadError == null &&
        detailState.hasResultImage &&
        !detailState.isDeleted;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chi tiết kết quả đã lưu'),
        actions: [
          IconButton(
            key: const Key('history_detail_refresh_button'),
            tooltip: 'Tải lại chi tiết',
            onPressed: detailState.isLoadingDetail
                ? null
                : controller.loadDetail,
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
              _HistoryDetailMetadataHeader(
                jobId: jobId,
                savedAt:
                    detailState.item?.savedAt ??
                    detailState.item?.completedAt ??
                    detailState.item?.createdAt,
                isSaved: detailState.item?.isSaved ?? false,
              ),
              if (detailState.effectiveDeleteErrorMessage != null) ...[
                const SizedBox(height: 8),
                _HistoryDetailActionErrorBanner(
                  bannerKey: const Key('history_detail_delete_error_banner'),
                  textKey: const Key('history_detail_delete_error_text'),
                  dismissButtonKey: const Key(
                    'dismiss_history_detail_delete_error_button',
                  ),
                  message: detailState.effectiveDeleteErrorMessage!,
                  onDismiss: controller.clearDeleteError,
                ),
              ],
              if (detailState.shareErrorMessage != null) ...[
                const SizedBox(height: 8),
                _HistoryDetailActionErrorBanner(
                  bannerKey: const Key('history_detail_share_error_banner'),
                  textKey: const Key('history_detail_share_error_text'),
                  dismissButtonKey: const Key(
                    'dismiss_history_detail_share_error_button',
                  ),
                  message: detailState.shareErrorMessage!,
                  onDismiss: controller.clearShareError,
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: _buildMainBody(
                  context,
                  detailState: detailState,
                  controller: controller,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('history_detail_share_button'),
                      onPressed: (!canActOnDetail || detailState.isSharing)
                          ? null
                          : () => _handleShare(context, controller),
                      icon: detailState.isSharing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.share_outlined, size: 18),
                      label: Text(
                        detailState.isSharing
                            ? 'Đang chia sẻ...'
                            : 'Chia sẻ ảnh',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('history_detail_delete_button'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                        side: BorderSide(
                          color: canActOnDetail
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      onPressed: (!canActOnDetail || detailState.isDeleting)
                          ? null
                          : () => _handleConfirmAndDelete(context, controller),
                      icon: detailState.isDeleting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text(
                        detailState.isDeleting
                            ? 'Đang xóa...'
                            : 'Xóa khỏi lịch sử',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('history_detail_back_button'),
                onPressed: () => _navigateBackToHistory(context),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Quay lại Lịch sử'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainBody(
    BuildContext context, {
    required HistoryDetailState detailState,
    required HistoryDetailController controller,
  }) {
    if (detailState.isLoadingDetail) {
      return const _HistoryDetailLoadingCard();
    }

    if (detailState.loadError != null) {
      final error = detailState.loadError!;
      return _HistoryDetailLoadErrorCard(
        isNotFound: detailState.isNotFoundError,
        errorMessage:
            detailState.effectiveLoadErrorMessage ??
            'Không thể tải chi tiết mục lịch sử này.',
        errorCode: error.rawCode.isNotEmpty
            ? error.rawCode
            : error.errorCode.rawValue,
        onRetryLoad: controller.loadDetail,
      );
    }

    return TryOnComparisonView(
      comparisonMode: detailState.comparisonMode,
      onModeChanged: controller.setComparisonMode,
      resultImageBytes: detailState.resultImageBytes,
      personImageBytes: detailState.personImageBytes,
      garmentImageBytes: detailState.garmentImageBytes,
    );
  }
}

class _HistoryDetailMetadataHeader extends StatelessWidget {
  const _HistoryDetailMetadataHeader({
    required this.jobId,
    required this.savedAt,
    required this.isSaved,
  });

  final String jobId;
  final DateTime? savedAt;
  final bool isSaved;

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.collections_bookmark_rounded,
              size: 18,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Job ID: $jobId',
                key: const Key('history_detail_job_id_text'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isSaved) ...[
              const SizedBox(width: 8),
              Container(
                key: const Key('history_detail_saved_badge'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
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
                      Icons.check_circle_rounded,
                      size: 14,
                      color: Colors.green,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Đã lưu',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (savedAt != null) ...[
          const SizedBox(height: 4),
          Text(
            'Lưu lúc: ${_formatTimestamp(savedAt!)}',
            key: const Key('history_detail_saved_at_text'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _HistoryDetailLoadingCard extends StatelessWidget {
  const _HistoryDetailLoadingCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('history_detail_loading_indicator'),
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
                'Đang tải chi tiết kết quả và ảnh đối chiếu Trước / Sau...',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryDetailLoadErrorCard extends StatelessWidget {
  const _HistoryDetailLoadErrorCard({
    required this.isNotFound,
    required this.errorMessage,
    required this.errorCode,
    required this.onRetryLoad,
  });

  final bool isNotFound;
  final String errorMessage;
  final String errorCode;
  final VoidCallback onRetryLoad;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('history_detail_error_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.error),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isNotFound
                    ? Icons.search_off_rounded
                    : Icons.broken_image_outlined,
                size: 40,
                color: colorScheme.error,
              ),
              const SizedBox(height: 8),
              Text(
                isNotFound
                    ? 'Mục lịch sử không tồn tại hoặc đã bị xóa'
                    : 'Không thể tải chi tiết kết quả đã lưu',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                errorMessage,
                key: const Key('history_detail_error_message_text'),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (errorCode.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Mã lỗi: $errorCode',
                  key: const Key('history_detail_error_code_text'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('history_detail_retry_button'),
                onPressed: onRetryLoad,
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

class _HistoryDetailActionErrorBanner extends StatelessWidget {
  const _HistoryDetailActionErrorBanner({
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
