import 'package:integration_test/integration_test.dart';

import '../test/release_gate_e2e_test.dart' as release_gate_e2e;

/// Device / Emulator End-to-End Integration Test entrypoint (`mobile/integration_test/app_e2e_test.dart`).
///
/// Reuses the comprehensive Release Gate E2E & Failure Scenarios test suite so the exact same
/// 6-screen user journey and fault-recovery assertions can be executed both in headless CI
/// (`flutter test test/release_gate_e2e_test.dart`) and on a connected Android Emulator / physical phone
/// (`flutter test integration_test/app_e2e_test.dart`).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  release_gate_e2e.main();
}

