import 'dart:async';

import 'package:mcp_bundle/ports.dart';

import '../../feat/alert/alert_evaluator.dart';
import '../../feat/alert/reorder_buffer.dart';
import '../../feat/alert/window_aggregator.dart';
import '../../feat/datasource/datasource_registry.dart';
import '../../feat/transform/transform_pipeline.dart';
import '../artifact/artifact_builder.dart';
import '../artifact/artifact_store.dart';
import '../artifact/provenance_tracker.dart';
import 'job_manager.dart';
import 'step_logger.dart';

/// Executes analysis in streaming mode against real-time data.
class StreamExecutor {
  final DataSourceRegistry _dataSourceRegistry;
  final TransformPipeline _transformPipeline;
  final ArtifactBuilder _artifactBuilder;
  final ArtifactStore _artifactStore;
  final ProvenanceTracker _provenanceTracker;
  final AlertEvaluator _alertEvaluator;
  final JobManager _jobManager;

  StreamExecutor({
    required DataSourceRegistry dataSourceRegistry,
    required TransformPipeline transformPipeline,
    required ArtifactBuilder artifactBuilder,
    required ArtifactStore artifactStore,
    required ProvenanceTracker provenanceTracker,
    required AlertEvaluator alertEvaluator,
    required JobManager jobManager,
  })  : _dataSourceRegistry = dataSourceRegistry,
        _transformPipeline = transformPipeline,
        _artifactBuilder = artifactBuilder,
        _artifactStore = artifactStore,
        _provenanceTracker = provenanceTracker,
        _alertEvaluator = alertEvaluator,
        _jobManager = jobManager;

  /// Execute a streaming analysis job.
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    final stepLogger = StepLogger();
    final errors = <AnalysisError>[];
    final artifactIds = <String>[];
    StreamSubscription<AnalysisDataSet>? subscription;
    Timer? emitTimer;

    final windowSize = _parseWindowSize(
      resolvedParams['windowSize'] as String? ?? '5m',
    );
    final emitInterval = _parseDuration(
      resolvedParams['emitInterval'] as String? ?? '1m',
    );
    // Streaming-semantics knobs (all optional; defaults preserve the
    // original behavior):
    // - windowKind: 'sliding' (default) | 'tumbling'
    // - maxWindowPoints: bounded-buffer cap (int)
    // - allowedLateness: e.g. '10s' — enables watermark reordering so
    //   out-of-order arrivals within that span are re-sequenced instead of
    //   degrading window membership.
    final windowKind = (resolvedParams['windowKind'] as String?) == 'tumbling'
        ? WindowKind.tumbling
        : WindowKind.sliding;
    final maxWindowPoints = (resolvedParams['maxWindowPoints'] as num?)?.toInt();
    final allowedLatenessSpec = resolvedParams['allowedLateness'] as String?;
    final reorder = allowedLatenessSpec == null
        ? null
        : ReorderBuffer(allowedLateness: _parseDuration(allowedLatenessSpec));
    final windowAggregator = WindowAggregator(
      windowSize: windowSize,
      kind: windowKind,
      maxPoints: maxWindowPoints,
    );

