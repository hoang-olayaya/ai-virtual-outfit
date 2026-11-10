import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../application/try_on_draft_controller.dart';
import '../../application/try_on_result_controller.dart';
import '../widgets/try_on_comparison_view.dart';

/// Result Screen (`/result/:jobId`): Displays the generated virtual try-on outfit image,
/// interactive Before/After comparison, Save to History, Share via native share sheet,
/// and Try Again actions.
///
/// Implements FR-08, FR-09, FR-10, FR-11, FR-15, FR-16, NFR-02, NFR-03, NFR-05,
/// and Scenario T11 in Phase F04:
/// - Loads result and input comparison images through [TryOnResultController] -> `TryOnRepository`
///   (Widgets never make direct HTTP calls).
/// - Supports switching between `Result Only`, `Before / After`, and `3-Panel` comparison modes.
/// - Strictly decouples Save, Share, and Try Again (`Save != Share != Retry`).
class ResultScreen extends ConsumerWidget {
  const ResultScreen({
    required this.jobId,
    super.key,
  });

  final String jobId;

  Future<void> _handleSave(
    BuildContext context,
    TryOnResultController controller,
  ) async {
    await controller.saveToHistory();
  }

  Future<void> _handleShare(
    BuildContext context,
    TryOnResultController controller,
  ) async {
    await controller.shareResult();
  }

  void _handleTryAgainKeepDraft(
    BuildContext context,
    TryOnResultController controller,
  ) {
    controller.prepareTryAgain(clearDraft: false);
    context.go(AppRoutes.upload);
  }

  void _handleTryAgainFromPreview(
    BuildContext context,
    TryOnResultController controller,
  ) {
    controller.prepareTryAgain(clearDraft: false);
    context.go(AppRoutes.preview);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resultState = ref.watch(tryOnResultControllerProvider(jobId));
    final controller = ref.read(tryOnResultControllerProvider(jobId).notifier);
    final draft = ref.watch(tryOnDraftControllerProvider);
    final canActOnResult =
        !resultState.isLoadingResult &&
        resultState.loadError == null &&
        resultState.hasResultImage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kết quả thử trang phục'),
        actions: [
          if (draft.isReady)
            IconButton(
              key: const Key('result_try_again_preview_button'),
              tooltip: 'Đổi ảnh nhanh tại màn Xem trước',
              onPressed: () => _handleTryAgainFromPreview(context, controller),
              icon: const Icon(Icons.swap_horiz_rounded),
            ),
          IconButton(
            key: const Key('result_nav_history_button'),
            tooltip: 'Lịch sử',
            onPressed: () => context.push(AppRoutes.history),
            icon: const Icon(Icons.history_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ResultMetadataHeader(
                jobId: jobId,
                isSaved: resultState.isSaved,
              ),
              if (resultState.effectiveSaveErrorMessage != null) ...[
                const SizedBox(height: 8),
                _ResultActionErrorBanner(
                  bannerKey: const Key('result_save_error_banner'),
                  textKey: const Key('result_save_error_text'),
                  dismissButtonKey: const Key(
                    'dismiss_result_save_error_button',
                  ),
                  message: resultState.effectiveSaveErrorMessage!,
                  onDismiss: controller.clearSaveError,
                ),
              ],
              if (resultState.shareErrorMessage != null) ...[
                const SizedBox(height: 8),
                _ResultActionErrorBanner(
                  bannerKey: const Key('result_share_error_banner'),
                  textKey: const Key('result_share_error_text'),
                  dismissButtonKey: const Key(
                    'dismiss_result_share_error_button',
                  ),
                  message: resultState.shareErrorMessage!,
                  onDismiss: controller.clearShareError,
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: _buildMainBody(
                  context,
                  resultState: resultState,
                  controller: controller,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: resultState.isSaved
                        ? FilledButton.tonalIcon(
                            key: const Key('result_save_button'),
                            onPressed: (!canActOnResult || resultState.isSaving)
                                ? null
                                : () => _handleSave(context, controller),
                            icon: const Icon(
                              Icons.bookmark_added_rounded,
                              size: 18,
                            ),
                            label: const Text('Đã lưu Lịch sử'),
                          )
                        : FilledButton.icon(
                            key: const Key('result_save_button'),
                            onPressed: (!canActOnResult || resultState.isSaving)
                                ? null
                                : () => _handleSave(context, controller),
                            icon: resultState.isSaving
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.bookmark_add_outlined,
                                    size: 18,
                                  ),
                            label: Text(
                              resultState.isSaving
                                  ? 'Đang lưu...'
                                  : 'Lưu kết quả',
                            ),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('result_share_button'),
                      onPressed: (!canActOnResult || resultState.isSharing)
                          ? null
                          : () => _handleShare(context, controller),
                      icon: resultState.isSharing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.share_outlined, size: 18),
                      label: Text(
                        resultState.isSharing
                            ? 'Đang chia sẻ...'
                            : 'Chia sẻ ảnh',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                key: const Key('result_try_again_button'),
                onPressed: () =>
                    _handleTryAgainKeepDraft(context, controller),
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Thử lại bộ trang phục khác'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainBody(
    BuildContext context, {
    required TryOnResultState resultState,
    required TryOnResultController controller,
  }) {
    if (resultState.isLoadingResult) {
      return const _ResultLoadingCard();
    }

    if (resultState.loadError != null) {
      return _ResultLoadErrorCard(
        errorMessage:
            resultState.effectiveLoadErrorMessage ??
            'Không thể tải hình ảnh kết quả. Vui lòng thử lại.',
        errorCode: resultState.loadError!.rawCode.isNotEmpty
            ? resultState.loadError!.rawCode
            : resultState.loadError!.errorCode.rawValue,
        onRetryLoad: controller.loadResult,
      );
    }

    return TryOnComparisonView(
      comparisonMode: resultState.comparisonMode,
      onModeChanged: controller.setComparisonMode,
      resultImageBytes: resultState.resultImageBytes,
      personImageBytes: resultState.personImageBytes,
      garmentImageBytes: resultState.garmentImageBytes,
    );
  }
}

class _ResultMetadataHeader extends StatelessWidget {
  const _ResultMetadataHeader({
    required this.jobId,
    required this.isSaved,
  });

  final String jobId;
  final bool isSaved;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      children: [
        Icon(
          Icons.verified_rounded,
          size: 18,
          color: colorScheme.primary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Job ID: $jobId',
            key: const Key('result_job_id_text'),
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
            key: const Key('result_saved_badge'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  'Đã lưu vào Lịch sử',
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
    );
  }
}

class _ResultLoadingCard extends StatelessWidget {
  const _ResultLoadingCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('result_loading_indicator'),
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
                'Đang tải hình ảnh kết quả thử trang phục...',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultLoadErrorCard extends StatelessWidget {
  const _ResultLoadErrorCard({
    required this.errorMessage,
    required this.errorCode,
    required this.onRetryLoad,
  });

  final String errorMessage;
  final String errorCode;
  final VoidCallback onRetryLoad;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('result_load_error_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.error),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 36,
                color: colorScheme.error,
              ),
              const SizedBox(height: 8),
              Text(
                'Không thể tải ảnh kết quả',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                errorMessage,
                key: const Key('result_load_error_message_text'),
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              if (errorCode.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Mã lỗi: $errorCode',
                  key: const Key('result_load_error_code_text'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('result_retry_load_button'),
                onPressed: onRetryLoad,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Tải lại ảnh kết quả'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultActionErrorBanner extends StatelessWidget {
  const _ResultActionErrorBanner({
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
