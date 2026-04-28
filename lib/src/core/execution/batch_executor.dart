import 'package:mcp_bundle/ports.dart';

import '../../feat/alert/alert_evaluator.dart';
import '../../feat/datasource/datasource_registry.dart';
import '../../feat/function/function_dispatcher.dart';
import '../../feat/transform/transform_pipeline.dart';
import '../artifact/artifact_builder.dart';
import '../artifact/artifact_store.dart';
import '../artifact/provenance_tracker.dart';
import 'job_manager.dart';
import 'retry_policy.dart';
import 'step_logger.dart';

/// Executes analysis in batch mode against historical data.
/// Timeout: 30 minutes. Retry: 3 retries with exponential backoff.
class BatchExecutor {
  final DataSourceRegistry _dataSourceRegistry;
  final TransformPipeline _transformPipeline;
  final FunctionDispatcher _functionDispatcher;
  final ArtifactBuilder _artifactBuilder;
  final ArtifactStore _artifactStore;
  final ProvenanceTracker _provenanceTracker;
  final AlertEvaluator _alertEvaluator;
  final JobManager _jobManager;
  final RetryPolicy _retryPolicy;

  /// Batch execution timeout (default: 30 minutes).
  final Duration timeout;

  BatchExecutor({
    required DataSourceRegistry dataSourceRegistry,
    required TransformPipeline transformPipeline,
    required FunctionDispatcher functionDispatcher,
    required ArtifactBuilder artifactBuilder,
    required ArtifactStore artifactStore,
    required ProvenanceTracker provenanceTracker,
    required AlertEvaluator alertEvaluator,
    required JobManager jobManager,
    RetryPolicy? retryPolicy,
    this.timeout = const Duration(minutes: 30),
  })  : _dataSourceRegistry = dataSourceRegistry,
        _transformPipeline = transformPipeline,
        _functionDispatcher = functionDispatcher,
        _artifactBuilder = artifactBuilder,
        _artifactStore = artifactStore,
        _provenanceTracker = provenanceTracker,
        _alertEvaluator = alertEvaluator,
        _jobManager = jobManager,
        _retryPolicy = retryPolicy ?? const RetryPolicy();

