import 'package:mcp_bundle/ports.dart';

/// Constructs typed artifact instances from analysis function results.
class ArtifactBuilder {
  int _idCounter = 0;

  String _generateId() {
    _idCounter++;
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'artifact-$ts-$_idCounter';
  }

  /// Build a Metric artifact.
  AnalysisMetricArtifact buildMetric({
    required String jobId,
    required String name,
    required dynamic value,
    required String unit,
    required AnalysisTimeRange timeRange,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    return AnalysisMetricArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      value: value,
      unit: unit,
      timeRange: timeRange,
    );
  }

  /// Build a Series artifact.
  AnalysisSeriesArtifact buildSeries({
    required String jobId,
    required String name,
    required List<AnalysisTimePoint> points,
    required String unit,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    return AnalysisSeriesArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      points: points,
      unit: unit,
    );
  }

  /// Build a Table artifact.
  AnalysisTableArtifact buildTable({
    required String jobId,
    required String name,
    required List<String> columns,
    required List<Map<String, dynamic>> rows,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    return AnalysisTableArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      columns: columns,
      rows: rows,
    );
  }

  /// Build a Chart artifact.
  AnalysisChartArtifact buildChart({
    required String jobId,
    required String name,
    required List<AnalysisSeriesArtifact> series,
    required AnalysisAxisMeta xAxis,
    required AnalysisAxisMeta yAxis,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    return AnalysisChartArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      series: series,
      xAxis: xAxis,
      yAxis: yAxis,
    );
  }

  /// Build a Summary artifact.
  AnalysisSummaryArtifact buildSummary({
    required String jobId,
    required String name,
    required String text,
    List<AnalysisEvidenceLink> evidenceLinks = const [],
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    return AnalysisSummaryArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      text: text,
      evidenceLinks: evidenceLinks,
    );
  }

  /// Build an AlertRule artifact.
  AnalysisAlertRuleArtifact buildAlertRule({
    required String jobId,
    required String name,
    required String condition,
    required AnalysisAlertSeverity severity,
    String? actionHook,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    return AnalysisAlertRuleArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      condition: condition,
      severity: severity,
      actionHook: actionHook,
    );
  }

  /// Build a Model artifact.
  ///
  /// Validates that [modelParameters] is not empty, [modelVersion] is a
  /// non-empty string, and [performanceMetrics] is not empty. Throws
  /// [AnalysisError] with code 'artifact.build_error' on violations.
  AnalysisModelArtifact buildModel({
    required String jobId,
    required String name,
    required Map<String, dynamic> modelParameters,
    required String modelVersion,
    required Map<String, dynamic> performanceMetrics,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    if (modelParameters.isEmpty) {
      throw AnalysisError(
        code: 'artifact.build_error',
        message:
            'Failed to build model artifact "$name": '
            'modelParameters must not be empty',
        details: {'field': 'modelParameters', 'artifactName': name},
      );
    }
    if (modelVersion.isEmpty) {
      throw AnalysisError(
        code: 'artifact.build_error',
        message:
            'Failed to build model artifact "$name": '
            'modelVersion must be a non-empty string',
        details: {'field': 'modelVersion', 'artifactName': name},
      );
    }
    if (performanceMetrics.isEmpty) {
      throw AnalysisError(
        code: 'artifact.build_error',
        message:
            'Failed to build model artifact "$name": '
            'performanceMetrics must not be empty',
        details: {'field': 'performanceMetrics', 'artifactName': name},
      );
    }
    return AnalysisModelArtifact(
      artifactId: _generateId(),
      name: name,
      provenance: AnalysisArtifactProvenance(
        version: provenance.version,
        tags: tags.isNotEmpty ? tags : provenance.tags,
        createdAt: DateTime.now(),
        sourceUri: provenance.sourceUri,
        sourceQuery: provenance.sourceQuery,
        inputRange: provenance.inputRange,
        specId: provenance.specId,
        specVersion: provenance.specVersion,
      ),
      parameters: modelParameters,
      modelVersion: modelVersion,
      performanceMetrics: performanceMetrics,
    );
  }

  /// Build artifacts from output definitions and function results.
  List<AnalysisArtifact> buildFromOutputDefs({
    required String jobId,
    required List<AnalysisOutputDef> outputDefs,
    required Map<String, dynamic> functionResults,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
  }) {
    final artifacts = <AnalysisArtifact>[];
    for (final outputDef in outputDefs) {
      final resultData = functionResults[outputDef.name];

      try {
        switch (outputDef.type) {
          case AnalysisArtifactType.metric:
            artifacts.add(buildMetric(
              jobId: jobId,
              name: outputDef.name,
              value: resultData is Map
                  ? resultData['value'] ?? 0.0
                  : resultData ?? 0.0,
              unit: resultData is Map
                  ? (resultData['unit'] as String? ?? '')
                  : '',
              timeRange: provenance.inputRange ??
                  AnalysisTimeRange(
                    start: DateTime.now(),
                    end: DateTime.now(),
                  ),
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.series:
            final points = <AnalysisTimePoint>[];
            if (resultData is Map && resultData['points'] is List) {
              for (final p in resultData['points'] as List) {
                if (p is Map<String, dynamic>) {
                  points.add(AnalysisTimePoint.fromJson(p));
                }
              }
            }
            artifacts.add(buildSeries(
              jobId: jobId,
              name: outputDef.name,
              points: points,
              unit: resultData is Map
                  ? (resultData['unit'] as String? ?? '')
                  : '',
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.table:
            artifacts.add(buildTable(
              jobId: jobId,
              name: outputDef.name,
              columns: resultData is Map
                  ? (resultData['columns'] as List?)?.cast<String>() ?? []
                  : [],
              rows: resultData is Map
                  ? (resultData['rows'] as List?)
                          ?.cast<Map<String, dynamic>>() ??
                      []
                  : [],
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.summary:
            artifacts.add(buildSummary(
              jobId: jobId,
              name: outputDef.name,
              text: resultData is Map
                  ? (resultData['text'] as String? ?? '')
                  : resultData?.toString() ?? '',
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.alert:
            artifacts.add(buildAlertRule(
              jobId: jobId,
              name: outputDef.name,
              condition: resultData is Map
                  ? (resultData['condition'] as String? ?? '')
                  : '',
              severity: AnalysisAlertSeverity.info,
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.model:
            artifacts.add(buildModel(
              jobId: jobId,
              name: outputDef.name,
              modelParameters: resultData is Map
                  ? Map<String, dynamic>.from(
                      resultData['parameters'] as Map? ?? {})
                  : {},
              modelVersion: resultData is Map
                  ? (resultData['modelVersion'] as String? ?? '1.0.0')
                  : '1.0.0',
              performanceMetrics: resultData is Map
                  ? Map<String, dynamic>.from(
                      resultData['performanceMetrics'] as Map? ?? {})
                  : {},
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.chart:
            artifacts.add(buildChart(
              jobId: jobId,
              name: outputDef.name,
              series: [],
              xAxis: AnalysisAxisMeta(label: 'x', type: 'linear'),
              yAxis: AnalysisAxisMeta(label: 'y', type: 'linear'),
              provenance: provenance,
              tags: tags,
            ));
        }
      } catch (e) {
        if (e is AnalysisError) rethrow;
        throw AnalysisError(
          code: 'artifact.build_error',
          message:
              'Failed to build artifact "${outputDef.name}" '
              'of type ${outputDef.type.name}: $e',
          details: {
            'outputName': outputDef.name,
            'outputType': outputDef.type.name,
          },
        );
      }
    }
    return artifacts;
  }
}
