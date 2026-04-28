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

/// Maintains sliding window state for streaming alert evaluation.
class WindowAggregator {
  final Duration windowSize;
  final List<AnalysisTimePoint> _points = [];

  WindowAggregator({required this.windowSize});

  /// Add a data point to the window. Evicts expired points.
  void add(AnalysisTimePoint point) {
    _points.add(point);
    _evictExpired();
  }

  /// Get current window state.
  WindowState get state {
    return WindowState(
      windowSize: windowSize,
      points: List.unmodifiable(_points),
      windowStart: _points.isNotEmpty ? _points.first.t : null,
      windowEnd: _points.isNotEmpty ? _points.last.t : null,
      pointCount: _points.length,
    );
  }

  /// Compute aggregate value for a column.
  double aggregate(String column, String aggregation) {
    if (_points.isEmpty) return 0.0;

    final values = _points
        .map((p) => p.v is num ? (p.v as num).toDouble() : 0.0)
        .toList();

    switch (aggregation) {
      case 'avg':
        return values.reduce((a, b) => a + b) / values.length;
      case 'min':
        return values.reduce(math.min);
      case 'max':
        return values.reduce(math.max);
      case 'sum':
        return values.reduce((a, b) => a + b);
      case 'count':
        return values.length.toDouble();
      case 'std':
        if (values.length < 2) return 0.0;
        final mean = values.reduce((a, b) => a + b) / values.length;
        final variance =
            values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
                (values.length - 1);
        return math.sqrt(variance);
      default:
        return 0.0;
    }
  }

  /// Reset window state.
  void reset() => _points.clear();

  void _evictExpired() {
    if (_points.isEmpty) return;
    final cutoff = _points.last.t.subtract(windowSize);
    _points.removeWhere((p) => p.t.isBefore(cutoff));
  }
}
