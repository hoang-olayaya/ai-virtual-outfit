import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_virtual_outfit/app.dart';
import 'package:ai_virtual_outfit/core/config/app_config.dart';
import 'package:ai_virtual_outfit/core/network/dio_client.dart';
import 'package:ai_virtual_outfit/core/services/image_picker_service.dart';
import 'package:ai_virtual_outfit/features/try_on/application/try_on_draft_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

/// Minimal valid 1x1 transparent PNG bytes.
final Uint8List _kValidPngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

/// Programmable fake [ImagePickerService] that returns queued [XFile]s, `null` (cancel),
/// or throws [ImagePickerException]s.
class _QueueFakeImagePickerService extends ImagePickerService {
  final List<Future<XFile?> Function(ImageSource source)> _queue = [];
  final List<ImageSource> recordedSources = [];

  void enqueueFile(
    String name, {
    Uint8List? bytes,
  }) {
    _queue.add((_) async {
      return XFile.fromData(
        bytes ?? _kValidPngBytes,
        name: name,
        path: '/mock/$name',
        mimeType: 'image/png',
      );
    });
  }

  void enqueueCancel() {
    _queue.add((_) async => null);
  }

  void enqueueError(ImagePickerException error) {
    _queue.add((_) async => throw error);
  }

  @override
  Future<XFile?> pickImage({
    ImageSource source = ImageSource.gallery,
    double? maxWidth = ImagePickerService.defaultMaxDimension,
    double? maxHeight = ImagePickerService.defaultMaxDimension,
    int? imageQuality = ImagePickerService.defaultImageQuality,
  }) {
    recordedSources.add(source);
    if (_queue.isEmpty) {
      return Future.value(null);
    }
    final next = _queue.removeAt(0);
    return next(source);
  }
}

