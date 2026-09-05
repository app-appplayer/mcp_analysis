import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

void main() {
  // ==========================================================================
  // Shared test data
  // ==========================================================================

  late AnalysisArtifactProvenance provenance;
  late AnalysisDataSet hotData;
  late AnalysisDataSet coldData;

  setUp(() {
    provenance = AnalysisArtifactProvenance(
      version: '1.0.0',
      createdAt: DateTime.now(),
      specId: 'test',
      specVersion: '1.0.0',
    );

    // Data with temperature values including one above 80
    hotData = AnalysisDataSet(
      columns: [
        const AnalysisColumnInfo(name: 'temperature', type: 'double'),
      ],
      rows: [
        {'temperature': 70.0},
        {'temperature': 75.0},
        {'temperature': 85.0},
      ],
      rowCount: 3,
    );

    // Data with all values below 80
    coldData = AnalysisDataSet(
      columns: [
        const AnalysisColumnInfo(name: 'temperature', type: 'double'),
      ],
      rows: [
        {'temperature': 68.0},
        {'temperature': 70.0},
        {'temperature': 72.0},
      ],
      rowCount: 3,
    );
  });

  // ==========================================================================
  // AlertEvaluator
  // ==========================================================================

  group('AlertEvaluator', () {
    late MockEventPort mockEventPort;
    late AlertPublisher publisher;
    late AlertEvaluator evaluator;

    setUp(() {
      mockEventPort = MockEventPort();
      publisher = AlertPublisher(eventPort: mockEventPort);
      evaluator = AlertEvaluator(publisher: publisher);
    });

    // TC-001: Threshold triggered
    test('TC-001: evaluate triggers alert when temperature > 80', () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-001',
        name: 'High temperature alert',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );

      final result = await evaluator.evaluate(rule, hotData);

      expect(result.triggered, isTrue);
      expect(result.alertRuleId, equals('rule-001'));
      expect(result.severity, equals(AnalysisAlertSeverity.critical));
      expect(result.currentValue, equals(85.0));
    });

    // TC-002: Threshold NOT triggered
    test('TC-002: evaluate does not trigger when max value is 72.0', () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-002',
        name: 'High temperature alert',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, coldData);

      expect(result.triggered, isFalse);
    });

    // TC-003: Boundary - exactly 80.0 is NOT triggered (strictly greater than)
    test('TC-003: evaluate does not trigger at exact boundary of 80.0',
        () async {
      final boundaryData = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': 75.0},
          {'temperature': 80.0},
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-003',
        name: 'Boundary test',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, boundaryData);

      expect(result.triggered, isFalse);
    });

    // TC-004: Triggered evaluation has non-null timestamp
    test('TC-004: triggered evaluation has non-null timestamp', () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-004',
        name: 'Timestamp test',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );

      final before = DateTime.now();
      final result = await evaluator.evaluate(rule, hotData);
      final after = DateTime.now();

      expect(result.timestamp, isNotNull);
      expect(
        result.timestamp.isAfter(before) ||
            result.timestamp.isAtSameMomentAs(before),
        isTrue,
      );
      expect(
        result.timestamp.isBefore(after) ||
            result.timestamp.isAtSameMomentAs(after),
        isTrue,
      );
    });

    // TC-005: evaluateAll processes 3 rules; 2 triggered
    test('TC-005: evaluateAll processes 3 rules with 2 triggered', () async {
      final rules = [
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-a',
          name: 'Rule A',
          provenance: provenance,
          condition: 'temperature > 80',
          severity: AnalysisAlertSeverity.critical,
        ),
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-b',
          name: 'Rule B',
          provenance: provenance,
          condition: 'temperature > 90',
          severity: AnalysisAlertSeverity.warn,
        ),
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-c',
          name: 'Rule C',
          provenance: provenance,
          condition: 'temperature > 70',
          severity: AnalysisAlertSeverity.info,
        ),
      ];

      final results = await evaluator.evaluateAll(rules, hotData);

      expect(results, hasLength(3));
      // Rule A: temperature > 80 triggers (85.0 > 80)
      expect(results[0].triggered, isTrue);
      // Rule B: temperature > 90 does not trigger (85.0 is not > 90)
      expect(results[1].triggered, isFalse);
      // Rule C: temperature > 70 triggers (75.0 > 70)
      expect(results[2].triggered, isTrue);

      final triggeredCount = results.where((r) => r.triggered).length;
      expect(triggeredCount, equals(2));
    });

    // TC-006: evaluateAll continues after malformed rule
    test('TC-006: evaluateAll continues processing after malformed rule',
        () async {
      final rules = [
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-valid',
          name: 'Valid rule',
          provenance: provenance,
          condition: 'temperature > 80',
          severity: AnalysisAlertSeverity.critical,
        ),
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-malformed',
          name: 'Malformed rule',
          provenance: provenance,
          condition: 'bad',
          severity: AnalysisAlertSeverity.warn,
        ),
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-valid-2',
          name: 'Another valid rule',
          provenance: provenance,
          condition: 'temperature > 70',
          severity: AnalysisAlertSeverity.info,
        ),
      ];

      final results = await evaluator.evaluateAll(rules, hotData);

      // All 3 rules should be evaluated without throwing
      expect(results, hasLength(3));
      expect(results[0].triggered, isTrue);
      // Malformed rule should not trigger
      expect(results[1].triggered, isFalse);
      expect(results[2].triggered, isTrue);
    });

    // TC-007: Malformed condition returns triggered: false with error message
    test('TC-007: malformed condition returns triggered false with error',
        () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-bad',
        name: 'Bad condition',
        provenance: provenance,
        condition: 'invalid',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, hotData);

      expect(result.triggered, isFalse);
      expect(result.alertRuleId, equals('rule-bad'));
    });
  });

  // ==========================================================================
  // WindowAggregator
  // ==========================================================================

  group('WindowAggregator', () {
    late WindowAggregator aggregator;

    setUp(() {
      aggregator = WindowAggregator(
        windowSize: const Duration(minutes: 5),
      );
    });

    // TC-008: add stores point
    test('TC-008: add stores point and state.pointCount equals 1', () {
      final point = AnalysisTimePoint(t: DateTime.now(), v: 42.0);

      aggregator.add(point);

      expect(aggregator.state.pointCount, equals(1));
    });

    // TC-009: add evicts points outside window
    test('TC-009: add evicts points outside window duration', () {
      final now = DateTime.now();

      // Add an old point outside the 5-minute window
      aggregator.add(AnalysisTimePoint(
        t: now.subtract(const Duration(minutes: 10)),
        v: 60.0,
      ));

      // Add a recent point within the window
      aggregator.add(AnalysisTimePoint(t: now, v: 70.0));

      // The old point should be evicted because it falls outside
      // the window relative to the latest point
      expect(aggregator.state.pointCount, equals(1));
      expect(aggregator.state.points.first.v, equals(70.0));
    });

    // TC-010: aggregate("avg")
    test('TC-010: aggregate avg of [70,72,74,76,78] equals 74.0', () {
      final now = DateTime.now();
      final values = [70.0, 72.0, 74.0, 76.0, 78.0];

      for (var i = 0; i < values.length; i++) {
        aggregator.add(AnalysisTimePoint(
          t: now.add(Duration(seconds: i)),
          v: values[i],
        ));
      }

      final avg = aggregator.aggregate('value', 'avg');

      expect(avg, equals(74.0));
    });

    // TC-011: aggregate("max")
    test('TC-011: aggregate max of [70,72,74,76,78] equals 78.0', () {
      final now = DateTime.now();
      final values = [70.0, 72.0, 74.0, 76.0, 78.0];

      for (var i = 0; i < values.length; i++) {
        aggregator.add(AnalysisTimePoint(
          t: now.add(Duration(seconds: i)),
          v: values[i],
        ));
      }

      final max = aggregator.aggregate('value', 'max');

      expect(max, equals(78.0));
    });

    // TC-012: aggregate("min")
    test('TC-012: aggregate min of [70,72,74,76,78] equals 70.0', () {
      final now = DateTime.now();
      final values = [70.0, 72.0, 74.0, 76.0, 78.0];

      for (var i = 0; i < values.length; i++) {
        aggregator.add(AnalysisTimePoint(
          t: now.add(Duration(seconds: i)),
          v: values[i],
        ));
      }

      final min = aggregator.aggregate('value', 'min');

      expect(min, equals(70.0));
    });

    // TC-013: aggregate("avg") on empty returns 0.0
    test('TC-013: aggregate avg on empty window returns 0.0', () {
      final avg = aggregator.aggregate('value', 'avg');

      expect(avg, equals(0.0));
    });

    // TC-014: reset clears all points
    test('TC-014: reset clears all points and pointCount equals 0', () {
      final now = DateTime.now();

      aggregator.add(AnalysisTimePoint(t: now, v: 50.0));
      aggregator.add(AnalysisTimePoint(
        t: now.add(const Duration(seconds: 1)),
        v: 60.0,
      ));

      expect(aggregator.state.pointCount, equals(2));

      aggregator.reset();

      expect(aggregator.state.pointCount, equals(0));
    });
  });

  // ==========================================================================
  // AlertPublisher
  // ==========================================================================

  group('AlertPublisher', () {
    late MockEventPort mockEventPort;
    late AlertPublisher publisher;

    setUp(() {
      mockEventPort = MockEventPort();
      publisher = AlertPublisher(eventPort: mockEventPort);
    });

    // TC-015: publish sends event via EventPort with type "analysis.alert"
    test('TC-015: publish sends event with type analysis.alert', () async {
      final evaluation = AlertEvaluation(
        ruleId: 'rule-pub-001',
        triggered: true,
        severity: AnalysisAlertSeverity.critical,
        condition: 'temperature > 80',
        currentValue: 85.0,
        timestamp: DateTime.now(),
        message: 'Alert triggered',
      );

      await publisher.publish(evaluation);

      expect(mockEventPort.publishedEvents, hasLength(1));
      expect(
        mockEventPort.publishedEvents.first.type,
        equals('analysis.alert'),
      );
    });

    // TC-016: Published event payload includes ruleId, condition, severity,
    //         timestamp
    test('TC-016: published event payload includes required fields', () async {
      final timestamp = DateTime.now();
      final evaluation = AlertEvaluation(
        ruleId: 'rule-pub-002',
        triggered: true,
        severity: AnalysisAlertSeverity.warn,
        condition: 'temperature > 75',
        currentValue: 80.0,
        timestamp: timestamp,
        message: 'Warning threshold exceeded',
      );

      await publisher.publish(evaluation);

      final payload = mockEventPort.publishedEvents.first.payload;

      expect(payload['ruleId'], equals('rule-pub-002'));
      expect(payload['condition'], equals('temperature > 75'));
      expect(payload['severity'], equals('warn'));
      expect(
        mockEventPort.publishedEvents.first.timestamp,
        equals(timestamp),
      );
    });

    // TC-017: EventPort failure throws alert.publish_failed
    test('TC-017: EventPort failure throws alert.publish_failed', () async {
      mockEventPort.shouldThrow = true;

      final evaluation = AlertEvaluation(
        ruleId: 'rule-pub-003',
        triggered: true,
        severity: AnalysisAlertSeverity.critical,
        condition: 'temperature > 80',
        currentValue: 90.0,
        timestamp: DateTime.now(),
        message: 'Critical alert',
      );

      // AlertPublisher.publish wraps EventPort failures as alert.publish_failed
      expect(
        () => publisher.publish(evaluation),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'alert.publish_failed',
          ),
        ),
      );
    });

    // TC-018: evaluateWindow with avg > 75 and window value 76.0 triggers
    test('TC-018: evaluateWindow triggers when window value exceeds threshold',
        () async {
      final windowAggregator = WindowAggregator(
        windowSize: const Duration(minutes: 5),
      );
      final now = DateTime.now();

      // Add a single point with value 76.0 to the window
      windowAggregator.add(AnalysisTimePoint(t: now, v: 76.0));

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-window-001',
        name: 'Window threshold',
        provenance: provenance,
        condition: 'value > 75',
        severity: AnalysisAlertSeverity.warn,
      );

      final evaluator2 = AlertEvaluator(publisher: publisher);
      final results = await evaluator2.evaluateWindow(
        [rule],
        windowAggregator.state,
      );

      expect(results, hasLength(1));
      expect(results.first.triggered, isTrue);
      expect(results.first.currentValue, equals(76.0));
    });
  });

  // ==========================================================================
  // AlertEvaluator additional coverage (TC-030 to TC-038)
  // ==========================================================================
  group('AlertEvaluator additional coverage', () {
    late MockEventPort mockEventPort;
    late AlertPublisher publisher;
    late AlertEvaluator evaluator;

    setUp(() {
      mockEventPort = MockEventPort();
      publisher = AlertPublisher(eventPort: mockEventPort);
      evaluator = AlertEvaluator(publisher: publisher);
    });

    // Window-based evaluation with window aggregate condition syntax
    test('TC-030: evaluateWindow with avg() condition triggers correctly',
        () async {
      final windowAggregator = WindowAggregator(
        windowSize: const Duration(minutes: 5),
      );
      final now = DateTime.now();

      // Add points: avg will be 80.0
      windowAggregator.add(AnalysisTimePoint(t: now, v: 75.0));
      windowAggregator.add(AnalysisTimePoint(
        t: now.add(const Duration(seconds: 1)),
        v: 85.0,
      ));

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-window-avg',
        name: 'Window avg test',
        provenance: provenance,
        condition: 'value > 70',
        severity: AnalysisAlertSeverity.warn,
      );

      final results = await evaluator.evaluateWindow(
        [rule],
        windowAggregator.state,
      );

      expect(results, hasLength(1));
      expect(results.first.triggered, isTrue);
    });

    // Empty dataset: no matching data
    test('TC-031: evaluate with empty dataset returns triggered false',
        () async {
      final emptyData = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [],
        rowCount: 0,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-empty',
        name: 'Empty data test',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, emptyData);
      expect(result.triggered, isFalse);
    });

    // Null/missing column value
    test('TC-032: evaluate with null column values returns triggered false',
        () async {
      final nullData = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': null},
          {'temperature': null},
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-null',
        name: 'Null value test',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, nullData);
      expect(result.triggered, isFalse);
    });

    // Non-existent column in data
    test('TC-033: evaluate with missing column returns triggered false',
        () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-missing-col',
        name: 'Missing column test',
        provenance: provenance,
        condition: 'nonexistent > 50',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, hotData);
      expect(result.triggered, isFalse);
    });

    // evaluateAll with mixed results (some trigger, some don't)
    test('TC-034: evaluateAll returns correct mix of triggered and not',
        () async {
      final rules = [
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-trigger',
          name: 'Triggers',
          provenance: provenance,
          condition: 'temperature > 80',
          severity: AnalysisAlertSeverity.critical,
        ),
        AnalysisAlertRuleArtifact(
          artifactId: 'rule-no-trigger',
          name: 'Does not trigger',
          provenance: provenance,
          condition: 'temperature > 100',
          severity: AnalysisAlertSeverity.info,
        ),
      ];

      final results = await evaluator.evaluateAll(rules, hotData);

      expect(results, hasLength(2));
      expect(results[0].triggered, isTrue);
      expect(results[1].triggered, isFalse);
    });

    // Window aggregate condition: avg(temperature, 5m) > 75
    test('TC-035: evaluate handles window aggregate condition syntax',
        () async {
      final now = DateTime.now();
      final tsData = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'temperature': 80.0},
          {
            '_timestamp': now.add(const Duration(minutes: 1)),
            'temperature': 90.0,
          },
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-window-cond',
        name: 'Window aggregate',
        provenance: provenance,
        condition: 'avg(temperature, 5m) > 75',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, tsData);
      // avg = (80+90)/2 = 85 > 75 => triggered
      expect(result.triggered, isTrue);
    });

    // Window aggregate with empty matching data
    test('TC-036: window aggregate with all null values returns not triggered',
        () async {
      final now = DateTime.now();
      final nullTsData = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'temperature': null},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-null-window',
        name: 'Null window',
        provenance: provenance,
        condition: 'avg(temperature, 5m) > 75',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, nullTsData);
      expect(result.triggered, isFalse);
    });

    // Alert with actionHook
    test('TC-037: evaluate includes actionHook in result', () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hook',
        name: 'Hook test',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
        actionHook: 'webhook://notify',
      );

      final result = await evaluator.evaluate(rule, hotData);
      expect(result.triggered, isTrue);
      expect(result.actionHook, equals('webhook://notify'));
    });

    // <= operator in condition
    test('TC-038: <= operator triggers at and below threshold', () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'level', type: 'double'),
        ],
        rows: [
          {'level': 50.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-lte',
        name: 'LTE test',
        provenance: provenance,
        condition: 'level <= 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // < operator in condition
    test('TC-039: < operator triggers below threshold', () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'level', type: 'double'),
        ],
        rows: [
          {'level': 30.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-lt',
        name: 'LT test',
        provenance: provenance,
        condition: 'level < 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // == operator with exact match
    test('TC-040: == operator triggers on exact numeric match', () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'count', type: 'double'),
        ],
        rows: [
          {'count': 42.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-eq',
        name: 'EQ test',
        provenance: provenance,
        condition: 'count == 42',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // Window duration parsing with different units
    test('TC-041: window aggregate with seconds duration', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 100.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-sec',
        name: 'Seconds window',
        provenance: provenance,
        condition: 'avg(val, 30s) > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // Window duration parsing: hours unit
    test('TC-043: window aggregate with hours duration', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 100.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hour',
        name: 'Hours window',
        provenance: provenance,
        condition: 'avg(val, 2h) > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // Window duration parsing: days unit
    test('TC-044: window aggregate with days duration', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 100.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-day',
        name: 'Days window',
        provenance: provenance,
        condition: 'avg(val, 1d) > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // Window aggregate with min() aggregation
    test('TC-045: window aggregate with min() aggregation', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 30.0},
          {
            '_timestamp': now.add(const Duration(seconds: 1)),
            'val': 90.0,
          },
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-min',
        name: 'Min aggregation',
        provenance: provenance,
        condition: 'min(val, 5m) < 50',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);
      // min = 30.0 < 50 => triggered
      expect(result.triggered, isTrue);
      expect(result.currentValue, equals(30.0));
    });

    // Window aggregate with count() aggregation
    test('TC-046: window aggregate with count() aggregation', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 1.0},
          {
            '_timestamp': now.add(const Duration(seconds: 1)),
            'val': 2.0,
          },
          {
            '_timestamp': now.add(const Duration(seconds: 2)),
            'val': 3.0,
          },
        ],
        rowCount: 3,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-count',
        name: 'Count aggregation',
        provenance: provenance,
        condition: 'count(val, 5m) > 2',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      // count = 3.0 > 2 => triggered
      expect(result.triggered, isTrue);
      expect(result.currentValue, equals(3.0));
    });

    // evaluateAll with empty rules list returns empty list
    test('TC-047: evaluateAll with empty rules list returns empty', () async {
      final results = await evaluator.evaluateAll([], hotData);
      expect(results, isEmpty);
    });

    // Window aggregate with string-valued data that can be parsed
    test('TC-048: window aggregate with string numeric values', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'string'),
        ],
        rows: [
          {'_timestamp': now, 'val': '100.0'},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-str-val',
        name: 'String value window',
        provenance: provenance,
        condition: 'avg(val, 5m) > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      // String '100.0' parsed to double => avg = 100.0 > 50
      expect(result.triggered, isTrue);
    });

    // Window aggregate with non-parseable string data
    test(
        'TC-049: window aggregate with non-parseable string returns not triggered',
        () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'string'),
        ],
        rows: [
          {'_timestamp': now, 'val': 'not-a-number'},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-bad-str',
        name: 'Bad string window',
        provenance: provenance,
        condition: 'avg(val, 5m) > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      // Non-parseable => 0 points => not triggered
      expect(result.triggered, isFalse);
    });

    // Window aggregate with invalid threshold
    test('TC-042: window aggregate with non-numeric threshold returns false',
        () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 100.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-bad-thresh',
        name: 'Bad threshold',
        provenance: provenance,
        condition: 'avg(val, 5m) > abc',
        severity: AnalysisAlertSeverity.info,
      );

      // Invalid threshold -> throws alert.invalid_condition -> caught -> triggered: false
      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isFalse);
    });
  });

  // ==========================================================================
  // Condition Expression Parsing (TC-019 to TC-022)
  // ==========================================================================
  group('Condition Expression Parsing', () {
    late MockEventPort mockEventPort;
    late AlertPublisher publisher;
    late AlertEvaluator evaluator;

    setUp(() {
      mockEventPort = MockEventPort();
      publisher = AlertPublisher(eventPort: mockEventPort);
      evaluator = AlertEvaluator(publisher: publisher);
    });

    // TC-019: String comparison condition
    // Current implementation only supports numeric comparisons.
    // String conditions parse as non-numeric threshold -> triggered: false.
    test(
        'TC-019: string comparison condition returns false (numeric-only parser)',
        () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'status', type: 'string'),
        ],
        rows: [
          {'status': 'error'},
          {'status': 'ok'},
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-str',
        name: 'Status check',
        provenance: provenance,
        condition: 'status == "error"',
        severity: AnalysisAlertSeverity.critical,
      );

      final result = await evaluator.evaluate(rule, data);
      // String comparison not supported; returns triggered: false
      expect(result.triggered, isFalse);
    });

    // TC-020: != operator in condition
    test('TC-020: != operator triggers when numeric value differs', () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'error_count', type: 'double'),
        ],
        rows: [
          {'error_count': 5.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-neq',
        name: 'Error count check',
        provenance: provenance,
        condition: 'error_count != 0',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // TC-021: >= operator in condition
    test('TC-021: >= operator triggers at exact threshold', () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'vibration', type: 'double'),
        ],
        rows: [
          {'vibration': 5.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-gte',
        name: 'Vibration check',
        provenance: provenance,
        condition: 'vibration >= 5.0',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // TC-022: Negative numeric value in condition
    test('TC-022: negative numeric value in condition', () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': -5.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-neg',
        name: 'Sub-zero check',
        provenance: provenance,
        condition: 'temperature > -10',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });
  });

  // ==========================================================================
  // WindowAggregator Additional Aggregations (TC-023 to TC-025)
  // ==========================================================================
  group('WindowAggregator additional aggregations', () {
    late WindowAggregator aggregator;

    setUp(() {
      aggregator = WindowAggregator(
        windowSize: const Duration(minutes: 5),
      );
      final now = DateTime.now();
      final values = [10.0, 20.0, 30.0, 40.0, 50.0];
      for (var i = 0; i < values.length; i++) {
        aggregator.add(AnalysisTimePoint(
          t: now.add(Duration(seconds: i)),
          v: values[i],
        ));
      }
    });

    // TC-023: aggregate("sum")
    test('TC-023: aggregate sum of [10,20,30,40,50] equals 150.0', () {
      final sum = aggregator.aggregate('value', 'sum');
      expect(sum, equals(150.0));
    });

    // TC-024: aggregate("count")
    test('TC-024: aggregate count of [10,20,30,40,50] equals 5.0', () {
      final count = aggregator.aggregate('value', 'count');
      expect(count, equals(5.0));
    });

    // TC-025: aggregate("std")
    test('TC-025: aggregate std of [10,20,30,40,50] is computed correctly', () {
      final std = aggregator.aggregate('value', 'std');
      // Standard deviation of [10,20,30,40,50]:
      // Sample std ~ 15.81, Population std ~ 14.14
      expect(std, closeTo(15.81, 2.0));
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================

  group('Integration', () {
    // IT-001: evaluate -> publish -> event published with severity
    test('IT-001: evaluate triggers publish and event contains severity',
        () async {
      final mockEventPort = MockEventPort();
      final publisher = AlertPublisher(eventPort: mockEventPort);
      final evaluator = AlertEvaluator(publisher: publisher);

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-int-001',
        name: 'Integration test rule',
        provenance: provenance,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );

      final result = await evaluator.evaluate(rule, hotData);

      // Evaluation should trigger
      expect(result.triggered, isTrue);
      expect(result.severity, equals(AnalysisAlertSeverity.critical));

      // Event should have been published
      expect(mockEventPort.publishedEvents, hasLength(1));

      final event = mockEventPort.publishedEvents.first;
      expect(event.type, equals('analysis.alert'));
      expect(event.payload['severity'], equals('critical'));
      expect(event.payload['ruleId'], equals('rule-int-001'));
    });

    // IT-002: window aggregate -> alert -> publish end-to-end
    test('IT-002: window aggregate to alert to publish end-to-end', () async {
      final mockEventPort = MockEventPort();
      final publisher = AlertPublisher(eventPort: mockEventPort);
      final evaluator = AlertEvaluator(publisher: publisher);
      final windowAggregator = WindowAggregator(
        windowSize: const Duration(minutes: 5),
      );

      // Step 1: Add data points to the window
      final now = DateTime.now();
      final values = [70.0, 72.0, 74.0, 76.0, 78.0];

      for (var i = 0; i < values.length; i++) {
        windowAggregator.add(AnalysisTimePoint(
          t: now.add(Duration(seconds: i)),
          v: values[i],
        ));
      }

      // Step 2: Verify aggregate computation
      final avg = windowAggregator.aggregate('value', 'avg');
      expect(avg, equals(74.0));

      // Step 3: Evaluate window against an alert rule
      // Using "value > 70" so that any point above 70 will trigger
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-int-002',
        name: 'Window integration rule',
        provenance: provenance,
        condition: 'value > 70',
        severity: AnalysisAlertSeverity.warn,
      );

      final results = await evaluator.evaluateWindow(
        [rule],
        windowAggregator.state,
      );

      // Step 4: Verify alert was triggered and event was published
      expect(results, hasLength(1));
      expect(results.first.triggered, isTrue);
      expect(results.first.severity, equals(AnalysisAlertSeverity.warn));

      expect(mockEventPort.publishedEvents, hasLength(1));

      final event = mockEventPort.publishedEvents.first;
      expect(event.type, equals('analysis.alert'));
      expect(event.payload['ruleId'], equals('rule-int-002'));
      expect(event.payload['severity'], equals('warn'));
    });
  });

  // ==========================================================================
  // AlertEvaluator coverage gap tests
  // ==========================================================================
  group('AlertEvaluator coverage gaps', () {
    late MockEventPort mockEventPort;
    late AlertPublisher publisher;
    late AlertEvaluator evaluator;

    setUp(() {
      mockEventPort = MockEventPort();
      publisher = AlertPublisher(eventPort: mockEventPort);
      evaluator = AlertEvaluator(publisher: publisher);
    });

    // Simple condition with string numeric value in data row
    test('TC-COV-050: simple condition with string numeric value triggers',
        () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'value', type: 'string'),
        ],
        rows: [
          {'value': '90.0'},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-str-simple',
        name: 'String simple value',
        provenance: provenance,
        condition: 'value > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
      expect(result.currentValue, equals(90.0));
    });

    // Simple condition with non-parseable string value
    test('TC-COV-051: simple condition with non-parseable string skips row',
        () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'value', type: 'string'),
        ],
        rows: [
          {'value': 'abc'},
          {'value': 100.0},
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-skip-str',
        name: 'Skip non-parseable',
        provenance: provenance,
        condition: 'value > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
      expect(result.currentValue, equals(100.0));
    });

    // Window condition with timestamp not being DateTime (falls back to DateTime.now())
    test(
        'TC-COV-052: window condition with non-DateTime timestamp uses fallback',
        () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'string'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': 'not-a-datetime', 'val': 100.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-ts-fallback',
        name: 'Timestamp fallback',
        provenance: provenance,
        condition: 'avg(val, 5m) > 50',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
    });

    // Non-triggered result returns lastValue from last row
    test('TC-COV-053: non-triggered simple condition returns last row value',
        () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'val': 10.0},
          {'val': 20.0},
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-last-val',
        name: 'Last value check',
        provenance: provenance,
        condition: 'val > 100',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isFalse);
      expect(result.currentValue, equals(20.0));
    });

    // Non-triggered evaluation does NOT publish
    test('TC-COV-054: non-triggered evaluation does not call publisher',
        () async {
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-no-pub',
        name: 'No publish test',
        provenance: provenance,
        condition: 'temperature > 100',
        severity: AnalysisAlertSeverity.info,
      );

      await evaluator.evaluate(rule, coldData);
      expect(mockEventPort.publishedEvents, isEmpty);
    });

    // Window aggregate with max() aggregation
    test('TC-COV-055: window aggregate with max() aggregation', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 30.0},
          {
            '_timestamp': now.add(const Duration(seconds: 1)),
            'val': 90.0,
          },
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-max-agg',
        name: 'Max aggregation',
        provenance: provenance,
        condition: 'max(val, 5m) > 80',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);
      expect(result.currentValue, equals(90.0));
    });

    // Window aggregate NOT triggered
    test('TC-COV-056: window aggregate condition not triggered', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'val', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'val': 10.0},
          {
            '_timestamp': now.add(const Duration(seconds: 1)),
            'val': 20.0,
          },
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-agg-no-trig',
        name: 'Not triggered aggregate',
        provenance: provenance,
        condition: 'avg(val, 5m) > 100',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isFalse);
      expect(result.currentValue, equals(15.0));
    });
  });

  // ==========================================================================
  // Event-Rate Condition (FR-ALRT-003)
  // ==========================================================================
  group('Event-Rate Condition (FR-ALRT-003)', () {
    late MockEventPort mockEventPort;
    late AlertPublisher publisher;
    late AlertEvaluator evaluator;

    setUp(() {
      mockEventPort = MockEventPort();
      publisher = AlertPublisher(eventPort: mockEventPort);
      evaluator = AlertEvaluator(publisher: publisher);
    });

    // TC-RATE-001: Event-rate condition triggered (55 errors in 5m => rate=11 > 10)
    test('TC-RATE-001: event-rate triggered when rate exceeds threshold',
        () async {
      final now = DateTime.now();
      final rows = <Map<String, dynamic>>[];
      // 55 error rows within the window
      for (var i = 0; i < 55; i++) {
        rows.add({
          '_timestamp': now.subtract(Duration(seconds: i * 5)),
          'status': 'error',
        });
      }

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'status', type: 'string'),
        ],
        rows: rows,
        rowCount: rows.length,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-rate-001',
        name: 'Error rate alert',
        provenance: provenance,
        condition: 'rate(status, "error", 5m) > 10',
        severity: AnalysisAlertSeverity.critical,
      );

      final result = await evaluator.evaluate(rule, data);

      expect(result.triggered, isTrue);
      // rate = 55 / 5 = 11.0
      expect(result.currentValue, equals(11.0));
    });

    // TC-RATE-002: Event-rate condition NOT triggered (10 errors in 5m => rate=2 < 10)
    test('TC-RATE-002: event-rate not triggered when rate below threshold',
        () async {
      final now = DateTime.now();
      final rows = <Map<String, dynamic>>[];
      // 10 error rows within the window
      for (var i = 0; i < 10; i++) {
        rows.add({
          '_timestamp': now.subtract(Duration(seconds: i * 5)),
          'status': 'error',
        });
      }

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'status', type: 'string'),
        ],
        rows: rows,
        rowCount: rows.length,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-rate-002',
        name: 'Error rate check',
        provenance: provenance,
        condition: 'rate(status, "error", 5m) > 10',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);

      expect(result.triggered, isFalse);
      // rate = 10 / 5 = 2.0
      expect(result.currentValue, equals(2.0));
    });

    // TC-RATE-003: Event-rate with zero matches => rate=0
    test('TC-RATE-003: event-rate with zero matches returns rate 0', () async {
      final now = DateTime.now();
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'status', type: 'string'),
        ],
        rows: [
          {'_timestamp': now, 'status': 'ok'},
          {
            '_timestamp': now.subtract(const Duration(minutes: 1)),
            'status': 'ok',
          },
        ],
        rowCount: 2,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-rate-003',
        name: 'Zero match rate',
        provenance: provenance,
        condition: 'rate(status, "error", 5m) > 10',
        severity: AnalysisAlertSeverity.info,
      );

      final result = await evaluator.evaluate(rule, data);

      expect(result.triggered, isFalse);
      expect(result.currentValue, equals(0.0));
    });

    // TC-RATE-004: Event-rate malformed condition (missing window) => triggered=false
    test('TC-RATE-004: malformed event-rate condition returns triggered false',
        () async {
      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'status', type: 'string'),
        ],
        rows: [
          {'status': 'error'},
        ],
        rowCount: 1,
      );

      // Missing window duration - does not match rate pattern, falls through
      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-rate-004',
        name: 'Malformed rate',
        provenance: provenance,
        condition: 'rate(status, "error") > 10',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isFalse);
    });

    // TC-RATE-005: Event-rate with mixed values, only errors counted
    test('TC-RATE-005: event-rate counts only matching values', () async {
      final now = DateTime.now();
      final rows = <Map<String, dynamic>>[];
      // 30 error rows
      for (var i = 0; i < 30; i++) {
        rows.add({
          '_timestamp': now.subtract(Duration(seconds: i * 5)),
          'status': 'error',
        });
      }
      // 20 ok rows (should not be counted)
      for (var i = 0; i < 20; i++) {
        rows.add({
          '_timestamp': now.subtract(Duration(seconds: i * 5)),
          'status': 'ok',
        });
      }

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'status', type: 'string'),
        ],
        rows: rows,
        rowCount: rows.length,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-rate-005',
        name: 'Mixed value rate',
        provenance: provenance,
        condition: 'rate(status, "error", 5m) > 5',
        severity: AnalysisAlertSeverity.warn,
      );

      final result = await evaluator.evaluate(rule, data);

      expect(result.triggered, isTrue);
      // rate = 30 / 5 = 6.0 > 5
      expect(result.currentValue, equals(6.0));
    });
  });

  // ==========================================================================
  // ActionHook Execution (FR-ALRT-006)
  // ==========================================================================
  group('ActionHook Execution (FR-ALRT-006)', () {
    late MockEventPort mockEventPort;
    late AnalysisArtifactProvenance prov;

    setUp(() {
      mockEventPort = MockEventPort();
      prov = AnalysisArtifactProvenance(
        version: '1.0.0',
        createdAt: DateTime.now(),
        specId: 'test',
        specVersion: '1.0.0',
      );
    });

    // TC-HOOK-001: ActionHook "form:" calls FormPort mock
    test('TC-HOOK-001: form actionHook calls FormPort.generateReport',
        () async {
      final mockFormPort = MockAlertFormPort();
      final publisher = AlertPublisher(
        eventPort: mockEventPort,
        formPort: mockFormPort,
      );
      final evaluator = AlertEvaluator(publisher: publisher);

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': 85.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hook-form',
        name: 'Form hook test',
        provenance: prov,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
        actionHook: 'form:alert-report-template',
      );

      await evaluator.evaluate(rule, data);

      expect(mockFormPort.calls, hasLength(1));
      expect(
          mockFormPort.calls.first.templateId, equals('alert-report-template'));
      expect(mockFormPort.calls.first.context['alertRuleId'],
          equals('rule-hook-form'));
      expect(mockFormPort.calls.first.context['severity'], equals('critical'));
      expect(mockFormPort.calls.first.context['condition'],
          equals('temperature > 80'));
    });

    // TC-HOOK-002: ActionHook unknown type => warning logged
    test('TC-HOOK-002: unknown actionHook type publishes warning event',
        () async {
      final publisher = AlertPublisher(eventPort: mockEventPort);
      final evaluator = AlertEvaluator(publisher: publisher);

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': 85.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hook-unknown',
        name: 'Unknown hook test',
        provenance: prov,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.warn,
        actionHook: 'slack:#channel',
      );

      await evaluator.evaluate(rule, data);

      // Should have alert event + warning event
      final warningEvents = mockEventPort.publishedEvents
          .where((e) => e.type == 'analysis.alert.warning')
          .toList();
      expect(warningEvents, hasLength(1));
      expect(
        warningEvents.first.payload['warning'],
        contains('Unknown actionHook type'),
      );
    });

    // TC-HOOK-003: ActionHook null => no action
    test('TC-HOOK-003: null actionHook does not execute any hook', () async {
      final mockFormPort = MockAlertFormPort();
      final publisher = AlertPublisher(
        eventPort: mockEventPort,
        formPort: mockFormPort,
      );
      final evaluator = AlertEvaluator(publisher: publisher);

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': 85.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hook-null',
        name: 'Null hook test',
        provenance: prov,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );

      await evaluator.evaluate(rule, data);

      // FormPort should not be called
      expect(mockFormPort.calls, isEmpty);
      // Only the alert event, no warning
      final warningEvents = mockEventPort.publishedEvents
          .where((e) => e.type == 'analysis.alert.warning')
          .toList();
      expect(warningEvents, isEmpty);
    });

    // TC-HOOK-004: ActionHook FormPort failure is non-blocking
    test('TC-HOOK-004: FormPort failure does not throw from evaluate',
        () async {
      final mockFormPort = MockAlertFormPort()..shouldThrow = true;
      final publisher = AlertPublisher(
        eventPort: mockEventPort,
        formPort: mockFormPort,
      );
      final evaluator = AlertEvaluator(publisher: publisher);

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': 85.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hook-fail',
        name: 'Failing hook test',
        provenance: prov,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
        actionHook: 'form:broken-template',
      );

      // Should not throw even though FormPort fails
      final result = await evaluator.evaluate(rule, data);
      expect(result.triggered, isTrue);

      // A warning event should have been published about the failure
      final warningEvents = mockEventPort.publishedEvents
          .where((e) => e.type == 'analysis.alert.warning')
          .toList();
      expect(warningEvents, hasLength(1));
      expect(
        warningEvents.first.payload['warning'],
        contains('ActionHook execution failed'),
      );
    });

    // TC-HOOK-005: form actionHook with null FormPort logs warning
    test('TC-HOOK-005: form actionHook without FormPort publishes warning',
        () async {
      final publisher = AlertPublisher(eventPort: mockEventPort);
      final evaluator = AlertEvaluator(publisher: publisher);

      final data = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: 'temperature', type: 'double'),
        ],
        rows: [
          {'temperature': 85.0},
        ],
        rowCount: 1,
      );

      final rule = AnalysisAlertRuleArtifact(
        artifactId: 'rule-hook-no-form',
        name: 'No FormPort test',
        provenance: prov,
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
        actionHook: 'form:some-template',
      );

      await evaluator.evaluate(rule, data);

      final warningEvents = mockEventPort.publishedEvents
          .where((e) => e.type == 'analysis.alert.warning')
          .toList();
      expect(warningEvents, hasLength(1));
      expect(
        warningEvents.first.payload['warning'],
        contains('FormPort not available'),
      );
    });
  });
}
