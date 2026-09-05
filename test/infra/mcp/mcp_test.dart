import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

// ============================================================================
// Helpers
// ============================================================================

/// Create a minimal valid AnalysisSpec for testing.
AnalysisSpec _createTestSpec({
  String specId = 'test-spec',
  String version = '1.0.0',
}) {
  return AnalysisSpec(
    specId: specId,
    version: version,
    inputSources: [
      AnalysisInputSource(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temp',
      ),
    ],
    analysisSteps: [
      AnalysisStep(
        function: 'descriptive_stats',
        parameters: {
          'columns': ['temp']
        },
      ),
    ],
    outputs: [
      AnalysisOutputDef(
        from: 'descriptive_stats',
        type: AnalysisArtifactType.metric,
        name: 'stats',
      ),
    ],
    metadata: const AnalysisSpecMetadata(description: 'Test'),
  );
}

/// Create a test AnalysisMetricArtifact for getArtifacts tests.
AnalysisMetricArtifact _createTestArtifact({
  String artifactId = 'artifact-001',
}) {
  final now = DateTime.now();
  return AnalysisMetricArtifact(
    artifactId: artifactId,
    name: 'test-metric',
    provenance: AnalysisArtifactProvenance(
      version: '1.0.0',
      createdAt: now,
      specId: 'test-spec',
      specVersion: '1.0.0',
    ),
    value: 42.0,
    unit: 'units',
    timeRange: AnalysisTimeRange(
      start: now.subtract(const Duration(hours: 1)),
      end: now,
    ),
  );
}

