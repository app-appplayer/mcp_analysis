import 'dart:async';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

// ============================================================================
// Mock Adapters
// ============================================================================

/// Simple mock adapter that returns pre-configured data.
class MockDataSourceAdapter implements DataSourceAdapter {
  MockDataSourceAdapter(this.data, {this.available = true});
  final AnalysisDataSet data;
  bool available;

  /// Captures the last query parameters for verification.
  String? lastQuery;
  Map<String, dynamic>? lastFilter;
  AnalysisTimeRange? lastTimeRange;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    lastQuery = query;
    lastFilter = filter;
    lastTimeRange = timeRange;

    if (!available) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'Not available',
      );
    }
    return data;
  }

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return AnalysisSourceSchema(columns: data.columns);
  }
}

/// Mock adapter that supports streaming via StreamableDataSource mixin.
class MockStreamableAdapter extends MockDataSourceAdapter
    with StreamableDataSource {
  MockStreamableAdapter(super.data);
  final StreamController<AnalysisDataSet> _controller =
      StreamController.broadcast();

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) =>
      _controller.stream;

  /// Emit a data set to all stream subscribers.
  void emit(AnalysisDataSet data) => _controller.add(data);

  /// Close the underlying stream controller.
  void close() => _controller.close();
}

/// Mock adapter that always throws on queryData.
class ErrorThrowingAdapter implements DataSourceAdapter {
  ErrorThrowingAdapter({
    this.errorCode = 'adapter.error',
    this.errorMessage = 'Adapter internal error',
  });
  final String errorCode;
  final String errorMessage;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    throw AnalysisError(code: errorCode, message: errorMessage);
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    throw AnalysisError(code: errorCode, message: errorMessage);
  }
}

/// Minimal stub HttpClientPort for existing ApiSourceAdapter tests.
class _StubHttpClient implements HttpClientPort {
  HttpResponseData? response;
  Object? errorToThrow;

  @override
  Future<HttpResponseData> request({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    return response!;
  }
}

// ============================================================================
// Test Data
// ============================================================================

final _testData = AnalysisDataSet(
  columns: [
    const AnalysisColumnInfo(name: 'temp', type: 'double'),
  ],
  rows: [
    {'temp': 72.0},
    {'temp': 73.0},
  ],
  rowCount: 2,
);

const _csvData =
    'date,temperature,status\n2024-01-01,72.0,active\n2024-01-02,73.5,active\n2024-01-03,74.0,inactive';

const _jsonData = '[{"name":"A","value":1},{"name":"B","value":2}]';

// ============================================================================
// Tests
// ============================================================================

void main() {
  // ==========================================================================
  // DataSourceRegistry (TC-001 to TC-010)
  // ==========================================================================
  group('DataSourceRegistry', () {
    late DataSourceRegistry registry;

    setUp(() {
      registry = DataSourceRegistry();
    });

    // TC-001: Register and query factgraph source
    test('TC-001: register and query factgraph source returns adapter data',
        () async {
      final adapter = MockDataSourceAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final result = await registry.queryData(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      );

      expect(result.columns.length, equals(1));
      expect(result.columns.first.name, equals('temp'));
      expect(result.rows.length, equals(2));
      expect(result.rowCount, equals(2));
      expect(result.rows[0]['temp'], equals(72.0));
      expect(result.rows[1]['temp'], equals(73.0));
      expect(adapter.lastQuery, equals('temperature'));
    });

    // TC-002: Register and query mcpIo source
    test('TC-002: register and query mcpIo source delegates to adapter',
        () async {
      final ioData = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'sensor', type: 'string'),
        ],
        rows: [
          {'sensor': 'thermometer-01'},
        ],
        rowCount: 1,
      );
      final adapter = MockDataSourceAdapter(ioData);
      registry.register(AnalysisSourceType.mcpIo, adapter);

      final result = await registry.queryData(
        sourceType: AnalysisSourceType.mcpIo,
        query: 'io://device1/temperature',
      );

      expect(result.columns.first.name, equals('sensor'));
      expect(result.rows.first['sensor'], equals('thermometer-01'));
      expect(adapter.lastQuery, equals('io://device1/temperature'));
    });

