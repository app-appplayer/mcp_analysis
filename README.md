# MCP Analysis

Analysis engine for the MCP ecosystem. Pipeline-based data analysis with pluggable functions, transforms, and multi-source data integration. Implements the `AnalysisPort` / `AnalysisFunctionPort` / `AnalysisDataSourcePort` Contract Layer defined in `mcp_bundle`.

## Components

- **Spec** — spec validator, parameter resolver, spec manager.
- **Artifact** — artifact builder, store, provenance tracker.
- **Execution** — execution engine, batch / ad-hoc / stream executors, job manager, retry policy, step logger.
- **DataSource** — multi-source data integration with pluggable adapters.
- **Functions and Transforms** — pluggable analysis functions and data transforms.
- **Alerts** — alert evaluation against analysis results.
- **MCP integration** — exposes analysis capabilities through MCP tools.
- **Standard port adapter** — `analysis_port_adapter.dart` implementing the `mcp_bundle` analysis Contract Layer.

## Quick Start

```dart
import 'package:mcp_analysis/mcp_analysis.dart';

final engine = ExecutionEngine(
  jobManager: JobManager(),
  artifactStore: InMemoryArtifactStore(),
);

final result = await engine.executeAdhoc(spec, parameters);
```

## Support

- [Issue Tracker](https://github.com/app-appplayer/mcp_analysis/issues)
- [Discussions](https://github.com/app-appplayer/mcp_analysis/discussions)

## License

MIT — see [LICENSE](LICENSE).
