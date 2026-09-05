import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Detects anomalies using threshold, z-score, IQR, or EWMA methods.
class AnomalyDetectFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'anomaly_detect',
        description:
            'Detect anomalies using threshold, z-score, IQR, or EWMA methods',
        parameters: {
          'method': AnalysisParameterSchema(
            name: 'method',
            type: 'string',
            defaultValue: 'threshold',
            description: 'Detection method: threshold, zscore, iqr, ewma, mad',
          ),
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Column to analyze',
          ),
          'threshold': AnalysisParameterSchema(
            name: 'threshold',
            type: 'double',
            description: 'Threshold value (for threshold method)',
          ),
          'sensitivity': AnalysisParameterSchema(
            name: 'sensitivity',
            type: 'double',
            defaultValue: 2.0,
            description: 'Sensitivity factor (for zscore/iqr methods)',
          ),
          'alpha': AnalysisParameterSchema(
            name: 'alpha',
            type: 'double',
            defaultValue: 0.3,
            description: 'Smoothing factor for EWMA method (0 < alpha <= 1)',
          ),
        },
        results: const {
          'anomalies': AnalysisResultSchema(
            name: 'anomalies',
            type: 'array',
            itemType: 'object',
            description: 'Rows flagged as anomalous',
          ),
          'count': AnalysisResultSchema(
            name: 'count',
            type: 'number',
            description: 'Number of anomalies',
          ),
          'method': AnalysisResultSchema(
            name: 'method',
            type: 'string',
            description: 'Detection method used',
          ),
        },
        supportedDataTypes: ['double', 'int'],
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    final sw = Stopwatch()..start();
    final method = parameters['method'] as String? ?? 'threshold';
    final column = parameters['column'] as String? ??
        data.columns
            .where((c) => c.type == 'double' || c.type == 'int')
            .map((c) => c.name)
            .firstOrNull ??
        '';

    if (column.isEmpty) {
      throw AnalysisError(
        code: 'analysis.parameter_error',
        message: 'No numeric column found for anomaly detection',
        step: 'function:anomaly_detect',
      );
    }

    final values = data.rows
        .map((r) => r[column])
        .whereType<num>()
        .map((v) => (v).toDouble())
        .toList();

    final anomalies = <Map<String, dynamic>>[];

    switch (method) {
      case 'threshold':
        final threshold = (parameters['threshold'] as num?)?.toDouble();
        if (threshold == null) {
          throw AnalysisError(
            code: 'analysis.parameter_error',
            message: 'Threshold method requires "threshold" parameter',
            step: 'function:anomaly_detect',
          );
        }
        for (var i = 0; i < values.length; i++) {
          if (values[i] > threshold) {
            anomalies.add({
              'index': i,
              'value': values[i],
              'score': values[i] - threshold,
            });
          }
        }

      case 'zscore':
        final sensitivity =
            (parameters['sensitivity'] as num?)?.toDouble() ?? 2.0;
        if (values.length < 2) break;
        final mean = values.reduce((a, b) => a + b) / values.length;
        final variance =
            values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
                (values.length - 1);
        final std = math.sqrt(variance);
        if (std == 0) break;

        for (var i = 0; i < values.length; i++) {
          final zScore = (values[i] - mean).abs() / std;
          if (zScore > sensitivity) {
            anomalies.add({
              'index': i,
              'value': values[i],
              'score': zScore,
            });
          }
        }

      case 'iqr':
        final sensitivity =
            (parameters['sensitivity'] as num?)?.toDouble() ?? 1.5;
        final sorted = List<double>.from(values)..sort();
        final q1 = sorted[(sorted.length * 0.25).floor()];
        final q3 = sorted[(sorted.length * 0.75).floor()];
        final iqr = q3 - q1;
        final lower = q1 - sensitivity * iqr;
        final upper = q3 + sensitivity * iqr;

        for (var i = 0; i < values.length; i++) {
          if (values[i] < lower || values[i] > upper) {
            anomalies.add({
              'index': i,
              'value': values[i],
              'score':
                  values[i] > upper ? values[i] - upper : lower - values[i],
            });
          }
        }

      case 'mad':
        // Median absolute deviation — robust z-score (0.6745·|x−med|/MAD),
        // immune to the outliers it hunts (unlike mean/std in zscore).
        final sensitivity =
            (parameters['sensitivity'] as num?)?.toDouble() ?? 3.5;
        if (values.length < 2) break;
        final sortedForMedian = List<double>.from(values)..sort();
        double medianOf(List<double> xs) => xs.length.isOdd
            ? xs[xs.length ~/ 2]
            : (xs[xs.length ~/ 2 - 1] + xs[xs.length ~/ 2]) / 2;
        final median = medianOf(sortedForMedian);
        final deviations = values.map((v) => (v - median).abs()).toList()
          ..sort();
        final mad = medianOf(deviations);
        if (mad == 0) break;

        for (var i = 0; i < values.length; i++) {
          final score = 0.6745 * (values[i] - median).abs() / mad;
          if (score > sensitivity) {
            anomalies.add({
              'index': i,
              'value': values[i],
              'score': score,
            });
          }
        }

      case 'ewma':
        final alpha = (parameters['alpha'] as num?)?.toDouble() ?? 0.3;
        final sensitivity =
            (parameters['sensitivity'] as num?)?.toDouble() ?? 2.0;
        if (values.isEmpty) break;

        // Compute EWMA series
        final ewma = <double>[values.first];
        for (var i = 1; i < values.length; i++) {
          ewma.add(alpha * values[i] + (1 - alpha) * ewma[i - 1]);
        }

        // Compute standard deviation of residuals
        final residuals = <double>[];
        for (var i = 0; i < values.length; i++) {
          residuals.add((values[i] - ewma[i]).abs());
        }
        final meanResidual =
            residuals.reduce((a, b) => a + b) / residuals.length;
        final residualVariance = residuals
                .map((r) => (r - meanResidual) * (r - meanResidual))
                .reduce((a, b) => a + b) /
            residuals.length;
        final residualStd = math.sqrt(residualVariance);

        if (residualStd > 0) {
          for (var i = 0; i < values.length; i++) {
            final deviation = (values[i] - ewma[i]).abs();
            if (deviation > sensitivity * residualStd) {
              anomalies.add({
                'index': i,
                'value': values[i],
                'score': deviation / residualStd,
                'ewma': ewma[i],
              });
            }
          }
        }

      default:
        throw AnalysisError(
          code: 'analysis.parameter_error',
          message:
              'Unknown anomaly detection method: "$method". Supported: threshold, zscore, iqr, ewma',
          step: 'function:anomaly_detect',
        );
    }

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'anomaly_detect',
      results: {
        'anomalies': anomalies,
        'count': anomalies.length,
        'method': method,
      },
      executionTime: sw.elapsed,
    );
  }
}
