/// Performance baseline harness for mcp_analysis (roadmap step 1).
///
/// Measures absolute numbers — batch function throughput (rows/s), streaming
/// window hot-path cost (per-point add, per-emit aggregate p50/p95), and
/// resident memory deltas — so tier-placement decisions and the incremental-
/// aggregation rewrite (step 2) have a recorded before/after.
///
/// Run: `dart run bench/analysis_bench.dart`
///
/// Deterministic: fixed seeds, fixed base timestamp. Every scenario reports
/// via [_report] in one aligned table; nothing asserts — this is a meter,
/// not a test (NFR assertions are wired separately once targets are set).
import 'dart:io';
import 'dart:math';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';

final _results = <List<String>>[];

void _report(String scenario, String metric, String value) {
  _results.add([scenario, metric, value]);
}

String _fmt(num v) {
  if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(2)}M';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
  return v.toStringAsFixed(v is int ? 0 : 2);
}

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

AnalysisDataSet _dataset(int rows, {int seed = 42}) {
  final rng = Random(seed);
  return AnalysisDataSet(
    columns: const [
      AnalysisColumnInfo(name: 'temperature', type: 'double'),
      AnalysisColumnInfo(name: 'pressure', type: 'double'),
    ],
    rows: List<Map<String, dynamic>>.generate(rows, (i) {
      final t = rng.nextDouble() * 100.0;
      return <String, dynamic>{
        'temperature': t,
        'pressure': t * 0.7 + rng.nextDouble() * 10.0,
      };
    }),
    rowCount: rows,
  );
}

Future<double> _benchBatch(
  String scenario,
  int rows,
  Future<void> Function(AnalysisDataSet data) run, {
  int warmup = 1,
  int iterations = 3,
}) async {
  final data = _dataset(rows);
  for (var i = 0; i < warmup; i++) {
    await run(data);
  }
  final sw = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    sw.start();
    await run(data);
    sw.stop();
  }
  final usPerIter = sw.elapsedMicroseconds / iterations;
  final rowsPerSec = rows / (usPerIter / 1e6);
  _report(scenario, 'rows/s', _fmt(rowsPerSec));
  _report(scenario, 'ms/run', (usPerIter / 1000).toStringAsFixed(1));
  return rowsPerSec;
}

/// Streaming window hot path: N points flow through a sliding window that
/// stays at [occupancy] points; every [emitEvery] points the aggregates are
/// read (mirrors the alert emit tick). Reports per-point add cost and
/// per-emit aggregate latency p50/p95.
void _benchWindow({
  required int occupancy,
  required int totalPoints,
  int emitEvery = 100,
}) {
  final scenario = 'window occ=${_fmt(occupancy)}';
  final base = DateTime.utc(2026, 1, 1);
  // Window sized so exactly [occupancy] one-second-spaced points fit.
  final aggregator = WindowAggregator(windowSize: Duration(seconds: occupancy));
  final rng = Random(7);

  final addSw = Stopwatch();
  final emitLatencies = <int>[];
  for (var i = 0; i < totalPoints; i++) {
    final p = AnalysisTimePoint(
      t: base.add(Duration(seconds: i)),
      v: rng.nextDouble() * 100.0,
    );
    addSw.start();
    aggregator.add(p);
    addSw.stop();
    if (i % emitEvery == 0 && i >= occupancy) {
      final sw = Stopwatch()..start();
      aggregator.aggregate('v', 'avg');
      aggregator.aggregate('v', 'std');
      aggregator.aggregate('v', 'min');
      aggregator.aggregate('v', 'max');
      sw.stop();
      emitLatencies.add(sw.elapsedMicroseconds);
    }
  }

  final addUsPerPoint = addSw.elapsedMicroseconds / totalPoints;
  _report(scenario, 'add us/pt', addUsPerPoint.toStringAsFixed(2));
  _report(scenario, 'add pts/s', _fmt(1e6 / addUsPerPoint));
  if (emitLatencies.isNotEmpty) {
    emitLatencies.sort();
    final p50 = emitLatencies[emitLatencies.length ~/ 2];
    final p95 = emitLatencies[(emitLatencies.length * 95) ~/ 100];
    _report(scenario, 'emit p50', '${(p50 / 1000).toStringAsFixed(2)}ms');
    _report(scenario, 'emit p95', '${(p95 / 1000).toStringAsFixed(2)}ms');
  }
}

Future<void> main() async {
  stdout.writeln('mcp_analysis bench — baseline meter');
  stdout.writeln('dart ${Platform.version.split(' ').first} · '
      '${Platform.operatingSystem}');
  final rssStart = _rssMb();

  // ── batch functions ──────────────────────────────────────────────
  final stats = DescriptiveStatsFunction();
  for (final rows in [10000, 100000, 1000000]) {
    await _benchBatch('stats ${_fmt(rows)}', rows, (d) async {
      await stats.execute({'columns': ['temperature']}, d);
    });
  }

  final anomaly = AnomalyDetectFunction();
  await _benchBatch('anomaly zscore 100K', 100000, (d) async {
    await anomaly.execute(
      {'columns': ['temperature'], 'method': 'zscore', 'threshold': 3.0},
      d,
    );
  });

  final corr = CorrelationRegressionFunction();
  await _benchBatch('correlation 100K', 100000, (d) async {
    await corr.execute({'columns': ['temperature', 'pressure']}, d);
  });

  final pipeline = TransformPipeline();
  await _benchBatch('transform filter 1M', 1000000, (d) async {
    await pipeline.execute(d, [
      AnalysisTransform(
        name: 'filter',
        parameters: {'column': 'temperature', 'operator': '>', 'value': 50.0},
      ),
    ]);
  });

  // ── streaming window hot path ───────────────────────────────────
  _benchWindow(occupancy: 300, totalPoints: 50000); // 5m window @1Hz-class
  _benchWindow(occupancy: 10000, totalPoints: 60000); // sensor-burst class
  _benchWindow(occupancy: 100000, totalPoints: 150000, emitEvery: 1000);

  // ── memory ──────────────────────────────────────────────────────
  final data = _dataset(1000000);
  _report('memory', '1M rows RSS Δ', '${_rssMb() - rssStart}MB');
  // Keep the dataset alive past the measurement.
  if (data.rows.length != 1000000) throw StateError('unreachable');

  // ── table ───────────────────────────────────────────────────────
  stdout.writeln('');
  final w0 = _results.map((r) => r[0].length).reduce(max) + 2;
  final w1 = _results.map((r) => r[1].length).reduce(max) + 2;
  for (final r in _results) {
    stdout.writeln('${r[0].padRight(w0)}${r[1].padRight(w1)}${r[2]}');
  }
}
