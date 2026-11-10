import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../application/job_status_controller.dart';
import '../../data/models/job_model.dart';

/// Processing Screen (`/processing/:jobId`): Polls Backend job status
/// (`queued` -> `processing` -> `succeeded` / `failed`).
///
/// Implements FR-07, FR-08, FR-10, FR-16, NFR-02, NFR-05, and Scenario T09 in Phase F03:
/// - Runs a single-flight status polling loop via [JobStatusController].
/// - Pauses polling when app enters background and resumes immediately on foreground.
/// - Preserves `jobId` and shows a non-blocking warning banner when transient network
///   failures occur (`network failure != job failed`).
/// - Navigates automatically to `ResultScreen` (`/result/:jobId`) when `status == succeeded`.
/// - Displays a structured error card with retry/recovery actions when `status == failed`
///   or a terminal error occurs.
class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({
    required this.jobId,
    super.key,
  });

  final String jobId;

  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen>
    with WidgetsBindingObserver {
  bool _hasNavigatedToResult = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(
      jobStatusControllerProvider(widget.jobId).notifier,
    );
    switch (state) {
      case AppLifecycleState.resumed:
        controller.resumePolling();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        controller.pausePolling();
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _navigateToResultOnce() {
    if (_hasNavigatedToResult || !mounted) {
      return;
    }
    _hasNavigatedToResult = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.pushReplacement(AppRoutes.resultPath(widget.jobId));
    });
  }

  void _returnToPreviewOrUpload() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.preview);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<JobStatusState>(
      jobStatusControllerProvider(widget.jobId),
      (previous, next) {
        if (next.isSucceeded && (previous == null || !previous.isSucceeded)) {
          _navigateToResultOnce();
        }
      },
    );

    final statusState = ref.watch(jobStatusControllerProvider(widget.jobId));
    final controller = ref.read(
      jobStatusControllerProvider(widget.jobId).notifier,
    );

    if (statusState.isSucceeded && !_hasNavigatedToResult) {
      _navigateToResultOnce();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Đang tạo ảnh thử đồ'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: statusState.isFailed
              ? _ProcessingFailureView(
                  jobId: widget.jobId,
                  statusState: statusState,
                  onRetryPoll: controller.refreshNow,
                  onBackToPreview: _returnToPreviewOrUpload,
                )
              : _ProcessingActiveView(
                  jobId: widget.jobId,
                  statusState: statusState,
                  onRetryPoll: controller.refreshNow,
                  onOpenResult: () => context.pushReplacement(
                    AppRoutes.resultPath(widget.jobId),
                  ),
                ),
        ),
      ),
    );
  }
}

class _ProcessingActiveView extends StatelessWidget {
  const _ProcessingActiveView({
    required this.jobId,
    required this.statusState,
    required this.onRetryPoll,
    required this.onOpenResult,
  });

  final String jobId;
  final JobStatusState statusState;
  final VoidCallback onRetryPoll;
  final VoidCallback onOpenResult;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = statusState.effectiveStatus;

    final String statusBadgeLabel;
    final String headline;
    final String subtitle;

    switch (status) {
      case JobStatus.queued:
        statusBadgeLabel = 'Đang xếp hàng chờ xử lý (Queued)';
        headline = 'Yêu cầu thử đồ đã được tiếp nhận...';
        subtitle =
            'Hệ thống đang chuẩn bị tài nguyên AI để xử lý hai bức ảnh của bạn.';
      case JobStatus.processing:
        statusBadgeLabel = 'AI đang ghép trang phục (Processing)';
        headline = 'Đang tạo ảnh thử trang phục...';
        subtitle =
            'Mô hình AI đang mô phỏng trang phục lên hình ảnh của bạn. Quá trình này có thể mất vài giây.';
      case JobStatus.succeeded:
        statusBadgeLabel = 'Hoàn tất tạo ảnh (Succeeded)';
        headline = 'Tạo ảnh thử trang phục thành công!';
        subtitle = 'Đang mở màn hình hiển thị kết quả...';
      case JobStatus.failed:
        statusBadgeLabel = 'Xử lý thất bại';
        headline = 'Không thể hoàn tất tạo ảnh';
        subtitle = '';
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Center(
          child: statusState.isSucceeded
              ? const Icon(
                  Icons.check_circle_rounded,
                  size: 64,
                  color: Colors.green,
                )
              : const SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(strokeWidth: 4),
                ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Container(
            key: const Key('processing_status_badge'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              statusBadgeLabel,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          headline,
          key: const Key('processing_headline_text'),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Job ID: $jobId',
          key: const Key('processing_job_id_text'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _ProcessingStepsCard(status: status),
        if (statusState.hasTransientNetworkIssue) ...[
          const SizedBox(height: 20),
          _TransientNetworkWarningBanner(
            message: statusState.transientError!.userFriendlyMessage,
            consecutiveErrors: statusState.consecutiveTransientErrors,
            isFetching: statusState.isFetching,
            onRetryNow: onRetryPoll,
          ),
        ],
        if (statusState.isSucceeded) ...[
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('processing_to_result_button'),
            onPressed: onOpenResult,
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: const Text('Xem kết quả ngay'),
          ),
        ],
      ],
    );
  }
}

class _ProcessingStepsCard extends StatelessWidget {
  const _ProcessingStepsCard({required this.status});