    // TC-003: Query unregistered source type throws source.unavailable
    test('TC-003: query unregistered source type throws source.unavailable',
        () async {
      expect(
        () => registry.queryData(
          sourceType: AnalysisSourceType.upload,
          query: 'some-data',
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });

    // TC-004: Query unavailable source throws source.unavailable
    test('TC-004: query unavailable source throws source.unavailable',
        () async {
      final adapter = MockDataSourceAdapter(_testData, available: false);
      registry.register(AnalysisSourceType.factgraph, adapter);

      expect(
        () => registry.queryData(
          sourceType: AnalysisSourceType.factgraph,
          query: 'temperature',
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });

    // TC-005: isAvailable returns true for registered available source
    test('TC-005: isAvailable returns true for registered available source',
        () async {
      final adapter = MockDataSourceAdapter(_testData, available: true);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final available =
          await registry.isAvailable(AnalysisSourceType.factgraph);
      expect(available, isTrue);
    });

    // TC-006: isAvailable returns false when no adapter registered
    test('TC-006: isAvailable returns false when no adapter registered',
        () async {
      final available =
          await registry.isAvailable(AnalysisSourceType.factgraph);
      expect(available, isFalse);
    });

    // TC-007: getSourceMetadata delegates to adapter
    test('TC-007: getSourceMetadata delegates to adapter', () async {
      final adapter = MockDataSourceAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final schema = await registry.getSourceMetadata(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      );

      expect(schema.columns.length, equals(1));
      expect(schema.columns.first.name, equals('temp'));
      expect(schema.columns.first.type, equals('double'));
    });

    // TC-008: subscribeStream with StreamableDataSource returns Stream
    test('TC-008: subscribeStream with StreamableDataSource returns Stream',
        () async {
      final adapter = MockStreamableAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final stream = registry.subscribeStream(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      );

      final future = stream.first;
      adapter.emit(_testData);

      final result = await future;
      expect(result.columns.first.name, equals('temp'));
      expect(result.rows.length, equals(2));

      adapter.close();
    });

    // TC-009: subscribeStream with non-streamable source emits error
    test('TC-009: subscribeStream with non-streamable source emits error',
        () async {
      final adapter = MockDataSourceAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final stream = registry.subscribeStream(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      );

      expect(
        stream,
        emitsError(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });

    // TC-010: queryData passes filter and timeRange through to adapter
    test('TC-010: queryData passes filter and timeRange through to adapter',
        () async {
      final adapter = MockDataSourceAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final filter = {'status': 'active', 'minTemp': 70.0};
      final timeRange = AnalysisTimeRange(
        start: DateTime(2024, 1, 1),
        end: DateTime(2024, 12, 31),
      );

      await registry.queryData(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
        filter: filter,
        timeRange: timeRange,
      );

      expect(adapter.lastQuery, equals('temperature'));
      expect(adapter.lastFilter, equals(filter));
      expect(adapter.lastTimeRange, isNotNull);
      expect(adapter.lastTimeRange!.start, equals(DateTime(2024, 1, 1)));
      expect(adapter.lastTimeRange!.end, equals(DateTime(2024, 12, 31)));
    });
  });

  // ==========================================================================
  // UploadSourceAdapter (TC-001 to TC-009)
  // ==========================================================================
  group('UploadSourceAdapter', () {
    late UploadSourceAdapter adapter;

    setUp(() {
      adapter = UploadSourceAdapter();
    });

    // TC-001: Parse CSV with header produces correct columns and rows
    test('TC-001: parse CSV with header produces correct columns and rows',
        () async {
      final result = await adapter.queryData(query: _csvData);

      expect(result.columns.length, equals(3));
      expect(result.columns[0].name, equals('date'));
      expect(result.columns[1].name, equals('temperature'));
      expect(result.columns[2].name, equals('status'));

      expect(result.rows.length, equals(3));
      expect(result.rowCount, equals(3));

      // First row values
      expect(result.rows[0]['date'], isA<DateTime>());
      expect(result.rows[0]['temperature'], equals(72.0));
      expect(result.rows[0]['status'], equals('active'));

      // Third row values
      expect(result.rows[2]['temperature'], equals(74.0));
      expect(result.rows[2]['status'], equals('inactive'));
    });

    // TC-002: CSV auto-detects numeric type for temperature column
    test('TC-002: CSV auto-detects numeric type for temperature column',
        () async {
      final result = await adapter.queryData(query: _csvData);

      // date column parsed as DateTime => type inferred from first row
      final dateCol = result.columns.firstWhere((c) => c.name == 'date');
      expect(dateCol.type, equals('datetime'));

      // temperature column should be inferred as double
      final tempCol = result.columns.firstWhere((c) => c.name == 'temperature');
      expect(tempCol.type, equals('double'));

      // status column should remain string
      final statusCol = result.columns.firstWhere((c) => c.name == 'status');
      expect(statusCol.type, equals('string'));
    });

    // TC-003: Parse JSON array produces correct columns and rows
    test('TC-003: parse JSON array produces correct columns and rows',
        () async {
      final result = await adapter.queryData(query: _jsonData);

      expect(result.columns.length, equals(2));
      expect(result.columns[0].name, equals('name'));
      expect(result.columns[1].name, equals('value'));

      expect(result.rows.length, equals(2));
      expect(result.rowCount, equals(2));
      expect(result.rows[0]['name'], equals('A'));
      expect(result.rows[0]['value'], equals(1));
      expect(result.rows[1]['name'], equals('B'));
      expect(result.rows[1]['value'], equals(2));
    });

    // TC-004: CSV with inconsistent column count throws schema_mismatch
    test(
        'TC-004: CSV with inconsistent column count throws source.schema_mismatch',
        () async {
      const badCsv = 'a,b,c\n1,2,3\n4,5';

      expect(
        () => adapter.queryData(query: badCsv),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.schema_mismatch'),
          ),
        ),
      );
    });

    // TC-005: JSON non-array content throws source.schema_mismatch
    test('TC-005: JSON non-array content throws source.schema_mismatch',
        () async {
      const jsonObject = '{"key":"value"}';

      expect(
        () => adapter.queryData(query: jsonObject),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.schema_mismatch'),
          ),
        ),
      );
    });

    // TC-006: Empty CSV (header only) produces empty rows
    test('TC-006: empty CSV (header only) produces empty rows', () async {
      const headerOnly = 'name,value,status';

      final result = await adapter.queryData(query: headerOnly);

      expect(result.columns.length, equals(3));
      expect(result.columns[0].name, equals('name'));
      expect(result.columns[1].name, equals('value'));
      expect(result.columns[2].name, equals('status'));
      expect(result.rows, isEmpty);
      expect(result.rowCount, equals(0));
    });

    // TC-007: isAvailable always returns true
    test('TC-007: isAvailable always returns true', () async {
      final result = await adapter.isAvailable();
      expect(result, isTrue);
    });

    // TC-008: Auto-detect comma delimiter
    test('TC-008: auto-detect comma delimiter', () async {
      const commaCsv = 'x,y\n1,2\n3,4';

      final result = await adapter.queryData(query: commaCsv);

      expect(result.columns.length, equals(2));
      expect(result.columns[0].name, equals('x'));
      expect(result.columns[1].name, equals('y'));
      expect(result.rows.length, equals(2));
      expect(result.rows[0]['x'], equals(1));
      expect(result.rows[0]['y'], equals(2));
    });

    // TC-009: Auto-detect tab delimiter
    test('TC-009: auto-detect tab delimiter', () async {
      const tabCsv = 'col_a\tcol_b\n10\t20\n30\t40';

      final result = await adapter.queryData(query: tabCsv);

      expect(result.columns.length, equals(2));
      expect(result.columns[0].name, equals('col_a'));
      expect(result.columns[1].name, equals('col_b'));
      expect(result.rows.length, equals(2));
      expect(result.rows[0]['col_a'], equals(10));
      expect(result.rows[0]['col_b'], equals(20));
      expect(result.rows[1]['col_a'], equals(30));
      expect(result.rows[1]['col_b'], equals(40));
    });
  });

