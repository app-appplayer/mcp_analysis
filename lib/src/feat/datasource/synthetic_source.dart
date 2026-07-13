import 'dart:convert';
import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import 'datasource_registry.dart';

/// Synthetic data source (`AnalysisSourceType.synthetic`) — the in-core
/// simulation seam. A generator registered as a DATA SOURCE, so synthetic
/// data flows the exact pipeline measured data does (transforms · analysis
/// functions · alerts · artifacts · provenance). Heavy physics solvers
/// (CFD/FEM) stay external (serving); this adapter covers the pure-Dart
/// deterministic tier: signal models + Monte Carlo sampling.
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
///     {"kind": "impulse", "at": 700, "level": 20}
///   ]
/// }
/// ```
/// Determinism: same spec (incl. seed) → identical dataset; the seed and
/// spec are echoed into the dataset metadata so provenance can replay it.
class SyntheticSourceAdapter extends DataSourceAdapter
    with StreamableDataSource {
  /// Epoch for synthetic timestamps — fixed so datasets are reproducible.
  static final DateTime _epoch = DateTime.utc(2026, 1, 1);

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
    return AnalysisSourceSchema(
      columns: const [
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
      final rows = full.rows.sublist(
          start, math.min(start + batchSize, full.rows.length));
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
    final rng = math.Random(seed);
    final components = (spec['components'] as List?)
            ?.map((c) => (c as Map).cast<String, dynamic>())
            .toList() ??
        [
          {'kind': 'constant', 'level': 0.0},
        ];

    final dtUs = (1e6 / sampleRate).round();
    final rows = List<Map<String, dynamic>>.generate(samples, (i) {
      final t = i / sampleRate;
      var v = 0.0;
      for (final c in components) {
        switch (c['kind'] as String? ?? 'constant') {
          case 'trend':
            v += ((c['slope'] as num?)?.toDouble() ?? 1.0) * t;
            break;
          case 'sine':
            v += ((c['amplitude'] as num?)?.toDouble() ?? 1.0) *
                math.sin(2 *
                        math.pi *
                        ((c['frequency'] as num?)?.toDouble() ?? 1.0) *
                        t +
                    ((c['phase'] as num?)?.toDouble() ?? 0.0));
            break;
          case 'noise':
            final std = (c['std'] as num?)?.toDouble() ?? 1.0;
            final dist = c['distribution'] as String? ?? 'gaussian';
            if (dist == 'uniform') {
              v += (rng.nextDouble() * 2 - 1) * std * math.sqrt(3.0);
            } else {
              // Box–Muller gaussian.
              final u1 = math.max(rng.nextDouble(), 1e-12);
              final u2 = rng.nextDouble();
              v += std *
                  math.sqrt(-2 * math.log(u1)) *
                  math.cos(2 * math.pi * u2);
            }
            break;
          case 'step':
            if (i >= ((c['at'] as num?)?.toInt() ?? 0)) {
              v += (c['level'] as num?)?.toDouble() ?? 1.0;
            }
            break;
          case 'impulse':
            if (i == ((c['at'] as num?)?.toInt() ?? -1)) {
              v += (c['level'] as num?)?.toDouble() ?? 1.0;
            }
            break;
          case 'constant':
          default:
            v += (c['level'] as num?)?.toDouble() ?? 0.0;
            break;
        }
      }
      return <String, dynamic>{
        '_timestamp': _epoch.add(Duration(microseconds: i * dtUs)),
        'value': v,
      };
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
}
