import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Kalman filter + forecast (`kalman_filter`) — deterministic recursive
/// state estimation over a local-level or local-linear-trend model. The
/// in-core prediction engine alongside `holt_winters` (iterative auto-fit
/// models like ARIMA stay outside per the compute-layer boundary).
///
/// Parameters: `column`, `model` (level|trend, default trend),
/// `processNoise` (Q scale, default 1e-3), `measurementNoise` (R, default
/// 1.0), `horizon` (forecast steps, default 10). Results: `filtered[]`
/// (smoothed series), `forecast[]`, `level`, `trend`, `innovationStd`
/// (residual scale — a live model-fit signal).
class KalmanFilterFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'kalman_filter',
        description:
            'Kalman filtering + forecasting (local level / linear trend)',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to filter',
          ),
          'model': AnalysisParameterSchema(
            name: 'model',
            type: 'string',
            defaultValue: 'trend',
            description: 'level (random walk) | trend (local linear trend)',
          ),
          'processNoise': AnalysisParameterSchema(
            name: 'processNoise',
            type: 'number',
            defaultValue: 0.001,
            description: 'Process noise variance scale (Q)',
          ),
          'measurementNoise': AnalysisParameterSchema(
            name: 'measurementNoise',
            type: 'number',
            defaultValue: 1.0,
            description: 'Measurement noise variance (R)',
          ),
          'horizon': AnalysisParameterSchema(
            name: 'horizon',
            type: 'number',
            defaultValue: 10,
            description: 'Forecast steps ahead',
          ),
        },
        results: const {
          'column': AnalysisResultSchema(
            name: 'column',
            type: 'string',
            description: 'Analyzed column',
          ),
          'model': AnalysisResultSchema(
            name: 'model',
            type: 'string',
            description: 'State model used',
          ),
          'filtered': AnalysisResultSchema(
            name: 'filtered',
            type: 'array',
            itemType: 'number',
            description: 'Filtered estimate per sample',
          ),
          'forecast': AnalysisResultSchema(
            name: 'forecast',
            type: 'array',
            itemType: 'number',
            description: 'Forecast beyond the input',
          ),
          'level': AnalysisResultSchema(
            name: 'level',
            type: 'number',
            description: 'Final level estimate',
          ),
          'trend': AnalysisResultSchema(
            name: 'trend',
            type: 'number',
            description: 'Final trend estimate',
          ),
          'innovationStd': AnalysisResultSchema(
            name: 'innovationStd',
            type: 'number',
            description: 'Innovation standard deviation',
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
    final column = resolveColumn(parameters, data);
    final z = numericColumn(data, column);
    if (z.length < 3) {
      throw ArgumentError('kalman_filter requires ≥ 3 samples');
    }
    final model = parameters['model'] as String? ?? 'trend';
    final q = (parameters['processNoise'] as num?)?.toDouble() ?? 1e-3;
    final r = (parameters['measurementNoise'] as num?)?.toDouble() ?? 1.0;
    final horizon = math.max(1, (parameters['horizon'] as num?)?.toInt() ?? 10);

    final filtered = List<double>.filled(z.length, 0.0);
    double level, trend = 0.0;
    var innovationSq = 0.0;
    var innovations = 0;

    if (model == 'level') {
      // 1-D random-walk Kalman.
      level = z[0];
      var p = 1.0;
      for (var i = 0; i < z.length; i++) {
        p += q;
        final k = p / (p + r);
        final innov = z[i] - level;
        level += k * innov;
        p *= (1 - k);
        filtered[i] = level;
        if (i > 0) {
          innovationSq += innov * innov;
          innovations++;
        }
      }
    } else {
      // 2-state local linear trend: x=[level, trend],
      // F=[[1,1],[0,1]], H=[1,0], Q=q·I, R=r.
      level = z[0];
      trend = z.length > 1 ? z[1] - z[0] : 0.0;
      var p00 = 1.0, p01 = 0.0, p10 = 0.0, p11 = 1.0;
      for (var i = 0; i < z.length; i++) {
        // Predict.
        final lPred = level + trend;
        final n00 = p00 + p01 + p10 + p11 + q;
        final n01 = p01 + p11;
        final n10 = p10 + p11;
        final n11 = p11 + q;
        // Update with measurement z[i] (H=[1,0]).
        final s = n00 + r;
        final k0 = n00 / s;
        final k1 = n10 / s;
        final innov = z[i] - lPred;
        level = lPred + k0 * innov;
        trend = trend + k1 * innov;
        p00 = (1 - k0) * n00;
        p01 = (1 - k0) * n01;
        p10 = n10 - k1 * n00;
        p11 = n11 - k1 * n01;
        filtered[i] = level;
        if (i > 0) {
          innovationSq += innov * innov;
          innovations++;
        }
      }
    }

    final forecast = List<double>.generate(
        horizon, (h) => model == 'level' ? level : level + (h + 1) * trend);

    return AnalysisFunctionResult(
      functionName: 'kalman_filter',
      results: {
        'column': column,
        'model': model,
        'filtered': filtered,
        'forecast': forecast,
        'level': level,
        'trend': trend,
        'innovationStd':
            innovations > 0 ? math.sqrt(innovationSq / innovations) : 0.0,
      },
      executionTime: sw.elapsed,
    );
  }
}
