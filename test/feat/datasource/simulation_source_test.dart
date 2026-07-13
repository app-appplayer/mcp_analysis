import 'dart:convert';
import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Known-value tests for the simulation tier of the synthetic source:
/// linear dynamic models (state_space · transfer_function · rlc, RK4) and
/// Monte Carlo ensemble prediction bands.
void main() {
  final source = SyntheticSourceAdapter();

  Future<List<double>> values(Map<String, dynamic> spec,
      {String column = 'value'}) async {
    final ds = await source.queryData(query: jsonEncode(spec));
    return ds.rows.map((r) => (r[column] as num).toDouble()).toList();
  }

  group('transfer_function', () {
    test('1/(s+1) step response follows 1 - e^-t', () async {
      const fs = 100.0;
      final y = await values({
        'samples': 600,
        'sampleRate': fs,
        'seed': 1,
        'components': [
          {
            'kind': 'transfer_function',
            'num': [1],
            'den': [1, 1],
            'input': {'kind': 'step', 'at': 0, 'level': 1},
          },
        ],
      });
      expect(y[100], closeTo(1 - math.exp(-1.0), 0.01)); // t = 1s
      expect(y[500], closeTo(1 - math.exp(-5.0), 0.01)); // t = 5s
    });

    test('2nd-order resonator impulse response rings at f_d', () async {
      // ωn = 2π·5, ζ = 0.05 → damped frequency ≈ 4.99 Hz.
      const fs = 500.0;
      final wn = 2 * math.pi * 5;
      final y = await values({
        'samples': 2048,
        'sampleRate': fs,
        'seed': 1,
        'components': [
          {
            'kind': 'transfer_function',
            'num': [wn * wn],
            'den': [1, 2 * 0.05 * wn, wn * wn],
            'input': {'kind': 'impulse', 'at': 0, 'level': 1},
          },
        ],
      });
      final ds = AnalysisDataSet(
        columns: const [AnalysisColumnInfo(name: 'v', type: 'double')],
        rows: [for (final v in y) <String, dynamic>{'v': v}],
        rowCount: y.length,
      );
      final r = await FftFunction().execute({'sampleRate': fs}, ds);
      expect(r.results['dominantFrequency'], closeTo(5.0, 0.5));
    });
  });

  group('rlc', () {
    test('underdamped series RLC step overshoot matches theory', () async {
      // L = C = 1, R = 0.4 → ζ = 0.2, peak = 1 + e^(-πζ/√(1-ζ²)) ≈ 1.527.
      final y = await values({
        'samples': 6000,
        'sampleRate': 100.0,
        'seed': 1,
        'components': [
          {
            'kind': 'rlc',
            'r': 0.4,
            'l': 1,
            'c': 1,
            'output': 'vc',
            'input': {'kind': 'step', 'at': 0, 'level': 1},
          },
        ],
      });
      final zeta = 0.2;
      final expectedPeak =
          1 + math.exp(-math.pi * zeta / math.sqrt(1 - zeta * zeta));
      expect(y.reduce(math.max), closeTo(expectedPeak, 0.01));
      expect(y.last, closeTo(1.0, 0.01)); // settles to the source voltage
    });
  });

  group('state_space', () {
    test('pure integrator turns a step into a ramp', () async {
      const fs = 100.0;
      final y = await values({
        'samples': 300,
        'sampleRate': fs,
        'seed': 1,
        'components': [
          {
            'kind': 'state_space',
            'a': [
              [0]
            ],
            'b': [1],
            'c': [1],
            'input': {'kind': 'step', 'at': 0, 'level': 2},
          },
        ],
      });
      expect(y[200], closeTo(2 * 200 / fs, 0.05)); // ∫2 dt = 2t
    });

    test('guards: dimension mismatch and nested model input throw', () {
      expect(
          () => values({
                'components': [
                  {
                    'kind': 'state_space',
                    'a': [
                      [0, 1]
                    ],
                    'b': [1],
                    'c': [1],
                  },
                ],
              }),
          throwsA(isA<AnalysisError>()));
      expect(
          () => values({
                'components': [
                  {
                    'kind': 'transfer_function',
                    'num': [1],
                    'den': [0, 1], // den[0] = 0
                  },
                ],
              }),
          throwsA(isA<AnalysisError>()));
      expect(
          () => values({
                'components': [
                  {
                    'kind': 'rlc',
                    'r': 1,
                    'l': 1,
                    'c': 1,
                    'input': {
                      'kind': 'transfer_function',
                      'num': [1],
                      'den': [1, 1],
                    },
                  },
                ],
              }),
          throwsA(isA<AnalysisError>()));
    });
  });

  group('ensemble', () {
    test('percentile bands match the noise distribution', () async {
      final spec = {
        'samples': 200,
        'sampleRate': 10.0,
        'seed': 7,
        'components': [
          {'kind': 'constant', 'level': 5.0},
          {'kind': 'noise', 'std': 1.0},
        ],
        'ensemble': {
          'runs': 400,
          'percentiles': [5, 50, 95],
        },
      };
      final ds = await source.queryData(query: jsonEncode(spec));
      expect(ds.columns.map((c) => c.name),
          containsAll(['value', 'value_p5', 'value_p50', 'value_p95']));
      // Averaged over samples: mean ≈ 5, p95 − p5 ≈ 2·1.645·std.
      double avg(String col) =>
          ds.rows.map((r) => (r[col] as num).toDouble()).reduce((a, b) => a + b) /
          ds.rows.length;
      expect(avg('value'), closeTo(5.0, 0.05));
      expect(avg('value_p95') - avg('value_p5'), closeTo(3.29, 0.3));
      expect(ds.metadata?['ensembleRuns'], 400);
    });

    test('deterministic: same spec twice gives identical bands', () async {
      final spec = {
        'samples': 50,
        'seed': 3,
        'components': [
          {
            'kind': 'rlc',
            'r': 0.4,
            'l': 1,
            'c': 1,
            'input': {'kind': 'noise', 'std': 1.0},
          },
        ],
        'ensemble': {
          'runs': 20,
          'percentiles': [50],
        },
      };
      final a = await source.queryData(query: jsonEncode(spec));
      final b = await source.queryData(query: jsonEncode(spec));
      for (var i = 0; i < a.rows.length; i++) {
        expect(a.rows[i]['value_p50'], b.rows[i]['value_p50']);
        expect(a.rows[i]['value'], b.rows[i]['value']);
      }
    });
  });
}