class _HealthyBackendAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/health') {
      return ResponseBody.fromString(
        jsonEncode({'status': 'ok', 'app': 'AI Virtual Outfit Preview'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (options.path == '/api/v1/health/ready') {
      return ResponseBody.fromString(
        jsonEncode({'status': 'ready', 'checks': <String, dynamic>{}}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString('{}', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('TryOnDraftController unit tests (F02)', () {
    test(
      'selects person and garment images, computes isReady, and preserves existing image when gallery is cancelled',
      () async {
        final fakePicker = _QueueFakeImagePickerService();
        final container = ProviderContainer(
          overrides: [
            imagePickerServiceProvider.overrideWithValue(fakePicker),
          ],
        );
        addTearDown(container.dispose);

        // Initial state
        final initial = container.read(tryOnDraftControllerProvider);
        expect(initial.hasPersonImage, isFalse);
        expect(initial.hasGarmentImage, isFalse);
        expect(initial.isReady, isFalse);
        expect(initial.selectedCount, 0);

        final controller = container.read(tryOnDraftControllerProvider.notifier);

        // 1. Pick Person image -> selectedCount = 1, isReady = false
        fakePicker.enqueueFile('person_photo.png');
        final pickedPerson = await controller.pickPersonImage();
        expect(pickedPerson, isTrue);

        final afterPerson = container.read(tryOnDraftControllerProvider);
        expect(afterPerson.hasPersonImage, isTrue);
        expect(afterPerson.personImage!.fileName, 'person_photo.png');
        expect(afterPerson.isReady, isFalse);
        expect(afterPerson.selectedCount, 1);

        // 2. Open Person picker again and cancel -> existing person_photo.png MUST be preserved
        fakePicker.enqueueCancel();
        final cancelled = await controller.pickPersonImage();
        expect(cancelled, isFalse);

        final afterCancel = container.read(tryOnDraftControllerProvider);
        expect(afterCancel.hasPersonImage, isTrue);
        expect(afterCancel.personImage!.fileName, 'person_photo.png');
        expect(afterCancel.errorMessage, isNull);

        // 3. Pick Garment image -> selectedCount = 2, isReady = true
        fakePicker.enqueueFile('jacket_garment.png');
        final pickedGarment = await controller.pickGarmentImage(
          source: ImageSource.camera,
        );
        expect(pickedGarment, isTrue);
        expect(fakePicker.recordedSources.last, ImageSource.camera);

        final afterBoth = container.read(tryOnDraftControllerProvider);
        expect(afterBoth.hasGarmentImage, isTrue);
        expect(afterBoth.garmentImage!.fileName, 'jacket_garment.png');
        expect(afterBoth.isReady, isTrue);
        expect(afterBoth.selectedCount, 2);

        // 4. Replace Person image -> new file replaces old file, isReady remains true
        fakePicker.enqueueFile('person_replaced.png');
        await controller.pickPersonImage();
        final afterReplace = container.read(tryOnDraftControllerProvider);
        expect(afterReplace.personImage!.fileName, 'person_replaced.png');
        expect(afterReplace.garmentImage!.fileName, 'jacket_garment.png');
        expect(afterReplace.isReady, isTrue);

        // 5. Remove Garment image -> isReady becomes false
        controller.removeGarmentImage();
        final afterRemove = container.read(tryOnDraftControllerProvider);
        expect(afterRemove.hasPersonImage, isTrue);
        expect(afterRemove.hasGarmentImage, isFalse);
        expect(afterRemove.isReady, isFalse);
      },
    );

    test(
      'rejects empty (0-byte) and oversized (>10 MB) files and surfaces ImagePickerException messages',
      () async {
        final fakePicker = _QueueFakeImagePickerService();
        final container = ProviderContainer(
          overrides: [
            imagePickerServiceProvider.overrideWithValue(fakePicker),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(tryOnDraftControllerProvider.notifier);

        // 1. Empty 0-byte file
        fakePicker.enqueueFile('empty.png', bytes: Uint8List(0));
        final emptyResult = await controller.pickPersonImage();
        expect(emptyResult, isFalse);
        expect(
          container.read(tryOnDraftControllerProvider).errorMessage,
          contains('bị rỗng'),
        );
        expect(
          container.read(tryOnDraftControllerProvider).hasPersonImage,
          isFalse,
        );

        // 2. Oversized file (> 10 MB)
        fakePicker.enqueueFile(
          'huge.png',
          bytes: Uint8List(TryOnDraftController.maxFileSizeBytes + 1024),
        );
        final hugeResult = await controller.pickGarmentImage();
        expect(hugeResult, isFalse);
        expect(
          container.read(tryOnDraftControllerProvider).errorMessage,
          contains('vượt quá giới hạn tối đa 10 MB'),
        );
        expect(
          container.read(tryOnDraftControllerProvider).hasGarmentImage,
          isFalse,
        );

        // 3. Permission denied error from ImagePickerService
        fakePicker.enqueueError(
          const ImagePickerException(
            code: 'photo_access_denied',
            message: 'Không có quyền truy cập Thư viện ảnh.',
          ),
        );
        final permResult = await controller.pickPersonImage();
        expect(permResult, isFalse);
        expect(
          container.read(tryOnDraftControllerProvider).errorMessage,
          'Không có quyền truy cập Thư viện ảnh.',
        );

        // 4. Clear error
        controller.clearError();
        expect(
          container.read(tryOnDraftControllerProvider).errorMessage,
          isNull,
        );
      },
    );
  });

  group('UploadScreen & PreviewScreen widget tests (F02)', () {
    testWidgets(
      'FR-01..FR-05: Preview & Try-On buttons are disabled until both images are picked, and PreviewScreen allows replacing images',
      (tester) async {
        const config = AppConfig(baseUrl: 'http://10.0.2.2:8000');
        final mockDio = Dio(BaseOptions(baseUrl: config.baseUrl))
          ..httpClientAdapter = _HealthyBackendAdapter();
        final fakePicker = _QueueFakeImagePickerService();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(config),
              dioProvider.overrideWithValue(mockDio),
              imagePickerServiceProvider.overrideWithValue(fakePicker),
            ],
            child: const VirtualOutfitApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Initially 0/2 selected -> Preview button is disabled
        final previewButtonFinder = find.byKey(const Key('nav_preview_button'));
        expect(
          tester.widget<FilledButton>(previewButtonFinder).onPressed,
          isNull,
        );
        expect(find.textContaining('Đã chọn 0/2'), findsOneWidget);

        // Pick Person image (1/2) -> Preview button is still disabled
        fakePicker.enqueueFile('model_person.png');
        await tester.tap(find.byKey(const Key('pick_person_gallery_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('person_image_preview')), findsOneWidget);
        expect(find.textContaining('model_person.png'), findsOneWidget);
        expect(find.textContaining('Đã chọn 1/2'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(previewButtonFinder).onPressed,
          isNull,
        );

        // Pick Garment image (2/2) -> Preview button becomes enabled
        fakePicker.enqueueFile('shirt_garment.png');
        await tester.ensureVisible(
          find.byKey(const Key('pick_garment_gallery_button')),
        );
        await tester.tap(find.byKey(const Key('pick_garment_gallery_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('garment_image_preview')), findsOneWidget);
        expect(find.textContaining('shirt_garment.png'), findsOneWidget);
        expect(find.text('Sẵn sàng thử đồ'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(previewButtonFinder).onPressed,
          isNotNull,
        );

        // Navigate to PreviewScreen
        await tester.ensureVisible(previewButtonFinder);
        await tester.tap(previewButtonFinder);
        await tester.pumpAndSettle();

        // Both images are displayed side-by-side on PreviewScreen
        expect(find.text('Xem trước ảnh đã chọn'), findsOneWidget);
        expect(find.byKey(const Key('preview_person_image')), findsOneWidget);
        expect(find.byKey(const Key('preview_garment_image')), findsOneWidget);
        expect(find.textContaining('model_person.png'), findsOneWidget);
        expect(find.textContaining('shirt_garment.png'), findsOneWidget);

        final startTryOnButton = find.byKey(
          const Key('preview_start_processing_button'),
        );
        expect(
          tester.widget<FilledButton>(startTryOnButton).onPressed,
          isNotNull,
        );

        // Replace Garment image directly from PreviewScreen via bottom sheet
        fakePicker.enqueueFile('dress_garment_v2.png');
        await tester.tap(
          find.byKey(const Key('preview_replace_garment_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('sheet_pick_gallery_option')));
        await tester.pumpAndSettle();

        expect(find.textContaining('dress_garment_v2.png'), findsOneWidget);
        expect(find.textContaining('model_person.png'), findsOneWidget);
      },
    );
  });
}

