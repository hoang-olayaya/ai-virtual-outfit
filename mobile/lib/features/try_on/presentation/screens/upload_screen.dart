import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/network/api_error.dart';
import '../../../../core/router/app_router.dart';
import '../../data/models/health_status_model.dart';
import '../../data/try_on_repository.dart';

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
class UploadScreen extends ConsumerWidget {
  const UploadScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivityAsync = ref.watch(backendConnectivityProvider);
    final config = ref.watch(appConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Virtual Outfit Preview'),
        actions: [
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
              Text(
                'Chọn ảnh đầu vào',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Cung cấp một ảnh chân dung/toàn thân của bạn và một ảnh trang phục muốn thử.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              const _ImageSlotPlaceholderCard(
                slotKey: Key('person_image_slot'),
                icon: Icons.person_outline_rounded,
                title: '1. Ảnh của bạn (Person Image)',
                subtitle: 'Sẽ kích hoạt chọn ảnh từ thư viện ở Phase F02',
              ),
              const SizedBox(height: 12),
              const _ImageSlotPlaceholderCard(
                slotKey: Key('garment_image_slot'),
                icon: Icons.checkroom_rounded,
                title: '2. Ảnh trang phục (Garment Image)',
                subtitle: 'Sẽ kích hoạt chọn ảnh trang phục ở Phase F02',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const Key('nav_preview_button'),
                onPressed: () => context.push(AppRoutes.preview),
                icon: const Icon(Icons.visibility_rounded),
                label: const Text('Xem trước & Xác nhận (Preview Shell)'),
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

class _ImageSlotPlaceholderCard extends StatelessWidget {
  const _ImageSlotPlaceholderCard({
    required this.slotKey,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final Key slotKey;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: slotKey,
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(icon, color: colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

