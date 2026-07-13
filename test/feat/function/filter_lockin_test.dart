import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Known-value tests for the filter completions (notch · Butterworth
/// order cascade · median) and the software lock-in amplifier.
AnalysisDataSet _signal(List<double> samples) => AnalysisDataSet(
      columns: const [AnalysisColumnInfo(name: 'v', type: 'double')],
      rows: [
        for (final s in samples) <String, dynamic>{'v': s},
      ],
      rowCount: samples.length,
    );

List<double> _sine(double freq, double fs, int n,
        {double amp = 1.0, double phase = 0.0}) =>
    List.generate(
        n, (i) => amp * math.sin(2 * math.pi * freq * i / fs + phase));

/// Peak amplitude of the settled second half of a series.
double _tailAmp(List<double> xs) =>
    xs.sublist(xs.length ~/ 2).map((v) => v.abs()).reduce(math.max);

void main() {
  const fs = 1000.0;
  final filter = DigitalFilterFunction();

  group('notch', () {
    test('kills the center tone, passes a neighboring tone', () async {
      final killed = await filter.execute(
          {'type': 'notch', 'sampleRate': fs, 'cutoff': 60.0, 'q': 5.0},
          _signal(_sine(60, fs, 4000)));
      final passed = await filter.execute(
          {'type': 'notch', 'sampleRate': fs, 'cutoff': 60.0, 'q': 5.0},
          _signal(_sine(120, fs, 4000)));
      expect(_tailAmp((killed.results['values'] as List).cast<double>()),
          lessThan(0.05));
      expect(_tailAmp((passed.results['values'] as List).cast<double>()),
          closeTo(1.0, 0.1));
    });
  });

  group('butterworth order cascade', () {
    test('order 6 attenuates the stopband far more than order 2', () async {
      Future<double> stopband(int order) async {
        final r = await filter.execute({
          'type': 'lowpass',
          'sampleRate': fs,
          'cutoff': 50.0,
          'order': order,
        }, _signal(_sine(150, fs, 4000)));
        return _tailAmp((r.results['values'] as List).cast<double>());
      }

      final o2 = await stopband(2);
      final o6 = await stopband(6);
      expect(o6, lessThan(o2 / 10),
          reason: 'higher order must roll off much faster');
    });

    test('order 6 passband stays flat', () async {
      final r = await filter.execute({
        'type': 'lowpass',
        'sampleRate': fs,
        'cutoff': 50.0,
        'order': 6,
      }, _signal(_sine(5, fs, 4000)));
      expect(_tailAmp((r.results['values'] as List).cast<double>()),
          closeTo(1.0, 0.1));
    });
  });

  group('median filter', () {
    test('removes impulses, preserves the level', () async {
      final x = List<double>.filled(200, 10.0);
      x[50] = 500.0;
      x[120] = -300.0;
      final r =
          await filter.execute({'type': 'median', 'taps': 5}, _signal(x));
      final out = (r.results['values'] as List).cast<double>();
      expect(out[50], 10.0);
      expect(out[120], 10.0);
      expect(out[10], 10.0);
    });
  });

  group('lockin', () {
    test('recovers amplitude and phase of a buried weak tone', () async {
      const fRef = 80.0;
      const amp = 0.05; // weak target
      const phase = 0.7;
      final rng = math.Random(17);
      const n = 20000;
      final x = List<double>.generate(n, (i) {
        final t = i / fs;
        return amp * math.sin(2 * math.pi * fRef * t + phase) +
            2.0 * math.sin(2 * math.pi * 33 * t) + // 40× interferer
            (rng.nextDouble() - 0.5) * 0.5; // broadband noise
      });
      final r = await LockinFunction().execute(
          {'sampleRate': fs, 'referenceFrequency': fRef}, _signal(x));
      expect(r.results['amplitude'], closeTo(amp, amp * 0.15));
      expect(r.results['phase'], closeTo(phase, 0.1));
      expect((r.results['amplitudeSeries'] as List).length, n);
    });

    test('guards: missing reference and above-Nyquist throw', () {
      expect(
          () => LockinFunction()
              .execute({'sampleRate': fs}, _signal(_sine(10, fs, 64))),
          throwsArgumentError);
      expect(
          () => LockinFunction().execute(
              {'sampleRate': fs, 'referenceFrequency': 600.0},
              _signal(_sine(10, fs, 64))),
          throwsArgumentError);
    });
  });
}
