import 'dart:collection';

import 'package:mcp_bundle/ports.dart';

/// Watermark-based reordering for out-of-order streams (streaming-semantics
/// step of the roadmap).
///
/// [WindowAggregator] keeps its aggregates order-independent, but exact
/// window membership assumes non-decreasing event time. Real multi-hop
/// streams (edge → PC over a network) deliver late and out of order; this
/// buffer restores the ordered contract at the ingest boundary:
///
/// - Points are held until the watermark (`max event time − allowedLateness`)
///   passes them, then released in event-time order.
/// - A point older than the last released time missed its slot entirely and
///   is dropped (counted in [lateDropped]) — the trade every watermark system
///   makes between latency and completeness.
/// - `allowedLateness` is the disorder span the stream is allowed: larger
///   tolerates worse disorder at the cost of that much added latency.
class ReorderBuffer {
  ReorderBuffer({required this.allowedLateness});

  final Duration allowedLateness;

  /// Pending points keyed by event time (multiple points may share one).
  final SplayTreeMap<DateTime, List<AnalysisTimePoint>> _pending =
      SplayTreeMap<DateTime, List<AnalysisTimePoint>>();

  DateTime? _maxT;
  DateTime? _lastReleased;

  /// Points dropped for arriving older than an already-released time.
  int lateDropped = 0;

  int _pendingCount = 0;

  /// Buffered points not yet released.
  int get pendingCount => _pendingCount;

  /// Offer a point; returns every point the advancing watermark releases,
  /// in event-time order (often empty).
  List<AnalysisTimePoint> add(AnalysisTimePoint point) {
    if (_lastReleased != null && point.t.isBefore(_lastReleased!)) {
      lateDropped++;
      return const [];
    }
    if (_maxT == null || point.t.isAfter(_maxT!)) _maxT = point.t;
    _pending.putIfAbsent(point.t, () => <AnalysisTimePoint>[]).add(point);
    _pendingCount++;
    return _release(_maxT!.subtract(allowedLateness));
  }

  /// Release everything still pending (end of stream).
  List<AnalysisTimePoint> flush() {
    final out = <AnalysisTimePoint>[];
    for (final list in _pending.values) {
      out.addAll(list);
    }
    _pending.clear();
    _pendingCount = 0;
    if (out.isNotEmpty) _lastReleased = out.last.t;
    return out;
  }

  List<AnalysisTimePoint> _release(DateTime watermark) {
    final out = <AnalysisTimePoint>[];
    while (_pending.isNotEmpty) {
      final t = _pending.firstKey()!;
      if (t.isAfter(watermark)) break;
      out.addAll(_pending.remove(t)!);
    }
    if (out.isNotEmpty) {
      _pendingCount -= out.length;
      _lastReleased = out.last.t;
    }
    return out;
  }
}
