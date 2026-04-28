import 'dart:async';

import 'package:mcp_bundle/ports.dart';

/// Interface for data source adapters.
abstract class DataSourceAdapter {
  /// The type of data source this adapter handles.
  AnalysisSourceType get sourceType;

  /// Query data from this source.
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  });

  /// Get source metadata (schema, columns, types).
  Future<AnalysisSourceSchema> getSourceMetadata(String query);

  /// Check if source is available.
  Future<bool> isAvailable();
}

/// Mixin for adapters that support streaming.
mixin StreamableDataSource on DataSourceAdapter {
  /// Subscribe to a data stream.
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  });
}

/// Routes data source requests to appropriate adapter.
class DataSourceRegistry implements AnalysisDataSourcePort {
  final Map<AnalysisSourceType, DataSourceAdapter> _adapters = {};

  /// Register an adapter for a source type.
  void register(AnalysisSourceType sourceType, DataSourceAdapter adapter) {
    _adapters[sourceType] = adapter;
  }

  /// Unregister an adapter.
  void unregister(AnalysisSourceType sourceType) {
    _adapters.remove(sourceType);
  }

  @override
  Future<AnalysisDataSet> queryData({
    required AnalysisSourceType sourceType,
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    final adapter = _adapters[sourceType];
    if (adapter == null) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'No adapter registered for source type: ${sourceType.name}',
        details: {
          'sourceType': sourceType.name,
          'available': _adapters.keys.map((k) => k.name).toList(),
        },
      );
    }

    // Check source availability before querying
    if (!await adapter.isAvailable()) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'Data source ${sourceType.name} is not available',
        details: {'sourceType': sourceType.name},
      );
    }

    return adapter.queryData(
      query: query,
      filter: filter,
      timeRange: timeRange,
    );
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata({
    required AnalysisSourceType sourceType,
    required String query,
  }) async {
    final adapter = _adapters[sourceType];
    if (adapter == null) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'No adapter registered for source type: ${sourceType.name}',
      );
    }

    return adapter.getSourceMetadata(query);
  }

  @override
  Future<bool> isAvailable(AnalysisSourceType sourceType) async {
    final adapter = _adapters[sourceType];
    if (adapter == null) return false;
    return adapter.isAvailable();
  }

  /// Subscribe to a streaming data source.
  Stream<AnalysisDataSet> subscribeStream({
    required AnalysisSourceType sourceType,
    required String query,
    Map<String, dynamic>? filter,
  }) {
    final adapter = _adapters[sourceType];
    if (adapter == null || adapter is! StreamableDataSource) {
      return Stream.error(AnalysisError(
        code: 'source.unavailable',
        message:
            'No streaming adapter registered for source type: ${sourceType.name}',
      ));
    }

    return adapter.subscribe(
      query: query,
      filter: filter,
    );
  }
}