  // ==========================================================================
  // UploadSourceAdapter - setContent (TC-010 to TC-012)
  // ==========================================================================
  group('UploadSourceAdapter setContent', () {
    late UploadSourceAdapter adapter;

    setUp(() {
      adapter = UploadSourceAdapter();
    });

    // TC-010: setContent with explicit format overrides detection
    test('TC-010: setContent stores content for subsequent queryData',
        () async {
      adapter.setContent(_csvData, format: 'csv');

      // query parameter is ignored when content is pre-set
      final result = await adapter.queryData(query: 'ignored');

      expect(result.columns.length, equals(3));
      expect(result.rows.length, equals(3));
    });

    // TC-011: setContent auto-detects JSON format
    test('TC-011: setContent auto-detects JSON format', () async {
      adapter.setContent(_jsonData);

      final result = await adapter.queryData(query: 'ignored');

      expect(result.columns.length, equals(2));
      expect(result.rows[0]['name'], equals('A'));
    });

    // TC-012: getSourceMetadata returns column schema from content
    test('TC-012: getSourceMetadata returns column schema from content',
        () async {
      adapter.setContent(_csvData);

      final schema = await adapter.getSourceMetadata('ignored');

      expect(schema.columns.length, equals(3));
      expect(schema.columns[0].name, equals('date'));
      expect(schema.columns[1].name, equals('temperature'));
      expect(schema.columns[2].name, equals('status'));
    });
  });

  // ==========================================================================
  // UploadSourceAdapter - JSON edge cases (TC-013 to TC-015)
  // ==========================================================================
  group('UploadSourceAdapter JSON edge cases', () {
    late UploadSourceAdapter adapter;

    setUp(() {
      adapter = UploadSourceAdapter();
    });

    // TC-013: JSON with boolean and null values
    test('TC-013: JSON with boolean and null values', () async {
      const json = '[{"flag":true,"count":null},{"flag":false,"count":5}]';

      final result = await adapter.queryData(query: json);

      expect(result.rows[0]['flag'], isTrue);
      expect(result.rows[0]['count'], isNull);
      expect(result.rows[1]['flag'], isFalse);
      expect(result.rows[1]['count'], equals(5));
    });

    // TC-014: Empty JSON array produces empty dataset
    test('TC-014: empty JSON array produces empty dataset', () async {
      const emptyJson = '[]';

      final result = await adapter.queryData(query: emptyJson);

      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
      expect(result.rowCount, equals(0));
    });

    // TC-015: JSON column type inference from first row
    test('TC-015: JSON column type inference from first row', () async {
      final result = await adapter.queryData(query: _jsonData);

      final nameCol = result.columns.firstWhere((c) => c.name == 'name');
      expect(nameCol.type, equals('string'));

      final valueCol = result.columns.firstWhere((c) => c.name == 'value');
      expect(valueCol.type, equals('int'));
    });
  });

  // ==========================================================================
  // UploadSourceAdapter - CSV value parsing (TC-016 to TC-018)
  // ==========================================================================
  group('UploadSourceAdapter CSV value parsing', () {
    late UploadSourceAdapter adapter;

    setUp(() {
      adapter = UploadSourceAdapter();
    });

    // TC-016: Boolean values in CSV are parsed correctly
    test('TC-016: boolean values in CSV are parsed correctly', () async {
      const csv = 'name,active\nAlice,true\nBob,false';

      final result = await adapter.queryData(query: csv);

      expect(result.rows[0]['active'], isTrue);
      expect(result.rows[1]['active'], isFalse);
    });

    // TC-017: Integer values in CSV remain as int (not double)
    test('TC-017: integer values in CSV remain as int', () async {
      const csv = 'id,count\n1,100\n2,200';

      final result = await adapter.queryData(query: csv);

      expect(result.rows[0]['id'], isA<int>());
      expect(result.rows[0]['id'], equals(1));
      expect(result.rows[0]['count'], isA<int>());
      expect(result.rows[0]['count'], equals(100));
    });

    // TC-018: Empty field values are parsed as null
    test('TC-018: empty field values are parsed as null', () async {
      const csv = 'a,b\nval,\n,val2';

      final result = await adapter.queryData(query: csv);

      expect(result.rows[0]['a'], equals('val'));
      expect(result.rows[0]['b'], isNull);
      expect(result.rows[1]['a'], isNull);
      expect(result.rows[1]['b'], equals('val2'));
    });
  });

