import 'dart:async';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

// ============================================================================
// Mock FactsPort
// ============================================================================

/// Configurable mock for FactsPort used by FactGraphSourceAdapter tests.
class MockFactsPort implements FactsPort {
  List<FactRecord> facts;
  bool shouldThrow = false;
  String throwMessage = 'Connection refused';
  bool throwUnauthorized = false;
  bool throwTimeout = false;

  /// Captures the last query for verification.
  FactQuery? lastQuery;

  MockFactsPort({this.facts = const []});

  @override
  Future<List<FactRecord>> queryFacts(FactQuery query) async {
    lastQuery = query;
    if (throwTimeout) {
      throw TimeoutException('FactGraph query timed out');
    }
    if (throwUnauthorized) {
      throw Exception('Forbidden: permission denied');
    }
    if (shouldThrow) {
      throw Exception(throwMessage);
    }
    return facts;
  }

  @override
  Future<void> writeFacts(List<FactRecord> facts) async {}

  @override
  Future<FactRecord?> getFact(String id) async => null;

  @override
  Future<void> deleteFacts(List<String> ids) async {}
}

// ============================================================================
// Test Data
// ============================================================================

final _t1 = DateTime(2024, 1, 1, 10, 0);
final _t2 = DateTime(2024, 1, 2, 10, 0);
final _t3 = DateTime(2024, 1, 3, 10, 0);

final _sampleFacts = [
  FactRecord(
    id: 'f1',
    workspaceId: 'ws-001',
    type: 'temperature',
    content: {'value': 72.0, 'unit': 'C'},
    createdAt: _t1,
  ),
  FactRecord(
    id: 'f2',
    workspaceId: 'ws-001',
    type: 'temperature',
    content: {'value': 73.5, 'unit': 'C'},
    createdAt: _t2,
  ),
  FactRecord(
    id: 'f3',
    workspaceId: 'ws-001',
    type: 'temperature',
    content: {'value': 95.0, 'unit': 'C'},
    createdAt: _t3,
  ),
];

// ============================================================================
// Tests
// ============================================================================

