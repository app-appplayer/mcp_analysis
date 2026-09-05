import 'dart:convert';
import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import 'datasource_registry.dart';

/// Synthetic data source (`AnalysisSourceType.synthetic`) — the in-core
/// simulation seam. A generator registered as a DATA SOURCE, so synthetic
/// data flows the exact pipeline measured data does (transforms · analysis
/// functions · alerts · artifacts · provenance). Heavy physics solvers
/// (CFD/FEM, nonlinear device convergence loops) stay external (serving);
/// this adapter covers the pure-Dart deterministic tier: signal models,
/// linear dynamic-system simulation, and Monte Carlo sampling.
///
/// The `query` string is a JSON spec:
/// ```json
/// {
///   "samples": 1000,
///   "sampleRate": 100,          // Hz — drives _timestamp spacing
///   "seed": 42,                  // REQUIRED for reproducibility; recorded
///   "components": [              // summed together
///     {"kind": "constant", "level": 10},
///     {"kind": "trend", "slope": 0.5},
///     {"kind": "sine", "amplitude": 2, "frequency": 5, "phase": 0},
///     {"kind": "noise", "std": 0.3, "distribution": "gaussian"},
///     {"kind": "step", "at": 500, "level": 4},
///     {"kind": "impulse", "at": 700, "level": 20},
///     {"kind": "state_space", "a": [[-1]], "b": [1], "c": [1], "d": 0,
///      "x0": [0], "input": {"kind": "step", "at": 0, "level": 1}},
///     {"kind": "transfer_function", "num": [1], "den": [1, 1],
///      "input": {"kind": "step", "at": 0, "level": 1}},
///     {"kind": "rlc", "r": 0.4, "l": 1, "c": 1, "output": "vc",
///      "input": {"kind": "step", "at": 0, "level": 1}}
///   ],
///   "ensemble": {"runs": 200, "percentiles": [5, 50, 95]}
/// }
/// ```
/// Model kinds (`state_space` · `transfer_function` · `rlc`) simulate a
/// LINEAR dynamic system with fixed-step RK4 under zero-order-hold input
/// (the `input` is any non-model component spec, noise included) —
/// deterministic, cost O(samples · states²). `rlc` is the series-RLC
/// convenience mapping (voltage-source driven; output `vc` | `il` | `vr`).
///
/// `ensemble` runs the whole spec N times with seeds seed..seed+N-1 and
/// emits `value` (mean) plus `value_p<p>` percentile columns — simulation-
/// based prediction bands rather than point extrapolation.
///
/// Determinism: same spec (incl. seed) → identical dataset; the seed and
/// spec are echoed into the dataset metadata so provenance can replay it.
class SyntheticSourceAdapter extends DataSourceAdapter
    with StreamableDataSource {
  /// Epoch for synthetic timestamps — fixed so datasets are reproducible.
  static final DateTime _epoch = DateTime.utc(2026, 1, 1);

  static const _modelKinds = {'state_space', 'transfer_function', 'rlc'};

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.synthetic;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    final spec = _parseSpec(query);
    return _generate(spec);
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return const AnalysisSourceSchema(
      columns: [
        AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        AnalysisColumnInfo(name: 'value', type: 'double'),
      ],
    );
  }

  @override
  Future<bool> isAvailable() async => true;

  /// Stream mode: emits the generated series in [batchSize] chunks —
  /// lets stream-executor jobs run against synthetic feeds.
  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) async* {
    final spec = _parseSpec(query);
    final full = _generate(spec);
    final batchSize = (spec['batchSize'] as num?)?.toInt() ?? 100;
    for (var start = 0; start < full.rows.length; start += batchSize) {
      final rows = full.rows
          .sublist(start, math.min(start + batchSize, full.rows.length));
      yield AnalysisDataSet(
        columns: full.columns,
        rows: rows,
        rowCount: rows.length,
        metadata: full.metadata,
      );
    }
  }

  Map<String, dynamic> _parseSpec(String query) {
    try {
      final decoded = jsonDecode(query);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('spec must be a JSON object');
      }
      return decoded;
    } on FormatException catch (e) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'synthetic source query must be a JSON spec: ${e.message}',
      );
    }
  }

  AnalysisDataSet _generate(Map<String, dynamic> spec) {
    final samples = (spec['samples'] as num?)?.toInt() ?? 1000;
    if (samples <= 0 || samples > 10000000) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'synthetic samples must be 1..10M (got $samples)',
      );
    }
    final sampleRate = (spec['sampleRate'] as num?)?.toDouble() ?? 1.0;
    final seed = (spec['seed'] as num?)?.toInt() ?? 0;
    final components = (spec['components'] as List?)
            ?.map((c) => (c as Map).cast<String, dynamic>())
            .toList() ??
        [
          {'kind': 'constant', 'level': 0.0},
        ];

    final dtUs = (1e6 / sampleRate).round();
    final ensembleSpec = spec['ensemble'] as Map?;

    if (ensembleSpec == null) {
      final series = _series(components, samples, sampleRate, seed);
      final rows = List<Map<String, dynamic>>.generate(
          samples,
          (i) => <String, dynamic>{
                '_timestamp': _epoch.add(Duration(microseconds: i * dtUs)),
                'value': series[i],
              });
      return AnalysisDataSet(
        columns: const [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: rows,
        rowCount: rows.length,
        metadata: {
          'source': 'synthetic',
          'seed': seed,
          'sampleRate': sampleRate,
          'spec': spec,
        },
      );
    }

    // Monte Carlo ensemble: N seeded runs → mean + percentile band columns.
    final runs = ((ensembleSpec['runs'] as num?)?.toInt() ?? 100);
    if (runs < 2 || runs > 10000 || samples * runs > 50000000) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'ensemble runs must be 2..10000 with runs×samples ≤ 50M',
      );
    }
    final percentiles = ((ensembleSpec['percentiles'] as List?)
                ?.map((p) => (p as num).toDouble())
                .toList() ??
            [5.0, 50.0, 95.0])
        .where((p) => p >= 0 && p <= 100)
        .toList();
    final all = List<List<double>>.generate(
        runs, (k) => _series(components, samples, sampleRate, seed + k));

    final columns = <AnalysisColumnInfo>[
      const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
      const AnalysisColumnInfo(name: 'value', type: 'double'),
      for (final p in percentiles)
        AnalysisColumnInfo(name: 'value_p${_pLabel(p)}', type: 'double'),
    ];
    final scratch = List<double>.filled(runs, 0.0);
    final rows = List<Map<String, dynamic>>.generate(samples, (i) {
      var mean = 0.0;
      for (var k = 0; k < runs; k++) {
        scratch[k] = all[k][i];
        mean += all[k][i];
      }
      mean /= runs;
      scratch.sort();
      final row = <String, dynamic>{
        '_timestamp': _epoch.add(Duration(microseconds: i * dtUs)),
        'value': mean,
      };
      for (final p in percentiles) {
        row['value_p${_pLabel(p)}'] = _percentileSorted(scratch, p);
      }
      return row;
    });

    return AnalysisDataSet(
      columns: columns,
      rows: rows,
      rowCount: rows.length,
      metadata: {
        'source': 'synthetic',
        'seed': seed,
        'sampleRate': sampleRate,
        'ensembleRuns': runs,
        'spec': spec,
      },
    );
  }

  /// One realization of the spec: point-wise kinds evaluated per sample,
  /// model kinds simulated as full series first, everything summed.
  List<double> _series(
    List<Map<String, dynamic>> components,
    int samples,
    double sampleRate,
    int seed,
  ) {
    final out = List<double>.filled(samples, 0.0);

    // Model components each get their own derived rng (input noise) so the
    // point-wise pass below keeps the original draw order.
    for (var idx = 0; idx < components.length; idx++) {
      final c = components[idx];
      if (_modelKinds.contains(c['kind'])) {
        final rng = math.Random(seed ^ (0x9E3779 * (idx + 1)));
        final y = _simulateModel(c, samples, sampleRate, rng);
        for (var i = 0; i < samples; i++) {
          out[i] += y[i];
        }
      }
    }

    final rng = math.Random(seed);
    for (var i = 0; i < samples; i++) {
      final t = i / sampleRate;
      for (final c in components) {
        if (!_modelKinds.contains(c['kind'])) {
          out[i] += _componentValue(c, i, t, rng);
        }
      }
    }
    return out;
  }

  double _componentValue(
      Map<String, dynamic> c, int i, double t, math.Random rng) {
    switch (c['kind'] as String? ?? 'constant') {
      case 'trend':
        return ((c['slope'] as num?)?.toDouble() ?? 1.0) * t;
      case 'sine':
        return ((c['amplitude'] as num?)?.toDouble() ?? 1.0) *
            math.sin(2 *
                    math.pi *
                    ((c['frequency'] as num?)?.toDouble() ?? 1.0) *
                    t +
                ((c['phase'] as num?)?.toDouble() ?? 0.0));
      case 'noise':
        final std = (c['std'] as num?)?.toDouble() ?? 1.0;
        final dist = c['distribution'] as String? ?? 'gaussian';
        if (dist == 'uniform') {
          return (rng.nextDouble() * 2 - 1) * std * math.sqrt(3.0);
        }
        // Box–Muller gaussian.
        final u1 = math.max(rng.nextDouble(), 1e-12);
        final u2 = rng.nextDouble();
        return std * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
      case 'step':
        return i >= ((c['at'] as num?)?.toInt() ?? 0)
            ? (c['level'] as num?)?.toDouble() ?? 1.0
            : 0.0;
      case 'impulse':
        return i == ((c['at'] as num?)?.toInt() ?? -1)
            ? (c['level'] as num?)?.toDouble() ?? 1.0
            : 0.0;
      case 'constant':
      default:
        return (c['level'] as num?)?.toDouble() ?? 0.0;
    }
  }

  /// Linear dynamic-system simulation: ẋ = Ax + Bu, y = Cx + Du under
  /// zero-order-hold input, fixed-step RK4 at the sample rate.
  List<double> _simulateModel(
    Map<String, dynamic> c,
    int samples,
    double sampleRate,
    math.Random rng,
  ) {
    final ss = _toStateSpace(c);
    final a = ss.a, b = ss.b, cRow = ss.c;
    final d = ss.d;
    final n = a.length;
    final inputSpec = (c['input'] as Map?)?.cast<String, dynamic>() ??
        {'kind': 'step', 'at': 0, 'level': 1.0};
    if (_modelKinds.contains(inputSpec['kind'])) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'model input must be a point-wise component (no nesting)',
      );
    }

    final dt = 1 / sampleRate;
    final x = List<double>.from(ss.x0);
    final y = List<double>.filled(samples, 0.0);
    final k1 = List<double>.filled(n, 0.0);
    final k2 = List<double>.filled(n, 0.0);
    final k3 = List<double>.filled(n, 0.0);
    final k4 = List<double>.filled(n, 0.0);
    final tmp = List<double>.filled(n, 0.0);

    void deriv(List<double> state, double u, List<double> out) {
      for (var r = 0; r < n; r++) {
        var s = b[r] * u;
        for (var cc = 0; cc < n; cc++) {
          s += a[r][cc] * state[cc];
        }
        out[r] = s;
      }
    }

    for (var i = 0; i < samples; i++) {
      final u = _componentValue(inputSpec, i, i / sampleRate, rng);
      var yi = d * u;
      for (var r = 0; r < n; r++) {
        yi += cRow[r] * x[r];
      }
      y[i] = yi;

      deriv(x, u, k1);
      for (var r = 0; r < n; r++) {
        tmp[r] = x[r] + dt / 2 * k1[r];
      }
      deriv(tmp, u, k2);
      for (var r = 0; r < n; r++) {
        tmp[r] = x[r] + dt / 2 * k2[r];
      }
      deriv(tmp, u, k3);
      for (var r = 0; r < n; r++) {
        tmp[r] = x[r] + dt * k3[r];
      }
      deriv(tmp, u, k4);
      for (var r = 0; r < n; r++) {
        x[r] += dt / 6 * (k1[r] + 2 * k2[r] + 2 * k3[r] + k4[r]);
      }
    }
    return y;
  }

  _StateSpace _toStateSpace(Map<String, dynamic> c) {
    switch (c['kind'] as String) {
      case 'state_space':
        final a = (c['a'] as List?)
            ?.map((row) =>
                (row as List).map((v) => (v as num).toDouble()).toList())
            .toList();
        final b = (c['b'] as List?)?.map((v) => (v as num).toDouble()).toList();
        final cRow =
            (c['c'] as List?)?.map((v) => (v as num).toDouble()).toList();
        if (a == null || b == null || cRow == null) {
          throw AnalysisError(
            code: 'source.schema_mismatch',
            message: 'state_space requires a (n×n), b (n), c (n)',
          );
        }
        final n = a.length;
        if (n < 1 ||
            n > 20 ||
            a.any((row) => row.length != n) ||
            b.length != n ||
            cRow.length != n) {
          throw AnalysisError(
            code: 'source.schema_mismatch',
            message: 'state_space matrix dimensions inconsistent (n ≤ 20)',
          );
        }
        final x0 =
            (c['x0'] as List?)?.map((v) => (v as num).toDouble()).toList() ??
                List<double>.filled(n, 0.0);
        if (x0.length != n) {
          throw AnalysisError(
            code: 'source.schema_mismatch',
            message: 'x0 length must equal state count',
          );
        }
        return _StateSpace(a, b, cRow, (c['d'] as num?)?.toDouble() ?? 0.0, x0);

      case 'transfer_function':
        final num0 =
            (c['num'] as List?)?.map((v) => (v as num).toDouble()).toList();
        final den =
            (c['den'] as List?)?.map((v) => (v as num).toDouble()).toList();
        if (num0 == null ||
            den == null ||
            den.length < 2 ||
            den.length > 21 ||
            num0.isEmpty ||
            num0.length > den.length ||
            den[0] == 0) {
          throw AnalysisError(
            code: 'source.schema_mismatch',
            message: 'transfer_function requires proper num/den '
                '(descending s powers, den[0] ≠ 0, order ≤ 20)',
          );
        }
        final n = den.length - 1;
        // Normalize to monic denominator, pad numerator to n+1 coefficients.
        final aCoef = [for (var k = 1; k <= n; k++) den[k] / den[0]];
        final bCoef = [
          for (var k = 0; k <= n; k++)
            k < n + 1 - num0.length
                ? 0.0
                : num0[k - (n + 1 - num0.length)] / den[0],
        ];
        // Controllable canonical form.
        final a = List.generate(
            n,
            (r) => List.generate(
                n,
                (cc) => r < n - 1
                    ? (cc == r + 1 ? 1.0 : 0.0)
                    : -aCoef[n - 1 - cc]));
        final b = [for (var r = 0; r < n; r++) r == n - 1 ? 1.0 : 0.0];
        final d = bCoef[0];
        final cRow = [
          for (var cc = 0; cc < n; cc++) bCoef[n - cc] - aCoef[n - 1 - cc] * d,
        ];
        return _StateSpace(a, b, cRow, d, List<double>.filled(n, 0.0));

      case 'rlc':
        // Series RLC driven by a voltage source; states x = [iL, vC].
        final r = (c['r'] as num?)?.toDouble() ?? 1.0;
        final l = (c['l'] as num?)?.toDouble() ?? 1.0;
        final cap = (c['c'] as num?)?.toDouble() ?? 1.0;
        if (l <= 0 || cap <= 0 || r < 0) {
          throw AnalysisError(
            code: 'source.schema_mismatch',
            message: 'rlc requires l > 0, c > 0, r ≥ 0',
          );
        }
        final a = [
          [-r / l, -1 / l],
          [1 / cap, 0.0],
        ];
        final b = [1 / l, 0.0];
        final output = c['output'] as String? ?? 'vc';
        final cRow = switch (output) {
          'il' => [1.0, 0.0],
          'vr' => [r, 0.0],
          'vc' => [0.0, 1.0],
          _ => throw AnalysisError(
              code: 'source.schema_mismatch',
              message: 'rlc output must be vc | il | vr',
            ),
        };
        return _StateSpace(a, b, cRow, 0.0, [0.0, 0.0]);

      default:
        throw StateError('not a model kind: ${c['kind']}');
    }
  }

  String _pLabel(double p) => p == p.roundToDouble()
      ? p.round().toString()
      : p.toString().replaceAll('.', '_');

  double _percentileSorted(List<double> sorted, double p) {
    final pos = (sorted.length - 1) * p / 100;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) return sorted[lo];
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }
}

class _StateSpace {
  const _StateSpace(this.a, this.b, this.c, this.d, this.x0);

  final List<List<double>> a;
  final List<double> b;
  final List<double> c;
  final double d;
  final List<double> x0;
}
