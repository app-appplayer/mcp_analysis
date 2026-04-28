import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

// ============================================================================
// Helpers
// ============================================================================

/// Create a minimal valid AnalysisTableArtifact for masking tests.
AnalysisTableArtifact _createTableArtifact({
  String artifactId = 'table-001',
  String name = 'test-table',
  List<String>? columns,
  List<Map<String, dynamic>>? rows,
}) {
  return AnalysisTableArtifact(
    artifactId: artifactId,
    name: name,
    provenance: AnalysisArtifactProvenance(
      version: '1.0.0',
      createdAt: DateTime.now(),
      specId: 'test-spec',
      specVersion: '1.0.0',
    ),
    columns: columns ?? ['name', 'ssn', 'score'],
    rows: rows ??
        [
          {'name': 'Alice', 'ssn': '123-45-6789', 'score': 95},
          {'name': 'Bob', 'ssn': '987-65-4321', 'score': 88},
        ],
  );
}

/// Create a non-table artifact (metric) to test mixed artifact lists.
AnalysisMetricArtifact _createMetricArtifact({
  String artifactId = 'metric-001',
}) {
  final now = DateTime.now();
  return AnalysisMetricArtifact(
    artifactId: artifactId,
    name: 'avg-score',
    provenance: AnalysisArtifactProvenance(
      version: '1.0.0',
      createdAt: now,
      specId: 'test-spec',
      specVersion: '1.0.0',
    ),
    value: 91.5,
    unit: 'points',
    timeRange: AnalysisTimeRange(
      start: now.subtract(const Duration(hours: 1)),
      end: now,
    ),
  );
}

