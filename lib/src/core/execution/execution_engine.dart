import 'package:mcp_bundle/ports.dart';

import '../../infra/governance/audit_logger.dart';
import '../../infra/governance/rbac_policy.dart';
import '../spec/spec_manager.dart';
import 'adhoc_executor.dart';
import 'batch_executor.dart';
import 'job_manager.dart';
import 'execution_operations.dart';
import 'stream_executor.dart';

/// Central orchestrator for analysis execution.
/// Dispatches to mode-specific executors after governance checks.
class ExecutionEngine implements ExecutionOperations {
  final SpecManager _specManager;
  final JobManager _jobManager;
  final BatchExecutor _batchExecutor;
  final AdhocExecutor _adhocExecutor;
  final StreamExecutor _streamExecutor;
  final RbacPolicy _rbac;
  final AuditLogger _auditLogger;
  final MetricPort _metricPort;

  ExecutionEngine({
    required SpecManager specManager,
    required JobManager jobManager,
    required BatchExecutor batchExecutor,
    required AdhocExecutor adhocExecutor,
    required StreamExecutor streamExecutor,
    required RbacPolicy rbac,
    required AuditLogger auditLogger,
    required MetricPort metricPort,
  })  : _specManager = specManager,
        _jobManager = jobManager,
        _batchExecutor = batchExecutor,
        _adhocExecutor = adhocExecutor,
        _streamExecutor = streamExecutor,
        _rbac = rbac,
        _auditLogger = auditLogger,
        _metricPort = metricPort;

  /// Execute an analysis. Main entry point.
  /// 1. Resolve Spec + parameters
  /// 2. Check RBAC permissions
  /// 3. Create Job
  /// 4. Dispatch to mode-specific executor
  /// 5. Record audit log + operational metrics
  Future<AnalysisJob> runAnalysis({
    required String specId,
    required Map<String, dynamic> parameters,
    AnalysisExecutionMode mode = AnalysisExecutionMode.batch,
    AnalysisTimeRange? timeRange,
    RbacContext? rbacContext,
  }) async {
    final sw = Stopwatch()..start();

    // 1. Resolve Spec
    final spec = await _specManager.getSpec(specId);
    if (spec == null) {
      throw AnalysisError(
        code: 'spec.not_found',
        message: 'Spec "$specId" not found',
        details: {'specId': specId},
      );
    }

    // 2. Resolve parameters
    final resolvedParams = _specManager.resolveParameters(spec, parameters);

    // 3. Check RBAC permissions
    if (rbacContext != null) {
      await _rbac.canExecute(rbacContext, specId);
    }

    // 4. Create Job
    final job = await _jobManager.createJob(
      specId: specId,
      specVersion: spec.version,
      mode: mode,
      parameters: resolvedParams,
      timeRange: timeRange,
    );

    // 5. Start job and dispatch to executor
    await _jobManager.startJob(job.jobId);

    try {
      final AnalysisJob completedJob;

      switch (mode) {
        case AnalysisExecutionMode.batch:
          completedJob = await _batchExecutor.execute(
            job: job,
            spec: spec,
            resolvedParams: resolvedParams,
          );
          break;
        case AnalysisExecutionMode.adhoc:
          completedJob = await _adhocExecutor.execute(
            job: job,
            spec: spec,
            resolvedParams: resolvedParams,
          );
          break;
        case AnalysisExecutionMode.streaming:
          completedJob = await _streamExecutor.execute(
            job: job,
            spec: spec,
            resolvedParams: resolvedParams,
          );
          break;
      }

      sw.stop();

      // 6. Record audit + metrics
      await _recordAuditAndMetrics(
        actorId: rbacContext?.actorId ?? 'system',
        specId: specId,
        jobId: job.jobId,
        mode: mode,
        timeRange: timeRange,
        parameters: resolvedParams,
        durationMs: sw.elapsedMilliseconds,
        completedJob: completedJob,
        failed: false,
      );

      return completedJob;
    } catch (e) {
      sw.stop();

      // Record failure in audit
      await _recordAuditAndMetrics(
        actorId: rbacContext?.actorId ?? 'system',
        specId: specId,
        jobId: job.jobId,
        mode: mode,
        timeRange: timeRange,
        parameters: resolvedParams,
        durationMs: sw.elapsedMilliseconds,
        failed: true,
      );

      if (e is AnalysisError) {
        await _jobManager.failJob(job.jobId, errors: [e]);
        rethrow;
      }
      final error = AnalysisError(
        code: 'analysis.execution_error',
        message: 'Execution failed: $e',
        timestamp: DateTime.now(),
      );
      await _jobManager.failJob(job.jobId, errors: [error]);
      rethrow;
    }
  }

  /// Get Job status and results.
  Future<AnalysisJob?> getJob(String jobId) async {
    return _jobManager.getJob(jobId);
  }

  /// Cancel a running Job.
  Future<AnalysisJob> cancelJob(String jobId, {RbacContext? rbacContext}) async {
    if (rbacContext != null) {
      final job = await _jobManager.getJob(jobId);
      if (job == null) {
        throw AnalysisError(
          code: 'job.not_found',
          message: 'Job "$jobId" not found',
        );
      }

      // Check cancel permission
      final isSameActor =
          job.parameters['_actorId'] == rbacContext.actorId;
      final operation =
          isSameActor ? 'cancel_own_job' : 'cancel_any_job';
      await _rbac.checkPermission(
        context: rbacContext,
        operation: operation,
        resourceId: jobId,
      );
    }

    return _jobManager.cancelJob(jobId);
  }

  Future<void> _recordAuditAndMetrics({
    required String actorId,
    required String specId,
    required String jobId,
    required AnalysisExecutionMode mode,
    required AnalysisTimeRange? timeRange,
    required Map<String, dynamic> parameters,
    required int durationMs,
    AnalysisJob? completedJob,
    bool failed = false,
  }) async {
    // Audit log (non-blocking)
    try {
      await _auditLogger.recordExecution(
        actorId: actorId,
        specId: specId,
        jobId: jobId,
        inputRange: timeRange,
        parameters: parameters,
      );
    } catch (_) {
      // Audit failures are non-blocking per NFR requirements
    }

    // Operational metrics (non-blocking)
    final tags = {
      'specId': specId,
      'mode': mode.name,
    };

    try {
      await _metricPort.record(
        'analysis.job_duration_ms',
        durationMs.toDouble(),
        tags: tags,
      );

      // Record throughput (artifacts produced per second)
      final artifactCount = completedJob?.artifactIds.length ?? 0;
      final throughput = durationMs > 0
          ? (artifactCount / (durationMs / 1000.0))
          : 0.0;
      await _metricPort.record(
        'analysis.throughput',
        throughput,
        tags: tags,
      );

      // Record failure rate (0.0 for success, 1.0 for failure)
      await _metricPort.record(
        'analysis.failure_rate',
        failed ? 1.0 : 0.0,
        tags: tags,
      );

      // Record alert count from completed job errors
      final alertCount = completedJob?.errors.length ?? 0;
      await _metricPort.record(
        'analysis.alert_count',
        alertCount.toDouble(),
        tags: tags,
      );
    } catch (_) {
      // Metric failures are non-blocking
    }
  }
}
