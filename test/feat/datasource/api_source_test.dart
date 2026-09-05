import 'dart:async';
import 'dart:convert';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

// ============================================================================
// Mock HTTP Client
// ============================================================================

/// Mock HttpClientPort that returns pre-configured responses.
class MockHttpClient implements HttpClientPort {
  MockHttpClient({this.response});
  HttpResponseData? response;
  Object? errorToThrow;

  /// Captures the last request for verification.
  String? lastMethod;
  String? lastUrl;
  Map<String, String>? lastHeaders;
  String? lastBody;
  Duration? lastTimeout;

  @override
  Future<HttpResponseData> request({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    lastMethod = method;
    lastUrl = url;
    lastHeaders = headers;
    lastBody = body;
    lastTimeout = timeout;

    if (errorToThrow != null) {
      throw errorToThrow!;
    }

    return response!;
  }
}

// ============================================================================
// Helper: build query JSON
// ============================================================================

String _buildQuery({
  required String url,
  String method = 'GET',
  Map<String, String>? headers,
  Map<String, String>? responseMapping,
  String? dataArrayPath,
  int? timeout,
}) {
  final config = <String, dynamic>{
    'url': url,
    'method': method,
  };
  if (headers != null) config['headers'] = headers;
  if (responseMapping != null) config['responseMapping'] = responseMapping;
  if (dataArrayPath != null) config['dataArrayPath'] = dataArrayPath;
  if (timeout != null) config['timeout'] = timeout;
  return json.encode(config);
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  // ==========================================================================
  // ApiSourceAdapter (TC-001 to TC-012)
  // ==========================================================================
  group('ApiSourceAdapter', () {
    late MockHttpClient httpClient;
    late ApiSourceAdapter adapter;

    setUp(() {
      httpClient = MockHttpClient();
      adapter = ApiSourceAdapter(httpClient: httpClient);
    });

    // TC-001: Successful API call returns mapped data
    test('TC-001: successful API call returns mapped AnalysisDataSet',
        () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode([
          {'name': 'Sensor A', 'value': 42.0},
          {'name': 'Sensor B', 'value': 37.5},
        ]),
      );

      final query = _buildQuery(url: 'https://api.example.com/sensors');
      final result = await adapter.queryData(query: query);

      expect(result.columns.length, equals(2));
      expect(result.columns[0].name, equals('name'));
      expect(result.columns[1].name, equals('value'));
      expect(result.rows.length, equals(2));
      expect(result.rowCount, equals(2));
      expect(result.rows[0]['name'], equals('Sensor A'));
      expect(result.rows[0]['value'], equals(42.0));
      expect(result.rows[1]['name'], equals('Sensor B'));
      expect(result.rows[1]['value'], equals(37.5));

      // Verify HTTP call parameters
      expect(httpClient.lastMethod, equals('GET'));
      expect(httpClient.lastUrl, equals('https://api.example.com/sensors'));
    });

    // TC-002: Response mapping with nested JSON paths
    test('TC-002: response mapping extracts nested JSON paths', () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode({
          'data': {
            'readings': [
              {
                'id': 'r1',
                'metrics': {'temperature': 72.0},
                'location': {'city': 'Seoul'},
              },
              {
                'id': 'r2',
                'metrics': {'temperature': 68.5},
                'location': {'city': 'Busan'},
              },
            ],
          },
        }),
      );

      final query = _buildQuery(
        url: 'https://api.example.com/readings',
        dataArrayPath: 'data.readings',
        responseMapping: {
          'readingId': 'id',
          'temp': 'metrics.temperature',
          'city': 'location.city',
        },
      );

      final result = await adapter.queryData(query: query);

      expect(result.columns.length, equals(3));
      expect(result.rows.length, equals(2));
      expect(result.rows[0]['readingId'], equals('r1'));
      expect(result.rows[0]['temp'], equals(72.0));
      expect(result.rows[0]['city'], equals('Seoul'));
      expect(result.rows[1]['readingId'], equals('r2'));
      expect(result.rows[1]['temp'], equals(68.5));
      expect(result.rows[1]['city'], equals('Busan'));
    });

    // TC-003: 401 status code throws source.unauthorized
    test('TC-003: 401 status code throws source.unauthorized', () async {
      httpClient.response = const HttpResponseData(
        statusCode: 401,
        body: '{"error":"Unauthorized"}',
      );

      final query = _buildQuery(url: 'https://api.example.com/secure');

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.unauthorized')),
        ),
      );
    });

    // TC-004: 403 status code throws source.unauthorized
    test('TC-004: 403 status code throws source.unauthorized', () async {
      httpClient.response = const HttpResponseData(
        statusCode: 403,
        body: '{"error":"Forbidden"}',
      );

      final query = _buildQuery(url: 'https://api.example.com/secure');

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.unauthorized')),
        ),
      );
    });

    // TC-005: Timeout throws source.timeout
    test('TC-005: timeout throws source.timeout', () async {
      httpClient.errorToThrow = TimeoutException('Request timed out');

      final query = _buildQuery(
        url: 'https://api.example.com/slow',
        timeout: 5,
      );

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.timeout')),
        ),
      );
    });

    // TC-006: Connection failure throws source.unavailable
    test('TC-006: connection failure throws source.unavailable', () async {
      httpClient.errorToThrow = Exception('Connection refused');

      final query = _buildQuery(url: 'https://api.example.com/down');

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.unavailable')),
        ),
      );
    });

    // TC-007: Invalid JSON response throws source.schema_mismatch
    test('TC-007: invalid JSON response throws source.schema_mismatch',
        () async {
      httpClient.response = const HttpResponseData(
        statusCode: 200,
        body: 'not valid json {{',
      );

      final query = _buildQuery(url: 'https://api.example.com/bad');

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.schema_mismatch')),
        ),
      );
    });

    // TC-008: Missing dataArrayPath on non-array response throws schema_mismatch
    test(
        'TC-008: non-array response without dataArrayPath throws source.schema_mismatch',
        () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode({
          'data': [1, 2, 3]
        }),
      );

      // No dataArrayPath specified, but response is an object not array
      final query = _buildQuery(url: 'https://api.example.com/object');

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.schema_mismatch')),
        ),
      );
    });

    // TC-009: Missing url in config throws error
    test('TC-009: missing url in config throws source.schema_mismatch',
        () async {
      final query = json.encode({'method': 'GET'});

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.schema_mismatch')),
        ),
      );
    });

    // TC-010: 500 status code throws source.unavailable
    test('TC-010: 500 status code throws source.unavailable', () async {
      httpClient.response = const HttpResponseData(
        statusCode: 500,
        body: '{"error":"Internal Server Error"}',
      );

      final query = _buildQuery(url: 'https://api.example.com/error');

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.unavailable')),
        ),
      );
    });

    // TC-011: Invalid query JSON throws source.schema_mismatch
    test('TC-011: invalid query JSON throws source.schema_mismatch', () async {
      expect(
        () => adapter.queryData(query: 'not json'),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.schema_mismatch')),
        ),
      );
    });

    // TC-012: dataArrayPath navigates nested response correctly
    test('TC-012: dataArrayPath navigates nested response', () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode({
          'result': {
            'items': [
              {'id': 1, 'label': 'A'},
              {'id': 2, 'label': 'B'},
            ],
          },
        }),
      );

      final query = _buildQuery(
        url: 'https://api.example.com/nested',
        dataArrayPath: 'result.items',
      );

      final result = await adapter.queryData(query: query);

      expect(result.rows.length, equals(2));
      expect(result.rows[0]['id'], equals(1));
      expect(result.rows[0]['label'], equals('A'));
      expect(result.rows[1]['id'], equals(2));
      expect(result.rows[1]['label'], equals('B'));
    });

    // TC-013: isAvailable returns true
    test('TC-013: isAvailable returns true', () async {
      final available = await adapter.isAvailable();
      expect(available, isTrue);
    });

    // TC-014: getSourceMetadata returns columns from responseMapping
    test('TC-014: getSourceMetadata returns columns from responseMapping',
        () async {
      final query = _buildQuery(
        url: 'https://api.example.com/data',
        responseMapping: {'temp': 'temperature', 'loc': 'location.name'},
      );

      final schema = await adapter.getSourceMetadata(query);

      expect(schema.columns.length, equals(2));
      expect(schema.columns[0].name, equals('temp'));
      expect(schema.columns[1].name, equals('loc'));
    });

    // TC-015: Custom headers are passed to HTTP client
    test('TC-015: custom headers are passed to HTTP client', () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode([]),
      );

      final query = _buildQuery(
        url: 'https://api.example.com/data',
        headers: {'Authorization': 'Bearer token123', 'X-Custom': 'value'},
      );

      await adapter.queryData(query: query);

      expect(httpClient.lastHeaders, isNotNull);
      expect(
          httpClient.lastHeaders!['Authorization'], equals('Bearer token123'));
      expect(httpClient.lastHeaders!['X-Custom'], equals('value'));
    });

    // TC-016: Empty data array returns empty dataset with columns
    test('TC-016: empty data array returns empty dataset', () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode({'data': <dynamic>[]}),
      );

      final query = _buildQuery(
        url: 'https://api.example.com/empty',
        dataArrayPath: 'data',
        responseMapping: {'name': 'name', 'value': 'value'},
      );

      final result = await adapter.queryData(query: query);

      expect(result.rows, isEmpty);
      expect(result.rowCount, equals(0));
      expect(result.columns.length, equals(2));
    });

    // TC-017: sourceType returns AnalysisSourceType.external
    test('TC-017: sourceType returns AnalysisSourceType.external', () {
      expect(adapter.sourceType, equals(AnalysisSourceType.external));
    });

    // TC-018: dataArrayPath pointing to missing key throws schema_mismatch
    test(
        'TC-018: dataArrayPath pointing to missing key throws source.schema_mismatch',
        () async {
      httpClient.response = HttpResponseData(
        statusCode: 200,
        body: json.encode({'other': <dynamic>[]}),
      );

      final query = _buildQuery(
        url: 'https://api.example.com/missing',
        dataArrayPath: 'data.readings',
      );

      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('source.schema_mismatch')),
        ),
      );
    });
  });
}