    try {
      // Subscribe to data stream
      if (spec.inputSources.isEmpty) {
        return _jobManager.failJob(
          job.jobId,
          errors: [
            AnalysisError(
              code: 'source.unavailable',
              message: 'No input sources defined for streaming',
              timestamp: DateTime.now(),
            ),
          ],
        );
      }

      final source = spec.inputSources.first;
      final stream = _dataSourceRegistry.subscribeStream(
        sourceType: source.sourceType,
        query: source.query ?? '',
      );

      final completer = Completer<AnalysisJob>();
      var isCanceled = false;

      // Periodic artifact emission timer
      emitTimer = Timer.periodic(emitInterval, (_) async {
        await _emitPeriodicArtifacts(
          job, spec, windowAggregator, resolvedParams,
        );
      });

      _jobManager.registerCancelHandler(job.jobId, () {
        isCanceled = true;
        emitTimer?.cancel();
        subscription?.cancel();
      });

      subscription = stream.listen(
        (dataSet) async {
          if (isCanceled) return;

          // Add points to window — through the reorder buffer when
          // `allowedLateness` is configured (restores event-time order for
          // out-of-order arrivals), directly otherwise.
          for (final row in dataSet.rows) {
            final timestamp =
                row['_timestamp'] is DateTime
                    ? row['_timestamp'] as DateTime
                    : DateTime.now();
            final value = row.values.firstWhere(
              (v) => v is num,
              orElse: () => 0.0,
            );
            final point = AnalysisTimePoint(t: timestamp, v: value);
            if (reorder == null) {
              windowAggregator.add(point);
            } else {
              for (final released in reorder.add(point)) {
                windowAggregator.add(released);
              }
            }
          }

          // Apply transforms on window data
          var windowData = AnalysisDataSet(
            columns: dataSet.columns,
            rows: windowAggregator.state.points
                .map((p) => <String, dynamic>{'_timestamp': p.t, 'value': p.v})
                .toList(),
            rowCount: windowAggregator.state.pointCount,
          );

          if (spec.transforms.isNotEmpty) {
            try {
              final result = await _transformPipeline.execute(
                windowData,
                spec.transforms,
              );
              windowData = result.dataSet;
            } catch (_) {
              // Transform errors in streaming are non-blocking
            }
          }

          // Evaluate alerts
          final alertArtifacts = <AnalysisAlertRuleArtifact>[];
          for (final output in spec.outputs) {
            if (output.type == AnalysisArtifactType.alert) {
              final provenance = _provenanceTracker.createProvenance(
                specId: spec.specId,
                specVersion: spec.version,
                inputSources: spec.inputSources,
                inputTimeRange: null,
                parameters: resolvedParams,
              );
              final alertArtifact = _artifactBuilder.buildAlertRule(
                jobId: job.jobId,
                name: output.name,
                condition: output.parameters?['condition'] as String? ??
                    'value > 0',
                severity: AnalysisAlertSeverity.warn,
                provenance: provenance,
              );
              alertArtifacts.add(alertArtifact);
            }
          }

          if (alertArtifacts.isNotEmpty) {
            try {
              await _alertEvaluator.evaluateAll(alertArtifacts, windowData);
            } catch (_) {
              // Alert errors in streaming are non-blocking
            }
          }
        },
        onError: (Object error) {
          stepLogger.logStep(
            step: 'stream:error',
            inputSize: 0,
            outputSize: 0,
            executionTime: Duration.zero,
          );
          _jobManager.addError(job.jobId, AnalysisError(
            code: 'stream.error',
            message: 'Stream processing error: $error',
            step: 'stream:error',
            timestamp: DateTime.now(),
          ));
        },
        onDone: () async {
          emitTimer?.cancel();
          if (reorder != null) {
            for (final released in reorder.flush()) {
              windowAggregator.add(released);
            }
          }
          if (!completer.isCompleted) {
            // Merge locally tracked errors with errors accumulated via addError()
            final currentJob = await _jobManager.getJob(job.jobId);
            final allErrors = [
              ...?currentJob?.errors,
              ...errors,
            ];
            final completedJob = await _jobManager.completeJob(
              job.jobId,
              artifactIds: artifactIds,
              logs: stepLogger.logs,
              errors: allErrors,
            );
            stepLogger.clear();
            completer.complete(completedJob);
          }
        },
      );

      // For streaming, return the running job immediately
      // Job is already started by ExecutionEngine, just return current state
      return (await _jobManager.getJob(job.jobId))!;
    } catch (e) {
      emitTimer?.cancel();
      subscription?.cancel();
      final failedJob = await _jobManager.failJob(
        job.jobId,
        errors: [
          ...errors,
          AnalysisError(
            code: 'analysis.execution_error',
            message: 'Streaming execution failed: $e',
            timestamp: DateTime.now(),
          ),
        ],
        logs: stepLogger.logs,
      );
      stepLogger.clear();
      return failedJob;
    }
  }

  /// Emit periodic metric/series artifacts from window state.
  Future<void> _emitPeriodicArtifacts(
    AnalysisJob job,
    AnalysisSpec spec,
    WindowAggregator aggregator,
    Map<String, dynamic> parameters,
  ) async {
    if (aggregator.state.pointCount == 0) return;

    final provenance = _provenanceTracker.createProvenance(
      specId: spec.specId,
      specVersion: spec.version,
      inputSources: spec.inputSources,
      inputTimeRange: null,
      parameters: parameters,
    );

    final artifacts = _artifactBuilder.buildFromOutputDefs(
      jobId: job.jobId,
      outputDefs: spec.outputs
          .where((o) =>
              o.type == AnalysisArtifactType.metric ||
              o.type == AnalysisArtifactType.series)
          .toList(),
      functionResults: {
        'windowState': aggregator.state,
        'pointCount': aggregator.state.pointCount,
        'lateDropped': aggregator.lateDropped,
        'overflowDropped': aggregator.overflowDropped,
      },
      provenance: provenance,
    );

    if (artifacts.isNotEmpty) {
      await _artifactStore.saveAll(artifacts);
    }
  }

  /// Parse a window size string (e.g., '5m', '1h', '30s') into a Duration.
  Duration _parseWindowSize(String windowSpec) {
    return _parseDuration(windowSpec);
  }

  /// Parse a duration string (e.g., '5m', '1h', '30s') into a Duration.
  Duration _parseDuration(String durationSpec) {
    final trimmed = durationSpec.trim().toLowerCase();
    if (trimmed.isEmpty) return const Duration(minutes: 5);

    final match = RegExp(r'^(\d+)\s*([smh])$').firstMatch(trimmed);
    if (match == null) return const Duration(minutes: 5);

    final value = int.parse(match.group(1)!);
    final unit = match.group(2)!;

    switch (unit) {
      case 's':
        return Duration(seconds: value);
      case 'm':
        return Duration(minutes: value);
      case 'h':
        return Duration(hours: value);
      default:
        return Duration(minutes: value);
    }
  }
}
