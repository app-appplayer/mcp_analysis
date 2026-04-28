import 'dart:math';

import 'package:mcp_bundle/ports.dart';

import 'job_operations.dart';

/// Manages lifecycle of AnalysisJob instances.
class JobManager implements JobOperations {
  final StoragePort<AnalysisJob> _storage;
  final Map<String, void Function()> _cancelHandlers = {};
  final Random _random = Random();

  JobManager({required StoragePort<AnalysisJob> storage}) : _storage = storage;

  /// Create a new Job with unique ID.
  Future<AnalysisJob> createJob({
    required String specId,
    required String specVersion,
    required AnalysisExecutionMode mode,
    Map<String, dynamic> parameters = const {},
    AnalysisTimeRange? timeRange,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rnd = _random.nextInt(9999).toString().padLeft(4, '0');
    final jobId = 'job-$ts-$rnd';

    final job = AnalysisJob(
      jobId: jobId,
      specId: specId,
      specVersion: specVersion,
      mode: mode,
      status: AnalysisJobStatus.queued,
      progress: 0.0,
      createdAt: DateTime.now(),
      inputRange: timeRange,
      parameters: parameters,
    );

    await _storage.save(jobId, job);
    return job;
  }

  /// Transition job to running state.
  Future<AnalysisJob> startJob(String jobId) async {
    final job = await _storage.get(jobId);
    if (job == null) {
      throw AnalysisError(
        code: 'job.not_found',
        message: 'Job "$jobId" not found',
      );
    }

    final updated = AnalysisJob(
      jobId: job.jobId,
      specId: job.specId,
      specVersion: job.specVersion,
      mode: job.mode,
      status: AnalysisJobStatus.running,
      progress: 0.0,
      createdAt: job.createdAt,
      startTime: DateTime.now(),
      inputRange: job.inputRange,
      parameters: job.parameters,
    );

    await _storage.save(jobId, updated);
    return updated;
  }

  /// Update job progress.
  Future<void> updateProgress(String jobId, double progress) async {
    final job = await _storage.get(jobId);
    if (job == null) return;

    final updated = AnalysisJob(
      jobId: job.jobId,
      specId: job.specId,
      specVersion: job.specVersion,
      mode: job.mode,
      status: job.status,
      progress: progress.clamp(0.0, 1.0),
      createdAt: job.createdAt,
      startTime: job.startTime,
      inputRange: job.inputRange,
      parameters: job.parameters,
      artifactIds: job.artifactIds,
      logs: job.logs,
      errors: job.errors,
    );

    await _storage.save(jobId, updated);
  }

  /// Complete a job successfully.
  Future<AnalysisJob> completeJob(
    String jobId, {
    List<String> artifactIds = const [],
    List<AnalysisJobLog> logs = const [],
    List<AnalysisError> errors = const [],
  }) async {
    final job = await _storage.get(jobId);
    if (job == null) {
      throw AnalysisError(
        code: 'job.not_found',
        message: 'Job "$jobId" not found',
      );
    }

    final updated = AnalysisJob(
      jobId: job.jobId,
      specId: job.specId,
      specVersion: job.specVersion,
      mode: job.mode,
      status: AnalysisJobStatus.completed,
      progress: 1.0,
      createdAt: job.createdAt,
      startTime: job.startTime,
      endTime: DateTime.now(),
      inputRange: job.inputRange,
      parameters: job.parameters,
      artifactIds: artifactIds,
      logs: logs,
      errors: errors,
    );

    await _storage.save(jobId, updated);
    _cancelHandlers.remove(jobId);
    return updated;
  }

  /// Fail a job.
  Future<AnalysisJob> failJob(
    String jobId, {
    List<AnalysisError> errors = const [],
    List<AnalysisJobLog> logs = const [],
  }) async {
    final job = await _storage.get(jobId);
    if (job == null) {
      throw AnalysisError(
        code: 'job.not_found',
        message: 'Job "$jobId" not found',
      );
    }

    final updated = AnalysisJob(
      jobId: job.jobId,
      specId: job.specId,
      specVersion: job.specVersion,
      mode: job.mode,
      status: AnalysisJobStatus.failed,
      progress: job.progress,
      createdAt: job.createdAt,
      startTime: job.startTime,
      endTime: DateTime.now(),
      inputRange: job.inputRange,
      parameters: job.parameters,
      logs: logs,
      errors: errors,
    );

    await _storage.save(jobId, updated);
    _cancelHandlers.remove(jobId);
    return updated;
  }

  /// Cancel a job.
  Future<AnalysisJob> cancelJob(String jobId) async {
    final job = await _storage.get(jobId);
    if (job == null) {
      throw AnalysisError(
        code: 'job.not_found',
        message: 'Job "$jobId" not found',
      );
    }

    if (job.status != AnalysisJobStatus.queued &&
        job.status != AnalysisJobStatus.running) {
      throw AnalysisError(
        code: 'job.invalid_transition',
        message: 'Cannot cancel job in ${job.status.name} state',
      );
    }

    final cancelHandler = _cancelHandlers[jobId];
    if (cancelHandler != null) {
      cancelHandler();
    }

    final updated = AnalysisJob(
      jobId: job.jobId,
      specId: job.specId,
      specVersion: job.specVersion,
      mode: job.mode,
      status: AnalysisJobStatus.canceled,
      progress: job.progress,
      createdAt: job.createdAt,
      startTime: job.startTime,
      endTime: DateTime.now(),
      inputRange: job.inputRange,
      parameters: job.parameters,
      logs: job.logs,
      errors: [
        ...job.errors,
        AnalysisError(
          code: 'job.canceled',
          message: 'Job was canceled by user',
          timestamp: DateTime.now(),
        ),
      ],
    );

    await _storage.save(jobId, updated);
    _cancelHandlers.remove(jobId);
    return updated;
  }

  /// Append an error to a running Job without changing its status.
  /// Used for non-fatal errors in streaming mode.
  Future<void> addError(String jobId, AnalysisError error) async {
    final job = await _storage.get(jobId);
    if (job == null) {
      throw AnalysisError(
        code: 'job.not_found',
        message: 'Job "$jobId" not found',
      );
    }

    final updated = AnalysisJob(
      jobId: job.jobId,
      specId: job.specId,
      specVersion: job.specVersion,
      mode: job.mode,
      status: job.status,
      progress: job.progress,
      createdAt: job.createdAt,
      startTime: job.startTime,
      inputRange: job.inputRange,
      parameters: job.parameters,
      artifactIds: job.artifactIds,
      logs: job.logs,
      errors: [...job.errors, error],
    );

    await _storage.save(jobId, updated);
  }

  /// Register a cancel handler for a job.
  void registerCancelHandler(String jobId, void Function() handler) {
    _cancelHandlers[jobId] = handler;
  }

  /// Get a job by ID.
  Future<AnalysisJob?> getJob(String jobId) async {
    return _storage.get(jobId);
  }

  /// List all jobs.
  Future<List<AnalysisJob>> listJobs() async {
    return _storage.getAll();
  }
}
