import 'package:mcp_bundle/ports.dart';

/// Constructs provenance metadata for artifacts.
class ProvenanceTracker {
  /// Create provenance from execution context.
  AnalysisArtifactProvenance createProvenance({
    required String specId,
    required String specVersion,
    required List<AnalysisInputSource> inputSources,
    required AnalysisTimeRange? inputTimeRange,
    required Map<String, dynamic> parameters,
  }) {
    final sourceUris = inputSources
        .map((s) => '${s.sourceType.name}://${s.query ?? "default"}')
        .toList();

    return AnalysisArtifactProvenance(
      version: specVersion,
      tags: [],
      createdAt: DateTime.now(),
      sourceUri: sourceUris.isNotEmpty ? sourceUris.first : null,
      sourceQuery: inputSources.isNotEmpty ? inputSources.first.query : null,
      inputRange: inputTimeRange,
      specId: specId,
      specVersion: specVersion,
    );
  }
}
