import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Streaming-semantics knobs (roadmap step 3): tumbling windows, the
/// bounded-buffer cap, watermark late-drop, and the reorder buffer that
/// restores event-time order for out-of-order arrivals.
void main() {
  final base = DateTime.utc(2026, 1, 1);
  AnalysisTimePoint pt(int seconds, double v) =>
      AnalysisTimePoint(t: base.add(Duration(seconds: seconds)), v: v);

  group('tumbling window', () {
    test('accumulates within an interval and resets at the boundary', () {
      final agg = WindowAggregator(
        windowSize: const Duration(seconds: 10),
        kind: WindowKind.tumbling,
      );
      for (var i = 0; i < 10; i++) {
        agg.add(pt(i, 1.0)); // interval [0,10)
      }
      expect(agg.aggregate('v', 'count'), 10.0);
      expect(agg.aggregate('v', 'sum'), 10.0);

      agg.add(pt(10, 5.0)); // crosses into [10,20) → reset
      expect(agg.aggregate('v', 'count'), 1.0);
      expect(agg.aggregate('v', 'sum'), 5.0);
      expect(agg.aggregate('v', 'min'), 5.0);
      expect(agg.aggregate('v', 'max'), 5.0);
    });

    test('a point from an already-closed interval is late-dropped', () {
      final agg = WindowAggregator(
        windowSize: const Duration(seconds: 10),
        kind: WindowKind.tumbling,
      );
      agg.add(pt(15, 1.0)); // interval [10,20)
      agg.add(pt(5, 9.0)); // belongs to closed [0,10)
      expect(agg.lateDropped, 1);
      expect(agg.aggregate('v', 'count'), 1.0);
      expect(agg.aggregate('v', 'sum'), 1.0);
    });
  });

  group('bounded buffer (maxPoints)', () {
    test('overflow evicts oldest and counts', () {
      final agg = WindowAggregator(
        windowSize: const Duration(hours: 1), // time never evicts here
        maxPoints: 3,
      );
      for (var i = 0; i < 5; i++) {
        agg.add(pt(i, i.toDouble()));
      }
      expect(agg.aggregate('v', 'count'), 3.0);
      expect(agg.overflowDropped, 2);
      expect(agg.aggregate('v', 'min'), 2.0); // 0,1 evicted
      expect(agg.aggregate('v', 'max'), 4.0);
      expect(agg.aggregate('v', 'sum'), 9.0);
    });
  });

  group('watermark late-drop (sliding)', () {
    test('a point older than watermark − window never enters', () {
      final agg = WindowAggregator(windowSize: const Duration(seconds: 10));
      agg.add(pt(100, 1.0)); // watermark = 100
      agg.add(pt(85, 9.0)); // < 100-10 → expired on arrival
      expect(agg.lateDropped, 1);
      expect(agg.aggregate('v', 'count'), 1.0);
      expect(agg.aggregate('v', 'sum'), 1.0);
    });

    test('in-window out-of-order point still aggregates correctly', () {
      final agg = WindowAggregator(windowSize: const Duration(seconds: 10));
      agg.add(pt(100, 1.0));
      agg.add(pt(95, 2.0)); // out of order but within window
      expect(agg.lateDropped, 0);
      expect(agg.aggregate('v', 'count'), 2.0);
      expect(agg.aggregate('v', 'sum'), 3.0);
      expect(agg.aggregate('v', 'min'), 1.0);
      expect(agg.aggregate('v', 'max'), 2.0);
    });
  });

  group('ReorderBuffer', () {
    test('releases points in event-time order once the watermark passes', () {
      final buf = ReorderBuffer(allowedLateness: const Duration(seconds: 5));
      expect(buf.add(pt(10, 1)), isEmpty); // watermark 5 — nothing ready
      expect(buf.add(pt(8, 2)), isEmpty); // out of order, held
      final released = buf.add(pt(20, 3)); // watermark 15 → 8,10 release
      expect(released.map((p) => p.t.second).toList(), [8, 10]);
      expect(buf.pendingCount, 1); // the 20s point still held
    });

    test('too-late point (older than last released) is dropped + counted', () {
      final buf = ReorderBuffer(allowedLateness: const Duration(seconds: 2));
      buf.add(pt(10, 1));
      buf.add(pt(20, 2)); // releases 10
      expect(buf.add(pt(9, 3)), isEmpty); // older than released 10
      expect(buf.lateDropped, 1);
    });

    test('flush releases the tail in order', () {
      final buf = ReorderBuffer(allowedLateness: const Duration(seconds: 60));
      buf.add(pt(3, 1));
      buf.add(pt(1, 2));
      buf.add(pt(2, 3));
      final out = buf.flush();
      expect(out.map((p) => p.t.second).toList(), [1, 2, 3]);
      expect(buf.pendingCount, 0);
    });

    test('reorder → aggregator chain fixes disorder end to end', () {
      final buf = ReorderBuffer(allowedLateness: const Duration(seconds: 5));
      final agg = WindowAggregator(windowSize: const Duration(seconds: 30));
      // Disordered arrivals within a 5s span.
      for (final s in [10, 12, 11, 15, 13, 14, 25, 24, 30]) {
        for (final p in buf.add(pt(s, s.toDouble()))) {
          agg.add(p);
        }
      }
      for (final p in buf.flush()) {
        agg.add(p);
      }
      expect(agg.lateDropped, 0);
      expect(buf.lateDropped, 0);
      expect(agg.aggregate('v', 'count'), 9.0);
      expect(agg.aggregate('v', 'min'), 10.0);
      expect(agg.aggregate('v', 'max'), 30.0);
    });
  });
}