  // ==========================================================================
  // DataSourceRegistry - unregister (TC-011 to TC-012)
  // ==========================================================================
  group('DataSourceRegistry unregister', () {
    late DataSourceRegistry registry;

    setUp(() {
      registry = DataSourceRegistry();
    });

    // TC-011: Unregister removes adapter so isAvailable returns false
    test('TC-011: unregister removes adapter', () async {
      final adapter = MockDataSourceAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      expect(await registry.isAvailable(AnalysisSourceType.factgraph), isTrue);

      registry.unregister(AnalysisSourceType.factgraph);

      expect(await registry.isAvailable(AnalysisSourceType.factgraph), isFalse);
    });

    // TC-012: Unregistered source query throws after unregister
    test('TC-012: query after unregister throws source.unavailable', () async {
      final adapter = MockDataSourceAdapter(_testData);
      registry.register(AnalysisSourceType.upload, adapter);
      registry.unregister(AnalysisSourceType.upload);

      expect(
        () => registry.queryData(
          sourceType: AnalysisSourceType.upload,
          query: 'data',
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // DataSourceRegistry - getSourceMetadata edge cases
  // ==========================================================================
  group('DataSourceRegistry getSourceMetadata edge cases', () {
    late DataSourceRegistry registry;

    setUp(() {
      registry = DataSourceRegistry();
    });

    // Unregistered source type throws source.unavailable
    test('getSourceMetadata for unregistered source throws', () async {
      expect(
        () => registry.getSourceMetadata(
          sourceType: AnalysisSourceType.factgraph,
          query: 'temperature',
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // DataSourceRegistry - subscribeStream edge cases
  // ==========================================================================
  group('DataSourceRegistry subscribeStream edge cases', () {
    late DataSourceRegistry registry;

    setUp(() {
      registry = DataSourceRegistry();
    });

    // subscribeStream with unregistered source emits error
    test('subscribeStream with unregistered source emits error', () {
      final stream = registry.subscribeStream(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      );

      expect(
        stream,
        emitsError(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });

    // subscribeStream passes filter to adapter
    test('subscribeStream passes filter to streamable adapter', () async {
      final adapter = MockStreamableAdapter(_testData);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final stream = registry.subscribeStream(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
        filter: {'unit': 'celsius'},
      );

      final future = stream.first;
      adapter.emit(_testData);

      final result = await future;
      expect(result.rowCount, equals(2));

      adapter.close();
    });
  });

  // ==========================================================================
  // Integration: multiple adapters registered
  // ==========================================================================
  group('Integration', () {
    late DataSourceRegistry registry;

    setUp(() {
      registry = DataSourceRegistry();
    });

    // Three adapters registered route to correct adapter
    test('3 adapters registered routes queries to correct adapter', () async {
      final factgraphData = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'fact', type: 'string')],
        rows: [
          {'fact': 'knowledge-item'},
        ],
        rowCount: 1,
      );
      final uploadData = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'uploaded', type: 'string')],
        rows: [
          {'uploaded': 'file-content'},
        ],
        rowCount: 1,
      );
      final externalData = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'api', type: 'string')],
        rows: [
          {'api': 'external-data'},
        ],
        rowCount: 1,
      );

      registry.register(
          AnalysisSourceType.factgraph, MockDataSourceAdapter(factgraphData));
      registry.register(
          AnalysisSourceType.upload, MockDataSourceAdapter(uploadData));
      registry.register(
          AnalysisSourceType.external, MockDataSourceAdapter(externalData));

      final r1 = await registry.queryData(
        sourceType: AnalysisSourceType.factgraph,
        query: 'q1',
      );
      expect(r1.columns.first.name, equals('fact'));

      final r2 = await registry.queryData(
        sourceType: AnalysisSourceType.upload,
        query: 'q2',
      );
      expect(r2.columns.first.name, equals('uploaded'));

      final r3 = await registry.queryData(
        sourceType: AnalysisSourceType.external,
        query: 'q3',
      );
      expect(r3.columns.first.name, equals('api'));
    });

    // Adapter error propagated through registry
    test('adapter error is propagated through registry', () async {
      final errorAdapter = ErrorThrowingAdapter(
        errorCode: 'adapter.error',
        errorMessage: 'Simulated adapter failure',
      );
      registry.register(AnalysisSourceType.factgraph, errorAdapter);

      expect(
        () => registry.queryData(
          sourceType: AnalysisSourceType.factgraph,
          query: 'temperature',
        ),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', equals('adapter.error'))
              .having((e) => e.message, 'message',
                  equals('Simulated adapter failure')),
        ),
      );
    });

    // Registry implements AnalysisDataSourcePort interface
    test('registry implements AnalysisDataSourcePort', () {
      expect(registry, isA<AnalysisDataSourcePort>());
    });

    // isAvailable returns false for adapter that reports unavailable
    test('isAvailable returns false for adapter that reports unavailable',
        () async {
      final adapter = MockDataSourceAdapter(_testData, available: false);
      registry.register(AnalysisSourceType.factgraph, adapter);

      final available =
          await registry.isAvailable(AnalysisSourceType.factgraph);
      expect(available, isFalse);
    });

    // Register replaces existing adapter for same source type
    test('register replaces existing adapter for same source type', () async {
      final firstData = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'v1', type: 'string')],
        rows: [
          {'v1': 'first'},
        ],
        rowCount: 1,
      );
      final secondData = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'v2', type: 'string')],
        rows: [
          {'v2': 'second'},
        ],
        rowCount: 1,
      );

      registry.register(
          AnalysisSourceType.upload, MockDataSourceAdapter(firstData));
      registry.register(
          AnalysisSourceType.upload, MockDataSourceAdapter(secondData));

      final result = await registry.queryData(
        sourceType: AnalysisSourceType.upload,
        query: 'data',
      );

      expect(result.columns.first.name, equals('v2'));
      expect(result.rows.first['v2'], equals('second'));
    });
  });

  // ==========================================================================
  // IoSourceAdapter (TC-030 to TC-039)
  // ==========================================================================
  group('IoSourceAdapter', () {
    // TC-030: queryData with valid IoStreamPort response
    test('TC-030: queryData returns AnalysisDataSet from IoStream', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      final result = await adapter.queryData(query: 'io://device1/temp');

      expect(result.columns, isNotEmpty);
      expect(result.columns.any((c) => c.name == '_timestamp'), isTrue);
      expect(result.columns.any((c) => c.name == 'value'), isTrue);
    });

    // TC-031: subscribe returns Stream<AnalysisDataSet>
    test('TC-031: subscribe returns Stream<AnalysisDataSet>', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(
        query: 'io://device1/temp',
      );

      expect(stream, isA<Stream<AnalysisDataSet>>());

      final first = await stream.first;
      expect(first.rowCount, equals(1));
      expect(first.columns.any((c) => c.name == 'value'), isTrue);
    });

    // TC-032: isAvailable checks listSubscriptions
    test('TC-032: isAvailable returns true when listSubscriptions succeeds',
        () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final available = await adapter.isAvailable();
      expect(available, isTrue);
    });

    // TC-033: isAvailable returns false when port throws
    test('TC-033: isAvailable returns false when listSubscriptions throws',
        () async {
      final port = _FailingListSubscriptionsPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final available = await adapter.isAvailable();
      expect(available, isFalse);
    });

    // TC-034: getSourceMetadata returns IoStream schema
    test('TC-034: getSourceMetadata returns IoStream schema', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final schema = await adapter.getSourceMetadata('io://device1/temp');

      expect(schema.columns, isNotEmpty);
      expect(schema.columns.any((c) => c.name == '_timestamp'), isTrue);
      expect(schema.columns.any((c) => c.name == 'value'), isTrue);
      expect(schema.timestampField, equals('_timestamp'));
    });
  });

  // ==========================================================================
  // Source Timeout (TC-040)
  // ==========================================================================
  group('SourceTimeout', () {
    // TC-040: IoSourceAdapter throws source.timeout
    test('TC-040: IoSourceAdapter throws source.timeout on query timeout',
        () async {
      final slowPort = _SlowIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: slowPort,
        queryTimeout: const Duration(milliseconds: 50),
      );

      expect(
        () => adapter.queryData(query: 'io://device1/temp'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'source.timeout',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // IoSourceAdapter coverage boost
  // ==========================================================================
  group('IoSourceAdapter coverage boost', () {
    // queryData with non-io:// URI (fallback parsing path)
    test('queryData with non-io:// URI uses fallback parsing', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      final result = await adapter.queryData(query: 'raw-topic-name');

      expect(result.columns, isNotEmpty);
      // Fallback: deviceId='unknown', metric='value', topic='raw-topic-name'
      expect(result.rows, isNotEmpty);
      expect(result.rows.first['_deviceId'], equals('unknown'));
    });

    // queryData with io:// URI but no metric segment
    test('queryData with io:// URI missing metric uses default', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      final result = await adapter.queryData(query: 'io://device1');

      expect(result.columns, isNotEmpty);
      expect(result.rows.first['_deviceId'], equals('device1'));
    });

    // subscribe with non-io:// URI
    test('subscribe with non-io:// URI uses fallback parsing', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(query: 'plain-topic');
      expect(stream, isA<Stream<AnalysisDataSet>>());

      final first = await stream.first;
      expect(first.rowCount, equals(1));
      expect(first.rows.first['_deviceId'], equals('unknown'));
    });

    // subscribe emits error when port throws unauthorized
    test('subscribe emits source.unauthorized on unauthorized error', () async {
      final port = _UnauthorizedIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(query: 'io://restricted/temp');

      expect(
        stream,
        emitsError(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'source.unauthorized',
          ),
        ),
      );
    });

    // subscribe emits source.unavailable on generic error
    test('subscribe emits source.unavailable on generic error', () async {
      final port = _GenericErrorIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(query: 'io://device/temp');

      expect(
        stream,
        emitsError(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'source.unavailable',
          ),
        ),
      );
    });

    // subscribe emits AnalysisError directly when port throws AnalysisError
    test('subscribe re-emits AnalysisError from port', () async {
      final port = _AnalysisErrorIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(query: 'io://device/temp');

      expect(
        stream,
        emitsError(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'custom.port_error',
          ),
        ),
      );
    });

    // queryData rethrows AnalysisError from non-timeout path
    test('queryData rethrows AnalysisError from port', () async {
      final port = _AnalysisErrorIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      expect(
        () => adapter.queryData(query: 'io://device/temp'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'custom.port_error',
          ),
        ),
      );
    });

    // queryData wraps generic error as source.unavailable
    test('queryData wraps generic error as source.unavailable', () async {
      final port = _GenericErrorIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      expect(
        () => adapter.queryData(query: 'io://device/temp'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'source.unavailable',
          ),
        ),
      );
    });

    // queryData handles envelope with non-numeric value
    test('queryData handles non-numeric payload value', () async {
      final port = _StringValueIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      final result = await adapter.queryData(query: 'io://device1/status');

      expect(result.rows, isNotEmpty);
      expect(result.rows.first['value'], equals('active'));
    });

    // queryData handles envelope with no unit
    test('queryData handles envelope with no unit', () async {
      final port = _NoUnitIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      final result = await adapter.queryData(query: 'io://device1/temp');

      expect(result.rows, isNotEmpty);
      // _unit key should not be in the row when unit is null
      expect(result.rows.first.containsKey('_unit'), isFalse);
    });

    // subscribe handles envelope with filter parameter
    test('subscribe passes filter parameter', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(
        query: 'io://device1/temp',
        filter: {'unit': 'celsius'},
      );

      final first = await stream.first;
      expect(first.rowCount, equals(1));
    });

    // queryData with empty io:// path
    test('queryData with empty io:// path uses unknown deviceId', () async {
      final port = _MockIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      final result = await adapter.queryData(query: 'io://');

      expect(result.rows, isNotEmpty);
    });
  });

  // ==========================================================================
  // Source Unauthorized (TC-042)
  // ==========================================================================
  group('SourceUnauthorized', () {
    // TC-042: IoSourceAdapter throws source.unauthorized
    test('TC-042: IoSourceAdapter throws source.unauthorized', () async {
      final authPort = _UnauthorizedIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: authPort);

      expect(
        () => adapter.queryData(query: 'io://restricted/temp'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'source.unauthorized',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // ApiSourceAdapter (TC-050 to TC-057)
  // ==========================================================================
  group('ApiSourceAdapter', () {
    late _StubHttpClient httpClient;
    late ApiSourceAdapter adapter;

    setUp(() {
      httpClient = _StubHttpClient();
      adapter = ApiSourceAdapter(httpClient: httpClient);
    });

    // TC-050: queryData with invalid query JSON throws schema_mismatch
    test(
        'TC-050: queryData with invalid query JSON throws source.schema_mismatch',
        () async {
      expect(
        () => adapter.queryData(query: 'not-json'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.schema_mismatch'),
          ),
        ),
      );
    });

    // TC-051: getSourceMetadata returns empty schema when no mapping
    test('TC-051: getSourceMetadata returns empty column schema', () async {
      const query = '{"url":"https://api.example.com/data"}';
      final schema = await adapter.getSourceMetadata(query);

      expect(schema.columns, isEmpty);
    });

    // TC-052: isAvailable returns true
    test('TC-052: isAvailable returns true', () async {
      final available = await adapter.isAvailable();
      expect(available, isTrue);
    });

    // TC-053: timeout from HTTP client produces source.timeout
    test('TC-053: timeout produces source.timeout', () async {
      httpClient.errorToThrow = TimeoutException('timed out');

      const query = '{"url":"https://api.example.com/data"}';
      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.timeout'),
          ),
        ),
      );
    });

    // TC-054: 401 status produces source.unauthorized
    test('TC-054: 401 produces source.unauthorized', () async {
      httpClient.response = const HttpResponseData(
        statusCode: 401,
        body: '{"error":"Unauthorized"}',
      );

      const query = '{"url":"https://api.example.com/data"}';
      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unauthorized'),
          ),
        ),
      );
    });

    // TC-055: connection failure throws source.unavailable
    test('TC-055: connection failure throws source.unavailable', () async {
      httpClient.errorToThrow = Exception('Connection refused');

      const query = '{"url":"https://api.example.com/data"}';
      expect(
        () => adapter.queryData(query: query),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unavailable'),
          ),
        ),
      );
    });

    // TC-056: custom timeout is configurable
    test('TC-056: custom timeout is configurable', () {
      final customAdapter = ApiSourceAdapter(
        httpClient: httpClient,
        queryTimeout: const Duration(seconds: 60),
      );
      expect(customAdapter.queryTimeout, const Duration(seconds: 60));
    });

    // TC-057: default timeout is 30 seconds
    test('TC-057: default timeout is 30 seconds', () {
      expect(adapter.queryTimeout, const Duration(seconds: 30));
    });
  });

  // ==========================================================================
  // UploadSourceAdapter - coverage boost for uncovered branches
  // ==========================================================================
  group('UploadSourceAdapter coverage boost', () {
    late UploadSourceAdapter adapter;

    setUp(() {
      adapter = UploadSourceAdapter();
    });

    // Unsupported format in setContent triggers default branch
    test('setContent with unsupported format throws schema_mismatch', () async {
      adapter.setContent('some data', format: 'xml');

      expect(
        () => adapter.queryData(query: 'ignored'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.schema_mismatch'),
          ),
        ),
      );
    });

    // getSourceMetadata for JSON content uses _parseJson path
    test('getSourceMetadata with JSON content returns correct schema',
        () async {
      adapter.setContent('[{"x":1,"y":"hello"}]', format: 'json');

      final schema = await adapter.getSourceMetadata('ignored');

      expect(schema.columns.length, equals(2));
      expect(schema.columns[0].name, equals('x'));
      expect(schema.columns[1].name, equals('y'));
    });

    // JSON with escape sequences in strings
    test('JSON string with escape sequences parses correctly', () async {
      const json = '[{"msg":"hello \\"world\\"","val":42}]';

      final result = await adapter.queryData(query: json);

      expect(result.rows.length, equals(1));
      expect(result.rows[0]['msg'], equals('hello "world"'));
      expect(result.rows[0]['val'], equals(42));
    });

    // Semicolon-delimited CSV
    test('CSV with semicolon delimiter is auto-detected', () async {
      const csv = 'a;b;c\n1;2;3\n4;5;6';

      final result = await adapter.queryData(query: csv);

      expect(result.columns.length, equals(3));
      expect(result.columns[0].name, equals('a'));
      expect(result.rows.length, equals(2));
      expect(result.rows[0]['a'], equals(1));
      expect(result.rows[0]['b'], equals(2));
    });

    // Empty CSV content produces empty dataset
    test('completely empty CSV content produces empty dataset', () async {
      const csv = '';

      final result = await adapter.queryData(query: csv);

      expect(result.columns, isEmpty);
      expect(result.rows, isEmpty);
      expect(result.rowCount, equals(0));
    });

    // JSON with nested objects and arrays
    test('JSON with nested objects and arrays parses correctly', () async {
      const json = '[{"name":"A","meta":{"score":10},"tags":[1,2]}]';

      final result = await adapter.queryData(query: json);

      expect(result.rows.length, equals(1));
      expect(result.rows[0]['name'], equals('A'));
      // Nested object parsed as map
      final meta = result.rows[0]['meta'];
      expect(meta, isA<Map<dynamic, dynamic>>());
      expect((meta as Map<dynamic, dynamic>)['score'], equals(10));
      // Array parsed as list
      final tags = result.rows[0]['tags'];
      expect(tags, isA<List<dynamic>>());
      expect(tags, containsAll([1, 2]));
    });

    // JSON with double values (floating point primitives)
    test('JSON with double values parses correctly', () async {
      const json = '[{"pi":3.14,"neg":-1.5}]';

      final result = await adapter.queryData(query: json);

      expect(result.rows[0]['pi'], closeTo(3.14, 0.001));
      expect(result.rows[0]['neg'], closeTo(-1.5, 0.001));
    });

    // JSON with false boolean value
    test('JSON with false primitive parses correctly', () async {
      const json = '[{"active":false}]';

      final result = await adapter.queryData(query: json);

      expect(result.rows[0]['active'], isFalse);
    });

    // _inferType for bool type in CSV (first row has bool)
    test('CSV column type inferred as bool when first row is boolean',
        () async {
      const csv = 'flag,count\ntrue,10\nfalse,20';

      final result = await adapter.queryData(query: csv);

      final flagCol = result.columns.firstWhere((c) => c.name == 'flag');
      expect(flagCol.type, equals('bool'));
    });

    // _inferType for int type in CSV
    test('CSV column type inferred as int when first row is integer', () async {
      const csv = 'id,name\n42,Alice';

      final result = await adapter.queryData(query: csv);

      final idCol = result.columns.firstWhere((c) => c.name == 'id');
      expect(idCol.type, equals('int'));
    });

    // _inferType for DateTime value parsed in CSV
    test('CSV column type inferred as datetime for date strings', () async {
      const csv = 'ts,val\n2024-01-01,100';

      final result = await adapter.queryData(query: csv);

      final tsCol = result.columns.firstWhere((c) => c.name == 'ts');
      expect(tsCol.type, equals('datetime'));
    });

    // queryData with filter parameter (filter is not used by upload but should not crash)
    test('queryData with filter parameter does not crash', () async {
      const csv = 'a,b\n1,2';

      final result = await adapter.queryData(
        query: csv,
        filter: {'key': 'value'},
      );

      expect(result.rows.length, equals(1));
    });
  });

  // ==========================================================================
  // IoSourceAdapter - stream error in queryData (onError callback)
  // ==========================================================================
  group('IoSourceAdapter queryData stream error', () {
    // queryData where stream emits error before completing
    test('queryData with stream error completes without crashing', () async {
      final port = _StreamErrorIoStreamPort();
      final adapter = IoSourceAdapter(
        ioStreamPort: port,
        queryTimeout: const Duration(seconds: 2),
      );

      // The stream emits an error, which triggers onError and completes
      // the completer. Since the error is handled by completing the future,
      // queryData should return whatever rows were collected before the error.
      final result = await adapter.queryData(query: 'io://device1/temp');
      expect(result.columns, isNotEmpty);
    });

    // subscribe stream emits non-numeric value
    test('subscribe with non-numeric payload value', () async {
      final port = _StringValueIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(query: 'io://device1/status');
      final first = await stream.first;
      expect(first.rowCount, equals(1));
      expect(first.rows.first['value'], equals('active'));
    });

    // subscribe stream handles envelope without unit
    test('subscribe with envelope without unit', () async {
      final port = _NoUnitIoStreamPort();
      final adapter = IoSourceAdapter(ioStreamPort: port);

      final stream = adapter.subscribe(query: 'io://device1/temp');
      final first = await stream.first;
      expect(first.rowCount, equals(1));
      // _unit key should not be present when unit is null
      expect(first.rows.first.containsKey('_unit'), isFalse);
    });
  });
}

