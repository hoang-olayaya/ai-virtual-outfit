import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../application/try_on_result_controller.dart';

/// Reusable widget that renders the generated AI try-on result image and
/// interactive Before/After comparison panels (FR-08, FR-09).
///
/// Used in `ResultScreen` (Phase F04) and reusable in `HistoryDetailScreen` (Phase F05).
class TryOnComparisonView extends StatelessWidget {
  const TryOnComparisonView({
    required this.comparisonMode,
    required this.onModeChanged,
    this.resultImageBytes,
    this.personImageBytes,
    this.garmentImageBytes,
    super.key,
  });

  final ResultComparisonMode comparisonMode;
  final ValueChanged<ResultComparisonMode> onModeChanged;
  final Uint8List? resultImageBytes;
  final Uint8List? personImageBytes;
  final Uint8List? garmentImageBytes;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ComparisonModeSelector(
          currentMode: comparisonMode,
          onModeChanged: onModeChanged,
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _buildModeContent(context),
        ),
      ],
    );
  }

  Widget _buildModeContent(BuildContext context) {
    switch (comparisonMode) {
      case ResultComparisonMode.resultOnly:
        return _SingleResultPanel(
          resultBytes: resultImageBytes,
        );
      case ResultComparisonMode.beforeAfter:
        return Row(
          key: const Key('comparison_before_after_view'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _ImageComparisonCard(
                cardKey: const Key('result_before_person_card'),
                imageKey: const Key('result_before_person_image'),
                badgeLabel: 'TRƯỚC (Ảnh gốc)',
                icon: Icons.person_outline_rounded,
                bytes: personImageBytes,
                emptyMessage: 'Chưa có ảnh gốc để đối chiếu',
                isHighlighted: false,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ImageComparisonCard(
                cardKey: const Key('result_after_card'),
                imageKey: const Key('result_after_image'),
                badgeLabel: 'SAU (Kết quả AI)',
                icon: Icons.auto_awesome_rounded,
                bytes: resultImageBytes,
                emptyMessage: 'Chưa có ảnh kết quả',
                isHighlighted: true,
              ),
            ),
          ],
        );
      case ResultComparisonMode.allThree:
        return Row(
          key: const Key('comparison_all_three_view'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _ImageComparisonCard(
                      cardKey: const Key('result_before_person_card'),
                      imageKey: const Key('result_before_person_image'),
                      badgeLabel: '1. Ảnh của bạn',
                      icon: Icons.person_outline_rounded,
                      bytes: personImageBytes,
                      emptyMessage: 'Không có ảnh người',
                      isHighlighted: false,
                      compact: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _ImageComparisonCard(
                      cardKey: const Key('result_input_garment_card'),
                      imageKey: const Key('result_input_garment_image'),
                      badgeLabel: '2. Trang phục',
                      icon: Icons.checkroom_rounded,
                      bytes: garmentImageBytes,
                      emptyMessage: 'Không có ảnh đồ',
                      isHighlighted: false,
                      compact: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 6,
              child: _ImageComparisonCard(
                cardKey: const Key('result_after_card'),
                imageKey: const Key('result_after_image'),
                badgeLabel: '3. Kết quả Thử đồ AI',
                icon: Icons.auto_awesome_rounded,
                bytes: resultImageBytes,
                emptyMessage: 'Chưa có ảnh kết quả',
                isHighlighted: true,
              ),
            ),
          ],
        );
    }
  }
}

class _ComparisonModeSelector extends StatelessWidget {
  const _ComparisonModeSelector({
    required this.currentMode,
    required this.onModeChanged,
  });

  final ResultComparisonMode currentMode;
  final ValueChanged<ResultComparisonMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      key: const Key('comparison_mode_selector'),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeTabButton(
              buttonKey: const Key('compare_mode_result_only_button'),
              icon: Icons.photo_outlined,
              label: 'Kết quả AI',
              isSelected: currentMode == ResultComparisonMode.resultOnly,
              onTap: () => onModeChanged(ResultComparisonMode.resultOnly),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _ModeTabButton(
              buttonKey: const Key('compare_mode_before_after_button'),
              icon: Icons.compare_rounded,
              label: 'Trước / Sau',
              isSelected: currentMode == ResultComparisonMode.beforeAfter,
              onTap: () => onModeChanged(ResultComparisonMode.beforeAfter),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _ModeTabButton(
              buttonKey: const Key('compare_mode_all_three_button'),
              icon: Icons.dashboard_customize_outlined,
              label: 'Đầy đủ (3 ảnh)',
              isSelected: currentMode == ResultComparisonMode.allThree,
              onTap: () => onModeChanged(ResultComparisonMode.allThree),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeTabButton extends StatelessWidget {
  const _ModeTabButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: isSelected ? colorScheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: buttonKey,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SingleResultPanel extends StatelessWidget {
  const _SingleResultPanel({
    required this.resultBytes,
  });

  final Uint8List? resultBytes;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('comparison_result_only_view'),
      child: _ImageComparisonCard(
        cardKey: const Key('result_after_card'),
        imageKey: const Key('result_after_image'),
        badgeLabel: 'Ảnh kết quả thử trang phục (Zoom / Pan)',
        icon: Icons.auto_awesome_rounded,
        bytes: resultBytes,
        emptyMessage: 'Chưa có ảnh kết quả',
        isHighlighted: true,
        enableInteractiveZoom: true,
      ),
    );
  }
}

class _ImageComparisonCard extends StatelessWidget {
  const _ImageComparisonCard({
    required this.cardKey,
    required this.imageKey,
    required this.badgeLabel,
    required this.icon,
    required this.bytes,
    required this.emptyMessage,
    required this.isHighlighted,
    this.compact = false,
    this.enableInteractiveZoom = false,
  });

  final Key cardKey;
  final Key imageKey;
  final String badgeLabel;
  final IconData icon;
  final Uint8List? bytes;
  final String emptyMessage;
  final bool isHighlighted;
  final bool compact;
  final bool enableInteractiveZoom;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage = bytes != null && bytes!.isNotEmpty;

    return Card(
      key: cardKey,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isHighlighted
              ? colorScheme.primary
              : colorScheme.outlineVariant,
          width: isHighlighted ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 8 : 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: compact ? 15 : 17,
                  color: isHighlighted
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    badgeLabel,
                    style:
                        (compact
                                ? Theme.of(context).textTheme.labelMedium
                                : Theme.of(context).textTheme.labelLarge)
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: isHighlighted
                                  ? colorScheme.primary
                                  : colorScheme.onSurface,
                            ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  color: colorScheme.surfaceContainerHighest,
                  child: hasImage
                      ? (enableInteractiveZoom
                            ? InteractiveViewer(
                                minScale: 1.0,
                                maxScale: 4.0,
                                child: _buildMemoryImage(colorScheme),
                              )
                            : _buildMemoryImage(colorScheme))
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  icon,
                                  size: compact ? 24 : 36,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  emptyMessage,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoryImage(ColorScheme colorScheme) {
    return Image.memory(
      bytes!,
      key: imageKey,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (context, error, stackTrace) => Center(
        child: Icon(
          Icons.broken_image_outlined,
          size: 36,
          color: colorScheme.error,
        ),
      ),
    );
  }
}