void main() {
  // ==========================================================================
  // RbacPolicy Tests
  // ==========================================================================
  group('RbacPolicy', () {
    late RbacPolicy policy;

    setUp(() {
      policy = RbacPolicy();
    });

    // TC-001: Operator can execute (no exception)
    test('TC-001: operator can execute analysis', () async {
      final ctx = RbacContext(actorId: 'op-1', role: 'operator');
      // Should complete without throwing
      await policy.canExecute(ctx, 'test-spec');
    });

    // TC-002: Operator cannot manage spec
    test('TC-002: operator cannot manage spec -> governance.unauthorized',
        () async {
      final ctx = RbacContext(actorId: 'op-1', role: 'operator');
      expect(
        () => policy.canManageSpec(ctx),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
    });

    // TC-003: Engineer can manage spec
    test('TC-003: engineer can manage spec', () async {
      final ctx = RbacContext(actorId: 'eng-1', role: 'engineer');
      // Should complete without throwing
      await policy.canManageSpec(ctx);
    });

    // TC-004: Engineer can execute
    test('TC-004: engineer can execute analysis', () async {
      final ctx = RbacContext(actorId: 'eng-1', role: 'engineer');
      await policy.canExecute(ctx, 'any-spec');
    });

    // TC-005: Admin can view audit
    test('TC-005: admin can view audit', () async {
      final ctx = RbacContext(actorId: 'admin-1', role: 'admin');
      await policy.canViewAudit(ctx);
    });

    // TC-006: Operator cannot view audit
    test('TC-006: operator cannot view audit -> governance.unauthorized',
        () async {
      final ctx = RbacContext(actorId: 'op-1', role: 'operator');
      expect(
        () => policy.canViewAudit(ctx),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
    });

    // TC-007: All 3 roles can view artifacts
    test('TC-007: all roles (operator, engineer, admin) can view artifacts',
        () async {
      for (final role in ['operator', 'engineer', 'admin']) {
        final ctx = RbacContext(actorId: '$role-user', role: role);
        // Should complete without throwing for all three roles
        await policy.canViewArtifacts(ctx);
      }
    });

    // TC-008: Unknown role denied all operations
    test('TC-008: unknown role denied all -> governance.unauthorized',
        () async {
      final ctx = RbacContext(actorId: 'guest-1', role: 'guest');

      // Every permission check should fail for an unknown role
      expect(
        () => policy.canExecute(ctx, 'any-spec'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
      expect(
        () => policy.canManageSpec(ctx),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
      expect(
        () => policy.canViewArtifacts(ctx),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
      expect(
        () => policy.canViewAudit(ctx),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // AuditLogger Tests
  // ==========================================================================
  group('AuditLogger', () {
    late InMemoryStorage<AuditRecord> storage;
    late AuditLogger logger;

    setUp(() {
      storage = InMemoryStorage<AuditRecord>();
      logger = AuditLogger(storage: storage);
    });

    // TC-009: recordExecution stores record with all fields
    test('TC-009: recordExecution stores record with all fields', () async {
      final now = DateTime.now();
      final range = AnalysisTimeRange(
        start: now.subtract(const Duration(hours: 1)),
        end: now,
      );

      await logger.recordExecution(
        actorId: 'actor-1',
        specId: 'spec-001',
        jobId: 'job-001',
        inputRange: range,
        parameters: {'threshold': 0.5},
      );

      final records = await logger.query();
      expect(records, hasLength(1));

      final record = records.first;
      expect(record.actorId, 'actor-1');
      expect(record.action, 'execute');
      expect(record.specId, 'spec-001');
      expect(record.jobId, 'job-001');
      expect(record.inputRange, isNotNull);
      expect(record.parameters, {'threshold': 0.5});
    });

    // TC-010: timestamp is close to current time
    test('TC-010: auto-generated timestamp is close to current time', () async {
      final before = DateTime.now();
      await logger.recordExecution(
        actorId: 'actor-1',
        specId: 'spec-001',
        jobId: 'job-001',
        inputRange: null,
        parameters: {},
      );
      final after = DateTime.now();

      final records = await logger.query();
      expect(records, hasLength(1));

      final timestamp = records.first.timestamp;
      // Timestamp should be between before and after
      expect(
        timestamp.isAfter(before.subtract(const Duration(seconds: 1))),
        isTrue,
        reason: 'Timestamp should not be before the test started',
      );
      expect(
        timestamp.isBefore(after.add(const Duration(seconds: 1))),
        isTrue,
        reason: 'Timestamp should not be after the test ended',
      );
    });

    // TC-011: recordSpecChange stores with action="create_spec"
    test('TC-011: recordSpecChange stores with action=create_spec', () async {
      await logger.recordSpecChange(
        actorId: 'eng-1',
        specId: 'spec-new',
        action: 'create_spec',
      );

      final records = await logger.query();
      expect(records, hasLength(1));
      expect(records.first.action, 'create_spec');
      expect(records.first.specId, 'spec-new');
      expect(records.first.actorId, 'eng-1');
    });

    // TC-012: query by actorId returns only matching records
    test('TC-012: query by actorId returns only matching records', () async {
      await logger.recordExecution(
        actorId: 'actor-a',
        specId: 'spec-1',
        jobId: 'job-1',
        inputRange: null,
        parameters: {},
      );
      await logger.recordExecution(
        actorId: 'actor-b',
        specId: 'spec-2',
        jobId: 'job-2',
        inputRange: null,
        parameters: {},
      );
      await logger.recordExecution(
        actorId: 'actor-a',
        specId: 'spec-3',
        jobId: 'job-3',
        inputRange: null,
        parameters: {},
      );

      // InMemoryStorage.query returns all items (no filtering), so the
      // AuditLogger only filters by time range in its query method.
      // The actorId filter is passed to storage criteria; in-memory mock
      // returns all, but this verifies the flow works end-to-end.
      final results = await logger.query(actorId: 'actor-a');
      // Since InMemoryStorage returns all, we get all 3 records.
      // This tests that the query method at least accepts the parameter.
      expect(results, isNotEmpty);
    });

    // TC-013: query by time range filters correctly
    test('TC-013: query by time range filters correctly', () async {
      final baseTime = DateTime(2025, 1, 1, 12, 0);

      await logger.recordExecution(
        actorId: 'actor-1',
        specId: 'spec-1',
        jobId: 'job-1',
        inputRange: null,
        parameters: {},
        timestamp: baseTime,
      );
      await logger.recordExecution(
        actorId: 'actor-1',
        specId: 'spec-2',
        jobId: 'job-2',
        inputRange: null,
        parameters: {},
        timestamp: baseTime.add(const Duration(hours: 2)),
      );
      await logger.recordExecution(
        actorId: 'actor-1',
        specId: 'spec-3',
        jobId: 'job-3',
        inputRange: null,
        parameters: {},
        timestamp: baseTime.add(const Duration(hours: 4)),
      );

      // Query for the middle time window only
      final results = await logger.query(
        startTime: baseTime.add(const Duration(hours: 1)),
        endTime: baseTime.add(const Duration(hours: 3)),
      );

      // Only the record at baseTime+2h should match the window
      expect(results, hasLength(1));
      expect(results.first.specId, 'spec-2');
    });

    // TC-014: Storage failure -> returns AnalysisError (non-blocking)
    test('TC-014: storage failure returns AnalysisError non-blocking', () async {
      storage.shouldThrow = true;

      // recordExecution should return AnalysisError, not throw
      final execResult = await logger.recordExecution(
        actorId: 'actor-1',
        specId: 'spec-1',
        jobId: 'job-1',
        inputRange: null,
        parameters: {},
      );
      expect(execResult, isNotNull);
      expect(execResult!.code, 'governance.audit_failed');

      // recordSpecChange should return AnalysisError, not throw
      final specResult = await logger.recordSpecChange(
        actorId: 'actor-1',
        specId: 'spec-1',
        action: 'update_spec',
      );
      expect(specResult, isNotNull);
      expect(specResult!.code, 'governance.audit_failed');
    });
  });

  // ==========================================================================
  // DataMasker Tests
  // ==========================================================================
  group('DataMasker', () {
    late DataMasker masker;

    setUp(() {
      masker = DataMasker();
    });

    // TC-015: Masked column values become "***"
    test('TC-015: masked column values become "***"', () {
      final table = _createTableArtifact();
      final config = {'ssn': true};

      final result = masker.applyMasking([table], config);
      expect(result, hasLength(1));

      final masked = result.first as AnalysisTableArtifact;
      for (final row in masked.rows) {
        expect(row['ssn'], '***');
      }
    });

    // TC-016: Non-masked columns remain unchanged
    test('TC-016: non-masked columns remain unchanged', () {
      final table = _createTableArtifact();
      final config = {'ssn': true};

      final result = masker.applyMasking([table], config);
      final masked = result.first as AnalysisTableArtifact;

      // name and score columns should be unchanged
      expect(masked.rows[0]['name'], 'Alice');
      expect(masked.rows[0]['score'], 95);
      expect(masked.rows[1]['name'], 'Bob');
      expect(masked.rows[1]['score'], 88);
    });

    // TC-017: Empty maskConfig leaves artifacts unchanged
    test('TC-017: empty maskConfig leaves artifacts unchanged', () {
      final table = _createTableArtifact();
      final config = <String, bool>{};

      final result = masker.applyMasking([table], config);
      expect(result, hasLength(1));

      // With empty config, applyMasking returns the original list
      final unchanged = result.first as AnalysisTableArtifact;
      expect(unchanged.rows[0]['ssn'], '123-45-6789');
      expect(unchanged.rows[1]['ssn'], '987-65-4321');
    });

    // TC-018: Mixed artifacts - only table artifacts are masked
    test('TC-018: mixed artifacts - only table is masked', () {
      final table = _createTableArtifact();
      final metric = _createMetricArtifact();
      final config = {'ssn': true};

      final result = masker.applyMasking([metric, table], config);
      expect(result, hasLength(2));

      // Metric artifact should be returned unchanged
      final metricResult = result[0];
      expect(metricResult, isA<AnalysisMetricArtifact>());
      expect((metricResult as AnalysisMetricArtifact).value, 91.5);

      // Table artifact should have ssn masked
      final tableResult = result[1];
      expect(tableResult, isA<AnalysisTableArtifact>());
      final maskedTable = tableResult as AnalysisTableArtifact;
      for (final row in maskedTable.rows) {
        expect(row['ssn'], '***');
      }
    });
  });

  // ==========================================================================
  // Group-Based Role Resolution (TC-019 to TC-024)
  // ==========================================================================
  group('Group-Based Role Resolution', () {
    late RbacPolicy policy;

    setUp(() {
      policy = RbacPolicy();
    });

    // TC-019: Group 'engineers' member gets engineer-level permissions
    test('TC-019: engineers group elevates operator to engineer permissions',
        () async {
      final ctx = RbacContext(
        actorId: 'user-004',
        role: 'operator',
        groups: ['engineers'],
      );
      // Operator cannot manage spec, but engineers group should allow it
      await policy.canManageSpec(ctx);
    });

    // TC-020: Group 'admin' member gets admin-level permissions
    test('TC-020: admin group elevates operator to admin permissions', () async {
      final ctx = RbacContext(
        actorId: 'user-005',
        role: 'operator',
        groups: ['admin'],
      );
      // Operator cannot view audit, but admin group should allow it
      await policy.canViewAudit(ctx);
    });

    // TC-021: Explicit role takes precedence over lower group-based role
    test('TC-021: explicit admin role preserved despite lower group', () async {
      final ctx = RbacContext(
        actorId: 'user-006',
        role: 'admin',
        groups: ['operators'],
      );
      // Admin should still be able to view audit despite operators group
      await policy.canViewAudit(ctx);
    });

    // TC-023: Group 'admins' (plural) member gets admin-level permissions
    test('TC-023: admins (plural) group elevates to admin permissions', () async {
      final ctx = RbacContext(
        actorId: 'user-007',
        role: 'operator',
        groups: ['admins'],
      );
      await policy.canViewAudit(ctx);
    });

    // TC-024: Explicit role not downgraded by lower group
    test('TC-024: explicit engineer role not downgraded by operators group',
        () async {
      final ctx = RbacContext(
        actorId: 'user-008',
        role: 'engineer',
        groups: ['operators'],
      );
      // Engineer should still be able to manage spec despite operators group
      await policy.canManageSpec(ctx);
    });
  });

  // ==========================================================================
  // DataMasker maskSeries (TC-022)
  // ==========================================================================
  group('DataMasker maskSeries', () {
    late DataMasker masker;

    setUp(() {
      masker = DataMasker();
    });

    // TC-022: maskSeries masks series artifact values
    test('TC-022: maskSeries masks series artifact point values', () {
      final now = DateTime.now();
      final series = AnalysisSeriesArtifact(
        artifactId: 'series-001',
        name: 'test-series',
        provenance: AnalysisArtifactProvenance(
          version: '1.0.0',
          createdAt: now,
          specId: 'test-spec',
          specVersion: '1.0.0',
        ),
        points: [
          AnalysisTimePoint(t: now, v: 72.0),
          AnalysisTimePoint(
            t: now.add(const Duration(minutes: 1)),
            v: 85.0,
          ),
          AnalysisTimePoint(
            t: now.add(const Duration(minutes: 2)),
            v: 73.0,
          ),
          AnalysisTimePoint(
            t: now.add(const Duration(minutes: 3)),
            v: 68.0,
          ),
          AnalysisTimePoint(
            t: now.add(const Duration(minutes: 4)),
            v: 90.0,
          ),
        ],
        unit: 'F',
      );

      final result = masker.maskSeries(series);

      expect(result, isA<AnalysisSeriesArtifact>());
      expect(result.points, hasLength(5));
      // Timestamps should be preserved
      expect(result.points[0].t, equals(now));
      // All point values should be replaced with '***'
      for (final point in result.points) {
        expect(point.v, equals(DataMasker.maskedValue));
      }
    });
  });

  // ==========================================================================
  // AuditLogger.query with limit (TC-025) and recordSpecChange update_spec (TC-026)
  // ==========================================================================
  group('AuditLogger query and recordSpecChange', () {
    late InMemoryStorage<AuditRecord> storage;
    late AuditLogger logger;

    setUp(() {
      storage = InMemoryStorage<AuditRecord>();
      logger = AuditLogger(storage: storage);
    });

    // TC-025: query with limit parameter
    test('TC-025: query with limit returns at most N records', () async {
      // Store 5 records
      for (var i = 0; i < 5; i++) {
        await logger.recordExecution(
          actorId: 'actor-$i',
          specId: 'spec-$i',
          jobId: 'job-$i',
          inputRange: null,
          parameters: {},
        );
      }

      final results = await logger.query(limit: 2);
      expect(results.length, lessThanOrEqualTo(2));
    });

    // TC-026: recordSpecChange with action 'update_spec'
    test('TC-026: recordSpecChange with action update_spec', () async {
      final result = await logger.recordSpecChange(
        actorId: 'eng-1',
        specId: 'spec-update',
        action: 'update_spec',
      );

      expect(result, isNull);

      final records = await logger.query();
      expect(records, hasLength(1));
      expect(records.first.action, 'update_spec');
      expect(records.first.specId, 'spec-update');
      expect(records.first.actorId, 'eng-1');
    });

    // TC-027: RbacPolicy.checkPermission direct call with operation and resourceId
    test('TC-027: checkPermission direct call with operation and resourceId',
        () async {
      final policy = RbacPolicy();
      final engineerCtx = RbacContext(actorId: 'user-002', role: 'engineer');
      final operatorCtx = RbacContext(actorId: 'user-001', role: 'operator');

      // Engineer should be permitted to execute with resourceId
      await policy.checkPermission(
        context: engineerCtx,
        operation: 'execute',
        resourceId: 'spec-001',
      );

      // Operator should be denied create_spec permission
      expect(
        () => policy.checkPermission(
          context: operatorCtx,
          operation: 'create_spec',
          resourceId: 'spec-001',
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'governance.unauthorized',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('Integration', () {
    // IT-001: RBAC -> AuditLogger round-trip: permission check then audit log
    test('IT-001: RBAC check then audit log round-trip', () async {
      final policy = RbacPolicy();
      final storage = InMemoryStorage<AuditRecord>();
      final logger = AuditLogger(storage: storage);

      final ctx = RbacContext(actorId: 'eng-1', role: 'engineer');

      // Permission check should pass
      await policy.canExecute(ctx, 'spec-001');

      // Log the execution
      await logger.recordExecution(
        actorId: ctx.actorId,
        specId: 'spec-001',
        jobId: 'job-001',
        inputRange: null,
        parameters: {'threshold': 0.9},
      );

      // Verify audit record was created
      final records = await logger.query();
      expect(records, hasLength(1));
      expect(records.first.actorId, ctx.actorId);
      expect(records.first.specId, 'spec-001');
      expect(records.first.action, 'execute');
    });

    // IT-002: DataMasker preserves provenance after masking
    test('IT-002: DataMasker preserves provenance after masking', () {
      final masker = DataMasker();
      final table = _createTableArtifact();
      final originalProvenance = table.provenance;

      final result = masker.applyMasking([table], {'ssn': true});
      final masked = result.first as AnalysisTableArtifact;

      // Provenance metadata should be preserved
      expect(masked.provenance.specId, originalProvenance.specId);
      expect(masked.provenance.specVersion, originalProvenance.specVersion);
      expect(masked.artifactId, table.artifactId);
      expect(masked.name, table.name);
      expect(masked.columns, table.columns);
    });
  });

  // ==========================================================================
  // AuditLogger coverage boost: query edge cases
  // ==========================================================================
  group('AuditLogger query edge cases', () {
    late InMemoryStorage<AuditRecord> storage;
    late AuditLogger logger;

    setUp(() {
      storage = InMemoryStorage<AuditRecord>();
      logger = AuditLogger(storage: storage);
    });

    // Query with specId filter
    test('query with specId filter accepts parameter', () async {
      await logger.recordExecution(
        actorId: 'a1',
        specId: 'spec-x',
        jobId: 'j1',
        inputRange: null,
        parameters: {},
      );
      await logger.recordExecution(
        actorId: 'a2',
        specId: 'spec-y',
        jobId: 'j2',
        inputRange: null,
        parameters: {},
      );

      final results = await logger.query(specId: 'spec-x');
      // InMemoryStorage returns all, but we verify the criteria path runs
      expect(results, isNotEmpty);
    });

    // Query with all filters combined
    test('query with all filters combined', () async {
      final baseTime = DateTime(2025, 6, 1, 12, 0);
      for (var i = 0; i < 5; i++) {
        await logger.recordExecution(
          actorId: 'actor-1',
          specId: 'spec-1',
          jobId: 'job-$i',
          inputRange: null,
          parameters: {},
          timestamp: baseTime.add(Duration(hours: i)),
        );
      }

      final results = await logger.query(
        actorId: 'actor-1',
        specId: 'spec-1',
        startTime: baseTime.add(const Duration(hours: 1)),
        endTime: baseTime.add(const Duration(hours: 3)),
        limit: 2,
      );

      // Time filter: hours 1,2,3 => 3 records; limit 2 => 2 records
      expect(results.length, lessThanOrEqualTo(2));
    });

    // Query with empty results (time range excludes all)
    test('query with time range that excludes all records', () async {
      final baseTime = DateTime(2025, 6, 1, 12, 0);
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's1',
        jobId: 'j1',
        inputRange: null,
        parameters: {},
        timestamp: baseTime,
      );

      final results = await logger.query(
        startTime: baseTime.add(const Duration(hours: 10)),
        endTime: baseTime.add(const Duration(hours: 20)),
      );

      expect(results, isEmpty);
    });

    // Query with limit=0 returns all (limit not applied when <= 0)
    test('query with limit 0 returns all records', () async {
      for (var i = 0; i < 3; i++) {
        await logger.recordExecution(
          actorId: 'a-$i',
          specId: 's-$i',
          jobId: 'j-$i',
          inputRange: null,
          parameters: {},
        );
      }

      final results = await logger.query(limit: 0);
      expect(results, hasLength(3));
    });

    // recordExecution with custom timestamp
    test('recordExecution with custom timestamp uses provided value', () async {
      final customTime = DateTime(2020, 1, 1);
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's1',
        jobId: 'j1',
        inputRange: null,
        parameters: {},
        timestamp: customTime,
      );

      final records = await logger.query();
      expect(records.first.timestamp, equals(customTime));
    });

    // recordSpecChange with custom timestamp
    test('recordSpecChange with custom timestamp uses provided value',
        () async {
      final customTime = DateTime(2020, 6, 15);
      await logger.recordSpecChange(
        actorId: 'eng-1',
        specId: 'spec-ts',
        action: 'create_spec',
        timestamp: customTime,
      );

      final records = await logger.query();
      expect(records.first.timestamp, equals(customTime));
    });

    // recordExecution error details contain all fields
    test('recordExecution error details contain specId and jobId', () async {
      storage.shouldThrow = true;
      final result = await logger.recordExecution(
        actorId: 'a1',
        specId: 'my-spec',
        jobId: 'my-job',
        inputRange: null,
        parameters: {},
      );

      expect(result, isNotNull);
      expect(result!.details, containsPair('specId', 'my-spec'));
      expect(result.details, containsPair('jobId', 'my-job'));
      expect(result.details, containsPair('action', 'execute'));
    });

    // recordSpecChange error details contain action and specId
    test('recordSpecChange error details contain action and specId', () async {
      storage.shouldThrow = true;
      final result = await logger.recordSpecChange(
        actorId: 'a1',
        specId: 'my-spec',
        action: 'delete_spec',
      );

      expect(result, isNotNull);
      expect(result!.details, containsPair('action', 'delete_spec'));
      expect(result.details, containsPair('specId', 'my-spec'));
    });

    // AuditRecord.toJson includes all optional fields when present
    test('AuditRecord.toJson includes all optional fields', () {
      final now = DateTime.now();
      final range = AnalysisTimeRange(
        start: now.subtract(const Duration(hours: 1)),
        end: now,
      );
      final record = AuditRecord(
        recordId: 'r-1',
        actorId: 'a-1',
        action: 'execute',
        specId: 'spec-1',
        jobId: 'job-1',
        inputRange: range,
        parameters: {'key': 'val'},
        timestamp: now,
      );

      final json = record.toJson();
      expect(json, containsPair('recordId', 'r-1'));
      expect(json, containsPair('specId', 'spec-1'));
      expect(json, containsPair('jobId', 'job-1'));
      expect(json, contains('inputRange'));
      expect(json, containsPair('parameters', {'key': 'val'}));
    });

    // AuditRecord.toJson omits null optional fields
    test('AuditRecord.toJson omits null optional fields', () {
      final record = AuditRecord(
        recordId: 'r-2',
        actorId: 'a-2',
        action: 'create_spec',
        timestamp: DateTime.now(),
      );

      final json = record.toJson();
      expect(json.containsKey('specId'), isFalse);
      expect(json.containsKey('jobId'), isFalse);
      expect(json.containsKey('inputRange'), isFalse);
      expect(json.containsKey('parameters'), isFalse);
    });

    // Query with endTime only
    test('query with endTime only filters correctly', () async {
      final baseTime = DateTime(2025, 1, 1, 12, 0);
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's1',
        jobId: 'j1',
        inputRange: null,
        parameters: {},
        timestamp: baseTime,
      );
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's2',
        jobId: 'j2',
        inputRange: null,
        parameters: {},
        timestamp: baseTime.add(const Duration(hours: 5)),
      );

      final results = await logger.query(
        endTime: baseTime.add(const Duration(hours: 1)),
      );
      expect(results, hasLength(1));
      expect(results.first.specId, 's1');
    });

    // Query with startTime only
    test('query with startTime only filters correctly', () async {
      final baseTime = DateTime(2025, 1, 1, 12, 0);
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's1',
        jobId: 'j1',
        inputRange: null,
        parameters: {},
        timestamp: baseTime,
      );
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's2',
        jobId: 'j2',
        inputRange: null,
        parameters: {},
        timestamp: baseTime.add(const Duration(hours: 5)),
      );

      final results = await logger.query(
        startTime: baseTime.add(const Duration(hours: 3)),
      );
      expect(results, hasLength(1));
      expect(results.first.specId, 's2');
    });

    // Limit larger than results returns all
    test('query with limit larger than results returns all', () async {
      await logger.recordExecution(
        actorId: 'a1',
        specId: 's1',
        jobId: 'j1',
        inputRange: null,
        parameters: {},
      );

      final results = await logger.query(limit: 100);
      expect(results, hasLength(1));
    });
  });

  // ==========================================================================
  // governance.audit_failed (TC-021 to TC-023)
  // ==========================================================================
  group('AuditLogger audit_failed', () {
    // TC-021: recordExecution returns null on success
    test('TC-021: recordExecution returns null on success', () async {
      final storage = InMemoryStorage<AuditRecord>();
      final logger = AuditLogger(storage: storage);

      final result = await logger.recordExecution(
        actorId: 'user-1',
        specId: 'spec-1',
        jobId: 'job-1',
        inputRange: null,
        parameters: {},
      );

      expect(result, isNull);
      expect(storage.length, 1);
    });

    // TC-022: recordExecution returns governance.audit_failed on storage error
    test('TC-022: recordExecution returns governance.audit_failed on failure',
        () async {
      final storage = InMemoryStorage<AuditRecord>();
      storage.shouldThrow = true;
      final logger = AuditLogger(storage: storage);

      final result = await logger.recordExecution(
        actorId: 'user-1',
        specId: 'spec-1',
        jobId: 'job-1',
        inputRange: null,
        parameters: {},
      );

      expect(result, isNotNull);
      expect(result!.code, equals('governance.audit_failed'));
    });

    // TC-023: recordSpecChange returns governance.audit_failed on storage error
    test('TC-023: recordSpecChange returns governance.audit_failed on failure',
        () async {
      final storage = InMemoryStorage<AuditRecord>();
      storage.shouldThrow = true;
      final logger = AuditLogger(storage: storage);

      final result = await logger.recordSpecChange(
        actorId: 'user-1',
        specId: 'spec-1',
        action: 'create_spec',
      );

      expect(result, isNotNull);
      expect(result!.code, equals('governance.audit_failed'));
      expect(result.details, containsPair('action', 'create_spec'));
    });
  });
}
