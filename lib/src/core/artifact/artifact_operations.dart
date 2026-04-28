import 'package:mcp_bundle/ports.dart';

/// Public interface for artifact persistence and query operations.
/// Consumed by MOD-CORE-002 (ExecutionEngine) and MOD-INFRA-002.
abstract interface class ArtifactOperations {
  Future<void> save(AnalysisArtifact artifact);
  Future<void> saveAll(List<AnalysisArtifact> artifacts);
  Future<AnalysisArtifact?> get(String artifactId);
  Future<List<AnalysisArtifact>> query({
    String? jobId,
    String? specId,
    AnalysisArtifactType? type,
    List<String>? tags,
    AnalysisTimeRange? timeRange,
    int? limit,
  });
}
