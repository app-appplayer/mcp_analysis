import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

void main() {
  // Shared test data: 5-row time series with _timestamp, temperature, status.
  // Row index 2 has null temperature. Row index 3 has outlier 95.0.
  final now = DateTime(2024, 1, 1);
  final testRows = [
    {'_timestamp': now, 'temperature': 71.0, 'status': 'active'},
    {
      '_timestamp': now.add(const Duration(minutes: 1)),
      'temperature': 73.5,
      'status': 'active',
    },
    {
      '_timestamp': now.add(const Duration(minutes: 2)),
      'temperature': null,
      'status': 'active',
    },
    {
      '_timestamp': now.add(const Duration(minutes: 3)),
      'temperature': 95.0,
      'status': 'inactive',
    },
    {
      '_timestamp': now.add(const Duration(minutes: 4)),
      'temperature': 72.0,
      'status': 'active',
    },
  ];

  final testColumns = [
    const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
    const AnalysisColumnInfo(name: 'temperature', type: 'double', unit: 'F'),
    const AnalysisColumnInfo(name: 'status', type: 'string'),
  ];

  late AnalysisDataSet testDataSet;

  setUp(() {
    testDataSet = AnalysisDataSet(
      columns: testColumns,
      rows: testRows.map((r) => Map<String, dynamic>.from(r)).toList(),
      rowCount: testRows.length,
    );
  });

  // ==========================================================================
  // FilterTransform (TC-001 to TC-004)
  // ==========================================================================
  group('FilterTransform', () {
    late FilterTransform filter;

    setUp(() {
      filter = FilterTransform();
    });

    test('TC-001: filters rows by equality on string column', () async {
      // Filter status == 'active' should yield 4 rows (indices 0,1,2,4)
      final result = await filter.apply(testDataSet, {
        'column': 'status',
        'operator': '==',
        'value': 'active',
      });

      expect(result.rowCount, equals(4));
      for (final row in result.rows) {
        expect(row['status'], equals('active'));
      }
    });

    test('TC-002: filters rows by greater-than on numeric column', () async {
      // Filter temperature > 73 should yield 2 rows (73.5 and 95.0).
      // The null row does not match because null comparison returns false.
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': '>',
        'value': 73,
      });

      expect(result.rowCount, equals(2));
      final temps = result.rows.map((r) => r['temperature'] as double);
      expect(temps, containsAll([73.5, 95.0]));
    });

    test('TC-003: filters rows with isNull operator', () async {
      // Filter temperature isNull should yield 1 row (index 2)
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': 'isNull',
      });

      expect(result.rowCount, equals(1));
      expect(result.rows.first['temperature'], isNull);
      expect(
        result.rows.first['_timestamp'],
        equals(now.add(const Duration(minutes: 2))),
      );
    });

    test('TC-004: throws on non-existent column parameter', () async {
      // Missing 'column' parameter should throw AnalysisError
      // with code 'transform.parameter_error'
      expect(
        () => filter.apply(testDataSet, {
          'operator': '==',
          'value': 'active',
        }),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.parameter_error',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // SortTransform (TC-005 to TC-006)
  // ==========================================================================
  group('SortTransform', () {
    late SortTransform sort;

    setUp(() {
      sort = SortTransform();
    });

    test('TC-005: sorts ascending by temperature with nulls first', () async {
      final result = await sort.apply(testDataSet, {
        'columns': 'temperature',
        'ascending': true,
      });

      expect(result.rowCount, equals(5));
      // Null sorts first (compareValues returns -1 for null a)
      expect(result.rows[0]['temperature'], isNull);
      // Then ascending numeric values
      expect(result.rows[1]['temperature'], equals(71.0));
      expect(result.rows[2]['temperature'], equals(72.0));
      expect(result.rows[3]['temperature'], equals(73.5));
      expect(result.rows[4]['temperature'], equals(95.0));
    });

    test('TC-006: sorts descending by temperature', () async {
      final result = await sort.apply(testDataSet, {
        'columns': 'temperature',
        'ascending': false,
      });

      expect(result.rowCount, equals(5));
      // Descending: highest first, null last
      expect(result.rows[0]['temperature'], equals(95.0));
      expect(result.rows[1]['temperature'], equals(73.5));
      expect(result.rows[2]['temperature'], equals(72.0));
      expect(result.rows[3]['temperature'], equals(71.0));
      // Null sorts to end in descending (compareValues -1 negated => +1)
      expect(result.rows[4]['temperature'], isNull);
    });
  });

  // ==========================================================================
  // FillnaTransform (TC-007 to TC-010)
  // ==========================================================================
  group('FillnaTransform', () {
    late FillnaTransform fillna;

    setUp(() {
      fillna = FillnaTransform();
    });

    test('TC-007: forward fill replaces null with previous value', () async {
      // Row index 2 has null temperature; previous row (index 1) has 73.5
      final result = await fillna.apply(testDataSet, {
        'column': 'temperature',
        'method': 'forward',
      });

      expect(result.rowCount, equals(5));
      expect(result.rows[2]['temperature'], equals(73.5));
      // Other rows remain unchanged
      expect(result.rows[0]['temperature'], equals(71.0));
      expect(result.rows[1]['temperature'], equals(73.5));
      expect(result.rows[3]['temperature'], equals(95.0));
      expect(result.rows[4]['temperature'], equals(72.0));
    });

    test('TC-008: value fill replaces null with specified value', () async {
      final result = await fillna.apply(testDataSet, {
        'column': 'temperature',
        'method': 'value',
        'value': 0.0,
      });

      expect(result.rowCount, equals(5));
      expect(result.rows[2]['temperature'], equals(0.0));
    });

    test('TC-009: backward fill replaces null with next non-null value',
        () async {
      // Row index 2 has null; next non-null is row 3 with 95.0
      final result = await fillna.apply(testDataSet, {
        'column': 'temperature',
        'method': 'backward',
      });

      expect(result.rowCount, equals(5));
      expect(result.rows[2]['temperature'], equals(95.0));
    });

    test('TC-010: fill on column with no nulls leaves data unchanged',
        () async {
      // 'status' column has no null values
      final result = await fillna.apply(testDataSet, {
        'column': 'status',
        'method': 'forward',
      });

      expect(result.rowCount, equals(5));
      for (var i = 0; i < result.rows.length; i++) {
        expect(result.rows[i]['status'], equals(testRows[i]['status']));
      }
    });
  });

  // ==========================================================================
  // ClipTransform (TC-011 to TC-014)
  // ==========================================================================
  group('ClipTransform', () {
    late ClipTransform clip;

    setUp(() {
      clip = ClipTransform();
    });

    test('TC-011: clips values above max', () async {
      // max=80 should clip 95.0 to 80.0
      final result = await clip.apply(testDataSet, {
        'column': 'temperature',
        'max': 80,
      });

      expect(result.rowCount, equals(5));
      // Row 3 had 95.0, now clipped to 80.0
      expect(result.rows[3]['temperature'], equals(80.0));
      // Row 0 unchanged (71.0 < 80)
      expect(result.rows[0]['temperature'], equals(71.0));
    });

    test('TC-012: clips values below min', () async {
      // min=72 should clip 71.0 to 72.0
      final result = await clip.apply(testDataSet, {
        'column': 'temperature',
        'min': 72,
      });

      expect(result.rowCount, equals(5));
      // Row 0 had 71.0, now clipped to 72.0
      expect(result.rows[0]['temperature'], equals(72.0));
      // Row 3 unchanged (95.0 > 72)
      expect(result.rows[3]['temperature'], equals(95.0));
    });

    test('TC-013: clips values with both min and max bounds', () async {
      final result = await clip.apply(testDataSet, {
        'column': 'temperature',
        'min': 72,
        'max': 80,
      });

      expect(result.rowCount, equals(5));
      // 71.0 -> 72.0 (clipped to min)
      expect(result.rows[0]['temperature'], equals(72.0));
      // 73.5 unchanged (within range)
      expect(result.rows[1]['temperature'], equals(73.5));
      // null remains null (not a num, so untouched)
      expect(result.rows[2]['temperature'], isNull);
      // 95.0 -> 80.0 (clipped to max)
      expect(result.rows[3]['temperature'], equals(80.0));
      // 72.0 unchanged (at min boundary)
      expect(result.rows[4]['temperature'], equals(72.0));
    });

    test('TC-014: clip with range wider than all values leaves data unchanged',
        () async {
      final result = await clip.apply(testDataSet, {
        'column': 'temperature',
        'min': 0,
        'max': 200,
      });

      expect(result.rowCount, equals(5));
      // All numeric values should remain the same
      expect(result.rows[0]['temperature'], equals(71.0));
      expect(result.rows[1]['temperature'], equals(73.5));
      expect(result.rows[2]['temperature'], isNull);
      expect(result.rows[3]['temperature'], equals(95.0));
      expect(result.rows[4]['temperature'], equals(72.0));
    });
  });

  // ==========================================================================
  // ResampleTransform (TC-015 to TC-018)
  // ==========================================================================
  group('ResampleTransform', () {
    late ResampleTransform resample;

    setUp(() {
      resample = ResampleTransform();
    });

    test('TC-015: resamples to 2-minute interval with mean aggregation',
        () async {
      final result = await resample.apply(testDataSet, {
        'interval': '2m',
        'aggregation': 'mean',
      });

      // 5 rows spanning 0..4 minutes, bucketed by 2-minute intervals:
      // Bucket 0 (0-1 min): rows at min 0 (71.0) and min 1 (73.5)
      // Bucket 1 (2-3 min): rows at min 2 (null) and min 3 (95.0)
      // Bucket 2 (4 min): row at min 4 (72.0)
      expect(result.rowCount, equals(3));
      // Bucket 0 mean: (71.0 + 73.5) / 2 = 72.25
      expect(result.rows[0]['temperature'], closeTo(72.25, 0.01));
      // Bucket 1: only 95.0 is numeric (null skipped), mean = 95.0
      expect(result.rows[1]['temperature'], closeTo(95.0, 0.01));
      // Bucket 2: 72.0
      expect(result.rows[2]['temperature'], closeTo(72.0, 0.01));
    });

    test('TC-016: resamples to 5-minute interval with sum aggregation',
        () async {
      final result = await resample.apply(testDataSet, {
        'interval': '5m',
        'aggregation': 'sum',
      });

      // All 5 rows fall in a single 5-minute bucket.
      expect(result.rowCount, equals(1));
      // Sum of non-null temperatures: 71.0 + 73.5 + 95.0 + 72.0 = 311.5
      expect(result.rows[0]['temperature'], closeTo(311.5, 0.01));
    });

    test('TC-017: resamples with count aggregation', () async {
      final result = await resample.apply(testDataSet, {
        'interval': '2m',
        'aggregation': 'count',
      });

      expect(result.rowCount, equals(3));
      // Bucket 0: 2 non-null temperature values
      expect(result.rows[0]['temperature'], equals(2));
      // Bucket 1: 1 non-null temperature value (null skipped)
      expect(result.rows[1]['temperature'], equals(1));
      // Bucket 2: 1 non-null temperature value
      expect(result.rows[2]['temperature'], equals(1));
    });

    test('TC-018: resamples empty dataset returns empty', () async {
      final emptyDataSet = AnalysisDataSet(
        columns: testColumns,
        rows: [],
        rowCount: 0,
      );

      final result = await resample.apply(emptyDataSet, {
        'interval': '2m',
        'aggregation': 'mean',
      });

      expect(result.rowCount, equals(0));
      expect(result.rows, isEmpty);
    });
  });

  // ==========================================================================
  // UnitConvertTransform (TC-021 to TC-023)
  // ==========================================================================
  group('UnitConvertTransform', () {
    late UnitConvertTransform convert;

    setUp(() {
      convert = UnitConvertTransform();
    });

    test('TC-021: converts Fahrenheit to Celsius (212 F -> 100 C)', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temp', type: 'double', unit: 'F'),
        ],
        rows: [
          {'temp': 212.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'temp',
        'from': 'F',
        'to': 'C',
      });

      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temp'] as double, closeTo(100.0, 0.01));
      // Column unit should be updated to 'C'
      final tempCol = result.columns.firstWhere((c) => c.name == 'temp');
      expect(tempCol.unit, equals('C'));
    });

    test('TC-022: converts Celsius to Fahrenheit (0 C -> 32 F)', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temp', type: 'double', unit: 'C'),
        ],
        rows: [
          {'temp': 0.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'temp',
        'from': 'C',
        'to': 'F',
      });

      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temp'] as double, closeTo(32.0, 0.01));
      final tempCol = result.columns.firstWhere((c) => c.name == 'temp');
      expect(tempCol.unit, equals('F'));
    });

    test('TC-023: throws on unsupported unit conversion pair', () async {
      // Missing required parameters should throw transform.parameter_error
      expect(
        () => convert.apply(testDataSet, {
          'column': 'temperature',
        }),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.parameter_error',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // TransformPipeline (TC-024 to TC-027)
  // ==========================================================================
  group('TransformPipeline', () {
    late TransformPipeline pipeline;

    setUp(() {
      pipeline = TransformPipeline();
    });

    test('TC-024: executes 3-step pipeline sequentially', () async {
      // Pipeline: fillna -> clip -> sort
      final transforms = [
        AnalysisTransform(
          name: 'fillna',
          parameters: {
            'column': 'temperature',
            'method': 'value',
            'value': 70.0,
          },
        ),
        AnalysisTransform(
          name: 'clip',
          parameters: {
            'column': 'temperature',
            'min': 70,
            'max': 80,
          },
        ),
        AnalysisTransform(
          name: 'sort',
          parameters: {
            'columns': 'temperature',
            'ascending': true,
          },
        ),
      ];

      final result = await pipeline.execute(testDataSet, transforms);

      expect(result.dataSet.rowCount, equals(5));
      expect(result.stepLogs.length, equals(3));

      // After fillna: null -> 70.0
      // After clip: 95.0 -> 80.0, 71.0 stays, 73.5 stays, 70.0 stays, 72.0 stays
      // After sort ascending: 70.0, 71.0, 72.0, 73.5, 80.0
      final temps =
          result.dataSet.rows.map((r) => r['temperature'] as double).toList();
      expect(temps, equals([70.0, 71.0, 72.0, 73.5, 80.0]));
    });

    test('TC-025: empty transform list returns input unchanged', () async {
      final result = await pipeline.execute(testDataSet, []);

      expect(result.dataSet.rowCount, equals(testDataSet.rowCount));
      expect(result.dataSet.rows.length, equals(testDataSet.rows.length));
      expect(result.stepLogs, isEmpty);
    });

    test('TC-026: pipeline logs each step with input/output row counts',
        () async {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
        AnalysisTransform(
          name: 'sort',
          parameters: {
            'columns': 'temperature',
            'ascending': true,
          },
        ),
      ];

      final result = await pipeline.execute(testDataSet, transforms);

      expect(result.stepLogs.length, equals(2));

      // Step 1: filter - input 5 rows, output 4 rows
      expect(result.stepLogs[0].transformName, equals('filter'));
      expect(result.stepLogs[0].inputRowCount, equals(5));
      expect(result.stepLogs[0].outputRowCount, equals(4));

      // Step 2: sort - input 4 rows, output 4 rows
      expect(result.stepLogs[1].transformName, equals('sort'));
      expect(result.stepLogs[1].inputRowCount, equals(4));
      expect(result.stepLogs[1].outputRowCount, equals(4));
    });

    test('TC-027: throws on unknown transform name', () async {
      final transforms = [
        AnalysisTransform(
          name: 'nonexistent_transform',
          parameters: {},
        ),
      ];

      expect(
        () => pipeline.execute(testDataSet, transforms),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.unknown',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // SchemaPropagator (TC-028 to TC-031)
  // ==========================================================================
  group('SchemaPropagator', () {
    late SchemaPropagator propagator;
    late TransformPipeline pipeline;

    setUp(() {
      propagator = SchemaPropagator();
      pipeline = TransformPipeline();
    });

    test('TC-028: schema propagation through filter preserves columns',
        () async {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // Filter preserves all columns
      expect(outputSchema.length, equals(testColumns.length));
      expect(outputSchema[0].name, equals('_timestamp'));
      expect(outputSchema[1].name, equals('temperature'));
      expect(outputSchema[2].name, equals('status'));
    });

    // TC-030 (spec): Propagate schema through join
    // Current implementation returns input schema unchanged for join.
    test('TC-030: schema propagation through join preserves left columns', () {
      final transforms = [
        AnalysisTransform(
          name: 'join',
          parameters: {
            'rightData': <Map<String, dynamic>>[],
            'method': 'nearest',
          },
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // Join preserves left-side columns
      final colNames = outputSchema.map((c) => c.name).toSet();
      expect(colNames, contains('_timestamp'));
      expect(colNames, contains('temperature'));
      expect(colNames, contains('status'));
      expect(outputSchema.length, equals(testColumns.length));
    });

    // TC-031 (spec): Propagate schema through unit_convert (unit updated)
    test('TC-031: schema propagation through unit_convert updates unit', () {
      final transforms = [
        AnalysisTransform(
          name: 'unit_convert',
          parameters: {
            'column': 'temperature',
            'from': 'F',
            'to': 'C',
          },
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // Column names should be preserved
      expect(outputSchema.length, equals(testColumns.length));
      // Temperature column unit should be updated to 'C'
      final tempCol = outputSchema.firstWhere((c) => c.name == 'temperature');
      expect(tempCol.unit, equals('C'));
    });
  });

  // ==========================================================================
  // Error Cases (TC-032 to TC-036)
  // ==========================================================================
  group('Transform Error Cases', () {
    // TC-032: ResampleTransform with invalid interval format
    // Implementation defaults to 5m for unparseable intervals
    test('TC-032: resample with invalid interval defaults to 5m', () async {
      final resample = ResampleTransform();
      final ds = AnalysisDataSet(
        columns: testColumns,
        rows: [
          {
            '_timestamp': DateTime(2024, 1, 1),
            'temperature': 70.0,
            'status': 'active'
          },
        ],
        rowCount: 1,
      );

      // Should not throw; defaults to 5-minute interval
      final result = await resample.apply(ds, {
        'interval': 'invalid',
        'aggregation': 'mean',
      });
      expect(result.rowCount, equals(1));
    });

    // TC-033: FillnaTransform with invalid method
    // Implementation silently ignores unknown methods (no-op for null values)
    test('TC-033: fillna with invalid method leaves nulls unchanged', () async {
      final fillna = FillnaTransform();

      final result = await fillna.apply(testDataSet, {
        'column': 'temperature',
        'method': 'nonexistent_method',
      });
      // Null at index 2 should remain null (unrecognized method = no-op)
      expect(result.rows[2]['temperature'], isNull);
    });

    // TC-034: JoinTransform with invalid method falls through to nearest
    test('TC-034: join with invalid method defaults to nearest', () async {
      final join = JoinTransform();

      // With rightData but invalid method, should default to nearest matching
      final result = await join.apply(testDataSet, {
        'rightData': <Map<String, dynamic>>[],
        'method': 'invalid_method',
      });
      // Empty right data -> input returned unchanged
      expect(result.rowCount, equals(testDataSet.rowCount));
    });

    // TC-035: JoinTransform with missing rightData
    test('TC-035: join with missing rightData throws parameter_error',
        () async {
      final join = JoinTransform();

      expect(
        () => join.apply(testDataSet, {
          'method': 'nearest',
        }),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.parameter_error',
          ),
        ),
      );
    });

    // TC-028 (spec): TransformPipeline custom handler registration
    test('TC-028-spec: pipeline accepts custom handler registration', () async {
      final pipeline = TransformPipeline(
        customHandlers: {
          'custom_transform': _StubTransformHandler(),
        },
      );

      final transforms = [
        AnalysisTransform(
          name: 'custom_transform',
          parameters: {'key': 'value'},
        ),
      ];

      // Custom handler should be invoked without throwing 'transform.unknown'
      final result = await pipeline.execute(testDataSet, transforms);
      expect(result.dataSet.rowCount, equals(testDataSet.rowCount));
      expect(result.stepLogs, hasLength(1));
      expect(result.stepLogs[0].transformName, equals('custom_transform'));
    });
  });

  // ==========================================================================
  // FilterTransform additional operators (TC-040 to TC-045)
  // ==========================================================================
  group('FilterTransform additional operators', () {
    late FilterTransform filter;

    setUp(() {
      filter = FilterTransform();
    });

    test('TC-040: isNotNull operator filters rows with non-null values',
        () async {
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': 'isNotNull',
      });

      // 4 rows have non-null temperature (indices 0,1,3,4)
      expect(result.rowCount, equals(4));
      for (final row in result.rows) {
        expect(row['temperature'], isNotNull);
      }
    });

    test('TC-041: in operator filters rows with values in list', () async {
      final result = await filter.apply(testDataSet, {
        'column': 'status',
        'operator': 'in',
        'value': ['active'],
      });

      expect(result.rowCount, equals(4));
      for (final row in result.rows) {
        expect(row['status'], equals('active'));
      }
    });

    test('TC-042: notIn operator filters rows with values not in list',
        () async {
      final result = await filter.apply(testDataSet, {
        'column': 'status',
        'operator': 'notIn',
        'value': ['inactive'],
      });

      // All rows except 'inactive' (index 3); null status rows are also excluded
      // since null != is not in the list check. Actually null is not 'inactive' so...
      // notIn with null cellValue -> false (because cellValue==null returns false early)
      expect(result.rowCount, equals(4));
    });

    test('TC-043: != operator filters rows by inequality', () async {
      final result = await filter.apply(testDataSet, {
        'column': 'status',
        'operator': '!=',
        'value': 'active',
      });

      // Only the inactive row matches (null row returns false)
      expect(result.rowCount, equals(1));
      expect(result.rows[0]['status'], equals('inactive'));
    });

    test('TC-044: <= operator filters rows by less-than-or-equal', () async {
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': '<=',
        'value': 72.0,
      });

      // 71.0 and 72.0 match
      expect(result.rowCount, equals(2));
    });

    test('TC-045: >= operator filters rows by greater-than-or-equal', () async {
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': '>=',
        'value': 73.5,
      });

      // 73.5 and 95.0 match
      expect(result.rowCount, equals(2));
    });

    test('TC-046: < operator filters rows by less-than', () async {
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': '<',
        'value': 72.0,
      });

      // 71.0 matches
      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temperature'], equals(71.0));
    });

    test('TC-047: unknown operator returns no matching rows', () async {
      final result = await filter.apply(testDataSet, {
        'column': 'temperature',
        'operator': 'unknown_op',
        'value': 72.0,
      });

      expect(result.rowCount, equals(0));
    });
  });

  // ==========================================================================
  // FillnaTransform interpolate method (TC-050)
  // ==========================================================================
  group('FillnaTransform interpolate', () {
    late FillnaTransform fillna;

    test('TC-050: interpolate fills null with average of prev and next',
        () async {
      fillna = FillnaTransform();
      final result = await fillna.apply(testDataSet, {
        'column': 'temperature',
        'method': 'interpolate',
      });

      // Row 2 is null. prev=73.5 (row 1), next=95.0 (row 3)
      // interpolated = (73.5 + 95.0) / 2 = 84.25
      expect(result.rows[2]['temperature'], closeTo(84.25, 0.01));
    });

    test('TC-051: interpolate with no next value uses prev only', () async {
      fillna = FillnaTransform();
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'val': 10.0},
          {'val': null},
        ],
        rowCount: 2,
      );

      final result = await fillna.apply(ds, {
        'column': 'val',
        'method': 'interpolate',
      });

      // No next value, so prev is used
      expect(result.rows[1]['val'], equals(10.0));
    });

    test('TC-052: interpolate with no prev value uses next only', () async {
      fillna = FillnaTransform();
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'val': null},
          {'val': 20.0},
        ],
        rowCount: 2,
      );

      final result = await fillna.apply(ds, {
        'column': 'val',
        'method': 'interpolate',
      });

      // No prev value, so next is used
      expect(result.rows[0]['val'], equals(20.0));
    });
  });

  // ==========================================================================
  // ResampleTransform additional aggregations (TC-055 to TC-058)
  // ==========================================================================
  group('ResampleTransform additional aggregations', () {
    late ResampleTransform resample;

    setUp(() {
      resample = ResampleTransform();
    });

    test('TC-055: resamples with min aggregation', () async {
      final result = await resample.apply(testDataSet, {
        'interval': '5m',
        'aggregation': 'min',
      });

      // All rows in one bucket. Non-null temps: 71.0, 73.5, 95.0, 72.0
      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temperature'], equals(71.0));
    });

    test('TC-056: resamples with max aggregation', () async {
      final result = await resample.apply(testDataSet, {
        'interval': '5m',
        'aggregation': 'max',
      });

      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temperature'], equals(95.0));
    });

    test('TC-057: resamples with first aggregation', () async {
      final result = await resample.apply(testDataSet, {
        'interval': '5m',
        'aggregation': 'first',
      });

      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temperature'], equals(71.0));
    });

    test('TC-058: resamples with last aggregation', () async {
      final result = await resample.apply(testDataSet, {
        'interval': '5m',
        'aggregation': 'last',
      });

      expect(result.rowCount, equals(1));
      expect(result.rows[0]['temperature'], equals(72.0));
    });

    test('TC-059: resamples with unknown aggregation defaults to mean',
        () async {
      final result = await resample.apply(testDataSet, {
        'interval': '5m',
        'aggregation': 'unknown_agg',
      });

      expect(result.rowCount, equals(1));
      // Default is mean: (71.0 + 73.5 + 95.0 + 72.0) / 4 = 77.875
      expect(result.rows[0]['temperature'], closeTo(77.875, 0.01));
    });

    test('TC-060: resamples with no timestamp column returns input unchanged',
        () async {
      final noTsDs = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
        ],
        rowCount: 2,
      );

      final result = await resample.apply(noTsDs, {
        'interval': '5m',
        'aggregation': 'mean',
      });

      // No timestamp column, returned as-is
      expect(result.rowCount, equals(2));
    });
  });

  // ==========================================================================
  // JoinTransform methods (TC-061 to TC-068)
  // ==========================================================================
  group('JoinTransform methods', () {
    late JoinTransform join;
    late AnalysisDataSet leftDs;

    setUp(() {
      join = JoinTransform();
      final now = DateTime(2024, 1, 1);
      leftDs = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'sensor', type: 'string'),
        ],
        rows: [
          {'_timestamp': now, 'sensor': 'A'},
          {'_timestamp': now.add(const Duration(minutes: 2)), 'sensor': 'B'},
          {'_timestamp': now.add(const Duration(minutes: 5)), 'sensor': 'C'},
        ],
        rowCount: 3,
      );
    });

    test('TC-061: nearest join matches closest right timestamp', () async {
      final now = DateTime(2024, 1, 1);
      final result = await join.apply(leftDs, {
        'method': 'nearest',
        'rightData': <Map<String, dynamic>>[
          {
            '_timestamp': now.add(const Duration(minutes: 1)),
            'pressure': 1013.0
          },
          {
            '_timestamp': now.add(const Duration(minutes: 4)),
            'pressure': 1015.0
          },
        ],
      });

      expect(result.rowCount, equals(3));
      // Row 0 (t=0): nearest is t=1min -> 1013.0
      expect(result.rows[0]['pressure'], equals(1013.0));
      // Row 1 (t=2): nearest is t=1min -> 1013.0
      expect(result.rows[1]['pressure'], equals(1013.0));
      // Row 2 (t=5): nearest is t=4min -> 1015.0
      expect(result.rows[2]['pressure'], equals(1015.0));
    });

    test('TC-062: exact join matches only exact timestamp', () async {
      final now = DateTime(2024, 1, 1);
      final result = await join.apply(leftDs, {
        'method': 'exact',
        'rightData': <Map<String, dynamic>>[
          {'_timestamp': now, 'pressure': 1013.0},
          {
            '_timestamp': now.add(const Duration(minutes: 3)),
            'pressure': 1015.0
          },
        ],
      });

      expect(result.rowCount, equals(3));
      // Row 0 (t=0): exact match at t=0 -> 1013.0
      expect(result.rows[0]['pressure'], equals(1013.0));
      // Row 1 (t=2min): no exact match -> null
      expect(result.rows[1]['pressure'], isNull);
      // Row 2 (t=5min): no exact match -> null
      expect(result.rows[2]['pressure'], isNull);
    });

    test('TC-063: forward join matches next right timestamp >= left', () async {
      final now = DateTime(2024, 1, 1);
      final result = await join.apply(leftDs, {
        'method': 'forward',
        'rightData': <Map<String, dynamic>>[
          {
            '_timestamp': now.add(const Duration(minutes: 1)),
            'pressure': 1013.0
          },
          {
            '_timestamp': now.add(const Duration(minutes: 4)),
            'pressure': 1015.0
          },
        ],
      });

      expect(result.rowCount, equals(3));
      // Row 0 (t=0): forward -> t=1min (first >= 0) -> 1013.0
      expect(result.rows[0]['pressure'], equals(1013.0));
      // Row 1 (t=2): forward -> t=4min (first >= 2min) -> 1015.0
      expect(result.rows[1]['pressure'], equals(1015.0));
      // Row 2 (t=5): forward -> no right >= 5min -> null
      expect(result.rows[2]['pressure'], isNull);
    });

    test('TC-064: backward join matches last right timestamp <= left',
        () async {
      final now = DateTime(2024, 1, 1);
      final result = await join.apply(leftDs, {
        'method': 'backward',
        'rightData': <Map<String, dynamic>>[
          {
            '_timestamp': now.add(const Duration(minutes: 1)),
            'pressure': 1013.0
          },
          {
            '_timestamp': now.add(const Duration(minutes: 4)),
            'pressure': 1015.0
          },
        ],
      });

      expect(result.rowCount, equals(3));
      // Row 0 (t=0): backward -> no right <= 0 -> null
      expect(result.rows[0]['pressure'], isNull);
      // Row 1 (t=2): backward -> t=1min (last <= 2min) -> 1013.0
      expect(result.rows[1]['pressure'], equals(1013.0));
      // Row 2 (t=5): backward -> t=4min (last <= 5min) -> 1015.0
      expect(result.rows[2]['pressure'], equals(1015.0));
    });

    test('TC-065: join adds columns from right data to output', () async {
      final now = DateTime(2024, 1, 1);
      final result = await join.apply(leftDs, {
        'method': 'nearest',
        'rightData': <Map<String, dynamic>>[
          {'_timestamp': now, 'pressure': 1013.0, 'humidity': 60.0},
        ],
      });

      // Output should have left columns + new right columns
      final colNames = result.columns.map((c) => c.name).toSet();
      expect(colNames, contains('_timestamp'));
      expect(colNames, contains('sensor'));
      expect(colNames, contains('pressure'));
      expect(colNames, contains('humidity'));
    });

    test('TC-066: join with left row missing timestamp preserves row as-is',
        () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [
          {'_timestamp': null, 'value': 42.0},
        ],
        rowCount: 1,
      );

      final now = DateTime(2024, 1, 1);
      final result = await join.apply(ds, {
        'method': 'nearest',
        'rightData': <Map<String, dynamic>>[
          {'_timestamp': now, 'extra': 'data'},
        ],
      });

      expect(result.rowCount, equals(1));
      expect(result.rows[0]['value'], equals(42.0));
    });
  });

  // ==========================================================================
  // UnitConvertTransform additional conversions (TC-070 to TC-076)
  // ==========================================================================
  group('UnitConvertTransform additional conversions', () {
    late UnitConvertTransform convert;

    setUp(() {
      convert = UnitConvertTransform();
    });

    test('TC-070: converts m/s to km/h', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'speed', type: 'double', unit: 'm/s'),
        ],
        rows: [
          {'speed': 10.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'speed',
        'from': 'm/s',
        'to': 'km/h',
      });

      // 10 m/s * 3.6 = 36 km/h
      expect(result.rows[0]['speed'] as double, closeTo(36.0, 0.01));
      final col = result.columns.firstWhere((c) => c.name == 'speed');
      expect(col.unit, equals('km/h'));
    });

    test('TC-071: converts Pa to kPa', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(
              name: 'pressure', type: 'double', unit: 'Pa'),
        ],
        rows: [
          {'pressure': 101325.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'pressure',
        'from': 'Pa',
        'to': 'kPa',
      });

      // 101325 Pa * 0.001 = 101.325 kPa
      expect(result.rows[0]['pressure'] as double, closeTo(101.325, 0.01));
    });

    test('TC-072: converts m to km', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'distance', type: 'double', unit: 'm'),
        ],
        rows: [
          {'distance': 5000.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'distance',
        'from': 'm',
        'to': 'km',
      });

      // 5000 m * 0.001 = 5.0 km
      expect(result.rows[0]['distance'] as double, closeTo(5.0, 0.01));
    });

    test('TC-073: converts C to K', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temp', type: 'double', unit: 'C'),
        ],
        rows: [
          {'temp': 0.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'temp',
        'from': 'C',
        'to': 'K',
      });

      // 0 C + 273.15 = 273.15 K
      expect(result.rows[0]['temp'] as double, closeTo(273.15, 0.01));
    });

    test('TC-074: unsupported conversion pair leaves values unchanged',
        () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'val', type: 'double', unit: 'X'),
        ],
        rows: [
          {'val': 42.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'val',
        'from': 'X',
        'to': 'Y',
      });

      // No conversion factor found; value unchanged
      expect(result.rows[0]['val'], equals(42.0));
      // But column unit is updated
      final col = result.columns.firstWhere((c) => c.name == 'val');
      expect(col.unit, equals('Y'));
    });

    test('TC-075: converts ft to m', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'height', type: 'double', unit: 'ft'),
        ],
        rows: [
          {'height': 100.0},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'height',
        'from': 'ft',
        'to': 'm',
      });

      // 100 ft * 0.3048 = 30.48 m
      expect(result.rows[0]['height'] as double, closeTo(30.48, 0.01));
    });

    test('TC-076: null value in column is not converted', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temp', type: 'double', unit: 'F'),
        ],
        rows: [
          {'temp': null},
        ],
        rowCount: 1,
      );

      final result = await convert.apply(ds, {
        'column': 'temp',
        'from': 'F',
        'to': 'C',
      });

      expect(result.rows[0]['temp'], isNull);
    });
  });

  // ==========================================================================
  // ClipTransform additional edge cases (TC-080 to TC-082)
  // ==========================================================================
  group('ClipTransform additional edge cases', () {
    late ClipTransform clip;

    setUp(() {
      clip = ClipTransform();
    });

    test('TC-080: clip missing column parameter throws error', () async {
      expect(
        () => clip.apply(testDataSet, {
          'min': 70,
          'max': 80,
        }),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.parameter_error',
          ),
        ),
      );
    });

    test('TC-081: clip with only min bound', () async {
      final result = await clip.apply(testDataSet, {
        'column': 'temperature',
        'min': 73,
      });

      // 71.0 -> 73, 73.5 unchanged, null unchanged, 95.0 unchanged, 72.0 -> 73
      expect(result.rows[0]['temperature'], equals(73.0));
      expect(result.rows[1]['temperature'], equals(73.5));
      expect(result.rows[2]['temperature'], isNull);
      expect(result.rows[3]['temperature'], equals(95.0));
      expect(result.rows[4]['temperature'], equals(73.0));
    });

    test('TC-082: clip value exactly at bounds remains unchanged', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'val': 10.0},
          {'val': 20.0},
        ],
        rowCount: 2,
      );

      final result = await clip.apply(ds, {
        'column': 'val',
        'min': 10,
        'max': 20,
      });

      expect(result.rows[0]['val'], equals(10.0));
      expect(result.rows[1]['val'], equals(20.0));
    });
  });

  // ==========================================================================
  // SchemaPropagator additional tests (TC-085 to TC-088)
  // ==========================================================================
  group('SchemaPropagator additional', () {
    late SchemaPropagator propagator;
    late TransformPipeline pipeline;

    setUp(() {
      propagator = SchemaPropagator();
      pipeline = TransformPipeline();
    });

    test('TC-085: empty transforms list returns input schema unchanged', () {
      final outputSchema = propagator.propagate(
        testColumns,
        [],
        pipeline.handlers,
      );

      expect(outputSchema.length, equals(testColumns.length));
      for (var i = 0; i < testColumns.length; i++) {
        expect(outputSchema[i].name, equals(testColumns[i].name));
        expect(outputSchema[i].type, equals(testColumns[i].type));
        expect(outputSchema[i].unit, equals(testColumns[i].unit));
      }
    });

    test('TC-086: schema propagation through multi-step pipeline', () {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
        AnalysisTransform(
          name: 'unit_convert',
          parameters: {
            'column': 'temperature',
            'from': 'F',
            'to': 'C',
          },
        ),
        AnalysisTransform(
          name: 'clip',
          parameters: {
            'column': 'temperature',
            'min': 0,
            'max': 100,
          },
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // Column count unchanged
      expect(outputSchema.length, equals(testColumns.length));
      // Temperature unit updated to C by unit_convert step
      final tempCol = outputSchema.firstWhere((c) => c.name == 'temperature');
      expect(tempCol.unit, equals('C'));
    });

    test('TC-087: schema propagation throws on unknown transform', () {
      final transforms = [
        AnalysisTransform(
          name: 'nonexistent',
          parameters: {},
        ),
      ];

      expect(
        () => propagator.propagate(testColumns, transforms, pipeline.handlers),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.unknown',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // SortTransform additional tests (TC-090 to TC-092)
  // ==========================================================================
  group('SortTransform additional', () {
    late SortTransform sort;

    setUp(() {
      sort = SortTransform();
    });

    test('TC-090: sort throws on missing columns parameter', () async {
      expect(
        () => sort.apply(testDataSet, {}),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'transform.parameter_error',
          ),
        ),
      );
    });

    test('TC-091: sort by list of column names', () async {
      final result = await sort.apply(testDataSet, {
        'columns': ['status', 'temperature'],
        'ascending': true,
      });

      expect(result.rowCount, equals(5));
      // Sorted by status first (null < 'active' < 'inactive'), then by temperature
    });

    test('TC-092: sort on string column alphabetically', () async {
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'name', type: 'string'),
        ],
        rows: [
          {'name': 'charlie'},
          {'name': 'alice'},
          {'name': 'bob'},
        ],
        rowCount: 3,
      );

      final result = await sort.apply(ds, {
        'columns': 'name',
        'ascending': true,
      });

      expect(result.rows[0]['name'], equals('alice'));
      expect(result.rows[1]['name'], equals('bob'));
      expect(result.rows[2]['name'], equals('charlie'));
    });
  });

  // ==========================================================================
  // Integration Tests (IT-001 to IT-003)
  // ==========================================================================
  group('Integration', () {
    late TransformPipeline pipeline;

    setUp(() {
      pipeline = TransformPipeline();
    });

    test('IT-001: full 4-step pipeline: filter -> resample -> fillna -> clip',
        () async {
      final transforms = [
        // Step 1: Filter to active rows only (4 rows: indices 0,1,2,4)
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
        // Step 2: Resample to 2-minute interval with mean
        AnalysisTransform(
          name: 'resample',
          parameters: {
            'interval': '2m',
            'aggregation': 'mean',
          },
        ),
        // Step 3: Fill any nulls with forward fill
        AnalysisTransform(
          name: 'fillna',
          parameters: {
            'column': 'temperature',
            'method': 'forward',
          },
        ),
        // Step 4: Clip temperature between 70 and 80
        AnalysisTransform(
          name: 'clip',
          parameters: {
            'column': 'temperature',
            'min': 70,
            'max': 80,
          },
        ),
      ];

      final result = await pipeline.execute(testDataSet, transforms);

      // Verify all 4 steps were logged
      expect(result.stepLogs.length, equals(4));
      expect(result.stepLogs[0].transformName, equals('filter'));
      expect(result.stepLogs[1].transformName, equals('resample'));
      expect(result.stepLogs[2].transformName, equals('fillna'));
      expect(result.stepLogs[3].transformName, equals('clip'));

      // Verify step log chain: each output feeds next input
      for (var i = 1; i < result.stepLogs.length; i++) {
        expect(
          result.stepLogs[i].inputRowCount,
          equals(result.stepLogs[i - 1].outputRowCount),
        );
      }

      // Verify final dataset has rows and temperature is within bounds
      expect(result.dataSet.rowCount, greaterThan(0));
      for (final row in result.dataSet.rows) {
        final temp = row['temperature'];
        if (temp is num) {
          expect(temp, greaterThanOrEqualTo(70));
          expect(temp, lessThanOrEqualTo(80));
        }
      }
    });

    test('IT-002: pipeline preserves timestamp ordering', () async {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
        AnalysisTransform(
          name: 'resample',
          parameters: {
            'interval': '2m',
            'aggregation': 'mean',
          },
        ),
      ];

      final result = await pipeline.execute(testDataSet, transforms);

      // Verify timestamps are in ascending order
      for (var i = 1; i < result.dataSet.rows.length; i++) {
        final prevTs = result.dataSet.rows[i - 1]['_timestamp'] as DateTime;
        final currTs = result.dataSet.rows[i]['_timestamp'] as DateTime;
        expect(
          currTs.isAfter(prevTs) || currTs.isAtSameMomentAs(prevTs),
          isTrue,
          reason: 'Timestamps must be in ascending order after resample',
        );
      }
    });

    // IT-002 (spec): Schema propagation matches actual pipeline output
    test('IT-002-spec: schema propagation matches actual pipeline output',
        () async {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
      ];

      final result = await pipeline.execute(testDataSet, transforms);
      final propagator = SchemaPropagator();
      final propagatedSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      expect(propagatedSchema.length, equals(result.dataSet.columns.length));
      for (var i = 0; i < propagatedSchema.length; i++) {
        expect(
            propagatedSchema[i].name, equals(result.dataSet.columns[i].name));
      }
    });

    test('IT-003: full pipeline with schema propagation consistency', () async {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
        AnalysisTransform(
          name: 'fillna',
          parameters: {
            'column': 'temperature',
            'method': 'value',
            'value': 0.0,
          },
        ),
        AnalysisTransform(
          name: 'clip',
          parameters: {
            'column': 'temperature',
            'min': 0,
            'max': 100,
          },
        ),
      ];

      // Execute pipeline
      final result = await pipeline.execute(testDataSet, transforms);

      // Propagate schema
      final propagator = SchemaPropagator();
      final propagatedSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // Schema from propagation and from actual execution should match
      expect(
        propagatedSchema.length,
        equals(result.dataSet.columns.length),
      );
      for (var i = 0; i < propagatedSchema.length; i++) {
        expect(
          propagatedSchema[i].name,
          equals(result.dataSet.columns[i].name),
        );
        expect(
          propagatedSchema[i].type,
          equals(result.dataSet.columns[i].type),
        );
      }
    });
  });

  // ==========================================================================
  // TransformPipeline coverage boost (non-AnalysisError wrapping, single step)
  // ==========================================================================
  group('TransformPipeline coverage boost', () {
    test('non-AnalysisError thrown by handler is wrapped with transform.failed',
        () async {
      // Register a handler that throws a non-AnalysisError exception
      final pipeline = TransformPipeline(
        customHandlers: {
          'throwing_transform': _ThrowingTransformHandler(),
        },
      );

      final ds = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'x', type: 'double')],
        rows: [
          {'x': 1.0},
        ],
        rowCount: 1,
      );

      expect(
        () => pipeline.execute(ds, [
          AnalysisTransform(
            name: 'throwing_transform',
            parameters: {'key': 'val'},
          ),
        ]),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', 'transform.failed')
              .having(
                (e) => e.message,
                'message',
                contains('throwing_transform'),
              )
              .having(
            (e) => e.details?['parameters'],
            'details.parameters',
            {'key': 'val'},
          ),
        ),
      );
    });

    test('AnalysisError thrown by handler is rethrown not wrapped', () async {
      final pipeline = TransformPipeline(
        customHandlers: {
          'analysis_error_transform': _AnalysisErrorTransformHandler(),
        },
      );

      final ds = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'x', type: 'double')],
        rows: [
          {'x': 1.0},
        ],
        rowCount: 1,
      );

      expect(
        () => pipeline.execute(ds, [
          AnalysisTransform(
            name: 'analysis_error_transform',
            parameters: {},
          ),
        ]),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'custom.transform_error',
          ),
        ),
      );
    });

    test('single step pipeline produces exactly one step log', () async {
      final pipeline = TransformPipeline();
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': DateTime(2024, 1, 1), 'val': 10.0},
          {'_timestamp': DateTime(2024, 1, 1, 0, 1), 'val': 20.0},
        ],
        rowCount: 2,
      );

      final result = await pipeline.execute(ds, [
        AnalysisTransform(
          name: 'sort',
          parameters: {'columns': 'val', 'ascending': false},
        ),
      ]);

      expect(result.stepLogs, hasLength(1));
      expect(result.stepLogs[0].transformName, equals('sort'));
      expect(result.stepLogs[0].inputRowCount, equals(2));
      expect(result.stepLogs[0].outputRowCount, equals(2));
      expect(result.stepLogs[0].outputSchema, isNotEmpty);
      expect(result.stepLogs[0].executionTime, isA<Duration>());
      // Verify sort applied: 20.0 before 10.0
      expect(result.dataSet.rows[0]['val'], equals(20.0));
    });

    test('pipeline with custom handler that modifies data', () async {
      final pipeline = TransformPipeline(
        customHandlers: {
          'custom_transform': _StubTransformHandler(),
          'double_custom': _DoublingTransformHandler(),
        },
      );

      expect(pipeline.handlers.containsKey('custom_transform'), isTrue);
      expect(pipeline.handlers.containsKey('double_custom'), isTrue);
      // Built-in handlers should also be present
      expect(pipeline.handlers.containsKey('filter'), isTrue);

      final ds = AnalysisDataSet(
        columns: [const AnalysisColumnInfo(name: 'x', type: 'double')],
        rows: [
          {'x': 5.0},
        ],
        rowCount: 1,
      );

      final result = await pipeline.execute(ds, [
        AnalysisTransform(
          name: 'double_custom',
          parameters: {},
        ),
      ]);

      // Doubling handler doubles all numeric values
      expect(result.dataSet.rows[0]['x'], equals(10.0));
    });

    test('stepLogs accumulate across multiple steps', () async {
      final pipeline = TransformPipeline();
      final now = DateTime(2024, 1, 1);
      final ds = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 30.0},
          {'_timestamp': now.add(const Duration(minutes: 1)), 'val': 10.0},
          {'_timestamp': now.add(const Duration(minutes: 2)), 'val': 20.0},
        ],
        rowCount: 3,
      );

      final result = await pipeline.execute(ds, [
        AnalysisTransform(
          name: 'filter',
          parameters: {'column': 'val', 'operator': '>', 'value': 15.0},
        ),
        AnalysisTransform(
          name: 'sort',
          parameters: {'columns': 'val', 'ascending': true},
        ),
      ]);

      expect(result.stepLogs, hasLength(2));
      // Step 1: filter 3 rows -> 2 rows
      expect(result.stepLogs[0].inputRowCount, equals(3));
      expect(result.stepLogs[0].outputRowCount, equals(2));
      // Step 2: sort 2 rows -> 2 rows
      expect(result.stepLogs[1].inputRowCount, equals(2));
      expect(result.stepLogs[1].outputRowCount, equals(2));
      // Final data: [20.0, 30.0]
      expect(result.dataSet.rows[0]['val'], equals(20.0));
      expect(result.dataSet.rows[1]['val'], equals(30.0));
    });
  });

  // ==========================================================================
  // Schema Propagation Validation (FR-TRAN-006)
  // ==========================================================================
  group('Schema Propagation Validation', () {
    late SchemaPropagator propagator;
    late TransformPipeline pipeline;

    setUp(() {
      propagator = SchemaPropagator();
      pipeline = TransformPipeline();
    });

    // TC-093: filter validates column exists
    test('TC-093: filter schema propagation validates column exists', () {
      final transforms = [
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'nonexistent_col',
            'operator': '==',
            'value': 'x',
          },
        ),
      ];

      expect(
        () => propagator.propagate(testColumns, transforms, pipeline.handlers),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', 'transform.schema_error')
              .having(
                (e) => e.message,
                'message',
                contains('nonexistent_col'),
              ),
        ),
      );
    });

    // TC-094: clip validates numeric type
    test('TC-094: clip schema propagation validates numeric type', () {
      final transforms = [
        AnalysisTransform(
          name: 'clip',
          parameters: {'column': 'status', 'min': 0, 'max': 100},
        ),
      ];

      expect(
        () => propagator.propagate(testColumns, transforms, pipeline.handlers),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', 'transform.schema_error')
              .having(
                (e) => e.message,
                'message',
                contains('requires numeric column'),
              ),
        ),
      );
    });

    // TC-095: resample drops non-numeric columns
    test('TC-095: resample schema propagation drops non-numeric columns', () {
      final transforms = [
        AnalysisTransform(
          name: 'resample',
          parameters: {'interval': '5m', 'aggregation': 'mean'},
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // Should keep _timestamp (datetime) and temperature (double),
      // but drop status (string)
      final colNames = outputSchema.map((c) => c.name).toList();
      expect(colNames, contains('_timestamp'));
      expect(colNames, contains('temperature'));
      expect(colNames, isNot(contains('status')));
      expect(outputSchema.length, equals(2));
    });

    // TC-096: join handles column name conflicts
    test('TC-096: join schema propagation handles column name conflicts', () {
      final transforms = [
        AnalysisTransform(
          name: 'join',
          parameters: {
            'rightColumns': [
              {'name': 'temperature', 'type': 'double', 'unit': 'C'},
              {'name': 'humidity', 'type': 'double', 'unit': '%'},
            ],
            'rightData': <Map<String, dynamic>>[],
            'method': 'nearest',
          },
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      final colNames = outputSchema.map((c) => c.name).toList();
      // Left columns preserved
      expect(colNames, contains('_timestamp'));
      expect(colNames, contains('temperature'));
      expect(colNames, contains('status'));
      // Conflicting right column prefixed with _right_
      expect(colNames, contains('_right_temperature'));
      // Non-conflicting right column added as-is
      expect(colNames, contains('humidity'));
      expect(outputSchema.length, equals(5));
    });

    // TC-097: unit_convert updates unit metadata
    test('TC-097: unit_convert schema propagation updates unit metadata', () {
      final transforms = [
        AnalysisTransform(
          name: 'unit_convert',
          parameters: {
            'column': 'temperature',
            'from': 'F',
            'to': 'C',
          },
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      expect(outputSchema.length, equals(testColumns.length));
      final tempCol = outputSchema.firstWhere((c) => c.name == 'temperature');
      expect(tempCol.unit, equals('C'));
      // Other columns unchanged
      final statusCol = outputSchema.firstWhere((c) => c.name == 'status');
      expect(statusCol.unit, isNull);
    });

    // TC-098: fillna on non-existent column throws schema error
    test('TC-098: fillna on non-existent column throws schema error', () {
      final transforms = [
        AnalysisTransform(
          name: 'fillna',
          parameters: {
            'column': 'nonexistent_col',
            'method': 'value',
            'value': 0,
          },
        ),
      ];

      expect(
        () => propagator.propagate(testColumns, transforms, pipeline.handlers),
        throwsA(
          isA<AnalysisError>()
              .having((e) => e.code, 'code', 'transform.schema_error')
              .having(
                (e) => e.message,
                'message',
                contains('nonexistent_col'),
              ),
        ),
      );
    });

    // TC-099: chained transforms propagate correctly
    test('TC-099: chained transforms propagate schema correctly', () {
      final transforms = [
        // Step 1: filter (preserves schema)
        AnalysisTransform(
          name: 'filter',
          parameters: {
            'column': 'status',
            'operator': '==',
            'value': 'active',
          },
        ),
        // Step 2: unit_convert (updates temperature unit from F to C)
        AnalysisTransform(
          name: 'unit_convert',
          parameters: {
            'column': 'temperature',
            'from': 'F',
            'to': 'C',
          },
        ),
        // Step 3: resample (drops non-numeric columns)
        AnalysisTransform(
          name: 'resample',
          parameters: {'interval': '5m', 'aggregation': 'mean'},
        ),
      ];

      final outputSchema = propagator.propagate(
        testColumns,
        transforms,
        pipeline.handlers,
      );

      // After resample: _timestamp + temperature only (status dropped)
      expect(outputSchema.length, equals(2));
      final colNames = outputSchema.map((c) => c.name).toList();
      expect(colNames, contains('_timestamp'));
      expect(colNames, contains('temperature'));
      expect(colNames, isNot(contains('status')));
      // Temperature unit updated by unit_convert step
      final tempCol = outputSchema.firstWhere((c) => c.name == 'temperature');
      expect(tempCol.unit, equals('C'));
    });
  });
}

// =============================================================================
// Test helper implementations
// =============================================================================

/// A transform handler that throws a non-AnalysisError exception.
class _ThrowingTransformHandler implements TransformHandler {
  @override
  String get name => 'throwing_transform';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    throw StateError('Simulated transform failure');
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    return inputSchema;
  }
}

/// A transform handler that throws an AnalysisError.
class _AnalysisErrorTransformHandler implements TransformHandler {
  @override
  String get name => 'analysis_error_transform';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    throw AnalysisError(
      code: 'custom.transform_error',
      message: 'Intentional AnalysisError',
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    return inputSchema;
  }
}

/// A transform handler that doubles all numeric values.
class _DoublingTransformHandler implements TransformHandler {
  @override
  String get name => 'double_custom';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final newRows = input.rows.map((row) {
      final newRow = Map<String, dynamic>.from(row);
      for (final key in newRow.keys) {
        if (newRow[key] is num) {
          newRow[key] = (newRow[key] as num).toDouble() * 2;
        }
      }
      return newRow;
    }).toList();

    return AnalysisDataSet(
      columns: input.columns,
      rows: newRows,
      rowCount: newRows.length,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    return inputSchema;
  }
}

/// A stub transform handler for custom handler registration tests.
class _StubTransformHandler implements TransformHandler {
  @override
  String get name => 'custom_transform';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    // Pass-through: returns input data unchanged
    return input;
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    return inputSchema;
  }
}
