import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Time series analysis: moving average, trend line.
class TimeSeriesFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'time_series_analysis',
        description: 'Time series analysis: moving average, trend line',
        parameters: {
          'method': AnalysisParameterSchema(
            name: 'method',
            type: 'string',
            defaultValue: 'moving_avg',
            description: 'Analysis method: moving_avg, trend',
          ),
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Column to analyze',
          ),
          'windowSize': AnalysisParameterSchema(
            name: 'windowSize',
            type: 'int',
            defaultValue: 3,
            description: 'Window size for moving average',
          ),
        },
        results: const {
          'moving_averages': AnalysisResultSchema(
            name: 'moving_averages',
            type: 'array',
            itemType: 'number',
            description: 'Moving average series',
          ),
          'windowSize': AnalysisResultSchema(
            name: 'windowSize',
            type: 'number',
            description: 'Averaging window in samples',
          ),
          'slope': AnalysisResultSchema(
            name: 'slope',
            type: 'number',
            description: 'Trend slope',
          ),
          'intercept': AnalysisResultSchema(
            name: 'intercept',
            type: 'number',
            description: 'Trend intercept',
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
    final method = parameters['method'] as String? ?? 'moving_avg';
    final column = parameters['column'] as String? ??
        data.columns
            .where((c) => c.type == 'double' || c.type == 'int')
            .map((c) => c.name)
            .firstOrNull ??
        '';
    final windowSize = (parameters['windowSize'] as num?)?.toInt() ?? 3;

    final values = data.rows
        .map((r) => r[column])
        .whereType<num>()
        .map((v) => (v).toDouble())
        .toList();

    final results = <String, dynamic>{};

    switch (method) {
      case 'moving_avg':
        final movingAvg = <double?>[];
        for (var i = 0; i < values.length; i++) {
          if (i < windowSize - 1) {
            movingAvg.add(null);
          } else {
            var sum = 0.0;
            for (var j = i - windowSize + 1; j <= i; j++) {
              sum += values[j];
            }
            movingAvg.add(sum / windowSize);
          }
        }
        results['moving_averages'] = movingAvg;
        results['windowSize'] = windowSize;

      case 'trend':
        // Linear trend: y = slope * x + intercept
        if (values.length < 2) {
          results['slope'] = 0.0;
          results['intercept'] = values.isNotEmpty ? values.first : 0.0;
          break;
        }

        final n = values.length;
        var sumX = 0.0;
        var sumY = 0.0;
        var sumXY = 0.0;
        var sumX2 = 0.0;

        for (var i = 0; i < n; i++) {
          final x = i.toDouble();
          final y = values[i];
          sumX += x;
          sumY += y;
          sumXY += x * y;
          sumX2 += x * x;
        }

        final slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
        final intercept = (sumY - slope * sumX) / n;

        results['slope'] = slope;
        results['intercept'] = intercept;

      default:
        throw AnalysisError(
          code: 'analysis.parameter_error',
          message:
              'Unknown time series method: "$method". Supported: moving_avg, trend',
          step: 'function:time_series_analysis',
        );
    }

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'time_series_analysis',
      results: results,
      executionTime: sw.elapsed,
    );
  }
}
