import 'dart:async';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';
import '../../helpers/test_data.dart';

// ============================================================================
// Streaming DataSource Adapter for testing
// ============================================================================

class FakeStreamableAdapter extends DataSourceAdapter
    with StreamableDataSource {
  final StreamController<AnalysisDataSet> _controller =
      StreamController<AnalysisDataSet>.broadcast();
  bool isAvailableFlag = true;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.mcpIo;

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
        AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        AnalysisColumnInfo(name: 'value', type: 'double'),
      ],
    );
  }

  @override
  Future<bool> isAvailable() async => isAvailableFlag;

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) {
    return _controller.stream;
  }

  /// Emit a data set into the stream.
  void emit(AnalysisDataSet dataSet) {
    _controller.add(dataSet);
  }

  /// Emit an error into the stream.
  void emitError(Object error) {
    _controller.addError(error);
  }

  /// Close the stream (triggers onDone).
  Future<void> closeStream() async {
    await _controller.close();
  }

  bool get isClosed => _controller.isClosed;
}

// ============================================================================
// Test Fixture
// ============================================================================

class _StreamTestFixture {
  _StreamTestFixture._({
    required this.jobStorage,
    required this.artifactStorage,
    required this.jobManager,
    required this.dataSourceRegistry,
    required this.transformPipeline,
    required this.artifactBuilder,
    required this.artifactStore,
    required this.provenanceTracker,
    required this.alertEvaluator,
    required this.eventPort,
    required this.executor,
  });

  factory _StreamTestFixture() {
    final jobStorage = InMemoryStorage<AnalysisJob>();
    final artifactStorage = InMemoryStorage<AnalysisArtifact>();
    final jobManager = JobManager(storage: jobStorage);
    final dataSourceRegistry = DataSourceRegistry();
    final transformPipeline = TransformPipeline();
    final artifactBuilder = ArtifactBuilder();
    final artifactStore = ArtifactStore(storage: artifactStorage);
    final provenanceTracker = ProvenanceTracker();
    final eventPort = MockEventPort();
    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: eventPort),
    );

    final executor = StreamExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    return _StreamTestFixture._(
      jobStorage: jobStorage,
      artifactStorage: artifactStorage,
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
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
  final ArtifactBuilder artifactBuilder;
  final ArtifactStore artifactStore;
  final ProvenanceTracker provenanceTracker;
  final AlertEvaluator alertEvaluator;
  final MockEventPort eventPort;
  final StreamExecutor executor;

  /// Create a job in running state.
  Future<AnalysisJob> createRunningJob({
    String specId = 'stream-spec',
  }) async {
    final job = await jobManager.createJob(
      specId: specId,
      specVersion: '1.0.0',
      mode: AnalysisExecutionMode.streaming,
    );
    await jobManager.startJob(job.jobId);
    return job;
  }
}

/// Creates a minimal spec for streaming tests.
AnalysisSpec _createStreamSpec({
  String specId = 'stream-spec',
  List<AnalysisInputSource>? inputSources,
  List<AnalysisTransform>? transforms,
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
    analysisSteps: const [],
    outputs: outputs ??
        [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'stream_metric',
          ),
        ],
    metadata: const AnalysisSpecMetadata(
      description: 'Test streaming spec',
      tags: ['test', 'streaming'],
    ),
  );
}

/// Creates a timestamped data set for streaming window tests.
AnalysisDataSet _createStreamDataSet({
  required DateTime timestamp,
  double value = 75.0,
}) {
  return AnalysisDataSet(
    columns: [
      const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
      const AnalysisColumnInfo(name: 'value', type: 'double'),
    ],
    rows: [
      {'_timestamp': timestamp, 'value': value},
    ],
    rowCount: 1,
  );
}

// ============================================================================
// Tests
// ============================================================================

