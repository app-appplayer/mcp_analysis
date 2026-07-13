import 'dart:collection';
import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

/// Current state of the sliding window.
class WindowState {
  final Duration windowSize;
  final List<AnalysisTimePoint> points;
  final DateTime? windowStart;
  final DateTime? windowEnd;
  final int pointCount;

  const WindowState({
    required this.windowSize,
    required this.points,
    this.windowStart,
    this.windowEnd,
    required this.pointCount,
  });
}

/// Windowing discipline for streaming aggregation.
enum WindowKind {
  /// Continuous eviction — the window always covers the trailing
  /// [WindowAggregator.windowSize] behind the watermark.
  sliding,

  /// Epoch-aligned fixed intervals — accumulates within the current
  /// interval and resets when a point crosses the boundary; aggregates
  /// read as interval-so-far.
  tumbling,
}

/// Maintains sliding window state for streaming alert evaluation.
///
/// INCREMENTAL: aggregates are maintained as running state on add/evict, so
/// [add] is amortized O(1) and [aggregate] is O(1) regardless of window
/// occupancy. The previous implementation rescanned every live point per
/// aggregate call and evicted with `removeWhere` — measured on the bench
/// harness that collapsed to ~781 points/s at 100K occupancy (1.28 ms/point,
/// emit p95 17.5 ms), which cannot sustain even a 1 kHz stream.
///
/// - sum / avg / count — Kahan-compensated running sum (eviction subtracts
///   through the same compensated accumulator; the accumulator resets to
///   exactly zero whenever the window empties, bounding drift).
/// - std — running compensated sum-of-squares (`(Σx² − n·x̄²)/(n−1)`). This
///   one-pass form trades the two-pass version's cancellation resistance for
///   O(1) updates; the regression suite pins the drift against the naive
///   recomputation on long streams.
/// - min / max — monotonic deques keyed by insertion sequence, amortized O(1).
///
/// Points are expected in non-decreasing time order (the streaming contract;
/// eviction pops expired points from the FRONT). Exact out-of-order handling
/// is layered on top via [ReorderBuffer]; the aggregator itself tolerates
/// disorder gracefully — expiry runs against the max event time seen (the
/// watermark), a point already older than the watermark window is dropped
/// (counted in [lateDropped]), and the running aggregates are
/// order-independent so an in-window stray only means slightly-late eviction.
///
/// Streaming-semantics knobs:
/// - [kind] — [WindowKind.sliding] (default) evicts continuously;
///   [WindowKind.tumbling] accumulates epoch-aligned fixed intervals and
///   resets at each boundary (aggregates read as interval-so-far).
/// - [maxPoints] — bounded-buffer cap: on overflow the oldest point is
///   evicted immediately and counted in [overflowDropped], keeping memory
///   at rate-independent O(maxPoints).
class WindowAggregator {
  final Duration windowSize;

  /// Sliding (continuous eviction) or tumbling (interval reset).
  final WindowKind kind;

  /// Bounded-buffer cap; null = unbounded (memory grows with rate×window).
  final int? maxPoints;

  /// Points dropped because they arrived older than the watermark window.
  int lateDropped = 0;

  /// Points evicted early because the [maxPoints] cap was hit.
  int overflowDropped = 0;

  /// Max event time seen — the watermark expiry runs against.
  DateTime? _maxT;

  /// Tumbling: epoch-aligned start of the interval being accumulated.
  DateTime? _bucketStart;

  // Live points occupy _points[_head..]; eviction advances _head and the
  // backing list is compacted once the dead prefix dominates, keeping add
  // amortized O(1) without shifting on every eviction.
  final List<AnalysisTimePoint> _points = [];
  int _head = 0;

  // Sequence number of _points[_head] — monotonic deque entries are keyed by
  // sequence so eviction can pop them without searching.
  int _headSeq = 0;

  // Kahan-compensated running aggregates over live points.
  double _sum = 0.0, _sumComp = 0.0;
  double _sumSq = 0.0, _sumSqComp = 0.0;

  // Monotonic deques: _minDeque values are non-decreasing front→back,
  // _maxDeque values are non-increasing front→back.
  final Queue<_SeqValue> _minDeque = Queue<_SeqValue>();
  final Queue<_SeqValue> _maxDeque = Queue<_SeqValue>();

  WindowAggregator({
    required this.windowSize,
    this.kind = WindowKind.sliding,
    this.maxPoints,
  });

  int get _count => _points.length - _head;

