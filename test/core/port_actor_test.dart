import 'dart:async';

import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// The port carries who is asking.
///
/// It used to carry nobody. The engine has always accepted an RBAC
/// context, but no caller could supply one through the port, so role
/// checks never evaluated, every audit record was written against
/// `system`, and the whole governance layer answered to no one. The
/// contract also had no way to stop a running job, list what had run,
/// delete a spec, or say which functions exist.
/// A stream that keeps going, which is what makes cancellation the only
/// way a streaming job ends.
class _EndlessSource extends DataSourceAdapter with StreamableDataSource {
  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.mcpIo;

  AnalysisDataSet _tick(int i) => AnalysisDataSet(
        columns: const [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [
          {
            '_timestamp': DateTime.utc(2026).add(Duration(seconds: i)),
            'value': i.toDouble(),
          },
        ],
        rowCount: 1,
      );

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) =>
      Stream<AnalysisDataSet>.periodic(
        const Duration(milliseconds: 20),
        _tick,
      );

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async =>
      _tick(0);

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async =>
      const AnalysisSourceSchema(
        columns: [AnalysisColumnInfo(name: 'value', type: 'double')],
      );

  @override
  Future<bool> isAvailable() async => true;
}

void main() {
  defaultPortTests();
  late AnalysisPortAdapter port;
  setUp(() => port = AnalysisPortAdapter.inMemory());

  AnalysisSpec spec(String id) => AnalysisSpec(
        specId: id,
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.synthetic,
            query: '{"samples":16,"sampleRate":16,"seed":1,'
                '"components":[{"kind":"sine","amplitude":1,"frequency":2}]}',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            id: 'stats',
            function: 'descriptive_stats',
            parameters: {
              'columns': ['value'],
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            from: 'stats',
            type: AnalysisArtifactType.summary,
            name: 'stats',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'actor'),
      );

  group('the actor reaches the governance layer', () {
    test('a role without execute permission is refused', () async {
      await port.createSpec(spec('guarded'));
      expect(
        () => port.runAnalysis(
          specId: 'guarded',
          parameters: {},
          actor: const AnalysisActor(id: 'viewer-1', role: 'viewer'),
        ),
        throwsA(isA<AnalysisError>()),
        reason: 'an unknown role has no permissions; before the port carried '
            'an actor this call could not be refused at all',
      );
    });

    test('a role with execute permission runs', () async {
      await port.createSpec(spec('permitted'));
      final job = await port.runAnalysis(
        specId: 'permitted',
        parameters: {},
        actor: const AnalysisActor(id: 'op-1', role: 'operator'),
      );
      expect(job.status, equals(AnalysisJobStatus.completed));
    });

    test('no actor still runs — hosts that do not authorize are unchanged',
        () async {
      await port.createSpec(spec('anonymous'));
      final job = await port.runAnalysis(specId: 'anonymous', parameters: {});
      expect(job.status, equals(AnalysisJobStatus.completed));
    });
  });

  group('operations the contract was missing', () {
    test('listJobs enumerates runs, newest first', () async {
      await port.createSpec(spec('a'));
      await port.createSpec(spec('b'));
      await port.runAnalysis(specId: 'a', parameters: {});
      await port.runAnalysis(specId: 'b', parameters: {});
      await port.runAnalysis(specId: 'a', parameters: {});

      expect(await port.listJobs(), hasLength(3));
      expect(await port.listJobs(specId: 'a'), hasLength(2));
      expect(
        await port.listJobs(status: AnalysisJobStatus.completed),
        hasLength(3),
      );
      expect(await port.listJobs(limit: 2), hasLength(2));

      final all = await port.listJobs();
      for (var i = 1; i < all.length; i++) {
        expect(all[i - 1].createdAt.isBefore(all[i].createdAt), isFalse);
      }
    });

    test('deleteSpec removes it and refuses twice', () async {
      await port.createSpec(spec('temporary'));
      expect(await port.listSpecs(search: 'temporary'), hasLength(1));

      await port.deleteSpec('temporary');
      expect(await port.listSpecs(search: 'temporary'), isEmpty);

      expect(
        () => port.deleteSpec('temporary'),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'spec.not_found')),
      );
    });

    test('listFunctions publishes the catalog a spec author needs', () async {
      final all = await port.listFunctions();
      expect(all, hasLength(36));

      final fft = all.firstWhere((f) => f.functionName == 'fft');
      expect(fft.parameters.keys, contains('sampleRate'));
      expect(fft.results.keys, containsAll(['frequencies', 'magnitudes']),
          reason: 'an author binds an output to these names');
      expect(fft.results['frequencies']!.unit, equals('Hz'));

      final searched = await port.listFunctions(search: 'vibration');
      expect(searched.map((f) => f.functionName),
          contains('vibration_indicators'));
      expect(searched.length, lessThan(all.length));
    });

    test('a streaming job can be stopped', () async {
      port.dataSourceRegistry
          .register(AnalysisSourceType.mcpIo, _EndlessSource());
      final streaming = AnalysisSpec(
        specId: 'streaming',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(sourceType: AnalysisSourceType.mcpIo, query: 'x'),
        ],
        analysisSteps: [
          AnalysisStep(
            id: 'stats',
            function: 'descriptive_stats',
            parameters: {
              'columns': ['value'],
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            from: 'stats',
            type: AnalysisArtifactType.metric,
            name: 'stats',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'endless'),
      );
      await port.createSpec(streaming);
      final job = await port.runAnalysis(
        specId: 'streaming',
        parameters: {},
        mode: AnalysisExecutionMode.streaming,
      );
      expect(job.status, equals(AnalysisJobStatus.running),
          reason: 'a stream does not finish on its own, which is exactly '
              'why the contract needed a way to stop it');

      final canceled = await port.cancelJob(job.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    test('a finished job cannot be canceled', () async {
      await port.createSpec(spec('finished'));
      final job = await port.runAnalysis(specId: 'finished', parameters: {});
      expect(job.status, equals(AnalysisJobStatus.completed));
      expect(
        () => port.cancelJob(job.jobId),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'job.invalid_transition')),
      );
    });

    test('the standard builder registers every dependency-free source',
        () async {
      // `synthetic` and `upload` need nothing from the host; `mcpIo`,
      // `external` and `factgraph` each need a port the host owns.
      final registry = port.dataSourceRegistry;
      expect(registry.hasAdapter(AnalysisSourceType.synthetic), isTrue);
      expect(registry.hasAdapter(AnalysisSourceType.upload), isTrue);
      expect(registry.hasAdapter(AnalysisSourceType.external), isFalse);
    });

    test('cancelJob on an unknown job is refused', () async {
      expect(
        () => port.cancelJob('no-such-job'),
        throwsA(isA<AnalysisError>()),
      );
    });
  });
}