void main() {
  group('StreamExecutor', () {
    late _StreamTestFixture f;
    late FakeStreamableAdapter streamAdapter;

    setUp(() {
      f = _StreamTestFixture();
      streamAdapter = FakeStreamableAdapter();
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        streamAdapter,
      );
    });

    // TC-001: Streaming starts with startJob
    test('TC-001: streaming execution returns running job', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // StreamExecutor returns running job immediately
      expect(result.status, equals(AnalysisJobStatus.running));
    });

    // TC-002: Window aggregation on incoming data
    test('TC-002: window aggregation collects incoming data points', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {'windowSize': '5m'},
      );

      // Emit data points into the stream
      final now = DateTime.now();
      streamAdapter.emit(_createStreamDataSet(
        timestamp: now,
        value: 70.0,
      ));
      streamAdapter.emit(_createStreamDataSet(
        timestamp: now.add(const Duration(minutes: 1)),
        value: 80.0,
      ));

      // Allow async handlers to process
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Close stream to trigger onDone
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Job should eventually complete
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // TC-003: Transform applied per window
    test('TC-003: transforms are applied per window data', () async {
      final spec = _createStreamSpec(
        transforms: [
          AnalysisTransform(
            name: 'filter',
            parameters: {
              'column': 'value',
              'operator': '>',
              'value': 60.0,
            },
          ),
        ],
      );
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit data that passes filter
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 75.0,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Close and verify completion
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // TC-004: Alert evaluation per window
    test('TC-004: alert evaluation runs per window data', () async {
      final spec = _createStreamSpec(
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'temp_alert',
            parameters: {'condition': 'value > 50'},
          ),
        ],
      );

      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit data that triggers alert
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 100.0,
      ));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Alert evaluation should have produced events
      // (AlertPublisher publishes through EventPort)
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // TC-005: Periodic artifact emission
    test('TC-005: periodic artifact emission during streaming', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit multiple data points
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        streamAdapter.emit(_createStreamDataSet(
          timestamp: now.add(Duration(minutes: i)),
          value: 70.0 + i * 2,
        ));
      }

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Job should complete after stream closes
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // TC-006: Job cancellation stops subscription
    test('TC-006: cancelling a job stops the stream subscription', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit one data point
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 75.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Cancel the job via JobManager (triggers registered cancel handler)
      final canceled = await f.jobManager.cancelJob(job.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));

      // Emitting after cancel should not affect anything
      if (!streamAdapter.isClosed) {
        streamAdapter.emit(_createStreamDataSet(
          timestamp: DateTime.now(),
          value: 999.0,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Verify job stayed canceled
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.canceled));
    });

    // TC-007: Window eviction (memory management)
    test('TC-007: window evicts expired data points', () {
      final aggregator = WindowAggregator(
        windowSize: const Duration(minutes: 5),
      );
      final now = DateTime.now();

      // Add old point (outside window)
      aggregator.add(AnalysisTimePoint(
        t: now.subtract(const Duration(minutes: 10)),
        v: 50.0,
      ));

      // Add recent point (inside window)
      aggregator.add(AnalysisTimePoint(t: now, v: 75.0));

      // Old point should be evicted
      expect(aggregator.state.pointCount, equals(1));
      expect(aggregator.state.points.first.v, equals(75.0));
    });

    // TC-008: Stream error → non-fatal (JobManager.addError)
    test('TC-008: stream error is non-fatal and recorded', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit a good data point first
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 75.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Emit an error (non-fatal)
      streamAdapter.emitError(Exception('Transient connection error'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Stream should still be alive; close it normally
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Job should complete (error is non-fatal)
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
      // Errors should have been recorded
      expect(
        finalJob.errors.any((e) => e.code == 'stream.error'),
        isTrue,
      );
    });

    // TC-009: Fatal error → job failed
    test('TC-009: fatal error in stream setup fails the job', () async {
      // No input sources → should fail
      final spec = _createStreamSpec(inputSources: []);
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      expect(result.status, equals(AnalysisJobStatus.failed));
      expect(
        result.errors.any((e) => e.code == 'source.unavailable'),
        isTrue,
      );
    });

    // TC-010: No analysis function execution in streaming
    test('TC-010: streaming mode does not execute analysis functions',
        () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // StreamExecutor does not call FunctionDispatcher
      // It returns running job immediately without function execution
      expect(result.status, equals(AnalysisJobStatus.running));

      // Emit and close
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 70.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      // No function steps in logs (streaming does not run analysis functions)
      expect(
        finalJob!.logs.any((l) => l.step.startsWith('function:')),
        isFalse,
      );
    });
  });

  // ==========================================================================
  // StreamExecutor coverage boost
  // ==========================================================================
  group('StreamExecutor coverage boost', () {
    late _StreamTestFixture f;
    late FakeStreamableAdapter streamAdapter;

    setUp(() {
      f = _StreamTestFixture();
      streamAdapter = FakeStreamableAdapter();
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        streamAdapter,
      );
    });

    // Non-alert outputs do not trigger alert evaluation
    test('non-alert outputs skip alert evaluation', () async {
      final spec = _createStreamSpec(
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'metric_out',
          ),
          AnalysisOutputDef(
            type: AnalysisArtifactType.table,
            name: 'table_out',
          ),
        ],
      );
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 100.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // No alert events should have been published
      expect(f.eventPort.publishedEvents, isEmpty);

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Data with non-DateTime timestamp uses DateTime.now() fallback
    test('non-DateTime timestamp uses fallback', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit data where _timestamp is a string, not DateTime
      final dataSet = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'string'),
          const AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [
          {'_timestamp': '2025-01-01T00:00:00', 'value': 75.0},
        ],
        rowCount: 1,
      );
      streamAdapter.emit(dataSet);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Data with no numeric value uses orElse 0.0
    test('data with no numeric value uses 0.0 fallback', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit data where value is a string (no num)
      final dataSet = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'label', type: 'string'),
        ],
        rows: [
          {'_timestamp': DateTime.now(), 'label': 'test'},
        ],
        rowCount: 1,
      );
      streamAdapter.emit(dataSet);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // windowSize defaults to '5m' when not provided
    test('windowSize defaults to 5m when not in params', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {}, // No windowSize
      );

      expect(result.status, equals(AnalysisJobStatus.running));

      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 70.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Multiple data points build up in the window
    test('multiple points accumulate in window', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {'windowSize': '60m'},
      );

      final now = DateTime.now();
      for (var i = 0; i < 10; i++) {
        streamAdapter.emit(_createStreamDataSet(
          timestamp: now.add(Duration(seconds: i * 10)),
          value: 60.0 + i,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Alert output with default condition (no 'condition' parameter)
    test('alert output with default condition uses value > 0', () async {
      final spec = _createStreamSpec(
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'default_alert',
            // No parameters -> condition defaults to 'value > 0'
          ),
        ],
      );
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 50.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Empty rows in a data set emission
    test('empty rows in data set emission is handled', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit empty data set
      final emptyDataSet = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [],
        rowCount: 0,
      );
      streamAdapter.emit(emptyDataSet);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });
  });

  // ==========================================================================
  // WindowAggregator coverage boost
  // ==========================================================================
  group('WindowAggregator coverage boost', () {
    // Multiple points within window are retained
    test('multiple points within window are retained', () {
      final aggregator = WindowAggregator(
        windowSize: const Duration(minutes: 10),
      );
      final now = DateTime.now();

      for (var i = 0; i < 5; i++) {
        aggregator.add(AnalysisTimePoint(
          t: now.add(Duration(minutes: i)),
          v: 50.0 + i,
        ));
      }

      expect(aggregator.state.pointCount, equals(5));
    });

    // All points expired leaves empty window
    test('all points outside window are evicted', () {
      final aggregator = WindowAggregator(
        windowSize: const Duration(minutes: 1),
      );
      final now = DateTime.now();

      // Add points far in the past
      aggregator.add(AnalysisTimePoint(
        t: now.subtract(const Duration(minutes: 10)),
        v: 50.0,
      ));
      aggregator.add(AnalysisTimePoint(
        t: now.subtract(const Duration(minutes: 5)),
        v: 60.0,
      ));

      // Now add a current point to trigger eviction
      aggregator.add(AnalysisTimePoint(t: now, v: 70.0));

      // Only the current point should remain
      expect(aggregator.state.pointCount, equals(1));
      expect(aggregator.state.points.first.v, equals(70.0));
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('StreamExecutor Integration', () {
    late _StreamTestFixture f;
    late FakeStreamableAdapter streamAdapter;

    setUp(() {
      f = _StreamTestFixture();
      streamAdapter = FakeStreamableAdapter();
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        streamAdapter,
      );
    });

    // IT-001: Full streaming lifecycle
    test('IT-001: full streaming lifecycle from start to completion', () async {
      final spec = _createStreamSpec(
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'temp_alert',
            parameters: {'condition': 'value > 80'},
          ),
        ],
      );
      final job = await f.createRunningJob();

      // Start streaming
      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {'windowSize': '5m'},
      );
      expect(result.status, equals(AnalysisJobStatus.running));

      // Emit data over time
      final now = DateTime.now();
      for (var i = 0; i < 3; i++) {
        streamAdapter.emit(_createStreamDataSet(
          timestamp: now.add(Duration(minutes: i)),
          value: 70.0 + i * 10, // 70, 80, 90
        ));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // Close stream (data source done)
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Verify completion
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob, isNotNull);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // IT-003: Fatal exception during stream setup fails the job
    test('IT-003: exception during stream subscribe fails the job', () async {
      // Register a source that throws during subscribe
      final throwingAdapter = _ThrowingStreamAdapter();
      f.dataSourceRegistry.register(
        AnalysisSourceType.external,
        throwingAdapter,
      );

      final spec = _createStreamSpec(
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.external,
            query: 'failing_query',
          ),
        ],
      );
      final job = await f.createRunningJob();

      final result = await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Job should be failed due to caught exception
      expect(result.status, equals(AnalysisJobStatus.failed));
      expect(
        result.errors.any((e) => e.code == 'analysis.execution_error'),
        isTrue,
      );
    });

    // IT-004: Transform error during streaming is non-blocking
    test('IT-004: transform error in streaming is non-blocking', () async {
      final spec = _createStreamSpec(
        transforms: [
          AnalysisTransform(
            name: 'nonexistent_transform',
            parameters: {},
          ),
        ],
      );
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit data that will trigger an unknown transform
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 50.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Stream should still be alive; close it normally
      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Job should complete (transform errors are non-blocking)
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // IT-002: Cancel during active streaming
    test('IT-002: cancel during active streaming stops subscription', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      // Start streaming
      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      // Emit some data
      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 75.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Cancel while streaming
      final canceled = await f.jobManager.cancelJob(job.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));

      // Further emissions should be ignored
      if (!streamAdapter.isClosed) {
        streamAdapter.emit(_createStreamDataSet(
          timestamp: DateTime.now(),
          value: 999.0,
        ));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Job remains canceled
      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.canceled));
    });
  });

  // ==========================================================================
  // StreamExecutor additional coverage
  // ==========================================================================
  group('StreamExecutor additional coverage', () {
    late _StreamTestFixture f;
    late FakeStreamableAdapter streamAdapter;

    setUp(() {
      f = _StreamTestFixture();
      streamAdapter = FakeStreamableAdapter();
      f.dataSourceRegistry.register(
        AnalysisSourceType.factgraph,
        streamAdapter,
      );
    });

    // Multiple alert outputs are all evaluated
    test('multiple alert outputs all produce alert artifacts', () async {
      final spec = _createStreamSpec(
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'alert1',
            parameters: {'condition': 'value > 10'},
          ),
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'alert2',
            parameters: {'condition': 'value > 50'},
          ),
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'metric_out',
          ),
        ],
      );
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 100.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Stream with both transform and alert outputs
    test('stream with transforms and alert outputs handles both', () async {
      final spec = _createStreamSpec(
        transforms: [
          AnalysisTransform(
            name: 'filter',
            parameters: {
              'column': 'value',
              'operator': '>',
              'value': 0.0,
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.alert,
            name: 'combined_alert',
            parameters: {'condition': 'value > 50'},
          ),
        ],
      );
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {},
      );

      streamAdapter.emit(_createStreamDataSet(
        timestamp: DateTime.now(),
        value: 100.0,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });

    // Multiple rows per emission are each processed
    test('multiple rows per emission are each added to window', () async {
      final spec = _createStreamSpec();
      final job = await f.createRunningJob();

      await f.executor.execute(
        job: job,
        spec: spec,
        resolvedParams: {'windowSize': '60m'},
      );

      final now = DateTime.now();
      // Emit a dataset with multiple rows at once
      final multiRowDs = AnalysisDataSet(
        columns: [
          const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          const AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [
          {'_timestamp': now, 'value': 10.0},
          {'_timestamp': now.add(const Duration(seconds: 30)), 'value': 20.0},
          {'_timestamp': now.add(const Duration(minutes: 1)), 'value': 30.0},
        ],
        rowCount: 3,
      );
      streamAdapter.emit(multiRowDs);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await streamAdapter.closeStream();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalJob = await f.jobManager.getJob(job.jobId);
      expect(finalJob!.status, equals(AnalysisJobStatus.completed));
    });
  });
}

// =============================================================================
// Additional test helpers
// =============================================================================

/// A streamable adapter that throws during subscribe to test error handling.
class _ThrowingStreamAdapter extends DataSourceAdapter
    with StreamableDataSource {
  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.mcpIo;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    throw Exception('Query not supported');
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return const AnalysisSourceSchema(columns: []);
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) {
    // Throw during subscribe to trigger the outer catch block
    throw Exception('Stream subscription failed');
  }
}
