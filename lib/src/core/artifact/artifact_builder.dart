import 'dart:convert';

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
        jobId: jobId,
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
        jobId: jobId,
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
        jobId: jobId,
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
        jobId: jobId,
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
        jobId: jobId,
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
        jobId: jobId,
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
        message: 'Failed to build model artifact "$name": '
            'modelParameters must not be empty',
        details: {'field': 'modelParameters', 'artifactName': name},
      );
    }
    if (modelVersion.isEmpty) {
      throw AnalysisError(
        code: 'artifact.build_error',
        message: 'Failed to build model artifact "$name": '
            'modelVersion must be a non-empty string',
        details: {'field': 'modelVersion', 'artifactName': name},
      );
    }
    if (performanceMetrics.isEmpty) {
      throw AnalysisError(
        code: 'artifact.build_error',
        message: 'Failed to build model artifact "$name": '
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
        jobId: jobId,
      ),
      parameters: modelParameters,
      modelVersion: modelVersion,
      performanceMetrics: performanceMetrics,
    );
  }

  /// Value the output binds to: the named result [field] when the spec
  /// gives one, the whole result map otherwise.
  ///
  /// Naming the field is what makes a function's own vocabulary reachable
  /// — `magnitudes`, `zScores`, `isoZone`. Without it every artifact type
  /// can only read the one conventional key it was written to expect, and
  /// almost no function returns that key.
  static dynamic _select(dynamic resultData, String? field) {
    if (field == null) return resultData;
    if (resultData is Map) return resultData[field];
    return null;
  }

  /// Numeric list from a result field, or null when the field is absent
  /// or holds something else.
  static List<double>? _numList(dynamic v) {
    if (v is! List) return null;
    final out = <double>[];
    for (final e in v) {
      if (e is num) {
        out.add(e.toDouble());
      } else {
        return null;
      }
    }
    return out;
  }

  /// Span a non-temporal index is mapped onto, in microseconds.
  ///
  /// `AnalysisTimePoint.t` is a `DateTime`, so a spectrum's frequency axis
  /// or a correlogram's lag axis has to be carried as a position on it.
  /// Microseconds are the finest unit a `Duration` has, so a fixed
  /// multiplier sets a floor on how close two index values may be before
  /// they land on the same point — at ×1000 two bins 0.0001 apart merged,
  /// and three points became one. Normalizing the range instead keeps the
  /// order and the relative spacing whatever the units are.
  static const int _indexSpanMicros = 1000000000;

  /// Points for a series or a chart: [values] against [index] when an
  /// index field is given, against position otherwise.
  ///
  /// A `DateTime` index is used as-is. A numeric one is a position, not a
  /// time — the axis label names the field it came from.
  static List<AnalysisTimePoint> _points({
    required List<double> values,
    List<dynamic>? index,
  }) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    // Range of the numeric part of the index, for normalizing onto the span.
    double? min;
    double? max;
    if (index != null) {
      for (var i = 0; i < values.length && i < index.length; i++) {
        final raw = index[i];
        if (raw is! num || raw is DateTime) continue;
        final v = raw.toDouble();
        if (min == null || v < min) min = v;
        if (max == null || v > max) max = v;
      }
    }
    final span = (min != null && max != null) ? max - min : 0.0;

    final points = <AnalysisTimePoint>[];
    for (var i = 0; i < values.length; i++) {
      final raw = index != null && i < index.length ? index[i] : null;
      final DateTime t;
      if (raw is DateTime) {
        t = raw;
      } else if (raw is num && span > 0) {
        final position = (raw.toDouble() - min!) / span * _indexSpanMicros;
        t = epoch.add(Duration(microseconds: position.round()));
      } else if (raw is num) {
        // Every index value is the same; position is all that is left.
        t = epoch.add(Duration(microseconds: i));
      } else {
        t = epoch.add(Duration(microseconds: i));
      }
      points.add(AnalysisTimePoint(t: t, v: values[i]));
    }
    return points;
  }

  /// Build artifacts from output definitions and function results.
  /// Build artifacts from output definitions and function results.
  ///
  /// An output bound to a field the run did not produce yields **no
  /// artifact**, and [onSkipped] is called with the reason. A conditional
  /// result field — `criticalValue` for one test but not another,
  /// `bandPowers` only when bands were requested — is declared by the
  /// function and so passes spec validation, but a run whose parameters do
  /// not produce it has no value to carry. Building the artifact anyway
  /// reports `0.0` for a number nobody computed, which is the failure this
  /// binding exists to remove.
  List<AnalysisArtifact> buildFromOutputDefs({
    required String jobId,
    required List<AnalysisOutputDef> outputDefs,
    required Map<String, dynamic> functionResults,
    required AnalysisArtifactProvenance provenance,
    List<String> tags = const [],
    void Function(AnalysisError)? onSkipped,
  }) {
    final artifacts = <AnalysisArtifact>[];
    for (final outputDef in outputDefs) {
      // An output reads the step named by its `from`, falling back to
      // its own name. The spec validator rejects a key that matches no
      // step, so a miss here cannot silently produce an empty artifact.
      final stepResult = functionResults[outputDef.sourceKey];

      // A bound field that the run did not produce is not zero, not an
      // empty series and not an empty string — it is an artifact that
      // cannot be built.
      final boundField = outputDef.field;
      if (boundField != null &&
          !(stepResult is Map && stepResult.containsKey(boundField))) {
        onSkipped?.call(AnalysisError(
          code: 'artifact.unproduced_field',
          message: 'Output "${outputDef.name}" reads '
              '"${outputDef.sourceKey}.$boundField", which this run did not '
              'produce. The field is declared but conditional; check the '
              "step's parameters.",
          details: {
            'outputName': outputDef.name,
            'from': outputDef.sourceKey,
            'field': boundField,
          },
          timestamp: DateTime.now(),
        ));
        continue;
      }

      final resultData = _select(stepResult, outputDef.field);
      final indexField = outputDef.indexField;
      if (indexField != null &&
          !(stepResult is Map && stepResult.containsKey(indexField))) {
        onSkipped?.call(AnalysisError(
          code: 'artifact.unproduced_field',
          message: 'Output "${outputDef.name}" indexes by '
              '"${outputDef.sourceKey}.$indexField", which this run did not '
              'produce.',
          details: {
            'outputName': outputDef.name,
            'from': outputDef.sourceKey,
            'indexField': indexField,
          },
          timestamp: DateTime.now(),
        ));
        continue;
      }
      final indexValues = indexField == null
          ? null
          : (_select(stepResult, indexField) as List<dynamic>?);

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
            final selected = _numList(resultData);
            if (selected != null) {
              points.addAll(_points(values: selected, index: indexValues));
            } else if (resultData is Map && resultData['points'] is List) {
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
            // A selected field holding rows carries its own column set,
            // read off the first row rather than declared twice.
            final selectedRows = resultData is List
                ? resultData.whereType<Map<String, dynamic>>().toList()
                : null;
            artifacts.add(buildTable(
              jobId: jobId,
              name: outputDef.name,
              columns: selectedRows != null
                  ? (selectedRows.isEmpty
                      ? <String>[]
                      : selectedRows.first.keys.toList())
                  : resultData is Map
                      ? (resultData['columns'] as List?)?.cast<String>() ?? []
                      : [],
              rows: selectedRows ??
                  (resultData is Map
                      ? (resultData['rows'] as List?)
                              ?.cast<Map<String, dynamic>>() ??
                          []
                      : []),
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.summary:
            // A summary without a 'text' convention key carries the whole
            // function-results map as JSON — otherwise rich results (fft,
            // lockin, ...) would be unreachable through the port surface.
            artifacts.add(buildSummary(
              jobId: jobId,
              name: outputDef.name,
              text: resultData is Map
                  ? (resultData['text'] as String? ?? jsonEncode(resultData))
                  : resultData?.toString() ?? '',
              provenance: provenance,
              tags: tags,
            ));
          case AnalysisArtifactType.alert:
            // Severity comes from the result, or from the output's own
            // parameters when the function does not grade its findings.
            // Hardcoding `info` made every rule the same urgency however
            // the analysis judged it.
            final severityName =
                resultData is Map ? resultData['severity'] as String? : null;
            final declaredSeverity =
                outputDef.parameters?['severity'] as String?;
            artifacts.add(buildAlertRule(
              jobId: jobId,
              name: outputDef.name,
              condition: resultData is Map
                  ? (resultData['condition'] as String? ?? '')
                  : '',
              severity: AnalysisAlertSeverity.fromString(
                severityName ?? declaredSeverity ?? 'info',
              ),
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
            // A chart is its series. Before `field` there was no way to
            // say which result values to plot, so every chart shipped
            // empty; the axis labels name the fields they came from.
            final values = _numList(resultData);
            final chartSeries = <AnalysisSeriesArtifact>[
              if (values != null)
                buildSeries(
                  jobId: jobId,
                  name: outputDef.field ?? outputDef.name,
                  points: _points(values: values, index: indexValues),
                  unit: '',
                  provenance: provenance,
                  tags: tags,
                ),
            ];
            artifacts.add(buildChart(
              jobId: jobId,
              name: outputDef.name,
              series: chartSeries,
              xAxis: AnalysisAxisMeta(
                label: outputDef.indexField ?? 'index',
                type: 'linear',
              ),
              yAxis: AnalysisAxisMeta(
                label: outputDef.field ?? 'value',
                type: 'linear',
              ),
              provenance: provenance,
              tags: tags,
            ));
        }
      } catch (e) {
        if (e is AnalysisError) rethrow;
        throw AnalysisError(
          code: 'artifact.build_error',
          message: 'Failed to build artifact "${outputDef.name}" '
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