  final JobStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isProcessingOrDone =
        status == JobStatus.processing || status == JobStatus.succeeded;
    final isDone = status == JobStatus.succeeded;

    return Card(
      key: const Key('processing_steps_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StepRow(
              icon: Icons.check_circle_rounded,
              label: '1. Xác thực & tải 2 ảnh lên máy chủ',
              isActive: status == JobStatus.queued,
              isCompleted: isProcessingOrDone,
            ),
            const SizedBox(height: 12),
            _StepRow(
              icon: isDone
                  ? Icons.check_circle_rounded
                  : Icons.auto_awesome_rounded,
              label: '2. AI tổng hợp hình ảnh thử trang phục',
              isActive: status == JobStatus.processing,
              isCompleted: isDone,
            ),
            const SizedBox(height: 12),
            _StepRow(
              icon: Icons.photo_library_outlined,
              label: '3. Lưu ảnh kết quả & sẵn sàng hiển thị',
              isActive: false,
              isCompleted: isDone,
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.isCompleted,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final bool isCompleted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color color;
    if (isCompleted) {
      color = Colors.green;
    } else if (isActive) {
      color = colorScheme.primary;
    } else {
      color = colorScheme.onSurfaceVariant;
    }

    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: (isActive || isCompleted)
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }
}

class _TransientNetworkWarningBanner extends StatelessWidget {
  const _TransientNetworkWarningBanner({
    required this.message,
    required this.consecutiveErrors,
    required this.isFetching,
    required this.onRetryNow,
  });

  final String message;
  final int consecutiveErrors;
  final bool isFetching;
  final VoidCallback onRetryNow;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      key: const Key('processing_network_warning_banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.tertiary),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.wifi_off_rounded,
                color: colorScheme.onTertiaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Kết nối mạng đang chập chờn ($consecutiveErrors lần): $message\n'
                  'Hệ thống vẫn giữ nguyên Job ID và tự động thử kết nối lại.',
                  key: const Key('processing_network_warning_text'),
                  style: TextStyle(
                    color: colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              key: const Key('processing_retry_poll_button'),
              onPressed: isFetching ? null : onRetryNow,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Thử kết nối lại ngay'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProcessingFailureView extends StatelessWidget {
  const _ProcessingFailureView({
    required this.jobId,
    required this.statusState,
    required this.onRetryPoll,
    required this.onBackToPreview,
  });

  final String jobId;
  final JobStatusState statusState;
  final VoidCallback onRetryPoll;
  final VoidCallback onBackToPreview;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final errorMessage =
        statusState.effectiveErrorMessage ??
        'Quá trình tạo ảnh thử đồ không thành công. Vui lòng thử lại.';
    final errorCode = statusState.effectiveErrorCode;
    final canRetryStatusCheck =
        statusState.fatalError != null && statusState.job?.isFailed != true;

    return Card(
      key: const Key('processing_error_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.error),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Không thể hoàn tất tạo ảnh thử đồ',
              key: const Key('processing_error_title_text'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              errorMessage,
              key: const Key('processing_error_message_text'),
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (errorCode != null && errorCode.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Mã lỗi: $errorCode',
                key: const Key('processing_error_code_text'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Job ID: $jobId',
              key: const Key('processing_job_id_text'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (canRetryStatusCheck) ...[
              OutlinedButton.icon(
                key: const Key('processing_retry_poll_button'),
                onPressed: statusState.isFetching ? null : onRetryPoll,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Kiểm tra lại trạng thái'),
              ),
              const SizedBox(height: 10),
            ],
            FilledButton.icon(
              key: const Key('processing_back_to_preview_button'),
              onPressed: onBackToPreview,
              icon: const Icon(Icons.replay_rounded),
              label: const Text('Thử lại với ảnh đã chọn'),
            ),
          ],
        ),
      ),
    );
  }
}
