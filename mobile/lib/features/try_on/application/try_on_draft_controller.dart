import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/services/image_picker_service.dart';

/// Identifies which of the two required try-on input slots is being operated on.
enum TryOnImageSlot {
  person,
  garment,
}

/// Immutable value object holding a user-selected input image (`person` or `garment`)
/// along with its decoded in-memory bytes for fast, deterministic UI previewing and
/// multipart submission.
@immutable
class SelectedDraftImage {
  const SelectedDraftImage({
    required this.file,
    required this.bytes,
    required this.fileName,
    required this.sizeBytes,
  });

  final XFile file;
  final Uint8List bytes;
  final String fileName;
  final int sizeBytes;

  String get path => file.path;

  /// Human-readable file size string (e.g., `245.8 KB` or `2.4 MB`).
  String get formattedSize {
    if (sizeBytes < 1024) {
      return '$sizeBytes B';
    }
    final kb = sizeBytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }
}

/// Immutable state managed by [TryOnDraftController] for the Upload & Preview screens.
///
/// Satisfies:
/// - **FR-01:** Select person image
/// - **FR-02:** Select garment image
/// - **FR-03:** Preview both selected input images
/// - **FR-04:** Replace/remove either image before submitting
/// - **FR-05:** Gate Try-On initiation behind [isReady] (`personImage != null && garmentImage != null`)
@immutable
class TryOnDraftState {
  const TryOnDraftState({
    this.personImage,
    this.garmentImage,
    this.activePickingSlot,
    this.errorMessage,
  });

  final SelectedDraftImage? personImage;
  final SelectedDraftImage? garmentImage;
  final TryOnImageSlot? activePickingSlot;
  final String? errorMessage;

  /// Whether the user has selected a valid person image (FR-01).
  bool get hasPersonImage => personImage != null;

  /// Whether the user has selected a valid garment image (FR-02).
  bool get hasGarmentImage => garmentImage != null;

  /// Whether both required input images are present and no picker operation is in flight (FR-05).
  bool get isReady =>
      personImage != null && garmentImage != null && activePickingSlot == null;

  /// Whether the image picker is currently open for either slot.
  bool get isPicking => activePickingSlot != null;

  /// Number of selected images (`0`, `1`, or `2`).
  int get selectedCount =>
      (personImage != null ? 1 : 0) + (garmentImage != null ? 1 : 0);

