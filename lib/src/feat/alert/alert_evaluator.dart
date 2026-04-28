import 'package:mcp_bundle/ports.dart';

import 'alert_publisher.dart';
import 'window_aggregator.dart';

/// Regex for window aggregate conditions: avg(column, 5m) > 75
final _windowConditionPattern = RegExp(
  r'^(\w+)\((\w+),\s*(\d+[smhd])\)\s*(>|>=|<|<=|==|!=)\s*(.+)$',
);

/// Regex for event-rate conditions: rate(column, "value", 5m) > 10
final _eventRateConditionPattern = RegExp(
  r'^rate\((\w+),\s*"([^"]+)",\s*(\d+[smhd])\)\s*(>|>=|<|<=|==|!=)\s*(.+)$',
);

/// Regex for simple conditions: column > value
final _simpleConditionPattern = RegExp(
  r'^(\w+)\s+(>|>=|<|<=|==|!=)\s+(.+)$',
);

/// Main facade for alert condition evaluation.
class AlertEvaluator {
  final AlertPublisher _publisher;

  AlertEvaluator({required AlertPublisher publisher}) : _publisher = publisher;

  /// Evaluate an AlertRule against current data. Returns AnalysisAlert.
  Future<AnalysisAlert> evaluate(
    AnalysisAlertRuleArtifact rule,
    AnalysisDataSet currentData,
  ) async {
    try {
      final result = _evaluateCondition(rule.condition, currentData);
      final evaluation = AlertEvaluation(
        ruleId: rule.artifactId,
        triggered: result.triggered,
        severity: rule.severity,
        condition: rule.condition,
        currentValue: result.value,
        timestamp: DateTime.now(),
        message: result.triggered
            ? 'Alert triggered: ${rule.condition} (current: ${result.value})'
            : null,
      );

      if (evaluation.triggered) {
        await _publisher.publish(evaluation);
        await _publisher.executeActionHook(rule.actionHook, evaluation);
      }

      return _toAnalysisAlert(evaluation, rule.actionHook);
    } catch (e) {
      if (e is AnalysisError && e.code != 'alert.invalid_condition') rethrow;
      return AnalysisAlert(
        alertRuleId: rule.artifactId,
        triggered: false,
        severity: rule.severity,
        condition: rule.condition,
        currentValue: null,
        timestamp: DateTime.now(),
      );
    }
  }

  /// Evaluate all AlertRules for a Job against current data.
  Future<List<AnalysisAlert>> evaluateAll(
    List<AnalysisAlertRuleArtifact> rules,
    AnalysisDataSet currentData,
  ) async {
    final alerts = <AnalysisAlert>[];
    for (final rule in rules) {
      alerts.add(await evaluate(rule, currentData));
    }
    return alerts;
  }

  /// Evaluate a streaming window against alert conditions.
  Future<List<AnalysisAlert>> evaluateWindow(
    List<AnalysisAlertRuleArtifact> rules,
    WindowState windowState,
  ) async {
    final windowData = AnalysisDataSet(
      columns: [const AnalysisColumnInfo(name: 'value', type: 'double')],
      rows: windowState.points
          .map((p) => <String, dynamic>{'value': p.v})
          .toList(),
      rowCount: windowState.pointCount,
    );
    return evaluateAll(rules, windowData);
  }

  /// Convert internal AlertEvaluation to mcp_bundle AnalysisAlert.
  AnalysisAlert _toAnalysisAlert(AlertEvaluation eval, String? actionHook) {
    return AnalysisAlert(
      alertRuleId: eval.ruleId,
      severity: eval.severity,
      timestamp: eval.timestamp,
      condition: eval.condition,
      currentValue: eval.currentValue,
      triggered: eval.triggered,
      actionHook: actionHook,
    );
  }

  _ConditionResult _evaluateCondition(
    String condition,
    AnalysisDataSet data,
  ) {
    final trimmed = condition.trim();

    // Try event-rate condition first: rate(column, "value", 5m) > 10
    final rateMatch = _eventRateConditionPattern.firstMatch(trimmed);
    if (rateMatch != null) {
      return _evaluateEventRateCondition(
        column: rateMatch.group(1)!,
        matchValue: rateMatch.group(2)!,
        windowStr: rateMatch.group(3)!,
        operator: rateMatch.group(4)!,
        thresholdStr: rateMatch.group(5)!.trim(),
        data: data,
      );
    }

    // Try window aggregate condition: avg(column, 5m) > 75
    final windowMatch = _windowConditionPattern.firstMatch(trimmed);
    if (windowMatch != null) {
      return _evaluateWindowCondition(
        aggregation: windowMatch.group(1)!,
        column: windowMatch.group(2)!,
        windowStr: windowMatch.group(3)!,
        operator: windowMatch.group(4)!,
        thresholdStr: windowMatch.group(5)!.trim(),
        data: data,
      );
    }

    // Try simple condition: column operator value
    final simpleMatch = _simpleConditionPattern.firstMatch(trimmed);
    if (simpleMatch != null) {
      return _evaluateSimpleCondition(
        column: simpleMatch.group(1)!,
        operator: simpleMatch.group(2)!,
        thresholdStr: simpleMatch.group(3)!.trim(),
        data: data,
      );
    }

    // Fallback: try splitting by whitespace for backward compatibility
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 3) {
      return _evaluateSimpleCondition(
        column: parts[0],
        operator: parts[1],
        thresholdStr: parts[2],
        data: data,
      );
    }

