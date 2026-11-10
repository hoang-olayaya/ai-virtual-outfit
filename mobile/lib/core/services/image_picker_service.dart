import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// Typed failure representing an error while opening the device gallery/camera
/// or reading the selected image file.
class ImagePickerException implements Exception {
  const ImagePickerException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'ImagePickerException($code): $message';
}

/// Service abstraction over [ImagePicker] for selecting person and garment photos.
///
/// Scaffolded in F01 and wired into `TryOnDraftController` in F02.
class ImagePickerService {
  ImagePickerService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  /// Default client-side resize bound matching Backend `UPLOAD_MAX_DIMENSION_PX = 4096`
  /// while preventing excessive memory consumption on mobile devices.
  static const double defaultMaxDimension = 2048;

  /// Default JPEG/WebP quality when picking from device gallery/camera.
  static const int defaultImageQuality = 90;

  /// Picks a single image from the device gallery or camera.
  ///
  /// Converts platform permission/picker errors into user-friendly [ImagePickerException]s.
  /// Returns `null` if the user cancels the picker without choosing an image.
  Future<XFile?> pickImage({
    ImageSource source = ImageSource.gallery,
    double? maxWidth = defaultMaxDimension,
    double? maxHeight = defaultMaxDimension,
    int? imageQuality = defaultImageQuality,
  }) async {
    try {
      return await _picker.pickImage(
        source: source,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        imageQuality: imageQuality,
      );
    } on PlatformException catch (error) {
      final normalizedCode = error.code.toLowerCase();
      if (normalizedCode.contains('access_denied') ||
          normalizedCode.contains('permission')) {
        throw ImagePickerException(
          code: error.code,
          message:
              'Không có quyền truy cập Thư viện ảnh hoặc Máy ảnh. Vui lòng cấp quyền trong Cài đặt thiết bị.',
        );
      }
      if (normalizedCode.contains('already_active')) {
        throw ImagePickerException(
          code: error.code,
          message: 'Trình chọn ảnh đang mở. Vui lòng hoàn tất thao tác hiện tại.',
        );
      }
      throw ImagePickerException(
        code: error.code,
        message:
            error.message ?? 'Không thể mở trình chọn ảnh trên thiết bị này.',
      );
    } catch (error) {
      if (error is ImagePickerException) {
        rethrow;
      }
      throw ImagePickerException(
        code: 'PICKER_ERROR',
        message: 'Đã xảy ra lỗi khi chọn ảnh: $error',
      );
    }
  }
}

/// Riverpod provider for [ImagePickerService].
final imagePickerServiceProvider = Provider<ImagePickerService>((ref) {
  return ImagePickerService();
});


