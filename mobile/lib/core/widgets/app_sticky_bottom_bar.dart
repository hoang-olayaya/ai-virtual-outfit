import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Fixed bottom action area with soft shadow and SafeArea handling.
class AppStickyBottomBar extends StatelessWidget {
  const AppStickyBottomBar({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        boxShadow: AppShadows.bar,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: child,
        ),
      ),
    );
  }
}

