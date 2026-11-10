import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../application/try_on_draft_controller.dart';

/// Reusable card widget displaying either an empty image selection slot or the
/// currently selected draft image preview with Replace / Remove controls.
class DraftImageSlotCard extends StatelessWidget {
  const DraftImageSlotCard({
    required this.slotKey,
    required this.pickGalleryButtonKey,
    required this.pickCameraButtonKey,
    required this.removeButtonKey,
    required this.previewImageKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selectedImage,
    required this.isPicking,
    required this.onPickFromGallery,
    required this.onPickFromCamera,
    required this.onRemove,
    super.key,
  });

  final Key slotKey;
  final Key pickGalleryButtonKey;
  final Key pickCameraButtonKey;
  final Key removeButtonKey;
  final Key previewImageKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final SelectedDraftImage? selectedImage;
  final bool isPicking;
  final VoidCallback onPickFromGallery;
  final VoidCallback onPickFromCamera;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage = selectedImage != null;

    return Card(
      key: slotKey,
      elevation: 0,
      color: hasImage
          ? colorScheme.surface
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: hasImage ? colorScheme.primary : colorScheme.outlineVariant,
          width: hasImage ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: hasImage
                      ? colorScheme.primary
                      : colorScheme.primaryContainer,
                  child: Icon(
                    hasImage ? Icons.check_rounded : icon,
                    color: hasImage
                        ? colorScheme.onPrimary
                        : colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (hasImage)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'Đã chọn',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasImage
                            ? '${selectedImage!.fileName} (${selectedImage!.formattedSize})'
                            : subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasImage)
                  IconButton(
                    key: removeButtonKey,
                    tooltip: 'Xóa ảnh đã chọn',
                    onPressed: isPicking ? null : onRemove,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: colorScheme.error,
                    ),
                  ),
              ],
            ),
            if (hasImage) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 200,
                  color: colorScheme.surfaceContainerHighest,
                  child: Image.memory(
                    selectedImage!.bytes,
                    key: previewImageKey,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    errorBuilder: (context, error, stackTrace) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.broken_image_outlined,
                            size: 36,
                            color: colorScheme.error,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Không thể hiển thị bản xem trước ảnh',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: pickGalleryButtonKey,
                  onPressed: isPicking ? null : onPickFromGallery,
                  icon: isPicking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          hasImage
                              ? Icons.swap_horiz_rounded
                              : Icons.photo_library_outlined,
                        ),
                  label: Text(
                    hasImage ? 'Đổi ảnh từ Thư viện' : 'Chọn từ Thư viện',
                  ),
                ),
                OutlinedButton.icon(
                  key: pickCameraButtonKey,
                  onPressed: isPicking ? null : onPickFromCamera,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: Text(hasImage ? 'Chụp lại' : 'Chụp ảnh mới'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal bottom sheet helper to let the user choose between Gallery and Camera.
Future<ImageSource?> showImageSourceSheet(
  BuildContext context, {
  required String title,
}) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  title,
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ListTile(
                key: const Key('sheet_pick_gallery_option'),
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Chọn từ Thư viện ảnh'),
                subtitle: const Text('Sử dụng ảnh JPEG, PNG hoặc WebP có sẵn'),
                onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
              ),
              ListTile(
                key: const Key('sheet_pick_camera_option'),
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Chụp ảnh bằng Camera'),
                subtitle: const Text('Chụp trực tiếp bằng máy ảnh thiết bị'),
                onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
              ),
            ],
          ),
        ),
      );
    },
  );
}