  TryOnDraftState copyWith({
    SelectedDraftImage? personImage,
    bool clearPersonImage = false,
    SelectedDraftImage? garmentImage,
    bool clearGarmentImage = false,
    TryOnImageSlot? activePickingSlot,
    bool clearActivePickingSlot = false,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return TryOnDraftState(
      personImage:
          clearPersonImage ? null : (personImage ?? this.personImage),
      garmentImage:
          clearGarmentImage ? null : (garmentImage ?? this.garmentImage),
      activePickingSlot: clearActivePickingSlot
          ? null
          : (activePickingSlot ?? this.activePickingSlot),
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Riverpod [Notifier] that manages the user's selected Person and Garment draft images.
///
/// Key guarantees:
/// - **No auto-upload on selection:** Selecting an image only updates local draft state.
/// - **Cancel safety:** Closing the native gallery/camera without choosing a file preserves
///   any previously selected image in that slot.
/// - **Client-side size & emptiness guard:** Rejects empty (`0 B`) or oversized (`> 10 MB`)
///   files immediately with a clear Vietnamese message before reaching the Backend.
class TryOnDraftController extends Notifier<TryOnDraftState> {
  /// Maximum allowed file size per image matching Backend `UPLOAD_MAX_FILE_SIZE_BYTES` (10 MB).
  static const int maxFileSizeBytes = 10 * 1024 * 1024;

  @override
  TryOnDraftState build() {
    return const TryOnDraftState();
  }

  /// Opens the device gallery/camera to pick or replace the Person image (FR-01, FR-04).
  ///
  /// Returns `true` if a new valid image was selected, or `false` if cancelled/rejected.
  Future<bool> pickPersonImage({
    ImageSource source = ImageSource.gallery,
  }) {
    return _pickForSlot(TryOnImageSlot.person, source: source);
  }

  /// Opens the device gallery/camera to pick or replace the Garment image (FR-02, FR-04).
  ///
  /// Returns `true` if a new valid image was selected, or `false` if cancelled/rejected.
  Future<bool> pickGarmentImage({
    ImageSource source = ImageSource.gallery,
  }) {
    return _pickForSlot(TryOnImageSlot.garment, source: source);
  }

  /// Directly sets a [SelectedDraftImage] for testing or pre-populated retry flows.
  void setDraftImage(TryOnImageSlot slot, SelectedDraftImage image) {
    if (slot == TryOnImageSlot.person) {
      state = state.copyWith(
        personImage: image,
        clearErrorMessage: true,
      );
    } else {
      state = state.copyWith(
        garmentImage: image,
        clearErrorMessage: true,
      );
    }
  }

  /// Removes the currently selected Person image (FR-04).
  void removePersonImage() {
    state = state.copyWith(
      clearPersonImage: true,
      clearErrorMessage: true,
    );
  }

  /// Removes the currently selected Garment image (FR-04).
  void removeGarmentImage() {
    state = state.copyWith(
      clearGarmentImage: true,
      clearErrorMessage: true,
    );
  }

  /// Clears any active validation or permission error banner.
  void clearError() {
    if (state.errorMessage != null) {
      state = state.copyWith(clearErrorMessage: true);
    }
  }

  /// Resets the entire draft (both images and any error message).
  void clearDraft() {
    state = const TryOnDraftState();
  }

  Future<bool> _pickForSlot(
    TryOnImageSlot slot, {
    required ImageSource source,
  }) async {
    if (state.isPicking) {
      return false;
    }

    state = state.copyWith(
      activePickingSlot: slot,
      clearErrorMessage: true,
    );

    final pickerService = ref.read(imagePickerServiceProvider);

    try {
      final pickedFile = await pickerService.pickImage(source: source);

      // User dismissed the picker without selecting an image:
      // preserve existing image in the slot without showing an error.
      if (pickedFile == null) {
        state = state.copyWith(clearActivePickingSlot: true);
        return false;
      }

      final bytes = await pickedFile.readAsBytes();
      if (bytes.isEmpty) {
        state = state.copyWith(
          clearActivePickingSlot: true,
          errorMessage:
              'Tệp ảnh được chọn bị rỗng hoặc không thể đọc dữ liệu. Vui lòng chọn ảnh khác.',
        );
        return false;
      }

      if (bytes.length > maxFileSizeBytes) {
        final sizeMb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
        state = state.copyWith(
          clearActivePickingSlot: true,
          errorMessage:
              'Ảnh đã chọn ($sizeMb MB) vượt quá giới hạn tối đa 10 MB. Vui lòng chọn ảnh nhỏ hơn.',
        );
        return false;
      }

      final resolvedName = _resolveFileName(
        pickedFile,
        fallback: slot == TryOnImageSlot.person ? 'person.jpg' : 'garment.png',
      );

      final selected = SelectedDraftImage(
        file: pickedFile,
        bytes: bytes,
        fileName: resolvedName,
        sizeBytes: bytes.length,
      );

      if (slot == TryOnImageSlot.person) {
        state = state.copyWith(
          personImage: selected,
          clearActivePickingSlot: true,
          clearErrorMessage: true,
        );
      } else {
        state = state.copyWith(
          garmentImage: selected,
          clearActivePickingSlot: true,
          clearErrorMessage: true,
        );
      }
      return true;
    } on ImagePickerException catch (error) {
      state = state.copyWith(
        clearActivePickingSlot: true,
        errorMessage: error.message,
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        clearActivePickingSlot: true,
        errorMessage:
            'Không thể đọc tệp ảnh đã chọn. Vui lòng kiểm tra quyền truy cập và thử lại.',
      );
      return false;
    }
  }

  static String _resolveFileName(XFile file, {required String fallback}) {
    final candidate = file.name.trim().isNotEmpty ? file.name.trim() : file.path.trim();
    if (candidate.isEmpty) {
      return fallback;
    }
    final normalizedPath = candidate.replaceAll('\\', '/');
    final segments = normalizedPath.split('/');
    final last = segments.isNotEmpty ? segments.last.trim() : '';
    return last.isNotEmpty ? last : fallback;
  }
}

/// Riverpod provider for [TryOnDraftController].
///
/// Kept alive across navigation between `UploadScreen` (`/`) and `PreviewScreen` (`/preview`)
/// so the user can freely inspect, compare, and replace images without losing state.
final tryOnDraftControllerProvider =
    NotifierProvider<TryOnDraftController, TryOnDraftState>(
      TryOnDraftController.new,
    );