// ============================================================================
// Helper Mocks for IoSourceAdapter
// ============================================================================

/// Mock IoStreamPort that returns a finite stream of envelopes.
class _MockIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) async {
    final controller = StreamController<PayloadEnvelope>();
    final handle = SubscriptionHandle(
      subscriptionId: 'sub-mock-001',
      topic: spec.uri,
      mode: spec.mode,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    // Emit one envelope and close
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      controller.add(PayloadEnvelope(
        uri: spec.uri,
        kind: PayloadKind.stream,
        payload: TypedPayload(
          type: PayloadType.scalar,
          value: 72.5,
          unit: 'celsius',
          timestamp: DateTime.now(),
          quality: Quality.ok,
        ),
        meta: EnvelopeMeta(
          capturedAt: DateTime.now(),
          sourceAddress: 'device1',
        ),
      ));
      controller.close();
    });

    return IoStreamSubscription(
      handle: handle,
      stream: controller.stream,
    );
  }

  @override
  Future<void> unsubscribe(String subscriptionId) async {}

  @override
  Future<List<SubscriptionHandle>> listSubscriptions({
    String? consumerId,
    String? deviceId,
  }) async {
    return [];
  }

  @override
  Future<SubscriptionStatus?> getStatus(String subscriptionId) async => null;
}

