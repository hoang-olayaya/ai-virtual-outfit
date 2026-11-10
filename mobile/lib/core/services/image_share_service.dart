import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Service abstraction over [SharePlus] for sharing generated try-on result images.
///
/// Scaffolded in F01 and wired into `ResultScreen` / `HistoryDetailScreen` in F04/F05.
class ImageShareService {
  const ImageShareService();

  /// Opens the native OS share sheet for a local image file path.
  Future<ShareResult> shareLocalImageFile(
    String filePath, {
    String? text,
  }) {
    return SharePlus.instance.share(
      ShareParams(
        files: [XFile(filePath)],
        text: text,
      ),
    );
  }
}

/// Riverpod provider for [ImageShareService].
final imageShareServiceProvider = Provider<ImageShareService>((ref) {
  return const ImageShareService();
});