    throw AnalysisError(
      code: 'alert.invalid_condition',
      message: 'Cannot parse alert condition: "$condition"',
      details: {'condition': condition},
    );
  }

  _ConditionResult _evaluateWindowCondition({
    required String aggregation,
    required String column,
    required String windowStr,
    required String operator,
    required String thresholdStr,
    required AnalysisDataSet data,
  }) {
    final threshold = double.tryParse(thresholdStr);
    if (threshold == null) {
      throw AnalysisError(
        code: 'alert.invalid_condition',
        message: 'Invalid threshold value: "$thresholdStr"',
      );
    }

    // Build a window aggregator with the specified window size
    final windowDuration = _parseWindowDuration(windowStr);
    final aggregator = WindowAggregator(windowSize: windowDuration);

    // Add data points from the dataset
    for (final row in data.rows) {
      final rawValue = row[column];
      if (rawValue == null) continue;
      final value = rawValue is num
          ? rawValue.toDouble()
          : double.tryParse('$rawValue');
      if (value == null) continue;

      final ts = row['_timestamp'] is DateTime
          ? row['_timestamp'] as DateTime
          : DateTime.now();
      aggregator.add(AnalysisTimePoint(t: ts, v: value));
    }

    if (aggregator.state.pointCount == 0) {
      return const _ConditionResult(triggered: false, value: null);
    }

    // Compute the aggregate
    final aggValue = aggregator.aggregate(column, aggregation);
    final triggered = _compareValues(aggValue, operator, threshold);

    return _ConditionResult(triggered: triggered, value: aggValue);
  }

  _ConditionResult _evaluateSimpleCondition({
    required String column,
    required String operator,
    required String thresholdStr,
    required AnalysisDataSet data,
  }) {
    final threshold = double.tryParse(thresholdStr);
    if (threshold == null) {
      return const _ConditionResult(triggered: false, value: null);
    }

    // Find column values
    for (final row in data.rows) {
      final rawValue = row[column];
      if (rawValue == null) continue;
      final value = rawValue is num
          ? rawValue.toDouble()
          : double.tryParse('$rawValue');
      if (value == null) continue;

      if (_compareValues(value, operator, threshold)) {
        return _ConditionResult(triggered: true, value: value);
      }
    }

    // Check last row value for non-triggered result
    dynamic lastValue;
    if (data.rows.isNotEmpty) {
      lastValue = data.rows.last[column];
    }

    return _ConditionResult(triggered: false, value: lastValue);
  }

  _ConditionResult _evaluateEventRateCondition({
    required String column,
    required String matchValue,
    required String windowStr,
    required String operator,
    required String thresholdStr,
    required AnalysisDataSet data,
  }) {
    final threshold = double.tryParse(thresholdStr);
    if (threshold == null) {
      throw AnalysisError(
        code: 'alert.invalid_condition',
        message: 'Invalid threshold value: "$thresholdStr"',
      );
    }

    final windowDuration = _parseWindowDuration(windowStr);
    final windowMinutes = windowDuration.inSeconds / 60.0;
    if (windowMinutes <= 0) {
      return const _ConditionResult(triggered: false, value: null);
    }

    // Filter rows where column matches the target value within the window
    final now = DateTime.now();
    final cutoff = now.subtract(windowDuration);
    int matchCount = 0;

    for (final row in data.rows) {
      // Check timestamp if available
      final ts = row['_timestamp'];
      if (ts is DateTime && ts.isBefore(cutoff)) {
        continue;
      }

      // Check if column value matches
      final rawValue = row[column];
      if (rawValue == null) continue;
      if ('$rawValue' == matchValue) {
        matchCount++;
      }
    }

    // Compute rate = event count / window duration in minutes
    final rate = matchCount / windowMinutes;
    final triggered = _compareValues(rate, operator, threshold);

    return _ConditionResult(triggered: triggered, value: rate);
  }

  bool _compareValues(double value, String operator, double threshold) {
    return switch (operator) {
      '>' => value > threshold,
      '>=' => value >= threshold,
      '<' => value < threshold,
      '<=' => value <= threshold,
      '==' => value == threshold,
      '!=' => value != threshold,
      _ => false,
    };
  }

  Duration _parseWindowDuration(String window) {
    final match = RegExp(r'^(\d+)([smhd])$').firstMatch(window);
    if (match == null) return const Duration(minutes: 5);

    final value = int.parse(match.group(1)!);
    return switch (match.group(2)!) {
      's' => Duration(seconds: value),
      'm' => Duration(minutes: value),
      'h' => Duration(hours: value),
      'd' => Duration(days: value),
      _ => Duration(minutes: value),
    };
  }
}

class _ConditionResult {
  final bool triggered;
  final dynamic value;

  const _ConditionResult({required this.triggered, this.value});
}
