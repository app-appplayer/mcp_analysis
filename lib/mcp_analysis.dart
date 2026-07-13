/// MCP Analysis package.
///
/// Provides analysis orchestration, data source management,
/// transform pipelines, function execution, alert evaluation,
/// and MCP integration for the makemind ecosystem.
library mcp_analysis;

// CORE - Port Adapter
export 'src/core/analysis_port_adapter.dart';

// CORE - Spec
export 'src/core/spec/spec_validator.dart';
export 'src/core/spec/parameter_resolver.dart';
export 'src/core/spec/spec_manager.dart';

// CORE - Artifact
export 'src/core/artifact/artifact_builder.dart';
export 'src/core/artifact/artifact_store.dart';
export 'src/core/artifact/provenance_tracker.dart';

// CORE - Execution
export 'src/core/execution/step_logger.dart';
export 'src/core/execution/job_manager.dart';
export 'src/core/execution/retry_policy.dart';
export 'src/core/execution/batch_executor.dart';
export 'src/core/execution/adhoc_executor.dart';
export 'src/core/execution/stream_executor.dart';
export 'src/core/execution/execution_engine.dart';

// FEAT - DataSource
export 'src/feat/datasource/datasource_registry.dart';
export 'src/feat/datasource/io_source.dart';
export 'src/feat/datasource/upload_source.dart';
export 'src/feat/datasource/api_source.dart';
export 'src/feat/datasource/factgraph_source.dart';
export 'src/feat/datasource/synthetic_source.dart';

// FEAT - Transform
export 'src/feat/transform/transform_pipeline.dart';
export 'src/feat/transform/transforms.dart';
export 'src/feat/transform/schema_propagator.dart';

// FEAT - Function
export 'src/feat/function/function_catalog.dart';
export 'src/feat/function/function_dispatcher.dart';
export 'src/feat/function/plugin_loader.dart';
export 'src/feat/function/builtin/descriptive_stats.dart';
export 'src/feat/function/builtin/anomaly_detect.dart';
export 'src/feat/function/builtin/event_analysis.dart';
export 'src/feat/function/builtin/time_series.dart';
export 'src/feat/function/builtin/correlation.dart';
export 'src/feat/function/builtin/classification.dart';
export 'src/feat/function/builtin/seasonality.dart';
export 'src/feat/function/builtin/dsp_spectrum.dart';
export 'src/feat/function/builtin/dsp_filter.dart';
export 'src/feat/function/builtin/dsp_events.dart';
export 'src/feat/function/builtin/dsp_resample.dart';
export 'src/feat/function/builtin/timeseries_advanced.dart';
export 'src/feat/function/builtin/smoothing.dart';
export 'src/feat/function/builtin/stats_extended.dart';
export 'src/feat/function/builtin/dsp_advanced.dart';
export 'src/feat/function/builtin/multivariate.dart';
export 'src/feat/function/builtin/kalman.dart';
export 'src/feat/domain/domain_builtin.dart';

// FEAT - Alert
export 'src/feat/alert/alert_evaluator.dart';
export 'src/feat/alert/alert_publisher.dart';
export 'src/feat/alert/window_aggregator.dart';
export 'src/feat/alert/reorder_buffer.dart';

// INFRA - Governance
export 'src/infra/governance/rbac_policy.dart';
export 'src/infra/governance/audit_logger.dart';
export 'src/infra/governance/data_masker.dart';

// INFRA - MCP
export 'src/infra/mcp/mcp_tool_handler.dart';
export 'src/infra/mcp/mcp_resource_handler.dart';
