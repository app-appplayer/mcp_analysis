import 'package:mcp_bundle/ports.dart';

import '../feat/alert/alert_evaluator.dart';
import '../feat/datasource/datasource_registry.dart';
import 'artifact/artifact_store.dart';
import 'execution/execution_engine.dart';
import 'spec/spec_manager.dart';

/// Public API entry point. Implements AnalysisPort by delegating
/// to internal modules. Pure facade — no business logic.
class AnalysisPortAdapter implements AnalysisPort {
  final SpecManager _specManager;
  final ExecutionEngine _executionEngine;
  final ArtifactStore _artifactStore;
  final DataSourceRegistry _dataSourceRegistry;
  final AlertEvaluator _alertEvaluator;

  AnalysisPortAdapter({
    required SpecManager specManager,
    required ExecutionEngine executionEngine,
    required ArtifactStore artifactStore,
    required DataSourceRegistry dataSourceRegistry,
    required AlertEvaluator alertEvaluator,
  })  : _specManager = specManager,
        _executionEngine = executionEngine,
        _artifactStore = artifactStore,
        _dataSourceRegistry = dataSourceRegistry,
        _alertEvaluator = alertEvaluator;

  /// Retrieve a single Spec by ID.
  Future<AnalysisSpec?> getSpec(String specId) async {
    return _specManager.getSpec(specId);
  }

  @override
  Future<List<AnalysisSpec>> listSpecs({
    String? search,
    int? limit,
    int? offset,
  }) {
    return _specManager.listSpecs(
      search: search,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<AnalysisSpec> createSpec(AnalysisSpec spec) {
    return _specManager.createSpec(spec);
  }

  @override
  Future<AnalysisSpec> updateSpec(String specId, AnalysisSpec spec) {
    return _specManager.updateSpec(specId, spec);
  }

  @override
  Future<AnalysisJob> runAnalysis({
    required String specId,
    required Map<String, dynamic> parameters,
    AnalysisExecutionMode mode = AnalysisExecutionMode.batch,
    AnalysisTimeRange? timeRange,
  }) {
    return _executionEngine.runAnalysis(
      specId: specId,
      parameters: parameters,
      mode: mode,
      timeRange: timeRange,
    );
  }

  @override
  Future<AnalysisJob?> getJob(String jobId) {
    return _executionEngine.getJob(jobId);
  }

  @override
  Future<List<AnalysisArtifact>> getArtifacts({
    String? jobId,
    String? specId,
    AnalysisArtifactType? type,
    List<String>? tags,
    AnalysisTimeRange? timeRange,
    int? limit,
  }) {
    return _artifactStore.query(
      jobId: jobId,
      specId: specId,
      type: type,
      tags: tags,
      timeRange: timeRange,
      limit: limit,
    );
  }

  /// Cancel a running Job.
  Future<AnalysisJob> cancelJob(String jobId) async {
    return _executionEngine.cancelJob(jobId);
  }

  @override
  Future<AnalysisAlert> evaluateAlert(String alertRuleId) async {
    // 1. Lookup the AlertRule artifact by ID
    final artifact = await _artifactStore.get(alertRuleId);
    if (artifact == null || artifact is! AnalysisAlertRuleArtifact) {
      throw AnalysisError(
        code: 'artifact.not_found',
        message: 'Alert rule artifact "$alertRuleId" not found',
        details: {'alertRuleId': alertRuleId},
      );
    }

    final rule = artifact;

    // 2. Resolve the original Spec from provenance
    final specId = rule.provenance.specId;
    final spec = await _specManager.getSpec(specId);

    if (spec == null) {
      throw AnalysisError(
        code: 'spec.not_found',
        message: 'Spec "$specId" for alert rule not found',
        details: {'specId': specId, 'alertRuleId': alertRuleId},
      );
    }

    // 3. Query current data from original sources
    AnalysisDataSet? currentData;
    for (final source in spec.inputSources) {
      try {
        currentData = await _dataSourceRegistry.queryData(
          sourceType: source.sourceType,
          query: source.query ?? '',
          filter: source.filter,
          timeRange: source.timeRange,
        );
        break;
      } catch (_) {
        // Try next source
      }
    }

    if (currentData == null) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'Could not query data for alert evaluation',
        details: {'alertRuleId': alertRuleId, 'specId': specId},
      );
    }

    // 4. Delegate to AlertEvaluator
    return _alertEvaluator.evaluate(rule, currentData);
  }
}
