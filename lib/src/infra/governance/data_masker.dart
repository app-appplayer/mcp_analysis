import 'package:mcp_bundle/ports.dart';

/// Masks sensitive fields in analysis artifacts.
class DataMasker {
  static const String maskedValue = '***';

  /// Apply masking to artifacts based on mask configuration.
  List<AnalysisArtifact> applyMasking(
    List<AnalysisArtifact> artifacts,
    Map<String, bool> maskConfig,
  ) {
    final maskedColumns = maskConfig.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toSet();

    if (maskedColumns.isEmpty) return artifacts;

    return artifacts.map((artifact) {
      if (artifact is AnalysisTableArtifact) {
        return maskTable(artifact, maskedColumns);
      }
      if (artifact is AnalysisSeriesArtifact) {
        return maskSeries(artifact);
      }
      return artifact;
    }).toList();
  }

  /// Mask values in a Series artifact if flagged.
  AnalysisSeriesArtifact maskSeries(AnalysisSeriesArtifact series) {
    // Replace all point values with masked value
    final maskedPoints = series.points
        .map((p) => AnalysisTimePoint(
              t: p.t,
              v: maskedValue,
            ))
        .toList();
    return AnalysisSeriesArtifact(
      artifactId: series.artifactId,
      name: series.name,
      provenance: series.provenance,
      points: maskedPoints,
      unit: series.unit,
    );
  }

  /// Mask a single Table artifact's specified columns.
  AnalysisTableArtifact maskTable(
    AnalysisTableArtifact table,
    Set<String> maskedColumns,
  ) {
    final maskedRows = table.rows.map((row) {
      final newRow = Map<String, dynamic>.from(row);
      for (final col in maskedColumns) {
        if (newRow.containsKey(col)) {
          newRow[col] = maskedValue;
        }
      }
      return newRow;
    }).toList();

    return AnalysisTableArtifact(
      artifactId: table.artifactId,
      name: table.name,
      provenance: table.provenance,
      columns: table.columns,
      rows: maskedRows,
      columnUnits: table.columnUnits,
    );
  }
}
