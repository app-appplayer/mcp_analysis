import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Computes descriptive statistics: min, max, avg, std, percentiles.
class DescriptiveStatsFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'descriptive_stats',
        description:
            'Compute descriptive statistics (min, max, avg, std, percentiles)',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Columns to analyze',
          ),
          'percentiles': AnalysisParameterSchema(
            name: 'percentiles',
            type: 'array',
            defaultValue: [25, 50, 75],
            description: 'Percentiles to compute',
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
    final columns = _extractColumns(parameters, data);
    final percentiles = (parameters['percentiles'] as List?)
            ?.map((p) => (p as num).toInt())
            .toList() ??
        [25, 50, 75];

    final results = <String, dynamic>{};

    for (final col in columns) {
      final values = data.rows
          .map((r) => r[col])
          .whereType<num>()
          .map((v) => (v).toDouble())
          .toList();

      if (values.isEmpty) {
        results[col] = {
          'count': 0,
          'min': 0.0,
          'max': 0.0,
          'avg': 0.0,
          'std': 0.0,
        };
        continue;
      }

      values.sort();
      final count = values.length;
      final sum = values.reduce((a, b) => a + b);
      final avg = sum / count;
      final minVal = values.first;
      final maxVal = values.last;

      // Standard deviation
      double std = 0.0;
      if (count > 1) {
        final variance =
            values.map((v) => (v - avg) * (v - avg)).reduce((a, b) => a + b) /
                (count - 1);
        std = math.sqrt(variance);
      }

      // Higher moments — skewness (Fisher g1) and kurtosis (Pearson,
      // normal ≈ 3): the vibration-indicator staples (impulsive bearing
      // faults drive kurtosis > 3).
      double skewness = 0.0;
      double kurtosis = 0.0;
      if (count > 2 && std > 0) {
        var m3 = 0.0, m4 = 0.0;
        for (final v in values) {
          final d = v - avg;
          m3 += d * d * d;
          m4 += d * d * d * d;
        }
        m3 /= count;
        m4 /= count;
        final s2 =
            values.map((v) => (v - avg) * (v - avg)).reduce((a, b) => a + b) /
                count; // population variance for moment ratios
        skewness = m3 / math.pow(s2, 1.5);
        kurtosis = m4 / (s2 * s2);
      }

      final stats = <String, dynamic>{
        'count': count,
        'min': minVal,
        'max': maxVal,
        'avg': avg,
        'std': std,
        'skewness': skewness,
        'kurtosis': kurtosis,
      };

      // Percentiles
      for (final p in percentiles) {
        final index = (p / 100 * (count - 1)).round();
        stats['p$p'] = values[index.clamp(0, count - 1)];
      }

      results[col] = stats;
    }

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'descriptive_stats',
      results: results,
      executionTime: sw.elapsed,
    );
  }

  List<String> _extractColumns(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) {
    final cols = parameters['columns'];
    if (cols is List && cols.isNotEmpty) {
      return cols.cast<String>();
    }
    // Default: all numeric columns
    return data.columns
        .where((c) => c.type == 'double' || c.type == 'int')
        .map((c) => c.name)
        .toList();
  }
}
