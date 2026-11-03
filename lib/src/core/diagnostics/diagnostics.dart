import 'package:flutter/foundation.dart';

/// ORPHEUS: crash reporting (Sentry) is removed. Diagnostics only go to the
/// console, which DeviceLog mirrors into the local, user-shareable log.
enum DiagnosticLevel { debug, info, warning, error, fatal }

class Diagnostics {
  const Diagnostics();

  Future<void> capture(
    Object error, {
    required String operation,
    StackTrace? stackTrace,
    DiagnosticLevel level = DiagnosticLevel.warning,
    Map<String, String> tags = const {},
    Map<String, Object?> extra = const {},
  }) async {
    debugPrintThrottled('[$operation] $error');
  }

  Future<void> report(
    String message, {
    Map<String, Object?> data = const {},
  }) async {
    debugPrintThrottled('[report] $message $data');
  }

  void trail(
    String message, {
    String category = 'app',
    Map<String, Object?> data = const {},
  }) {
    debugPrintThrottled('[$category] $message');
  }
}