/// IoStreamPort that delays forever (for timeout testing).
class _SlowIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) {
    return Future.delayed(const Duration(seconds: 10), () {
      throw TimeoutException('Timed out');
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// IoStreamPort that throws unauthorized error.
class _UnauthorizedIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) {
    throw Exception('Forbidden: unauthorized access');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// IoStreamPort that throws a generic (non-auth) error.
class _GenericErrorIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) {
    throw Exception('Connection reset by peer');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// IoStreamPort that throws an AnalysisError.
class _AnalysisErrorIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) {
    throw AnalysisError(
      code: 'custom.port_error',
      message: 'Custom port error',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// IoStreamPort that returns a string payload value (non-numeric).
class _StringValueIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) async {
    final controller = StreamController<PayloadEnvelope>();
    final handle = SubscriptionHandle(
      subscriptionId: 'sub-str-001',
      topic: spec.uri,
      mode: spec.mode,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    Future<void>.delayed(const Duration(milliseconds: 10), () {
      controller.add(PayloadEnvelope(
        uri: spec.uri,
        kind: PayloadKind.stream,
        payload: TypedPayload(
          type: PayloadType.scalar,
          value: 'active',
          unit: 'status',
          timestamp: DateTime.now(),
          quality: Quality.ok,
        ),
        meta: EnvelopeMeta(
          capturedAt: DateTime.now(),
          sourceAddress: 'device1',
        ),
      ));
      controller.close();
    });

    return IoStreamSubscription(
      handle: handle,
      stream: controller.stream,
    );
  }

  @override
  Future<void> unsubscribe(String subscriptionId) async {}

  @override
  Future<List<SubscriptionHandle>> listSubscriptions({
    String? consumerId,
    String? deviceId,
  }) async {
    return [];
  }

  @override
  Future<SubscriptionStatus?> getStatus(String subscriptionId) async => null;
}

/// IoStreamPort that returns a payload with no unit.
class _NoUnitIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) async {
    final controller = StreamController<PayloadEnvelope>();
    final handle = SubscriptionHandle(
      subscriptionId: 'sub-nounit-001',
      topic: spec.uri,
      mode: spec.mode,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    Future<void>.delayed(const Duration(milliseconds: 10), () {
      controller.add(PayloadEnvelope(
        uri: spec.uri,
        kind: PayloadKind.stream,
        payload: TypedPayload(
          type: PayloadType.scalar,
          value: 72.5,
          // unit intentionally omitted (null)
          timestamp: DateTime.now(),
          quality: Quality.ok,
        ),
        meta: EnvelopeMeta(
          capturedAt: DateTime.now(),
          sourceAddress: 'device1',
        ),
      ));
      controller.close();
    });

    return IoStreamSubscription(
      handle: handle,
      stream: controller.stream,
    );
  }

  @override
  Future<void> unsubscribe(String subscriptionId) async {}

  @override
  Future<List<SubscriptionHandle>> listSubscriptions({
    String? consumerId,
    String? deviceId,
  }) async {
    return [];
  }

  @override
  Future<SubscriptionStatus?> getStatus(String subscriptionId) async => null;
}

/// IoStreamPort whose stream emits an error after one envelope.
class _StreamErrorIoStreamPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) async {
    final controller = StreamController<PayloadEnvelope>();
    final handle = SubscriptionHandle(
      subscriptionId: 'sub-err-001',
      topic: spec.uri,
      mode: spec.mode,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    // Emit one envelope, then an error, then close
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      controller.add(PayloadEnvelope(
        uri: spec.uri,
        kind: PayloadKind.stream,
        payload: TypedPayload(
          type: PayloadType.scalar,
          value: 42.0,
          unit: 'celsius',
          timestamp: DateTime.now(),
          quality: Quality.ok,
        ),
        meta: EnvelopeMeta(
          capturedAt: DateTime.now(),
          sourceAddress: 'device1',
        ),
      ));
      controller.addError(Exception('Stream disrupted'));
      controller.close();
    });

    return IoStreamSubscription(
      handle: handle,
      stream: controller.stream,
    );
  }

  @override
  Future<void> unsubscribe(String subscriptionId) async {}

  @override
  Future<List<SubscriptionHandle>> listSubscriptions({
    String? consumerId,
    String? deviceId,
  }) async {
    return [];
  }

  @override
  Future<SubscriptionStatus?> getStatus(String subscriptionId) async => null;
}

/// IoStreamPort whose listSubscriptions throws (for isAvailable test).
class _FailingListSubscriptionsPort implements IoStreamPort {
  @override
  Future<IoStreamSubscription> subscribe(
    TopicSpec spec, {
    required String consumerId,
  }) async {
    throw Exception('Not available');
  }

  @override
  Future<void> unsubscribe(String subscriptionId) async {}

  @override
  Future<List<SubscriptionHandle>> listSubscriptions({
    String? consumerId,
    String? deviceId,
  }) async {
    throw Exception('Connection refused');
  }

  @override
  Future<SubscriptionStatus?> getStatus(String subscriptionId) async => null;
}
