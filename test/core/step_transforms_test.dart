import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Transforms belonging to one step.
///
/// `AnalysisSpec.transforms` run once over the merged sources, before any
/// step. There was therefore nowhere to put a reshaping that belongs to a
/// single step, and nowhere at all to put one between two steps.
void main() {
  late AnalysisPort port;
  setUp(() => port = AnalysisPortAdapter.inMemory());

  // A 4 Hz tone: values swing between -1 and 1.
  AnalysisInputSource tone() => AnalysisInputSource(
        sourceType: AnalysisSourceType.synthetic,
        query: '{"samples":64,"sampleRate":32,"seed":1,'
            '"components":[{"kind":"sine","amplitude":1,"frequency":4}]}',
      );

  Future<Map<String, dynamic>> statsOf(
    String specId, {
    List<AnalysisTransform> stepTransforms = const [],
    List<AnalysisTransform> specTransforms = const [],
  }) async {
    await port.createSpec(
      AnalysisSpec(
        specId: specId,
        version: '1.0.0',
        inputSources: [tone()],
        transforms: specTransforms,
        analysisSteps: [
          AnalysisStep(
            id: 'stats',
            function: 'descriptive_stats',
            parameters: {
              'columns': ['value'],
            },
            transforms: stepTransforms,
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            from: 'stats',
            type: AnalysisArtifactType.summary,
            name: 'stats',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'step transforms'),
      ),
    );
    final job = await port.runAnalysis(specId: specId, parameters: {});
    final fresh = await port.getJob(job.jobId);
    expect(fresh?.status, equals(AnalysisJobStatus.completed),
        reason: '${fresh?.errors.map((e) => e.toString()).toList()}');
    final artifacts = await port.getArtifacts(jobId: job.jobId);
    return {
      'text': (artifacts.single as AnalysisSummaryArtifact).text,
      'logs': fresh!.logs.map((l) => l.step).toList(),
    };
  }

  test('a step-level transform reshapes only that step', () async {
    final plain = await statsOf('plain');
    final clipped = await statsOf(
      'clipped',
      stepTransforms: [
        AnalysisTransform(
          name: 'clip',
          parameters: {'column': 'value', 'min': -0.5, 'max': 0.5},
        ),
      ],
    );

    expect(clipped['text'], isNot(equals(plain['text'])),
        reason: 'clipping to +/-0.5 must move the statistics; if these '
            'match the step transform did nothing');
    expect(plain['text'], contains('"max":1.0'));
    expect(clipped['text'], contains('"max":0.5'));
  });

  test('it is logged under the step it belongs to', () async {
    final result = await statsOf(
      'logged',
      stepTransforms: [
        AnalysisTransform(
          name: 'clip',
          parameters: {'column': 'value', 'max': 0.5},
        ),
      ],
    );
    expect(result['logs'], contains('transform:stats'));
  });

  test('spec-level transforms still run once, before every step', () async {
    final result = await statsOf(
      'spec-level',
      specTransforms: [
        AnalysisTransform(
          name: 'clip',
          parameters: {'column': 'value', 'min': -0.5, 'max': 0.5},
        ),
      ],
    );
    expect(result['text'], contains('"max":0.5'));
    expect(result['logs'], contains('transform:pipeline'));
    expect(result['logs'], isNot(contains('transform:spec-level')));
  });

  test('a nameless step transform is rejected', () async {
    expect(
      () => port.createSpec(
        AnalysisSpec(
          specId: 'nameless',
          version: '1.0.0',
          inputSources: [tone()],
          analysisSteps: [
            AnalysisStep(
              function: 'descriptive_stats',
              parameters: {},
              transforms: [AnalysisTransform(name: '', parameters: {})],
            ),
          ],
          outputs: [
            AnalysisOutputDef(
              type: AnalysisArtifactType.summary,
              name: 'descriptive_stats',
            ),
          ],
          metadata: const AnalysisSpecMetadata(description: 'nameless'),
        ),
      ),
      throwsA(
        isA<AnalysisError>().having(
          (e) => e.details?['issues'].toString(),
          'issues',
          contains('empty_transform'),
        ),
      ),
    );
  });
}
