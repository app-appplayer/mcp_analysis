import 'dart:math';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// The incremental WindowAggregator (running Kahan sums + monotonic deques)
/// must produce the same numbers the naive full-rescan produced — these pin
/// the equivalence under sliding eviction, long-stream drift, and the
/// non-numeric coercion semantics.
void main() {
  final base = DateTime.utc(2026, 1, 1);

  /// Naive reference over an explicit live-point list.
  double naive(List<double> xs, String agg) {
    if (xs.isEmpty) return 0.0;
    switch (agg) {
      case 'avg':
        return xs.reduce((a, b) => a + b) / xs.length;
      case 'min':
        return xs.reduce(min);
      case 'max':
        return xs.reduce(max);
      case 'sum':
        return xs.reduce((a, b) => a + b);
      case 'count':
        return xs.length.toDouble();
      case 'std':
        if (xs.length < 2) return 0.0;
        final mean = xs.reduce((a, b) => a + b) / xs.length;
        final variance =
            xs.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
                (xs.length - 1);
        return sqrt(variance);
      default:
        return 0.0;
    }
  }

  test('incremental aggregates match the naive rescan under sliding eviction',
      () {
    final rng = Random(11);
    final agg = WindowAggregator(windowSize: const Duration(seconds: 50));
    final live = <MapEntry<DateTime, double>>[];

    for (var i = 0; i < 5000; i++) {
      // Irregular spacing so eviction boundaries vary.
      final t = base.add(Duration(milliseconds: i * 137));
      final x = rng.nextDouble() * 200.0 - 100.0;
      agg.add(AnalysisTimePoint(t: t, v: x));
      live.add(MapEntry(t, x));
      final cutoff = t.subtract(const Duration(seconds: 50));
      live.removeWhere((e) => e.key.isBefore(cutoff));

      if (i % 97 == 0) {
        final xs = live.map((e) => e.value).toList();
        for (final a in ['avg', 'min', 'max', 'sum', 'count', 'std']) {
          expect(agg.aggregate('v', a), closeTo(naive(xs, a), 1e-8),
              reason: 'aggregation "$a" diverged at point $i');
        }
      }
    }
  });

  test('long-stream drift stays bounded (200K points through the window)',
      () {
    final rng = Random(23);
    final agg = WindowAggregator(windowSize: const Duration(seconds: 1000));
    final live = <double>[];

    for (var i = 0; i < 200000; i++) {
      final x = 1000.0 + rng.nextDouble(); // adversarial: mean >> spread
      agg.add(AnalysisTimePoint(t: base.add(Duration(seconds: i)), v: x));
      live.add(x);
      if (live.length > 1001) live.removeAt(0);
    }

    expect(agg.aggregate('v', 'avg'), closeTo(naive(live, 'avg'), 1e-6));
    expect(agg.aggregate('v', 'sum'),
        closeTo(naive(live, 'sum'), naive(live, 'sum').abs() * 1e-9));
    // One-pass variance is the numerically delicate one — pin it explicitly.
    expect(agg.aggregate('v', 'std'), closeTo(naive(live, 'std'), 1e-4));
    expect(agg.aggregate('v', 'min'), naive(live, 'min'));
    expect(agg.aggregate('v', 'max'), naive(live, 'max'));
  });

  test('non-numeric values coerce to 0.0 and occupy the window (parity)', () {
    final agg = WindowAggregator(windowSize: const Duration(minutes: 5));
    agg.add(AnalysisTimePoint(t: base, v: 10.0));
    agg.add(AnalysisTimePoint(t: base.add(const Duration(seconds: 1)), v: 'x'));
    agg.add(AnalysisTimePoint(t: base.add(const Duration(seconds: 2)), v: 20.0));

    expect(agg.aggregate('v', 'count'), 3.0);
    expect(agg.aggregate('v', 'sum'), 30.0);
    expect(agg.aggregate('v', 'avg'), closeTo(10.0, 1e-12));
    expect(agg.aggregate('v', 'min'), 0.0); // coerced value participates
    expect(agg.aggregate('v', 'max'), 20.0);
  });

  test('reset clears every running aggregate', () {
    final agg = WindowAggregator(windowSize: const Duration(minutes: 1));
    for (var i = 0; i < 100; i++) {
      agg.add(AnalysisTimePoint(
          t: base.add(Duration(seconds: i)), v: i.toDouble()));
    }
    agg.reset();
    expect(agg.state.pointCount, 0);
    for (final a in ['avg', 'min', 'max', 'sum', 'count', 'std']) {
      expect(agg.aggregate('v', a), 0.0);
    }
    // Usable after reset.
    agg.add(AnalysisTimePoint(t: base, v: 7.0));
    expect(agg.aggregate('v', 'avg'), 7.0);
  });

  test('window fully empties then refills — accumulators snap back to zero',
      () {
    final agg = WindowAggregator(windowSize: const Duration(seconds: 10));
    for (var i = 0; i < 50; i++) {
      agg.add(AnalysisTimePoint(
          t: base.add(Duration(seconds: i)), v: 123.456));
    }
    // A far-future point evicts everything previous.
    agg.add(AnalysisTimePoint(
        t: base.add(const Duration(days: 1)), v: 5.0));
    expect(agg.aggregate('v', 'count'), 1.0);
    expect(agg.aggregate('v', 'sum'), 5.0);
    expect(agg.aggregate('v', 'avg'), 5.0);
    expect(agg.aggregate('v', 'min'), 5.0);
    expect(agg.aggregate('v', 'max'), 5.0);
    expect(agg.aggregate('v', 'std'), 0.0);
  });
}
