import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Numeric correctness of the DSP builtin family against known-value
/// signals (standard-catalog step of the roadmap).
AnalysisDataSet _signal(List<double> samples) => AnalysisDataSet(
      columns: const [AnalysisColumnInfo(name: 'v', type: 'double')],
      rows: [
        for (final s in samples) <String, dynamic>{'v': s},
      ],
      rowCount: samples.length,
    );

List<double> _sine(double freq, double fs, int n, {double amp = 1.0}) =>
    List.generate(n, (i) => amp * math.sin(2 * math.pi * freq * i / fs));

void main() {
  group('fft', () {
    test('recovers the dominant frequency of a pure sine', () async {
      const fs = 1000.0;
      final data = _signal(_sine(50, fs, 1024));
      final r = await FftFunction().execute({'sampleRate': fs}, data);
      expect(r.results['dominantFrequency'],
          closeTo(50.0, (r.results['resolution'] as double) + 1e-9));
    });

    test('amplitude normalization: A-amplitude sine reads ≈ A', () async {
      const fs = 1000.0;
      final data = _signal(_sine(125, fs, 1024, amp: 3.0)); // on-bin freq
      final r = await FftFunction()
          .execute({'sampleRate': fs, 'window': 'rect'}, data);
      final mags = (r.results['magnitudes'] as List).cast<double>();
      final freqs = (r.results['frequencies'] as List).cast<double>();
      final idx = freqs.indexWhere((f) => (f - 125.0).abs() < 1e-9);
      expect(mags[idx], closeTo(3.0, 0.05));
    });
  });

  group('psd_welch', () {
    test('band powers separate two sines into their bands', () async {
      const fs = 256.0;
      final n = 2048;
      final s1 = _sine(10, fs, n, amp: 2.0);
      final s2 = _sine(40, fs, n, amp: 1.0);
      final data =
          _signal([for (var i = 0; i < n; i++) s1[i] + s2[i]]);
      final r = await PsdWelchFunction().execute({
        'sampleRate': fs,
        'segmentLength': 256,
        'bands': [
          {'name': 'low', 'low': 5, 'high': 15},
          {'name': 'mid', 'low': 35, 'high': 45},
          {'name': 'empty', 'low': 80, 'high': 120},
        ],
      }, data);
      final bands = (r.results['bandPowers'] as Map).cast<String, double>();
      // 2× amplitude → 4× power.
      expect(bands['low']! / bands['mid']!, closeTo(4.0, 0.5));
      expect(bands['empty']!, lessThan(bands['mid']! * 0.01));
    });
  });

  group('digital_filter', () {
    test('lowpass passes below-cutoff and attenuates above-cutoff', () async {
      const fs = 1000.0;
      final low = _sine(10, fs, 2000);
      final high = _sine(200, fs, 2000);
      final f = DigitalFilterFunction();

      double tailAmplitude(List<double> xs) {
        final tail = xs.sublist(xs.length ~/ 2);
        return tail.map((v) => v.abs()).reduce(math.max);
      }

      final passed = await f.execute(
          {'type': 'lowpass', 'sampleRate': fs, 'cutoff': 50.0},
          _signal(low));
      final blocked = await f.execute(
          {'type': 'lowpass', 'sampleRate': fs, 'cutoff': 50.0},
          _signal(high));
      expect(
          tailAmplitude((passed.results['values'] as List).cast<double>()),
          closeTo(1.0, 0.1));
      expect(
          tailAmplitude((blocked.results['values'] as List).cast<double>()),
          lessThan(0.15));
    });

    test('moving_average smooths a constant to itself', () async {
      final r = await DigitalFilterFunction().execute(
          {'type': 'moving_average', 'taps': 4},
          _signal(List.filled(32, 7.0)));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.last, closeTo(7.0, 1e-12));
    });
  });

  group('peak_detect', () {
    test('finds synthetic peaks with distance + prominence gates', () async {
      // Peaks at 5, 15, 25 with heights 3, 5, 4 over a zero floor.
      final x = List<double>.filled(30, 0.0);
      x[5] = 3.0;
      x[15] = 5.0;
      x[25] = 4.0;
      x[16] = 1.0; // shoulder that must not count (below neighbors gate)
      final r = await PeakDetectFunction()
          .execute({'minProminence': 2.0, 'minDistance': 5}, _signal(x));
      expect(r.results['indices'], [5, 15, 25]);
      expect(r.results['count'], 3);
      expect(r.results['intervals'], [10, 10]);
    });
  });

  group('zero_crossing', () {
    test('estimates a sine frequency from rising crossings', () async {
      const fs = 1000.0;
      final r = await ZeroCrossingFunction().execute(
          {'sampleRate': fs, 'direction': 'rising'},
          _signal(_sine(20, fs, 1000)));
      expect(r.results['estimatedFrequency'], closeTo(20.0, 0.5));
    });
  });

  group('resample', () {
    test('linear doubling preserves a ramp', () async {
      final ramp = [for (var i = 0; i < 10; i++) i.toDouble()];
      final r = await ResampleFunction().execute(
          {'mode': 'linear', 'sourceRate': 10, 'targetRate': 20},
          _signal(ramp));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.length, 20);
      expect(out[2], closeTo(1.0, 1e-9)); // t=0.1s → value 1
      expect(out[3], closeTo(1.5, 1e-9));
    });

    test('decimate reduces length by factor', () async {
      final r = await ResampleFunction().execute(
          {'mode': 'decimate', 'factor': 4, 'sourceRate': 100},
          _signal(List.generate(100, (i) => i.toDouble())));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.length, 25);
      expect(r.results['outputRate'], 25.0);
    });
  });

  group('envelope', () {
    test('RMS envelope of a sine settles near A/√2', () async {
      final r = await EnvelopeFunction().execute(
          {'mode': 'rms', 'window': 100},
          _signal(_sine(50, 1000, 1000, amp: 2.0)));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.last, closeTo(2.0 / math.sqrt2, 0.05));
    });
  });
}
