import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/network/api_error.dart';
import '../../../../core/router/app_router.dart';
import '../../application/try_on_draft_controller.dart';
import '../../data/models/health_status_model.dart';
import '../../data/try_on_repository.dart';
import '../widgets/draft_image_slot_card.dart';

/// Combined snapshot of Backend Liveness (`/health`) and Readiness (`/api/v1/health/ready`).
@immutable
class BackendConnectivitySnapshot {
  const BackendConnectivitySnapshot({
    required this.baseUrl,
    required this.liveness,
    this.readiness,
  });

  final String baseUrl;
  final HealthStatusModel liveness;
  final HealthStatusModel? readiness;

  bool get isReady =>
      liveness.isHealthy && (readiness == null || readiness!.isHealthy);
}

/// Riverpod [FutureProvider] that queries Backend health/readiness through [TryOnRepository].
final backendConnectivityProvider =
    FutureProvider.autoDispose<BackendConnectivitySnapshot>((ref) async {
      final repo = ref.watch(tryOnRepositoryProvider);
      final config = ref.watch(appConfigProvider);
      final liveness = await repo.checkHealth();
      HealthStatusModel? readiness;
      try {
        readiness = await repo.checkReadiness();
      } on ApiException {
        // Keep liveness info even if readiness probe is degraded.
        readiness = null;
      }
      return BackendConnectivitySnapshot(
        baseUrl: config.baseUrl,
        liveness: liveness,
        readiness: readiness,
      );
    });

