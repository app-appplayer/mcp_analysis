import 'dart:async';

import 'package:mcp_bundle/ports.dart';

import 'datasource_registry.dart';

/// Bridges analysis data source interface to FactsPort for fact graph data.
class FactGraphSourceAdapter extends DataSourceAdapter {
  FactGraphSourceAdapter({
    required FactsPort factsPort,
    required String workspaceId,
  })  : _factsPort = factsPort,
        _workspaceId = workspaceId;
  final FactsPort _factsPort;
  final String _workspaceId;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    try {
      final factQuery = _buildQuery(query, filter, timeRange);
      final facts = await _factsPort.queryFacts(factQuery);
      return _mapToDataSet(facts, timeRange);
    } on TimeoutException catch (e) {
      throw AnalysisError(
        code: 'source.timeout',
        message: 'FactGraph query timed out: $e',
        details: {'query': query},
      );
    } catch (e) {
      if (e is AnalysisError) rethrow;
      final msg = e.toString().toLowerCase();
      if (msg.contains('unauthorized') ||
          msg.contains('forbidden') ||
          msg.contains('permission denied')) {
        throw AnalysisError(
          code: 'source.unauthorized',
          message: 'FactGraph access denied: $e',
          details: {'query': query},
        );
      }
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'FactGraph query failed: $e',
        details: {'query': query},
      );
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      await _factsPort.queryFacts(FactQuery(
        workspaceId: _workspaceId,
        limit: 1,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    final sampleFacts = await _factsPort.queryFacts(FactQuery(
      workspaceId: _workspaceId,
      types: [query],
      limit: 10,
    ));
    return _inferSchema(sampleFacts);
  }

  /// Build a FactQuery from analysis parameters.
  FactQuery _buildQuery(
    String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  ) {
    return FactQuery(
      workspaceId: _workspaceId,
      types: [query],
      entityId: filter?['entityId'] as String?,
      period: timeRange != null
          ? Period.absolute(start: timeRange.start, end: timeRange.end)
          : null,
      filters: filter,
    );
  }

  /// Map FactRecord list to AnalysisDataSet.
  AnalysisDataSet _mapToDataSet(
    List<FactRecord> facts,
    AnalysisTimeRange? timeRange,
  ) {
    if (facts.isEmpty) {
      return AnalysisDataSet(
        columns: const [],
        rows: const [],
        rowCount: 0,
        timeRange: timeRange,
      );
    }

    final columns = _extractColumns(facts.first);
    final rows = facts.map(_factToRow).toList();
    return AnalysisDataSet(
      columns: columns,
      rows: rows,
      rowCount: rows.length,
      timeRange: timeRange,
    );
  }

  /// Extract column definitions from a sample fact.
  List<AnalysisColumnInfo> _extractColumns(FactRecord fact) {
    final cols = <AnalysisColumnInfo>[
      const AnalysisColumnInfo(name: '_factId', type: 'string'),
      const AnalysisColumnInfo(name: '_factType', type: 'string'),
      const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
    ];

    if (fact.confidence != null) {
      cols.add(const AnalysisColumnInfo(name: '_confidence', type: 'double'));
    }

    // Add columns from content map
    for (final entry in fact.content.entries) {
      cols.add(AnalysisColumnInfo(
        name: entry.key,
        type: _inferType(entry.value),
      ));
    }

    return cols;
  }

  /// Convert a FactRecord to a row map.
  Map<String, dynamic> _factToRow(FactRecord fact) {
    return <String, dynamic>{
      '_factId': fact.id,
      '_factType': fact.type,
      '_timestamp': fact.createdAt,
      if (fact.confidence != null) '_confidence': fact.confidence,
      ...fact.content,
    };
  }

  /// Infer schema from sample facts.
  AnalysisSourceSchema _inferSchema(List<FactRecord> sampleFacts) {
    if (sampleFacts.isEmpty) {
      return const AnalysisSourceSchema(
        columns: [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        ],
        timestampField: '_timestamp',
      );
    }
    return AnalysisSourceSchema(
      columns: _extractColumns(sampleFacts.first),
      timestampField: '_timestamp',
    );
  }

  /// Infer Dart type name from a value.
  String _inferType(dynamic value) {
    if (value is int) return 'int';
    if (value is double) return 'double';
    if (value is bool) return 'bool';
    if (value is DateTime) return 'datetime';
    return 'string';
  }
}
