import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Software lock-in amplifier (`lockin`) — synchronous (phase-sensitive)
/// demodulation: multiply by a sin/cos reference at the target frequency,
/// lowpass the products, and read amplitude/phase of exactly that component
/// with strong rejection of everything else (lock-in thermography, weak
/// tone extraction, impedance measurement).
///
/// Division of labor: the ANALOG front end (pre-amplification of
/// sub-ADC-noise signals, anti-aliasing, avoiding ADC saturation under a
/// large background) is the hardware/board tier's job — this function is
/// the digital lock-in over an adequately digitized signal.
///
/// Parameters: `column`, `sampleRate` (Hz, required),
/// `referenceFrequency` (Hz, required), `lowpassCutoff` (Hz, default
/// referenceFrequency/10), `settle` (fraction of the series discarded
/// before reading the scalar outputs, default 0.5). Results: `amplitude`,
/// `phase` (radians), `i`/`q` (settled means), `amplitudeSeries[]`.
class LockinFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'lockin',
        description:
            'Software lock-in amplifier — synchronous demodulation at a '
            'reference frequency (amplitude + phase)',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the samples',
          ),
          'sampleRate': AnalysisParameterSchema(
            name: 'sampleRate',
            type: 'number',
            description: 'Sampling rate in Hz (required)',
          ),
          'referenceFrequency': AnalysisParameterSchema(
            name: 'referenceFrequency',
            type: 'number',
            description: 'Reference (demodulation) frequency in Hz (required)',
          ),
          'lowpassCutoff': AnalysisParameterSchema(
            name: 'lowpassCutoff',
            type: 'number',
            description:
                'Post-demodulation lowpass cutoff in Hz (default f_ref/10)',
          ),
          'settle': AnalysisParameterSchema(
            name: 'settle',
            type: 'number',
            defaultValue: 0.5,
            description:
                'Fraction of the series discarded as filter settling time '
                'before reading amplitude/phase (0..0.9)',
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
    final fs = (parameters['sampleRate'] as num?)?.toDouble();
    final fRef = (parameters['referenceFrequency'] as num?)?.toDouble();
    if (fs == null || fs <= 0 || fRef == null || fRef <= 0) {
      throw ArgumentError(
          'lockin requires sampleRate and referenceFrequency in Hz');
    }
    if (fRef >= fs / 2) {
      throw ArgumentError(
          'referenceFrequency ($fRef Hz) must be below Nyquist (${fs / 2})');
    }
    final x = numericColumn(data, column);
    if (x.length < 16) throw ArgumentError('lockin requires ≥ 16 samples');
    final cutoff =
        (parameters['lowpassCutoff'] as num?)?.toDouble() ?? fRef / 10;
    final settle =
        ((parameters['settle'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 0.9);

    // Demodulate: I = LP(x·cos), Q = LP(x·sin). Two cascaded biquads give a
    // 4th-order rolloff so off-reference tones die fast.
    final iRaw = List<double>.generate(
        x.length, (n) => x[n] * math.cos(2 * math.pi * fRef * n / fs));
    final qRaw = List<double>.generate(
        x.length, (n) => x[n] * math.sin(2 * math.pi * fRef * n / fs));
    final iF = _lp2(iRaw, fs, cutoff);
    final qF = _lp2(qRaw, fs, cutoff);

    final start = (x.length * settle).floor();
    var iMean = 0.0, qMean = 0.0;
    for (var n = start; n < x.length; n++) {
      iMean += iF[n];
      qMean += qF[n];
    }
    final count = x.length - start;
    iMean /= count;
    qMean /= count;

    // x = A·sin(2πf t + φ): LP(x·sin)=A/2·cosφ, LP(x·cos)=A/2·sinφ.
    final amplitude = 2 * math.sqrt(iMean * iMean + qMean * qMean);
    final phase = math.atan2(iMean, qMean);
    final amplitudeSeries = List<double>.generate(x.length,
        (n) => 2 * math.sqrt(iF[n] * iF[n] + qF[n] * qF[n]));

    return AnalysisFunctionResult(
      functionName: 'lockin',
      results: {
        'column': column,
        'referenceFrequency': fRef,
        'amplitude': amplitude,
        'phase': phase,
        'i': iMean,
        'q': qMean,
        'amplitudeSeries': amplitudeSeries,
      },
      executionTime: sw.elapsed,
    );
  }

  /// Two cascaded RBJ lowpass biquads (4th-order rolloff).
  List<double> _lp2(List<double> x, double fs, double cutoff) {
    final w0 = 2 * math.pi * cutoff / fs;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * 0.7071);
    final a0 = 1 + alpha;
    final b0 = (1 - cosW0) / 2 / a0;
    final b1 = (1 - cosW0) / a0;
    final b2 = (1 - cosW0) / 2 / a0;
    final a1 = -2 * cosW0 / a0;
    final a2 = (1 - alpha) / a0;

    List<double> pass(List<double> input) {
      final out = List<double>.filled(input.length, 0.0);
      var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
      for (var n = 0; n < input.length; n++) {
        final y = b0 * input[n] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = input[n];
        y2 = y1;
        y1 = y;
        out[n] = y;
      }
      return out;
    }

    return pass(pass(x));
  }
}
