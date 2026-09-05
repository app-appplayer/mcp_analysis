import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Deterministic synthetic input — one sine, 32 samples.
const _syntheticQuery = '{"samples":32,"sampleRate":32,"seed":1,'
    '"components":[{"kind":"sine","amplitude":1,"frequency":4}]}';

AnalysisInputSource _source() => AnalysisInputSource(
      sourceType: AnalysisSourceType.synthetic,
      query: _syntheticQuery,
    );

AnalysisStep _stats({String? id}) => AnalysisStep(
      id: id,
      function: 'descriptive_stats',
      parameters: {
        'columns': ['value'],
      },
    );

AnalysisSpec _spec({
  required String specId,
  required List<AnalysisStep> steps,
  required List<AnalysisOutputDef> outputs,
}) =>
    AnalysisSpec(
      specId: specId,
      version: '1.0.0',
      inputSources: [_source()],
      analysisSteps: steps,
      outputs: outputs,
      metadata: const AnalysisSpecMetadata(description: 'binding test'),
    );

AnalysisStep _fft({String? id}) => AnalysisStep(
      id: id,
      function: 'fft',
      parameters: {'column': 'value', 'sampleRate': 32},
    );

void main() {
  indexAxisTests();
  late AnalysisPort port;

  setUp(() => port = AnalysisPortAdapter.inMemory());

  group('artifacts are scoped to the job that produced them', () {
    test('getArtifacts(jobId:) returns only that run', () async {
      final spec = _spec(
        specId: 'scoped',
        steps: [_stats()],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.summary,
            name: 'descriptive_stats',
          ),
        ],
      );
      await port.createSpec(spec);

      final first = await port.runAnalysis(specId: 'scoped', parameters: {});
      final second = await port.runAnalysis(specId: 'scoped', parameters: {});
      expect(first.jobId, isNot(equals(second.jobId)));

      expect(await port.getArtifacts(), hasLength(2));

      final onlyFirst = await port.getArtifacts(jobId: first.jobId);
      expect(onlyFirst, hasLength(1));
      expect(onlyFirst.single.provenance.jobId, equals(first.jobId));

      final onlySecond = await port.getArtifacts(jobId: second.jobId);
      expect(onlySecond, hasLength(1));
      expect(onlySecond.single.provenance.jobId, equals(second.jobId));
    });

    test('getArtifacts(jobId:) on an unknown job is empty, not everything',
        () async {
      await port.createSpec(
        _spec(
          specId: 'scoped-2',
          steps: [_stats()],
          outputs: [
            AnalysisOutputDef(
              type: AnalysisArtifactType.summary,
              name: 'descriptive_stats',
            ),
          ],
        ),
      );
      await port.runAnalysis(specId: 'scoped-2', parameters: {});

      expect(await port.getArtifacts(jobId: 'no-such-job'), isEmpty);
    });

    test('tags narrow the result set', () async {
      await port.createSpec(
        _spec(
          specId: 'scoped-3',
          steps: [_stats()],
          outputs: [
            AnalysisOutputDef(
              type: AnalysisArtifactType.summary,
              name: 'descriptive_stats',
            ),
          ],
        ),
      );
      await port.runAnalysis(specId: 'scoped-3', parameters: {});

      expect(await port.getArtifacts(tags: ['absent-tag']), isEmpty);
    });
  });

  group('outputs bind to steps', () {
    test('an output named after its step still resolves (no "from")', () async {
      await port.createSpec(
        _spec(
          specId: 'implicit',
          steps: [_stats()],
          outputs: [
            AnalysisOutputDef(
              type: AnalysisArtifactType.summary,
              name: 'descriptive_stats',
            ),
          ],
        ),
      );
      final job = await port.runAnalysis(specId: 'implicit', parameters: {});
      final artifacts = await port.getArtifacts(jobId: job.jobId);

      final summary = artifacts.single as AnalysisSummaryArtifact;
      expect(summary.text, contains('count'));
    });

    test('"from" lets the artifact carry a name of its own', () async {
      await port.createSpec(
        _spec(
          specId: 'explicit',
          steps: [_stats()],
          outputs: [
            AnalysisOutputDef(
              from: 'descriptive_stats',
              type: AnalysisArtifactType.summary,
              name: 'temperature_stats',
            ),
          ],
        ),
      );
      final job = await port.runAnalysis(specId: 'explicit', parameters: {});
      final artifacts = await port.getArtifacts(jobId: job.jobId);

      final summary = artifacts.single as AnalysisSummaryArtifact;
      expect(summary.name, equals('temperature_stats'));
      expect(summary.text, contains('count'),
          reason: 'a renamed output must still carry its step results');
    });

    test('an output that names no step is rejected, not silently emptied',
        () async {
      expect(
        () => port.createSpec(
          _spec(
            specId: 'dangling',
            steps: [_stats()],
            outputs: [
              AnalysisOutputDef(
                type: AnalysisArtifactType.metric,
                name: 'rms_value',
              ),
            ],
          ),
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.details?['issues'].toString(),
            'issues',
            contains('unresolved_output_source'),
          ),
        ),
      );
    });
  });

  group('one function can run more than once', () {
    test('distinct ids keep both results', () async {
      await port.createSpec(
        _spec(
          specId: 'twice',
          steps: [_stats(id: 'stats_a'), _stats(id: 'stats_b')],
          outputs: [
            AnalysisOutputDef(
              from: 'stats_a',
              type: AnalysisArtifactType.summary,
              name: 'first',
            ),
            AnalysisOutputDef(
              from: 'stats_b',
              type: AnalysisArtifactType.summary,
              name: 'second',
            ),
          ],
        ),
      );
      final job = await port.runAnalysis(specId: 'twice', parameters: {});
      final artifacts = await port.getArtifacts(jobId: job.jobId);

      expect(artifacts, hasLength(2));
      for (final a in artifacts.cast<AnalysisSummaryArtifact>()) {
        expect(a.text, contains('count'));
      }
    });

    test('a streaming output reads a key the engine supplies, not a step',
        () async {
      // A streaming job emits from the window it accumulates, so its
      // outputs name `windowState` / `pointCount` / `lateDropped` /
      // `overflowDropped` — keys no step produces. Requiring every output
      // to resolve to a step made a streaming spec unwritable.
      for (final key in SpecValidator.engineSuppliedResultKeys) {
        await port.createSpec(
          _spec(
            specId: 'streaming-$key',
            steps: [_stats()],
            outputs: [
              AnalysisOutputDef(
                type: AnalysisArtifactType.metric,
                name: key,
              ),
            ],
          ),
        );
      }
      expect(await port.listSpecs(), hasLength(4));
    });

    test('two steps under one key are rejected', () async {
      expect(
        () => port.createSpec(
          _spec(
            specId: 'collide',
            steps: [_stats(), _stats()],
            outputs: [
              AnalysisOutputDef(
                type: AnalysisArtifactType.summary,
                name: 'descriptive_stats',
              ),
            ],
          ),
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.details?['issues'].toString(),
            'issues',
            contains('duplicate_step_key'),
          ),
        ),
      );
    });
  });

  group('outputs bind to a result field', () {
    Future<List<AnalysisArtifact>> runSpectrum(
      AnalysisPort port,
      String specId,
      AnalysisOutputDef output,
    ) async {
      await port.createSpec(
        _spec(specId: specId, steps: [_fft(id: 'spectrum')], outputs: [output]),
      );
      final job = await port.runAnalysis(specId: specId, parameters: {});
      return port.getArtifacts(jobId: job.jobId);
    }

    test('a series takes the named field, indexed by another', () async {
      final artifacts = await runSpectrum(
        port,
        'series-field',
        AnalysisOutputDef(
          from: 'spectrum',
          field: 'magnitudes',
          indexField: 'frequencies',
          type: AnalysisArtifactType.series,
          name: 'spectrum',
        ),
      );

      final series = artifacts.single as AnalysisSeriesArtifact;
      expect(series.points, isNotEmpty,
          reason: 'the named field carries the values');
      expect(series.points.map((p) => p.v).any((v) => v != 0), isTrue);
      // Distinct frequency bins must not collapse onto one index.
      expect(series.points.map((p) => p.t).toSet().length,
          equals(series.points.length));
    });

    test('a chart carries the series it plots', () async {
      final artifacts = await runSpectrum(
        port,
        'chart-field',
        AnalysisOutputDef(
          from: 'spectrum',
          field: 'magnitudes',
          indexField: 'frequencies',
          type: AnalysisArtifactType.chart,
          name: 'spectrum_plot',
        ),
      );

      final chart = artifacts.single as AnalysisChartArtifact;
      expect(chart.series, hasLength(1));
      expect(chart.series.single.points, isNotEmpty);
      expect(chart.xAxis.label, equals('frequencies'));
      expect(chart.yAxis.label, equals('magnitudes'));
    });

    test('a metric takes a scalar field', () async {
      final artifacts = await runSpectrum(
        port,
        'metric-field',
        AnalysisOutputDef(
          from: 'spectrum',
          field: 'dominantFrequency',
          type: AnalysisArtifactType.metric,
          name: 'peak_hz',
        ),
      );

      final metric = artifacts.single as AnalysisMetricArtifact;
      expect(metric.value, isA<num>());
      expect(metric.value, greaterThan(0),
          reason: 'a real reading, not the 0.0 an unbound output produced');
    });

    test('a declared field the run did not produce yields no artifact',
        () async {
      // `criticalValue` is declared by hypothesis_test, so the binding
      // passes validation — but only the ks test produces it. Building the
      // artifact anyway reported 0.0 for a number nobody computed, which
      // is the failure the binding exists to remove.
      await port.createSpec(
        AnalysisSpec(
          specId: 'conditional',
          version: '1.0.0',
          inputSources: [_source()],
          analysisSteps: [
            AnalysisStep(
              id: 'test',
              function: 'hypothesis_test',
              parameters: {
                'columns': ['value', 'value'],
                'test': 't_test',
              },
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              from: 'test',
              field: 'criticalValue',
              type: AnalysisArtifactType.metric,
              name: 'critical',
            ),
            AnalysisOutputDef(
              from: 'test',
              field: 'statistic',
              type: AnalysisArtifactType.metric,
              name: 'statistic',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'conditional'),
        ),
      );

      final job = await port.runAnalysis(specId: 'conditional', parameters: {});
      final fresh = await port.getJob(job.jobId);
      final artifacts = await port.getArtifacts(jobId: job.jobId);

      expect(artifacts.map((a) => a.name), equals(['statistic']),
          reason: 'the produced field builds; the unproduced one does not');
      expect(
        fresh!.errors.map((e) => e.code),
        contains('artifact.unproduced_field'),
        reason: 'skipping is recorded, not silent',
      );
      expect(fresh.errors.single.details!['field'], equals('criticalValue'));
    });

    test('an unproduced index field also yields no artifact', () async {
      // `statistic` is produced; `criticalValue` is not, for a t-test.
      await port.createSpec(
        AnalysisSpec(
          specId: 'conditional-index',
          version: '1.0.0',
          inputSources: [_source()],
          analysisSteps: [
            AnalysisStep(
              id: 'test',
              function: 'hypothesis_test',
              parameters: {
                'columns': ['value', 'value'],
                'test': 't_test',
              },
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              from: 'test',
              field: 'statistic',
              indexField: 'criticalValue',
              type: AnalysisArtifactType.series,
              name: 'stat_by_critical',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'conditional idx'),
        ),
      );
      final job =
          await port.runAnalysis(specId: 'conditional-index', parameters: {});
      final fresh = await port.getJob(job.jobId);

      expect(fresh!.status, equals(AnalysisJobStatus.completed));
      expect(await port.getArtifacts(jobId: job.jobId), isEmpty,
          reason: 'an index that was not produced cannot be indexed by');
      expect(fresh.errors.map((e) => e.code),
          contains('artifact.unproduced_field'));
      expect(
          fresh.errors.single.details!['indexField'], equals('criticalValue'));
    });

    test('a field the function does not declare is rejected', () async {
      expect(
        () => port.createSpec(
          _spec(
            specId: 'bad-field',
            steps: [_fft(id: 'spectrum')],
            outputs: [
              AnalysisOutputDef(
                from: 'spectrum',
                field: 'amplitudes',
                type: AnalysisArtifactType.series,
                name: 'spectrum',
              ),
            ],
          ),
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.details?['issues'].toString(),
            'issues',
            contains('unknown_result_field'),
          ),
        ),
      );
    });

    test('an unknown indexField is rejected too', () async {
      expect(
        () => port.createSpec(
          _spec(
            specId: 'bad-index',
            steps: [_fft(id: 'spectrum')],
            outputs: [
              AnalysisOutputDef(
                from: 'spectrum',
                field: 'magnitudes',
                indexField: 'bins',
                type: AnalysisArtifactType.chart,
                name: 'spectrum',
              ),
            ],
          ),
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.details?['issues'].toString(),
            'issues',
            contains('unknown_result_field'),
          ),
        ),
      );
    });
  });
}

