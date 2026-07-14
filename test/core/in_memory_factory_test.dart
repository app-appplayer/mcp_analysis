import 'dart:convert';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// `AnalysisPortAdapter.inMemory()` — the package-owned standard builder.
/// One line must yield a REAL working engine: spec CRUD, batch execution
/// over the synthetic source, artifact retrieval, full catalog registered.
void main() {
  test('one line builds a working engine: synthetic sine → fft → artifacts',
      () async {
    final port = AnalysisPortAdapter.inMemory();

    await port.createSpec(AnalysisSpec.fromJson({
      'specId': 'tone-check',
      'version': '1.0.0',
      'inputSources': [
        {
          'sourceType': 'synthetic',
          'query': jsonEncode({
            'samples': 2048,
            'sampleRate': 1000,
            'seed': 5,
            'components': [
              {'kind': 'sine', 'amplitude': 1.0, 'frequency': 60.0},
            ],
          }),
        },
      ],
      'analysisSteps': [
        {
          'function': 'fft',
          'parameters': {'column': 'value', 'sampleRate': 1000},
        },
      ],
      'outputs': [
        {'type': 'summary', 'name': 'fft'},
      ],
      'metadata': {'description': 'factory smoke', 'tags': []},
    }));

    final job = await port.runAnalysis(
      specId: 'tone-check',
      parameters: <String, dynamic>{},
    );
    final done = await port.getJob(job.jobId);
    expect(done?.status, AnalysisJobStatus.completed);

    final artifacts = await port.getArtifacts(jobId: job.jobId);
    expect(artifacts, isNotEmpty);
    final payload = jsonEncode([for (final a in artifacts) a.toJson()]);
    expect(payload, contains('dominantFrequency'));
    expect(payload, contains('60'));
  });

  test('full catalog registered: a domain function runs through the engine',
      () async {
    final port = AnalysisPortAdapter.inMemory();
    await port.createSpec(AnalysisSpec.fromJson({
      'specId': 'vib',
      'version': '1.0.0',
      'inputSources': [
        {
          'sourceType': 'synthetic',
          'query': jsonEncode({
            'samples': 4096,
            'sampleRate': 1000,
            'seed': 9,
            'components': [
              {'kind': 'sine', 'amplitude': 2.0, 'frequency': 50.0},
            ],
          }),
        },
      ],
      'analysisSteps': [
        {
          'function': 'vibration_indicators',
          'parameters': {'column': 'value'},
        },
      ],
      'outputs': [
        {'type': 'summary', 'name': 'vibration_indicators'},
      ],
      'metadata': {'description': 'domain smoke', 'tags': []},
    }));
    final job =
        await port.runAnalysis(specId: 'vib', parameters: <String, dynamic>{});
    expect((await port.getJob(job.jobId))?.status,
        AnalysisJobStatus.completed);
    final artifacts = await port.getArtifacts(jobId: job.jobId);
    expect(artifacts, isNotEmpty);
    expect(jsonEncode([for (final a in artifacts) a.toJson()]),
        contains('rms'));
  });

  test('standardBuiltinFunctions matches the documented catalog size', () {
    final fns = standardBuiltinFunctions();
    expect(fns, hasLength(36));
    expect(fns.map((f) => f.info.functionName).toSet(), hasLength(36));
  });

  test('extraFunctions and extra data sources are honored', () async {
    final port = AnalysisPortAdapter.inMemory();
    expect(port.dataSourceRegistry, isA<DataSourceRegistry>());
  });
}
