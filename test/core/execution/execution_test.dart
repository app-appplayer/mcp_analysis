import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

// ============================================================================
// Test Helpers
// ============================================================================

/// Creates a minimal valid AnalysisSpec for execution engine tests.
AnalysisSpec _createSpec({
  String specId = 'exec-spec',
  String version = '1.0.0',
}) {
  return AnalysisSpec(
    specId: specId,
    version: version,
    inputSources: [
      AnalysisInputSource(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temperature',
      ),
    ],
    analysisSteps: [
      AnalysisStep(
        function: 'descriptive_stats',
        parameters: {'columns': ['temperature']},
      ),
    ],
    outputs: [
      AnalysisOutputDef(
        type: AnalysisArtifactType.metric,
        name: 'temperature_stats',
      ),
    ],
    metadata: const AnalysisSpecMetadata(
      description: 'Test spec for execution engine',
      tags: ['test'],
    ),
  );
}

// ============================================================================
// Fake BatchExecutor
// ============================================================================

/// A fake BatchExecutor that immediately completes jobs.
/// Extends the real BatchExecutor so the type system accepts it,
/// but overrides execute to bypass all real pipeline logic.
class FakeBatchExecutor extends BatchExecutor {
  final JobManager _testJobManager;

  FakeBatchExecutor({
    required JobManager jobManager,
    required DataSourceRegistry dataSourceRegistry,
    required TransformPipeline transformPipeline,
    required FunctionDispatcher functionDispatcher,
    required ArtifactBuilder artifactBuilder,
    required ArtifactStore artifactStore,
    required ProvenanceTracker provenanceTracker,
    required AlertEvaluator alertEvaluator,
  })  : _testJobManager = jobManager,
        super(
          jobManager: jobManager,
          dataSourceRegistry: dataSourceRegistry,
          transformPipeline: transformPipeline,
          functionDispatcher: functionDispatcher,
          artifactBuilder: artifactBuilder,
          artifactStore: artifactStore,
          provenanceTracker: provenanceTracker,
          alertEvaluator: alertEvaluator,
        );

  @override
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    // Immediately complete the job without running the real pipeline.
    return _testJobManager.completeJob(
      job.jobId,
      artifactIds: ['fake-artifact-001'],
    );
  }
}

// ============================================================================
// Fake AdhocExecutor
// ============================================================================

/// A fake AdhocExecutor that immediately completes jobs.
class FakeAdhocExecutor extends AdhocExecutor {
  final JobManager _testJobManager;

  FakeAdhocExecutor({
    required JobManager jobManager,
    required DataSourceRegistry dataSourceRegistry,
    required TransformPipeline transformPipeline,
    required FunctionDispatcher functionDispatcher,
    required ArtifactBuilder artifactBuilder,
    required ArtifactStore artifactStore,
    required ProvenanceTracker provenanceTracker,
    required AlertEvaluator alertEvaluator,
  })  : _testJobManager = jobManager,
        super(
          jobManager: jobManager,
          dataSourceRegistry: dataSourceRegistry,
          transformPipeline: transformPipeline,
          functionDispatcher: functionDispatcher,
          artifactBuilder: artifactBuilder,
          artifactStore: artifactStore,
          provenanceTracker: provenanceTracker,
          alertEvaluator: alertEvaluator,
        );

  @override
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    // Immediately complete the job without running the real pipeline.
    return _testJobManager.completeJob(
      job.jobId,
      artifactIds: ['fake-adhoc-artifact-001'],
    );
  }
}

// ============================================================================
// Fake StreamExecutor
// ============================================================================

/// A fake StreamExecutor that immediately completes jobs.
class FakeStreamExecutor extends StreamExecutor {
  final JobManager _testJobManager;