/// The index a series or chart is plotted against.
///
/// `AnalysisTimePoint.t` is a `DateTime`, so a frequency or lag axis has to
/// be carried as a position on it. A fixed multiplier put a floor on how
/// close two index values could be: bins 0.0001 apart landed on the same
/// microsecond and three points became one.
void indexAxisTests() {
  final builder = ArtifactBuilder();
  final provenance = AnalysisArtifactProvenance(
    version: '1.0.0',
    createdAt: DateTime.utc(2026),
    specId: 'spec',
    specVersion: '1.0.0',
  );

  AnalysisSeriesArtifact series(
    List<dynamic> index,
    List<double> values,
  ) {
    final artifacts = builder.buildFromOutputDefs(
      jobId: 'job',
      outputDefs: [
        AnalysisOutputDef(
          field: 'v',
          indexField: 'x',
          type: AnalysisArtifactType.series,
          name: 's',
        ),
      ],
      functionResults: {
        's': {'v': values, 'x': index},
      },
      provenance: provenance,
    );
    return artifacts.single as AnalysisSeriesArtifact;
  }

  group('index axis', () {
    test('closely spaced index values stay distinct', () {
      final s = series([0.0, 0.0001, 0.0002], [1, 2, 3]);
      expect(s.points.map((p) => p.t).toSet(), hasLength(3));
      expect(s.points.map((p) => p.v), equals([1.0, 2.0, 3.0]));
    });

    test('order and relative spacing survive', () {
      final s = series([0.0, 1.0, 3.0], [1, 2, 3]);
      final us = s.points.map((p) => p.t.microsecondsSinceEpoch).toList();
      expect(us[0] < us[1] && us[1] < us[2], isTrue);
      // 0 -> 1 is a third of 0 -> 3, and stays so.
      expect((us[1] - us[0]) / (us[2] - us[0]), closeTo(1 / 3, 1e-9));
    });

    test('negative index values keep their order', () {
      final s = series([-1, 0, 1], [0.1, 0.9, 0.1]);
      final us = s.points.map((p) => p.t.microsecondsSinceEpoch).toList();
      expect(us[0] < us[1] && us[1] < us[2], isTrue);
    });

    test('an index of one repeated value falls back to position', () {
      final s = series([5.0, 5.0, 5.0], [1, 2, 3]);
      expect(s.points.map((p) => p.t).toSet(), hasLength(3));
    });

    test('a DateTime index is used as it is', () {
      final t0 = DateTime.utc(2026, 5, 1);
      final s = series([t0, t0.add(const Duration(hours: 1))], [1, 2]);
      expect(s.points.first.t, equals(t0));
    });
  });
}
