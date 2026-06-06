import 'dart:async';

import 'package:firebase_performance/firebase_performance.dart';

class PerformanceTraceService {
  PerformanceTraceService._();

  static Future<T> record<T>(
    String traceName,
    FutureOr<T> Function() action,
  ) async {
    final trace = FirebasePerformance.instance.newTrace(traceName);
    await trace.start();
    try {
      return await action();
    } finally {
      await trace.stop();
    }
  }

  static Future<void> recordVoid(
    String traceName,
    FutureOr<void> Function() action,
  ) async {
    await record<void>(traceName, action);
  }
}
