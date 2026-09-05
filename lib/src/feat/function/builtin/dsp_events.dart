import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Prominence-gated peak detection (`peak_detect`) — the QRS/pulse-class
/// primitive.
///
/// Parameters: `column`, `minHeight` (absolute floor), `minProminence`
/// (height above the higher of the two flanking valleys, default 0 = off),
/// `minDistance` (samples between accepted peaks, default 1). Results:
/// `indices[]`, `values[]`, `count`, `intervals[]` (samples between
/// consecutive peaks — feed HRV-style interval statistics directly).
class PeakDetectFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'peak_detect',
        description:
            'Local-maximum peak detection with height/prominence/distance '
            'gates',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the samples',
          ),
          'minHeight': AnalysisParameterSchema(
            name: 'minHeight',
            type: 'number',
            description: 'Absolute minimum peak value',
          ),
          'minProminence': AnalysisParameterSchema(
            name: 'minProminence',
            type: 'number',
            defaultValue: 0,
            description: 'Minimum prominence above flanking valleys',
          ),
          'minDistance': AnalysisParameterSchema(
            name: 'minDistance',
            type: 'number',
            defaultValue: 1,
            description: 'Minimum samples between accepted peaks',
          ),
        },
        results: const {
          'column': AnalysisResultSchema(
            name: 'column',
            type: 'string',
            description: 'Analyzed column',
          ),
          'indices': AnalysisResultSchema(
            name: 'indices',
            type: 'array',
            itemType: 'number',
            description: 'Sample index of each peak',
          ),
          'values': AnalysisResultSchema(
            name: 'values',
            type: 'array',
            itemType: 'number',
            description: 'Value at each peak',
          ),
          'count': AnalysisResultSchema(
            name: 'count',
            type: 'number',
            description: 'Number of peaks',
          ),
          'intervals': AnalysisResultSchema(
            name: 'intervals',
            type: 'array',
            itemType: 'number',
            description: 'Sample gaps between peaks',
          ),
        },
        supportedDataTypes: ['double', 'int'],
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    final sw = Stopwatch()..start();
    final column = resolveColumn(parameters, data);
    final x = numericColumn(data, column);
    final minHeight = (parameters['minHeight'] as num?)?.toDouble();
    final minProm = (parameters['minProminence'] as num?)?.toDouble() ?? 0.0;
    final minDist =
        math.max(1, (parameters['minDistance'] as num?)?.toInt() ?? 1);

    // Local maxima (plateau-aware: first sample of a flat top counts).
    final candidates = <int>[];
    for (var i = 1; i < x.length - 1; i++) {
      if (x[i] > x[i - 1] && x[i] >= x[i + 1]) {
        if (minHeight == null || x[i] >= minHeight) candidates.add(i);
      }
    }

    // Prominence gate: walk to the higher flanking valley.
    final gated = <int>[];
    for (final i in candidates) {
      if (minProm <= 0) {
        gated.add(i);
        continue;
      }
      var leftMin = x[i];
      for (var j = i - 1; j >= 0 && x[j] <= x[i]; j--) {
        leftMin = math.min(leftMin, x[j]);
      }
      var rightMin = x[i];
      for (var j = i + 1; j < x.length && x[j] <= x[i]; j++) {
        rightMin = math.min(rightMin, x[j]);
      }
      final prominence = x[i] - math.max(leftMin, rightMin);
      if (prominence >= minProm) gated.add(i);
    }

    // Distance gate: greedy by descending height.
    final byHeight = List<int>.from(gated)
      ..sort((a, b) => x[b].compareTo(x[a]));
    final kept = <int>[];
    for (final i in byHeight) {
      if (kept.every((k) => (k - i).abs() >= minDist)) kept.add(i);
    }
    kept.sort();

    final intervals = <int>[
      for (var k = 1; k < kept.length; k++) kept[k] - kept[k - 1],
    ];

    return AnalysisFunctionResult(
      functionName: 'peak_detect',
      results: {
        'column': column,
        'indices': kept,
        'values': [for (final i in kept) x[i]],
        'count': kept.length,
        'intervals': intervals,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Zero-crossing analysis (`zero_crossing`) — frequency/period estimation
/// for scope-class waveforms.
///
/// Parameters: `column`, `sampleRate` (optional — enables Hz estimates),
/// `direction` (both|rising|falling, default both). Results: `indices[]`
/// (sample index before the crossing), `count`, and with `sampleRate`:
/// `estimatedFrequency` (rising-edge period average), `crossingRate` (/s).
class ZeroCrossingFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'zero_crossing',
        description: 'Zero-crossing locations, rate and frequency estimation',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the samples',
          ),
          'sampleRate': AnalysisParameterSchema(
            name: 'sampleRate',
            type: 'number',
            description: 'Sampling rate in Hz (enables frequency estimates)',
          ),
          'direction': AnalysisParameterSchema(
            name: 'direction',
            type: 'string',
            defaultValue: 'both',
            description: 'both | rising | falling',
          ),
        },
        results: const {
          'column': AnalysisResultSchema(
            name: 'column',
            type: 'string',
            description: 'Analyzed column',
          ),
          'indices': AnalysisResultSchema(
            name: 'indices',
            type: 'array',
            itemType: 'number',
            description: 'Sample index of each crossing',
          ),
          'count': AnalysisResultSchema(
            name: 'count',
            type: 'number',
            description: 'Number of crossings',
          ),
          'crossingRate': AnalysisResultSchema(
            name: 'crossingRate',
            type: 'number',
            unit: '/s',
            description: 'Crossings per second; present when sampleRate is '
                'given',
          ),
          'estimatedFrequency': AnalysisResultSchema(
            name: 'estimatedFrequency',
            type: 'number',
            unit: 'Hz',
            description: 'Frequency from the mean rising-edge period; '
                'present when at least two rising edges are found',
          ),
        },
        supportedDataTypes: ['double', 'int'],
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    final sw = Stopwatch()..start();
    final column = resolveColumn(parameters, data);
    final x = numericColumn(data, column);
    final fs = (parameters['sampleRate'] as num?)?.toDouble();
    final direction = parameters['direction'] as String? ?? 'both';

    final indices = <int>[];
    final rising = <int>[];
    for (var i = 1; i < x.length; i++) {
      final wasNeg = x[i - 1] < 0, isNeg = x[i] < 0;
      if (wasNeg == isNeg) continue;
      final isRising = wasNeg && !isNeg;
      if (direction == 'rising' && !isRising) continue;
      if (direction == 'falling' && isRising) continue;
      indices.add(i - 1);
      if (isRising) rising.add(i - 1);
    }

    double? estimatedFrequency;
    double? crossingRate;
    if (fs != null && fs > 0 && x.length > 1) {
      crossingRate = indices.length / (x.length / fs);
      if (rising.length >= 2) {
        final periods = [
          for (var k = 1; k < rising.length; k++)
            (rising[k] - rising[k - 1]) / fs,
        ];
        final meanPeriod = periods.reduce((a, b) => a + b) / periods.length;
        estimatedFrequency = meanPeriod > 0 ? 1 / meanPeriod : null;
      }
    }

    return AnalysisFunctionResult(
      functionName: 'zero_crossing',
      results: {
        'column': column,
        'indices': indices,
        'count': indices.length,
        if (crossingRate != null) 'crossingRate': crossingRate,
        if (estimatedFrequency != null)
          'estimatedFrequency': estimatedFrequency,
      },
      executionTime: sw.elapsed,
    );
  }
}
