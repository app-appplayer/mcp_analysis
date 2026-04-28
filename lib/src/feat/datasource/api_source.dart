import 'dart:async';
import 'dart:convert';

import 'package:mcp_bundle/ports.dart';

import 'datasource_registry.dart';

// ============================================================================
// HTTP Client Port (injected interface for HTTP calls)
// ============================================================================

/// Port interface for HTTP communication.
abstract class HttpClientPort {
  /// Execute an HTTP request and return the response.
  Future<HttpResponseData> request({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 30),
  });
}

/// Immutable HTTP response data returned from HttpClientPort.
class HttpResponseData {
  final int statusCode;
  final Map<String, String> headers;
  final String body;

  const HttpResponseData({
    required this.statusCode,
    this.headers = const {},
    required this.body,
  });
}

// ============================================================================
// API Configuration (parsed from query JSON)
// ============================================================================

/// Configuration for an API data source request.
class ApiConfig {
  final String url;
  final String method;
  final Map<String, String> headers;
  final Map<String, String> responseMapping;
  final String? dataArrayPath;
  final Duration timeout;

  const ApiConfig({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.responseMapping = const {},
    this.dataArrayPath,
    this.timeout = const Duration(seconds: 30),
  });

  /// Parse ApiConfig from a JSON query string.
  factory ApiConfig.fromJson(String queryJson) {
    final dynamic decoded;
    try {
      decoded = json.decode(queryJson);
    } catch (e) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'Invalid API config JSON: $e',
        details: {'query': queryJson},
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'API config must be a JSON object',
        details: {'query': queryJson},
      );
    }

    final url = decoded['url'] as String?;
    if (url == null || url.isEmpty) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'API config requires a non-empty "url" field',
        details: {'query': queryJson},
      );
    }

    final rawHeaders = decoded['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }

    final rawMapping = decoded['responseMapping'];
    final responseMapping = <String, String>{};
    if (rawMapping is Map) {
      for (final entry in rawMapping.entries) {
        responseMapping[entry.key.toString()] = entry.value.toString();
      }
    }

    final timeoutSeconds = decoded['timeout'] as int?;

    return ApiConfig(
      url: url,
      method: (decoded['method'] as String?)?.toUpperCase() ?? 'GET',
      headers: headers,
      responseMapping: responseMapping,
      dataArrayPath: decoded['dataArrayPath'] as String?,
      timeout: timeoutSeconds != null
          ? Duration(seconds: timeoutSeconds)
          : const Duration(seconds: 30),
    );
  }
}

// ============================================================================
// API Source Adapter
// ============================================================================

/// External API data source adapter.
///
/// Parses query JSON into ApiConfig, executes HTTP calls via HttpClientPort,
/// and maps the response to AnalysisDataSet using responseMapping.
class ApiSourceAdapter extends DataSourceAdapter {
  final HttpClientPort _httpClient;
  final Duration queryTimeout;

  ApiSourceAdapter({
    required HttpClientPort httpClient,
    this.queryTimeout = const Duration(seconds: 30),
  }) : _httpClient = httpClient;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.external;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    final config = ApiConfig.fromJson(query);

