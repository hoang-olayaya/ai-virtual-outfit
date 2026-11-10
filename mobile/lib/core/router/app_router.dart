import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/history/presentation/screens/history_detail_screen.dart';
import '../../features/history/presentation/screens/history_screen.dart';
import '../../features/try_on/presentation/screens/preview_screen.dart';
import '../../features/try_on/presentation/screens/processing_screen.dart';
import '../../features/try_on/presentation/screens/result_screen.dart';
import '../../features/try_on/presentation/screens/upload_screen.dart';

/// Centralized route paths and helper builders for the application.
abstract final class AppRoutes {
  static const String upload = '/';
  static const String preview = '/preview';
  static const String processing = '/processing/:jobId';
  static const String result = '/result/:jobId';
  static const String history = '/history';
  static const String historyDetail = '/history/:jobId';

  static String processingPath(String jobId) =>
      '/processing/${Uri.encodeComponent(jobId.trim())}';

  static String resultPath(String jobId) =>
      '/result/${Uri.encodeComponent(jobId.trim())}';

  static String historyDetailPath(String jobId) =>
      '/history/${Uri.encodeComponent(jobId.trim())}';
}

/// Builds a configured [GoRouter] instance covering all 6 screens in Architecture Notes V2:
/// - `UploadScreen` (`/`)
/// - `PreviewScreen` (`/preview`)
/// - `ProcessingScreen` (`/processing/:jobId`)
/// - `ResultScreen` (`/result/:jobId`)
/// - `HistoryScreen` (`/history`)
/// - `HistoryDetailScreen` (`/history/:jobId`)
GoRouter createAppRouter({String initialLocation = AppRoutes.upload}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.upload,
        name: 'upload',
        builder: (context, state) => const UploadScreen(),
      ),
      GoRoute(
        path: AppRoutes.preview,
        name: 'preview',
        builder: (context, state) => const PreviewScreen(),
      ),
      GoRoute(
        path: AppRoutes.processing,
        name: 'processing',
        builder: (context, state) {
          final jobId = state.pathParameters['jobId'] ?? '';
          return ProcessingScreen(jobId: jobId);
        },
      ),
      GoRoute(
        path: AppRoutes.result,
        name: 'result',
        builder: (context, state) {
          final jobId = state.pathParameters['jobId'] ?? '';
          return ResultScreen(jobId: jobId);
        },
      ),
      GoRoute(
        path: AppRoutes.history,
        name: 'history',
        builder: (context, state) => const HistoryScreen(),
      ),
      GoRoute(
        path: AppRoutes.historyDetail,
        name: 'history_detail',
        builder: (context, state) {
          final jobId = state.pathParameters['jobId'] ?? '';
          return HistoryDetailScreen(jobId: jobId);
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Không tìm thấy trang')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Đường dẫn không tồn tại: ${state.uri}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go(AppRoutes.upload),
              child: const Text('Về màn hình chính'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Riverpod provider for the application's [GoRouter].
final appRouterProvider = Provider<GoRouter>((ref) {
  return createAppRouter();
});