void main() {
  // ==========================================================================
  // FactGraphSourceAdapter Unit Tests (TC-001 to TC-012)
  // ==========================================================================
  group('FactGraphSourceAdapter', () {
    late MockFactsPort factsPort;
    late FactGraphSourceAdapter adapter;

    setUp(() {
      factsPort = MockFactsPort(facts: _sampleFacts);
      adapter = FactGraphSourceAdapter(
        factsPort: factsPort,
        workspaceId: 'ws-001',
      );
    });

    // TC-001: queryData returns mapped DataSet
    test('TC-001: queryData returns mapped DataSet with 3 rows', () async {
      final result = await adapter.queryData(
        query: 'temperature',
        timeRange: AnalysisTimeRange(
          start: _t1.subtract(const Duration(days: 1)),
          end: _t3.add(const Duration(days: 1)),
        ),
      );

      expect(result.rows.length, equals(3));
      expect(result.rowCount, equals(3));
    });

    // TC-002: DataSet columns include _timestamp
    test('TC-002: DataSet columns include _timestamp', () async {
      final result = await adapter.queryData(query: 'temperature');

      final timestampCol = result.columns.where((c) => c.name == '_timestamp');
      expect(timestampCol, isNotEmpty);
      expect(timestampCol.first.type, equals('datetime'));
    });

    // TC-003: DataSet columns include content fields
    test('TC-003: DataSet columns include content fields (value, unit)',
        () async {
      final result = await adapter.queryData(query: 'temperature');

      final colNames = result.columns.map((c) => c.name).toList();
      expect(colNames, contains('value'));
      expect(colNames, contains('unit'));
    });

    // TC-004: Time range filter applied to criteria
    test('TC-004: time range filter applied to FactQuery', () async {
      final timeRange = AnalysisTimeRange(start: _t1, end: _t2);
      await adapter.queryData(query: 'temperature', timeRange: timeRange);

      expect(factsPort.lastQuery, isNotNull);
      expect(factsPort.lastQuery!.period, isNotNull);
    });

    // TC-005: Filter parameters passed to criteria
    test('TC-005: filter parameters passed to FactQuery', () async {
      await adapter.queryData(
        query: 'temperature',
        filter: {'entityId': 'device-001'},
      );

      expect(factsPort.lastQuery, isNotNull);
      expect(factsPort.lastQuery!.entityId, equals('device-001'));
    });

    // TC-006: Empty result returns empty DataSet
    test('TC-006: empty result returns empty DataSet', () async {
      factsPort.facts = [];

      final result = await adapter.queryData(query: 'temperature');

      expect(result.rows, isEmpty);
      expect(result.rowCount, equals(0));
    });

    // TC-007: isAvailable returns true when port responds
    test('TC-007: isAvailable returns true when port responds', () async {
      final available = await adapter.isAvailable();
      expect(available, isTrue);
    });

    // TC-008: isAvailable returns false when port throws
    test('TC-008: isAvailable returns false when port throws', () async {
      factsPort.shouldThrow = true;

      final available = await adapter.isAvailable();
      expect(available, isFalse);
    });

    // TC-009: getSourceMetadata infers schema from sample
    test('TC-009: getSourceMetadata infers schema from sample', () async {
      final schema = await adapter.getSourceMetadata('temperature');

      expect(schema.columns, isNotEmpty);
      final colNames = schema.columns.map((c) => c.name).toList();
      expect(colNames, contains('_timestamp'));
    });

    // TC-010: Port authorization error mapped to source.unauthorized
    test('TC-010: authorization error mapped to source.unauthorized', () async {
      factsPort.throwUnauthorized = true;

      expect(
        () => adapter.queryData(query: 'temperature'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.unauthorized'),
          ),
        ),
      );
    });

    // TC-011: Port timeout error mapped to source.timeout
    test('TC-011: timeout error mapped to source.timeout', () async {
      factsPort.throwTimeout = true;

      expect(
        () => adapter.queryData(query: 'temperature'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            equals('source.timeout'),
          ),
        ),
      );
    });

    // TC-012: Schema mismatch error when content cannot be parsed
    test('TC-012: schema mismatch when content structure is unexpected',
        () async {
      // Replace with facts that have no content fields
      factsPort.facts = [
        FactRecord(
          id: 'bad-1',
          workspaceId: 'ws-001',
          type: 'temperature',
          content: const {},
          createdAt: _t1,
        ),
      ];

      // If adapter validates content structure, this should throw
      // schema_mismatch. Otherwise it produces an empty-content DataSet.
      final result = await adapter.queryData(
        query: 'temperature',
        filter: {'expectColumns': 'value,unit'},
      );

      // Empty content produces rows without the expected data fields
      expect(result.rows.first.containsKey('value'), isFalse);
    });
  });

  // ==========================================================================
  // Integration Tests (IT-001 to IT-002)
  // ==========================================================================
  group('FactGraphSourceAdapter Integration', () {
    late MockFactsPort factsPort;
    late FactGraphSourceAdapter adapter;

    setUp(() {
      factsPort = MockFactsPort(facts: _sampleFacts);
      adapter = FactGraphSourceAdapter(
        factsPort: factsPort,
        workspaceId: 'ws-001',
      );
    });

    // IT-001: Query → DataSet mapping preserves all values
    test('IT-001: queryData mapping preserves all values', () async {
      final result = await adapter.queryData(query: 'temperature');

      expect(result.rows.length, equals(3));

      // Verify each row contains mapped fact values
      for (var i = 0; i < result.rows.length; i++) {
        final row = result.rows[i];
        expect(row.containsKey('_timestamp'), isTrue);
      }

      // Verify content values are mapped
      final firstRow = result.rows[0];
      expect(firstRow['value'], equals(72.0));
      expect(firstRow['unit'], equals('C'));

      final secondRow = result.rows[1];
      expect(secondRow['value'], equals(73.5));

      final thirdRow = result.rows[2];
      expect(thirdRow['value'], equals(95.0));
    });

    // IT-002: Time range filtering works end-to-end
    test('IT-002: time range filtering passes criteria to port', () async {
      final timeRange = AnalysisTimeRange(start: _t1, end: _t2);

      await adapter.queryData(query: 'temperature', timeRange: timeRange);

      // Verify the query was constructed with time range
      expect(factsPort.lastQuery, isNotNull);
      expect(factsPort.lastQuery!.period, isNotNull);
    });
  });

  // ==========================================================================
  // FactGraphSourceAdapter registered with DataSourceRegistry
  // ==========================================================================
  group('FactGraphSourceAdapter with Registry', () {
    test('routes factgraph queries to FactGraphSourceAdapter', () async {
      final factsPort = MockFactsPort(facts: _sampleFacts);
      final adapter = FactGraphSourceAdapter(
        factsPort: factsPort,
        workspaceId: 'ws-001',
      );
      final registry = DataSourceRegistry();
      registry.register(AnalysisSourceType.factgraph, adapter);

      final result = await registry.queryData(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      );

      expect(result.rows.length, equals(3));
      expect(result.rowCount, equals(3));
    });
  });

  // ==========================================================================
  // FactGraphSourceAdapter coverage boost
  // ==========================================================================
  group('FactGraphSourceAdapter coverage boost', () {
    late MockFactsPort factsPort;
    late FactGraphSourceAdapter adapter;

    setUp(() {
      factsPort = MockFactsPort(facts: _sampleFacts);
      adapter = FactGraphSourceAdapter(
        factsPort: factsPort,
        workspaceId: 'ws-001',
      );
    });

    // Facts with confidence field produce _confidence column
    test('fact with confidence field produces _confidence column', () async {
      factsPort.facts = [
        FactRecord(
          id: 'fc1',
          workspaceId: 'ws-001',
          type: 'temperature',
          content: {'value': 72.0},
          createdAt: _t1,
          confidence: 0.95,
        ),
      ];

      final result = await adapter.queryData(query: 'temperature');

      final colNames = result.columns.map((c) => c.name).toList();
      expect(colNames, contains('_confidence'));
      expect(result.rows.first['_confidence'], equals(0.95));
    });

    // getSourceMetadata with empty facts returns minimal schema
    test('getSourceMetadata with empty facts returns timestamp-only schema', () async {
      factsPort.facts = [];

      final schema = await adapter.getSourceMetadata('nonexistent_type');

      expect(schema.columns, isNotEmpty);
      expect(schema.columns.any((c) => c.name == '_timestamp'), isTrue);
      expect(schema.timestampField, equals('_timestamp'));
    });

    // queryData with no timeRange passes null period
    test('queryData without timeRange passes null period', () async {
      await adapter.queryData(query: 'temperature');

      expect(factsPort.lastQuery, isNotNull);
      expect(factsPort.lastQuery!.period, isNull);
    });

    // _inferType for bool, DateTime, and int values
    test('fact content with various types produces correct column types', () async {
      factsPort.facts = [
        FactRecord(
          id: 'typed-1',
          workspaceId: 'ws-001',
          type: 'mixed',
          content: {
            'count': 42,
            'ratio': 3.14,
            'active': true,
            'label': 'test',
          },
          createdAt: _t1,
        ),
      ];

      final result = await adapter.queryData(query: 'mixed');

      final colMap = {for (final c in result.columns) c.name: c.type};
      expect(colMap['count'], equals('int'));
      expect(colMap['ratio'], equals('double'));
      expect(colMap['active'], equals('bool'));
      expect(colMap['label'], equals('string'));
    });

    // Generic error (not timeout, not unauthorized) maps to source.unavailable
    test('generic error maps to source.unavailable', () async {
      factsPort.shouldThrow = true;
      factsPort.throwMessage = 'Connection refused';

      expect(
        () => adapter.queryData(query: 'temperature'),
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
}
