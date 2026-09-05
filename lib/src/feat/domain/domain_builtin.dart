import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function/function_dispatcher.dart';
import '../function/builtin/dsp_common.dart';

/// Domain layer (tier 1) — thin, pure-Dart, dependency-free domain
/// functions: each is a COMPOSITION of compute-layer primitives plus
/// domain indicator definitions and judgment standards. Anything needing
/// an external dependency (instrument drivers, file-format parsers, FFI)
/// is tier 2 and lives in an external pack behind the ports (architecture
/// decision 2026-07-14: contract ← compute ← domain tier 1 in ONE
/// package).

/// Vibration severity indicators (`vibration_indicators`) — rotating
/// machinery condition monitoring.
///
/// Parameters: `column` (velocity signal, mm/s for ISO zoning),
/// `machineClass` (1..4, ISO 10816-1 class; default 2 = medium machines).
/// Results: `rms`, `peak`, `peakToPeak`, `crestFactor`, `kurtosis`,
/// `skewness`, `isoZone` (A/B/C/D), `isoLimits` (zone boundaries used).
/// Kurtosis > 3 signals impulsive faults (bearings); the ISO zone grades
/// overall severity.
class VibrationIndicatorsFunction implements AnalysisFunction {
  /// ISO 10816-1 zone boundaries (velocity RMS, mm/s) per machine class:
  /// A/B, B/C, C/D.
  static const Map<int, List<double>> isoZoneBounds = {
    1: [0.71, 1.8, 4.5], // small machines (≤15 kW)
    2: [1.12, 2.8, 7.1], // medium machines (15–75 kW)
    3: [1.8, 4.5, 11.2], // large rigid foundation
    4: [2.8, 7.1, 18.0], // large soft foundation
  };

  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'vibration_indicators',
        description: 'Rotating-machinery vibration indicators + ISO 10816 zone',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Velocity signal column (mm/s for ISO zoning)',
          ),
          'machineClass': AnalysisParameterSchema(
            name: 'machineClass',
            type: 'number',
            defaultValue: 2,
            description: 'ISO 10816-1 machine class (1..4)',
          ),
        },
        results: const {
          'column': AnalysisResultSchema(
            name: 'column',
            type: 'string',
            description: 'Analyzed velocity column',
          ),
          'rms': AnalysisResultSchema(
            name: 'rms',
            type: 'number',
            unit: 'mm/s',
            description: 'Root mean square velocity',
          ),
          'peak': AnalysisResultSchema(
            name: 'peak',
            type: 'number',
            unit: 'mm/s',
            description: 'Peak velocity',
          ),
          'peakToPeak': AnalysisResultSchema(
            name: 'peakToPeak',
            type: 'number',
            unit: 'mm/s',
            description: 'Peak-to-peak velocity',
          ),
          'crestFactor': AnalysisResultSchema(
            name: 'crestFactor',
            type: 'number',
            description: 'Peak over RMS',
          ),
          'kurtosis': AnalysisResultSchema(
            name: 'kurtosis',
            type: 'number',
            description: 'Impulsiveness; above 3 suggests bearing faults',
          ),
          'skewness': AnalysisResultSchema(
            name: 'skewness',
            type: 'number',
            description: 'Distribution asymmetry',
          ),
          'isoZone': AnalysisResultSchema(
            name: 'isoZone',
            type: 'string',
            description: 'ISO 10816 zone A/B/C/D',
          ),
          'isoLimits': AnalysisResultSchema(
            name: 'isoLimits',
            type: 'object',
            description: 'Zone boundaries used',
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
    if (x.length < 4) {
      throw ArgumentError('vibration_indicators requires ≥ 4 samples');
    }
    final machineClass =
        ((parameters['machineClass'] as num?)?.toInt() ?? 2).clamp(1, 4);

    final n = x.length;
    final mean = x.reduce((a, b) => a + b) / n;
    var sumSq = 0.0, m3 = 0.0, m4 = 0.0;
    var peak = 0.0, minV = x[0], maxV = x[0];
    for (final v in x) {
      final d = v - mean;
      sumSq += d * d;
      m3 += d * d * d;
      m4 += d * d * d * d;
      peak = math.max(peak, v.abs());
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
    final rms = math.sqrt(x.map((v) => v * v).reduce((a, b) => a + b) / n);
    final popVar = sumSq / n;
    final kurtosis = popVar > 0 ? (m4 / n) / (popVar * popVar) : 0.0;
    final skewness = popVar > 0 ? (m3 / n) / math.pow(popVar, 1.5) : 0.0;
    final crest = rms > 0 ? peak / rms : 0.0;

    final bounds = isoZoneBounds[machineClass]!;
    final zone = rms <= bounds[0]
        ? 'A'
        : rms <= bounds[1]
            ? 'B'
            : rms <= bounds[2]
                ? 'C'
                : 'D';

    return AnalysisFunctionResult(
      functionName: 'vibration_indicators',
      results: {
        'column': column,
        'rms': rms,
        'peak': peak,
        'peakToPeak': maxV - minV,
        'crestFactor': crest,
        'kurtosis': kurtosis,
        'skewness': skewness,
        'isoZone': zone,
        'isoLimits': {
          'machineClass': machineClass,
          'A/B': bounds[0],
          'B/C': bounds[1],
          'C/D': bounds[2],
        },
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Heart-rate variability metrics (`hrv_metrics`) — the standard HRV
/// indicator set over RR intervals (feed `peak_detect`'s `intervals`
/// converted to milliseconds, or a column of RR values).
///
/// Parameters: `column` (RR intervals), `unit` (ms|s, default ms).
/// Results: `meanRR` (ms), `meanHeartRate` (bpm), `sdnn` (ms), `rmssd`
/// (ms), `pnn50` (%), `count`.
class HrvMetricsFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'hrv_metrics',
        description:
            'Standard HRV indicators (SDNN, RMSSD, pNN50) over RR intervals',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'RR-interval column',
          ),
          'unit': AnalysisParameterSchema(
            name: 'unit',
            type: 'string',
            defaultValue: 'ms',
            description: 'RR unit: ms | s',
          ),
        },
        results: const {
          'column': AnalysisResultSchema(
            name: 'column',
            type: 'string',
            description: 'Analyzed RR interval column',
          ),
          'count': AnalysisResultSchema(
            name: 'count',
            type: 'number',
            description: 'Intervals used',
          ),
          'meanRR': AnalysisResultSchema(
            name: 'meanRR',
            type: 'number',
            unit: 'ms',
            description: 'Mean RR interval',
          ),
          'meanHeartRate': AnalysisResultSchema(
            name: 'meanHeartRate',
            type: 'number',
            unit: 'bpm',
            description: 'Mean heart rate',
          ),
          'sdnn': AnalysisResultSchema(
            name: 'sdnn',
            type: 'number',
            unit: 'ms',
            description: 'Standard deviation of NN intervals',
          ),
          'rmssd': AnalysisResultSchema(
            name: 'rmssd',
            type: 'number',
            unit: 'ms',
            description: 'Root mean square of successive differences',
          ),
          'pnn50': AnalysisResultSchema(
            name: 'pnn50',
            type: 'number',
            unit: '%',
            description: 'Share of successive differences over 50 ms',
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
    var rr = numericColumn(data, column);
    if (rr.length < 2) {
      throw ArgumentError('hrv_metrics requires ≥ 2 RR intervals');
    }
    if ((parameters['unit'] as String? ?? 'ms') == 's') {
      rr = [for (final v in rr) v * 1000.0];
    }

    final n = rr.length;
    final meanRR = rr.reduce((a, b) => a + b) / n;
    final sdnn = math.sqrt(
        rr.map((v) => (v - meanRR) * (v - meanRR)).reduce((a, b) => a + b) /
            (n - 1));
    var sumSqDiff = 0.0;
    var nn50 = 0;
    for (var i = 1; i < n; i++) {
      final d = rr[i] - rr[i - 1];
      sumSqDiff += d * d;
      if (d.abs() > 50.0) nn50++;
    }
    final rmssd = math.sqrt(sumSqDiff / (n - 1));

    return AnalysisFunctionResult(
      functionName: 'hrv_metrics',
      results: {
        'column': column,
        'count': n,
        'meanRR': meanRR,
        'meanHeartRate': meanRR > 0 ? 60000.0 / meanRR : 0.0,
        'sdnn': sdnn,
        'rmssd': rmssd,
        'pnn50': (nn50 / (n - 1)) * 100.0,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// EEG band powers (`eeg_band_powers`) — Welch PSD integrated over the
/// standard clinical bands (delta/theta/alpha/beta/gamma) with relative
/// power and the dominant band.
///
/// Parameters: `column`, `sampleRate` (required), `segmentLength`
/// (default 256). Results: `bandPowers{}`, `relativePowers{}`,
/// `dominantBand`, `totalPower`.
class EegBandPowersFunction implements AnalysisFunction {
  static const Map<String, List<double>> standardBands = {
    'delta': [0.5, 4],
    'theta': [4, 8],
    'alpha': [8, 13],
    'beta': [13, 30],
    'gamma': [30, 45],
  };

  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'eeg_band_powers',
        description: 'EEG band powers over the standard clinical bands '
            '(delta/theta/alpha/beta/gamma)',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'EEG channel column',
          ),
          'sampleRate': AnalysisParameterSchema(
            name: 'sampleRate',
            type: 'number',
            description: 'Sampling rate in Hz (required)',
          ),
          'segmentLength': AnalysisParameterSchema(
            name: 'segmentLength',
            type: 'number',
            defaultValue: 256,
            description: 'Welch segment length',
          ),
        },
        results: const {
          'column': AnalysisResultSchema(
            name: 'column',
            type: 'string',
            description: 'Analyzed column',
          ),
          'bandPowers': AnalysisResultSchema(
            name: 'bandPowers',
            type: 'object',
            description: 'Absolute power per band',
          ),
          'relativePowers': AnalysisResultSchema(
            name: 'relativePowers',
            type: 'object',
            description: 'Power share per band',
          ),
          'dominantBand': AnalysisResultSchema(
            name: 'dominantBand',
            type: 'string',
            description: 'Band with the most power',
          ),
          'totalPower': AnalysisResultSchema(
            name: 'totalPower',
            type: 'number',
            description: 'Summed band power',
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
    if (fs == null || fs <= 0) {
      throw ArgumentError('eeg_band_powers requires a positive sampleRate');
    }
    final x = numericColumn(data, column);
    final segLen =
        nextPow2((parameters['segmentLength'] as num?)?.toInt() ?? 256);
    if (x.length < segLen) {
      throw ArgumentError(
          'eeg_band_powers needs ≥ segmentLength ($segLen) samples');
    }

    // Welch PSD (hann, 50% overlap) — same estimator as `psd_welch`.
    final hop = math.max(1, segLen ~/ 2);
    final w = windowCoefficients('hann', segLen);
    final windowPower = w.map((v) => v * v).reduce((a, b) => a + b);
    final half = segLen ~/ 2;
    final psd = List<double>.filled(half, 0.0);
    var segments = 0;
    for (var start = 0; start + segLen <= x.length; start += hop) {
      final re = List<double>.generate(segLen, (i) => x[start + i] * w[i]);
      final im = List<double>.filled(segLen, 0.0);
      fftInPlace(re, im);
      for (var i = 0; i < half; i++) {
        psd[i] += (re[i] * re[i] + im[i] * im[i]) *
            ((i == 0) ? 1.0 : 2.0) /
            (fs * windowPower);
      }
      segments++;
    }
    for (var i = 0; i < half; i++) {
      psd[i] /= segments;
    }
    final resolution = fs / segLen;

    final bandPowers = <String, double>{};
    for (final entry in standardBands.entries) {
      var p = 0.0;
      for (var i = 0; i < half; i++) {
        final f = i * resolution;
        if (f >= entry.value[0] && f < entry.value[1]) p += psd[i] * resolution;
      }
      bandPowers[entry.key] = p;
    }
    final total = bandPowers.values.fold(0.0, (a, b) => a + b);
    final relative = {
      for (final e in bandPowers.entries)
        e.key: total > 0 ? e.value / total : 0.0,
    };
    final dominant =
        bandPowers.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

    return AnalysisFunctionResult(
      functionName: 'eeg_band_powers',
      results: {
        'column': column,
        'bandPowers': bandPowers,
        'relativePowers': relative,
        'dominantBand': dominant,
        'totalPower': total,
      },
      executionTime: sw.elapsed,
    );
  }
}
