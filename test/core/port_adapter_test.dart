import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';
import '../helpers/test_data.dart';

// ============================================================================
// Test Helpers
// ============================================================================

class _TestFixture {
  _TestFixture._({
    required this.specStorage,
    required this.jobStorage,
    required this.artifactStorage,
    required this.auditStorage,
    required this.specManager,
    required this.jobManager,
    required this.artifactStore,
    required this.dataSourceRegistry,
    required this.alertEvaluator,
    required this.adapter,
  });

  factory _TestFixture() {
    final specStorage = InMemoryStorage<AnalysisSpec>();
    final jobStorage = InMemoryStorage<AnalysisJob>();
    final artifactStorage = InMemoryStorage<AnalysisArtifact>();
    final auditStorage = InMemoryStorage<AuditRecord>();

    final specManager = SpecManager(
      storage: specStorage,
      validator: SpecValidator(),
      parameterResolver: ParameterResolver(),
    );
    final jobManager = JobManager(storage: jobStorage);
    final artifactStore = ArtifactStore(storage: artifactStorage);
    final dataSourceRegistry = DataSourceRegistry();
    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: MockEventPort()),
    );

    // Build a real ExecutionEngine with fake executors for the adapter
    final transformPipeline = TransformPipeline();
    final functionDispatcher = FunctionDispatcher(
      catalog: FunctionCatalog(),
    );
    final artifactBuilder = ArtifactBuilder();
    final provenanceTracker = ProvenanceTracker();
    final rbac = RbacPolicy();
    final auditLogger = AuditLogger(storage: auditStorage);
    final metricPort = MockMetricPort();

    final batchExecutor = BatchExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final adhocExecutor = AdhocExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final streamExecutor = StreamExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final executionEngine = ExecutionEngine(
      specManager: specManager,
      jobManager: jobManager,
      batchExecutor: batchExecutor,
      adhocExecutor: adhocExecutor,
      streamExecutor: streamExecutor,
      rbac: rbac,
      auditLogger: auditLogger,
      metricPort: metricPort,
    );

    final adapter = AnalysisPortAdapter(
      specManager: specManager,
      executionEngine: executionEngine,
      artifactStore: artifactStore,
      dataSourceRegistry: dataSourceRegistry,
      alertEvaluator: alertEvaluator,
    );

    return _TestFixture._(
      specStorage: specStorage,
      jobStorage: jobStorage,
      artifactStorage: artifactStorage,
      auditStorage: auditStorage,
      specManager: specManager,
      jobManager: jobManager,
      artifactStore: artifactStore,
      dataSourceRegistry: dataSourceRegistry,
      alertEvaluator: alertEvaluator,
      adapter: adapter,
    );
  }
  final InMemoryStorage<AnalysisSpec> specStorage;
  final InMemoryStorage<AnalysisJob> jobStorage;
  final InMemoryStorage<AnalysisArtifact> artifactStorage;
  final InMemoryStorage<AuditRecord> auditStorage;
  final SpecManager specManager;
  final JobManager jobManager;
  final ArtifactStore artifactStore;
  final DataSourceRegistry dataSourceRegistry;
  final AlertEvaluator alertEvaluator;
  final AnalysisPortAdapter adapter;
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('AnalysisPortAdapter', () {
    late _TestFixture f;

    setUp(() {
      f = _TestFixture();
    });

    // TC-001: Implements AnalysisPort interface
    test('TC-001: implements AnalysisPort', () {
      expect(f.adapter, isA<AnalysisPort>());
    });

    // TC-002: listSpecs delegates to SpecManager
    test('TC-002: listSpecs delegates to SpecManager', () async {
      final spec = createTestSpec(specId: 'adapter-spec');
      await f.specManager.createSpec(spec);

      final specs = await f.adapter.listSpecs(search: 'adapter');
      expect(specs, isNotEmpty);
      expect(specs.first.specId, 'adapter-spec');
    });

    // TC-003: listSpecs with limit and offset
    test('TC-003: listSpecs respects limit and offset', () async {
      for (var i = 0; i < 5; i++) {
        await f.specManager.createSpec(
          createTestSpec(specId: 'spec-$i'),
        );
      }

      final specs = await f.adapter.listSpecs(limit: 2, offset: 1);
      expect(specs.length, lessThanOrEqualTo(2));
    });

    // TC-004: createSpec delegates to SpecManager
    test('TC-004: createSpec delegates to SpecManager', () async {
      final spec = createTestSpec(specId: 'new-spec');
      final created = await f.adapter.createSpec(spec);

      expect(created.specId, 'new-spec');

      // Verify it was stored
      final fetched = await f.adapter.listSpecs(search: 'new-spec');
      expect(fetched, isNotEmpty);
    });

    // TC-005: updateSpec delegates to SpecManager
    test('TC-005: updateSpec delegates to SpecManager', () async {
      final spec = createTestSpec(specId: 'update-spec');
      await f.specManager.createSpec(spec);

      final updated = createTestSpec(
        specId: 'update-spec',
        version: '2.0.0',
      );
      final result = await f.adapter.updateSpec('update-spec', updated);
      expect(result.version, '2.0.0');
    });

    // TC-006: getJob delegates to ExecutionEngine
    test('TC-006: getJob delegates to ExecutionEngine', () async {
      final job = await f.jobManager.createJob(
        specId: 'test-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      final fetched = await f.adapter.getJob(job.jobId);
      expect(fetched, isNotNull);
      expect(fetched!.jobId, job.jobId);
    });

    // TC-007: getJob returns null for non-existent job
    test('TC-007: getJob returns null for non-existent job', () async {
      final result = await f.adapter.getJob('nonexistent');
      expect(result, isNull);
    });

    // TC-008: getArtifacts delegates to ArtifactStore
    test('TC-008: getArtifacts delegates to ArtifactStore', () async {
      final now = DateTime.now();
      final artifact = AnalysisMetricArtifact(
        artifactId: 'metric-001',
        name: 'test-metric',
        provenance: createTestProvenance(),
        value: 42.0,
        unit: 'units',
        timeRange: AnalysisTimeRange(
          start: now.subtract(const Duration(hours: 1)),
          end: now,
        ),
      );
      await f.artifactStore.save(artifact);

      final artifacts = await f.adapter.getArtifacts();
      expect(artifacts, isNotEmpty);
      expect(artifacts.first.artifactId, 'metric-001');
    });

    // TC-009: getArtifacts with type filter
    test('TC-009: getArtifacts with type filter', () async {
      final now = DateTime.now();
      final artifact = AnalysisMetricArtifact(
        artifactId: 'metric-002',
        name: 'filtered-metric',
        provenance: createTestProvenance(),
        value: 99.0,
        unit: 'units',
        timeRange: AnalysisTimeRange(
          start: now.subtract(const Duration(hours: 1)),
          end: now,
        ),
      );
      await f.artifactStore.save(artifact);

      final artifacts = await f.adapter.getArtifacts(
        type: AnalysisArtifactType.metric,
      );
      expect(artifacts, isNotEmpty);
    });

    // TC-010: evaluateAlert throws for missing alert rule artifact
    test('TC-010: evaluateAlert throws for missing alert rule', () async {
      expect(
        () => f.adapter.evaluateAlert('nonexistent-rule'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'artifact.not_found',
          ),
        ),
      );
    });

    // TC-011: evaluateAlert throws for wrong artifact type
    test('TC-011: evaluateAlert throws for non-AlertRule artifact', () async {
      final now = DateTime.now();
      final metricArtifact = AnalysisMetricArtifact(
        artifactId: 'metric-not-rule',
        name: 'not-a-rule',
        provenance: createTestProvenance(),
        value: 42.0,
        unit: 'units',
        timeRange: AnalysisTimeRange(
          start: now.subtract(const Duration(hours: 1)),
          end: now,
        ),
      );
      await f.artifactStore.save(metricArtifact);

      expect(
        () => f.adapter.evaluateAlert('metric-not-rule'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'artifact.not_found',
          ),
        ),
      );
    });

    // TC-012: runAnalysis delegates to ExecutionEngine
    test('TC-012: runAnalysis requires valid spec', () async {
      expect(
        () => f.adapter.runAnalysis(
          specId: 'nonexistent',
          parameters: {},
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.not_found',
          ),
        ),
      );
    });

    // TC-013: listSpecs returns empty for no match
    test('TC-013: listSpecs returns empty for no match', () async {
      final specs = await f.adapter.listSpecs(search: 'no-match');
      expect(specs, isEmpty);
    });

    // TC-013 (spec): getSpec delegates to SpecManager
    test('TC-013: getSpec delegates to SpecManager', () async {
      final spec = createTestSpec(specId: 'getspec-test');
      await f.specManager.createSpec(spec);

      final result = await f.adapter.getSpec('getspec-test');
      expect(result, isNotNull);
      expect(result!.specId, 'getspec-test');
    });

    // TC-014 (spec): cancelJob delegates to ExecutionEngine
    test('TC-014: cancelJob delegates to ExecutionEngine', () async {
      final spec = createTestSpec(specId: 'cancel-test');
      await f.specManager.createSpec(spec);

      final job = await f.jobManager.createJob(
        specId: 'cancel-test',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await f.jobManager.startJob(job.jobId);

      final canceled = await f.adapter.cancelJob(job.jobId);
      expect(canceled.status, AnalysisJobStatus.canceled);
    });

    // TC-015 (spec): evaluateAlert happy path full chain
    test('TC-015: evaluateAlert happy path with full chain', () async {
      final spec = createTestSpec(specId: 'alert-happy-spec');
      await f.specManager.createSpec(spec);

      // Create and store an AlertRule artifact referencing the spec
      final now = DateTime.now();
      final alertArtifact = AnalysisAlertRuleArtifact(
        artifactId: 'alert-happy-001',
        name: 'temp_alert',
        provenance: AnalysisArtifactProvenance(
          version: '1.0.0',
          createdAt: now,
          specId: 'alert-happy-spec',
          specVersion: '1.0.0',
          sourceUri: 'factgraph://temperature',
          sourceQuery: 'temperature',
        ),
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );
      await f.artifactStore.save(alertArtifact);

      // Register a data source so the adapter can query data
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        _SimpleDataSourceAdapter(),
      );

      final result = await f.adapter.evaluateAlert('alert-happy-001');
      expect(result, isNotNull);
      expect(result.alertRuleId, 'alert-happy-001');
    });

    // TC-016 (spec): evaluateAlert throws spec.not_found
    test('TC-016: evaluateAlert throws spec.not_found for missing spec',
        () async {
      final now = DateTime.now();
      final alertArtifact = AnalysisAlertRuleArtifact(
        artifactId: 'alert-no-spec',
        name: 'temp_alert',
        provenance: AnalysisArtifactProvenance(
          version: '1.0.0',
          createdAt: now,
          specId: 'missing-spec',
          specVersion: '1.0.0',
        ),
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );
      await f.artifactStore.save(alertArtifact);

      expect(
        () => f.adapter.evaluateAlert('alert-no-spec'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.not_found',
          ),
        ),
      );
    });

    // TC-017: evaluateAlert throws source.unavailable when all sources fail
    test(
        'TC-017: evaluateAlert throws source.unavailable when all sources fail',
        () async {
      // Create a spec with an input source that will always fail
      final spec = createTestSpec(
        specId: 'source-fail-spec',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
        ],
      );
      await f.specManager.createSpec(spec);

      // Create and store an AlertRule artifact referencing the spec
      final now = DateTime.now();
      final alertArtifact = AnalysisAlertRuleArtifact(
        artifactId: 'alert-source-fail',
        name: 'source_fail_alert',
        provenance: AnalysisArtifactProvenance(
          version: '1.0.0',
          createdAt: now,
          specId: 'source-fail-spec',
          specVersion: '1.0.0',
        ),
        condition: 'temperature > 80',
        severity: AnalysisAlertSeverity.critical,
      );
      await f.artifactStore.save(alertArtifact);

      // Register a failing data source adapter
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        _FailingDataSourceAdapter(),
      );

      expect(
        () => f.adapter.evaluateAlert('alert-source-fail'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'source.unavailable',
          ),
        ),
      );
    });

    // TC-roundtrip: createSpec followed by listSpecs returns created spec
    test('TC-roundtrip: createSpec -> listSpecs round trip', () async {
      final spec = createTestSpec(specId: 'roundtrip-spec');
      await f.adapter.createSpec(spec);

      final specs = await f.adapter.listSpecs(search: 'roundtrip');
      expect(specs, hasLength(1));
      expect(specs.first.specId, 'roundtrip-spec');
    });
  });
}

// ============================================================================
// Helper: Simple DataSourceAdapter for evaluateAlert chain tests
// ============================================================================

class _SimpleDataSourceAdapter implements DataSourceAdapter {
  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    return createTestDataSet();
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return const AnalysisSourceSchema(
      columns: [
        AnalysisColumnInfo(name: 'temperature', type: 'double'),
      ],
    );
  }

  @override
  Future<bool> isAvailable() async => true;
}

/// Data source adapter that always throws (for testing source failure paths).
class _FailingDataSourceAdapter implements DataSourceAdapter {
  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    throw AnalysisError(
      code: 'source.unavailable',
      message: 'Data source is unavailable',
    );
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    throw AnalysisError(
      code: 'source.unavailable',
      message: 'Data source is unavailable',
    );
  }

  @override
  Future<bool> isAvailable() async => false;
}