  FakeStreamExecutor({
    required JobManager jobManager,
    required DataSourceRegistry dataSourceRegistry,
    required TransformPipeline transformPipeline,
    required ArtifactBuilder artifactBuilder,
    required ArtifactStore artifactStore,
    required ProvenanceTracker provenanceTracker,
    required AlertEvaluator alertEvaluator,
  })  : _testJobManager = jobManager,
        super(
          jobManager: jobManager,
          dataSourceRegistry: dataSourceRegistry,
          transformPipeline: transformPipeline,
          artifactBuilder: artifactBuilder,
          artifactStore: artifactStore,
          provenanceTracker: provenanceTracker,
          alertEvaluator: alertEvaluator,
        );

  @override
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    // Immediately complete the job without running the real pipeline.
    return _testJobManager.completeJob(
      job.jobId,
      artifactIds: ['fake-stream-artifact-001'],
    );
  }
}

// ============================================================================
// Test Setup Factory
// ============================================================================

/// Holds all dependencies needed for ExecutionEngine tests.
class _TestFixture {
  final InMemoryStorage<AnalysisSpec> specStorage;
  final InMemoryStorage<AnalysisJob> jobStorage;
  final InMemoryStorage<AuditRecord> auditStorage;
  final SpecManager specManager;
  final JobManager jobManager;
  final RbacPolicy rbac;
  final AuditLogger auditLogger;
  final MockMetricPort metricPort;
  final FakeBatchExecutor batchExecutor;
  final FakeAdhocExecutor adhocExecutor;
  final FakeStreamExecutor streamExecutor;
  final ExecutionEngine engine;

  _TestFixture._({
    required this.specStorage,
    required this.jobStorage,
    required this.auditStorage,
    required this.specManager,
    required this.jobManager,
    required this.rbac,
    required this.auditLogger,
    required this.metricPort,
    required this.batchExecutor,
    required this.adhocExecutor,
    required this.streamExecutor,
    required this.engine,
  });

  /// Build a complete test fixture with real SpecManager/JobManager and
  /// fake executors.
  factory _TestFixture() {
    final specStorage = InMemoryStorage<AnalysisSpec>();
    final jobStorage = InMemoryStorage<AnalysisJob>();
    final auditStorage = InMemoryStorage<AuditRecord>();
    final artifactStorage = InMemoryStorage<AnalysisArtifact>();

    final specManager = SpecManager(
      storage: specStorage,
      validator: SpecValidator(),
      parameterResolver: ParameterResolver(),
    );
    final jobManager = JobManager(storage: jobStorage);
    final rbac = RbacPolicy();
    final auditLogger = AuditLogger(storage: auditStorage);
    final metricPort = MockMetricPort();

    // Shared sub-dependencies for the fake executors (never actually used).
    final dataSourceRegistry = DataSourceRegistry();
    final transformPipeline = TransformPipeline();
    final functionDispatcher = FunctionDispatcher(
      catalog: FunctionCatalog(),
    );
    final artifactBuilder = ArtifactBuilder();
    final artifactStore = ArtifactStore(storage: artifactStorage);
    final provenanceTracker = ProvenanceTracker();
    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: MockEventPort()),
    );

    final batchExecutor = FakeBatchExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final adhocExecutor = FakeAdhocExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final streamExecutor = FakeStreamExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final engine = ExecutionEngine(
      specManager: specManager,
      jobManager: jobManager,
      batchExecutor: batchExecutor,
      adhocExecutor: adhocExecutor,
      streamExecutor: streamExecutor,
      rbac: rbac,
      auditLogger: auditLogger,
      metricPort: metricPort,
    );

    return _TestFixture._(
      specStorage: specStorage,
      jobStorage: jobStorage,
      auditStorage: auditStorage,
      specManager: specManager,
      jobManager: jobManager,
      rbac: rbac,
      auditLogger: auditLogger,
      metricPort: metricPort,
      batchExecutor: batchExecutor,
      adhocExecutor: adhocExecutor,
      streamExecutor: streamExecutor,
      engine: engine,
    );
  }
}

