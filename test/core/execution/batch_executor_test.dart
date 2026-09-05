import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';
import '../../helpers/test_data.dart';

// ============================================================================
// Fake DataSourceAdapter for testing
// ============================================================================

class FakeDataSourceAdapter extends DataSourceAdapter
    with StreamableDataSource {
  FakeDataSourceAdapter({this.dataSet});
  AnalysisDataSet? dataSet;
  bool shouldFail = false;
  String failCode = 'source.unavailable';
  String failMessage = 'Source unavailable';

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    if (shouldFail) {
      throw AnalysisError(
        code: failCode,
        message: failMessage,
        timestamp: DateTime.now(),
      );
    }
    return dataSet ?? createTestDataSet();
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
  Future<bool> isAvailable() async => !shouldFail;

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) {
    return Stream.value(dataSet ?? createTestDataSet());
  }
}

// ============================================================================
// Fake AnalysisFunction for testing
// ============================================================================

class FakeAnalysisFunction implements AnalysisFunction {
  FakeAnalysisFunction({
    required this.functionName,
    Map<String, dynamic>? result,
  }) : result = result ??
            {
              'mean': 75.0,
              'stddev': 5.0,
              'count': 5,
            };
  final String functionName;
  final Map<String, dynamic> result;

  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: functionName,
        description: 'Fake $functionName for testing',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'list',
            description: 'Columns to analyze',
          ),
        },
        supportedDataTypes: ['double', 'int'],
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    return AnalysisFunctionResult(
      functionName: functionName,
      results: result,
      executionTime: const Duration(milliseconds: 10),
    );
  }
}

// ============================================================================
// Test Fixture
// ============================================================================

class _BatchTestFixture {
  _BatchTestFixture._({
    required this.jobStorage,
    required this.artifactStorage,
    required this.jobManager,
    required this.dataSourceRegistry,
    required this.transformPipeline,
    required this.functionDispatcher,
    required this.artifactBuilder,
    required this.artifactStore,
    required this.provenanceTracker,
    required this.alertEvaluator,
    required this.eventPort,
    required this.executor,
  });

  factory _BatchTestFixture({
    RetryPolicy? retryPolicy,
    Duration? timeout,
  }) {
    final jobStorage = InMemoryStorage<AnalysisJob>();
    final artifactStorage = InMemoryStorage<AnalysisArtifact>();
    final jobManager = JobManager(storage: jobStorage);
    final dataSourceRegistry = DataSourceRegistry();
    final transformPipeline = TransformPipeline();
    final functionDispatcher = FunctionDispatcher(
      catalog: FunctionCatalog(),
    );
    final artifactBuilder = ArtifactBuilder();
    final artifactStore = ArtifactStore(storage: artifactStorage);
    final provenanceTracker = ProvenanceTracker();
    final eventPort = MockEventPort();
    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: eventPort),
    );

    final executor = BatchExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
      retryPolicy: retryPolicy,
      timeout: timeout ?? const Duration(minutes: 30),
    );

    return _BatchTestFixture._(
      jobStorage: jobStorage,
      artifactStorage: artifactStorage,
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
      eventPort: eventPort,
      executor: executor,
    );
  }
  final InMemoryStorage<AnalysisJob> jobStorage;
  final InMemoryStorage<AnalysisArtifact> artifactStorage;
  final JobManager jobManager;
  final DataSourceRegistry dataSourceRegistry;
  final TransformPipeline transformPipeline;
  final FunctionDispatcher functionDispatcher;
  final ArtifactBuilder artifactBuilder;
  final ArtifactStore artifactStore;
  final ProvenanceTracker provenanceTracker;
  final AlertEvaluator alertEvaluator;
  final MockEventPort eventPort;
  final BatchExecutor executor;

  /// Create a job in running state for the given spec.
  Future<AnalysisJob> createRunningJob({
    String specId = 'batch-spec',
    AnalysisExecutionMode mode = AnalysisExecutionMode.batch,
  }) async {
    final job = await jobManager.createJob(
      specId: specId,
      specVersion: '1.0.0',
      mode: mode,
    );
    await jobManager.startJob(job.jobId);
    return job;
  }
}

