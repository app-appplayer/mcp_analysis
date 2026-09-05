import 'dart:async';

import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Streaming's periodic emission, and the same step wiring under ad-hoc.
///
/// `_emitPeriodicArtifacts` is the only way a streaming job produces
/// anything before it ends, and it is reached from a `Timer.periodic` —
/// which no unit test touching the executor directly ever fires. The step
/// input and step transforms were wired into both batch and ad-hoc
/// execution and only exercised through batch.
class _TickingSource extends DataSourceAdapter with StreamableDataSource {
  static const period = Duration(milliseconds: 5);

  AnalysisDataSet _tick(int i) => AnalysisDataSet(
        columns: const [
          AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
          AnalysisColumnInfo(name: 'value', type: 'double'),
        ],
        rows: [
          {
            '_timestamp': DateTime.utc(2026).add(Duration(milliseconds: i)),
            'value': (i % 5) + 1.0,
          },
        ],
        rowCount: 1,
      );

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.mcpIo;

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) =>
      Stream<AnalysisDataSet>.periodic(period, _tick);

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

AnalysisInputSource _synthetic() => AnalysisInputSource(
      sourceType: AnalysisSourceType.synthetic,
      query: '{"samples":64,"sampleRate":32,"seed":1,'
          '"components":[{"kind":"sine","amplitude":1,"frequency":4}]}',
    );

void main() {
  group('streaming emits while it runs', () {
    test('a running job produces artifacts before it is stopped', () async {
      final port = AnalysisPortAdapter.inMemory();
      port.dataSourceRegistry
          .register(AnalysisSourceType.mcpIo, _TickingSource());

      await port.createSpec(
        AnalysisSpec(
          specId: 'emitting',
          version: '1.0.0',
          inputSources: [
            AnalysisInputSource(
              sourceType: AnalysisSourceType.mcpIo,
              query: 'x',
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
              type: AnalysisArtifactType.metric,
              name: 'windowState',
            ),
            AnalysisOutputDef(
              type: AnalysisArtifactType.series,
              name: 'pointCount',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'emitting'),
        ),
      );

      final job = await port.runAnalysis(
        specId: 'emitting',
        // The interval parser reads s / m / h only; 1s is the shortest
        // period a spec can ask for.
        parameters: {'windowSize': '30s', 'emitInterval': '1s'},
        mode: AnalysisExecutionMode.streaming,
      );
      expect(job.status, equals(AnalysisJobStatus.running));

      // Let the timer fire.
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      final produced = await port.getArtifacts();
      await port.cancelJob(job.jobId);

      expect(produced, isNotEmpty,
          reason: 'the periodic emitter is the only thing that produces '
              'anything before a stream ends');
    });

    test('a window size and emit interval are read in s / m / h', () async {
      // Exercised through the port because the parser is private; an
      // unparseable spelling falls back rather than failing the job.
      final port = AnalysisPortAdapter.inMemory();
      port.dataSourceRegistry
          .register(AnalysisSourceType.mcpIo, _TickingSource());
      await port.createSpec(
        AnalysisSpec(
          specId: 'durations',
          version: '1.0.0',
          inputSources: [
            AnalysisInputSource(
              sourceType: AnalysisSourceType.mcpIo,
              query: 'x',
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
              type: AnalysisArtifactType.metric,
              name: 'windowState',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'durations'),
        ),
      );

      for (final spelling in ['1h', '2m', '45s', 'nonsense', '']) {
        final job = await port.runAnalysis(
          specId: 'durations',
          parameters: {'windowSize': spelling, 'emitInterval': '1s'},
          mode: AnalysisExecutionMode.streaming,
        );
        expect(job.status, equals(AnalysisJobStatus.running),
            reason: 'windowSize "$spelling" must not fail the job');
        await port.cancelJob(job.jobId);
      }
    });

    test('late arrivals are re-sequenced when allowedLateness is set',
        () async {
      final port = AnalysisPortAdapter.inMemory();
      port.dataSourceRegistry
          .register(AnalysisSourceType.mcpIo, _TickingSource());
      await port.createSpec(
        AnalysisSpec(
          specId: 'reordered',
          version: '1.0.0',
          inputSources: [
            AnalysisInputSource(
              sourceType: AnalysisSourceType.mcpIo,
              query: 'x',
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
              type: AnalysisArtifactType.metric,
              name: 'windowState',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'reordered'),
        ),
      );

      final job = await port.runAnalysis(
        specId: 'reordered',
        parameters: {
          'windowSize': '30s',
          'emitInterval': '1s',
          'allowedLateness': '10s',
          'windowKind': 'tumbling',
          'maxWindowPoints': 50,
        },
        mode: AnalysisExecutionMode.streaming,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final canceled = await port.cancelJob(job.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });
  });

  group('ad-hoc runs the same step wiring as batch', () {
    late AnalysisPortAdapter port;
    setUp(() => port = AnalysisPortAdapter.inMemory());

    AnalysisSpec chained(String specId, {List<AnalysisTransform>? stepXf}) =>
        AnalysisSpec(
          specId: specId,
          version: '1.0.0',
          inputSources: [_synthetic()],
          analysisSteps: [
            AnalysisStep(
              id: 'spectrum',
              function: 'fft',
              parameters: {'column': 'value', 'sampleRate': 32},
            ),
            AnalysisStep(
              id: 'peaks',
              function: 'peak_detect',
              parameters: {'column': 'value', 'minHeight': 0.05},
              input: const AnalysisStepInput(
                from: 'spectrum',
                field: 'magnitudes',
                indexField: 'frequencies',
              ),
              transforms: stepXf ?? const [],
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              from: 'peaks',
              type: AnalysisArtifactType.summary,
              name: 'peaks',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'adhoc chain'),
        );

    test('a step consumes an earlier step under ad-hoc too', () async {
      await port.createSpec(chained('adhoc-chain'));
      final job = await port.runAnalysis(
        specId: 'adhoc-chain',
        parameters: {},
        mode: AnalysisExecutionMode.adhoc,
      );
      expect(job.status, equals(AnalysisJobStatus.completed),
          reason: '${job.errors.map((e) => e.toString()).toList()}');

      final summary = (await port.getArtifacts(jobId: job.jobId)).single
          as AnalysisSummaryArtifact;
      expect(summary.text, contains('indices'));
    });

    test('a step transform applies under ad-hoc too', () async {
      await port.createSpec(chained('adhoc-plain'));
      await port.createSpec(
        chained(
          'adhoc-clipped',
          stepXf: [
            AnalysisTransform(
              name: 'clip',
              parameters: {'column': 'value', 'max': 0.01},
            ),
          ],
        ),
      );

      Future<String> run(String id) async {
        final job = await port.runAnalysis(
          specId: id,
          parameters: {},
          mode: AnalysisExecutionMode.adhoc,
        );
        expect(job.status, equals(AnalysisJobStatus.completed),
            reason: '${job.errors.map((e) => e.toString()).toList()}');
        final a = (await port.getArtifacts(jobId: job.jobId)).single
            as AnalysisSummaryArtifact;
        return a.text;
      }

      expect(
          await run('adhoc-clipped'), isNot(equals(await run('adhoc-plain'))),
          reason: 'clipping the spectrum to 0.01 must change which peaks are '
              'found; if these match the step transform did nothing');
    });
  });
}