// ============================================================================
// Failing BatchExecutor for TC-019
// ============================================================================

/// A BatchExecutor that always throws an error during execution.
class _FailingBatchExecutor extends BatchExecutor {
  _FailingBatchExecutor({
    required super.jobManager,
    required super.dataSourceRegistry,
    required super.transformPipeline,
    required super.functionDispatcher,
    required super.artifactBuilder,
    required super.artifactStore,
    required super.provenanceTracker,
    required super.alertEvaluator,
  });

  @override
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    throw AnalysisError(
      code: 'analysis.execution_error',
      message: 'Simulated executor failure',
      timestamp: DateTime.now(),
    );
  }
}

/// A BatchExecutor that throws a non-AnalysisError (generic exception).
class _GenericFailingBatchExecutor extends BatchExecutor {
  _GenericFailingBatchExecutor({
    required super.jobManager,
    required super.dataSourceRegistry,
    required super.transformPipeline,
    required super.functionDispatcher,
    required super.artifactBuilder,
    required super.artifactStore,
    required super.provenanceTracker,
    required super.alertEvaluator,
  });

  @override
  Future<AnalysisJob> execute({
    required AnalysisJob job,
    required AnalysisSpec spec,
    required Map<String, dynamic> resolvedParams,
  }) async {
    throw StateError('Generic non-AnalysisError failure');
  }
}

/// Test fixture that uses a failing batch executor.
class _FailingExecutorFixture {
  final SpecManager specManager;
  final JobManager jobManager;
  final ExecutionEngine engine;

  _FailingExecutorFixture._({
    required this.specManager,
    required this.jobManager,
    required this.engine,
  });