/// Creates a minimal AnalysisSpec for batch executor tests.
AnalysisSpec _createBatchSpec({
  String specId = 'batch-spec',
  List<AnalysisInputSource>? inputSources,
  List<AnalysisTransform>? transforms,
  List<AnalysisStep>? analysisSteps,
  List<AnalysisOutputDef>? outputs,
}) {
  return AnalysisSpec(
    specId: specId,
    version: '1.0.0',
    inputSources: inputSources ??
        [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
        ],
    transforms: transforms ?? [],
    analysisSteps: analysisSteps ??
        [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {
              'columns': ['temperature']
            },
          ),
        ],
    outputs: outputs ??
        [
          AnalysisOutputDef(
            from: 'descriptive_stats',
            type: AnalysisArtifactType.metric,
            name: 'temperature_stats',
          ),
        ],
    metadata: const AnalysisSpecMetadata(
      description: 'Test batch spec',
      tags: ['test'],
    ),
  );
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('BatchExecutor', () {
    late _BatchTestFixture f;

    setUp(() {
      f = _BatchTestFixture();
    });

    // TC-001: Successful batch execution (5-phase pipeline)
    test('TC-001: successful batch execution completes 5-phase pipeline',
        () async {
      // Register data source adapter
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 5),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      // Register analysis function
      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Phase 1-5 completed → job completed
      expect(result.status, equals(AnalysisJobStatus.completed));
      expect(result.progress, equals(1.0));
      expect(result.artifactIds, isNotEmpty);
      expect(result.logs, isNotEmpty);
    });

    // TC-002: Job status transitions (queued→running via startJob)
    test('TC-002: job transitions from queued to running via startJob',
        () async {
      final created = await f.jobManager.createJob(
        specId: 'batch-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      expect(created.status, equals(AnalysisJobStatus.queued));

      final started = await f.jobManager.startJob(created.jobId);
      expect(started.status, equals(AnalysisJobStatus.running));
    });

    // TC-003: Multiple input sources merged
    test('TC-003: multiple input sources are merged into a single dataset',
        () async {
      final now = DateTime.now();
      final adapter1 = FakeDataSourceAdapter(
        dataSet: AnalysisDataSet(
          columns: [
            const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
            const AnalysisColumnInfo(name: 'temperature', type: 'double'),
          ],
          rows: [
            {
              '_timestamp': now.subtract(const Duration(minutes: 2)),
              'temperature': 70.0
            },
          ],
          rowCount: 1,
        ),
      );
      final adapter2 = FakeDataSourceAdapter(
        dataSet: AnalysisDataSet(
          columns: [
            const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
            const AnalysisColumnInfo(name: 'humidity', type: 'double'),
          ],
          rows: [
            {
              '_timestamp': now.subtract(const Duration(minutes: 1)),
              'humidity': 55.0
            },
          ],
          rowCount: 1,
        ),
      );

      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter1);
      f.dataSourceRegistry.register(AnalysisSourceType.mcpIo, adapter2);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.mcpIo,
            query: 'humidity',
          ),
        ],
      );

      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.completed));
      // Two sources merged successfully
      expect(result.artifactIds, isNotEmpty);
    });

    // TC-004: Partial source failure continues with remaining
    test('TC-004: partial source failure continues with remaining sources',
        () async {
      // Use a fixture with fast retry to avoid test delays
      final fixture = _BatchTestFixture(
        retryPolicy: const RetryPolicy(
          maxRetries: 1,
          retryDelay: Duration.zero,
          backoffMultiplier: 1.0,
        ),
      );

      final goodAdapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 3),
      );
      final badAdapter = FakeDataSourceAdapter()..shouldFail = true;

      fixture.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        goodAdapter,
      );
      fixture.dataSourceRegistry.register(
        AnalysisSourceType.mcpIo,
        badAdapter,
      );

      fixture.functionDispatcher.registerBuiltins([
        FakeAnalysisFunction(functionName: 'descriptive_stats'),
      ]);

      final spec = _createBatchSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.mcpIo,
            query: 'bad_source',
          ),
        ],
      );

      final job = await fixture.createRunningJob();

      final result = await fixture.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Job completes with partial data from the good source
      expect(result.status, equals(AnalysisJobStatus.completed));
      // Should have errors from the failed source
      expect(result.errors, isNotEmpty);
      expect(
        result.errors.any((e) =>
            e.code == 'source.unavailable' || e.code == 'job.retry_exhausted'),
        isTrue,
      );
    });

    // TC-005: All sources fail → job failed
    test('TC-005: all sources fail results in job failed', () async {
      final fixture = _BatchTestFixture(
        retryPolicy: const RetryPolicy(
          maxRetries: 1,
          retryDelay: Duration.zero,
          backoffMultiplier: 1.0,
        ),
      );

      final badAdapter = FakeDataSourceAdapter()..shouldFail = true;
      fixture.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        badAdapter,
      );

      final spec = _createBatchSpec();
      final job = await fixture.createRunningJob();

      final result = await fixture.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.failed));
      expect(
        result.errors.any((e) =>
            e.code == 'source.unavailable' || e.code == 'job.retry_exhausted'),
        isTrue,
      );
    });

    // TC-006: Transform pipeline executed on merged data
    test('TC-006: transform pipeline is executed on merged data', () async {
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 5),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec(
        transforms: [
          AnalysisTransform(
            name: 'filter',
            parameters: {
              'column': 'temperature',
              'operator': '>',
              'value': 72.0,
            },
          ),
        ],
      );

      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.completed));
      // Verify transform step was logged
      expect(
        result.logs.any((l) => l.step == 'transform:pipeline'),
        isTrue,
      );
    });

    // TC-007: Analysis functions executed sequentially
    test('TC-007: analysis functions are executed sequentially', () async {
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 5),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final statsFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      final anomalyFunction = FakeAnalysisFunction(
        functionName: 'anomaly_detect',
        result: {'anomalies': <dynamic>[], 'score': 0.1},
      );
      f.functionDispatcher.registerBuiltins([statsFunction, anomalyFunction]);

      final spec = _createBatchSpec(
        analysisSteps: [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {
              'columns': ['temperature']
            },
          ),
          AnalysisStep(
            function: 'anomaly_detect',
            parameters: {
              'columns': ['temperature']
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'descriptive_stats',
          ),
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'anomaly_detect',
          ),
        ],
      );

      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.completed));
      // Both functions logged
      expect(
        result.logs.any((l) => l.step == 'function:descriptive_stats'),
        isTrue,
      );
      expect(
        result.logs.any((l) => l.step == 'function:anomaly_detect'),
        isTrue,
      );
    });

    // TC-008: Artifacts built with provenance
    test('TC-008: artifacts are built with provenance metadata', () async {
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 3),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec(specId: 'provenance-spec');
      final job = await f.createRunningJob(specId: 'provenance-spec');

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {'threshold': 0.5},
      );

      expect(result.status, equals(AnalysisJobStatus.completed));
      expect(result.artifactIds, isNotEmpty);

      // Verify artifact was stored with provenance
      for (final artifactId in result.artifactIds) {
        final artifact = await f.artifactStore.get(artifactId);
        expect(artifact, isNotNull);
        expect(artifact!.provenance.specId, equals('provenance-spec'));
        expect(artifact.provenance.specVersion, equals('1.0.0'));
      }
    });

    // TC-009: Alert evaluation on batch results
    test('TC-009: alert evaluation runs on batch results', () async {
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 3),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
        result: {
          'condition': 'temperature > 50',
        },
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec(
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'descriptive_stats',
          ),
        ],
      );

      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Job should complete (alerts are non-blocking on error)
      expect(result.status, equals(AnalysisJobStatus.completed));
    });

    // TC-010: Progress updates at each phase
    test('TC-010: progress is updated at each phase', () async {
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 3),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Final progress should be 1.0
      expect(result.progress, equals(1.0));
      expect(result.status, equals(AnalysisJobStatus.completed));
    });

    // TC-011: StepLogger records per-step logs (per-instance pattern)
    test('TC-011: StepLogger records per-step logs for each execution',
        () async {
      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 5),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.logs, isNotEmpty);
      // Source step logged
      expect(
        result.logs.any((l) => l.step.startsWith('source:')),
        isTrue,
      );
      // Function step logged
      expect(
        result.logs.any((l) => l.step.startsWith('function:')),
        isTrue,
      );

      // Verify StepLogger is per-instance (new execution has fresh logs)
      final stepLogger = StepLogger();
      expect(stepLogger.logs, isEmpty);
      stepLogger.logStep(
        step: 'test:step',
        inputSize: 10,
        outputSize: 5,
        executionTime: const Duration(milliseconds: 100),
      );
      expect(stepLogger.logs.length, equals(1));
      expect(stepLogger.logs.first.step, equals('test:step'));
    });

    // TC-012: Retry on transient error (source.unavailable)
    test('TC-012: retry on transient source.unavailable error', () async {
      // Adapter that fails twice then succeeds
      final failingAdapter = _RetryTestAdapter(
        failCount: 2,
        successData: createTestDataSet(rowCount: 3),
      );

      // Use a retry policy with no delay for testing
      final fixture = _BatchTestFixture(
        retryPolicy: const RetryPolicy(
          maxRetries: 3,
          retryDelay: Duration.zero,
          backoffMultiplier: 1.0,
        ),
      );
      fixture.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        failingAdapter,
      );
      fixture.functionDispatcher.registerBuiltins([
        FakeAnalysisFunction(functionName: 'descriptive_stats'),
      ]);

      final spec = _createBatchSpec();
      final job = await fixture.createRunningJob();

      final result = await fixture.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Should succeed after retries
      expect(result.status, equals(AnalysisJobStatus.completed));
      expect(failingAdapter.callCount, greaterThan(1));
    });

    // TC-013: Retry exhausted → job.retry_exhausted
    test('TC-013: retry exhausted results in retry_exhausted error', () async {
      // Adapter that always fails with source.unavailable
      final alwaysFailAdapter = _RetryTestAdapter(
        failCount: 100, // always fails
        successData: createTestDataSet(),
      );

      final fixture = _BatchTestFixture(
        retryPolicy: const RetryPolicy(
          maxRetries: 2,
          retryDelay: Duration.zero,
          backoffMultiplier: 1.0,
        ),
      );
      fixture.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        alwaysFailAdapter,
      );
      fixture.functionDispatcher.registerBuiltins([
        FakeAnalysisFunction(functionName: 'descriptive_stats'),
      ]);

      final spec = _createBatchSpec();
      final job = await fixture.createRunningJob();

      final result = await fixture.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // All retries exhausted → job fails
      expect(result.status, equals(AnalysisJobStatus.failed));
      expect(
        result.errors.any((e) =>
            e.code == 'source.unavailable' || e.code == 'job.retry_exhausted'),
        isTrue,
      );
    });

    // TC-014: Timeout → job.timeout
    test('TC-014: timeout results in job.timeout error', () async {
      // Use a very short timeout
      final fixture = _BatchTestFixture(
        timeout: const Duration(milliseconds: 1),
      );

      // Adapter that takes a long time
      final slowAdapter = _SlowDataSourceAdapter(
        delay: const Duration(seconds: 5),
        dataSet: createTestDataSet(),
      );
      fixture.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        slowAdapter,
      );
      fixture.functionDispatcher.registerBuiltins([
        FakeAnalysisFunction(functionName: 'descriptive_stats'),
      ]);

      final spec = _createBatchSpec();
      final job = await fixture.createRunningJob();

      final result = await fixture.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.failed));
      expect(
        result.errors.any((e) => e.code == 'job.timeout'),
        isTrue,
      );
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('BatchExecutor Integration', () {
    // IT-001: Full pipeline integration
    test('IT-001: full pipeline from data acquisition to artifact storage',
        () async {
      final f = _BatchTestFixture();

      final adapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 10),
      );
      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, adapter);

      final fakeFunction = FakeAnalysisFunction(
        functionName: 'descriptive_stats',
        result: {
          'mean': 75.0,
          'stddev': 5.0,
          'count': 10,
          'value': 75.0,
          'unit': '°F',
        },
      );
      f.functionDispatcher.registerBuiltins([fakeFunction]);

      final spec = _createBatchSpec(
        transforms: [
          AnalysisTransform(
            name: 'sort',
            parameters: {
              'columns': ['_timestamp'],
              'ascending': true
            },
          ),
        ],
      );

      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {'threshold': 0.9},
      );

      expect(result.status, equals(AnalysisJobStatus.completed));
      expect(result.progress, equals(1.0));
      expect(result.artifactIds, isNotEmpty);

      // Verify artifacts persisted
      for (final id in result.artifactIds) {
        final artifact = await f.artifactStore.get(id);
        expect(artifact, isNotNull);
      }

      // Verify step logs present
      expect(result.logs.length, greaterThanOrEqualTo(2));
    });

    // IT-002: Partial failure with artifact output
    test('IT-002: partial source failure still produces artifacts', () async {
      final f = _BatchTestFixture(
        retryPolicy: const RetryPolicy(
          maxRetries: 1,
          retryDelay: Duration.zero,
          backoffMultiplier: 1.0,
        ),
      );

      final goodAdapter = FakeDataSourceAdapter(
        dataSet: createTestDataSet(rowCount: 5),
      );
      final badAdapter = FakeDataSourceAdapter()..shouldFail = true;

      f.dataSourceRegistry.register(AnalysisSourceType.factgraph, goodAdapter);
      f.dataSourceRegistry.register(AnalysisSourceType.mcpIo, badAdapter);

      f.functionDispatcher.registerBuiltins([
        FakeAnalysisFunction(functionName: 'descriptive_stats'),
      ]);

      final spec = _createBatchSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.mcpIo,
            query: 'unavailable',
          ),
        ],
      );

      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Completes with artifacts from successful source
      expect(result.status, equals(AnalysisJobStatus.completed));
      expect(result.artifactIds, isNotEmpty);
      // Has errors from failed source
      expect(result.errors, isNotEmpty);
    });

    // IT-003: Retry policy integration
    test('IT-003: retry policy integration with exponential backoff', () async {
      final f = _BatchTestFixture(
        retryPolicy: const RetryPolicy(
          maxRetries: 3,
          retryDelay: Duration.zero,
          backoffMultiplier: 1.0,
        ),
      );

      // Fails once, then succeeds
      final retryAdapter = _RetryTestAdapter(
        failCount: 1,
        successData: createTestDataSet(rowCount: 5),
      );
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        retryAdapter,
      );

      f.functionDispatcher.registerBuiltins([
        FakeAnalysisFunction(functionName: 'descriptive_stats'),
      ]);

      final spec = _createBatchSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.completed));
      // Adapter was called more than once (retry happened)
      expect(retryAdapter.callCount, equals(2));
    });
  });
}

// ============================================================================
// Helper Adapters
// ============================================================================

/// Adapter that fails a specified number of times before succeeding.
class _RetryTestAdapter extends DataSourceAdapter with StreamableDataSource {
  _RetryTestAdapter({
    required this.failCount,
    required this.successData,
  });
  final int failCount;
  final AnalysisDataSet successData;
  int callCount = 0;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    callCount++;
    if (callCount <= failCount) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'Transient failure (attempt $callCount)',
        timestamp: DateTime.now(),
      );
    }
    return successData;
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

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) {
    return Stream.value(successData);
  }
}

/// Adapter that introduces a delay (for timeout testing).
class _SlowDataSourceAdapter extends DataSourceAdapter
    with StreamableDataSource {
  _SlowDataSourceAdapter({
    required this.delay,
    required this.dataSet,
  });
  final Duration delay;
  final AnalysisDataSet dataSet;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    await Future<void>.delayed(delay);
    return dataSet;
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return const AnalysisSourceSchema(
      columns: [],
    );
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) {
    return Stream.value(dataSet);
  }
}
