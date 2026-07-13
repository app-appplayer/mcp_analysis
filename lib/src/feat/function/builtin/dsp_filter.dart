import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Digital filtering (`digital_filter`) — RBJ-cookbook biquad IIR
/// (lowpass / highpass / bandpass) and FIR moving average, with optional
/// zero-phase (forward–backward) application.
///
/// Parameters: `column`, `sampleRate` (required for biquad types), `type`
/// (lowpass|highpass|bandpass|moving_average), `cutoff` (Hz; center
/// frequency for bandpass), `q` (default 0.7071), `taps` (moving_average
/// window length, default 5), `zeroPhase` (default false — filtfilt when
/// true). Results: `values[]` (filtered series, same length).
class DigitalFilterFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'digital_filter',
        description:
            'Biquad IIR (lowpass/highpass/bandpass) and FIR moving-average '
            'filtering, optionally zero-phase',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the samples',
          ),
          'type': AnalysisParameterSchema(
            name: 'type',
            type: 'string',
            defaultValue: 'lowpass',
            description: 'lowpass | highpass | bandpass | moving_average',
          ),
          'sampleRate': AnalysisParameterSchema(
            name: 'sampleRate',
            type: 'number',
            description: 'Sampling rate in Hz (required for biquad types)',
          ),
          'cutoff': AnalysisParameterSchema(
            name: 'cutoff',
            type: 'number',
            description:
                'Cutoff frequency in Hz (center frequency for bandpass)',
          ),
          'q': AnalysisParameterSchema(
            name: 'q',
            type: 'number',
            defaultValue: 0.7071,
            description: 'Filter Q factor',
          ),
          'taps': AnalysisParameterSchema(
            name: 'taps',
            type: 'number',
            defaultValue: 5,
            description: 'moving_average window length',
          ),
          'zeroPhase': AnalysisParameterSchema(
            name: 'zeroPhase',
            type: 'boolean',
            defaultValue: false,
            description: 'Apply forward–backward for zero phase shift',
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
    final signal = numericColumn(data, column);
    final type = parameters['type'] as String? ?? 'lowpass';
    final zeroPhase = parameters['zeroPhase'] as bool? ?? false;

    List<double> out;
    if (type == 'moving_average') {
      final taps = math.max(1, (parameters['taps'] as num?)?.toInt() ?? 5);
      out = _movingAverage(signal, taps);
    } else {
      final fs = (parameters['sampleRate'] as num?)?.toDouble();
      final cutoff = (parameters['cutoff'] as num?)?.toDouble();
      if (fs == null || fs <= 0 || cutoff == null || cutoff <= 0) {
        throw ArgumentError(
            'digital_filter($type) requires sampleRate and cutoff in Hz');
      }
      if (cutoff >= fs / 2) {
        throw ArgumentError(
            'cutoff ($cutoff Hz) must be below Nyquist (${fs / 2} Hz)');
      }
      final q = (parameters['q'] as num?)?.toDouble() ?? 0.7071;
      final c = _BiquadCoeffs.rbj(type, fs, cutoff, q);
      out = _biquad(signal, c);
      if (zeroPhase) {
        out = _biquad(out.reversed.toList(), c).reversed.toList();
      }
    }

    return AnalysisFunctionResult(
      functionName: 'digital_filter',
      results: {
        'column': column,
        'type': type,
        'values': out,
        'sampleCount': out.length,
      },
      executionTime: sw.elapsed,
    );
  }

  List<double> _movingAverage(List<double> x, int taps) {
    final out = List<double>.filled(x.length, 0.0);
    var sum = 0.0;
    for (var i = 0; i < x.length; i++) {
      sum += x[i];
      if (i >= taps) sum -= x[i - taps];
      out[i] = sum / math.min(i + 1, taps);
    }
    return out;
  }

  List<double> _biquad(List<double> x, _BiquadCoeffs c) {
    final out = List<double>.filled(x.length, 0.0);
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    for (var i = 0; i < x.length; i++) {
      final y = c.b0 * x[i] + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
      x2 = x1;
      x1 = x[i];
      y2 = y1;
      y1 = y;
      out[i] = y;
    }
    return out;
  }
}

/// Normalized RBJ audio-EQ-cookbook biquad coefficients.
class _BiquadCoeffs {
  final double b0, b1, b2, a1, a2;
  const _BiquadCoeffs(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory _BiquadCoeffs.rbj(String type, double fs, double f0, double q) {
    final w0 = 2 * math.pi * f0 / fs;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
      case 'highpass':
        b0 = (1 + cosW0) / 2;
        b1 = -(1 + cosW0);
        b2 = (1 + cosW0) / 2;
        break;
      case 'bandpass':
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
        break;
      case 'lowpass':
      default:
        b0 = (1 - cosW0) / 2;
        b1 = 1 - cosW0;
        b2 = (1 - cosW0) / 2;
        break;
    }
    a0 = 1 + alpha;
    a1 = -2 * cosW0;
    a2 = 1 - alpha;
    return _BiquadCoeffs(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
  }
}
