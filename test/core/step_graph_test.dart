import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Steps consuming other steps.
///
/// Before [AnalysisStepInput] every step read the same dataset, so a
/// spectrum could be computed and then not be the thing the next step
/// looked at — `peak_detect` after `fft` found the peaks of the raw
/// signal, silently and with no way to say otherwise.
void main() {
  resolverAndStoreEdgeTests();
  late AnalysisPort port;
  setUp(() => port = AnalysisPortAdapter.inMemory());

  // 64 samples of a 4 Hz tone at 32 Hz: one clear spectral line.
  AnalysisInputSource source() => AnalysisInputSource(
        sourceType: AnalysisSourceType.synthetic,
        query: '{"samples":64,"sampleRate":32,"seed":1,'
            '"components":[{"kind":"sine","amplitude":1,"frequency":4}]}',
      );

  AnalysisSpec spec({
    required String specId,
    required List<AnalysisStep> steps,
    required List<AnalysisOutputDef> outputs,
  }) =>
      AnalysisSpec(
        specId: specId,
        version: '1.0.0',
        inputSources: [source()],
        analysisSteps: steps,
        outputs: outputs,
        metadata: const AnalysisSpecMetadata(description: 'step graph'),
      );

  AnalysisStep fft() => AnalysisStep(
        id: 'spectrum',
        function: 'fft',
        parameters: {'column': 'value', 'sampleRate': 32},
      );

  AnalysisStep peaksOfSpectrum() => AnalysisStep(
        id: 'peaks',
        function: 'peak_detect',
        parameters: {'column': 'value', 'minHeight': 0.05},
        input: const AnalysisStepInput(
          from: 'spectrum',
          field: 'magnitudes',
          indexField: 'frequencies',
        ),
      );

  AnalysisStep peaksOfSignal() => AnalysisStep(
        id: 'peaks',
        function: 'peak_detect',
        parameters: {'column': 'value', 'minHeight': 0.05},
      );

  Future<AnalysisSummaryArtifact> runPeaks(
    String specId,
    AnalysisStep peaks,
  ) async {
    await port.createSpec(
      spec(
        specId: specId,
        steps: [fft(), peaks],
        outputs: [
          AnalysisOutputDef(
            from: 'peaks',
            type: AnalysisArtifactType.summary,
            name: 'peaks',
          ),
        ],
      ),
    );
    final job = await port.runAnalysis(specId: specId, parameters: {});
    final artifacts = await port.getArtifacts(jobId: job.jobId);
    return artifacts.single as AnalysisSummaryArtifact;
  }

  test('a step reads the earlier step it names, not the source data', () async {
    final onSpectrum = await runPeaks('chained', peaksOfSpectrum());
    final onSignal = await runPeaks('flat', peaksOfSignal());

    expect(onSpectrum.text, isNot(equals(onSignal.text)),
        reason: 'peaks of a spectrum are not peaks of the signal that '
            'produced it; if these match the input binding did nothing');
    expect(onSpectrum.text, contains('indices'));
  });

  test('the derived dataset carries the field it was told to read', () async {
    const resolver = StepInputResolver();
    final data = resolver.resolve(
      const AnalysisStepInput(
        from: 'spectrum',
        field: 'magnitudes',
        indexField: 'frequencies',
        column: 'magnitude',
        indexColumn: 'frequency',
      ),
      {
        'spectrum': {
          'magnitudes': [1.0, 5.0, 2.0],
          'frequencies': [0.0, 4.0, 8.0],
        },
      },
    );

    expect(data.rowCount, equals(3));
    expect(data.columns.map((c) => c.name), equals(['frequency', 'magnitude']));
    expect(data.rows[1]['magnitude'], equals(5.0));
    expect(data.rows[1]['frequency'], equals(4.0));
  });

  test('a field that is not numbers in this run fails loudly', () {
    expect(
      () => const StepInputResolver().resolve(
        const AnalysisStepInput(from: 'spectrum', field: 'column'),
        {
          'spectrum': {'column': 'value'},
        },
      ),
      throwsA(isA<AnalysisError>()
          .having((e) => e.code, 'code', 'analysis.invalid_step_input')),
    );
  });

  test('a step reading a later step is rejected', () async {
    expect(
      () => port.createSpec(
        spec(
          specId: 'forward-ref',
          steps: [peaksOfSpectrum(), fft()],
          outputs: [
            AnalysisOutputDef(
              from: 'peaks',
              type: AnalysisArtifactType.summary,
              name: 'peaks',
            ),
          ],
        ),
      ),
      throwsA(
        isA<AnalysisError>().having(
          (e) => e.details?['issues'].toString(),
          'issues',
          contains('step_input_order'),
        ),
      ),
    );
  });

  test('a step reading itself is rejected', () async {
    expect(
      () => port.createSpec(
        spec(
          specId: 'self-ref',
          steps: [
            AnalysisStep(
              id: 'loop',
              function: 'peak_detect',
              parameters: {'column': 'value'},
              input: const AnalysisStepInput(from: 'loop', field: 'values'),
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              from: 'loop',
              type: AnalysisArtifactType.summary,
              name: 'loop',
            ),
          ],
        ),
      ),
      throwsA(
        isA<AnalysisError>().having(
          (e) => e.details?['issues'].toString(),
          'issues',
          contains('step_input_order'),
        ),
      ),
    );
  });

  test('a step reading no known step is rejected', () async {
    expect(
      () => port.createSpec(
        spec(
          specId: 'unknown-ref',
          steps: [
            fft(),
            AnalysisStep(
              id: 'peaks',
              function: 'peak_detect',
              parameters: {'column': 'value'},
              input: const AnalysisStepInput(
                from: 'nowhere',
                field: 'magnitudes',
              ),
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              from: 'peaks',
              type: AnalysisArtifactType.summary,
              name: 'peaks',
            ),
          ],
        ),
      ),
      throwsA(
        isA<AnalysisError>().having(
          (e) => e.details?['issues'].toString(),
          'issues',
          contains('unresolved_step_input'),
        ),
      ),
    );
  });

  test('a step reading a field its source does not produce is rejected',
      () async {
    expect(
      () => port.createSpec(
        spec(
          specId: 'unknown-field',
          steps: [
            fft(),
            AnalysisStep(
              id: 'peaks',
              function: 'peak_detect',
              parameters: {'column': 'value'},
              input: const AnalysisStepInput(
                from: 'spectrum',
                field: 'amplitudes',
              ),
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              from: 'peaks',
              type: AnalysisArtifactType.summary,
              name: 'peaks',
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
}

/// Edges of step-input resolution and of persistence that the main cases
/// do not reach.
void resolverAndStoreEdgeTests() {
  group('step input edges', () {
    test('a source step that produced no result map fails loudly', () {
      expect(
        () => const StepInputResolver().resolve(
          const AnalysisStepInput(from: 'nothing', field: 'v'),
          {'nothing': 'not a map'},
        ),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'analysis.invalid_step_input')),
      );
    });

    test('an absent source step fails loudly', () {
      expect(
        () => const StepInputResolver().resolve(
          const AnalysisStepInput(from: 'absent', field: 'v'),
          const {},
        ),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'analysis.invalid_step_input')),
      );
    });

    test('an index shorter than the values leaves the tail unindexed', () {
      final data = const StepInputResolver().resolve(
        const AnalysisStepInput(
          from: 's',
          field: 'v',
          indexField: 'i',
        ),
        {
          's': {
            'v': [1.0, 2.0, 3.0],
            'i': [10.0],
          },
        },
      );
      expect(data.rowCount, equals(3));
      expect(data.rows.first['index'], equals(10.0));
      expect(data.rows.last['index'], isNull);
    });

    test('an index field that is not numbers is dropped, values kept', () {
      final data = const StepInputResolver().resolve(
        const AnalysisStepInput(from: 's', field: 'v', indexField: 'i'),
        {
          's': {
            'v': [1.0, 2.0],
            'i': ['a', 'b'],
          },
        },
      );
      expect(data.rowCount, equals(2));
      expect(data.columns.map((c) => c.name), equals(['value']));
    });

    test('an empty value list yields an empty dataset', () {
      final data = const StepInputResolver().resolve(
        const AnalysisStepInput(from: 's', field: 'v'),
        {
          's': {'v': <double>[]},
        },
      );
      expect(data.rowCount, isZero);
    });
  });

  group('step input validation edges', () {
    test('a step input naming no field is rejected', () async {
      final port = AnalysisPortAdapter.inMemory();
      expect(
        () => port.createSpec(
          AnalysisSpec(
            specId: 'no-field',
            version: '1.0.0',
            inputSources: [
              AnalysisInputSource(
                sourceType: AnalysisSourceType.synthetic,
                query: '{"samples":8,"sampleRate":8,"seed":1,'
                    '"components":[{"kind":"sine","amplitude":1,'
                    '"frequency":1}]}',
              ),
            ],
            analysisSteps: [
              AnalysisStep(
                id: 'first',
                function: 'descriptive_stats',
                parameters: {
                  'columns': ['value'],
                },
              ),
              AnalysisStep(
                id: 'second',
                function: 'descriptive_stats',
                parameters: {
                  'columns': ['value'],
                },
                input: const AnalysisStepInput(from: 'first', field: ''),
              ),
            ],
            outputs: [
              AnalysisOutputDef(
                from: 'second',
                type: AnalysisArtifactType.summary,
                name: 'out',
              ),
            ],
            metadata: const AnalysisSpecMetadata(description: 'no field'),
          ),
        ),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.details?['issues'].toString(),
            'issues',
            contains('missing_field'),
          ),
        ),
      );
    });
  });
}
