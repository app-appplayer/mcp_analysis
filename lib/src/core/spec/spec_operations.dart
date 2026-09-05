import 'package:mcp_bundle/ports.dart';

/// Public interface for Spec lifecycle operations.
/// Consumed by MOD-CORE-002 (ExecutionEngine) and MOD-INFRA-002.
abstract interface class SpecOperations {
  Future<List<AnalysisSpec>> listSpecs(
      {String? search, int? limit, int? offset});
  Future<AnalysisSpec?> getSpec(String specId);
  Future<AnalysisSpec> createSpec(AnalysisSpec spec);
  Future<AnalysisSpec> updateSpec(String specId, AnalysisSpec spec);
  Map<String, dynamic> resolveParameters(
      AnalysisSpec spec, Map<String, dynamic> overrides);
}
