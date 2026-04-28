import 'package:mcp_bundle/ports.dart';

/// Evaluation result for an alert condition.
class AlertEvaluation {
  final String ruleId;
  final bool triggered;
  final AnalysisAlertSeverity severity;
  final String condition;
  final dynamic currentValue;
  final DateTime timestamp;
  final String? message;

  const AlertEvaluation({
    required this.ruleId,
    required this.triggered,
    required this.severity,
    required this.condition,
    this.currentValue,
    required this.timestamp,
    this.message,
  });
}

/// Minimal interface for form report generation triggered by alert actionHooks.
///
/// Implementations bridge to the mcp_form package's FormPort for
/// creating alert report documents from templates.
abstract class AlertFormPort {
  /// Generate a report document using the given template and context data.
  Future<void> generateReport(
    String templateId,
    Map<String, dynamic> context,
  );
}

/// Publishes alert events through EventPort.
class AlertPublisher {
  final EventPort _eventPort;
  final AlertFormPort? _formPort;

  AlertPublisher({
    required EventPort eventPort,
    AlertFormPort? formPort,
  })  : _eventPort = eventPort,
        _formPort = formPort;

  /// Publish an alert event and execute any actionHook.
  /// Throws [AnalysisError] with code `alert.publish_failed` if
  /// the event port fails to publish.
  /// ActionHook errors are non-blocking (logged via event port, not thrown).
  Future<void> publish(AlertEvaluation evaluation) async {
    if (!evaluation.triggered) return;

    try {
      await _eventPort.publish(PortEvent(
        type: 'analysis.alert',
        payload: {
          'ruleId': evaluation.ruleId,
          'condition': evaluation.condition,
          'currentValue': evaluation.currentValue,
          'severity': evaluation.severity.name,
          'message': evaluation.message,
        },
        timestamp: evaluation.timestamp,
        source: 'mcp_analysis',
      ));
    } catch (e) {
      throw AnalysisError(
        code: 'alert.publish_failed',
        message: 'Failed to publish alert for rule "${evaluation.ruleId}": $e',
        details: {
          'ruleId': evaluation.ruleId,
          'severity': evaluation.severity.name,
        },
        timestamp: DateTime.now(),
      );
    }
  }

  /// Execute an actionHook if present. All errors are non-blocking.
  Future<void> executeActionHook(
    String? actionHook,
    AlertEvaluation evaluation,
  ) async {
    if (actionHook == null || actionHook.isEmpty) return;

    try {
      final separatorIndex = actionHook.indexOf(':');
      if (separatorIndex < 0) {
        // No type prefix found, log warning
        await _publishWarning(
          'Unknown actionHook format: "$actionHook"',
          evaluation,
        );
        return;
      }

      final hookType = actionHook.substring(0, separatorIndex);
      final hookTarget = actionHook.substring(separatorIndex + 1);

      switch (hookType) {
        case 'form':
          if (_formPort == null) {
            await _publishWarning(
              'FormPort not available for actionHook: "$actionHook"',
              evaluation,
            );
            return;
          }
          await _formPort!.generateReport(hookTarget, {
            'alertRuleId': evaluation.ruleId,
            'severity': evaluation.severity.name,
            'condition': evaluation.condition,
            'currentValue': evaluation.currentValue,
            'timestamp': evaluation.timestamp.toIso8601String(),
            'message': evaluation.message,
          });
        default:
          await _publishWarning(
            'Unknown actionHook type: "$hookType"',
            evaluation,
          );
      }
    } catch (e) {
      // All actionHook errors are non-blocking
      try {
        await _publishWarning(
          'ActionHook execution failed: "$actionHook" - $e',
          evaluation,
        );
      } catch (_) {
        // Even warning publication failure is swallowed
      }
    }
  }

  /// Publish a warning event for actionHook issues.
  Future<void> _publishWarning(
    String message,
    AlertEvaluation evaluation,
  ) async {
    try {
      await _eventPort.publish(PortEvent(
        type: 'analysis.alert.warning',
        payload: {
          'ruleId': evaluation.ruleId,
          'warning': message,
        },
        timestamp: DateTime.now(),
        source: 'mcp_analysis',
      ));
    } catch (_) {
      // Warning publication failure is non-blocking
    }
  }
}
