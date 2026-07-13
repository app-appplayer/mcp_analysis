import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// STFT spectrogram (`spectrogram`) — the time–frequency workhorse
/// (EEG epochs, machinery run-up, speech).
///
/// Parameters: `column`, `sampleRate` (required), `segmentLength`
/// (power of two, default 256), `overlap` (0..0.9, default 0.5), `window`.
/// Results: `times[]` (segment centers, s), `frequencies[]`,
/// `magnitudes[][]` (time-major), plus sizes.
class SpectrogramFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'spectrogram',
        description: 'STFT magnitude spectrogram (time–frequency analysis)',
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
            description: 'STFT segment length (rounded up to a power of two)',
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
      throw ArgumentError('spectrogram requires a positive sampleRate (Hz)');
    }
    final x = numericColumn(data, column);
    final segLen =
        nextPow2((parameters['segmentLength'] as num?)?.toInt() ?? 256);
    if (x.length < segLen) {
      throw ArgumentError(
          'spectrogram needs ≥ segmentLength ($segLen) samples');
    }
    final overlap =
        ((parameters['overlap'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 0.9);
    final hop = math.max(1, (segLen * (1 - overlap)).round());
    final w = windowCoefficients(
        parameters['window'] as String? ?? 'hann', segLen);
    final gain = w.reduce((a, b) => a + b) / segLen;

    final half = segLen ~/ 2;
    final times = <double>[];
    final mags = <List<double>>[];
    for (var start = 0; start + segLen <= x.length; start += hop) {
      final re = List<double>.generate(segLen, (i) => x[start + i] * w[i]);
      final im = List<double>.filled(segLen, 0.0);
      fftInPlace(re, im);
      times.add((start + segLen / 2) / fs);
      mags.add(List<double>.generate(half, (i) {
        final m = math.sqrt(re[i] * re[i] + im[i] * im[i]);
        return m * ((i == 0 ? 1.0 : 2.0) / (segLen * gain));
      }));
    }

    return AnalysisFunctionResult(
      functionName: 'spectrogram',
      results: {
        'column': column,
        'times': times,
        'frequencies':
            List<double>.generate(half, (i) => i * fs / segLen),
        'magnitudes': mags,
        'segmentCount': times.length,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Real cepstrum (`cepstrum`) — IFFT of log|FFT|; the bearing/gear-mesh
/// periodicity and echo detector.
///
/// Parameters: `column`, `sampleRate` (required). Results: `quefrencies[]`
/// (s), `cepstrum[]`, `peakQuefrency` (dominant repetition period, s).
class CepstrumFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'cepstrum',
        description:
            'Real cepstrum — repetition-period / echo detection',
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
      throw ArgumentError('cepstrum requires a positive sampleRate (Hz)');
    }
    final x = numericColumn(data, column);
    if (x.length < 8) throw ArgumentError('cepstrum requires ≥ 8 samples');

    final n = nextPow2(x.length);
    final re = List<double>.filled(n, 0.0);
    final im = List<double>.filled(n, 0.0);
    for (var i = 0; i < x.length; i++) {
      re[i] = x[i];
    }
    fftInPlace(re, im);
    // log magnitude spectrum (floored to avoid log 0).
    for (var i = 0; i < n; i++) {
      final m = math.sqrt(re[i] * re[i] + im[i] * im[i]);
      re[i] = math.log(math.max(m, 1e-300));
      im[i] = 0.0;
    }
    // Inverse FFT via conjugation trick: ifft(x) = conj(fft(conj(x)))/n —
    // input is real so plain forward FFT + /n on the real part suffices for
    // the real cepstrum's symmetric spectrum.
    fftInPlace(re, im);
    final half = n ~/ 2;
    final ceps = [for (var i = 0; i < half; i++) re[i] / n];
    final quefs = [for (var i = 0; i < half; i++) i / fs];

    // Dominant repetition period: skip the low-quefrency envelope region.
    var peakIdx = 0;
    var peakVal = double.negativeInfinity;
    final skip = math.max(2, (fs / (fs / 2)).round() * 2);
    for (var i = skip; i < half; i++) {
      if (ceps[i] > peakVal) {
        peakVal = ceps[i];
        peakIdx = i;
      }
    }

    return AnalysisFunctionResult(
      functionName: 'cepstrum',
      results: {
        'column': column,
        'quefrencies': quefs,
        'cepstrum': ceps,
        'peakQuefrency': quefs[peakIdx],
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Harmonic analysis (`harmonics`) — fundamental + harmonic amplitudes and
/// THD (the power-quality staple).
///
/// Parameters: `column`, `sampleRate` (required), `fundamental` (Hz;
/// auto-detected from the spectrum when omitted), `harmonicCount`
/// (default 10). Results: `fundamental`, `harmonics[]`
/// (`{order, frequency, amplitude, phase}`), `thd` (ratio), `thdPercent`.
class HarmonicsFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'harmonics',
        description:
            'Fundamental/harmonic amplitudes + THD (total harmonic '
            'distortion)',
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
          'fundamental': AnalysisParameterSchema(
            name: 'fundamental',
            type: 'number',
            description: 'Fundamental frequency in Hz (auto when omitted)',
          ),
          'harmonicCount': AnalysisParameterSchema(
            name: 'harmonicCount',
            type: 'number',
            defaultValue: 10,
            description: 'Number of harmonics to report',
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
      throw ArgumentError('harmonics requires a positive sampleRate (Hz)');
    }
    final x = numericColumn(data, column);
    if (x.length < 16) throw ArgumentError('harmonics requires ≥ 16 samples');
    final count = math.max(1, (parameters['harmonicCount'] as num?)?.toInt() ?? 10);

    final n = nextPow2(x.length);
    final re = List<double>.filled(n, 0.0);
    final im = List<double>.filled(n, 0.0);
    // Rectangular window keeps harmonic amplitude ratios exact for
    // coherent sampling; spectral leakage is the caller's concern.
    for (var i = 0; i < x.length; i++) {
      re[i] = x[i];
    }
    fftInPlace(re, im);
    final half = n ~/ 2;
    final resolution = fs / n;
    double magAt(int bin) =>
        math.sqrt(re[bin] * re[bin] + im[bin] * im[bin]) *
        (bin == 0 ? 1.0 : 2.0) /
        x.length;

    var f0 = (parameters['fundamental'] as num?)?.toDouble();
    if (f0 == null) {
      var best = 1;
      for (var i = 2; i < half; i++) {
        if (magAt(i) > magAt(best)) best = i;
      }
      f0 = best * resolution;
    }

    final harmonics = <Map<String, dynamic>>[];
    var fundamentalAmp = 0.0;
    var harmonicPowerSum = 0.0;
    for (var order = 1; order <= count; order++) {
      final target = f0 * order;
      if (target >= fs / 2) break;
      // Pick the strongest bin within ±1 of the ideal location.
      final ideal = (target / resolution).round();
      var bin = ideal;
      for (final cand in [ideal - 1, ideal + 1]) {
        if (cand > 0 && cand < half && magAt(cand) > magAt(bin)) bin = cand;
      }
      final amp = magAt(bin);
      harmonics.add({
        'order': order,
        'frequency': bin * resolution,
        'amplitude': amp,
        'phase': math.atan2(im[bin], re[bin]),
      });
      if (order == 1) {
        fundamentalAmp = amp;
      } else {
        harmonicPowerSum += amp * amp;
      }
    }
    final thd =
        fundamentalAmp > 0 ? math.sqrt(harmonicPowerSum) / fundamentalAmp : 0.0;

    return AnalysisFunctionResult(
      functionName: 'harmonics',
      results: {
        'column': column,
        'fundamental': f0,
        'harmonics': harmonics,
        'thd': thd,
        'thdPercent': thd * 100,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Cross-spectral analysis (`cross_psd`) — cross-PSD, coherence and the H1
/// FRF estimate between two channels (modal analysis / system
/// identification: input column = excitation, output column = response).
///
/// Parameters: `columns` ([input, output]), `sampleRate` (required),
/// `segmentLength` (default 256), `overlap` (default 0.5), `window`.
/// Results: `frequencies[]`, `coherence[]` (0..1), `frfMagnitude[]`,
/// `frfPhase[]`, `peakCoherentFrequency`.
class CrossPsdFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'cross_psd',
        description:
            'Cross-PSD, coherence and H1 FRF between two channels',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Exactly two columns [input, output]',
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
            description: 'Welch segment length (power of two)',
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
            description: 'Window function',
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
    final cols = (parameters['columns'] as List?)?.cast<String>();
    if (cols == null || cols.length != 2) {
      throw ArgumentError('cross_psd requires columns: [input, output]');
    }
    final fs = (parameters['sampleRate'] as num?)?.toDouble();
    if (fs == null || fs <= 0) {
      throw ArgumentError('cross_psd requires a positive sampleRate (Hz)');
    }
    final a = numericColumn(data, cols[0]);
    final b = numericColumn(data, cols[1]);
    final n = math.min(a.length, b.length);
    final segLen =
        nextPow2((parameters['segmentLength'] as num?)?.toInt() ?? 256);
    if (n < segLen) {
      throw ArgumentError('cross_psd needs ≥ segmentLength ($segLen) samples');
    }
    final overlap =
        ((parameters['overlap'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 0.9);
    final hop = math.max(1, (segLen * (1 - overlap)).round());
    final w = windowCoefficients(
        parameters['window'] as String? ?? 'hann', segLen);

    final half = segLen ~/ 2;
    final saa = List<double>.filled(half, 0.0);
    final sbb = List<double>.filled(half, 0.0);
    final sabRe = List<double>.filled(half, 0.0);
    final sabIm = List<double>.filled(half, 0.0);
    var segments = 0;
    for (var start = 0; start + segLen <= n; start += hop) {
      final ar = List<double>.generate(segLen, (i) => a[start + i] * w[i]);
      final ai = List<double>.filled(segLen, 0.0);
      final br = List<double>.generate(segLen, (i) => b[start + i] * w[i]);
      final bi = List<double>.filled(segLen, 0.0);
      fftInPlace(ar, ai);
      fftInPlace(br, bi);
      for (var i = 0; i < half; i++) {
        saa[i] += ar[i] * ar[i] + ai[i] * ai[i];
        sbb[i] += br[i] * br[i] + bi[i] * bi[i];
        // Sab = conj(A)·B
        sabRe[i] += ar[i] * br[i] + ai[i] * bi[i];
        sabIm[i] += ar[i] * bi[i] - ai[i] * br[i];
      }
      segments++;
    }

    final coherence = List<double>.filled(half, 0.0);
    final frfMag = List<double>.filled(half, 0.0);
    final frfPhase = List<double>.filled(half, 0.0);
    for (var i = 0; i < half; i++) {
      final sabSq = sabRe[i] * sabRe[i] + sabIm[i] * sabIm[i];
      coherence[i] =
          (saa[i] > 0 && sbb[i] > 0) ? (sabSq / (saa[i] * sbb[i])) : 0.0;
      frfMag[i] = saa[i] > 0 ? math.sqrt(sabSq) / saa[i] : 0.0; // |H1|
      frfPhase[i] = math.atan2(sabIm[i], sabRe[i]);
    }

    var peakIdx = 1;
    for (var i = 2; i < half; i++) {
      if (coherence[i] > coherence[peakIdx]) peakIdx = i;
    }

    return AnalysisFunctionResult(
      functionName: 'cross_psd',
      results: {
        'columns': cols,
        'frequencies':
            List<double>.generate(half, (i) => i * fs / segLen),
        'coherence': coherence,
        'frfMagnitude': frfMag,
        'frfPhase': frfPhase,
        'peakCoherentFrequency': peakIdx * fs / segLen,
        'segments': segments,
      },
      executionTime: sw.elapsed,
    );
  }
}
