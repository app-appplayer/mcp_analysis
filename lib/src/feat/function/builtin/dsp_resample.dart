import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Resampling (`resample`) — decimation and linear-interpolation rate
/// conversion (the edge→PC data-reduction primitive).
///
/// Parameters: `column`, `mode` (decimate|linear), `factor` (decimate: keep
/// every Nth sample; an anti-alias moving average of the same length is
/// applied first), `sourceRate`/`targetRate` (linear mode, Hz). Results:
/// `values[]`, `outputRate` when derivable.
class ResampleFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'resample',
        description:
            'Decimate (with anti-alias averaging) or linearly resample a '
            'waveform',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the samples',
          ),
          'mode': AnalysisParameterSchema(
            name: 'mode',
            type: 'string',
            defaultValue: 'decimate',
            description: 'decimate | linear',
          ),
          'factor': AnalysisParameterSchema(
            name: 'factor',
            type: 'number',
            defaultValue: 2,
            description: 'Decimation factor (keep every Nth sample)',
          ),
          'sourceRate': AnalysisParameterSchema(
            name: 'sourceRate',
            type: 'number',
            description: 'Source rate in Hz (linear mode)',
          ),
          'targetRate': AnalysisParameterSchema(
            name: 'targetRate',
            type: 'number',
            description: 'Target rate in Hz (linear mode)',
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
    final mode = parameters['mode'] as String? ?? 'decimate';

    List<double> out;
    double? outputRate;
    if (mode == 'linear') {
      final src = (parameters['sourceRate'] as num?)?.toDouble();
      final dst = (parameters['targetRate'] as num?)?.toDouble();
      if (src == null || dst == null || src <= 0 || dst <= 0) {
        throw ArgumentError(
            'resample(linear) requires sourceRate and targetRate in Hz');
      }
      final outLen = math.max(1, (x.length * dst / src).floor());
      out = List<double>.generate(outLen, (i) {
        final pos = i * src / dst;
        final lo = pos.floor();
        final hi = math.min(lo + 1, x.length - 1);
        final frac = pos - lo;
        return x[lo] * (1 - frac) + x[hi] * frac;
      });
      outputRate = dst;
    } else {
      final factor = math.max(1, (parameters['factor'] as num?)?.toInt() ?? 2);
      // Anti-alias: moving average of [factor] before striding.
      final filtered = List<double>.filled(x.length, 0.0);
      var sum = 0.0;
      for (var i = 0; i < x.length; i++) {
        sum += x[i];
        if (i >= factor) sum -= x[i - factor];
        filtered[i] = sum / math.min(i + 1, factor);
      }
      out = <double>[
        for (var i = 0; i < x.length; i += factor) filtered[i],
      ];
      final src = (parameters['sourceRate'] as num?)?.toDouble();
      if (src != null) outputRate = src / factor;
    }

    return AnalysisFunctionResult(
      functionName: 'resample',
      results: {
        'column': column,
        'mode': mode,
        'values': out,
        'sampleCount': out.length,
        if (outputRate != null) 'outputRate': outputRate,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Signal envelope (`envelope`) — moving RMS or rectified peak-hold, the
/// vibration/audio amplitude-tracking primitive.
///
/// Parameters: `column`, `mode` (rms|peak, default rms), `window` (samples,
/// default 16). Results: `values[]` (same length).
class EnvelopeFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'envelope',
        description: 'Moving-RMS or rectified peak-hold signal envelope',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the samples',
          ),
          'mode': AnalysisParameterSchema(
            name: 'mode',
            type: 'string',
            defaultValue: 'rms',
            description: 'rms | peak',
          ),
          'window': AnalysisParameterSchema(
            name: 'window',
            type: 'number',
            defaultValue: 16,
            description: 'Envelope window length in samples',
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
    final mode = parameters['mode'] as String? ?? 'rms';
    final window = math.max(1, (parameters['window'] as num?)?.toInt() ?? 16);

    final out = List<double>.filled(x.length, 0.0);
    if (mode == 'peak') {
      // Rectified moving max (window-scan; envelope windows are small).
      for (var i = 0; i < x.length; i++) {
        var m = 0.0;
        for (var j = math.max(0, i - window + 1); j <= i; j++) {
          m = math.max(m, x[j].abs());
        }
        out[i] = m;
      }
    } else {
      var sumSq = 0.0;
      for (var i = 0; i < x.length; i++) {
        sumSq += x[i] * x[i];
        if (i >= window) sumSq -= x[i - window] * x[i - window];
        out[i] = math.sqrt(math.max(0, sumSq) / math.min(i + 1, window));
      }
    }

    return AnalysisFunctionResult(
      functionName: 'envelope',
      results: {
        'column': column,
        'mode': mode,
        'values': out,
        'sampleCount': out.length,
      },
      executionTime: sw.elapsed,
    );
  }
}
