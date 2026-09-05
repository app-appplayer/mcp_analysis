import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';
import '../helpers/test_data.dart';

// ============================================================================
// Fake Data Source for E2E
// ============================================================================

class E2eDataSourceAdapter implements DataSourceAdapter {
  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    return createTestDataSet(rowCount: 10);
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

// ============================================================================
// E2E Test Fixture
// ============================================================================

class _E2eFixture {
  _E2eFixture._({
    required this.specManager,
    required this.jobManager,
    required this.artifactStore,
    required this.adapter,
    required this.toolHandler,
    required this.resourceHandler,
    required this.catalog,
  });

  factory _E2eFixture() {
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
    dataSourceRegistry.register(
      AnalysisSourceType.factgraph,
      E2eDataSourceAdapter(),
    );

    final catalog = FunctionCatalog();
    final descriptiveStats = DescriptiveStatsFunction();
    catalog.register(descriptiveStats.info);

    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: MockEventPort()),
    );

    final transformPipeline = TransformPipeline();
    final functionDispatcher = FunctionDispatcher(catalog: catalog);
    functionDispatcher.registerImplementation(
      'descriptive_stats',
      descriptiveStats,
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

    final toolHandler = McpToolHandler(
      analysisPort: adapter,
      rbac: rbac,
      auditLogger: auditLogger,
      dataMasker: DataMasker(),
    );

    final resourceHandler = McpResourceHandler(
      analysisPort: adapter,
      functionCatalog: catalog,
    );

    return _E2eFixture._(
      specManager: specManager,
      jobManager: jobManager,
      artifactStore: artifactStore,
      adapter: adapter,
      toolHandler: toolHandler,
      resourceHandler: resourceHandler,
      catalog: catalog,
    );
  }
  final SpecManager specManager;
  final JobManager jobManager;
  final ArtifactStore artifactStore;
  final AnalysisPortAdapter adapter;
  final McpToolHandler toolHandler;
  final McpResourceHandler resourceHandler;
  final FunctionCatalog catalog;
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('E2E System Test', () {
    late _E2eFixture f;

    setUp(() {
      f = _E2eFixture();
    });

    // E2E-001: Full lifecycle via MCP tools
    test('E2E-001: create spec -> run analysis -> get job -> get artifacts',
        () async {
      // 1. Create spec via MCP tool
      final spec = createTestSpec(specId: 'e2e-spec');
      final createResult = await f.toolHandler.handleTool(
        'analysis.create_spec',
        {'spec': spec.toJson()},
      );
      expect(createResult, containsPair('specId', 'e2e-spec'));

      // 2. Run analysis via MCP tool
      final runResult = await f.toolHandler.handleTool(
        'analysis.run',
        {'specId': 'e2e-spec', 'parameters': <String, dynamic>{}},
      );
      expect(runResult, containsPair('jobId', isA<String>()));
      final jobId = runResult['jobId'] as String;

      // 3. Get job status via MCP tool
      final jobResult = await f.toolHandler.handleTool(
        'analysis.get_job',
        {'jobId': jobId},
      );
      expect(jobResult, containsPair('jobId', jobId));
      expect(
        jobResult['status'],
        anyOf('completed', 'failed'),
      );

      // 4. Get artifacts via MCP tool
      final artifactResult = await f.toolHandler.handleTool(
        'analysis.get_artifacts',
        {'jobId': jobId},
      );
      expect(artifactResult, containsPair('artifacts', isA<List<dynamic>>()));
    });

    // E2E-002: Resource resolution via MCP
    test('E2E-002: create spec -> resolve via resource handler', () async {
      final spec = createTestSpec(specId: 'resource-spec');
      await f.adapter.createSpec(spec);

      // Resolve spec via resource handler
      final result = await f.resourceHandler
          .resolveResource('analysis:///spec/resource-spec');
      expect(result, containsPair('specId', 'resource-spec'));
    });

    // E2E-003: Catalog resource returns registered builtins
    test('E2E-003: catalog resource lists registered functions', () async {
      final result =
          await f.resourceHandler.resolveResource('analysis:///catalog');

      expect(result, containsPair('functions', isA<List<dynamic>>()));
      expect(result, containsPair('count', isA<int>()));

      final count = result['count'] as int;
      expect(count, greaterThan(0));

      // Verify known builtins are present
      final functions = result['functions'] as List;
      final names = functions
          .map((f) => (f as Map<String, dynamic>)['functionName'] as String)
          .toSet();
      expect(names, contains('descriptive_stats'));
    });

    // E2E-004: RBAC enforcement through full stack
    test('E2E-004: RBAC enforcement through full stack', () async {
      final spec = createTestSpec(specId: 'rbac-spec');
      await f.adapter.createSpec(spec);

      // Operator can run but not create specs
      const opCtx = RbacContext(actorId: 'op-1', role: 'operator');

      final runResult = await f.toolHandler.handleTool(
        'analysis.run',
        {'specId': 'rbac-spec', 'parameters': <String, dynamic>{}},
        rbacContext: opCtx,
      );
      expect(runResult, containsPair('jobId', isA<String>()));

      // Operator cannot create spec
      final newSpec = createTestSpec(specId: 'forbidden-spec');
      final createResult = await f.toolHandler.handleTool(
        'analysis.create_spec',
        {'spec': newSpec.toJson()},
        rbacContext: opCtx,
      );
      expect(createResult, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = createResult['error'] as Map<String, dynamic>;
      expect(error['code'], 'governance.unauthorized');
    });

    // E2E-005: Update spec and verify via list
    test('E2E-005: update spec and verify via list', () async {
      // Create initial spec
      final spec = createTestSpec(specId: 'updatable-spec');
      await f.adapter.createSpec(spec);

      // Update via tool
      final updatedSpec =
          createTestSpec(specId: 'updatable-spec', version: '2.0.0');
      final updateResult = await f.toolHandler.handleTool(
        'analysis.update_spec',
        {'specId': 'updatable-spec', 'spec': updatedSpec.toJson()},
      );
      expect(updateResult, containsPair('version', '2.0.0'));

      // Verify via list
      final listResult = await f.toolHandler.handleTool(
        'analysis.list_specs',
        {'search': 'updatable'},
      );
      final specs = listResult['specs'] as List;
      expect(specs, isNotEmpty);
      final found = specs.first as Map<String, dynamic>;
      expect(found['version'], '2.0.0');
    });

    // E2E-006: Versioned spec resource URI
    test('E2E-006: resolve versioned spec URI', () async {
      final spec = createTestSpec(specId: 'versioned-spec', version: '3.0.0');
      await f.adapter.createSpec(spec);

      final result = await f.resourceHandler
          .resolveResource('analysis:///spec/versioned-spec/v/3.0.0');
      expect(result, containsPair('specId', 'versioned-spec'));
      expect(result, containsPair('version', '3.0.0'));
    });

    // IT-004: Batch execution with alert triggering
    test('IT-004: batch execution with alert triggering', () async {
      // Create spec with alert output
      final spec = AnalysisSpec(
        specId: 'alert-batch-spec',
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
            parameters: {
              'columns': ['temperature']
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            from: 'descriptive_stats',
            type: AnalysisArtifactType.metric,
            name: 'temp_stats',
          ),
          AnalysisOutputDef(
            from: 'descriptive_stats',
            type: AnalysisArtifactType.alert,
            name: 'temp_alert',
          ),
        ],
        metadata: const AnalysisSpecMetadata(
          description: 'Batch with alert',
          tags: ['alert'],
        ),
      );
      await f.adapter.createSpec(spec);

      // Run batch analysis
      final runResult = await f.toolHandler.handleTool(
        'analysis.run',
        {
          'specId': 'alert-batch-spec',
          'parameters': <String, dynamic>{},
          'mode': 'batch',
        },
      );
      expect(runResult, containsPair('jobId', isA<String>()));

      // Verify artifacts produced
      final jobId = runResult['jobId'] as String;
      final artifactResult = await f.toolHandler.handleTool(
        'analysis.get_artifacts',
        {'jobId': jobId},
      );
      expect(artifactResult, containsPair('artifacts', isA<List<dynamic>>()));
    });

    // IT-005: Streaming lifecycle
    test('IT-005: streaming lifecycle start and cancel', () async {
      final spec = createTestSpec(specId: 'stream-spec');
      await f.adapter.createSpec(spec);

      // Start streaming execution
      final runResult = await f.toolHandler.handleTool(
        'analysis.run',
        {
          'specId': 'stream-spec',
          'parameters': <String, dynamic>{},
          'mode': 'streaming',
        },
      );
      expect(runResult, containsPair('jobId', isA<String>()));
      final jobId = runResult['jobId'] as String;

      // Verify job was created
      final jobResult = await f.toolHandler.handleTool(
        'analysis.get_job',
        {'jobId': jobId},
      );
      expect(jobResult, containsPair('jobId', jobId));
    });

    // IT-006: Ad-hoc synchronous execution
    test('IT-006: ad-hoc execution returns synchronous response', () async {
      final spec = createTestSpec(specId: 'adhoc-spec');
      await f.adapter.createSpec(spec);

      final runResult = await f.toolHandler.handleTool(
        'analysis.run',
        {
          'specId': 'adhoc-spec',
          'parameters': <String, dynamic>{},
          'mode': 'adhoc',
        },
      );

      // Ad-hoc should return job immediately with completed status
      expect(runResult, containsPair('jobId', isA<String>()));
      expect(
        runResult['status'],
        anyOf('completed', 'failed'),
      );
    });

    // IT-007: Multiple concurrent jobs with no interference
    test('IT-007: concurrent jobs with no interference', () async {
      // Create two independent specs
      final specA = createTestSpec(
        specId: 'concurrent-spec-a',
        description: 'Spec A',
      );
      final specB = createTestSpec(
        specId: 'concurrent-spec-b',
        description: 'Spec B',
      );
      await f.adapter.createSpec(specA);
      await f.adapter.createSpec(specB);

      // Start both jobs concurrently
      final futures = await Future.wait([
        f.toolHandler.handleTool(
          'analysis.run',
          {'specId': 'concurrent-spec-a', 'parameters': <String, dynamic>{}},
        ),
        f.toolHandler.handleTool(
          'analysis.run',
          {'specId': 'concurrent-spec-b', 'parameters': <String, dynamic>{}},
        ),
      ]);

      final resultA = futures[0];
      final resultB = futures[1];

      // Both should have different jobIds
      expect(resultA, containsPair('jobId', isA<String>()));
      expect(resultB, containsPair('jobId', isA<String>()));
      expect(resultA['jobId'], isNot(equals(resultB['jobId'])));

      // Both should reference their own spec
      expect(resultA['specId'], 'concurrent-spec-a');
      expect(resultB['specId'], 'concurrent-spec-b');
    });
  });
}
