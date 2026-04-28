import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Seasonal decomposition using classical additive moving average method.
class SeasonalityFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'seasonality_analysis',
        description:
            'Seasonal decomposition using classical additive moving average',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Column to analyze',
          ),
          'timestampColumn': AnalysisParameterSchema(
            name: 'timestampColumn',
            type: 'string',
            defaultValue: '_timestamp',
            description: 'Timestamp column name',
          ),
          'period': AnalysisParameterSchema(
            name: 'period',
            type: 'int',
            description: 'Seasonal period length',
          ),
          'method': AnalysisParameterSchema(
            name: 'method',
            type: 'string',
            defaultValue: 'moving_average',
            description: 'Decomposition method: moving_average',
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

    final column = parameters['column'] as String? ??
        data.columns
            .where((c) => c.type == 'double' || c.type == 'int')
            .map((c) => c.name)
            .firstOrNull ??
        '';
    final period = (parameters['period'] as num?)?.toInt() ?? 0;

    // Validate period
    if (period < 2) {
      throw AnalysisError(
        code: 'analysis.parameter_error',
        message:
            'Period must be >= 2, got $period',
        step: 'function:seasonality_analysis',
      );
    }

    // Extract numeric values
    final values = data.rows
        .map((r) => r[column])
        .where((v) => v is num)
        .map((v) => (v as num).toDouble())
        .toList();

    // Validate data length
    if (values.length < period * 2) {
      throw AnalysisError(
        code: 'analysis.parameter_error',
        message:
            'Need at least ${period * 2} data points for period $period, '
            'got ${values.length}',
        step: 'function:seasonality_analysis',
      );
    }

    final n = values.length;

    // Step 1: Centered moving average for trend
    final trend = List<double?>.filled(n, null);
    final halfWindow = period ~/ 2;

    if (period.isEven) {
      // For even period, use two-pass centered MA
      // First pass: simple MA of length = period
      final firstPass = List<double?>.filled(n, null);
      for (var i = halfWindow; i < n - halfWindow + 1; i++) {
        var sum = 0.0;
        for (var j = i - halfWindow; j < i - halfWindow + period; j++) {
          sum += values[j];
        }
        firstPass[i] = sum / period;
      }
      // Second pass: average consecutive pairs to center
      for (var i = halfWindow; i < n - halfWindow; i++) {
        final a = firstPass[i];
        final b = firstPass[i + 1] ?? firstPass[i];
        if (a != null && b != null) {
          trend[i] = (a + b) / 2;
        }
      }
    } else {
      // For odd period, single-pass centered MA
      for (var i = halfWindow; i < n - halfWindow; i++) {
        var sum = 0.0;
        for (var j = i - halfWindow; j <= i + halfWindow; j++) {
          sum += values[j];
        }
        trend[i] = sum / period;
      }
    }

    // Step 2: Detrended = values - trend (only where trend is available)
    final detrended = List<double?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      if (trend[i] != null) {
        detrended[i] = values[i] - trend[i]!;
      }
    }

    // Step 3: Seasonal indices - average detrended values at each position % period
    final seasonalSums = List<double>.filled(period, 0.0);
    final seasonalCounts = List<int>.filled(period, 0);
    for (var i = 0; i < n; i++) {
      if (detrended[i] != null) {
        final pos = i % period;
        seasonalSums[pos] += detrended[i]!;
        seasonalCounts[pos]++;
      }
    }

    final seasonalIndices = List<double>.filled(period, 0.0);
    for (var i = 0; i < period; i++) {
      if (seasonalCounts[i] > 0) {
        seasonalIndices[i] = seasonalSums[i] / seasonalCounts[i];
      }
    }

    // Normalize seasonal indices to sum approximately to 0
    final indexMean =
        seasonalIndices.reduce((a, b) => a + b) / period;
    for (var i = 0; i < period; i++) {
      seasonalIndices[i] -= indexMean;
    }

    // Step 4: Repeat seasonal indices across full series
    final seasonal = List<double>.generate(n, (i) => seasonalIndices[i % period]);

    // Step 5: Residual = values - trend - seasonal (null where trend is null)
    final residual = List<double?>.filled(n, null);
    for (var i = 0; i < n; i++) {
      if (trend[i] != null) {
        residual[i] = values[i] - trend[i]! - seasonal[i];
      }
    }

    // Step 6: Seasonality strength = 1 - var(residual) / var(detrended)
    final detrendedValues =
        detrended.where((v) => v != null).map((v) => v!).toList();
    final residualValues =
        residual.where((v) => v != null).map((v) => v!).toList();

    final strength = _computeStrength(detrendedValues, residualValues);

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'seasonality_analysis',
      results: {
        'trend': trend,
        'seasonal': seasonal,
        'residual': residual,
        'seasonal_indices': seasonalIndices,
        'period': period,
        'strength': strength,
      },
      executionTime: sw.elapsed,
    );
  }

  /// Compute seasonality strength: 1 - var(residual) / var(detrended),
  /// clamped to [0, 1].
  double _computeStrength(
    List<double> detrendedValues,
    List<double> residualValues,
  ) {
    if (detrendedValues.length < 2 || residualValues.length < 2) {
      return 0.0;
    }

    final varDetrended = _variance(detrendedValues);
    final varResidual = _variance(residualValues);

    if (varDetrended == 0.0) return 0.0;

    final strength = 1.0 - (varResidual / varDetrended);
    return strength.clamp(0.0, 1.0);
  }

  /// Compute sample variance of a list of values.
  double _variance(List<double> values) {
    if (values.length < 2) return 0.0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final sumSq =
        values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b);
    return sumSq / (values.length - 1);
  }
}