  /// Add a data point to the window. Evicts expired points.
  void add(AnalysisTimePoint point) {
    final maxT =
        (_maxT == null || point.t.isAfter(_maxT!)) ? point.t : _maxT!;
    _maxT = maxT;

    if (kind == WindowKind.tumbling) {
      // Epoch-aligned interval: crossing a boundary resets the window.
      final bucketStart = _bucketStartFor(point.t);
      if (_bucketStart == null || bucketStart.isAfter(_bucketStart!)) {
        _clearWindow();
        _bucketStart = bucketStart;
      } else if (bucketStart.isBefore(_bucketStart!)) {
        // Belongs to an already-closed interval.
        lateDropped++;
        return;
      }
    } else {
      // Watermark gate: a point already expired relative to the max event
      // time seen never enters the window.
      if (point.t.isBefore(maxT.subtract(windowSize))) {
        lateDropped++;
        return;
      }
    }

    _points.add(point);
    final seq = _headSeq + (_count - 1);
    // Non-numeric values coerce to 0.0 and still occupy the window — this
    // mirrors the original aggregation semantics exactly.
    final x = point.v is num ? (point.v as num).toDouble() : 0.0;

    _kahanAddSum(x);
    _kahanAddSumSq(x * x);

    while (_minDeque.isNotEmpty && _minDeque.last.value >= x) {
      _minDeque.removeLast();
    }
    _minDeque.addLast(_SeqValue(seq, x));
    while (_maxDeque.isNotEmpty && _maxDeque.last.value <= x) {
      _maxDeque.removeLast();
    }
    _maxDeque.addLast(_SeqValue(seq, x));

    if (kind == WindowKind.sliding) {
      _evictExpired();
    }

    final cap = maxPoints;
    if (cap != null) {
      while (_count > cap) {
        _evictFront();
        overflowDropped++;
      }
      _maybeCompact();
    }
  }

  /// Get current window state.
  WindowState get state {
    final live = _head == 0 ? _points : _points.sublist(_head);
    return WindowState(
      windowSize: windowSize,
      points: List.unmodifiable(live),
      windowStart: _count > 0 ? _points[_head].t : null,
      windowEnd: _count > 0 ? _points.last.t : null,
      pointCount: _count,
    );
  }

  /// Compute aggregate value for a column. O(1).
  double aggregate(String column, String aggregation) {
    final n = _count;
    if (n == 0) return 0.0;

    switch (aggregation) {
      case 'avg':
        return _sum / n;
      case 'min':
        return _minDeque.first.value;
      case 'max':
        return _maxDeque.first.value;
      case 'sum':
        return _sum;
      case 'count':
        return n.toDouble();
      case 'std':
        if (n < 2) return 0.0;
        final mean = _sum / n;
        final variance =
            math.max(0.0, (_sumSq - n * mean * mean) / (n - 1));
        return math.sqrt(variance);
      default:
        return 0.0;
    }
  }

  /// Reset window state.
  void reset() {
    _clearWindow();
    _maxT = null;
    _bucketStart = null;
    lateDropped = 0;
    overflowDropped = 0;
  }

  DateTime _bucketStartFor(DateTime t) {
    final w = windowSize.inMicroseconds;
    final us = t.microsecondsSinceEpoch;
    return DateTime.fromMicrosecondsSinceEpoch(us - (us % w), isUtc: t.isUtc);
  }

  void _clearWindow() {
    _points.clear();
    _head = 0;
    _headSeq = 0;
    _sum = 0.0;
    _sumComp = 0.0;
    _sumSq = 0.0;
    _sumSqComp = 0.0;
    _minDeque.clear();
    _maxDeque.clear();
  }

  /// Evict the single front (oldest-arrival) point from the running state.
  void _evictFront() {
    final evicted = _points[_head];
    final x = evicted.v is num ? (evicted.v as num).toDouble() : 0.0;
    _kahanAddSum(-x);
    _kahanAddSumSq(-(x * x));
    if (_minDeque.isNotEmpty && _minDeque.first.seq == _headSeq) {
      _minDeque.removeFirst();
    }
    if (_maxDeque.isNotEmpty && _maxDeque.first.seq == _headSeq) {
      _maxDeque.removeFirst();
    }
    _head++;
    _headSeq++;
  }

  void _evictExpired() {
    if (_count == 0) return;
    final cutoff = _maxT!.subtract(windowSize);
    while (_count > 0 && _points[_head].t.isBefore(cutoff)) {
      _evictFront();
    }
    _maybeCompact();
  }

  void _maybeCompact() {
    if (_count == 0) {
      // Empty window — snap accumulated floating error back to exact zero.
      _points.clear();
      _head = 0;
      _sum = 0.0;
      _sumComp = 0.0;
      _sumSq = 0.0;
      _sumSqComp = 0.0;
    } else if (_head > 1024 && _head * 2 > _points.length) {
      // Compact the dead prefix once it dominates (amortized O(1) per add).
      _points.removeRange(0, _head);
      _head = 0;
    }
  }

  void _kahanAddSum(double x) {
    final y = x - _sumComp;
    final t = _sum + y;
    _sumComp = (t - _sum) - y;
    _sum = t;
  }

  void _kahanAddSumSq(double x) {
    final y = x - _sumSqComp;
    final t = _sumSq + y;
    _sumSqComp = (t - _sumSq) - y;
    _sumSq = t;
  }
}

class _SeqValue {
  final int seq;
  final double value;
  const _SeqValue(this.seq, this.value);
}