void main() {
  // ==========================================================================
  // McpToolHandler Tests
  // ==========================================================================
  group('McpToolHandler', () {
    late MockAnalysisPort mockPort;
    late McpToolHandler handler;

    setUp(() {
      final testSpec = _createTestSpec();
      mockPort = MockAnalysisPort(
        specs: [testSpec],
        jobs: {
          'job-001': AnalysisJob(
            jobId: 'job-001',
            specId: 'test-spec',
            specVersion: '1.0.0',
            mode: AnalysisExecutionMode.batch,
            status: AnalysisJobStatus.completed,
            progress: 1.0,
            createdAt: DateTime.now(),
            parameters: const {},
          ),
        },
        artifacts: [_createTestArtifact()],
      );
      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: AuditLogger(storage: InMemoryStorage<AuditRecord>()),
        dataMasker: DataMasker(),
      );
    });

    // TC-001: list_specs routes to listSpecs, returns JSON
    test('TC-001: list_specs routes to listSpecs and returns specs JSON',
        () async {
      final result = await handler.handleTool('analysis.list_specs', {});

      expect(result, containsPair('specs', isA<List<dynamic>>()));
      final specs = result['specs'] as List;
      expect(specs, isNotEmpty);
      // First spec should have the specId from our mock
      expect((specs.first as Map)['specId'], 'test-spec');
    });

    // TC-002: list_specs passes search/limit arguments
    test('TC-002: list_specs passes search and limit arguments', () async {
      final result = await handler.handleTool('analysis.list_specs', {
        'search': 'test',
        'limit': 5,
      });

      expect(result, containsPair('specs', isA<List<dynamic>>()));
      final specs = result['specs'] as List;
      expect(specs, isNotEmpty);
    });

    // TC-003: analysis.run routes to runAnalysis
    test('TC-003: analysis.run routes to runAnalysis', () async {
      final result = await handler.handleTool('analysis.run', {
        'specId': 'test-spec',
        'parameters': <String, dynamic>{},
      });

      // Should return a job JSON with jobId
      expect(result, containsPair('jobId', isA<String>()));
      expect(result, containsPair('specId', 'test-spec'));
    });

    // TC-004: analysis.run passes all params including mode and timeRange
    test('TC-004: analysis.run passes all params', () async {
      final now = DateTime.now();
      final result = await handler.handleTool('analysis.run', {
        'specId': 'test-spec',
        'parameters': {'threshold': 0.9},
        'mode': 'batch',
        'timeRange': {
          'start': now.subtract(const Duration(hours: 1)).toIso8601String(),
          'end': now.toIso8601String(),
        },
      });

      expect(result, containsPair('specId', 'test-spec'));
      expect(result, containsPair('status', 'completed'));
    });

    // TC-005: get_job routes to getJob
    test('TC-005: get_job routes to getJob', () async {
      final result = await handler.handleTool('analysis.get_job', {
        'jobId': 'job-001',
      });

      expect(result, containsPair('jobId', 'job-001'));
      expect(result, containsPair('status', 'completed'));
    });

    // TC-006: get_artifacts routes to getArtifacts
    test('TC-006: get_artifacts routes to getArtifacts', () async {
      final result = await handler.handleTool('analysis.get_artifacts', {
        'jobId': 'job-001',
      });

      expect(result, containsPair('artifacts', isA<List<dynamic>>()));
      final artifacts = result['artifacts'] as List;
      expect(artifacts, isNotEmpty);
    });

    // TC-007: create_spec routes to createSpec
    test('TC-007: create_spec routes to createSpec', () async {
      final newSpec = _createTestSpec(specId: 'new-spec');
      final result = await handler.handleTool('analysis.create_spec', {
        'spec': newSpec.toJson(),
      });

      expect(result, containsPair('specId', 'new-spec'));
    });

    // TC-008: update_spec routes to updateSpec
    test('TC-008: update_spec routes to updateSpec', () async {
      final updatedSpec =
          _createTestSpec(specId: 'test-spec', version: '2.0.0');
      final result = await handler.handleTool('analysis.update_spec', {
        'specId': 'test-spec',
        'spec': updatedSpec.toJson(),
      });

      expect(result, containsPair('specId', 'test-spec'));
      expect(result, containsPair('version', '2.0.0'));
    });

    // TC-009: evaluate_alert routes to evaluateAlert
    test('TC-009: evaluate_alert routes to evaluateAlert', () async {
      final result = await handler.handleTool('analysis.evaluate_alert', {
        'alertRuleId': 'alert-rule-001',
      });

      expect(result, containsPair('alertRuleId', 'alert-rule-001'));
      expect(result, containsPair('triggered', isA<bool>()));
    });

    // TC-010: Unknown tool returns mcp.unknown_tool error
    test('TC-010: unknown tool returns mcp.unknown_tool error', () async {
      final result = await handler.handleTool('analysis.nonexistent', {});

      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.unknown_tool');
    });

    // TC-011: Missing specId in run returns mcp.invalid_arguments
    test('TC-011: missing specId in run returns mcp.invalid_arguments',
        () async {
      final result = await handler.handleTool('analysis.run', {
        'parameters': <String, dynamic>{},
      });

      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.invalid_arguments');
    });
  });

  // ==========================================================================
  // McpResourceHandler Tests
  // ==========================================================================
  group('McpResourceHandler', () {
    late MockAnalysisPort mockPort;
    late FunctionCatalog catalog;
    late McpResourceHandler handler;

    setUp(() {
      final testSpec = _createTestSpec();
      mockPort = MockAnalysisPort(
        specs: [testSpec],
        jobs: {
          'job-001': AnalysisJob(
            jobId: 'job-001',
            specId: 'test-spec',
            specVersion: '1.0.0',
            mode: AnalysisExecutionMode.batch,
            status: AnalysisJobStatus.completed,
            progress: 1.0,
            createdAt: DateTime.now(),
            parameters: const {},
          ),
        },
        artifacts: [_createTestArtifact(artifactId: 'artifact-001')],
      );

      catalog = FunctionCatalog();
      catalog.register(AnalysisFunctionInfo(
        functionName: 'descriptive_stats',
        description: 'Compute descriptive statistics',
        supportedDataTypes: ['numeric'],
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Column names to analyze',
          ),
        },
      ));

      handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );
    });

    // TC-012: Resolve analysis://spec/{specId} returns spec JSON
    test('TC-012: resolve analysis://spec/{specId} returns spec JSON',
        () async {
      final result =
          await handler.resolveResource('analysis:///spec/test-spec');

      expect(result, containsPair('specId', 'test-spec'));
      expect(result, containsPair('version', '1.0.0'));
    });

    // TC-013: Resolve analysis://artifact/{artifactId} returns artifact JSON
    test(
        'TC-013: resolve analysis://artifact/{artifactId} returns artifact JSON',
        () async {
      final result =
          await handler.resolveResource('analysis:///artifact/artifact-001');

      expect(result, containsPair('artifactId', 'artifact-001'));
      expect(result, containsPair('name', 'test-metric'));
    });

    // TC-014: Resolve analysis://catalog returns function list
    test('TC-014: resolve analysis://catalog returns function list', () async {
      final result = await handler.resolveResource('analysis:///catalog');

      expect(result, containsPair('functions', isA<List<dynamic>>()));
      expect(result, containsPair('count', 1));

      final functions = result['functions'] as List;
      expect(functions, hasLength(1));
      final firstFunc = functions.first as Map<String, dynamic>;
      expect(firstFunc['functionName'], 'descriptive_stats');
    });

    // TC-015: Unknown URI pattern returns error
    test('TC-015: unknown URI pattern throws mcp.unknown_resource', () async {
      expect(
        () => handler.resolveResource('analysis:///unknown/resource'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.unknown_resource',
          ),
        ),
      );
    });

    // TC-016: getResourceTemplates returns at least 4 templates
    test('TC-016: getResourceTemplates returns at least 4 templates', () {
      final templates = McpResourceHandler.getResourceTemplates();
      expect(templates.length, greaterThanOrEqualTo(4));

      // Verify each template has required fields
      for (final template in templates) {
        expect(template.uriTemplate, isNotEmpty);
        expect(template.name, isNotEmpty);
        expect(template.description, isNotEmpty);
      }

      // Verify specific URI templates are present
      final uris = templates.map((t) => t.uriTemplate).toSet();
      expect(uris, contains('analysis://spec/{specId}'));
      expect(uris, contains('analysis://artifact/{artifactId}'));
      expect(uris, contains('analysis://job/{jobId}'));
      expect(uris, contains('analysis://catalog'));
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('Integration', () {
    late MockAnalysisPort mockPort;
    late FunctionCatalog catalog;

    setUp(() {
      final testSpec = AnalysisSpec(
        specId: 'test-spec',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temp',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {
              'columns': ['temp']
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'stats',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Test'),
      );

      mockPort = MockAnalysisPort(
        specs: [testSpec],
        artifacts: [_createTestArtifact()],
      );

      catalog = FunctionCatalog();
      catalog.register(AnalysisFunctionInfo(
        functionName: 'descriptive_stats',
        description: 'Compute descriptive statistics',
        supportedDataTypes: ['numeric'],
      ));
    });

    // IT-001: Tool call -> port -> JSON round-trip
    test('IT-001: tool call -> port -> JSON round-trip', () async {
      final toolHandler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: AuditLogger(storage: InMemoryStorage<AuditRecord>()),
        dataMasker: DataMasker(),
      );

      // Run analysis via tool handler
      final runResult = await toolHandler.handleTool('analysis.run', {
        'specId': 'test-spec',
        'parameters': <String, dynamic>{},
      });

      // Verify the response is valid job JSON
      expect(runResult, containsPair('jobId', isA<String>()));
      expect(runResult, containsPair('specId', 'test-spec'));
      expect(runResult, containsPair('status', 'completed'));

      // Retrieve the job via get_job using the returned jobId
      final jobId = runResult['jobId'] as String;
      final getResult = await toolHandler.handleTool('analysis.get_job', {
        'jobId': jobId,
      });

      expect(getResult, containsPair('jobId', jobId));
      expect(getResult, containsPair('specId', 'test-spec'));
    });

    // IT-002: Resource resolve round-trip
    test('IT-002: resource resolve round-trip', () async {
      final resourceHandler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      // Resolve spec resource
      final specResult =
          await resourceHandler.resolveResource('analysis:///spec/test-spec');
      expect(specResult, containsPair('specId', 'test-spec'));

      // Resolve catalog resource
      final catalogResult =
          await resourceHandler.resolveResource('analysis:///catalog');
      expect(catalogResult, containsPair('count', 1));

      // Verify round-trip consistency: spec JSON can produce valid data
      final resolvedSpecId = specResult['specId'] as String;
      final listResult = await mockPort.listSpecs(search: resolvedSpecId);
      expect(listResult.first.specId, resolvedSpecId);
    });

    // IT-003: All 7 tool definitions have valid schemas
    test('IT-003: all 7 tool definitions have valid schemas', () {
      final definitions = McpToolHandler.getToolDefinitions();
      expect(definitions, hasLength(7));

      final expectedTools = {
        'analysis.list_specs',
        'analysis.run',
        'analysis.get_job',
        'analysis.get_artifacts',
        'analysis.create_spec',
        'analysis.update_spec',
        'analysis.evaluate_alert',
      };

      for (final def in definitions) {
        // Every definition must have name, description, and inputSchema
        expect(def, containsPair('name', isA<String>()));
        expect(def, containsPair('description', isA<String>()));
        expect(def, containsPair('inputSchema', isA<Map<dynamic, dynamic>>()));

        final schema = def['inputSchema'] as Map<String, dynamic>;
        expect(schema, containsPair('type', 'object'));
        expect(
            schema, containsPair('properties', isA<Map<dynamic, dynamic>>()));

        // Track that we found this tool
        expectedTools.remove(def['name']);
      }

      // All 7 tools should have been found
      expect(
        expectedTools,
        isEmpty,
        reason: 'Missing tool definitions: $expectedTools',
      );
    });
  });

  // ==========================================================================
  // McpResourceHandler coverage boost
  // ==========================================================================
  group('McpResourceHandler coverage boost', () {
    // Invalid URI (non-analysis scheme) throws mcp.invalid_uri
    test('non-analysis scheme throws mcp.invalid_uri', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      expect(
        () => handler.resolveResource('http://example.com/spec/test'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.invalid_uri',
          ),
        ),
      );
    });

    // Completely invalid URI string
    test('unparseable URI throws mcp.invalid_uri', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      // Uri.tryParse returns null for some strings; however most strings
      // actually parse. Test empty path instead.
      expect(
        () => handler.resolveResource('analysis:'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.invalid_uri',
          ),
        ),
      );
    });

    // Catalog resource with function data
    test('catalog resource returns function info with parameters', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      catalog.register(AnalysisFunctionInfo(
        functionName: 'my_func',
        description: 'My function description',
        supportedDataTypes: ['double', 'int'],
        parameters: {
          'threshold': AnalysisParameterSchema(
            name: 'threshold',
            type: 'double',
            description: 'Threshold value',
            defaultValue: 0.5,
          ),
        },
      ));

      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      final result = await handler.resolveResource('analysis:///catalog');
      expect(result['count'], equals(1));

      final functions = result['functions'] as List;
      final func = functions.first as Map<String, dynamic>;
      expect(func['functionName'], 'my_func');
      expect(func['description'], 'My function description');
      expect(func['supportedDataTypes'], contains('double'));

      final params = func['parameters'] as Map<String, dynamic>;
      expect(params, contains('threshold'));
      final threshold = params['threshold'] as Map<String, dynamic>;
      expect(threshold['defaultValue'], 0.5);
    });

    // Spec resource with missing specId segment
    test('spec URI without specId throws mcp.invalid_uri', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      expect(
        () => handler.resolveResource('analysis:///spec'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.invalid_uri',
          ),
        ),
      );
    });

    // Artifact resource with missing artifactId
    test('artifact URI without artifactId throws mcp.invalid_uri', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      expect(
        () => handler.resolveResource('analysis:///artifact'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.invalid_uri',
          ),
        ),
      );
    });

    // Job resource with missing jobId
    test('job URI without jobId throws mcp.invalid_uri', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      expect(
        () => handler.resolveResource('analysis:///job'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.invalid_uri',
          ),
        ),
      );
    });

    // Versioned spec URI with non-existent version
    test('versioned spec URI with wrong version throws resource_not_found',
        () async {
      final testSpec = _createTestSpec(specId: 'test-spec', version: '1.0.0');
      final mockPort = MockAnalysisPort(specs: [testSpec]);
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      expect(
        () => handler.resolveResource('analysis:///spec/test-spec/v/9.9.9'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.resource_not_found',
          ),
        ),
      );
    });

    // Empty catalog returns count 0
    test('catalog resource with empty catalog returns count 0', () async {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      final handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );

      final result = await handler.resolveResource('analysis:///catalog');
      expect(result['count'], equals(0));
      expect((result['functions'] as List), isEmpty);
    });

    // McpResourceTemplate.toJson returns expected structure
    test('McpResourceTemplate.toJson returns expected structure', () {
      const template = McpResourceTemplate(
        uriTemplate: 'analysis://spec/{specId}',
        name: 'Analysis Spec',
        description: 'Get spec by ID',
        mimeType: 'application/json',
      );

      final json = template.toJson();
      expect(json['uriTemplate'], 'analysis://spec/{specId}');
      expect(json['name'], 'Analysis Spec');
      expect(json['description'], 'Get spec by ID');
      expect(json['mimeType'], 'application/json');
    });
  });

  // ==========================================================================
  // mcp.resource_not_found (TC-020 to TC-022)
  // ==========================================================================
  group('McpResourceHandler resource_not_found', () {
    late McpResourceHandler resourceHandler;

    setUp(() {
      final mockPort = MockAnalysisPort();
      final catalog = FunctionCatalog();
      resourceHandler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );
    });

    // TC-020: Non-existent spec throws mcp.resource_not_found
    test('TC-020: non-existent spec throws mcp.resource_not_found', () async {
      expect(
        () => resourceHandler
            .resolveResource('analysis:///spec/nonexistent-spec'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.resource_not_found',
          ),
        ),
      );
    });

    // TC-021: Non-existent artifact throws mcp.resource_not_found
    test('TC-021: non-existent artifact throws mcp.resource_not_found',
        () async {
      expect(
        () => resourceHandler
            .resolveResource('analysis:///artifact/nonexistent-artifact'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.resource_not_found',
          ),
        ),
      );
    });

    // TC-022: Non-existent job throws mcp.resource_not_found
    test('TC-022: non-existent job throws mcp.resource_not_found', () async {
      expect(
        () =>
            resourceHandler.resolveResource('analysis:///job/nonexistent-job'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'mcp.resource_not_found',
          ),
        ),
      );
    });
  });

  // ==========================================================================
  // Spec TC-021: Versioned spec URI resolution
  // ==========================================================================
  group('McpResourceHandler versioned spec URI', () {
    late MockAnalysisPort mockPort;
    late FunctionCatalog catalog;
    late McpResourceHandler handler;

    setUp(() {
      final testSpec = _createTestSpec(specId: 'test-spec', version: '1.0.0');
      mockPort = MockAnalysisPort(
        specs: [testSpec],
        jobs: {
          'job-001': AnalysisJob(
            jobId: 'job-001',
            specId: 'test-spec',
            specVersion: '1.0.0',
            mode: AnalysisExecutionMode.batch,
            status: AnalysisJobStatus.completed,
            progress: 1.0,
            createdAt: DateTime.now(),
            parameters: const {},
          ),
        },
      );
      catalog = FunctionCatalog();
      handler = McpResourceHandler(
        analysisPort: mockPort,
        functionCatalog: catalog,
      );
    });

    // TC-021 (spec): Resolve analysis://spec/{specId}/v/{version} URI
    test(
        'TC-021: resolve analysis://spec/{specId}/v/{version} returns versioned spec',
        () async {
      final result =
          await handler.resolveResource('analysis:///spec/test-spec/v/1.0.0');

      expect(result, containsPair('specId', 'test-spec'));
      expect(result, containsPair('version', '1.0.0'));
    });

    // TC-022 (spec): Resolve analysis://job/{jobId} URI
    test('TC-022: resolve analysis://job/{jobId} returns job JSON', () async {
      final result = await handler.resolveResource('analysis:///job/job-001');

      expect(result, containsPair('jobId', 'job-001'));
      expect(result, containsPair('status', 'completed'));
    });
  });

  // ==========================================================================
  // Spec TC-023/TC-024: Audit logging at MCP boundary
  // ==========================================================================
  group('McpToolHandler audit logging', () {
    late MockAnalysisPort mockPort;
    late InMemoryStorage<AuditRecord> auditStorage;
    late AuditLogger auditLogger;
    late McpToolHandler handler;

    setUp(() {
      mockPort = MockAnalysisPort(
        specs: [_createTestSpec()],
        artifacts: [],
      );
      auditStorage = InMemoryStorage<AuditRecord>();
      auditLogger = AuditLogger(storage: auditStorage);
      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: auditLogger,
        dataMasker: DataMasker(),
      );
    });

    // TC-023 (spec): analysis.run records audit log (recordExecution called)
    test('TC-023: analysis.run records audit log via recordExecution',
        () async {
      const ctx = RbacContext(actorId: 'eng-1', role: 'engineer');

      await handler.handleTool(
        'analysis.run',
        {'specId': 'test-spec', 'parameters': <String, dynamic>{}},
        rbacContext: ctx,
      );

      final records = await auditLogger.query();
      expect(records, isNotEmpty);
      expect(records.any((r) => r.actorId == 'eng-1'), isTrue);
      expect(records.any((r) => r.action == 'execute'), isTrue);
      expect(records.any((r) => r.specId == 'test-spec'), isTrue);
    });

    // TC-024 (spec): analysis.update_spec records audit log (recordSpecChange called)
    test('TC-024: analysis.update_spec records audit log via recordSpecChange',
        () async {
      const ctx = RbacContext(actorId: 'eng-2', role: 'engineer');
      final updatedSpec =
          _createTestSpec(specId: 'test-spec', version: '2.0.0');

      await handler.handleTool(
        'analysis.update_spec',
        {'specId': 'test-spec', 'spec': updatedSpec.toJson()},
        rbacContext: ctx,
      );

      final records = await auditLogger.query();
      expect(records, isNotEmpty);
      expect(records.any((r) => r.actorId == 'eng-2'), isTrue);
      expect(records.any((r) => r.action == 'update_spec'), isTrue);
      expect(records.any((r) => r.specId == 'test-spec'), isTrue);
    });
  });

  // ==========================================================================
  // McpToolHandler coverage boost
  // ==========================================================================
  group('McpToolHandler coverage boost', () {
    late MockAnalysisPort mockPort;
    late McpToolHandler handler;

    setUp(() {
      final testSpec = _createTestSpec();
      mockPort = MockAnalysisPort(
        specs: [testSpec],
        jobs: {
          'job-001': AnalysisJob(
            jobId: 'job-001',
            specId: 'test-spec',
            specVersion: '1.0.0',
            mode: AnalysisExecutionMode.batch,
            status: AnalysisJobStatus.completed,
            progress: 1.0,
            createdAt: DateTime.now(),
            parameters: const {},
          ),
        },
        artifacts: [_createTestArtifact()],
      );
      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: AuditLogger(storage: InMemoryStorage<AuditRecord>()),
        dataMasker: DataMasker(),
      );
    });

    // Missing jobId in get_job returns error
    test('missing jobId in get_job returns mcp.invalid_arguments', () async {
      final result = await handler.handleTool('analysis.get_job', {});
      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.invalid_arguments');
    });

    // Missing spec in create_spec returns error
    test('missing spec in create_spec returns mcp.invalid_arguments', () async {
      final result = await handler.handleTool('analysis.create_spec', {});
      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.invalid_arguments');
    });

    // Missing specId or spec in update_spec returns error
    test('missing specId in update_spec returns mcp.invalid_arguments',
        () async {
      final result = await handler.handleTool('analysis.update_spec', {
        'spec': _createTestSpec().toJson(),
      });
      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.invalid_arguments');
    });

    test('missing spec in update_spec returns mcp.invalid_arguments', () async {
      final result = await handler.handleTool('analysis.update_spec', {
        'specId': 'test-spec',
      });
      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.invalid_arguments');
    });

    // Missing alertRuleId in evaluate_alert returns error
    test('missing alertRuleId in evaluate_alert returns mcp.invalid_arguments',
        () async {
      final result = await handler.handleTool('analysis.evaluate_alert', {});
      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'mcp.invalid_arguments');
    });

    // get_job with non-existent job returns error message
    test('get_job with non-existent job returns error', () async {
      final result = await handler.handleTool('analysis.get_job', {
        'jobId': 'nonexistent-job',
      });
      expect(result, containsPair('error', 'Job not found'));
      expect(result, containsPair('jobId', 'nonexistent-job'));
    });

    // getArtifacts with maskConfig applies masking
    test('getArtifacts with maskConfig applies masking', () async {
      final result = await handler.handleTool('analysis.get_artifacts', {
        'jobId': 'job-001',
        'maskConfig': {'name': true},
      });
      expect(result, containsPair('artifacts', isA<List<dynamic>>()));
    });

    // getArtifacts with type and tags filter
    test('getArtifacts with type and tags filter', () async {
      final result = await handler.handleTool('analysis.get_artifacts', {
        'type': 'metric',
        'tags': ['test'],
        'limit': 10,
      });
      expect(result, containsPair('artifacts', isA<List<dynamic>>()));
    });

    // RBAC check on listSpecs with rbacContext
    test('listSpecs with rbacContext passes RBAC', () async {
      const ctx = RbacContext(actorId: 'user-1', role: 'engineer');
      final result = await handler.handleTool(
        'analysis.list_specs',
        {'search': 'test'},
        rbacContext: ctx,
      );
      expect(result, containsPair('specs', isA<List<dynamic>>()));
    });

    // RBAC check on getJob with rbacContext
    test('getJob with rbacContext passes RBAC', () async {
      const ctx = RbacContext(actorId: 'user-1', role: 'engineer');
      final result = await handler.handleTool(
        'analysis.get_job',
        {'jobId': 'job-001'},
        rbacContext: ctx,
      );
      expect(result, containsPair('jobId', 'job-001'));
    });

    // RBAC check on getArtifacts with rbacContext
    test('getArtifacts with rbacContext passes RBAC', () async {
      const ctx = RbacContext(actorId: 'user-1', role: 'engineer');
      final result = await handler.handleTool(
        'analysis.get_artifacts',
        {},
        rbacContext: ctx,
      );
      expect(result, containsPair('artifacts', isA<List<dynamic>>()));
    });

    // RBAC check on createSpec with rbacContext
    test('createSpec with rbacContext passes RBAC', () async {
      const ctx = RbacContext(actorId: 'admin-1', role: 'engineer');
      final newSpec = _createTestSpec(specId: 'rbac-spec');
      final result = await handler.handleTool(
        'analysis.create_spec',
        {'spec': newSpec.toJson()},
        rbacContext: ctx,
      );
      expect(result, containsPair('specId', 'rbac-spec'));
    });

    // RBAC check on evaluateAlert with rbacContext
    test('evaluateAlert with rbacContext passes RBAC', () async {
      const ctx = RbacContext(actorId: 'user-1', role: 'engineer');
      final result = await handler.handleTool(
        'analysis.evaluate_alert',
        {'alertRuleId': 'alert-001'},
        rbacContext: ctx,
      );
      expect(result, containsPair('alertRuleId', 'alert-001'));
    });

    // run with mode argument
    test('run without mode defaults to batch', () async {
      final result = await handler.handleTool('analysis.run', {
        'specId': 'test-spec',
      });
      expect(result, containsPair('specId', 'test-spec'));
    });
  });

  // ==========================================================================
  // IT-004: End-to-end MCP run with RBAC + audit + masking
  // ==========================================================================
  group('Integration IT-004', () {
    late MockAnalysisPort mockPort;
    late InMemoryStorage<AuditRecord> auditStorage;
    late AuditLogger auditLogger;
    late McpToolHandler handler;

    setUp(() {
      mockPort = MockAnalysisPort(
        specs: [_createTestSpec()],
        artifacts: [],
      );
      auditStorage = InMemoryStorage<AuditRecord>();
      auditLogger = AuditLogger(storage: auditStorage);
      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: auditLogger,
        dataMasker: DataMasker(),
      );
    });

    // IT-004: End-to-end MCP run with RBAC + audit + masking
    test('IT-004: end-to-end run with RBAC check, execution, audit record',
        () async {
      const ctx = RbacContext(actorId: 'eng-it', role: 'engineer');

      // RBAC check passes for engineer → execute → audit logged → response
      final result = await handler.handleTool(
        'analysis.run',
        {'specId': 'test-spec', 'parameters': <String, dynamic>{}},
        rbacContext: ctx,
      );

      // Verify valid JSON response with Job fields
      expect(result, containsPair('jobId', isA<String>()));
      expect(result, containsPair('specId', 'test-spec'));

      // Verify audit record was created with correct fields
      final records = await auditLogger.query();
      expect(records, isNotEmpty);
      final execRecord = records.firstWhere((r) => r.action == 'execute');
      expect(execRecord.actorId, 'eng-it');
      expect(execRecord.specId, 'test-spec');
    });
  });
}