/// Primary entry screen (`/`): Select Person & Garment images, view Backend connectivity,
/// and navigate to Preview or History.
///
/// Implements FR-01, FR-02, FR-03, FR-04, and FR-05 in Phase F02.
class UploadScreen extends ConsumerWidget {
  const UploadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivityAsync = ref.watch(backendConnectivityProvider);
    final config = ref.watch(appConfigProvider);
    final draft = ref.watch(tryOnDraftControllerProvider);
    final draftController = ref.read(tryOnDraftControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Virtual Outfit Preview'),
        actions: [
          if (draft.selectedCount > 0)
            IconButton(
              key: const Key('clear_draft_button'),
              tooltip: 'Xóa toàn bộ ảnh đã chọn',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: draft.isPicking ? null : draftController.clearDraft,
            ),
          IconButton(
            key: const Key('nav_history_button'),
            tooltip: 'Lịch sử thử đồ',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => context.push(AppRoutes.history),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BackendConnectivityCard(
                connectivityAsync: connectivityAsync,
                baseUrl: config.baseUrl,
                onRefresh: () => ref.invalidate(backendConnectivityProvider),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Chọn ảnh đầu vào',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _DraftReadinessBadge(draft: draft),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Cung cấp một ảnh chân dung/toàn thân của bạn và một ảnh trang phục muốn thử.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (draft.errorMessage != null) ...[
                const SizedBox(height: 12),
                _DraftErrorBanner(
                  message: draft.errorMessage!,
                  onDismiss: draftController.clearError,
                ),
              ],
              const SizedBox(height: 16),
              DraftImageSlotCard(
                slotKey: const Key('person_image_slot'),
                pickGalleryButtonKey: const Key('pick_person_gallery_button'),
                pickCameraButtonKey: const Key('pick_person_camera_button'),
                removeButtonKey: const Key('remove_person_image_button'),
                previewImageKey: const Key('person_image_preview'),
                icon: Icons.person_outline_rounded,
                title: '1. Ảnh của bạn (Person Image)',
                subtitle:
                    'Chọn ảnh rõ mặt và dáng người đứng thẳng (JPEG/PNG/WebP ≤ 10 MB)',
                selectedImage: draft.personImage,
                isPicking: draft.activePickingSlot == TryOnImageSlot.person,
                onPickFromGallery: () => draftController.pickPersonImage(
                  source: ImageSource.gallery,
                ),
                onPickFromCamera: () => draftController.pickPersonImage(
                  source: ImageSource.camera,
                ),
                onRemove: draftController.removePersonImage,
              ),
              const SizedBox(height: 12),
              DraftImageSlotCard(
                slotKey: const Key('garment_image_slot'),
                pickGalleryButtonKey: const Key('pick_garment_gallery_button'),
                pickCameraButtonKey: const Key('pick_garment_camera_button'),
                removeButtonKey: const Key('remove_garment_image_button'),
                previewImageKey: const Key('garment_image_preview'),
                icon: Icons.checkroom_rounded,
                title: '2. Ảnh trang phục (Garment Image)',
                subtitle:
                    'Chọn ảnh trang phục phẳng hoặc trên nền đơn giản (JPEG/PNG/WebP ≤ 10 MB)',
                selectedImage: draft.garmentImage,
                isPicking: draft.activePickingSlot == TryOnImageSlot.garment,
                onPickFromGallery: () => draftController.pickGarmentImage(
                  source: ImageSource.gallery,
                ),
                onPickFromCamera: () => draftController.pickGarmentImage(
                  source: ImageSource.camera,
                ),
                onRemove: draftController.removeGarmentImage,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('nav_preview_button'),
                onPressed: draft.isReady
                    ? () => context.push(AppRoutes.preview)
                    : null,
                icon: const Icon(Icons.visibility_rounded),
                label: Text(
                  draft.isReady
                      ? 'Xem trước & Xác nhận (2/2 ảnh sẵn sàng)'
                      : 'Chọn đủ 2 ảnh để tiếp tục (${draft.selectedCount}/2)',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('nav_history_secondary_button'),
                onPressed: () => context.push(AppRoutes.history),
                icon: const Icon(Icons.collections_bookmark_outlined),
                label: const Text('Mở danh sách Lịch sử đã lưu'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DraftReadinessBadge extends StatelessWidget {
  const _DraftReadinessBadge({required this.draft});

  final TryOnDraftState draft;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isReady = draft.isReady;

    return Container(
      key: const Key('draft_readiness_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isReady
            ? Colors.green.withValues(alpha: 0.14)
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isReady ? Colors.green : colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isReady ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            size: 16,
            color: isReady ? Colors.green : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            isReady ? 'Sẵn sàng thử đồ' : 'Đã chọn ${draft.selectedCount}/2',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: isReady ? Colors.green.shade800 : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftErrorBanner extends StatelessWidget {
  const _DraftErrorBanner({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      key: const Key('draft_error_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              key: const Key('draft_error_text'),
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            key: const Key('dismiss_draft_error_button'),
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

class _BackendConnectivityCard extends StatelessWidget {
  const _BackendConnectivityCard({
    required this.connectivityAsync,
    required this.baseUrl,
    required this.onRefresh,
  });

  final AsyncValue<BackendConnectivitySnapshot> connectivityAsync;
  final String baseUrl;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('backend_connectivity_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cloud_done_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Kết nối Máy chủ Backend',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('refresh_health_button'),
                  tooltip: 'Kiểm tra lại kết nối',
                  visualDensity: VisualDensity.compact,
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
              ],
            ),
            Text(
              'Endpoint: $baseUrl',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            connectivityAsync.when(
              loading: () => const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Đang kiểm tra trạng thái Backend (/health)...'),
                ],
              ),
              error: (error, _) {
                final message = error is ApiException
                    ? error.userFriendlyMessage
                    : error.toString();
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: colorScheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Chưa kết nối được Backend: $message',
                        key: const Key('backend_status_error_text'),
                        style: TextStyle(color: colorScheme.error),
                      ),
                    ),
                  ],
                );
              },
              data: (snapshot) {
                final readyLabel = snapshot.readiness != null
                    ? ' • Readiness: ${snapshot.readiness!.status}'
                    : '';
                return Row(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Colors.green,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Trạng thái: ${snapshot.liveness.status.toUpperCase()}$readyLabel',
                        key: const Key('backend_status_ok_text'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.green,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
