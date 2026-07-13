import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Single-sided FFT magnitude spectrum (`fft`).
///
/// Parameters: `column`, `sampleRate` (Hz, required), `window`
/// (hann|hamming|rect, default hann). Input is zero-padded to the next power
/// of two. Results: `frequencies[]`, `magnitudes[]` (amplitude-normalized:
/// a full-scale sine of amplitude A reads ≈ A), `dominantFrequency`,
/// `resolution` (Hz/bin).
class FftFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'fft',
        description:
            'Single-sided FFT magnitude spectrum (radix-2, windowed)',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the waveform samples',
          ),
          'sampleRate': AnalysisParameterSchema(
            name: 'sampleRate',
            type: 'number',
            description: 'Sampling rate in Hz (required)',
          ),
          'window': AnalysisParameterSchema(
            name: 'window',
            type: 'string',
            defaultValue: 'hann',
            description: 'Window function: hann, hamming, rect',
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
      throw ArgumentError('fft requires a positive sampleRate (Hz)');
    }
    final signal = numericColumn(data, column);
    if (signal.length < 2) {
      throw ArgumentError('fft requires at least 2 samples');
    }

    final windowName = parameters['window'] as String? ?? 'hann';
    final w = windowCoefficients(windowName, signal.length);
    // Coherent gain compensation keeps a sine's magnitude ≈ its amplitude.
    final gain = w.reduce((a, b) => a + b) / signal.length;

    final n = nextPow2(signal.length);
    final re = List<double>.filled(n, 0.0);
    final im = List<double>.filled(n, 0.0);
    for (var i = 0; i < signal.length; i++) {
      re[i] = signal[i] * w[i];
    }
    fftInPlace(re, im);

    final half = n ~/ 2;
    final resolution = fs / n;
    final freqs = List<double>.generate(half, (i) => i * resolution);
    final mags = List<double>.generate(half, (i) {
      final m = math.sqrt(re[i] * re[i] + im[i] * im[i]);
      // Single-sided amplitude: ×2 for non-DC bins, normalized by the
      // windowed sample count.
      final scale = (i == 0 ? 1.0 : 2.0) / (signal.length * gain);
      return m * scale;
    });

    // Phase spectrum (radians) — phasor/harmonic-phase consumers.
    final phases =
        List<double>.generate(half, (i) => math.atan2(im[i], re[i]));

    var domIdx = 1 <= half - 1 ? 1 : 0;
    for (var i = 1; i < half; i++) {
      if (mags[i] > mags[domIdx]) domIdx = i;
    }

    return AnalysisFunctionResult(
      functionName: 'fft',
      results: {
        'column': column,
        'frequencies': freqs,
        'magnitudes': mags,
        'phases': phases,
        'dominantFrequency': freqs.isEmpty ? 0.0 : freqs[domIdx],
        'resolution': resolution,
        'sampleCount': signal.length,
        'fftSize': n,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Welch power spectral density estimate (`psd_welch`) with optional band
/// power integration — the EEG/vibration workhorse.
///
/// Parameters: `column`, `sampleRate` (required), `segmentLength` (power of
/// two, default 256), `overlap` (0..0.9, default 0.5), `window`, `bands`
/// (`[{name, low, high}]` in Hz → integrated band power per entry).
class PsdWelchFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'psd_welch',
        description:
            'Welch power spectral density estimate with optional band powers',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column holding the waveform samples',
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
            description: 'Welch segment length (rounded up to a power of two)',
          ),
          'overlap': AnalysisParameterSchema(
            name: 'overlap',
            type: 'number',
            defaultValue: 0.5,
            description: 'Segment overlap fraction (0..0.9)',
          ),
          'window': AnalysisParameterSchema(
            name: 'window',
            type: 'string',
            defaultValue: 'hann',
            description: 'Window function: hann, hamming, rect',
          ),
          'bands': AnalysisParameterSchema(
            name: 'bands',
            type: 'array',
            description:
                'Optional [{name, low, high}] Hz ranges → integrated power',
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
      throw ArgumentError('psd_welch requires a positive sampleRate (Hz)');
    }
    final signal = numericColumn(data, column);
    final segLen =
        nextPow2(((parameters['segmentLength'] as num?)?.toInt() ?? 256));
    if (signal.length < segLen) {
      throw ArgumentError(
          'psd_welch needs ≥ segmentLength ($segLen) samples, '
          'got ${signal.length}');
    }
    final overlap =
        ((parameters['overlap'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 0.9);
    final hop = math.max(1, (segLen * (1 - overlap)).round());
    final windowName = parameters['window'] as String? ?? 'hann';
    final w = windowCoefficients(windowName, segLen);
    final windowPower =
        w.map((v) => v * v).reduce((a, b) => a + b); // Σw² for normalization

    final half = segLen ~/ 2;
    final acc = List<double>.filled(half, 0.0);
    var segments = 0;
    for (var start = 0; start + segLen <= signal.length; start += hop) {
      final re = List<double>.generate(segLen, (i) => signal[start + i] * w[i]);
      final im = List<double>.filled(segLen, 0.0);
      fftInPlace(re, im);
      for (var i = 0; i < half; i++) {
        final p = re[i] * re[i] + im[i] * im[i];
        // One-sided PSD normalization (×2 except DC), per Welch.
        acc[i] += p * ((i == 0) ? 1.0 : 2.0) / (fs * windowPower);
      }
      segments++;
    }
    for (var i = 0; i < half; i++) {
      acc[i] /= segments;
    }
    final resolution = fs / segLen;
    final freqs = List<double>.generate(half, (i) => i * resolution);

    final bandsParam = parameters['bands'] as List?;
    final bandPowers = <String, double>{};
    if (bandsParam != null) {
      for (final b in bandsParam) {
        final m = (b as Map).cast<String, dynamic>();
        final low = (m['low'] as num).toDouble();
        final high = (m['high'] as num).toDouble();
        var power = 0.0;
        for (var i = 0; i < half; i++) {
          if (freqs[i] >= low && freqs[i] < high) power += acc[i] * resolution;
        }
        bandPowers[m['name'] as String? ?? '$low-$high'] = power;
      }
    }

    return AnalysisFunctionResult(
      functionName: 'psd_welch',
      results: {
        'column': column,
        'frequencies': freqs,
        'psd': acc,
        'resolution': resolution,
        'segments': segments,
        if (bandPowers.isNotEmpty) 'bandPowers': bandPowers,
      },
      executionTime: sw.elapsed,
    );
  }
}
