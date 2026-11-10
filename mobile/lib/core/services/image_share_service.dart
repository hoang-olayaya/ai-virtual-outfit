import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Typed failure representing an error while writing the temporary image file
/// or invoking the native OS share sheet.
class ImageShareException implements Exception {
  const ImageShareException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'ImageShareException($code): $message';
}

/// Callback signature for resolving the device temporary directory.
typedef TempDirectoryProvider = Future<Directory> Function();

/// Callback signature for invoking the platform share sheet.
typedef ShareLauncher = Future<ShareResult> Function(ShareParams params);

/// Detected image format metadata for safe temporary file creation.
class DetectedImageFormat {
  const DetectedImageFormat({
    required this.extension,
    required this.mimeType,
  });

  final String extension;
  final String mimeType;
}

/// Service abstraction over [SharePlus] and temporary file storage (`path_provider`)
/// for sharing generated virtual try-on result images (FR-15).
///
/// Architecture Rule:
/// - "Save != Share != Retry. Chia sẻ dùng local image file + share_plus."
/// - Writes downloaded result image bytes to an isolated temporary file
///   (`<tempDir>/try_on_share/try_on_<jobId>.<ext>`) with matching MIME type
///   before opening the native OS share sheet.
class ImageShareService {
  ImageShareService({
    TempDirectoryProvider? tempDirectoryProvider,
    ShareLauncher? shareLauncher,
  }) : _tempDirectoryProvider =
           tempDirectoryProvider ?? getTemporaryDirectory,
       _shareLauncher = shareLauncher ?? SharePlus.instance.share;

  final TempDirectoryProvider _tempDirectoryProvider;
  final ShareLauncher _shareLauncher;

  /// Inspects magic header bytes to determine the real image extension and MIME type.
  static DetectedImageFormat detectFormat(Uint8List bytes) {
    // PNG magic header: 89 50 4E 47 0D 0A 1A 0A
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return const DetectedImageFormat(
        extension: 'png',
        mimeType: 'image/png',
      );
    }

    // WebP magic header: "RIFF" .... "WEBP"
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return const DetectedImageFormat(
        extension: 'webp',
        mimeType: 'image/webp',
      );
    }

    // Default to JPEG (FF D8 FF)
    return const DetectedImageFormat(
      extension: 'jpg',
      mimeType: 'image/jpeg',
    );
  }

  /// Writes [bytes] into a sanitized temporary file inside `<tempDir>/try_on_share/`
  /// so the OS share sheet can read it as a local file.
  Future<File> writeTempResultImage(
    Uint8List bytes, {
    required String jobId,
  }) async {
    if (bytes.isEmpty) {
      throw const ImageShareException(
        code: 'EMPTY_IMAGE_BYTES',
        message: 'Không có dữ liệu ảnh kết quả để chia sẻ.',
      );
    }

    final sanitizedJobId = _sanitizeFileNameSegment(jobId);
    final format = detectFormat(bytes);

    try {
      final baseTempDir = await _tempDirectoryProvider();
      final shareDir = Directory(
        '${baseTempDir.path}${Platform.pathSeparator}try_on_share',
      );
      if (!shareDir.existsSync()) {
        shareDir.createSync(recursive: true);
      }

      final filePath =
          '${shareDir.path}${Platform.pathSeparator}try_on_$sanitizedJobId.${format.extension}';
      final file = File(filePath);
      file.writeAsBytesSync(bytes, flush: true);
      return file;
    } catch (error) {
      if (error is ImageShareException) {
        rethrow;
      }
      throw ImageShareException(
        code: 'TEMP_FILE_WRITE_ERROR',
        message:
            'Không thể lưu tệp ảnh tạm thời trên thiết bị để chia sẻ. Vui lòng thử lại.',
      );
    }
  }

  /// Writes [bytes] to a temporary local file and opens the native OS share sheet (FR-15).
  Future<ShareResult> shareResultImageBytes(
    Uint8List bytes, {
    required String jobId,
    String? text,
  }) async {
    final format = detectFormat(bytes);
    final tempFile = await writeTempResultImage(bytes, jobId: jobId);
    return shareLocalImageFile(
      tempFile.path,
      mimeType: format.mimeType,
      text: text,
    );
  }

  /// Opens the native OS share sheet for an existing local image file path.
  Future<ShareResult> shareLocalImageFile(
    String filePath, {
    String? mimeType,
    String? text,
  }) async {
    final trimmedPath = filePath.trim();
    if (trimmedPath.isEmpty) {
      throw const ImageShareException(
        code: 'EMPTY_FILE_PATH',
        message: 'Đường dẫn tệp ảnh chia sẻ không hợp lệ.',
      );
    }

    try {
      return await _shareLauncher(
        ShareParams(
          files: <XFile>[
            XFile(trimmedPath, mimeType: mimeType),
          ],
          text: text,
        ),
      );
    } catch (error) {
      if (error is ImageShareException) {
        rethrow;
      }
      throw ImageShareException(
        code: 'SHARE_SHEET_ERROR',
        message:
            'Không thể mở bảng chia sẻ trên thiết bị. Vui lòng thử lại.',
      );
    }
  }

  static String _sanitizeFileNameSegment(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return cleaned.isEmpty ? 'result' : cleaned;
  }
}

/// Riverpod provider for [ImageShareService].
final imageShareServiceProvider = Provider<ImageShareService>((ref) {
  return ImageShareService();
});