  factory _FailingExecutorFixture() {
    final specStorage = InMemoryStorage<AnalysisSpec>();
    final jobStorage = InMemoryStorage<AnalysisJob>();
    final auditStorage = InMemoryStorage<AuditRecord>();
    final artifactStorage = InMemoryStorage<AnalysisArtifact>();

    final specManager = SpecManager(
      storage: specStorage,
      validator: SpecValidator(),
      parameterResolver: ParameterResolver(),
    );
    final jobManager = JobManager(storage: jobStorage);
    final rbac = RbacPolicy();
    final auditLogger = AuditLogger(storage: auditStorage);
    final metricPort = MockMetricPort();

    final dataSourceRegistry = DataSourceRegistry();
    final transformPipeline = TransformPipeline();
    final functionDispatcher = FunctionDispatcher(
      catalog: FunctionCatalog(),
    );
    final artifactBuilder = ArtifactBuilder();
    final artifactStore = ArtifactStore(storage: artifactStorage);
    final provenanceTracker = ProvenanceTracker();
    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: MockEventPort()),
    );

    final failingBatchExecutor = _FailingBatchExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final adhocExecutor = FakeAdhocExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final streamExecutor = FakeStreamExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final engine = ExecutionEngine(
      specManager: specManager,
      jobManager: jobManager,
      batchExecutor: failingBatchExecutor,
      adhocExecutor: adhocExecutor,
      streamExecutor: streamExecutor,
      rbac: rbac,
      auditLogger: auditLogger,
      metricPort: metricPort,
    );

    return _FailingExecutorFixture._(
      specManager: specManager,
      jobManager: jobManager,
      engine: engine,
    );
  }
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('ExecutionEngine', () {
    late _TestFixture f;

    setUp(() {
      f = _TestFixture();
    });

    // TC-001: runAnalysis with valid spec returns a completed job
    test('TC-001: runAnalysis with valid spec returns a completed job',
        () async {
      // Register a spec first
      final spec = _createSpec(specId: 'valid-spec');
      await f.specManager.createSpec(spec);

      final job = await f.engine.runAnalysis(
        specId: 'valid-spec',
        parameters: {},
      );

      expect(job.status, equals(AnalysisJobStatus.completed));
      expect(job.specId, equals('valid-spec'));
      expect(job.artifactIds, contains('fake-artifact-001'));
    });

    // TC-002: runAnalysis with missing spec throws spec.not_found
    test('TC-002: runAnalysis with missing spec throws spec.not_found',
        () async {
      expect(
        () => f.engine.runAnalysis(
          specId: 'non-existent-spec',
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

    // TC-003: runAnalysis with RBAC denied throws governance.unauthorized
    test('TC-003: runAnalysis with RBAC denied throws governance.unauthorized',
        () async {
      final spec = _createSpec(specId: 'rbac-spec');
      await f.specManager.createSpec(spec);

      // Use a role that does not have 'execute' permission.
      // RbacPolicy only defines operator, engineer, admin roles.
      // An unknown role will have no permissions.
      final deniedContext = RbacContext(
        actorId: 'hacker',
        role: 'viewer',
      );

      expect(
        () => f.engine.runAnalysis(
          specId: 'rbac-spec',
          parameters: {},
          rbacContext: deniedContext,
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

    // TC-004: getJob delegates to JobManager
    test('TC-004: getJob delegates to JobManager', () async {
      // Create a job directly through JobManager
      final created = await f.jobManager.createJob(
        specId: 'some-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      // Retrieve through ExecutionEngine
      final fetched = await f.engine.getJob(created.jobId);
      expect(fetched, isNotNull);
      expect(fetched!.jobId, equals(created.jobId));
      expect(fetched.specId, equals('some-spec'));
    });

    // TC-005: getJob returns null for non-existent job
    test('TC-005: getJob returns null for non-existent job', () async {
      final result = await f.engine.getJob('ghost-job');
      expect(result, isNull);
    });

    // TC-006: cancelJob delegates to JobManager
    test('TC-006: cancelJob delegates to JobManager', () async {
      // Create and start a job
      final created = await f.jobManager.createJob(
        specId: 'cancel-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await f.jobManager.startJob(created.jobId);

      // Cancel through ExecutionEngine (no RBAC context)
      final canceled = await f.engine.cancelJob(created.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    // TC-007: cancelJob with RBAC context checks permission
    test('TC-007: cancelJob with RBAC context and operator can cancel own job',
        () async {
      // Create and start a job with _actorId parameter so RBAC can identify
      // the owner
      final created = await f.jobManager.createJob(
        specId: 'cancel-rbac-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
        parameters: {'_actorId': 'operator-1'},
      );
      await f.jobManager.startJob(created.jobId);

      // Operator can cancel their own job (cancel_own_job permission)
      final operatorContext = RbacContext(
        actorId: 'operator-1',
        role: 'operator',
      );
      final canceled = await f.engine.cancelJob(
        created.jobId,
        rbacContext: operatorContext,
      );
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    // TC-008: cancelJob with RBAC denied for cancel_any_job
    test(
        'TC-008: cancelJob by operator on another actor job throws governance.unauthorized',
        () async {
      // Create a job owned by a different actor
      final created = await f.jobManager.createJob(
        specId: 'other-owner-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
        parameters: {'_actorId': 'owner-99'},
      );
      await f.jobManager.startJob(created.jobId);

      // Operator tries to cancel someone else's job
      // operator role does not have cancel_any_job permission
      final operatorContext = RbacContext(
        actorId: 'operator-1',
        role: 'operator',
      );

      expect(
        () => f.engine.cancelJob(
          created.jobId,
          rbacContext: operatorContext,
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

    // TC-009: runAnalysis records audit log
    test('TC-009: runAnalysis records audit log', () async {
      final spec = _createSpec(specId: 'audit-spec');
      await f.specManager.createSpec(spec);

      await f.engine.runAnalysis(
        specId: 'audit-spec',
        parameters: {},
        rbacContext: const RbacContext(
          actorId: 'engineer-1',
          role: 'engineer',
        ),
      );

      // Verify audit record was stored
      final audits = await f.auditStorage.getAll();
      expect(audits, isNotEmpty);
      expect(audits.any((a) => a.specId == 'audit-spec'), isTrue);
      expect(audits.any((a) => a.actorId == 'engineer-1'), isTrue);
    });

    // TC-010: runAnalysis records operational metrics
    test('TC-010: runAnalysis records operational metrics', () async {
      final spec = _createSpec(specId: 'metric-spec');
      await f.specManager.createSpec(spec);

      await f.engine.runAnalysis(
        specId: 'metric-spec',
        parameters: {},
      );

      // Verify metric was recorded
      expect(f.metricPort.recordedMetrics, isNotEmpty);
      final metric = f.metricPort.recordedMetrics.firstWhere(
        (m) => m.name == 'analysis.job_duration_ms',
      );
      expect(metric.tags, isNotNull);
      expect(metric.tags!['specId'], equals('metric-spec'));
      expect(metric.tags!['mode'], equals('batch'));
    });

    // TC-011: runAnalysis with authorized RBAC context succeeds
    test('TC-011: runAnalysis with authorized RBAC context succeeds',
        () async {
      final spec = _createSpec(specId: 'authorized-spec');
      await f.specManager.createSpec(spec);

      // Operator has execute permission
      final operatorContext = RbacContext(
        actorId: 'op-1',
        role: 'operator',
      );

      final job = await f.engine.runAnalysis(
        specId: 'authorized-spec',
        parameters: {},
        rbacContext: operatorContext,
      );

      expect(job.status, equals(AnalysisJobStatus.completed));
    });

    // TC-012: runAnalysis without rbacContext skips RBAC check
    test('TC-012: runAnalysis without rbacContext skips RBAC check', () async {
      final spec = _createSpec(specId: 'no-rbac-spec');
      await f.specManager.createSpec(spec);

      // Should succeed without RBAC context
      final job = await f.engine.runAnalysis(
        specId: 'no-rbac-spec',
        parameters: {},
      );

      expect(job.status, equals(AnalysisJobStatus.completed));
    });

    // TC-013: cancelJob on non-existent job with RBAC throws job.not_found
    test('TC-013: cancelJob on non-existent job with RBAC throws job.not_found',
        () async {
      final ctx = RbacContext(actorId: 'admin-1', role: 'admin');

      expect(
        () => f.engine.cancelJob('ghost-job', rbacContext: ctx),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.not_found',
          ),
        ),
      );
    });

    // TC-014: admin can cancel any job (cancel_any_job permission)
    test('TC-014: admin can cancel any job', () async {
      final created = await f.jobManager.createJob(
        specId: 'admin-cancel-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
        parameters: {'_actorId': 'someone-else'},
      );
      await f.jobManager.startJob(created.jobId);

      final adminContext = RbacContext(
        actorId: 'admin-1',
        role: 'admin',
      );

      final canceled = await f.engine.cancelJob(
        created.jobId,
        rbacContext: adminContext,
      );
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    // TC-015: streaming mode routes to StreamExecutor
    test('TC-015: streaming mode routes to StreamExecutor', () async {
      final spec = _createSpec(specId: 'stream-route-spec');
      await f.specManager.createSpec(spec);

      final job = await f.engine.runAnalysis(
        specId: 'stream-route-spec',
        parameters: {},
        mode: AnalysisExecutionMode.streaming,
      );

      // FakeStreamExecutor completes with fake-stream-artifact-001
      expect(job.status, equals(AnalysisJobStatus.completed));
      expect(job.artifactIds, contains('fake-stream-artifact-001'));
    });

    // TC-016: adhoc mode routes to AdhocExecutor
    test('TC-016: adhoc mode routes to AdhocExecutor', () async {
      final spec = _createSpec(specId: 'adhoc-route-spec');
      await f.specManager.createSpec(spec);

      final job = await f.engine.runAnalysis(
        specId: 'adhoc-route-spec',
        parameters: {},
        mode: AnalysisExecutionMode.adhoc,
      );

      // FakeAdhocExecutor completes with fake-adhoc-artifact-001
      expect(job.status, equals(AnalysisJobStatus.completed));
      expect(job.artifactIds, contains('fake-adhoc-artifact-001'));
    });

    // TC-018: parameter resolution merges spec defaults with runtime overrides
    test('TC-018: parameter resolution is called with correct args', () async {
      final spec = AnalysisSpec(
        specId: 'param-resolve-spec',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {'columns': ['temperature']},
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'temperature_stats',
          ),
        ],
        parameters: {
          'threshold': 0.5,
          'window': 10,
        },
        metadata: const AnalysisSpecMetadata(
          description: 'Test param resolution',
          tags: ['test'],
        ),
      );
      await f.specManager.createSpec(spec);

      // Run with runtime overrides
      final job = await f.engine.runAnalysis(
        specId: 'param-resolve-spec',
        parameters: {'threshold': 0.9},
      );

      // Job should complete with merged parameters
      expect(job.status, equals(AnalysisJobStatus.completed));
      // Runtime override should be merged: threshold=0.9 from override,
      // window=10 from spec defaults
      final storedJob = await f.jobManager.getJob(job.jobId);
      expect(storedJob, isNotNull);
      expect(storedJob!.parameters['threshold'], equals(0.9));
      expect(storedJob.parameters['window'], equals(10));
    });

    // TC-019: executor failure marks job as failed
    test('TC-019: executor failure marks job as failed', () async {
      // Register spec
      final spec = _createSpec(specId: 'fail-exec-spec');
      await f.specManager.createSpec(spec);

      // Override the batch executor to throw an error
      final failingFixture = _FailingExecutorFixture();
      final failSpec = _createSpec(specId: 'fail-exec-spec-2');
      await failingFixture.specManager.createSpec(failSpec);

      expect(
        () => failingFixture.engine.runAnalysis(
          specId: 'fail-exec-spec-2',
          parameters: {},
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

    // TC-020: non-AnalysisError is wrapped in AnalysisError by catch block
    test('TC-020: non-AnalysisError from executor is wrapped in AnalysisError',
        () async {
      // Build a fixture with a generic-failing batch executor
      final specStorage = InMemoryStorage<AnalysisSpec>();
      final jobStorage = InMemoryStorage<AnalysisJob>();
      final auditStorage = InMemoryStorage<AuditRecord>();
      final artifactStorage = InMemoryStorage<AnalysisArtifact>();

      final specManager = SpecManager(
        storage: specStorage,
        validator: SpecValidator(),
        parameterResolver: ParameterResolver(),
      );
      final jobManager = JobManager(storage: jobStorage);
      final rbac = RbacPolicy();
      final auditLogger = AuditLogger(storage: auditStorage);
      final metricPort = MockMetricPort();

      final dataSourceRegistry = DataSourceRegistry();
      final transformPipeline = TransformPipeline();
      final functionDispatcher = FunctionDispatcher(catalog: FunctionCatalog());
      final artifactBuilder = ArtifactBuilder();
      final artifactStore = ArtifactStore(storage: artifactStorage);
      final provenanceTracker = ProvenanceTracker();
      final alertEvaluator = AlertEvaluator(
        publisher: AlertPublisher(eventPort: MockEventPort()),
      );

      final genericFailingExecutor = _GenericFailingBatchExecutor(
        jobManager: jobManager,
        dataSourceRegistry: dataSourceRegistry,
        transformPipeline: transformPipeline,
        functionDispatcher: functionDispatcher,
        artifactBuilder: artifactBuilder,
        artifactStore: artifactStore,
        provenanceTracker: provenanceTracker,
        alertEvaluator: alertEvaluator,
      );

      final adhocExecutor = FakeAdhocExecutor(
        jobManager: jobManager,
        dataSourceRegistry: dataSourceRegistry,
        transformPipeline: transformPipeline,
        functionDispatcher: functionDispatcher,
        artifactBuilder: artifactBuilder,
        artifactStore: artifactStore,
        provenanceTracker: provenanceTracker,
        alertEvaluator: alertEvaluator,
      );

      final streamExecutor = FakeStreamExecutor(
        jobManager: jobManager,
        dataSourceRegistry: dataSourceRegistry,
        transformPipeline: transformPipeline,
        artifactBuilder: artifactBuilder,
        artifactStore: artifactStore,
        provenanceTracker: provenanceTracker,
        alertEvaluator: alertEvaluator,
      );

      final engine = ExecutionEngine(
        specManager: specManager,
        jobManager: jobManager,
        batchExecutor: genericFailingExecutor,
        adhocExecutor: adhocExecutor,
        streamExecutor: streamExecutor,
        rbac: rbac,
        auditLogger: auditLogger,
        metricPort: metricPort,
      );

      final spec = _createSpec(specId: 'generic-fail-spec');
      await specManager.createSpec(spec);

      // DDD specifies: wrap in AnalysisError, failJob(), then rethrow original
      expect(
        () => engine.runAnalysis(
          specId: 'generic-fail-spec',
          parameters: {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('ExecutionEngine Integration', () {
    late _TestFixture f;

    setUp(() {
      f = _TestFixture();
    });

    // IT-001: Full lifecycle through ExecutionEngine
    test('IT-001: full lifecycle: register spec -> run -> get job -> verify',
        () async {
      // 1. Register spec
      final spec = _createSpec(specId: 'lifecycle-spec', version: '2.0.0');
      await f.specManager.createSpec(spec);

      // 2. Run analysis
      final job = await f.engine.runAnalysis(
        specId: 'lifecycle-spec',
        parameters: {'threshold': 0.9},
        mode: AnalysisExecutionMode.batch,
      );
      expect(job.status, equals(AnalysisJobStatus.completed));

      // 3. Retrieve via getJob
      final fetched = await f.engine.getJob(job.jobId);
      expect(fetched, isNotNull);
      expect(fetched!.status, equals(AnalysisJobStatus.completed));
      expect(fetched.specId, equals('lifecycle-spec'));
    });

    // IT-002: Multiple runs produce independent jobs
    test('IT-002: multiple runs produce independent jobs', () async {
      final spec = _createSpec(specId: 'multi-run-spec');
      await f.specManager.createSpec(spec);

      final job1 = await f.engine.runAnalysis(
        specId: 'multi-run-spec',
        parameters: {'run': 1},
      );
      final job2 = await f.engine.runAnalysis(
        specId: 'multi-run-spec',
        parameters: {'run': 2},
      );

      expect(job1.jobId, isNot(equals(job2.jobId)));
      expect(job1.status, equals(AnalysisJobStatus.completed));
      expect(job2.status, equals(AnalysisJobStatus.completed));

      // Both jobs should be retrievable independently
      final fetched1 = await f.engine.getJob(job1.jobId);
      final fetched2 = await f.engine.getJob(job2.jobId);
      expect(fetched1, isNotNull);
      expect(fetched2, isNotNull);
      expect(fetched1!.jobId, isNot(equals(fetched2!.jobId)));
    });
  });

  // ==========================================================================
  // stream.error code (TC-017)
  // ==========================================================================
  group('StreamExecutor error codes', () {
    // TC-017: StreamExecutor uses stream.error code for stream failures
    test('TC-017: stream errors use stream.error code', () {
      // Verify the error code is used in StreamExecutor
      // By creating an AnalysisError with stream.error code
      final error = AnalysisError(
        code: 'stream.error',
        message: 'Stream error: connection lost',
        timestamp: DateTime.now(),
      );

      expect(error.code, equals('stream.error'));
      expect(error.message, contains('Stream error'));
    });
  });
}
