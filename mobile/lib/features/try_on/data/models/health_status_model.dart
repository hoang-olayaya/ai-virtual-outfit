import 'package:flutter/foundation.dart';

/// DTO representing Backend Liveness (`GET /health`) and Readiness (`GET /api/v1/health/ready`) probes.
@immutable
class HealthStatusModel {
  const HealthStatusModel({
    required this.status,
    this.app,
    this.version,
    this.environment,
    this.checks = const <String, String>{},
  });

  final String status;
  final String? app;
  final String? version;
  final String? environment;
  final Map<String, String> checks;

  /// True when liveness returns `"ok"` or readiness returns `"ready"`.
  bool get isHealthy =>
      status.toLowerCase() == 'ok' || status.toLowerCase() == 'ready';

  factory HealthStatusModel.fromJson(Map<String, dynamic> json) {
    final rawChecks = json['checks'];
    final parsedChecks = <String, String>{};
    if (rawChecks is Map) {
      rawChecks.forEach((key, value) {
        parsedChecks[key.toString()] = value?.toString() ?? '';
      });
    }

    return HealthStatusModel(
      status: json['status']?.toString() ?? 'unknown',
      app: json['app']?.toString(),
      version: json['version']?.toString(),
      environment: json['environment']?.toString(),
      checks: Map<String, String>.unmodifiable(parsedChecks),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'status': status,
      if (app != null) 'app': app,
      if (version != null) 'version': version,
      if (environment != null) 'environment': environment,
      if (checks.isNotEmpty) 'checks': checks,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is HealthStatusModel &&
        other.status == status &&
        other.app == app &&
        other.version == version &&
        other.environment == environment &&
        mapEquals(other.checks, checks);
  }

  @override
  int get hashCode => Object.hash(
    status,
    app,
    version,
    environment,
    Object.hashAll(checks.entries.map((e) => Object.hash(e.key, e.value))),
  );
}

