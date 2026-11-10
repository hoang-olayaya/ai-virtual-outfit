import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// History Detail Screen (`/history/:jobId`): Displays full details, Before/After comparison,
/// Share, and Delete actions for a saved try-on result.
///
/// Shell created in F01; full detail/delete/share logic wired in F05.
class HistoryDetailScreen extends StatelessWidget {
  const HistoryDetailScreen({
    required this.jobId,
    super.key,
  });

  final String jobId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chi tiết kết quả đã lưu'),
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
                            Icons.collections_outlined,
                            size: 48,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Chi tiết Lịch sử (HistoryDetailScreen)',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Job ID: $jobId',
                            key: const Key('history_detail_job_id_text'),
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
              OutlinedButton.icon(
                key: const Key('history_detail_back_button'),
                onPressed: () => context.pop(),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Quay lại Lịch sử'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

