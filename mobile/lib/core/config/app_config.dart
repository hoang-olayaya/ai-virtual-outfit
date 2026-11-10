import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Application-wide configuration for Backend API connectivity and timeouts.
///
/// Supports compile-time injection via `--dart-define=API_BASE_URL=http://<ip>:8000`
/// and automatically falls back to `http://10.0.2.2:8000` on Android Emulator
/// or `http://localhost:8000` on iOS Simulator / Host environments.
///
/// Security Rule: Never store AI provider secrets (such as `FAL_KEY`) in mobile config.
@immutable
class AppConfig {
  const AppConfig({
    required this.baseUrl,
    this.apiV1Prefix = '/api/v1',
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.sendTimeout = const Duration(seconds: 30),
    this.pollingInterval = const Duration(seconds: 2),
    this.maxPollingDuration = const Duration(minutes: 5),
  });

  /// Default base URL for Android Emulator (maps to host loopback 127.0.0.1).
  static const String androidEmulatorDefaultBaseUrl = 'http://10.0.2.2:8000';

  /// Default base URL for iOS Simulator, Desktop, and Host test environments.
  static const String hostDefaultBaseUrl = 'http://localhost:8000';

  /// Compile-time environment override via `--dart-define=API_BASE_URL=...`.
  static const String _envBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Normalized base URL without trailing slash (e.g., `http://10.0.2.2:8000`).
  final String baseUrl;

  /// Versioned API prefix (default: `/api/v1`).
  final String apiV1Prefix;

  /// Connection timeout for HTTP requests.
  final Duration connectTimeout;

  /// Response receive timeout for HTTP requests.
  final Duration receiveTimeout;

  /// Request payload send timeout (e.g., multipart image upload).
  final Duration sendTimeout;

  /// Default polling interval for active try-on jobs.
  final Duration pollingInterval;

  /// Maximum duration to keep polling an active job before surfacing a client-side timeout.
  final Duration maxPollingDuration;

  /// Builds [AppConfig] using `--dart-define=API_BASE_URL` when provided,
  /// or selects the platform-appropriate local development default.
  factory AppConfig.fromEnvironment({
    String? overrideBaseUrl,
    TargetPlatform? platformOverride,
    bool? isWebOverride,
  }) {
    final rawDefinedUrl = (overrideBaseUrl ?? _envBaseUrl).trim();
    if (rawDefinedUrl.isNotEmpty) {
      return AppConfig(baseUrl: normalizeBaseUrl(rawDefinedUrl));
    }

    final isWeb = isWebOverride ?? kIsWeb;
    if (isWeb) {
      return const AppConfig(baseUrl: hostDefaultBaseUrl);
    }

    final targetPlatform = platformOverride ?? defaultTargetPlatform;
    if (targetPlatform == TargetPlatform.android) {
      return const AppConfig(baseUrl: androidEmulatorDefaultBaseUrl);
    }

    return const AppConfig(baseUrl: hostDefaultBaseUrl);
  }

  /// Strips trailing slashes so path concatenation is always deterministic.
  static String normalizeBaseUrl(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// Full base URL for versioned API endpoints (e.g., `http://10.0.2.2:8000/api/v1`).
  String get apiV1BaseUrl {
    final normalizedPrefix = apiV1Prefix.startsWith('/')
        ? apiV1Prefix
        : '/$apiV1Prefix';
    return '${normalizeBaseUrl(baseUrl)}$normalizedPrefix';
  }

  /// Resolves a relative API path (such as `/api/v1/try-ons/{id}/image` or `/health`)
  /// into a complete absolute URL against [baseUrl].
  /// If [pathOrUrl] is already an absolute `http://` or `https://` URL, returns it as-is.
  String resolveUrl(String pathOrUrl) {
    final trimmed = pathOrUrl.trim();
    if (trimmed.isEmpty) {
      return normalizeBaseUrl(baseUrl);
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final normalizedBase = normalizeBaseUrl(baseUrl);
    final normalizedPath = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    return '$normalizedBase$normalizedPath';
  }

  AppConfig copyWith({
    String? baseUrl,
    String? apiV1Prefix,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Duration? pollingInterval,
    Duration? maxPollingDuration,
  }) {
    return AppConfig(
      baseUrl: baseUrl != null ? normalizeBaseUrl(baseUrl) : this.baseUrl,
      apiV1Prefix: apiV1Prefix ?? this.apiV1Prefix,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      pollingInterval: pollingInterval ?? this.pollingInterval,
      maxPollingDuration: maxPollingDuration ?? this.maxPollingDuration,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppConfig &&
        other.baseUrl == baseUrl &&
        other.apiV1Prefix == apiV1Prefix &&
        other.connectTimeout == connectTimeout &&
        other.receiveTimeout == receiveTimeout &&
        other.sendTimeout == sendTimeout &&
        other.pollingInterval == pollingInterval &&
        other.maxPollingDuration == maxPollingDuration;
  }

  @override
  int get hashCode => Object.hash(
    baseUrl,
    apiV1Prefix,
    connectTimeout,
    receiveTimeout,
    sendTimeout,
    pollingInterval,
    maxPollingDuration,
  );
}

/// Global Riverpod provider for [AppConfig].
/// Can be overridden in tests or custom environments via `ProviderScope(overrides: [...])`.
final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.fromEnvironment();
});

