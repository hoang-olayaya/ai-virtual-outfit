import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

enum AppBannerType { error, warning, info }

/// Standardized dismissible banner. Callers pass their own keys so existing
/// test contracts remain intact.
class AppStatusBanner extends StatelessWidget {
  const AppStatusBanner({
    required this.message,
    required this.onDismiss,
    this.type = AppBannerType.error,
    this.textKey,
    this.dismissButtonKey,
    super.key,
  });

  final String message;
  final VoidCallback onDismiss;
  final AppBannerType type;
  final Key? textKey;
  final Key? dismissButtonKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    final IconData icon;
    switch (type) {
      case AppBannerType.error:
        bg = scheme.errorContainer;
        fg = scheme.onErrorContainer;
        icon = Icons.warning_amber_rounded;
      case AppBannerType.warning:
        bg = scheme.tertiaryContainer;
        fg = scheme.onTertiaryContainer;
        icon = Icons.wifi_off_rounded;
      case AppBannerType.info:
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
        icon = Icons.info_outline_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              key: textKey,
              style: TextStyle(color: fg, fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            key: dismissButtonKey,
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: Icon(Icons.close_rounded, size: 18, color: fg),
          ),
        ],
      ),
    );
  }
}