/// The no-op event and metric ports the standard builder installs when a
/// host wires none. They are what an unconfigured engine publishes into,
/// so their surface ships whether or not a host replaces them.
void defaultPortTests() {
  test('the standard engine runs with no event or metric port wired', () async {
    final port = AnalysisPortAdapter.inMemory();
    await port.createSpec(
      AnalysisSpec(
        specId: 'noop',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.synthetic,
            query: '{"samples":8,"sampleRate":8,"seed":1,'
                '"components":[{"kind":"sine","amplitude":1,"frequency":1}]}',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            id: 'stats',
            function: 'descriptive_stats',
            parameters: {
              'columns': ['value'],
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            from: 'stats',
            type: AnalysisArtifactType.alert,
            name: 'stats',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'noop ports'),
      ),
    );
    final job = await port.runAnalysis(specId: 'noop', parameters: {});
    expect(job.status, equals(AnalysisJobStatus.completed));
  });

  test('a host-supplied event port receives what the no-op would swallow',
      () async {
    final events = <PortEvent>[];
    final port = AnalysisPortAdapter.inMemory(
      eventPort: _RecordingEventPort(events),
      metricPort: _RecordingMetricPort(),
    );
    expect(port, isA<AnalysisPort>());
    expect(events, isEmpty);
  });
}

class _RecordingEventPort implements EventPort {
  _RecordingEventPort(this.events);
  final List<PortEvent> events;

  @override
  Future<void> publish(PortEvent event) async => events.add(event);

  @override
  Stream<PortEvent> subscribe(String eventType) =>
      const Stream<PortEvent>.empty();

  @override
  Stream<PortEvent> subscribeAll() => const Stream<PortEvent>.empty();

  @override
  Future<void> unsubscribe(String eventType) async {}
}

class _RecordingMetricPort implements MetricPort {
  @override
  Future<MetricValue> compute(
    String metricName,
    Map<String, dynamic> context,
  ) async =>
      MetricValue(value: 0, timestamp: DateTime.utc(2026));

  @override
  Future<void> record(
    String metricName,
    double value, {
    Map<String, String>? tags,
  }) async {}

  @override
  Stream<MetricEvent> watch(String metricName) =>
      const Stream<MetricEvent>.empty();

  @override
  Future<List<MetricValue>> history(
    String metricName, {
    DateTime? start,
    DateTime? end,
    int? limit,
  }) async =>
      const [];
}
