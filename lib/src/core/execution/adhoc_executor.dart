import 'package:mcp_bundle/ports.dart';

import '../../feat/alert/alert_evaluator.dart';
import '../../feat/datasource/datasource_registry.dart';
import '../../feat/function/function_dispatcher.dart';
import '../../feat/transform/transform_pipeline.dart';
import '../artifact/artifact_builder.dart';
import '../artifact/artifact_store.dart';
import '../artifact/provenance_tracker.dart';
import 'job_manager.dart';
import 'source_merger.dart';
import 'step_input_resolver.dart';
import 'step_logger.dart';

/// Executes analysis in ad-hoc mode for fast, synchronous results.
/// Timeout: 5 minutes. No retry. No progress updates.
class AdhocExecutor {
  AdhocExecutor({
    required DataSourceRegistry dataSourceRegistry,
    required TransformPipeline transformPipeline,
    required FunctionDispatcher functionDispatcher,
    required ArtifactBuilder artifactBuilder,
    required ArtifactStore artifactStore,
    required ProvenanceTracker provenanceTracker,
    required AlertEvaluator alertEvaluator,
    required JobManager jobManager,
    this.timeout = const Duration(minutes: 5),
  })  : _dataSourceRegistry = dataSourceRegistry,
        _transformPipeline = transformPipeline,
        _functionDispatcher = functionDispatcher,
        _artifactBuilder = artifactBuilder,
        _artifactStore = artifactStore,
        _provenanceTracker = provenanceTracker,
        _alertEvaluator = alertEvaluator,
        _jobManager = jobManager;
  final DataSourceRegistry _dataSourceRegistry;
  final TransformPipeline _transformPipeline;
  final FunctionDispatcher _functionDispatcher;
  final ArtifactBuilder _artifactBuilder;
  final ArtifactStore _artifactStore;
  final ProvenanceTracker _provenanceTracker;
  final AlertEvaluator _alertEvaluator;
  final JobManager _jobManager;

  /// Ad-hoc execution timeout (default: 5 minutes).
  final Duration timeout;

  /// Execute an ad-hoc analysis job.
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
                  'Ad-hoc execution timed out after ${timeout.inMinutes} minutes',
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
      // Phase 1: Data Acquisition (no retry - fail fast)
      final dataSets = <AnalysisDataSet>[];

      for (final source in spec.inputSources) {
        final sw = Stopwatch()..start();
        try {
          final dataSet = await _dataSourceRegistry.queryData(
            sourceType: source.sourceType,
            query: source.query ?? '',
            filter: source.filter,
            timeRange: source.timeRange ?? job.inputRange,
          );
          sw.stop();
          // Aliases apply as the source is read, so everything
          // downstream sees the names the spec chose.
          dataSets.add(const SourceMerger().applyAliases(source, dataSet));
          stepLogger.logStep(
            step: 'source:${source.sourceType.name}',
            inputSize: 0,
            outputSize: dataSet.rowCount,
            executionTime: sw.elapsed,
          );
        } catch (e) {
          sw.stop();
          // Fail fast: do not collect errors and continue, and do not
          // retry either. Batch execution retries a transient source
          // failure because nobody is waiting on it; an ad-hoc run is
          // someone waiting, and three backoffs is seven seconds of
          // silence before the same answer.
          return _jobManager.failJob(
            job.jobId,
            errors: [
              AnalysisError(
                code: 'source.unavailable',
                message: 'Failed to query source: $e',
                step: 'source:${source.sourceType.name}',
                timestamp: DateTime.now(),
              ),
            ],
            logs: stepLogger.logs,
          );
        }
      }

      if (dataSets.isEmpty) {
        return _jobManager.failJob(
          job.jobId,
          errors: [
            AnalysisError(
              code: 'source.unavailable',
              message: 'No data sources defined',
              timestamp: DateTime.now(),
            ),
          ],
          logs: stepLogger.logs,
        );
      }

      // Merge data sets (same logic as batch)
      var currentData = const SourceMerger().merge(spec.inputSources, dataSets);

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

      // Phase 3: Analysis Functions
      final functionResults = <String, dynamic>{};
      for (final step in spec.analysisSteps) {
        final sw = Stopwatch()..start();
        // A step reads the source dataset unless it names an earlier
        // step's result field; the validator has already checked that the
        // name resolves and runs first.
        var stepData = step.input == null
            ? currentData
            : const StepInputResolver().resolve(step.input!, functionResults);
        // Spec-level transforms run once over the merged sources; a step's
        // own run here, which is the only place a reshaping between two
        // steps can go.
        if (step.transforms.isNotEmpty) {
          final beforeTransform = stepData.rowCount;
          final transformSw = Stopwatch()..start();
          final stepTransform = await _transformPipeline.execute(
            stepData,
            step.transforms,
          );
          transformSw.stop();
          stepData = stepTransform.dataSet;
          stepLogger.logStep(
            step: 'transform:${step.resultKey}',
            inputSize: beforeTransform,
            outputSize: stepData.rowCount,
            executionTime: transformSw.elapsed,
          );
        }
        final result = await _functionDispatcher.executeFunction(
          functionName: step.function,
          parameters: _resolveStepParams(step.parameters, resolvedParams),
          data: stepData,
        );
        sw.stop();
        functionResults[step.resultKey] = result.results;
        stepLogger.logStep(
          step: step.id == null
              ? 'function:${step.function}'
              : 'function:${step.function}#${step.id}',
          inputSize: stepData.rowCount,
          outputSize: result.results.length,
          executionTime: sw.elapsed,
        );
      }

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
        onSkipped: errors.add,
      );

      await _artifactStore.saveAll(artifacts);
      artifactIds.addAll(artifacts.map((a) => a.artifactId));

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

      // Complete synchronously
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
            message: 'Ad-hoc execution failed: $e',
            timestamp: DateTime.now(),
          ),
        ],
        logs: stepLogger.logs,
      );
    }
  }

  /// Merge step-level parameters with globally resolved parameters.
  /// Step params override resolved params.
  Map<String, dynamic> _resolveStepParams(
    Map<String, dynamic> stepParams,
    Map<String, dynamic> resolvedParams,
  ) {
    return {...resolvedParams, ...stepParams};
  }

  /// Merge multiple datasets: column union, null fill, timestamp sort.
}
