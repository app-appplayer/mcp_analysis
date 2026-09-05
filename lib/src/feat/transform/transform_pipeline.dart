import 'package:mcp_bundle/ports.dart';

import 'transforms.dart';

/// Result of executing a transform pipeline.
class TransformResult {
  const TransformResult({required this.dataSet, required this.stepLogs});
  final AnalysisDataSet dataSet;
  final List<TransformStepLog> stepLogs;
}

/// Log entry for a single transform step.
class TransformStepLog {
  const TransformStepLog({
    required this.transformName,
    required this.inputRowCount,
    required this.outputRowCount,
    required this.outputSchema,
    required this.executionTime,
  });
  final String transformName;
  final int inputRowCount;
  final int outputRowCount;
  final List<AnalysisColumnInfo> outputSchema;
  final Duration executionTime;
}

/// Interface for individual transform implementations.
abstract class TransformHandler {
  String get name;

  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  );

  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  );
}

/// Orchestrates sequential execution of transform steps.
class TransformPipeline {
  TransformPipeline({Map<String, TransformHandler>? customHandlers}) {
    // Register built-in handlers
    final builtins = <TransformHandler>[
      FilterTransform(),
      SortTransform(),
      FillnaTransform(),
      ClipTransform(),
      ResampleTransform(),
      JoinTransform(),
      UnitConvertTransform(),
    ];
    for (final handler in builtins) {
      _handlers[handler.name] = handler;
    }
    if (customHandlers != null) {
      _handlers.addAll(customHandlers);
    }
  }
  final Map<String, TransformHandler> _handlers = {};

  /// Get registered handlers (for testing/validation).
  Map<String, TransformHandler> get handlers => Map.unmodifiable(_handlers);

  /// Execute a sequence of transforms on a DataSet.
  Future<TransformResult> execute(
    AnalysisDataSet input,
    List<AnalysisTransform> transforms,
  ) async {
    var current = input;
    final stepLogs = <TransformStepLog>[];

    for (final transform in transforms) {
      final handler = _handlers[transform.name];
      if (handler == null) {
        throw AnalysisError(
          code: 'transform.unknown',
          message:
              'Unknown transform: "${transform.name}". Available: ${_handlers.keys.join(", ")}',
          step: 'transform:${transform.name}',
        );
      }

      final sw = Stopwatch()..start();
      try {
        final result = await handler.apply(current, transform.parameters);
        sw.stop();

        stepLogs.add(TransformStepLog(
          transformName: transform.name,
          inputRowCount: current.rowCount,
          outputRowCount: result.rowCount,
          outputSchema: result.columns,
          executionTime: sw.elapsed,
        ));

        current = result;
      } catch (e) {
        sw.stop();
        if (e is AnalysisError) rethrow;
        throw AnalysisError(
          code: 'transform.failed',
          message: 'Transform "${transform.name}" failed: $e',
          step: 'transform:${transform.name}',
          details: {'parameters': transform.parameters},
        );
      }
    }

    return TransformResult(dataSet: current, stepLogs: stepLogs);
  }
}
