import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Computes correlation coefficient and linear regression.
class CorrelationRegressionFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'correlation_regression',
        description:
            'Compute correlation coefficient and linear regression',
        parameters: {
          'method': AnalysisParameterSchema(
            name: 'method',
            type: 'string',
            defaultValue: 'correlation',
            description: 'Method: correlation, linear_regression',
          ),
          'xColumn': AnalysisParameterSchema(
            name: 'xColumn',
            type: 'string',
            description: 'X variable column',
          ),
          'yColumn': AnalysisParameterSchema(
            name: 'yColumn',
            type: 'string',
            description: 'Y variable column',
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
    final method = parameters['method'] as String? ?? 'correlation';
    final xCol = parameters['xColumn'] as String? ?? 'x';
    final yCol = parameters['yColumn'] as String? ?? 'y';

    final pairs = <List<double>>[];
    for (final row in data.rows) {
      final x = row[xCol];
      final y = row[yCol];
      if (x is num && y is num) {
        pairs.add([x.toDouble(), y.toDouble()]);
      }
    }

    final results = <String, dynamic>{};

    if (pairs.length < 2) {
      results['correlation'] = 0.0;
      results['slope'] = 0.0;
      results['intercept'] = 0.0;
      results['r_squared'] = 0.0;
      sw.stop();
      return AnalysisFunctionResult(
        functionName: 'correlation_regression',
        results: results,
        executionTime: sw.elapsed,
      );
    }

    final xValues = pairs.map((p) => p[0]).toList();
    final yValues = pairs.map((p) => p[1]).toList();
    final n = pairs.length;

    final meanX = xValues.reduce((a, b) => a + b) / n;
    final meanY = yValues.reduce((a, b) => a + b) / n;

    var sumXY = 0.0;
    var sumX2 = 0.0;
    var sumY2 = 0.0;

    for (var i = 0; i < n; i++) {
      final dx = xValues[i] - meanX;
      final dy = yValues[i] - meanY;
      sumXY += dx * dy;
      sumX2 += dx * dx;
      sumY2 += dy * dy;
    }

    // Correlation coefficient
    final denominator = math.sqrt(sumX2 * sumY2);
    final correlation = denominator == 0 ? 0.0 : sumXY / denominator;
    results['correlation'] = correlation;

    if (method == 'linear_regression' || method == 'correlation') {
      // Linear regression: y = slope * x + intercept
      final slope = sumX2 == 0 ? 0.0 : sumXY / sumX2;
      final intercept = meanY - slope * meanX;

      // R-squared
      var ssRes = 0.0;
      var ssTot = 0.0;
      for (var i = 0; i < n; i++) {
        final predicted = slope * xValues[i] + intercept;
        ssRes += (yValues[i] - predicted) * (yValues[i] - predicted);
        ssTot += (yValues[i] - meanY) * (yValues[i] - meanY);
      }
      final rSquared = ssTot == 0 ? 0.0 : 1.0 - ssRes / ssTot;

      results['slope'] = slope;
      results['intercept'] = intercept;
      results['r_squared'] = rSquared;
    }

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'correlation_regression',
      results: results,
      executionTime: sw.elapsed,
    );
  }
}
