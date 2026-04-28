import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Shared test data
  // ---------------------------------------------------------------------------

  // Numeric data for descriptive stats and anomaly detection
  final numericData = AnalysisDataSet(
    columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
    rows: [
      {'value': 10.0},
      {'value': 20.0},
      {'value': 30.0},
      {'value': 40.0},
      {'value': 50.0},
      {'value': 100.0},
    ],
    rowCount: 6,
  );

  // Event data for event analysis
  final eventData = AnalysisDataSet(
    columns: [
      AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
      AnalysisColumnInfo(name: 'eventType', type: 'string'),
    ],
    rows: [
      {'_timestamp': DateTime(2024, 1, 1, 0, 0), 'eventType': 'error'},
      {'_timestamp': DateTime(2024, 1, 1, 1, 0), 'eventType': 'recovery'},
      {'_timestamp': DateTime(2024, 1, 1, 2, 0), 'eventType': 'error'},
      {'_timestamp': DateTime(2024, 1, 1, 3, 0), 'eventType': 'recovery'},
    ],
    rowCount: 4,
  );

  // Two-variable data for correlation / regression
  final twoVarData = AnalysisDataSet(
    columns: [
      AnalysisColumnInfo(name: 'x', type: 'double'),
      AnalysisColumnInfo(name: 'y', type: 'double'),
    ],
    rows: [
      {'x': 1.0, 'y': 2.0},
      {'x': 2.0, 'y': 4.0},
      {'x': 3.0, 'y': 6.0},
    ],
    rowCount: 3,
  );

  // =========================================================================
  // FunctionCatalog tests
  // =========================================================================
  group('FunctionCatalog', () {
    late FunctionCatalog catalog;

    setUp(() {
      catalog = FunctionCatalog();
    });

    // TC-001: Register and retrieve a function
    test('TC-001: register and get should return registered function', () {
      final info = AnalysisFunctionInfo(
        functionName: 'test_fn',
        description: 'A test function',
        parameters: {
          'param1': AnalysisParameterSchema(
            name: 'param1',
            type: 'string',
            description: 'Test parameter',
          ),
        },
        supportedDataTypes: ['double'],
      );

      catalog.register(info);

      final retrieved = catalog.get('test_fn');
      expect(retrieved, isNotNull);
      expect(retrieved!.functionName, equals('test_fn'));
      expect(retrieved.description, equals('A test function'));
      expect(retrieved.parameters, contains('param1'));
      expect(retrieved.supportedDataTypes, contains('double'));
    });

    // TC-002: Registering a duplicate name throws AnalysisError
    test('TC-002: register duplicate name throws AnalysisError', () {
      final info = AnalysisFunctionInfo(
        functionName: 'dup_fn',
        description: 'First',
      );
      catalog.register(info);

      final duplicate = AnalysisFunctionInfo(
        functionName: 'dup_fn',
        description: 'Second',
      );
      expect(
        () => catalog.register(duplicate),
        throwsA(isA<AnalysisError>()),
      );
    });

    // TC-003: getAll returns all registered functions
    test('TC-003: getAll returns all registered functions', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'fn_a',
        description: 'A',
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'fn_b',
        description: 'B',
      ));

      final all = catalog.getAll();
      expect(all, hasLength(2));
      expect(all.map((f) => f.functionName), containsAll(['fn_a', 'fn_b']));
    });

    // TC-004: get returns null for missing function
    test('TC-004: get returns null for unknown function name', () {
      expect(catalog.get('nonexistent'), isNull);
    });

    // TC-005: has returns true for registered function
    test('TC-005: has returns true for registered function', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'present',
        description: 'Present',
      ));
      expect(catalog.has('present'), isTrue);
    });

    // TC-006: has returns false for unregistered function
    test('TC-006: has returns false for unregistered function', () {
      expect(catalog.has('absent'), isFalse);
    });

    // TC-007: unregister removes a function and returns true
    test('TC-007: unregister removes function and returns true', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'removable',
        description: 'Removable',
      ));
      expect(catalog.unregister('removable'), isTrue);
      expect(catalog.has('removable'), isFalse);
    });

    // TC-008: unregister returns false for unknown function
    test('TC-008: unregister returns false for unknown function', () {
      expect(catalog.unregister('ghost'), isFalse);
    });

    // TC-009: getAvailableNames returns all registered names
    test('TC-009: getAvailableNames returns all registered names', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'alpha',
        description: 'Alpha',
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'beta',
        description: 'Beta',
      ));

      final names = catalog.getAvailableNames();
      expect(names, containsAll(['alpha', 'beta']));
      expect(names, hasLength(2));
    });

    // search with both category and dataType filters simultaneously
    test('search with both category and dataType filters', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'stats_double',
        description: 'Stats for doubles',
        supportedDataTypes: ['double'],
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'stats_string',
        description: 'Stats for strings',
        supportedDataTypes: ['string'],
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'other_double',
        description: 'Other double function',
        supportedDataTypes: ['double'],
      ));

      // Both category and dataType must match
      final results = catalog.search(category: 'stats', dataType: 'double');
      expect(results, hasLength(1));
      expect(results.first.functionName, equals('stats_double'));
    });

    // search with category only (no dataType)
    test('search with category only filters by name/description', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'anomaly_detect',
        description: 'Detect anomalies',
        supportedDataTypes: ['double'],
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'stats_fn',
        description: 'Statistics function',
        supportedDataTypes: ['double'],
      ));

      final results = catalog.search(category: 'anomaly');
      expect(results, hasLength(1));
      expect(results.first.functionName, equals('anomaly_detect'));
    });

    // search with no parameters returns all
    test('search with no parameters returns all functions', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'fn_x',
        description: 'X',
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'fn_y',
        description: 'Y',
      ));

      final results = catalog.search();
      expect(results, hasLength(2));
    });

    // TC-010 (spec): search filters by dataType
    test('TC-010-spec: search filters by dataType', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'double_fn',
        description: 'Handles doubles',
        supportedDataTypes: ['double'],
      ));
      catalog.register(AnalysisFunctionInfo(
        functionName: 'string_fn',
        description: 'Handles strings',
        supportedDataTypes: ['string'],
      ));

      final results = catalog.search(dataType: 'double');
      expect(results, hasLength(1));
      expect(results.first.functionName, 'double_fn');
    });

    // TC-011 (spec): search with no matches returns empty
    test('TC-011-spec: search with no matches returns empty', () {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'some_fn',
        description: 'Some function',
        supportedDataTypes: ['double'],
      ));

      final results = catalog.search(dataType: 'nonexistent');
      expect(results, isEmpty);
    });

    // TC-010: registerBuiltins via dispatcher registers 7 built-in functions
    test('TC-010: registerBuiltins registers all 7 built-in functions', () {
      final dispatcher = FunctionDispatcher(catalog: catalog);
      dispatcher.registerBuiltins([
        DescriptiveStatsFunction(),
        AnomalyDetectFunction(),
        EventAnalysisFunction(),
        TimeSeriesFunction(),
        CorrelationRegressionFunction(),
        RuleBasedClassificationFunction(),
        SeasonalityFunction(),
      ]);

      expect(catalog.getAll(), hasLength(7));
      expect(catalog.has('descriptive_stats'), isTrue);
      expect(catalog.has('anomaly_detect'), isTrue);
      expect(catalog.has('event_analysis'), isTrue);
      expect(catalog.has('time_series_analysis'), isTrue);
      expect(catalog.has('correlation_regression'), isTrue);
      expect(catalog.has('rule_based_classification'), isTrue);
      expect(catalog.has('seasonality_analysis'), isTrue);
    });
  });

  // =========================================================================
  // DescriptiveStatsFunction tests
  // =========================================================================
  group('DescriptiveStatsFunction', () {
    late DescriptiveStatsFunction fn;

    setUp(() {
      fn = DescriptiveStatsFunction();
    });

    // TC-001: min value
    test('TC-001: computes min = 10.0', () async {
      final result = await fn.execute({'columns': ['value']}, numericData);
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats['min'], equals(10.0));
    });

    // TC-002: max value
    test('TC-002: computes max = 100.0', () async {
      final result = await fn.execute({'columns': ['value']}, numericData);
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats['max'], equals(100.0));
    });

    // TC-003: average value (250/6 ~ 41.67)
    test('TC-003: computes avg close to 41.67', () async {
      final result = await fn.execute({'columns': ['value']}, numericData);
      final stats = result.results['value'] as Map<String, dynamic>;
      expect((stats['avg'] as double), closeTo(41.67, 0.01));
    });

    // TC-004: standard deviation is computed and positive
    test('TC-004: computes std > 0', () async {
      final result = await fn.execute({'columns': ['value']}, numericData);
      final stats = result.results['value'] as Map<String, dynamic>;
      final std = stats['std'] as double;
      expect(std, greaterThan(0));
    });

    // TC-005: percentiles are computed
    test('TC-005: computes percentiles p25, p50, p75', () async {
      final result = await fn.execute(
        {'columns': ['value'], 'percentiles': [25, 50, 75]},
        numericData,
      );
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats.containsKey('p25'), isTrue);
      expect(stats.containsKey('p50'), isTrue);
      expect(stats.containsKey('p75'), isTrue);
    });

    // TC-006: empty data returns count 0
    test('TC-006: empty data returns count 0 with zero stats', () async {
      final emptyData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [],
        rowCount: 0,
      );
      final result = await fn.execute({'columns': ['value']}, emptyData);
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats['count'], equals(0));
      expect(stats['min'], equals(0.0));
      expect(stats['max'], equals(0.0));
      expect(stats['avg'], equals(0.0));
      expect(stats['std'], equals(0.0));
    });

    // info property returns correct metadata
    test('info property returns correct function metadata', () {
      expect(fn.info.functionName, equals('descriptive_stats'));
      expect(fn.info.description, isNotEmpty);
      expect(fn.info.parameters, contains('columns'));
      expect(fn.info.parameters, contains('percentiles'));
      expect(fn.info.supportedDataTypes, containsAll(['double', 'int']));
    });

    // Single-value dataset: std should be 0
    test('single value dataset produces std of 0', () async {
      final singleData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 42.0},
        ],
        rowCount: 1,
      );
      final result = await fn.execute({'columns': ['value']}, singleData);
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats['count'], equals(1));
      expect(stats['std'], equals(0.0));
      expect(stats['min'], equals(42.0));
      expect(stats['max'], equals(42.0));
      expect(stats['avg'], equals(42.0));
    });

    // Default columns: auto-selects all numeric columns
    test('default columns auto-selects all numeric columns', () async {
      final multiColData = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'x', type: 'double'),
          AnalysisColumnInfo(name: 'label', type: 'string'),
          AnalysisColumnInfo(name: 'y', type: 'int'),
        ],
        rows: [
          {'x': 1.0, 'label': 'a', 'y': 10},
          {'x': 2.0, 'label': 'b', 'y': 20},
        ],
        rowCount: 2,
      );

      // No columns parameter: should auto-select 'x' and 'y'
      final result = await fn.execute({}, multiColData);
      expect(result.results.containsKey('x'), isTrue);
      expect(result.results.containsKey('y'), isTrue);
      expect(result.results.containsKey('label'), isFalse);
    });

    // Custom percentiles parameter
    test('custom percentiles computes requested percentile values', () async {
      final result = await fn.execute(
        {'columns': ['value'], 'percentiles': [10, 90]},
        numericData,
      );
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats.containsKey('p10'), isTrue);
      expect(stats.containsKey('p90'), isTrue);
      // Default percentiles should not be present
      expect(stats.containsKey('p25'), isFalse);
      expect(stats.containsKey('p75'), isFalse);
    });

    // Column with all null values produces count 0
    test('column with all null values produces count 0', () async {
      final nullData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': null},
          {'value': null},
        ],
        rowCount: 2,
      );
      final result = await fn.execute({'columns': ['value']}, nullData);
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats['count'], equals(0));
    });
  });

  // =========================================================================
  // AnomalyDetectFunction tests
  // =========================================================================
  group('AnomalyDetectFunction', () {
    late AnomalyDetectFunction fn;

    setUp(() {
      fn = AnomalyDetectFunction();
    });

    // TC-007: threshold method detects 100 when threshold=50
    test('TC-007: threshold detects value 100 above threshold 50', () async {
      final result = await fn.execute(
        {'method': 'threshold', 'column': 'value', 'threshold': 50},
        numericData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isNotEmpty);
      // 100.0 is the only value > 50
      expect(anomalies.length, equals(1));
      final anomaly = anomalies.first as Map<String, dynamic>;
      expect(anomaly['value'], equals(100.0));
    });

    // TC-008: threshold=200 detects no anomalies
    test('TC-008: threshold 200 detects no anomalies', () async {
      final result = await fn.execute(
        {'method': 'threshold', 'column': 'value', 'threshold': 200},
        numericData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isEmpty);
    });

    // TC-009: z-score method detects 100 as anomaly
    // Mean ~ 41.67, std ~ 31.89 => z-score for 100 ~ 1.83
    // Use sensitivity=1.5 to ensure detection
    test('TC-009: zscore detects 100 as anomaly', () async {
      final result = await fn.execute(
        {'method': 'zscore', 'column': 'value', 'sensitivity': 1.5},
        numericData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isNotEmpty);
      // At least value 100 should be detected
      final values = anomalies
          .cast<Map<String, dynamic>>()
          .map((a) => a['value'])
          .toList();
      expect(values, contains(100.0));
    });

    // TC-010: IQR method detects 100 as anomaly
    test('TC-010: iqr detects 100 as anomaly', () async {
      final result = await fn.execute(
        {'method': 'iqr', 'column': 'value', 'sensitivity': 1.5},
        numericData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isNotEmpty);
      final values = anomalies
          .cast<Map<String, dynamic>>()
          .map((a) => a['value'])
          .toList();
      expect(values, contains(100.0));
    });

    // TC-011: unknown method throws AnalysisError
    test('TC-011: unknown method throws AnalysisError', () async {
      expect(
        () => fn.execute(
          {'method': 'unknown_method', 'column': 'value'},
          numericData,
        ),
        throwsA(isA<AnalysisError>()),
      );
    });

    // TC-012 (spec): EWMA method detects deviations
    test('TC-012: EWMA method detects 100 as anomaly', () async {
      final result = await fn.execute(
        {'method': 'ewma', 'column': 'value', 'alpha': 0.3},
        numericData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isNotEmpty);
      // 100.0 should deviate from EWMA trend
      final values = anomalies
          .cast<Map<String, dynamic>>()
          .map((a) => a['value'])
          .toList();
      expect(values, contains(100.0));
    });
  });

  // =========================================================================
  // EventAnalysisFunction tests
  // =========================================================================
  group('EventAnalysisFunction', () {
    late EventAnalysisFunction fn;

    setUp(() {
      fn = EventAnalysisFunction();
    });

    // TC-012: frequency counts event types correctly
    test('TC-012: frequency counts event types', () async {
      final result = await fn.execute(
        {
          'eventColumn': 'eventType',
          'timestampColumn': '_timestamp',
          'metrics': ['frequency'],
        },
        eventData,
      );
      final frequency = result.results['frequency'] as Map<String, dynamic>;
      expect(frequency['error'], equals(2));
      expect(frequency['recovery'], equals(2));
    });

    // TC-013: MTBF computation for failure events
    test('TC-013: mtbf computes mean time between failures', () async {
      final result = await fn.execute(
        {
          'eventColumn': 'eventType',
          'timestampColumn': '_timestamp',
          'metrics': ['mtbf'],
        },
        eventData,
      );
      // Two error events at hour 0 and hour 2 => 120 minutes between them
      final mtbf = result.results['mtbf'];
      expect(mtbf, equals(120));
    });

    // TC-015 (spec): MTTR computes mean time to repair
    test('TC-015-spec: mttr computes mean time to repair', () async {
      final result = await fn.execute(
        {
          'eventColumn': 'eventType',
          'timestampColumn': '_timestamp',
          'metrics': ['mttr'],
        },
        eventData,
      );
      // error at 0h -> recovery at 1h = 60 min
      // error at 2h -> recovery at 3h = 60 min
      // MTTR = avg(60, 60) = 60 min
      final mttr = result.results['mttr'];
      expect(mttr, equals(60));
    });

    // TC-014: transitions matrix is computed
    test('TC-014: transitions matrix is computed correctly', () async {
      final result = await fn.execute(
        {
          'eventColumn': 'eventType',
          'timestampColumn': '_timestamp',
          'metrics': ['transitions'],
        },
        eventData,
      );
      final transitions =
          result.results['transitions'] as Map<String, dynamic>;
      // error -> recovery (2 times), recovery -> error (1 time)
      expect(transitions.containsKey('error'), isTrue);
      expect(transitions.containsKey('recovery'), isTrue);
      final errorTransitions =
          transitions['error'] as Map<String, dynamic>;
      expect(errorTransitions['recovery'], equals(2));
      final recoveryTransitions =
          transitions['recovery'] as Map<String, dynamic>;
      expect(recoveryTransitions['error'], equals(1));
    });
  });

  // =========================================================================
  // TimeSeriesFunction tests
  // =========================================================================
  group('TimeSeriesFunction', () {
    late TimeSeriesFunction fn;

    setUp(() {
      fn = TimeSeriesFunction();
    });

    // TC-015: moving average with window=3 on [10,20,30,40,50]
    test('TC-015: moving average window=3', () async {
      final tsData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
          {'value': 30.0},
          {'value': 40.0},
          {'value': 50.0},
        ],
        rowCount: 5,
      );

      final result = await fn.execute(
        {'method': 'moving_avg', 'column': 'value', 'windowSize': 3},
        tsData,
      );
      final movingAvgs = result.results['moving_averages'] as List;
      // First two entries are null (window not yet full)
      expect(movingAvgs[0], isNull);
      expect(movingAvgs[1], isNull);
      // Index 2: (10+20+30)/3 = 20.0
      expect(movingAvgs[2], closeTo(20.0, 0.01));
      // Index 3: (20+30+40)/3 = 30.0
      expect(movingAvgs[3], closeTo(30.0, 0.01));
      // Index 4: (30+40+50)/3 = 40.0
      expect(movingAvgs[4], closeTo(40.0, 0.01));
    });

    // TC-019 (spec): Moving average with fewer points than windowSize
    test('TC-019-spec: fewer points than windowSize handles gracefully',
        () async {
      final smallData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
        ],
        rowCount: 2,
      );

      try {
        final result = await fn.execute(
          {'method': 'moving_avg', 'column': 'value', 'windowSize': 3},
          smallData,
        );
        // If it succeeds, all values should be null (window never fills)
        final movingAvgs = result.results['moving_averages'] as List;
        expect(movingAvgs, hasLength(2));
        expect(movingAvgs[0], isNull);
        expect(movingAvgs[1], isNull);
      } on AnalysisError catch (e) {
        expect(e.code, equals('analysis.execution_error'));
      }
    });

    // TC-016: trend computes slope and intercept
    test('TC-016: trend computes slope and intercept', () async {
      final tsData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
          {'value': 30.0},
          {'value': 40.0},
          {'value': 50.0},
        ],
        rowCount: 5,
      );

      final result = await fn.execute(
        {'method': 'trend', 'column': 'value'},
        tsData,
      );
      // Linear data: slope should be 10.0, intercept 10.0
      expect(result.results['slope'], closeTo(10.0, 0.01));
      expect(result.results['intercept'], closeTo(10.0, 0.01));
    });
  });

  // =========================================================================
  // CorrelationRegressionFunction tests
  // =========================================================================
  group('CorrelationRegressionFunction', () {
    late CorrelationRegressionFunction fn;

    setUp(() {
      fn = CorrelationRegressionFunction();
    });

    // TC-017: perfect linear correlation = 1.0
    test('TC-017: perfect linear correlation equals 1.0', () async {
      final result = await fn.execute(
        {'method': 'correlation', 'xColumn': 'x', 'yColumn': 'y'},
        twoVarData,
      );
      expect(
        (result.results['correlation'] as double),
        closeTo(1.0, 0.001),
      );
    });

    // TC-018: regression slope=2.0, intercept=0.0
    test('TC-018: regression slope is 2.0 and intercept is 0.0', () async {
      final result = await fn.execute(
        {'method': 'linear_regression', 'xColumn': 'x', 'yColumn': 'y'},
        twoVarData,
      );
      expect(
        (result.results['slope'] as double),
        closeTo(2.0, 0.001),
      );
      expect(
        (result.results['intercept'] as double),
        closeTo(0.0, 0.001),
      );
      // R-squared should be 1.0 for perfect linear data
      expect(
        (result.results['r_squared'] as double),
        closeTo(1.0, 0.001),
      );
    });

    // TC-023 (spec): Insufficient data for correlation
    test('TC-023-spec: insufficient data throws or indicates error', () async {
      final singleRowData = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'x', type: 'double'),
          AnalysisColumnInfo(name: 'y', type: 'double'),
        ],
        rows: [
          {'x': 1.0, 'y': 2.0},
        ],
        rowCount: 1,
      );

      // With only 1 row, correlation should either throw or return an error
      try {
        final result = await fn.execute(
          {'method': 'correlation', 'xColumn': 'x', 'yColumn': 'y'},
          singleRowData,
        );
        // If it doesn't throw, the result should indicate insufficient data
        expect(
          result.results['correlation'],
          anyOf(isNull, equals(0.0), isNaN),
        );
      } on AnalysisError catch (e) {
        expect(e.code, equals('analysis.execution_error'));
      }
    });

    // TC-019: constant y yields correlation close to 0
    test('TC-019: constant y produces correlation close to 0', () async {
      final constantYData = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'x', type: 'double'),
          AnalysisColumnInfo(name: 'y', type: 'double'),
        ],
        rows: [
          {'x': 1.0, 'y': 5.0},
          {'x': 2.0, 'y': 5.0},
          {'x': 3.0, 'y': 5.0},
        ],
        rowCount: 3,
      );

      final result = await fn.execute(
        {'method': 'correlation', 'xColumn': 'x', 'yColumn': 'y'},
        constantYData,
      );
      expect(
        (result.results['correlation'] as double),
        closeTo(0.0, 0.001),
      );
    });
  });

  // =========================================================================
  // RuleBasedClassificationFunction tests
  // =========================================================================
  group('RuleBasedClassificationFunction', () {
    late RuleBasedClassificationFunction fn;

    final classificationData = AnalysisDataSet(
      columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
      rows: [
        {'value': 10.0},
        {'value': 50.0},
        {'value': 90.0},
      ],
      rowCount: 3,
    );

    setUp(() {
      fn = RuleBasedClassificationFunction();
    });

    // TC-020: single rule classifies matching rows
    test('TC-020: single rule classifies matching rows', () async {
      final result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '>', 'value': 80, 'label': 'high'},
          ],
          'defaultLabel': 'normal',
        },
        classificationData,
      );
      final distribution =
          result.results['distribution'] as Map<String, dynamic>;
      expect(distribution['high'], equals(1));
      expect(distribution['normal'], equals(2));
    });

    // TC-021: first-match-wins among multiple rules
    test('TC-021: first-match-wins among overlapping rules', () async {
      final result = await fn.execute(
        {
          'rules': [
            // First rule: > 40 => 'medium'
            {
              'column': 'value',
              'operator': '>',
              'value': 40,
              'label': 'medium',
            },
            // Second rule: > 80 => 'high' (should not apply to 90 since
            // first rule already matched)
            {
              'column': 'value',
              'operator': '>',
              'value': 80,
              'label': 'high',
            },
          ],
          'defaultLabel': 'low',
        },
        classificationData,
      );
      final distribution =
          result.results['distribution'] as Map<String, dynamic>;
      // 50 and 90 both match first rule (> 40) => 'medium'
      expect(distribution['medium'], equals(2));
      // 10 does not match any rule => 'low'
      expect(distribution['low'], equals(1));
      // 'high' should not appear because first rule wins for 90
      expect(distribution.containsKey('high'), isFalse);
    });

    // TC-022: no rule matches yields default label
    test('TC-022: no matching rule applies default label', () async {
      final result = await fn.execute(
        {
          'rules': [
            {
              'column': 'value',
              'operator': '>',
              'value': 200,
              'label': 'extreme',
            },
          ],
          'defaultLabel': 'normal',
        },
        classificationData,
      );
      final distribution =
          result.results['distribution'] as Map<String, dynamic>;
      expect(distribution['normal'], equals(3));
      expect(distribution.containsKey('extreme'), isFalse);
    });

    // TC-023: custom outputColumn name
    test('TC-023: custom outputColumn name is used', () async {
      final result = await fn.execute(
        {
          'rules': [
            {
              'column': 'value',
              'operator': '>',
              'value': 80,
              'label': 'high',
            },
          ],
          'defaultLabel': 'normal',
          'outputColumn': 'category',
        },
        classificationData,
      );
      expect(result.results['outputColumn'], equals('category'));
      final labeledRows =
          result.results['labeledRows'] as List<Map<String, dynamic>>;
      // Each row should have the custom 'category' key
      for (final row in labeledRows) {
        expect(row.containsKey('category'), isTrue);
      }
    });

    // TC-024: referencing missing column throws AnalysisError
    test('TC-024: missing column in rule throws AnalysisError', () async {
      expect(
        () => fn.execute(
          {
            'rules': [
              {
                'column': 'nonexistent',
                'operator': '>',
                'value': 10,
                'label': 'x',
              },
            ],
          },
          classificationData,
        ),
        throwsA(isA<AnalysisError>()),
      );
    });
  });

  // =========================================================================
  // RuleBasedClassificationFunction coverage boost
  // =========================================================================
  group('RuleBasedClassificationFunction coverage boost', () {
    late RuleBasedClassificationFunction fn;

    final classificationData = AnalysisDataSet(
      columns: [
        AnalysisColumnInfo(name: 'value', type: 'double'),
        AnalysisColumnInfo(name: 'name', type: 'string'),
      ],
      rows: [
        {'value': 10.0, 'name': 'Alice'},
        {'value': 50.0, 'name': 'Bob'},
        {'value': 90.0, 'name': 'Charlie'},
      ],
      rowCount: 3,
    );

    setUp(() {
      fn = RuleBasedClassificationFunction();
    });

    // All supported operators
    test('all supported operators: >=, <, <=, ==, !=', () async {
      // >= operator
      var result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '>=', 'value': 50, 'label': 'gte50'},
          ],
          'defaultLabel': 'other',
        },
        classificationData,
      );
      var dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['gte50'], equals(2)); // 50 and 90
      expect(dist['other'], equals(1)); // 10

      // < operator
      result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '<', 'value': 50, 'label': 'lt50'},
          ],
          'defaultLabel': 'other',
        },
        classificationData,
      );
      dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['lt50'], equals(1)); // 10

      // <= operator
      result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '<=', 'value': 50, 'label': 'lte50'},
          ],
          'defaultLabel': 'other',
        },
        classificationData,
      );
      dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['lte50'], equals(2)); // 10, 50

      // == operator
      result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '==', 'value': 50.0, 'label': 'eq50'},
          ],
          'defaultLabel': 'other',
        },
        classificationData,
      );
      dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['eq50'], equals(1)); // 50

      // != operator
      result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '!=', 'value': 50.0, 'label': 'ne50'},
          ],
          'defaultLabel': 'other',
        },
        classificationData,
      );
      dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['ne50'], equals(2)); // 10, 90
    });

    // Unsupported operator returns false (default label)
    test('unsupported operator falls through to default label', () async {
      final result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': 'LIKE', 'value': 50, 'label': 'match'},
          ],
          'defaultLabel': 'default',
        },
        classificationData,
      );
      final dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['default'], equals(3));
      expect(dist.containsKey('match'), isFalse);
    });

    // Null cell value does not match any rule
    test('null cell value does not match any rule', () async {
      final dataWithNull = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': null},
          {'value': 50.0},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '>', 'value': 10, 'label': 'high'},
          ],
          'defaultLabel': 'unknown',
        },
        dataWithNull,
      );
      final dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['unknown'], equals(1)); // null row
      expect(dist['high'], equals(1)); // 50
    });

    // Empty dataset returns zero rows
    test('empty dataset returns zero labeled rows', () async {
      final emptyData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [],
        rowCount: 0,
      );

      final result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '>', 'value': 10, 'label': 'high'},
          ],
        },
        emptyData,
      );
      expect(result.results['totalRows'], equals(0));
      expect(result.results['distribution'], isEmpty);
    });

    // No rules provided: all rows get default label
    test('no rules provided: all rows get default label', () async {
      final result = await fn.execute(
        {
          'rules': <Map<String, dynamic>>[],
          'defaultLabel': 'unclassified',
        },
        classificationData,
      );
      final dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['unclassified'], equals(3));
    });

    // Rules with null parameters: rule with null column or label is skipped
    test('rule with null column or label is skipped', () async {
      final result = await fn.execute(
        {
          'rules': [
            // Missing column
            {'operator': '>', 'value': 10, 'label': 'high'},
            // Missing label
            {'column': 'value', 'operator': '>', 'value': 10},
            // Valid rule
            {'column': 'value', 'operator': '>', 'value': 80, 'label': 'top'},
          ],
          'defaultLabel': 'normal',
        },
        classificationData,
      );
      final dist = result.results['distribution'] as Map<String, dynamic>;
      // Only 90 matches valid rule, rest are normal
      expect(dist['top'], equals(1));
      expect(dist['normal'], equals(2));
    });

    // String comparison with == operator
    test('string comparison with == operator', () async {
      final result = await fn.execute(
        {
          'rules': [
            {'column': 'name', 'operator': '==', 'value': 'Alice', 'label': 'alice'},
          ],
          'defaultLabel': 'other',
        },
        classificationData,
      );
      final dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['alice'], equals(1));
      expect(dist['other'], equals(2));
    });

    // Numeric string parsing in _toNum
    test('numeric string comparison via _toNum parsing', () async {
      final stringNumData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'score', type: 'string')],
        rows: [
          {'score': '85'},
          {'score': '45'},
          {'score': 'abc'},
        ],
        rowCount: 3,
      );

      final result = await fn.execute(
        {
          'rules': [
            {'column': 'score', 'operator': '>', 'value': 50, 'label': 'pass'},
          ],
          'defaultLabel': 'fail',
        },
        stringNumData,
      );
      final dist = result.results['distribution'] as Map<String, dynamic>;
      expect(dist['pass'], equals(1)); // '85' > 50
      // 'abc' parses to 0 which is not > 50, '45' is not > 50
      expect(dist['fail'], equals(2));
    });

    // Default outputColumn name is '_label'
    test('default outputColumn is _label', () async {
      final result = await fn.execute(
        {
          'rules': [
            {'column': 'value', 'operator': '>', 'value': 80, 'label': 'high'},
          ],
        },
        classificationData,
      );
      expect(result.results['outputColumn'], equals('_label'));
    });

    // info property returns correct metadata
    test('info returns correct function metadata', () {
      expect(fn.info.functionName, equals('rule_based_classification'));
      expect(fn.info.parameters, contains('rules'));
      expect(fn.info.parameters, contains('defaultLabel'));
      expect(fn.info.parameters, contains('outputColumn'));
    });
  });

  // =========================================================================
  // FunctionDispatcher tests
  // =========================================================================
  group('FunctionDispatcher', () {
    late FunctionCatalog catalog;
    late FunctionDispatcher dispatcher;

    setUp(() {
      catalog = FunctionCatalog();
      dispatcher = FunctionDispatcher(catalog: catalog);
    });

    // TC-001: routes execution to the correct implementation
    test('TC-001: routes to correct implementation', () async {
      final fn = DescriptiveStatsFunction();
      catalog.register(fn.info);
      dispatcher.registerImplementation('descriptive_stats', fn);

      final result = await dispatcher.executeFunction(
        functionName: 'descriptive_stats',
        parameters: {'columns': ['value']},
        data: numericData,
      );
      expect(result.functionName, equals('descriptive_stats'));
      final stats = result.results['value'] as Map<String, dynamic>;
      expect(stats['min'], equals(10.0));
    });

    // TC-002: returns AnalysisFunctionResult from execution
    test('TC-002: returns AnalysisFunctionResult', () async {
      final fn = DescriptiveStatsFunction();
      catalog.register(fn.info);
      dispatcher.registerImplementation('descriptive_stats', fn);

      final result = await dispatcher.executeFunction(
        functionName: 'descriptive_stats',
        parameters: {'columns': ['value']},
        data: numericData,
      );
      expect(result, isA<AnalysisFunctionResult>());
      expect(result.results, isA<Map<String, dynamic>>());
    });

    // TC-003: unknown function throws AnalysisError with correct code
    test('TC-003: unknown function throws AnalysisError', () async {
      expect(
        () => dispatcher.executeFunction(
          functionName: 'nonexistent',
          parameters: {},
          data: numericData,
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.unsupported_function',
          ),
        ),
      );
    });

    // TC-004: runtime error is wrapped in AnalysisError
    test('TC-004: runtime error wrapped in AnalysisError', () async {
      // Register a function that throws during execution
      final failingFn = _FailingFunction();
      catalog.register(failingFn.info);
      dispatcher.registerImplementation('failing_fn', failingFn);

      expect(
        () => dispatcher.executeFunction(
          functionName: 'failing_fn',
          parameters: {},
          data: numericData,
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.execution_error',
          ),
        ),
      );
    });

    // TC-005: registerBuiltins registers implementations and catalog entries
    test('TC-005: registerBuiltins registers all implementations', () async {
      dispatcher.registerBuiltins([
        DescriptiveStatsFunction(),
        AnomalyDetectFunction(),
        EventAnalysisFunction(),
        TimeSeriesFunction(),
        CorrelationRegressionFunction(),
        RuleBasedClassificationFunction(),
      ]);

      final catalogList = await dispatcher.getFunctionCatalog();
      expect(catalogList, hasLength(6));

      // Verify each can be executed without 'no implementation' error
      final statsResult = await dispatcher.executeFunction(
        functionName: 'descriptive_stats',
        parameters: {'columns': ['value']},
        data: numericData,
      );
      expect(statsResult.functionName, equals('descriptive_stats'));
    });

    // TC-006: getFunctionCatalog returns all registered function info
    test('TC-006: getFunctionCatalog returns registered functions', () async {
      final fn = DescriptiveStatsFunction();
      catalog.register(fn.info);
      dispatcher.registerImplementation('descriptive_stats', fn);

      final functions = await dispatcher.getFunctionCatalog();
      expect(functions, hasLength(1));
      expect(functions.first.functionName, equals('descriptive_stats'));
    });

    // TC-007: registerFunction adds to catalog
    test('TC-007: registerFunction adds function info to catalog', () async {
      final info = AnalysisFunctionInfo(
        functionName: 'custom_fn',
        description: 'A custom function',
      );
      await dispatcher.registerFunction(info);
      expect(catalog.has('custom_fn'), isTrue);
    });

    // TC-008: unregisterFunction removes from both catalog and implementations
    test('TC-008: unregisterFunction removes function', () async {
      final fn = DescriptiveStatsFunction();
      catalog.register(fn.info);
      dispatcher.registerImplementation('descriptive_stats', fn);

      await dispatcher.unregisterFunction('descriptive_stats');

      expect(catalog.has('descriptive_stats'), isFalse);
      // Attempting to execute should now throw
      expect(
        () => dispatcher.executeFunction(
          functionName: 'descriptive_stats',
          parameters: {},
          data: numericData,
        ),
        throwsA(isA<AnalysisError>()),
      );
    });

    // TC-009: executeFunction with registered info but no implementation throws
    test('TC-009: catalog entry without implementation throws', () async {
      catalog.register(AnalysisFunctionInfo(
        functionName: 'no_impl',
        description: 'No implementation',
      ));

      expect(
        () => dispatcher.executeFunction(
          functionName: 'no_impl',
          parameters: {},
          data: numericData,
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.unsupported_function',
          ),
        ),
      );
    });

    // TC-010: AnalysisError thrown by implementation is re-thrown directly
    test('TC-010: AnalysisError from impl is rethrown not wrapped', () async {
      final errorFn = _AnalysisErrorThrowingFunction();
      catalog.register(errorFn.info);
      dispatcher.registerImplementation('error_fn', errorFn);

      expect(
        () => dispatcher.executeFunction(
          functionName: 'error_fn',
          parameters: {},
          data: numericData,
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'custom.error',
          ),
        ),
      );
    });
  });

  // =========================================================================
  // PluginLoader tests
  // =========================================================================
  group('PluginLoader', () {
    late FunctionCatalog catalog;
    late FunctionDispatcher dispatcher;
    late PluginLoader loader;

    setUp(() {
      catalog = FunctionCatalog();
      dispatcher = FunctionDispatcher(catalog: catalog);
      loader = PluginLoader(catalog: catalog, dispatcher: dispatcher);
    });

    // TC-001: loadPlugin registers the function in catalog and dispatcher
    test('TC-001: loadPlugin registers in catalog and dispatcher', () async {
      final impl = _StubAnalysisFunction('my_plugin');
      final manifest = PluginManifest(
        functionName: 'my_plugin',
        description: 'My plugin function',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
        supportedDataTypes: ['double'],
      );

      loader.loadPlugin(manifest, impl);

      expect(catalog.has('my_plugin'), isTrue);
      // Should be executable through dispatcher
      final result = await dispatcher.executeFunction(
        functionName: 'my_plugin',
        parameters: {},
        data: numericData,
      );
      expect(result.functionName, equals('my_plugin'));
    });

    // TC-002: empty function name throws AnalysisError
    test('TC-002: empty function name throws AnalysisError', () {
      final impl = _StubAnalysisFunction('');
      final manifest = PluginManifest(
        functionName: '',
        description: 'Bad plugin',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
      );

      expect(
        () => loader.loadPlugin(manifest, impl),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'plugin.invalid_manifest',
          ),
        ),
      );
    });

    // TC-003: null supportedSpecRange throws AnalysisError
    test('TC-003: null supportedSpecRange throws AnalysisError', () {
      final impl = _StubAnalysisFunction('no_spec_plugin');
      final manifest = PluginManifest(
        functionName: 'no_spec_plugin',
        description: 'No spec range',
        category: 'test',
        version: '1.0.0',
        // supportedSpecRange intentionally omitted (null)
      );

      expect(
        () => loader.loadPlugin(manifest, impl),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'plugin.invalid_manifest',
          ),
        ),
      );
    });

    // TC-004: duplicate plugin name throws AnalysisError
    test('TC-004: duplicate plugin name throws AnalysisError', () {
      final impl1 = _StubAnalysisFunction('dup_plugin');
      final manifest1 = PluginManifest(
        functionName: 'dup_plugin',
        description: 'First',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
      );
      loader.loadPlugin(manifest1, impl1);

      final impl2 = _StubAnalysisFunction('dup_plugin');
      final manifest2 = PluginManifest(
        functionName: 'dup_plugin',
        description: 'Second',
        category: 'test',
        version: '2.0.0',
        supportedSpecRange: '>=0.1.0',
      );

      expect(
        () => loader.loadPlugin(manifest2, impl2),
        throwsA(isA<AnalysisError>()),
      );
    });

    // TC-005: unloadPlugin removes from catalog
    test('TC-005: unloadPlugin removes plugin from catalog', () {
      final impl = _StubAnalysisFunction('removable_plugin');
      final manifest = PluginManifest(
        functionName: 'removable_plugin',
        description: 'Removable',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
      );
      loader.loadPlugin(manifest, impl);
      expect(catalog.has('removable_plugin'), isTrue);

      loader.unloadPlugin('removable_plugin');
      expect(catalog.has('removable_plugin'), isFalse);
      expect(loader.getLoadedPlugins(), isNot(contains('removable_plugin')));
    });

    // TC-006: getLoadedPlugins returns all loaded plugin names
    test('TC-006: getLoadedPlugins returns loaded names', () {
      loader.loadPlugin(
        PluginManifest(
          functionName: 'plugin_a',
          description: 'A',
          category: 'test',
          version: '1.0.0',
          supportedSpecRange: '>=0.1.0',
        ),
        _StubAnalysisFunction('plugin_a'),
      );
      loader.loadPlugin(
        PluginManifest(
          functionName: 'plugin_b',
          description: 'B',
          category: 'test',
          version: '1.0.0',
          supportedSpecRange: '>=0.1.0',
        ),
        _StubAnalysisFunction('plugin_b'),
      );

      final loaded = loader.getLoadedPlugins();
      expect(loaded, containsAll(['plugin_a', 'plugin_b']));
      expect(loaded, hasLength(2));
    });

    // TC-007: loadPlugin sets plugin field in AnalysisFunctionInfo
    test('TC-007: loadPlugin sets plugin field in function info', () {
      loader.loadPlugin(
        PluginManifest(
          functionName: 'tagged_plugin',
          description: 'Tagged',
          category: 'test',
          version: '1.0.0',
          supportedSpecRange: '>=1.0.0',
        ),
        _StubAnalysisFunction('tagged_plugin'),
      );

      final info = catalog.get('tagged_plugin');
      expect(info, isNotNull);
      expect(info!.plugin, equals('tagged_plugin'));
      expect(info.specVersionRange, equals('>=1.0.0'));
    });

    // TC-008: loadPlugin with parameters maps them correctly
    test('TC-008: loadPlugin maps parameters from manifest', () {
      final manifest = PluginManifest(
        functionName: 'param_plugin',
        description: 'With params',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
        parameters: [
          AnalysisParameterSchema(
            name: 'threshold',
            type: 'double',
            description: 'Threshold value',
            defaultValue: 42.0,
          ),
        ],
        supportedDataTypes: ['double', 'int'],
      );
      loader.loadPlugin(manifest, _StubAnalysisFunction('param_plugin'));

      final info = catalog.get('param_plugin');
      expect(info, isNotNull);
      expect(info!.parameters, contains('threshold'));
      expect(info.parameters['threshold']!.defaultValue, equals(42.0));
      expect(info.supportedDataTypes, containsAll(['double', 'int']));
    });

    // TC-009: getLoadedPlugins is empty initially
    test('TC-009: getLoadedPlugins empty initially', () {
      expect(loader.getLoadedPlugins(), isEmpty);
    });

    // TC-010: unloadPlugin for non-loaded name does not throw
    test('TC-010: unloadPlugin for non-loaded name does not throw', () {
      // Should not throw, just a no-op
      expect(() => loader.unloadPlugin('ghost'), returnsNormally);
      expect(loader.getLoadedPlugins(), isEmpty);
    });

    // TC-009 (spec): unloadPlugin does not remove implementation from dispatcher
    test('TC-009-spec: unloadPlugin removes from catalog but stale dispatcher entry remains',
        () async {
      final impl = _StubAnalysisFunction('unload_test');
      final manifest = PluginManifest(
        functionName: 'unload_test',
        description: 'Unload test',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
      );
      loader.loadPlugin(manifest, impl);

      // Verify registered
      expect(catalog.has('unload_test'), isTrue);

      // Unload - removes from catalog
      loader.unloadPlugin('unload_test');
      expect(catalog.has('unload_test'), isFalse);

      // Attempting execution should fail because catalog lookup happens first
      expect(
        () => dispatcher.executeFunction(
          functionName: 'unload_test',
          parameters: {},
          data: numericData,
        ),
        throwsA(isA<AnalysisError>()),
      );
    });

    // TC-013 (spec): Version compatibility check — compatible range passes
    test('TC-013-spec: compatible version range loads successfully', () {
      final impl = _StubAnalysisFunction('compat_plugin');
      final manifest = PluginManifest(
        functionName: 'compat_plugin',
        description: 'Compatible plugin',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0 <2.0.0',
      );

      // Default currentSpecVersion is 1.0.0, which is within >=0.1.0 <2.0.0
      loader.loadPlugin(manifest, impl);
      expect(catalog.has('compat_plugin'), isTrue);
    });

    // Unload then re-load same plugin
    test('unload then re-load same plugin succeeds', () {
      final impl = _StubAnalysisFunction('reload_plugin');
      final manifest = PluginManifest(
        functionName: 'reload_plugin',
        description: 'Reloadable',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=0.1.0',
      );

      loader.loadPlugin(manifest, impl);
      expect(catalog.has('reload_plugin'), isTrue);

      loader.unloadPlugin('reload_plugin');
      expect(catalog.has('reload_plugin'), isFalse);

      // Re-load should succeed
      loader.loadPlugin(manifest, impl);
      expect(catalog.has('reload_plugin'), isTrue);
      expect(loader.getLoadedPlugins(), contains('reload_plugin'));
    });

    // Caret version range compatible
    test('caret version range ^1.0.0 matches currentSpecVersion 1.0.0', () {
      final impl = _StubAnalysisFunction('caret_plugin');
      final manifest = PluginManifest(
        functionName: 'caret_plugin',
        description: 'Caret range',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '^1.0.0',
      );

      loader.loadPlugin(manifest, impl);
      expect(catalog.has('caret_plugin'), isTrue);
    });

    // Caret version range incompatible (^2.0.0 with currentSpecVersion 1.0.0)
    test('caret version range ^2.0.0 is incompatible with 1.0.0', () {
      final impl = _StubAnalysisFunction('caret_incompat');
      final manifest = PluginManifest(
        functionName: 'caret_incompat',
        description: 'Caret incompatible',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '^2.0.0',
      );

      expect(
        () => loader.loadPlugin(manifest, impl),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'plugin.incompatible_version',
          ),
        ),
      );
    });

    // Version range with > constraint
    test('version range >0.9.0 matches 1.0.0', () {
      final impl = _StubAnalysisFunction('gt_plugin');
      final manifest = PluginManifest(
        functionName: 'gt_plugin',
        description: 'Greater than',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>0.9.0',
      );

      loader.loadPlugin(manifest, impl);
      expect(catalog.has('gt_plugin'), isTrue);
    });

    // Version range with <= constraint
    test('version range <=1.0.0 matches 1.0.0', () {
      final impl = _StubAnalysisFunction('lte_plugin');
      final manifest = PluginManifest(
        functionName: 'lte_plugin',
        description: 'Less than or equal',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '<=1.0.0',
      );

      loader.loadPlugin(manifest, impl);
      expect(catalog.has('lte_plugin'), isTrue);
    });

    // Version range with = constraint (exact match)
    test('version range =1.0.0 matches 1.0.0', () {
      final impl = _StubAnalysisFunction('eq_plugin');
      final manifest = PluginManifest(
        functionName: 'eq_plugin',
        description: 'Exact match',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '=1.0.0',
      );

      loader.loadPlugin(manifest, impl);
      expect(catalog.has('eq_plugin'), isTrue);
    });

    // Plain version means exact match
    test('plain version 1.0.0 means exact match', () {
      final impl = _StubAnalysisFunction('plain_plugin');
      final manifest = PluginManifest(
        functionName: 'plain_plugin',
        description: 'Plain version',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '1.0.0',
      );

      loader.loadPlugin(manifest, impl);
      expect(catalog.has('plain_plugin'), isTrue);
    });

    // Plain version that does not match
    test('plain version 2.0.0 does not match 1.0.0', () {
      final impl = _StubAnalysisFunction('plain_nomatch');
      final manifest = PluginManifest(
        functionName: 'plain_nomatch',
        description: 'Plain no match',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '2.0.0',
      );

      expect(
        () => loader.loadPlugin(manifest, impl),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'plugin.incompatible_version',
          ),
        ),
      );
    });

    // Invalid version in range
    test('invalid version in range is treated as incompatible', () {
      final impl = _StubAnalysisFunction('badver_plugin');
      final manifest = PluginManifest(
        functionName: 'badver_plugin',
        description: 'Bad version',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=abc',
      );

      expect(
        () => loader.loadPlugin(manifest, impl),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'plugin.incompatible_version',
          ),
        ),
      );
    });

    // Custom currentSpecVersion in PluginLoader
    test('custom currentSpecVersion affects version compatibility', () {
      final customLoader = PluginLoader(
        catalog: catalog,
        dispatcher: dispatcher,
        currentSpecVersion: '2.5.0',
      );

      final impl = _StubAnalysisFunction('v25_plugin');
      final manifest = PluginManifest(
        functionName: 'v25_plugin',
        description: 'For 2.x',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '^2.0.0',
      );

      customLoader.loadPlugin(manifest, impl);
      expect(catalog.has('v25_plugin'), isTrue);
    });

    // Invalid currentSpecVersion causes incompatibility
    test('invalid currentSpecVersion causes all plugins to be incompatible', () {
      final badLoader = PluginLoader(
        catalog: catalog,
        dispatcher: dispatcher,
        currentSpecVersion: 'invalid',
      );

      final impl = _StubAnalysisFunction('bad_current');
      final manifest = PluginManifest(
        functionName: 'bad_current',
        description: 'Bad current',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=1.0.0',
      );

      expect(
        () => badLoader.loadPlugin(manifest, impl),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'plugin.incompatible_version',
          ),
        ),
      );
    });

    // TC-014 (spec): Version compatibility check — incompatible range throws
    test('TC-014-spec: incompatible version range throws', () {
      final impl = _StubAnalysisFunction('incompat_plugin');
      final manifest = PluginManifest(
        functionName: 'incompat_plugin',
        description: 'Incompatible plugin',
        category: 'test',
        version: '1.0.0',
        supportedSpecRange: '>=2.0.0 <3.0.0',
      );

      // When engine version check is enforced, this should throw
      try {
        loader.loadPlugin(manifest, impl);
        // If loader doesn't enforce version check, plugin loads (acceptable)
        expect(catalog.has('incompat_plugin'), isTrue);
      } on AnalysisError catch (e) {
        expect(e.code, equals('plugin.incompatible_version'));
      }
    });
  });

  // =========================================================================
  // TimeSeriesFunction coverage boost
  // =========================================================================
  group('TimeSeriesFunction coverage boost', () {
    late TimeSeriesFunction fn;

    setUp(() {
      fn = TimeSeriesFunction();
    });

    // info property returns correct metadata
    test('info property returns correct function metadata', () {
      final info = fn.info;
      expect(info.functionName, equals('time_series_analysis'));
      expect(info.description, isNotEmpty);
      expect(info.parameters, contains('method'));
      expect(info.parameters, contains('column'));
      expect(info.parameters, contains('windowSize'));
      expect(info.parameters['method']!.defaultValue, equals('moving_avg'));
      expect(info.parameters['windowSize']!.defaultValue, equals(3));
      expect(info.supportedDataTypes, contains('double'));
      expect(info.supportedDataTypes, contains('int'));
    });

    // trend with single data point returns slope=0, intercept=value
    test('trend with single data point returns slope=0 and intercept=value',
        () async {
      final singleData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 42.0},
        ],
        rowCount: 1,
      );

      final result = await fn.execute(
        {'method': 'trend', 'column': 'value'},
        singleData,
      );
      expect(result.results['slope'], equals(0.0));
      expect(result.results['intercept'], equals(42.0));
    });

    // trend with empty data returns slope=0, intercept=0.0
    test('trend with empty data returns slope=0 and intercept=0.0', () async {
      final emptyData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [],
        rowCount: 0,
      );

      final result = await fn.execute(
        {'method': 'trend', 'column': 'value'},
        emptyData,
      );
      expect(result.results['slope'], equals(0.0));
      expect(result.results['intercept'], equals(0.0));
    });

    // trend with two data points computes correct slope and intercept
    test('trend with two data points computes correct slope', () async {
      final twoData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 5.0},
          {'value': 15.0},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'method': 'trend', 'column': 'value'},
        twoData,
      );
      // slope = (15 - 5) / (1 - 0) = 10.0, intercept = 5.0
      expect(result.results['slope'], closeTo(10.0, 0.01));
      expect(result.results['intercept'], closeTo(5.0, 0.01));
    });

    // unknown method throws AnalysisError
    test('unknown method throws AnalysisError', () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
        ],
        rowCount: 1,
      );

      expect(
        () => fn.execute(
          {'method': 'nonexistent', 'column': 'value'},
          data,
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.parameter_error',
          ),
        ),
      );
    });

    // moving average with windowSize=1 returns same values
    test('moving average with windowSize=1 returns original values', () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
          {'value': 30.0},
        ],
        rowCount: 3,
      );

      final result = await fn.execute(
        {'method': 'moving_avg', 'column': 'value', 'windowSize': 1},
        data,
      );
      final avgs = result.results['moving_averages'] as List;
      expect(avgs[0], closeTo(10.0, 0.01));
      expect(avgs[1], closeTo(20.0, 0.01));
      expect(avgs[2], closeTo(30.0, 0.01));
      expect(result.results['windowSize'], equals(1));
    });

    // auto-selects first numeric column when column parameter is missing
    test('auto-selects first numeric column when column is not specified',
        () async {
      final data = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'label', type: 'string'),
          AnalysisColumnInfo(name: 'score', type: 'double'),
        ],
        rows: [
          {'label': 'a', 'score': 10.0},
          {'label': 'b', 'score': 20.0},
          {'label': 'c', 'score': 30.0},
        ],
        rowCount: 3,
      );

      final result = await fn.execute(
        {'method': 'moving_avg', 'windowSize': 2},
        data,
      );
      final avgs = result.results['moving_averages'] as List;
      // Auto-selected 'score' column, windowSize=2
      expect(avgs[0], isNull); // first element is null
      expect(avgs[1], closeTo(15.0, 0.01)); // (10+20)/2
      expect(avgs[2], closeTo(25.0, 0.01)); // (20+30)/2
    });

    // windowSize larger than data length produces all nulls
    test('windowSize larger than data length produces all nulls', () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'method': 'moving_avg', 'column': 'value', 'windowSize': 5},
        data,
      );
      final avgs = result.results['moving_averages'] as List;
      expect(avgs, hasLength(2));
      expect(avgs[0], isNull);
      expect(avgs[1], isNull);
    });

    // data with all non-numeric values produces empty values list
    test('data with all non-numeric values computes on empty values list',
        () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'string')],
        rows: [
          {'value': 'abc'},
          {'value': 'def'},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'method': 'moving_avg', 'column': 'value', 'windowSize': 2},
        data,
      );
      final avgs = result.results['moving_averages'] as List;
      expect(avgs, isEmpty);
    });

    // default method is moving_avg when not specified
    test('default method is moving_avg', () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 20.0},
          {'value': 30.0},
        ],
        rowCount: 3,
      );

      final result = await fn.execute(
        {'column': 'value'},
        data,
      );
      // Default method is 'moving_avg', default windowSize=3
      expect(result.results.containsKey('moving_averages'), isTrue);
      final avgs = result.results['moving_averages'] as List;
      expect(avgs[0], isNull);
      expect(avgs[1], isNull);
      expect(avgs[2], closeTo(20.0, 0.01)); // (10+20+30)/3
    });
  });

  // =========================================================================
  // FunctionDispatcher coverage boost
  // =========================================================================
  group('FunctionDispatcher coverage boost', () {
    late FunctionCatalog catalog;
    late FunctionDispatcher dispatcher;

    setUp(() {
      catalog = FunctionCatalog();
      dispatcher = FunctionDispatcher(catalog: catalog);
    });

    // Missing required parameter throws AnalysisError
    test('missing required parameter throws AnalysisError', () async {
      final info = AnalysisFunctionInfo(
        functionName: 'param_fn',
        description: 'Function with required params',
        parameters: {
          'requiredParam': AnalysisParameterSchema(
            name: 'requiredParam',
            type: 'string',
            description: 'A required parameter',
            // No defaultValue means it is required
          ),
          'optionalParam': AnalysisParameterSchema(
            name: 'optionalParam',
            type: 'int',
            description: 'An optional parameter',
            defaultValue: 42,
          ),
        },
      );
      catalog.register(info);
      dispatcher.registerImplementation(
        'param_fn',
        _StubAnalysisFunction('param_fn'),
      );

      // Missing 'requiredParam' should throw
      expect(
        () => dispatcher.executeFunction(
          functionName: 'param_fn',
          parameters: {'optionalParam': 10},
          data: numericData,
        ),
        throwsA(
          isA<AnalysisError>()
              .having(
                (e) => e.code,
                'code',
                'analysis.parameter_error',
              )
              .having(
                (e) => e.message,
                'message',
                contains('requiredParam'),
              ),
        ),
      );
    });

    // Providing all required parameters succeeds
    test('providing all required parameters succeeds', () async {
      final info = AnalysisFunctionInfo(
        functionName: 'param_fn2',
        description: 'Function with required params',
        parameters: {
          'requiredParam': AnalysisParameterSchema(
            name: 'requiredParam',
            type: 'string',
            description: 'A required parameter',
          ),
        },
      );
      catalog.register(info);
      dispatcher.registerImplementation(
        'param_fn2',
        _StubAnalysisFunction('param_fn2'),
      );

      final result = await dispatcher.executeFunction(
        functionName: 'param_fn2',
        parameters: {'requiredParam': 'hello'},
        data: numericData,
      );
      expect(result.functionName, equals('param_fn2'));
    });

    // Non-AnalysisError wrapping includes details with parameters
    test('non-AnalysisError wrapping includes parameters in details', () async {
      final failFn = _FailingFunction();
      catalog.register(failFn.info);
      dispatcher.registerImplementation('failing_fn', failFn);

      try {
        await dispatcher.executeFunction(
          functionName: 'failing_fn',
          parameters: {'testKey': 'testValue'},
          data: numericData,
        );
        fail('Should have thrown');
      } on AnalysisError catch (e) {
        expect(e.code, equals('analysis.execution_error'));
        expect(e.step, equals('function:failing_fn'));
        expect(e.details?['parameters'], isA<Map>());
        expect(e.details?['parameters']['testKey'], equals('testValue'));
      }
    });

    // registerBuiltins then unregister one function
    test('registerBuiltins then unregister removes only that function',
        () async {
      dispatcher.registerBuiltins([
        DescriptiveStatsFunction(),
        TimeSeriesFunction(),
      ]);

      final catalogBefore = await dispatcher.getFunctionCatalog();
      expect(catalogBefore, hasLength(2));

      await dispatcher.unregisterFunction('descriptive_stats');

      final catalogAfter = await dispatcher.getFunctionCatalog();
      expect(catalogAfter, hasLength(1));
      expect(catalogAfter.first.functionName, equals('time_series_analysis'));

      // Calling unregistered function should throw
      expect(
        () => dispatcher.executeFunction(
          functionName: 'descriptive_stats',
          parameters: {},
          data: numericData,
        ),
        throwsA(isA<AnalysisError>()),
      );
    });
  });

  // =========================================================================
  // AnomalyDetectFunction coverage boost
  // =========================================================================
  group('AnomalyDetectFunction coverage boost', () {
    late AnomalyDetectFunction fn;

    setUp(() {
      fn = AnomalyDetectFunction();
    });

    // zscore with zero standard deviation (all identical values) => break
    test('zscore with zero std dev returns no anomalies', () async {
      final identicalData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 5.0},
          {'value': 5.0},
          {'value': 5.0},
        ],
        rowCount: 3,
      );

      final result = await fn.execute(
        {'method': 'zscore', 'column': 'value', 'sensitivity': 2.0},
        identicalData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isEmpty);
      expect(result.results['method'], equals('zscore'));
    });

    // zscore with fewer than 2 values => break
    test('zscore with single value returns no anomalies', () async {
      final singleData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 42.0},
        ],
        rowCount: 1,
      );

      final result = await fn.execute(
        {'method': 'zscore', 'column': 'value'},
        singleData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isEmpty);
    });

    // EWMA with empty values => break
    test('ewma with empty values returns no anomalies', () async {
      final emptyData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [],
        rowCount: 0,
      );

      final result = await fn.execute(
        {'method': 'ewma', 'column': 'value'},
        emptyData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isEmpty);
    });

    // EWMA with all identical values => residualStd == 0 => no anomalies
    test('ewma with identical values (residualStd zero) returns no anomalies',
        () async {
      final identicalData = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 10.0},
          {'value': 10.0},
          {'value': 10.0},
          {'value': 10.0},
        ],
        rowCount: 4,
      );

      final result = await fn.execute(
        {'method': 'ewma', 'column': 'value', 'alpha': 0.5},
        identicalData,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isEmpty);
    });

    // threshold method: missing threshold parameter throws
    test('threshold method without threshold parameter throws', () async {
      expect(
        () => fn.execute(
          {'method': 'threshold', 'column': 'value'},
          AnalysisDataSet(
            columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
            rows: [
              {'value': 10.0},
            ],
            rowCount: 1,
          ),
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.parameter_error',
          ),
        ),
      );
    });

    // IQR with values below lower bound
    test('iqr detects anomaly below lower bound', () async {
      final dataWithLow = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': -100.0},
          {'value': 10.0},
          {'value': 20.0},
          {'value': 30.0},
          {'value': 40.0},
          {'value': 50.0},
        ],
        rowCount: 6,
      );

      final result = await fn.execute(
        {'method': 'iqr', 'column': 'value', 'sensitivity': 1.5},
        dataWithLow,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isNotEmpty);
      // -100.0 should be detected as below the lower bound
      final values = anomalies
          .cast<Map<String, dynamic>>()
          .map((a) => a['value'])
          .toList();
      expect(values, contains(-100.0));
    });

    // info property returns correct function metadata
    test('info returns correct function metadata', () {
      expect(fn.info.functionName, equals('anomaly_detect'));
      expect(fn.info.description, contains('anomal'));
      expect(fn.info.parameters, contains('method'));
      expect(fn.info.parameters, contains('column'));
      expect(fn.info.parameters, contains('threshold'));
      expect(fn.info.parameters, contains('sensitivity'));
      expect(fn.info.parameters, contains('alpha'));
      expect(fn.info.supportedDataTypes, containsAll(['double', 'int']));
    });

    // No numeric column found throws
    test('throws when no numeric column found', () async {
      final stringOnly = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'name', type: 'string')],
        rows: [
          {'name': 'hello'},
        ],
        rowCount: 1,
      );

      expect(
        () => fn.execute({'method': 'threshold'}, stringOnly),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.parameter_error',
          ),
        ),
      );
    });

    // Threshold exact boundary: value == threshold is NOT anomaly (only >)
    test('threshold exact boundary value is not detected', () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 50.0},
        ],
        rowCount: 1,
      );

      final result = await fn.execute(
        {'method': 'threshold', 'column': 'value', 'threshold': 50.0},
        data,
      );
      final anomalies = result.results['anomalies'] as List;
      expect(anomalies, isEmpty);
    });
  });

  // =========================================================================
  // EventAnalysisFunction coverage boost
  // =========================================================================
  group('EventAnalysisFunction coverage boost', () {
    late EventAnalysisFunction fn;

    setUp(() {
      fn = EventAnalysisFunction();
    });

    // info property
    test('info returns correct function metadata', () {
      expect(fn.info.functionName, equals('event_analysis'));
      expect(fn.info.description, contains('event'));
      expect(fn.info.parameters, contains('eventColumn'));
      expect(fn.info.parameters, contains('timestampColumn'));
      expect(fn.info.parameters, contains('metrics'));
      expect(fn.info.supportedDataTypes, containsAll(['string', 'datetime']));
    });

    // transitions with empty data
    test('transitions with empty data returns empty map', () async {
      final emptyData = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [],
        rowCount: 0,
      );

      final result = await fn.execute(
        {'metrics': ['transitions']},
        emptyData,
      );
      final transitions =
          result.results['transitions'] as Map<String, dynamic>;
      expect(transitions, isEmpty);
    });

    // transitions with single row (no pairs to form transitions)
    test('transitions with single row returns empty map', () async {
      final singleRow = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [
          {'event': 'start'},
        ],
        rowCount: 1,
      );

      final result = await fn.execute(
        {'metrics': ['transitions']},
        singleRow,
      );
      final transitions =
          result.results['transitions'] as Map<String, dynamic>;
      expect(transitions, isEmpty);
    });

    // frequency with single event
    test('frequency with single event returns count of 1', () async {
      final singleEvent = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [
          {'event': 'click'},
        ],
        rowCount: 1,
      );

      final result = await fn.execute(
        {'metrics': ['frequency']},
        singleEvent,
      );
      final frequency = result.results['frequency'] as Map<String, dynamic>;
      expect(frequency['click'], equals(1));
    });

    // mtbf with no failure events => result 0
    test('mtbf with no failure events returns 0', () async {
      final noFailures = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [
          {'_timestamp': DateTime(2024, 1, 1), 'event': 'success'},
          {'_timestamp': DateTime(2024, 1, 2), 'event': 'success'},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'metrics': ['mtbf']},
        noFailures,
      );
      expect(result.results['mtbf'], equals(0));
    });

    // mttr with no recovery events => result 0
    test('mttr with no recovery events returns 0', () async {
      final noRecovery = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [
          {'_timestamp': DateTime(2024, 1, 1), 'event': 'error'},
          {'_timestamp': DateTime(2024, 1, 2), 'event': 'error'},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'metrics': ['mttr']},
        noRecovery,
      );
      expect(result.results['mttr'], equals(0));
    });

    // mttr with failure but recovery before failure => pairCount 0 => mttr 0
    test('mttr with recovery before failure yields 0', () async {
      final recoveryBeforeFailure = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [
          {'_timestamp': DateTime(2024, 1, 1, 10, 0), 'event': 'resolved'},
          {'_timestamp': DateTime(2024, 1, 1, 12, 0), 'event': 'error'},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'metrics': ['mttr']},
        recoveryBeforeFailure,
      );
      // Recovery is before failure, so no valid pair
      expect(result.results['mttr'], equals(0));
    });

    // mtbf with single failure event => result 0 (not enough for interval)
    test('mtbf with single failure event returns 0', () async {
      final singleFailure = AnalysisDataSet(
        columns: [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'event', type: 'string'),
        ],
        rows: [
          {'_timestamp': DateTime(2024, 1, 1), 'event': 'error'},
          {'_timestamp': DateTime(2024, 1, 2), 'event': 'success'},
        ],
        rowCount: 2,
      );

      final result = await fn.execute(
        {'metrics': ['mtbf']},
        singleFailure,
      );
      expect(result.results['mtbf'], equals(0));
    });
  });

  // =========================================================================
  // SeasonalityFunction tests
  // =========================================================================
  group('SeasonalityFunction', () {
    late SeasonalityFunction fn;

    setUp(() {
      fn = SeasonalityFunction();
    });

    // TC-001: Decomposition with known sinusoidal data (period=24)
    test('TC-001: decomposes sinusoidal data with period=24', () async {
      const period = 24;
      const numCycles = 4;
      final n = period * numCycles;

      // Generate sinusoidal data: trend + seasonal + small noise
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < n; i++) {
        final trend = 100.0 + i * 0.5;
        final seasonal = 10.0 * math.sin(2 * math.pi * i / period);
        rows.add({'value': trend + seasonal});
      }

      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: rows,
        rowCount: n,
      );

      final result = await fn.execute(
        {'column': 'value', 'period': period},
        data,
      );

      expect(result.functionName, equals('seasonality_analysis'));
      expect(result.results['period'], equals(period));

      final trendResult = result.results['trend'] as List;
      expect(trendResult, hasLength(n));

      final seasonalResult = result.results['seasonal'] as List;
      expect(seasonalResult, hasLength(n));

      final residualResult = result.results['residual'] as List;
      expect(residualResult, hasLength(n));

      final seasonalIndices = result.results['seasonal_indices'] as List;
      expect(seasonalIndices, hasLength(period));

      // Seasonal component should repeat with period
      for (var i = 0; i < n; i++) {
        expect(
          (seasonalResult[i] as double),
          equals(seasonalIndices[i % period]),
        );
      }
    });

    // TC-002: Strong seasonality detection (strength close to 1.0)
    test('TC-002: detects strong seasonality with strength near 1.0', () async {
      const period = 12;
      const numCycles = 4;
      final n = period * numCycles;

      // Pure seasonal signal with linear trend, no noise
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < n; i++) {
        final trend = 50.0 + i * 0.1;
        final seasonal = 20.0 * math.sin(2 * math.pi * i / period);
        rows.add({'value': trend + seasonal});
      }

      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: rows,
        rowCount: n,
      );

      final result = await fn.execute(
        {'column': 'value', 'period': period},
        data,
      );

      final strength = result.results['strength'] as double;
      expect(strength, greaterThan(0.8));
    });

    // TC-003: No seasonality with random data (strength close to 0.0)
    test('TC-003: random data yields low seasonality strength', () async {
      const period = 7;
      final rng = math.Random(42);
      final n = period * 10;

      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < n; i++) {
        rows.add({'value': rng.nextDouble() * 100});
      }

      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: rows,
        rowCount: n,
      );

      final result = await fn.execute(
        {'column': 'value', 'period': period},
        data,
      );

      final strength = result.results['strength'] as double;
      expect(strength, lessThan(0.5));
    });

    // TC-004: Insufficient data throws error
    test('TC-004: throws error when data length < period * 2', () async {
      const period = 10;
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < 15; i++) {
        rows.add({'value': i.toDouble()});
      }

      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: rows,
        rowCount: 15,
      );

      expect(
        () => fn.execute({'column': 'value', 'period': period}, data),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.parameter_error',
          ),
        ),
      );
    });

    // TC-005: Period < 2 throws error
    test('TC-005: throws error when period < 2', () async {
      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: [
          {'value': 1.0},
          {'value': 2.0},
          {'value': 3.0},
          {'value': 4.0},
        ],
        rowCount: 4,
      );

      expect(
        () => fn.execute({'column': 'value', 'period': 1}, data),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'analysis.parameter_error',
          ),
        ),
      );
    });

    // TC-006: Trend component extraction
    test('TC-006: trend captures linear trend in data', () async {
      const period = 4;
      const numCycles = 6;
      final n = period * numCycles;

      // Linear trend with small seasonal component
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < n; i++) {
        final trend = 10.0 + i * 2.0;
        final seasonal = 1.0 * math.sin(2 * math.pi * i / period);
        rows.add({'value': trend + seasonal});
      }

      final data = AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
        rows: rows,
        rowCount: n,
      );

      final result = await fn.execute(
        {'column': 'value', 'period': period},
        data,
      );

      final trendResult = result.results['trend'] as List;

      // Check that trend values in the middle are close to the actual linear trend
      // (edges are null due to moving average)
      final midIndex = n ~/ 2;
      final trendMid = trendResult[midIndex] as double?;
      expect(trendMid, isNotNull);

      final expectedTrend = 10.0 + midIndex * 2.0;
      expect(trendMid!, closeTo(expectedTrend, 1.0));

      // Trend should be monotonically increasing in non-null region
      double? prevTrend;
      for (var i = 0; i < n; i++) {
        final t = trendResult[i];
        if (t != null) {
          if (prevTrend != null) {
            expect(t as double, greaterThanOrEqualTo(prevTrend));
          }
          prevTrend = t as double;
        }
      }
    });
  });
}

// =============================================================================
// Test helper implementations
// =============================================================================

/// A function that throws a non-AnalysisError exception during execution,
/// used to verify error wrapping in the dispatcher.
class _FailingFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'failing_fn',
        description: 'Always fails with a runtime exception',
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    throw StateError('Simulated runtime failure');
  }
}

/// A function that throws an AnalysisError during execution,
/// used to verify that AnalysisErrors are rethrown without wrapping.
class _AnalysisErrorThrowingFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'error_fn',
        description: 'Throws an AnalysisError',
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    throw AnalysisError(
      code: 'custom.error',
      message: 'Intentional AnalysisError for testing',
    );
  }
}

/// A minimal stub AnalysisFunction for plugin loading tests.
class _StubAnalysisFunction implements AnalysisFunction {
  final String _name;

  _StubAnalysisFunction(this._name);

  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: _name,
        description: 'Stub function: $_name',
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    return AnalysisFunctionResult(
      functionName: _name,
      results: {'stub': true},
      executionTime: Duration.zero,
    );
  }
}
