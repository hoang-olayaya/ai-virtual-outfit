import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';

/// Result Screen (`/result/:jobId`): Displays generated try-on outfit image,
/// Before/After comparison, Save to History, Share, and Try Again actions.
///
/// Shell created in F01; full media rendering, Save, and Share wired in F04.
class ResultScreen extends StatelessWidget {
  const ResultScreen({
    required this.jobId,
    super.key,
  });

  final String jobId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kết quả thử trang phục'),
        actions: [
          IconButton(
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
                            Icons.photo_library_outlined,
                            size: 48,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Màn hình Kết quả (ResultScreen)',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Job ID: $jobId',
                            key: const Key('result_job_id_text'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('result_try_again_button'),
                onPressed: () => context.go(AppRoutes.upload),
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Thử lại bộ trang phục khác'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

