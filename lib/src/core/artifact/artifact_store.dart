import 'package:mcp_bundle/ports.dart';

import 'artifact_operations.dart';

/// Handles persistence and query operations for artifacts.
class ArtifactStore implements ArtifactOperations {
  final StoragePort<AnalysisArtifact> _storage;

  ArtifactStore({required StoragePort<AnalysisArtifact> storage})
      : _storage = storage;

  /// Save a single artifact.
  Future<void> save(AnalysisArtifact artifact) async {
    try {
      await _storage.save(artifact.artifactId, artifact);
    } catch (e) {
      throw AnalysisError(
        code: 'artifact.store_failed',
        message: 'Failed to persist artifact: ${artifact.artifactId}',
        details: {'artifactId': artifact.artifactId, 'error': '$e'},
      );
    }
  }

  /// Save multiple artifacts.
  Future<void> saveAll(List<AnalysisArtifact> artifacts) async {
    for (final artifact in artifacts) {
      await save(artifact);
    }
  }

  /// Get artifact by ID.
  Future<AnalysisArtifact?> get(String artifactId) async {
    return _storage.get(artifactId);
  }

  /// Query artifacts with filters.
  Future<List<AnalysisArtifact>> query({
    String? jobId,
    String? specId,
    AnalysisArtifactType? type,
    List<String>? tags,
    AnalysisTimeRange? timeRange,
    int? limit,
  }) async {
    final criteria = <String, dynamic>{};
    if (jobId != null) criteria['jobId'] = jobId;
    if (specId != null) criteria['specId'] = specId;
    if (type != null) criteria['type'] = type.name;
    if (tags != null && tags.isNotEmpty) criteria['tags'] = tags;

    var results = await _storage.query(criteria);

    if (type != null) {
      results = results.where((a) => a.type == type).toList();
    }

    if (specId != null) {
      results =
          results.where((a) => a.provenance.specId == specId).toList();
    }

    if (timeRange != null) {
      results = results.where((a) {
        final createdAt = a.provenance.createdAt;
        return !createdAt.isBefore(timeRange.start) &&
            !createdAt.isAfter(timeRange.end);
      }).toList();
    }

    if (limit != null && limit > 0 && limit < results.length) {
      results = results.sublist(0, limit);
    }

    return results;
  }
}
