import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Alert severity used to be hardcoded to `info` in `buildFromOutputDefs`,
/// so every rule an analysis produced carried the same urgency however the
/// analysis had graded it.
void main() {
  final builder = ArtifactBuilder();
  final provenance = AnalysisArtifactProvenance(
    version: '1.0.0',
    createdAt: DateTime.utc(2026),
    specId: 'spec',
    specVersion: '1.0.0',
  );

  AnalysisAlertRuleArtifact build({
    Map<String, dynamic>? result,
    Map<String, dynamic>? outputParameters,
  }) {
    final artifacts = builder.buildFromOutputDefs(
      jobId: 'job',
      outputDefs: [
        AnalysisOutputDef(
          type: AnalysisArtifactType.alert,
          name: 'rule',
          parameters: outputParameters,
        ),
      ],
      functionResults: {if (result != null) 'rule': result},
      provenance: provenance,
    );
    return artifacts.single as AnalysisAlertRuleArtifact;
  }

  test('the result grades the rule', () {
    final artifact = build(
      result: {'condition': 'rms > 7.1', 'severity': 'critical'},
    );
    expect(artifact.severity, equals(AnalysisAlertSeverity.critical));
    expect(artifact.condition, equals('rms > 7.1'));
  });

  test('the output declares it when the function does not', () {
    final artifact = build(
      result: {'condition': 'rms > 4.5'},
      outputParameters: {'severity': 'warn'},
    );
    expect(artifact.severity, equals(AnalysisAlertSeverity.warn));
  });

  test('the result wins over the output declaration', () {
    final artifact = build(
      result: {'condition': 'x', 'severity': 'critical'},
      outputParameters: {'severity': 'info'},
    );
    expect(artifact.severity, equals(AnalysisAlertSeverity.critical));
  });

  test('info remains the default when neither says', () {
    expect(build(result: {'condition': 'x'}).severity,
        equals(AnalysisAlertSeverity.info));
  });

  test('an unreadable severity falls back rather than throwing', () {
    expect(
        build(result: {'condition': 'x', 'severity': 'apocalyptic'}).severity,
        equals(AnalysisAlertSeverity.info));
  });
}