    final HttpResponseData response;
    try {
      response = await _httpClient.request(
        method: config.method,
        url: config.url,
        headers: config.headers,
        timeout: config.timeout,
      );
    } on TimeoutException {
      throw AnalysisError(
        code: 'source.timeout',
        message: 'API query timed out after ${config.timeout.inSeconds}s',
        details: {'query': query, 'timeoutSeconds': config.timeout.inSeconds},
      );
    } catch (e) {
      if (e is AnalysisError) rethrow;
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'API connection failed: $e',
        details: {'query': query},
      );
    }

    // Map HTTP status codes to error types
    _checkStatusCode(response.statusCode, query);

    // Parse response body as JSON
    final dynamic responseBody;
    try {
      responseBody = json.decode(response.body);
    } catch (e) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'Invalid JSON response from API: $e',
        details: {'query': query},
      );
    }

    // Extract data array using dataArrayPath
    final dataArray = _extractDataArray(responseBody, config.dataArrayPath);

    // Map response to AnalysisDataSet
    return _mapToDataSet(dataArray, config.responseMapping, timeRange);
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    final config = ApiConfig.fromJson(query);

    // Infer columns from responseMapping if available
    if (config.responseMapping.isNotEmpty) {
      final columns = config.responseMapping.keys
          .map((key) => AnalysisColumnInfo(name: key, type: 'string'))
          .toList();
      return AnalysisSourceSchema(columns: columns);
    }

    return const AnalysisSourceSchema(columns: []);
  }

  @override
  Future<bool> isAvailable() async {
    return true;
  }

  /// Check HTTP status code and throw appropriate errors.
  void _checkStatusCode(int statusCode, String query) {
    if (statusCode >= 200 && statusCode < 300) return;

    if (statusCode == 401 || statusCode == 403) {
      throw AnalysisError(
        code: 'source.unauthorized',
        message: 'API access denied with status $statusCode',
        details: {'query': query, 'statusCode': statusCode},
      );
    }

    throw AnalysisError(
      code: 'source.unavailable',
      message: 'API returned error status $statusCode',
      details: {'query': query, 'statusCode': statusCode},
    );
  }

  /// Extract the data array from the response using dataArrayPath.
  ///
  /// Supports paths like:
  ///  - null/empty -> response must be a list at root
  ///  - "data" -> response["data"]
  ///  - "data.readings" -> response["data"]["readings"]
  List<dynamic> _extractDataArray(dynamic body, String? dataArrayPath) {
    if (dataArrayPath == null || dataArrayPath.isEmpty) {
      if (body is List) return body;
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message:
            'Response is not an array and no dataArrayPath specified',
      );
    }

    dynamic current = body;
    final segments = dataArrayPath.split('.');

    for (final segment in segments) {
      if (current is! Map<String, dynamic>) {
        throw AnalysisError(
          code: 'source.schema_mismatch',
          message:
              'Cannot navigate path "$dataArrayPath": expected object at "$segment"',
          details: {'dataArrayPath': dataArrayPath},
        );
      }
      current = current[segment];
      if (current == null) {
        throw AnalysisError(
          code: 'source.schema_mismatch',
          message:
              'Path "$dataArrayPath" not found in response: missing "$segment"',
          details: {'dataArrayPath': dataArrayPath},
        );
      }
    }

    if (current is! List) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message:
            'Value at path "$dataArrayPath" is not an array',
        details: {'dataArrayPath': dataArrayPath},
      );
    }

    return current;
  }

  /// Map a list of response objects to AnalysisDataSet.
  ///
  /// If responseMapping is provided, maps source JSON paths to output column names.
  /// Supported JSON path syntax:
  ///  - "key" -> simple key lookup
  ///  - "parent.child" -> nested key lookup
  ///  - "items[].field" -> array element field extraction (flattened)
  AnalysisDataSet _mapToDataSet(
    List<dynamic> dataArray,
    Map<String, String> responseMapping,
    AnalysisTimeRange? timeRange,
  ) {
    if (dataArray.isEmpty) {
      final columns = responseMapping.isNotEmpty
          ? responseMapping.keys
              .map((k) => AnalysisColumnInfo(name: k, type: 'string'))
              .toList()
          : <AnalysisColumnInfo>[];
      return AnalysisDataSet(
        columns: columns,
        rows: const [],
        rowCount: 0,
        timeRange: timeRange,
      );
    }

    final rows = <Map<String, dynamic>>[];

    for (final item in dataArray) {
      if (item is! Map<String, dynamic>) continue;

      if (responseMapping.isEmpty) {
        // No mapping: use raw keys
        rows.add(Map<String, dynamic>.from(item));
      } else {
        // Apply mapping: outputColumn -> jsonPath
        final row = <String, dynamic>{};
        for (final entry in responseMapping.entries) {
          row[entry.key] = _extractValue(item, entry.value);
        }
        rows.add(row);
      }
    }

    // Infer columns from first row
    final columns = <AnalysisColumnInfo>[];
    if (rows.isNotEmpty) {
      for (final entry in rows.first.entries) {
        columns.add(AnalysisColumnInfo(
          name: entry.key,
          type: _inferType(entry.value),
        ));
      }
    }

    return AnalysisDataSet(
      columns: columns,
      rows: rows,
      rowCount: rows.length,
      timeRange: timeRange,
    );
  }

  /// Extract a value from a map using a JSON path expression.
  ///
  /// Supports:
  ///  - "key" -> map["key"]
  ///  - "parent.child" -> map["parent"]["child"]
  ///  - "items[].field" -> (returns first match from array)
  dynamic _extractValue(Map<String, dynamic> map, String path) {
    final segments = path.split('.');
    dynamic current = map;

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];

      // Handle array access syntax: "items[]"
      if (segment.endsWith('[]')) {
        final arrayKey = segment.substring(0, segment.length - 2);
        if (current is Map<String, dynamic>) {
          final arr = current[arrayKey];
          if (arr is List && arr.isNotEmpty) {
            // If there are remaining path segments, extract from first element
            if (i + 1 < segments.length) {
              final remaining = segments.sublist(i + 1).join('.');
              final first = arr.first;
              if (first is Map<String, dynamic>) {
                return _extractValue(first, remaining);
              }
            }
            return arr;
          }
          return null;
        }
        return null;
      }

      // Simple key navigation
      if (current is Map<String, dynamic>) {
        current = current[segment];
      } else {
        return null;
      }
    }

    return current;
  }

  /// Infer column type from a value.
  String _inferType(dynamic value) {
    if (value is int) return 'int';
    if (value is double) return 'double';
    if (value is num) return 'double';
    if (value is bool) return 'bool';
    if (value is DateTime) return 'datetime';
    return 'string';
  }
}
