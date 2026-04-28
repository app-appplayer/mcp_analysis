import 'package:mcp_bundle/ports.dart';

/// Records per-step execution logs for each Job.
class StepLogger {
  final List<AnalysisJobLog> _logs = [];

  /// Log a step execution.
  void logStep({
    required String step,
    required int inputSize,
    required int outputSize,
    required Duration executionTime,
  }) {
    _logs.add(AnalysisJobLog(
      step: step,
      timestamp: DateTime.now(),
      inputSize: inputSize,
      outputSize: outputSize,
      executionTime: executionTime,
    ));
  }

  /// Get all logged steps.
  List<AnalysisJobLog> get logs => List.unmodifiable(_logs);

  /// Clear all logs.
  void clear() => _logs.clear();
}
