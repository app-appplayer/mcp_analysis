import 'dart:async';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';

// ============================================================================
// Storage Mock
// ============================================================================

/// In-memory StoragePort for testing.
class InMemoryStorage<T> implements StoragePort<T> {
  final Map<String, T> _store = {};
  bool shouldThrow = false;
  String throwMessage = 'Storage error';

  @override
  Future<void> save(String id, T item) async {
    if (shouldThrow) throw Exception(throwMessage);
    _store[id] = item;
  }

  @override
  Future<T?> get(String id) async {
    if (shouldThrow) throw Exception(throwMessage);
    return _store[id];
  }

  @override
  Future<void> delete(String id) async {
    _store.remove(id);
  }

  @override
  Future<List<T>> getAll() async {
    return _store.values.toList();
  }

  @override
  Future<List<T>> query(Map<String, dynamic> criteria) async {
    return _store.values.toList();
  }

  @override
  Future<bool> exists(String id) async {
    return _store.containsKey(id);
  }

  int get length => _store.length;
  void clear() => _store.clear();
}

// ============================================================================
// EventPort Mock
// ============================================================================

/// Records published events for verification.
class MockEventPort implements EventPort {
  final List<PortEvent> publishedEvents = [];
  bool shouldThrow = false;
  final _controllers = <String, StreamController<PortEvent>>{};

  @override
  Future<void> publish(PortEvent event) async {
    if (shouldThrow) throw Exception('EventPort error');
    publishedEvents.add(event);
  }

  @override
  Stream<PortEvent> subscribe(String eventType) {
    _controllers[eventType] ??= StreamController<PortEvent>.broadcast();
    return _controllers[eventType]!.stream;
  }

  @override
  Stream<PortEvent> subscribeAll() {
    return const Stream.empty();
  }

  @override
  Future<void> unsubscribe(String eventType) async {
    await _controllers[eventType]?.close();
    _controllers.remove(eventType);
  }
}

// ============================================================================
// MetricPort Mock
// ============================================================================

class MockMetricPort implements MetricPort {
  final List<({String name, double value, Map<String, String>? tags})>
      recordedMetrics = [];

  @override
  Future<MetricValue> compute(
    String metricName,
    Map<String, dynamic> context,
  ) async {
    return MetricValue(value: 0.0, timestamp: DateTime.now());
  }

  @override
  Future<void> record(
    String metricName,
    double value, {
    Map<String, String>? tags,
  }) async {
    recordedMetrics.add((name: metricName, value: value, tags: tags));
  }

  @override
  Stream<MetricEvent> watch(String metricName) {
    return const Stream.empty();
  }

  @override
  Future<List<MetricValue>> history(
    String metricName, {
    DateTime? start,
    DateTime? end,
    int? limit,
  }) async {
    return [];
  }
}

// ============================================================================
// AnalysisPort Mock
// ============================================================================

class MockAnalysisPort implements AnalysisPort {
  final List<AnalysisSpec> specs;
  final Map<String, AnalysisJob> jobs;
  final List<AnalysisArtifact> artifacts;

  MockAnalysisPort({
    List<AnalysisSpec>? specs,
    Map<String, AnalysisJob>? jobs,
    List<AnalysisArtifact>? artifacts,
  })  : specs = specs ?? [],
        jobs = jobs ?? {},
        artifacts = artifacts ?? [];

  @override
  Future<List<AnalysisSpec>> listSpecs({
    String? search,
    int? limit,
    int? offset,
  }) async {
    var results = List<AnalysisSpec>.from(specs);
    if (search != null) {
      results = results
          .where((s) => s.specId.contains(search))
          .toList();
    }
    if (offset != null && offset < results.length) {
      results = results.sublist(offset);
    }
    if (limit != null && limit < results.length) {
      results = results.sublist(0, limit);
    }
    return results;
  }

  @override
  Future<AnalysisJob> runAnalysis({
    required String specId,
    required Map<String, dynamic> parameters,
    AnalysisExecutionMode mode = AnalysisExecutionMode.batch,
    AnalysisTimeRange? timeRange,
  }) async {
    final job = AnalysisJob(
      jobId: 'job-mock-001',
      specId: specId,
      specVersion: '1.0.0',
      mode: mode,
      status: AnalysisJobStatus.completed,
      progress: 1.0,
      createdAt: DateTime.now(),
      parameters: parameters,
    );
    jobs[job.jobId] = job;
    return job;
  }

  @override
  Future<AnalysisJob?> getJob(String jobId) async {
    return jobs[jobId];
  }

  @override
  Future<List<AnalysisArtifact>> getArtifacts({
    String? jobId,
    String? specId,
    AnalysisArtifactType? type,
    List<String>? tags,
    AnalysisTimeRange? timeRange,
    int? limit,
  }) async {
    return artifacts;
  }

  @override
  Future<AnalysisSpec> createSpec(AnalysisSpec spec) async {
    specs.add(spec);
    return spec;
  }

  @override
  Future<AnalysisSpec> updateSpec(String specId, AnalysisSpec spec) async {
    specs.removeWhere((s) => s.specId == specId);
    specs.add(spec);
    return spec;
  }

  @override
  Future<AnalysisAlert> evaluateAlert(String alertRuleId) async {
    return AnalysisAlert(
      alertRuleId: alertRuleId,
      severity: AnalysisAlertSeverity.warn,
      timestamp: DateTime.now(),
      condition: 'value > 0',
      currentValue: 1.0,
      triggered: true,
    );
  }
}

// ============================================================================
// AlertFormPort Mock
// ============================================================================

/// Records generated report calls for verification.
class MockAlertFormPort implements AlertFormPort {
  final List<({String templateId, Map<String, dynamic> context})> calls = [];
  bool shouldThrow = false;

  @override
  Future<void> generateReport(
    String templateId,
    Map<String, dynamic> context,
  ) async {
    if (shouldThrow) throw Exception('FormPort generateReport error');
    calls.add((templateId: templateId, context: context));
  }
}
