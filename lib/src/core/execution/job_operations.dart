import 'package:mcp_bundle/ports.dart';

/// Public interface for Job lifecycle management.
/// Consumed by ExecutionEngine and mode-specific executors.
abstract interface class JobOperations {
  Future<AnalysisJob> createJob({
    required String specId,
    required String specVersion,
    required AnalysisExecutionMode mode,
    required Map<String, dynamic> parameters,
    AnalysisTimeRange? timeRange,
  });
  Future<AnalysisJob> startJob(String jobId);
  Future<AnalysisJob?> getJob(String jobId);
  Future<List<AnalysisJob>> listJobs();
  Future<void> updateProgress(String jobId, double progress);

  /// AnalysisJob uses artifactIds: `List<String>`, not
  /// `List<AnalysisArtifact>`.
  Future<AnalysisJob> completeJob(String jobId,
      {required List<String> artifactIds,
      List<AnalysisError> errors,
      List<AnalysisJobLog> logs});
  Future<AnalysisJob> failJob(String jobId,
      {List<AnalysisError> errors, List<AnalysisJobLog> logs});
  Future<AnalysisJob> cancelJob(String jobId);
  Future<void> addError(String jobId, AnalysisError error);
}
