# MCP Analysis

Analysis engine for the MCP ecosystem. Pipeline-based data analysis with pluggable functions, transforms, and multi-source data integration. Implements the `AnalysisPort` / `AnalysisFunctionPort` / `AnalysisDataSourcePort` Contract Layer defined in `mcp_bundle`.

## Components

- **Spec** — spec validator, parameter resolver, spec manager.
- **Artifact** — artifact builder, store, provenance tracker.
- **Execution** — execution engine, batch / ad-hoc / stream executors, job manager, retry policy, step logger.
- **DataSource** — multi-source data integration with pluggable adapters, including a synthetic source for simulation: signal models, linear dynamic systems (state-space / transfer function / RLC, RK4), and Monte Carlo ensemble prediction bands.
- **Functions and Transforms** — 36 built-in functions: statistics (incl. moments, PCA, hypothesis tests), DSP (FFT w/ phase, Welch PSD, spectrogram, cepstrum, harmonics/THD, cross-PSD/coherence/FRF, filters incl. notch/Butterworth-cascade/median, software lock-in, peaks, resample, envelope), timeseries (ACF auto-period, cross-correlation, CUSUM, Holt-Winters, Savitzky-Golay w/ derivatives, Lomb-Scargle for uneven sampling, Kalman filter/smoother), interpolation, and a built-in domain layer (vibration ISO 10816, HRV, EEG bands) — plus pluggable custom functions and transforms.
- **Alerts** — alert evaluation against analysis results.
- **MCP integration** — exposes analysis capabilities through MCP tools.
- **Standard port adapter** — `analysis_port_adapter.dart` implementing the `mcp_bundle` analysis Contract Layer.

## Quick Start

```dart
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';

Future<void> main() async {
  // Spec store, executors, job manager, built-in functions and the
  // synthetic / upload sources, wired in memory.
  final port = AnalysisPortAdapter.inMemory();

  await port.createSpec(
    AnalysisSpec(
      specId: 'tone-stats',
      version: '1.0.0',
      inputSources: [
        AnalysisInputSource(
          sourceType: AnalysisSourceType.synthetic,
          query: '{"samples":64,"sampleRate":32,"seed":1,'
              '"components":[{"kind":"sine","amplitude":1,"frequency":4}]}',
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
      metadata: const AnalysisSpecMetadata(description: 'Tone statistics'),
    ),
  );

  final job = await port.runAnalysis(specId: 'tone-stats', parameters: {});
  final artifacts = await port.getArtifacts(jobId: job.jobId);
  // job.status is completed; artifacts holds the summary artifact.
  assert(job.status == AnalysisJobStatus.completed && artifacts.isNotEmpty);
}
```

## Support

- [Issue Tracker](https://github.com/app-appplayer/mcp_analysis/issues)
- [Discussions](https://github.com/app-appplayer/mcp_analysis/discussions)

## License

MIT — see [LICENSE](LICENSE).
