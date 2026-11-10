import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../application/try_on_draft_controller.dart';
import '../../application/try_on_submission_controller.dart';
import '../widgets/draft_image_slot_card.dart';

/// Preview Screen (`/preview`): Displays selected Person and Garment images side-by-side
/// before submitting a Try-On job.
///
/// Implements FR-03, FR-04, FR-05, FR-06, and FR-16 in Phases F02 & F03:
/// - Side-by-side visual comparison of selected Person and Garment images.
/// - Direct replacement of either image via bottom sheet (Gallery / Camera) without losing
///   the other image.
/// - Strict readiness & double-submit gate: "Thử trang phục ngay" button is only enabled
///   when `draft.isReady && !submission.isSubmitting`.
/// - Submits multipart request via [TryOnSubmissionController] and navigates to
///   `ProcessingScreen` (`/processing/:jobId`) on HTTP 202 Accepted.
class PreviewScreen extends ConsumerWidget {
  const PreviewScreen({super.key});

  static const String sampleDemoJobId = '00000000-0000-0000-0000-000000000001';

  Future<void> _replaceImage(
    BuildContext context,
    TryOnDraftController draftController,
    TryOnSubmissionController submissionController, {
    required TryOnImageSlot slot,
    required String title,
  }) async {
    final source = await showImageSourceSheet(context, title: title);
    if (source == null) {
      return;
    }
    submissionController.clearError();
    if (slot == TryOnImageSlot.person) {
      await draftController.pickPersonImage(source: source);
    } else {
      await draftController.pickGarmentImage(source: source);
    }
  }

