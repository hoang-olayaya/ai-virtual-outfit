import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';

/// Processing Screen (`/processing/:jobId`): Polls Backend job status (`queued` -> `processing` -> `succeeded`/`failed`).
///
/// Shell created in F01; full single-loop polling controller wired in F03.
class ProcessingScreen extends StatelessWidget {
  const ProcessingScreen({
    required this.jobId,
    super.key,
  });

  final String jobId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Đang tạo ảnh thử đồ'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: CircularProgressIndicator(),
              ),
              const SizedBox(height: 24),
              Text(
                'Đang xử lý yêu cầu thử trang phục...',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Job ID: $jobId',
                key: const Key('processing_job_id_text'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                key: const Key('processing_to_result_button'),
                onPressed: () =>
                    context.pushReplacement(AppRoutes.resultPath(jobId)),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('Xem kết quả (Result Shell)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

