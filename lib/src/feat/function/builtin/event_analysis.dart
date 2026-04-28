import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Analyzes event patterns: frequency, MTBF, MTTR, state transitions.
class EventAnalysisFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'event_analysis',
        description:
            'Analyze event patterns: frequency, MTBF, MTTR, state transitions',
        parameters: {
          'eventColumn': AnalysisParameterSchema(
            name: 'eventColumn',
            type: 'string',
            defaultValue: 'event',
            description: 'Column containing event type',
          ),
          'timestampColumn': AnalysisParameterSchema(
            name: 'timestampColumn',
            type: 'string',
            defaultValue: '_timestamp',
            description: 'Column containing timestamp',
          ),
          'metrics': AnalysisParameterSchema(
            name: 'metrics',
            type: 'array',
            defaultValue: ['frequency'],
            description: 'Metrics to compute: frequency, mtbf, mttr, transitions',
          ),
        },
        supportedDataTypes: ['string', 'datetime'],
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    final sw = Stopwatch()..start();
    final eventColumn = parameters['eventColumn'] as String? ?? 'event';
    final tsColumn = parameters['timestampColumn'] as String? ?? '_timestamp';
    final metrics = (parameters['metrics'] as List?)?.cast<String>() ??
        ['frequency'];

    final results = <String, dynamic>{};

    if (metrics.contains('frequency')) {
      final frequency = <String, int>{};
      for (final row in data.rows) {
        final event = '${row[eventColumn]}';
        frequency[event] = (frequency[event] ?? 0) + 1;
      }
      results['frequency'] = frequency;
    }

    if (metrics.contains('mtbf')) {
      // Mean Time Between Failures
      final failureEvents = data.rows
          .where((r) => '${r[eventColumn]}'.toLowerCase().contains('error') ||
              '${r[eventColumn]}'.toLowerCase().contains('fail'))
          .toList();

      if (failureEvents.length >= 2) {
        final timestamps = failureEvents
            .map((r) {
              final ts = r[tsColumn];
              if (ts is DateTime) return ts;
              if (ts is String) return DateTime.tryParse(ts);
              return null;
            })
            .whereType<DateTime>()
            .toList();

        if (timestamps.length >= 2) {
          var totalMs = 0;
          for (var i = 1; i < timestamps.length; i++) {
            totalMs += timestamps[i].difference(timestamps[i - 1]).inMilliseconds;
          }
          results['mtbf'] = Duration(
            milliseconds: totalMs ~/ (timestamps.length - 1),
          ).inMinutes;
        }
      }
      results['mtbf'] ??= 0;
    }

    if (metrics.contains('mttr')) {
      // Mean Time To Recovery
      final failureEvents = data.rows
          .where((r) =>
              '${r[eventColumn]}'.toLowerCase().contains('error') ||
              '${r[eventColumn]}'.toLowerCase().contains('fail'))
          .toList();

      final recoveryEvents = data.rows
          .where((r) =>
              '${r[eventColumn]}'.toLowerCase().contains('recover') ||
              '${r[eventColumn]}'.toLowerCase().contains('resolve') ||
              '${r[eventColumn]}'.toLowerCase().contains('fixed'))
          .toList();

      DateTime? _parseTimestamp(dynamic ts) {
        if (ts is DateTime) return ts;
        if (ts is String) return DateTime.tryParse(ts);
        return null;
      }

      if (failureEvents.isNotEmpty && recoveryEvents.isNotEmpty) {
        var totalMs = 0;
        var pairCount = 0;

        for (final failure in failureEvents) {
          final failureTs = _parseTimestamp(failure[tsColumn]);
          if (failureTs == null) continue;

          // Find next recovery after this failure
          DateTime? recoveryTs;
          for (final recovery in recoveryEvents) {
            final rTs = _parseTimestamp(recovery[tsColumn]);
            if (rTs != null && rTs.isAfter(failureTs)) {
              recoveryTs = rTs;
              break;
            }
          }

          if (recoveryTs != null) {
            totalMs += recoveryTs.difference(failureTs).inMilliseconds;
            pairCount++;
          }
        }

        results['mttr'] = pairCount > 0
            ? Duration(milliseconds: totalMs ~/ pairCount).inMinutes
            : 0;
      } else {
        results['mttr'] = 0;
      }
    }

    if (metrics.contains('transitions')) {
      final transitions = <String, Map<String, int>>{};
      for (var i = 1; i < data.rows.length; i++) {
        final from = '${data.rows[i - 1][eventColumn]}';
        final to = '${data.rows[i][eventColumn]}';
        transitions.putIfAbsent(from, () => {});
        transitions[from]![to] = (transitions[from]![to] ?? 0) + 1;
      }
      results['transitions'] = transitions;
    }

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'event_analysis',
      results: results,
      executionTime: sw.elapsed,
    );
  }
}
