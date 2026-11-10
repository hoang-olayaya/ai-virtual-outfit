import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';

/// Preview Screen (`/preview`): Displays selected Person and Garment images side-by-side
/// before submitting a Try-On job.
///
/// Shell created in F01; full draft state and image comparison wired in F02.
class PreviewScreen extends StatelessWidget {
  const PreviewScreen({super.key});

  static const String sampleDemoJobId = '00000000-0000-0000-0000-000000000001';

  @override
  Widget build(BuildContext context) {
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
              Expanded(
                child: Card(
                  elevation: 0,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.compare_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Màn hình Xem trước (PreviewScreen)',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Hiển thị đối chiếu ảnh người dùng và ảnh trang phục trước khi gửi yêu cầu tạo ảnh thử đồ.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('preview_start_processing_button'),
                onPressed: () =>
                    context.push(AppRoutes.processingPath(sampleDemoJobId)),
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('Thử trang phục (Processing Shell)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('preview_back_button'),
                onPressed: () => context.pop(),
                child: const Text('Quay lại chọn ảnh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

