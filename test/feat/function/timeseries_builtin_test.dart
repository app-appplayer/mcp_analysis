import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

AnalysisDataSet _series(List<double> samples, {String name = 'v'}) =>
    AnalysisDataSet(
      columns: [AnalysisColumnInfo(name: name, type: 'double')],
      rows: [
        for (final s in samples) <String, dynamic>{name: s},
      ],
      rowCount: samples.length,
    );

void main() {
  group('acf', () {
    test('detects the period of a clean periodic signal', () async {
      final x = [
        for (var i = 0; i < 240; i++) math.sin(2 * math.pi * i / 12),
      ];
      final r = await AcfFunction().execute({}, _series(x));
      expect(r.results['detectedPeriod'], 12);
      expect(r.results['periodConfidence'], greaterThan(0.9));
    });

    test('reports no period for white noise', () async {
      final rng = math.Random(3);
      final x = [for (var i = 0; i < 400; i++) rng.nextDouble() - 0.5];
      final r = await AcfFunction().execute({}, _series(x));
      expect(r.results['periodConfidence'], lessThan(0.3));
    });
  });

  group('cross_correlation', () {
    test('recovers a known lag between two series', () async {
      const lag = 7;
      final rng = math.Random(5);
      final a = [for (var i = 0; i < 300; i++) rng.nextDouble() - 0.5];
      // b[i] = a[i - lag]  → best positive-direction match at +... (b lags a)
      final b = [
        for (var i = 0; i < 300; i++) i - lag >= 0 ? a[i - lag] : 0.0,
      ];
      final data = AnalysisDataSet(
        columns: const [
          AnalysisColumnInfo(name: 'a', type: 'double'),
          AnalysisColumnInfo(name: 'b', type: 'double'),
        ],
        rows: [
          for (var i = 0; i < 300; i++)
            <String, dynamic>{'a': a[i], 'b': b[i]},
        ],
        rowCount: 300,
      );
      final r = await CrossCorrelationFunction()
          .execute({'columns': ['a', 'b'], 'maxLag': 20}, data);
      expect((r.results['bestLag'] as int).abs(), lag);
      expect((r.results['bestCorrelation'] as double).abs(),
          greaterThan(0.9));
    });
  });

  group('changepoint_cusum', () {
    test('flags a mean shift and stays quiet on a stable series', () async {
      final rng = math.Random(9);
      final stable = [
        for (var i = 0; i < 200; i++) 10 + (rng.nextDouble() - 0.5),
      ];
      final shifted = [
        ...stable.sublist(0, 100),
        for (var i = 0; i < 100; i++) 20 + (rng.nextDouble() - 0.5),
      ];

      // ARL0 at the h=5/k=0.5 default is ~930 samples, so a 200-sample
      // noise run can legitimately alarm; the quiet assertion pins a higher
      // threshold where false alarms are effectively impossible.
      final quiet = await ChangepointCusumFunction()
          .execute({'threshold': 10}, _series(stable));
      expect(quiet.results['count'], 0);

      final r = await ChangepointCusumFunction()
          .execute({}, _series(shifted));
      final cps = (r.results['changepoints'] as List).cast<int>();
      expect(cps, isNotEmpty);
      expect(cps.first, inInclusiveRange(98, 110),
          reason: 'shift at 100 should be flagged promptly');
    });
  });

  group('holt_winters', () {
    test('extrapolates a linear trend', () async {
      final x = [for (var i = 0; i < 60; i++) 5.0 + 2.0 * i];
      final r = await HoltWintersFunction()
          .execute({'horizon': 5, 'alpha': 0.8, 'beta': 0.8}, _series(x));
      final f = (r.results['forecast'] as List).cast<double>();
      // Next values continue 5 + 2i: at i=60 → 125.
      expect(f.first, closeTo(125.0, 2.0));
      expect(f.last, closeTo(133.0, 3.0));
    });
  });

  group('anomaly_detect mad', () {
    test('robustly flags one gross outlier', () async {
      final x = [for (var i = 0; i < 99; i++) 10.0 + (i % 5) * 0.1];
      x.add(100.0); // gross outlier
      final r = await AnomalyDetectFunction().execute(
          {'columns': ['v'], 'method': 'mad'}, _series(x));
      final anomalies = r.results['anomalies'] as List;
      expect(anomalies, hasLength(1));
      expect((anomalies.single as Map)['value'], 100.0);
    });
  });

  group('smoothing', () {
    test('sma of a constant is the constant', () async {
      final r = await SmoothingFunction().execute(
          {'method': 'sma', 'window': 4}, _series(List.filled(20, 3.0)));
      expect(((r.results['values'] as List).cast<double>()).last,
          closeTo(3.0, 1e-12));
    });

    test('savgol preserves a quadratic exactly (order 2)', () async {
      final x = [for (var i = 0; i < 30; i++) 0.5 * i * i - 3 * i + 2];
      final r = await SmoothingFunction().execute(
          {'method': 'savgol', 'window': 7, 'polyOrder': 2}, _series(x));
      final out = (r.results['values'] as List).cast<double>();
      // Interior points reproduce the polynomial exactly.
      for (var i = 5; i < 25; i++) {
        expect(out[i], closeTo(x[i], 1e-6));
      }
    });

    test('ema follows a step with expected lag', () async {
      final x = [...List.filled(10, 0.0), ...List.filled(30, 1.0)];
      final r = await SmoothingFunction()
          .execute({'method': 'ema', 'alpha': 0.5}, _series(x));
      final out = (r.results['values'] as List).cast<double>();
      expect(out[9], closeTo(0.0, 1e-9));
      expect(out.last, closeTo(1.0, 1e-3));
    });
  });

  group('differencing', () {
    test('first difference of a linear ramp is constant', () async {
      final x = [for (var i = 0; i < 20; i++) 3.0 * i + 1];
      final r = await DifferencingFunction().execute({}, _series(x));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.length, 19);
      expect(out.every((v) => (v - 3.0).abs() < 1e-9), isTrue);
    });

    test('seasonal difference removes a pure seasonal pattern', () async {
      final x = [
        for (var i = 0; i < 48; i++) math.sin(2 * math.pi * i / 12),
      ];
      final r = await DifferencingFunction()
          .execute({'lag': 12}, _series(x));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.every((v) => v.abs() < 1e-9), isTrue);
    });
  });
}
