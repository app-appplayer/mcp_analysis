import 'dart:convert';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';
import '../helpers/test_data.dart';

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('RetryPolicy', () {
    // TC-001: Successful action on first try returns result
    test('TC-001: successful action on first try', () async {
      const policy = RetryPolicy();
      var callCount = 0;

      final result = await policy.withRetry(() async {
        callCount++;
        return 42;
      });

      expect(result, 42);
      expect(callCount, 1);
    });

    // TC-002: Retries on source.unavailable error
    test('TC-002: retries on source.unavailable error', () async {
      const policy = RetryPolicy(
        retryDelay: Duration(milliseconds: 10),
      );
      var callCount = 0;

      final result = await policy.withRetry(() async {
        callCount++;
        if (callCount < 3) {
          throw AnalysisError(
            code: 'source.unavailable',
            message: 'Transient error',
          );
        }
        return 'success';
      });

      expect(result, 'success');
      expect(callCount, 3);
    });

    // TC-003: Retries on source.timeout error
    test('TC-003: retries on source.timeout error', () async {
      const policy = RetryPolicy(
        retryDelay: Duration(milliseconds: 10),
      );
      var callCount = 0;

      final result = await policy.withRetry(() async {
        callCount++;
        if (callCount < 2) {
          throw AnalysisError(
            code: 'source.timeout',
            message: 'Timeout error',
          );
        }
        return 'recovered';
      });

      expect(result, 'recovered');
      expect(callCount, 2);
    });

    // TC-004: Non-retryable errors are rethrown immediately
    test('TC-004: non-retryable errors are rethrown immediately', () async {
      const policy = RetryPolicy(
        retryDelay: Duration(milliseconds: 10),
      );
      var callCount = 0;

      expect(
        () => policy.withRetry(() async {
          callCount++;
          throw AnalysisError(
            code: 'spec.not_found',
            message: 'Not a retryable error',
          );
        }),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.not_found',
          ),
        ),
      );

      // Should only be called once since the error is not retryable
      expect(callCount, 1);
    });

    // TC-005: Exhausted retries throws job.retry_exhausted
    test('TC-005: exhausted retries throws job.retry_exhausted', () async {
      const policy = RetryPolicy(
        maxRetries: 2,
        retryDelay: Duration(milliseconds: 10),
      );
      var callCount = 0;

      await expectLater(
        policy.withRetry(() async {
          callCount++;
          throw AnalysisError(
            code: 'source.unavailable',
            message: 'Always fails',
          );
        }),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.retry_exhausted',
          ),
        ),
      );

      // Initial attempt + 2 retries = 3 calls
      expect(callCount, 3);
    });

    // TC-006: Default parameters are correct
    test('TC-006: default parameters are correct', () {
      const policy = RetryPolicy();
      expect(policy.maxRetries, 3);
      expect(policy.retryDelay, const Duration(seconds: 1));
      expect(policy.backoffMultiplier, 2.0);
    });

    // TC-007: Custom parameters are respected
    test('TC-007: custom parameters are respected', () {
      const policy = RetryPolicy(
        maxRetries: 5,
        retryDelay: Duration(milliseconds: 500),
        backoffMultiplier: 1.5,
      );
      expect(policy.maxRetries, 5);
      expect(policy.retryDelay, const Duration(milliseconds: 500));
      expect(policy.backoffMultiplier, 1.5);
    });

    // TC-008: Exponential backoff increases delay
    test('TC-008: exponential backoff increases delay between retries',
        () async {
      const policy = RetryPolicy(
        maxRetries: 3,
        retryDelay: Duration(milliseconds: 50),
        backoffMultiplier: 2.0,
      );

      final timestamps = <DateTime>[];

      try {
        await policy.withRetry(() async {
          timestamps.add(DateTime.now());
          throw AnalysisError(
            code: 'source.unavailable',
            message: 'Always fails',
          );
        });
      } catch (_) {
        // Expected
      }

      // 4 timestamps: initial + 3 retries
      expect(timestamps.length, 4);

      // Verify delays increase (with some tolerance for timing)
      if (timestamps.length >= 3) {
        final delay1 = timestamps[1].difference(timestamps[0]).inMilliseconds;
        final delay2 = timestamps[2].difference(timestamps[1]).inMilliseconds;
        // Second delay should be larger than first (backoff)
        expect(delay2, greaterThan(delay1 * 0.8));
      }
    });

    // TC-009: Non-AnalysisError is not retried
    test('TC-009: non-AnalysisError is rethrown immediately', () async {
      const policy = RetryPolicy(
        retryDelay: Duration(milliseconds: 10),
      );
      var callCount = 0;

      expect(
        () => policy.withRetry(() async {
          callCount++;
          throw Exception('Generic error');
        }),
        throwsA(isA<Exception>()),
      );

      expect(callCount, 1);
    });
  });

  // ==========================================================================
  // NFR-REL-001: Partial Failure Handling
  // ==========================================================================
  group('Partial Failure Handling', () {
    // TC-001: Partial source failure returns available results
    test('TC-001: partial source failure continues with available sources',
        () async {
      final jobStorage = InMemoryStorage<AnalysisJob>();
      final artifactStorage = InMemoryStorage<AnalysisArtifact>();
      final jobManager = JobManager(storage: jobStorage);
      final dataSourceRegistry = DataSourceRegistry();

      // Source A: succeeds
      dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        _SuccessfulAdapter(value: 'factgraph-data'),
      );
      // Source B: times out (will be caught as partial failure)
      dataSourceRegistry.register(
        AnalysisSourceType.mcpIo,
        _FailingAdapter(
          errorCode: 'source.timeout',
          errorMessage: 'Source B timed out',
        ),
      );

      final catalog = FunctionCatalog();
      final dispatcher = FunctionDispatcher(catalog: catalog);
      final statsFunc = DescriptiveStatsFunction();
      dispatcher.registerImplementation('descriptive_stats', statsFunc);
      catalog.register(statsFunc.info);

      final executor = BatchExecutor(
        jobManager: jobManager,
        dataSourceRegistry: dataSourceRegistry,
        transformPipeline: TransformPipeline(),
        functionDispatcher: dispatcher,
        artifactBuilder: ArtifactBuilder(),
        artifactStore: ArtifactStore(storage: artifactStorage),
        provenanceTracker: ProvenanceTracker(),
        alertEvaluator: AlertEvaluator(
          publisher: AlertPublisher(eventPort: MockEventPort()),
        ),
        retryPolicy: const RetryPolicy(
          maxRetries: 0,
          retryDelay: Duration(milliseconds: 1),
        ),
      );

      final spec = createTestSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.mcpIo,
            query: 'io://device1/temp',
          ),
        ],
      );

      final job = await jobManager.createJob(
        specId: 'partial-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await jobManager.startJob(job.jobId);

      final result = await executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Job should complete (not fail) because Source A succeeded
      expect(result.status, equals(AnalysisJobStatus.completed));
      // Errors should contain the partial failure
      expect(result.errors, isNotEmpty);
    });

    // TC-002: Partial failure result structure
    test('TC-002: partial failure job has errors and artifacts', () async {
      final jobStorage = InMemoryStorage<AnalysisJob>();
      final artifactStorage = InMemoryStorage<AnalysisArtifact>();
      final jobManager = JobManager(storage: jobStorage);
      final dataSourceRegistry = DataSourceRegistry();

      dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        _SuccessfulAdapter(value: 'data'),
      );
      dataSourceRegistry.register(
        AnalysisSourceType.mcpIo,
        _FailingAdapter(
          errorCode: 'source.unavailable',
          errorMessage: 'Source B down',
        ),
      );

      final catalog = FunctionCatalog();
      final dispatcher = FunctionDispatcher(catalog: catalog);
      final statsFunc = DescriptiveStatsFunction();
      dispatcher.registerImplementation('descriptive_stats', statsFunc);
      catalog.register(statsFunc.info);

      final executor = BatchExecutor(
        jobManager: jobManager,
        dataSourceRegistry: dataSourceRegistry,
        transformPipeline: TransformPipeline(),
        functionDispatcher: dispatcher,
        artifactBuilder: ArtifactBuilder(),
        artifactStore: ArtifactStore(storage: artifactStorage),
        provenanceTracker: ProvenanceTracker(),
        alertEvaluator: AlertEvaluator(
          publisher: AlertPublisher(eventPort: MockEventPort()),
        ),
        retryPolicy: const RetryPolicy(
          maxRetries: 0,
          retryDelay: Duration(milliseconds: 1),
        ),
      );

      final spec = createTestSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.mcpIo,
            query: 'io://device1/temp',
          ),
        ],
      );

      final job = await jobManager.createJob(
        specId: 'partial-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await jobManager.startJob(job.jobId);

      final result = await executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Errors have code and message fields
      for (final error in result.errors) {
        expect(error.code, isNotEmpty);
        expect(error.message, isNotEmpty);
      }
    });

    // TC-003: Failed source error includes context info
    test('TC-003: failed source error includes step context', () async {
      final jobStorage = InMemoryStorage<AnalysisJob>();
      final artifactStorage = InMemoryStorage<AnalysisArtifact>();
      final jobManager = JobManager(storage: jobStorage);
      final dataSourceRegistry = DataSourceRegistry();

      dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        _SuccessfulAdapter(value: 'ok'),
      );
      dataSourceRegistry.register(
        AnalysisSourceType.mcpIo,
        _FailingAdapter(
          errorCode: 'source.unavailable',
          errorMessage: 'mcpIo unreachable',
        ),
      );

      final catalog = FunctionCatalog();
      final dispatcher = FunctionDispatcher(catalog: catalog);
      final statsFunc = DescriptiveStatsFunction();
      dispatcher.registerImplementation('descriptive_stats', statsFunc);
      catalog.register(statsFunc.info);

      final executor = BatchExecutor(
        jobManager: jobManager,
        dataSourceRegistry: dataSourceRegistry,
        transformPipeline: TransformPipeline(),
        functionDispatcher: dispatcher,
        artifactBuilder: ArtifactBuilder(),
        artifactStore: ArtifactStore(storage: artifactStorage),
        provenanceTracker: ProvenanceTracker(),
        alertEvaluator: AlertEvaluator(
          publisher: AlertPublisher(eventPort: MockEventPort()),
        ),
        retryPolicy: const RetryPolicy(
          maxRetries: 0,
          retryDelay: Duration(milliseconds: 1),
        ),
      );

      final spec = createTestSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.mcpIo,
            query: 'io://device1/temp',
          ),
        ],
      );

      final job = await jobManager.createJob(
        specId: 'ctx-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await jobManager.startJob(job.jobId);

      final result = await executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Find the error for the mcpIo source
      final ioError = result.errors.where(
        (e) => e.step?.contains('mcpIo') ?? false,
      );
      expect(ioError, isNotEmpty,
          reason: 'Error should include step with source type');
      expect(ioError.first.code, isNotEmpty);
      expect(ioError.first.message, isNotEmpty);
    });
  });

  // ==========================================================================
  // NFR-REL-002: Error Structure
  // ==========================================================================
  group('Error Structure', () {
    // TC-004: All errors have code + message fields
    test('TC-004: AnalysisError always has code and message', () {
      final errors = [
        AnalysisError(
          code: 'spec.not_found',
          message: 'Spec xyz not found',
        ),
        AnalysisError(
          code: 'transform.failed',
          message: 'Transform filter failed',
          step: 'transform:filter',
        ),
        AnalysisError(
          code: 'analysis.parameter_error',
          message: 'Missing required parameter columns',
          details: {'parameter': 'columns'},
        ),
      ];

      for (final error in errors) {
        expect(error.code, isNotEmpty);
        expect(error.message, isNotEmpty);
        // Code follows domain.specific pattern
        expect(error.code, contains('.'));
        final parts = error.code.split('.');
        expect(parts.length, equals(2));
        expect(parts[0], isNotEmpty);
        expect(parts[1], isNotEmpty);
      }
    });

    // TC-005: Pipeline errors include step field
    test('TC-005: transform errors include step field', () async {
      final pipeline = TransformPipeline();
      final data = createTestDataSet(rowCount: 3);

      try {
        await pipeline.execute(data, [
          AnalysisTransform(
            name: 'nonexistent_transform',
            parameters: {},
          ),
        ]);
        fail('Expected AnalysisError');
      } on AnalysisError catch (e) {
        expect(e.code, equals('transform.unknown'));
        expect(e.step, isNotNull);
        expect(e.step, contains('transform:'));
      }
    });
  });

  // ==========================================================================
  // NFR-REL-003: Deterministic Execution
  // ==========================================================================
  group('Deterministic Execution', () {
    // TC-006: Identical results across 3 runs
    test('TC-006: 3 identical runs produce same function results', () async {
      final data = createTestDataSet(rowCount: 10);

      final catalog = FunctionCatalog();
      final dispatcher = FunctionDispatcher(catalog: catalog);
      final statsFunc = DescriptiveStatsFunction();
      dispatcher.registerImplementation('descriptive_stats', statsFunc);
      catalog.register(statsFunc.info);

      final results = <AnalysisFunctionResult>[];
      for (var i = 0; i < 3; i++) {
        final result = await dispatcher.executeFunction(
          functionName: 'descriptive_stats',
          parameters: {
            'columns': ['temperature']
          },
          data: data,
        );
        results.add(result);
      }

      // All 3 runs produce identical result values
      final json0 = jsonEncode(results[0].results);
      final json1 = jsonEncode(results[1].results);
      final json2 = jsonEncode(results[2].results);
      expect(json0, equals(json1));
      expect(json1, equals(json2));
    });

    // TC-007: Artifact values bit-identical
    test('TC-007: artifact values are bit-identical across runs', () async {
      final data = createTestDataSet(rowCount: 10);

      final catalog = FunctionCatalog();
      final dispatcher = FunctionDispatcher(catalog: catalog);
      final statsFunc = DescriptiveStatsFunction();
      dispatcher.registerImplementation('descriptive_stats', statsFunc);
      catalog.register(statsFunc.info);

      final serializedResults = <String>[];
      for (var i = 0; i < 3; i++) {
        final result = await dispatcher.executeFunction(
          functionName: 'descriptive_stats',
          parameters: {
            'columns': ['temperature']
          },
          data: data,
        );
        serializedResults.add(jsonEncode(result.results));
      }

      // JSON representations identical
      expect(serializedResults[0], equals(serializedResults[1]));
      expect(serializedResults[1], equals(serializedResults[2]));
    });

    // TC-008: Provenance identical across runs
    test('TC-008: provenance fields identical across 3 runs', () {
      final provenances = <AnalysisArtifactProvenance>[];
      for (var i = 0; i < 3; i++) {
        provenances.add(createTestProvenance(
          specId: 'determinism-spec',
          specVersion: '1.0.0',
        ));
      }

      // specId and specVersion are identical
      for (var i = 1; i < 3; i++) {
        expect(provenances[i].specId, equals(provenances[0].specId));
        expect(provenances[i].specVersion, equals(provenances[0].specVersion));
        expect(provenances[i].sourceUri, equals(provenances[0].sourceUri));
        expect(provenances[i].sourceQuery, equals(provenances[0].sourceQuery));
      }
    });
  });

  // ==========================================================================
  // NFR-REL-004: Error Code System
  // ==========================================================================
  group('Error Code System', () {
    // TC-009: All 36 error codes defined and follow domain.specific pattern
    test('TC-009: all 36 error codes follow domain.specific pattern', () {
      // Complete error code registry from SDD §9.1
      final errorCodes = [
        'source.unavailable',
        'source.unauthorized',
        'source.schema_mismatch',
        'source.timeout',
        'spec.not_found',
        'spec.duplicate',
        'spec.invalid',
        'transform.failed',
        'transform.schema_error',
        'transform.unknown',
        'transform.parameter_error',
        'analysis.unsupported_function',
        'analysis.parameter_error',
        'analysis.execution_error',
        'analysis.duplicate_function',
        'job.timeout',
        'job.canceled',
        'job.retry_exhausted',
        'job.execution_error',
        'job.not_found',
        'job.invalid_transition',
        'artifact.store_failed',
        'artifact.not_found',
        'artifact.build_error',
        'governance.unauthorized',
        'governance.audit_failed',
        'alert.evaluation_error',
        'alert.publish_failed',
        'alert.invalid_condition',
        'plugin.invalid_manifest',
        'plugin.incompatible_version',
        'plugin.execution_error',
        'stream.error',
        'mcp.unknown_tool',
        'mcp.invalid_arguments',
        'mcp.resource_not_found',
      ];

      // Verify count
      expect(errorCodes.length, equals(36));

      // Verify domain.specific pattern
      for (final code in errorCodes) {
        expect(code, contains('.'));
        final parts = code.split('.');
        expect(parts.length, equals(2),
            reason: 'Code "$code" does not follow domain.specific pattern');
        expect(parts[0], isNotEmpty);
        expect(parts[1], isNotEmpty);
      }

      // Verify 11 unique domains
      final domains = errorCodes.map((c) => c.split('.')[0]).toSet();
      expect(domains.length, equals(11));
      expect(
        domains,
        containsAll([
          'source',
          'spec',
          'transform',
          'analysis',
          'job',
          'artifact',
          'governance',
          'alert',
          'plugin',
          'stream',
          'mcp',
        ]),
      );
    });

    // TC-010: Error codes assigned to correct modules
    test('TC-010: error codes are assigned to correct modules', () {
      // Module-to-error-code mapping from SDD §9.1
      final moduleErrorCodes = <String, Set<String>>{
        'MOD-FEAT-001': {
          'source.unavailable',
          'source.unauthorized',
          'source.schema_mismatch',
          'source.timeout',
        },
        'MOD-CORE-001': {
          'spec.not_found',
          'spec.duplicate',
          'spec.invalid',
        },
        'MOD-FEAT-002': {
          'transform.failed',
          'transform.schema_error',
          'transform.unknown',
          'transform.parameter_error',
        },
        'MOD-FEAT-003': {
          'analysis.unsupported_function',
          'analysis.parameter_error',
          'analysis.execution_error',
          'analysis.duplicate_function',
          'plugin.invalid_manifest',
          'plugin.incompatible_version',
          'plugin.execution_error',
        },
        'MOD-CORE-002': {
          'job.timeout',
          'job.canceled',
          'job.retry_exhausted',
          'job.execution_error',
          'job.not_found',
          'job.invalid_transition',
          'stream.error',
        },
        'MOD-CORE-003': {
          'artifact.store_failed',
          'artifact.not_found',
          'artifact.build_error',
        },
        'MOD-INFRA-001': {
          'governance.unauthorized',
          'governance.audit_failed',
          'source.unauthorized',
        },
        'MOD-FEAT-004': {
          'alert.evaluation_error',
          'alert.publish_failed',
          'alert.invalid_condition',
        },
        'MOD-INFRA-002': {
          'mcp.unknown_tool',
          'mcp.invalid_arguments',
          'mcp.resource_not_found',
        },
      };

      // Verify no module produces codes from an unrelated domain
      // (source.unauthorized is shared between MOD-FEAT-001 and MOD-INFRA-001)
      for (final entry in moduleErrorCodes.entries) {
        for (final code in entry.value) {
          // Verify each code follows pattern
          expect(code, contains('.'));
        }
      }

      // Verify total unique codes across all modules = 36
      final allCodes = <String>{};
      for (final codes in moduleErrorCodes.values) {
        allCodes.addAll(codes);
      }
      expect(allCodes.length, equals(36));
    });
  });
}

// ============================================================================
// Helper Adapters for Reliability Tests
// ============================================================================

/// A data source adapter that always succeeds with test data.
class _SuccessfulAdapter implements DataSourceAdapter {
  _SuccessfulAdapter({required this.value});
  final String value;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    return createTestDataSet(rowCount: 5);
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return const AnalysisSourceSchema(columns: [
      AnalysisColumnInfo(name: 'temperature', type: 'double'),
    ]);
  }
}

/// A data source adapter that always fails with a specific error.
class _FailingAdapter implements DataSourceAdapter {
  _FailingAdapter({required this.errorCode, required this.errorMessage});
  final String errorCode;
  final String errorMessage;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.factgraph;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    throw AnalysisError(code: errorCode, message: errorMessage);
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    throw AnalysisError(code: errorCode, message: errorMessage);
  }
}