  /// Execute a batch analysis job.
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    return Future(() => _executeInternal(
          job: job,
          spec: spec,
          resolvedParams: resolvedParams,
        )).timeout(
      timeout,
      onTimeout: () async {
        return _jobManager.failJob(
          job.jobId,
          errors: [
            AnalysisError(
              code: 'job.timeout',
              message:
                  'Batch execution timed out after ${timeout.inMinutes} minutes',
              timestamp: DateTime.now(),
            ),
          ],
        );
      },
    );
  }

  Future<AnalysisJob> _executeInternal({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    final stepLogger = StepLogger();
    final errors = <AnalysisError>[];
    final artifactIds = <String>[];

    try {
      // Phase 1: Data Acquisition (with retry for transient errors)
      await _jobManager.updateProgress(job.jobId, 0.25);
      final dataSets = <AnalysisDataSet>[];

      for (final source in spec.inputSources) {
        final sw = Stopwatch()..start();
        try {
          final dataSet = await _retryPolicy.withRetry(() async {
            return _dataSourceRegistry.queryData(
              sourceType: source.sourceType,
              query: source.query ?? '',
              filter: source.filter,
              timeRange: source.timeRange ?? job.inputRange,
            );
          });
          sw.stop();
          dataSets.add(dataSet);
          stepLogger.logStep(
            step: 'source:${source.sourceType.name}',
            inputSize: 0,
            outputSize: dataSet.rowCount,
            executionTime: sw.elapsed,
          );
        } catch (e) {
          sw.stop();
          errors.add(AnalysisError(
            code: e is AnalysisError ? e.code : 'source.unavailable',
            message: 'Failed to query source: $e',
            step: 'source:${source.sourceType.name}',
            timestamp: DateTime.now(),
          ));
        }
      }

      if (dataSets.isEmpty) {
        return _jobManager.failJob(
          job.jobId,
          errors: [
            AnalysisError(
              code: 'source.unavailable',
              message: 'All data sources failed',
              timestamp: DateTime.now(),
            ),
            ...errors,
          ],
          logs: stepLogger.logs,
        );
      }

      // Merge data sets: column union, null fill, timestamp sort
      var currentData = _mergeDataSets(dataSets);

      // Phase 2: Transform
      if (spec.transforms.isNotEmpty) {
        final sw = Stopwatch()..start();
        final transformResult = await _transformPipeline.execute(
          currentData,
          spec.transforms,
        );
        sw.stop();
        currentData = transformResult.dataSet;
        stepLogger.logStep(
          step: 'transform:pipeline',
          inputSize: dataSets.fold(0, (sum, ds) => sum + ds.rowCount),
          outputSize: currentData.rowCount,
          executionTime: sw.elapsed,
        );
      }
      await _jobManager.updateProgress(job.jobId, 0.50);

      // Phase 3: Analysis Functions
      final functionResults = <String, dynamic>{};
      for (final step in spec.analysisSteps) {
        final sw = Stopwatch()..start();
        final result = await _functionDispatcher.executeFunction(
          functionName: step.function,
          parameters: step.parameters,
          data: currentData,
        );
        sw.stop();
        functionResults[step.function] = result.results;
        stepLogger.logStep(
          step: 'function:${step.function}',
          inputSize: currentData.rowCount,
          outputSize: result.results.length,
          executionTime: sw.elapsed,
        );
      }
      await _jobManager.updateProgress(job.jobId, 0.75);

      // Phase 4: Artifact Building
      final provenance = _provenanceTracker.createProvenance(
        specId: spec.specId,
        specVersion: spec.version,
        inputSources: spec.inputSources,
        inputTimeRange: job.inputRange,
        parameters: resolvedParams,
      );

      final artifacts = _artifactBuilder.buildFromOutputDefs(
        jobId: job.jobId,
        outputDefs: spec.outputs,
        functionResults: functionResults,
        provenance: provenance,
      );

      await _artifactStore.saveAll(artifacts);
      artifactIds.addAll(artifacts.map((a) => a.artifactId));
      await _jobManager.updateProgress(job.jobId, 0.90);

      // Phase 5: Alert Evaluation
      final alertArtifacts =
          artifacts.whereType<AnalysisAlertRuleArtifact>().toList();
      if (alertArtifacts.isNotEmpty) {
        try {
          await _alertEvaluator.evaluateAll(alertArtifacts, currentData);
        } catch (e) {
          errors.add(AnalysisError(
            code: 'alert.evaluation_error',
            message: 'Alert evaluation failed: $e',
            step: 'alert:evaluate',
            timestamp: DateTime.now(),
          ));
        }
      }

      // Complete
      return _jobManager.completeJob(
        job.jobId,
        artifactIds: artifactIds,
        logs: stepLogger.logs,
        errors: errors,
      );
    } catch (e) {
      return _jobManager.failJob(
        job.jobId,
        errors: [
          ...errors,
          AnalysisError(
            code: 'analysis.execution_error',
            message: 'Batch execution failed: $e',
            timestamp: DateTime.now(),
          ),
        ],
        logs: stepLogger.logs,
      );
    }
  }

  /// Merge multiple datasets: column union, null fill, timestamp sort.
  AnalysisDataSet _mergeDataSets(List<AnalysisDataSet> dataSets) {
    if (dataSets.length == 1) return dataSets.first;

    // Column union
    final columnMap = <String, AnalysisColumnInfo>{};
    for (final ds in dataSets) {
      for (final col in ds.columns) {
        columnMap.putIfAbsent(col.name, () => col);
      }
    }
    final mergedColumns = columnMap.values.toList();
    final allColumnNames = columnMap.keys.toSet();

    // Concatenate rows with null fill for missing columns
    final mergedRows = <Map<String, dynamic>>[];
    for (final ds in dataSets) {
      for (final row in ds.rows) {
        final newRow = <String, dynamic>{};
        for (final colName in allColumnNames) {
          newRow[colName] = row[colName]; // null if missing
        }
        mergedRows.add(newRow);
      }
    }

    // Sort by _timestamp ascending
    mergedRows.sort((a, b) {
      final aTs = a['_timestamp'];
      final bTs = b['_timestamp'];
      if (aTs is DateTime && bTs is DateTime) return aTs.compareTo(bTs);
      if (aTs is DateTime) return -1;
      if (bTs is DateTime) return 1;
      return 0;
    });

    return AnalysisDataSet(
      columns: mergedColumns,
      rows: mergedRows,
      rowCount: mergedRows.length,
      metadata: {'mergedSourceCount': dataSets.length},
    );
  }
}
