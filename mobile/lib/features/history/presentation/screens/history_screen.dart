import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';

/// History Screen (`/history`): Displays paginated list of saved virtual try-on results
/// retrieved from the PostgreSQL Backend.
///
/// Shell created in F01; full HistoryController and list rendering wired in F05.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  static const String sampleHistoryJobId =
      '00000000-0000-0000-0000-000000000001';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử đã lưu'),
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
                            Icons.history_rounded,
                            size: 48,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Danh sách Lịch sử (HistoryScreen)',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Các kết quả thử trang phục đã lưu trên máy chủ sẽ hiển thị tại đây.',
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
                key: const Key('history_open_detail_button'),
                onPressed: () => context.push(
                  AppRoutes.historyDetailPath(sampleHistoryJobId),
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Xem chi tiết mục mẫu (Detail Shell)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

