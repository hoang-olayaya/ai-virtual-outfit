import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 3-step progress indicator: Chọn ảnh → Xem trước → Kết quả AI.
class AppStepHeader extends StatelessWidget {
  const AppStepHeader({required this.currentStep, super.key})
    : assert(currentStep >= 1 && currentStep <= 3);

  final int currentStep;

  static const List<String> _labels = ['Chọn ảnh', 'Xem trước', 'Kết quả AI'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      key: const Key('app_step_header'),
      children: [
        for (var i = 0; i < _labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: i < currentStep
                    ? scheme.primary
                    : scheme.outlineVariant,
              ),
            ),
          _StepDot(
            index: i + 1,
            label: _labels[i],
            isActive: i + 1 == currentStep,
            isDone: i + 1 < currentStep,
          ),
        ],
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.index,
    required this.label,
    required this.isActive,
    required this.isDone,
  });

  final int index;
  final String label;
  final bool isActive;
  final bool isDone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlighted = isActive || isDone;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: AppDurations.normal,
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: highlighted ? scheme.primary : scheme.surfaceContainerHighest,
          ),
          child: isDone
              ? Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary)
              : Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: highlighted
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: highlighted ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

