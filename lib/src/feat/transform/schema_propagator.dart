import 'package:mcp_bundle/ports.dart';

import 'transform_pipeline.dart';

/// Tracks schema evolution across transform steps.
class SchemaPropagator {
  /// Compute the final output schema after all transforms.
  List<AnalysisColumnInfo> propagate(
    List<AnalysisColumnInfo> inputSchema,
    List<AnalysisTransform> transforms,
    Map<String, TransformHandler> handlers,
  ) {
    var current = inputSchema;
    for (final transform in transforms) {
      final handler = handlers[transform.name];
      if (handler == null) {
        throw AnalysisError(
          code: 'transform.unknown',
          message: 'Unknown transform: "${transform.name}"',
          step: 'transform:${transform.name}',
        );
      }
      current = handler.computeOutputSchema(current, transform.parameters);
    }
    return current;
  }
}
