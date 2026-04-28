import 'package:mcp_bundle/ports.dart';

import '../../infra/governance/rbac_policy.dart';

/// Public interface for analysis execution operations.
/// Consumed by MOD-INFRA-002 (MCP tool handlers).
abstract interface class ExecutionOperations {
  Future<AnalysisJob> runAnalysis({
    required String specId,
    required Map<String, dynamic> parameters,
    AnalysisExecutionMode mode,
    AnalysisTimeRange? timeRange,
    RbacContext? rbacContext,
  });
  Future<AnalysisJob?> getJob(String jobId);
  Future<AnalysisJob> cancelJob(String jobId, {RbacContext? rbacContext});
}
