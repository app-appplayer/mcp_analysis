import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Known-value checks for the domain-coverage batch: advanced spectrum
/// (spectrogram/cepstrum/harmonics/cross-PSD), multivariate (PCA,
/// Lomb–Scargle), higher moments, savgol derivative, and the domain tier 1
/// functions (vibration/HRV/EEG).
AnalysisDataSet _cols(Map<String, List<double>> series) {
  final names = series.keys.toList();
  final n = series.values.map((v) => v.length).reduce(math.min);
  return AnalysisDataSet(
    columns: [
      for (final name in names) AnalysisColumnInfo(name: name, type: 'double'),
    ],
    rows: [
      for (var i = 0; i < n; i++)
        <String, dynamic>{for (final name in names) name: series[name]![i]},
    ],
    rowCount: n,
  );
}

List<double> _sine(double f, double fs, int n, {double amp = 1.0}) =>
    List.generate(n, (i) => amp * math.sin(2 * math.pi * f * i / fs));

void main() {
  group('moments (descriptive_stats)', () {
    test('symmetric data → skewness ≈ 0, uniform kurtosis ≈ 1.8', () async {
      final x = [for (var i = 0; i < 10000; i++) (i % 1000) / 1000.0];
      final r = await DescriptiveStatsFunction().execute({
        'columns': ['v']
      }, _cols({'v': x}));
      final stats = (r.results['v'] as Map);
      expect((stats['skewness'] as double).abs(), lessThan(0.05));
      expect(stats['kurtosis'], closeTo(1.8, 0.1)); // uniform distribution
    });
  });

  group('savgol derivative', () {
    test('1st derivative of a linear ramp is its slope', () async {
      final x = [for (var i = 0; i < 40; i++) 2.5 * i + 1];
      final r = await SmoothingFunction().execute(
          {'method': 'savgol', 'window': 7, 'derivative': 1}, _cols({'v': x}));
      final out = (r.results['values'] as List).cast<double>();
      for (var i = 5; i < 35; i++) {
        expect(out[i], closeTo(2.5, 1e-6));
      }
    });
  });

  group('spectrogram', () {
    test('tracks a frequency step over time', () async {
      const fs = 1000.0;
      final x = [..._sine(50, fs, 2048), ..._sine(150, fs, 2048)];
      final r = await SpectrogramFunction()
          .execute({'sampleRate': fs, 'segmentLength': 256}, _cols({'v': x}));
      final freqs = (r.results['frequencies'] as List).cast<double>();
      final mags = (r.results['magnitudes'] as List);
      int domIdx(List<dynamic> m) {
        var best = 1;
        for (var i = 2; i < m.length; i++) {
          if ((m[i] as double) > (m[best] as double)) best = i;
        }
        return best;
      }

      final early = freqs[domIdx(mags.first as List)];
      final late = freqs[domIdx(mags.last as List)];
      expect(early, closeTo(50.0, 5.0));
      expect(late, closeTo(150.0, 5.0));
    });
  });

  group('harmonics / THD', () {
    test('recovers a known 10% third-harmonic THD', () async {
      const fs = 6400.0;
      const f0 = 50.0;
      const n = 4096; // ≥ several cycles
      final x = List.generate(n, (i) {
        final t = i / fs;
        return math.sin(2 * math.pi * f0 * t) +
            0.1 * math.sin(2 * math.pi * 3 * f0 * t);
      });
      final r = await HarmonicsFunction()
          .execute({'sampleRate': fs, 'fundamental': f0}, _cols({'v': x}));
      expect(r.results['thd'], closeTo(0.10, 0.015));
    });
  });

  group('cross_psd', () {
    test('coherent linear channel → coherence ≈ 1 at signal band', () async {
      const fs = 1000.0;
      final rng = math.Random(2);
      final input = [
        for (var i = 0; i < 4096; i++) rng.nextDouble() - 0.5,
      ];
      final output = [for (final v in input) 2.0 * v]; // H = 2, no noise
      final r = await CrossPsdFunction().execute({
        'columns': ['in', 'out'],
        'sampleRate': fs,
        'segmentLength': 256
      }, _cols({'in': input, 'out': output}));
      final coh = (r.results['coherence'] as List).cast<double>();
      final frf = (r.results['frfMagnitude'] as List).cast<double>();
      // Away from DC, coherence ~1 and |H| ~2.
      expect(coh[10], closeTo(1.0, 0.05));
      expect(frf[10], closeTo(2.0, 0.1));
    });
  });

  group('pca', () {
    test('a 1-D latent structure loads onto the first component', () async {
      final rng = math.Random(7);
      final t = [for (var i = 0; i < 500; i++) rng.nextDouble() * 10];
      final r = await PcaFunction().execute(
          {},
          _cols({
            'a': [for (final v in t) v + (rng.nextDouble() - 0.5) * 0.01],
            'b': [for (final v in t) 2 * v + (rng.nextDouble() - 0.5) * 0.01],
            'c': [for (final v in t) -v + (rng.nextDouble() - 0.5) * 0.01],
          }));
      final ratio =
          (r.results['explainedVarianceRatio'] as List).cast<double>();
      expect(ratio.first, greaterThan(0.99),
          reason: 'one latent factor should dominate');
    });
  });

  group('lomb_scargle', () {
    test('finds the period in UNEVENLY sampled data', () async {
      final rng = math.Random(11);
      const period = 3.7;
      final times = <double>[];
      var t = 0.0;
      while (t < 200) {
        times.add(t);
        t += 0.2 + rng.nextDouble() * 0.8; // irregular sampling
      }
      final values = [
        for (final tt in times) math.sin(2 * math.pi * tt / period),
      ];
      final r = await LombScargleFunction().execute({
        'columns': ['t', 'v'],
        'frequencySteps': 2000
      }, _cols({'t': times, 'v': values}));
      expect(r.results['bestPeriod'], closeTo(period, 0.05));
    });
  });

  group('domain tier 1', () {
    test('vibration_indicators — RMS zone + impulsive kurtosis', () async {
      // Sine of amplitude 4 mm/s → RMS ≈ 2.83 → class 2 zone C (2.8–7.1).
      final x = _sine(50, 1000, 2000, amp: 4.0);
      final r = await VibrationIndicatorsFunction()
          .execute({'machineClass': 2}, _cols({'v': x}));
      expect(r.results['rms'], closeTo(4.0 / math.sqrt2, 0.05));
      expect(r.results['isoZone'], 'C');
      expect(r.results['crestFactor'], closeTo(math.sqrt2, 0.05));
      // Sine kurtosis = 1.5 (sub-Gaussian).
      expect(r.results['kurtosis'], closeTo(1.5, 0.1));
    });

    test('hrv_metrics — known RR set', () async {
      final rr = [800.0, 810.0, 790.0, 870.0, 800.0, 805.0];
      final r = await HrvMetricsFunction().execute({}, _cols({'rr': rr}));
      expect(r.results['meanRR'], closeTo(812.5, 0.1));
      expect(r.results['meanHeartRate'], closeTo(60000 / 812.5, 0.1));
      // diffs: 10, -20, 80, -70, 5 → |d|>50: 2 of 5 → 40%
      expect(r.results['pnn50'], closeTo(40.0, 0.1));
    });

    test('eeg_band_powers — alpha-dominant synthetic EEG', () async {
      const fs = 256.0;
      const n = 4096;
      final rng = math.Random(13);
      final x = List.generate(n, (i) {
        final t = i / fs;
        return 10 * math.sin(2 * math.pi * 10 * t) + // alpha 10 Hz
            2 * math.sin(2 * math.pi * 20 * t) + // beta 20 Hz
            (rng.nextDouble() - 0.5);
      });
      final r = await EegBandPowersFunction()
          .execute({'sampleRate': fs}, _cols({'v': x}));
      expect(r.results['dominantBand'], 'alpha');
      final rel = (r.results['relativePowers'] as Map).cast<String, double>();
      expect(rel['alpha']!, greaterThan(0.7));
    });
  });
}