  Future<void> _handleSubmitTryOn(
    BuildContext context,
    TryOnSubmissionController submissionController,
  ) async {
    final createdJob = await submissionController.submitDraft();
    if (createdJob != null && context.mounted) {
      await context.push(AppRoutes.processingPath(createdJob.jobId));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(tryOnDraftControllerProvider);
    final draftController = ref.read(tryOnDraftControllerProvider.notifier);
    final submission = ref.watch(tryOnSubmissionControllerProvider);
    final submissionController = ref.read(
      tryOnSubmissionControllerProvider.notifier,
    );
    final colorScheme = Theme.of(context).colorScheme;
    final isBusy = draft.isPicking || submission.isSubmitting;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Xem trước ảnh đã chọn'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Kiểm tra lại ảnh bản thân và trang phục trước khi tạo ảnh thử đồ AI.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (draft.errorMessage != null) ...[
                const SizedBox(height: 12),
                _PreviewBanner(
                  bannerKey: const Key('preview_error_banner'),
                  textKey: const Key('preview_error_text'),
                  dismissButtonKey: const Key('dismiss_preview_error_button'),
                  message: draft.errorMessage!,
                  onDismiss: draftController.clearError,
                ),
              ],
              if (submission.errorMessage != null) ...[
                const SizedBox(height: 12),
                _PreviewBanner(
                  bannerKey: const Key('preview_submission_error_banner'),
                  textKey: const Key('preview_submission_error_text'),
                  dismissButtonKey: const Key(
                    'dismiss_preview_submission_error_button',
                  ),
                  message: submission.errorMessage!,
                  onDismiss: submissionController.clearError,
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: draft.selectedCount == 0
                    ? _EmptyPreviewCard(
                        onBackToUpload: () => context.go(AppRoutes.upload),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _PreviewComparisonPanel(
                              panelKey: const Key('preview_person_panel'),
                              imageKey: const Key('preview_person_image'),
                              replaceButtonKey: const Key(
                                'preview_replace_person_button',
                              ),
                              pickDirectGalleryButtonKey: const Key(
                                'preview_pick_person_gallery_button',
                              ),
                              label: 'Ảnh của bạn',
                              emptyHint: 'Chưa chọn ảnh người',
                              icon: Icons.person_outline_rounded,
                              image: draft.personImage,
                              isInteractionDisabled: isBusy,
                              onReplaceTap: () => _replaceImage(
                                context,
                                draftController,
                                submissionController,
                                slot: TryOnImageSlot.person,
                                title: 'Đổi ảnh của bạn',
                              ),
                              onDirectGalleryTap: () {
                                submissionController.clearError();
                                draftController.pickPersonImage();
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _PreviewComparisonPanel(
                              panelKey: const Key('preview_garment_panel'),
                              imageKey: const Key('preview_garment_image'),
                              replaceButtonKey: const Key(
                                'preview_replace_garment_button',
                              ),
                              pickDirectGalleryButtonKey: const Key(
                                'preview_pick_garment_gallery_button',
                              ),
                              label: 'Ảnh trang phục',
                              emptyHint: 'Chưa chọn trang phục',
                              icon: Icons.checkroom_rounded,
                              image: draft.garmentImage,
                              isInteractionDisabled: isBusy,
                              onReplaceTap: () => _replaceImage(
                                context,
                                draftController,
                                submissionController,
                                slot: TryOnImageSlot.garment,
                                title: 'Đổi ảnh trang phục',
                              ),
                              onDirectGalleryTap: () {
                                submissionController.clearError();
                                draftController.pickGarmentImage();
                              },
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('preview_start_processing_button'),
                onPressed: (draft.isReady && !submission.isSubmitting)
                    ? () => _handleSubmitTryOn(context, submissionController)
                    : null,
                icon: submission.isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  submission.isSubmitting
                      ? 'Đang gửi yêu cầu thử đồ...'
                      : draft.isReady
                      ? 'Thử trang phục ngay'
                      : 'Cần chọn đủ 2 ảnh để thử trang phục (${draft.selectedCount}/2)',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('preview_back_button'),
                onPressed: submission.isSubmitting
                    ? null
                    : () {
                        if (context.canPop()) {
                          context.pop();
                        } else {
                          context.go(AppRoutes.upload);
                        }
                      },
                child: const Text('Quay lại chọn ảnh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner({
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
      padding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              key: textKey,
              style: TextStyle(color: colorScheme.onErrorContainer),
            ),
          ),
          IconButton(
            key: dismissButtonKey,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewComparisonPanel extends StatelessWidget {
  const _PreviewComparisonPanel({
    required this.panelKey,
    required this.imageKey,
    required this.replaceButtonKey,
    required this.pickDirectGalleryButtonKey,
    required this.label,
    required this.emptyHint,
    required this.icon,
    required this.image,
    required this.isInteractionDisabled,
    required this.onReplaceTap,
    required this.onDirectGalleryTap,
  });

  final Key panelKey;
  final Key imageKey;
  final Key replaceButtonKey;
  final Key pickDirectGalleryButtonKey;
  final String label;
  final String emptyHint;
  final IconData icon;
  final SelectedDraftImage? image;
  final bool isInteractionDisabled;
  final VoidCallback onReplaceTap;
  final VoidCallback onDirectGalleryTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage = image != null;

    return Card(
      key: panelKey,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: hasImage ? colorScheme.primary : colorScheme.outlineVariant,
          width: hasImage ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              hasImage
                  ? '${image!.fileName} (${image!.formattedSize})'
                  : emptyHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  color: colorScheme.surfaceContainerHighest,
                  child: hasImage
                      ? Image.memory(
                          image!.bytes,
                          key: imageKey,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) => Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              size: 40,
                              color: colorScheme.error,
                            ),
                          ),
                        )
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icon,
                                size: 42,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                emptyHint,
                                style: Theme.of(context).textTheme.bodySmall,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (hasImage)
              OutlinedButton.icon(
                key: replaceButtonKey,
                onPressed: isInteractionDisabled ? null : onReplaceTap,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('Đổi ảnh'),
              )
            else
              FilledButton.tonalIcon(
                key: pickDirectGalleryButtonKey,
                onPressed: isInteractionDisabled ? null : onDirectGalleryTap,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: const Text('Chọn ảnh'),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPreviewCard extends StatelessWidget {
  const _EmptyPreviewCard({required this.onBackToUpload});

  final VoidCallback onBackToUpload;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('preview_empty_state_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 48,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Chưa có ảnh nào được chọn',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Vui lòng chọn ảnh bản thân và ảnh trang phục ở màn hình trước để xem trước và bắt đầu thử đồ.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const Key('preview_empty_back_button'),
                onPressed: onBackToUpload,
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Về màn hình chọn ảnh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
