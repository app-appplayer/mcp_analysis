import 'package:mcp_bundle/ports.dart';

/// Creates a minimal valid AnalysisSpec for testing.
AnalysisSpec createTestSpec({
  String specId = 'test-spec-001',
  String version = '1.0.0',
  String? description,
  Map<String, dynamic> parameters = const {},
  List<AnalysisInputSource>? inputSources,
  List<AnalysisTransform>? transforms,
  List<AnalysisStep>? analysisSteps,
  List<AnalysisOutputDef>? outputs,
}) {
  return AnalysisSpec(
    specId: specId,
    version: version,
    inputSources: inputSources ??
        [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temperature',
          ),
        ],
    transforms: transforms ?? [],
    analysisSteps: analysisSteps ??
        [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {'columns': ['temperature']},
          ),
        ],
    outputs: outputs ??
        [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'temperature_stats',
          ),
        ],
    parameters: parameters,
    metadata: AnalysisSpecMetadata(
      author: 'test',
      description: description ?? 'Test spec',
      tags: ['test'],
    ),
  );
}

/// Creates a test AnalysisDataSet with numeric time-series data.
AnalysisDataSet createTestDataSet({
  int rowCount = 5,
  List<Map<String, dynamic>>? rows,
}) {
  final now = DateTime.now();
  final defaultRows = List.generate(
    rowCount,
    (i) => <String, dynamic>{
      '_timestamp': now.subtract(Duration(minutes: rowCount - i)),
      'temperature': 70.0 + i * 2.5,
      'status': i == 3 ? 'inactive' : 'active',
    },
  );

  return AnalysisDataSet(
    columns: [
      const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
      const AnalysisColumnInfo(
          name: 'temperature', type: 'double', unit: '°F'),
      const AnalysisColumnInfo(name: 'status', type: 'string'),
    ],
    rows: rows ?? defaultRows,
    rowCount: (rows ?? defaultRows).length,
  );
}

/// Creates a test AnalysisArtifactProvenance.
AnalysisArtifactProvenance createTestProvenance({
  String specId = 'test-spec-001',
  String specVersion = '1.0.0',
}) {
  return AnalysisArtifactProvenance(
    version: specVersion,
    createdAt: DateTime.now(),
    specId: specId,
    specVersion: specVersion,
    sourceUri: 'factgraph://temperature',
    sourceQuery: 'temperature',
  );
}

/// Creates a test AnalysisJob.
AnalysisJob createTestJob({
  String jobId = 'job-001',
  String specId = 'test-spec-001',
  AnalysisJobStatus status = AnalysisJobStatus.queued,
  double progress = 0.0,
}) {
  return AnalysisJob(
    jobId: jobId,
    specId: specId,
    specVersion: '1.0.0',
    mode: AnalysisExecutionMode.batch,
    status: status,
    progress: progress,
    createdAt: DateTime.now(),
    parameters: const {},
  );
}
