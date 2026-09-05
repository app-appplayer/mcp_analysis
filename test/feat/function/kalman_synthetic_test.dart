import 'dart:convert';
import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Prediction (kalman_filter) + simulation (synthetic source) — the in-core
/// upper-tier residents per the 2026-07-14 placement rule.
AnalysisDataSet _series(List<double> samples) => AnalysisDataSet(
      columns: const [AnalysisColumnInfo(name: 'v', type: 'double')],
      rows: [
        for (final s in samples) <String, dynamic>{'v': s},
      ],
      rowCount: samples.length,
    );

void main() {
  group('kalman_filter', () {
    test('trend model tracks and extrapolates a noisy line', () async {
      final rng = math.Random(3);
      final z = [
        for (var i = 0; i < 200; i++)
          10.0 + 2.0 * i + (rng.nextDouble() - 0.5) * 2.0,
      ];
      final r = await KalmanFilterFunction().execute(
          {'horizon': 5, 'processNoise': 0.01, 'measurementNoise': 1.0},
          _series(z));
      expect(r.results['trend'], closeTo(2.0, 0.15));
      final f = (r.results['forecast'] as List).cast<double>();
      // At i=200 the line is ~410.
      expect(f.first, closeTo(10.0 + 2.0 * 200, 4.0));
      expect(f.last - f.first, closeTo(4 * 2.0, 1.0)); // slope carried
    });

    test('level model smooths a constant under noise', () async {
      final rng = math.Random(5);
      final z = [for (var i = 0; i < 300; i++) 50.0 + (rng.nextDouble() - 0.5)];
      final r =
          await KalmanFilterFunction().execute({'model': 'level'}, _series(z));
      expect(r.results['level'], closeTo(50.0, 0.3));
      final filtered = (r.results['filtered'] as List).cast<double>();
      // Filtered tail variance well below raw noise.
      final tail = filtered.sublist(200);
      final mean = tail.reduce((a, b) => a + b) / tail.length;
      final dev = tail.map((v) => (v - mean).abs()).reduce(math.max);
      expect(dev, lessThan(0.2));
    });
  });

  group('synthetic source', () {
    final adapter = SyntheticSourceAdapter();
    String spec(Map<String, dynamic> m) => jsonEncode(m);

    test('deterministic: same seed → identical dataset', () async {
      final q = spec({
        'samples': 50,
        'seed': 42,
        'components': [
          {'kind': 'noise', 'std': 1.0},
        ],
      });
      final a = await adapter.queryData(query: q);
      final b = await adapter.queryData(query: q);
      for (var i = 0; i < 50; i++) {
        expect(a.rows[i]['value'], b.rows[i]['value']);
      }
      expect(a.metadata?['seed'], 42);
    });

    test('composite signal: trend + sine + step composes correctly', () async {
      final q = spec({
        'samples': 100,
        'sampleRate': 10,
        'seed': 1,
        'components': [
          {'kind': 'constant', 'level': 5},
          {'kind': 'trend', 'slope': 1.0}, // per second; t = i/10
          {'kind': 'step', 'at': 50, 'level': 100},
        ],
      });
      final d = await adapter.queryData(query: q);
      expect(d.rows[0]['value'], closeTo(5.0, 1e-9));
      expect(d.rows[10]['value'], closeTo(5.0 + 1.0, 1e-9)); // t=1s
      expect(d.rows[49]['value'], lessThan(20.0));
      expect(d.rows[50]['value'], greaterThan(100.0)); // step landed
    });

    test('synthetic → analysis pipeline symmetry (fft finds the tone)',
        () async {
      final q = spec({
        'samples': 1024,
        'sampleRate': 1000,
        'seed': 7,
        'components': [
          {'kind': 'sine', 'amplitude': 1.0, 'frequency': 60},
        ],
      });
      final d = await adapter.queryData(query: q);
      // Measured-data path, unchanged: the generated dataset feeds fft.
      final r = await FftFunction()
          .execute({'sampleRate': 1000, 'column': 'value'}, d);
      expect(r.results['dominantFrequency'], closeTo(60.0, 1.5));
    });

    test('monte-carlo noise: gaussian std lands near spec', () async {
      final q = spec({
        'samples': 20000,
        'seed': 11,
        'components': [
          {'kind': 'noise', 'std': 2.5, 'distribution': 'gaussian'},
        ],
      });
      final d = await adapter.queryData(query: q);
      final xs = d.rows.map((r) => r['value'] as double).toList();
      final mean = xs.reduce((a, b) => a + b) / xs.length;
      final std = math.sqrt(
          xs.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
              (xs.length - 1));
      expect(mean, closeTo(0.0, 0.06));
      expect(std, closeTo(2.5, 0.06));
    });

    test('stream mode batches the series', () async {
      final q = spec({
        'samples': 250,
        'seed': 1,
        'batchSize': 100,
        'components': [
          {'kind': 'constant', 'level': 1},
        ],
      });
      final batches = await adapter.subscribe(query: q).toList();
      expect(batches.map((b) => b.rows.length).toList(), [100, 100, 50]);
    });

    test('registry routes AnalysisSourceType.synthetic', () async {
      final registry = DataSourceRegistry();
      registry.register(AnalysisSourceType.synthetic, adapter);
      final d = await registry.queryData(
        sourceType: AnalysisSourceType.synthetic,
        query: spec({
          'samples': 10,
          'seed': 1,
          'components': [
            {'kind': 'constant', 'level': 3},
          ],
        }),
      );
      expect(d.rowCount, 10);
      expect(d.rows.first['value'], 3.0);
    });
  });
}
