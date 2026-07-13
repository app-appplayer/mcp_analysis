import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Series smoothing (`smoothing`) — SMA, EMA and Savitzky–Golay.
///
/// Parameters: `column`, `method` (sma|ema|savgol, default sma), `window`
/// (sma/savgol length, default 5; savgol must be odd ≥ 5), `alpha`
/// (ema factor, default 2/(window+1)), `polyOrder` (savgol, default 2).
/// Results: `values[]` (same length).
class SmoothingFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'smoothing',
        description: 'SMA / EMA / Savitzky–Golay series smoothing',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to smooth',
          ),
          'method': AnalysisParameterSchema(
            name: 'method',
            type: 'string',
            defaultValue: 'sma',
            description: 'sma | ema | savgol',
          ),
          'window': AnalysisParameterSchema(
            name: 'window',
            type: 'number',
            defaultValue: 5,
            description: 'Window length (savgol: odd, ≥5)',
          ),
          'alpha': AnalysisParameterSchema(
            name: 'alpha',
            type: 'number',
            description: 'EMA smoothing factor (default 2/(window+1))',
          ),
          'polyOrder': AnalysisParameterSchema(
            name: 'polyOrder',
            type: 'number',
            defaultValue: 2,
            description: 'Savitzky–Golay polynomial order',
          ),
          'derivative': AnalysisParameterSchema(
            name: 'derivative',
            type: 'number',
            defaultValue: 0,
            description:
                'Savitzky–Golay derivative order (0 = smooth; spectroscopy '
                'uses 1st/2nd derivatives)',
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
    final x = numericColumn(data, column);
    final method = parameters['method'] as String? ?? 'sma';
    final window = math.max(1, (parameters['window'] as num?)?.toInt() ?? 5);

    List<double> out;
    switch (method) {
      case 'ema':
        final alpha = (parameters['alpha'] as num?)?.toDouble() ??
            2.0 / (window + 1);
        out = List<double>.filled(x.length, 0.0);
        for (var i = 0; i < x.length; i++) {
          out[i] = i == 0 ? x[0] : alpha * x[i] + (1 - alpha) * out[i - 1];
        }
        break;
      case 'savgol':
        final w = window.isOdd ? math.max(5, window) : math.max(5, window + 1);
        final order = math.min(
            (parameters['polyOrder'] as num?)?.toInt() ?? 2, w - 2);
        final deriv = math.min(
            (parameters['derivative'] as num?)?.toInt() ?? 0, order);
        final coeffs = _savgolCoefficients(w, order, derivative: deriv);
        final half = w ~/ 2;
        out = List<double>.generate(x.length, (i) {
          var s = 0.0;
          for (var k = -half; k <= half; k++) {
            final j = (i + k).clamp(0, x.length - 1);
            s += coeffs[k + half] * x[j];
          }
          return s;
        });
        break;
      case 'sma':
      default:
        out = List<double>.filled(x.length, 0.0);
        var sum = 0.0;
        for (var i = 0; i < x.length; i++) {
          sum += x[i];
          if (i >= window) sum -= x[i - window];
          out[i] = sum / math.min(i + 1, window);
        }
        break;
    }

    return AnalysisFunctionResult(
      functionName: 'smoothing',
      results: {
        'column': column,
        'method': method,
        'values': out,
        'sampleCount': out.length,
      },
      executionTime: sw.elapsed,
    );
  }

  /// Savitzky–Golay smoothing coefficients via least-squares normal
  /// equations (Gram polynomial fit at the window center).
  List<double> _savgolCoefficients(int window, int order,
      {int derivative = 0}) {
    final half = window ~/ 2;
    // Vandermonde A: rows k=-half..half, cols p=0..order → k^p.
    final a = List.generate(window,
        (r) => List.generate(order + 1, (p) => math.pow(r - half, p).toDouble()));
    // Normal matrix N = AᵀA (size (order+1)²), target = Aᵀe (center weight).
    final m = order + 1;
    final n = List.generate(m, (i) => List<double>.filled(m, 0.0));
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < m; j++) {
        var s = 0.0;
        for (var r = 0; r < window; r++) {
          s += a[r][i] * a[r][j];
        }
        n[i][j] = s;
      }
    }
    // Solve N·c = e_d — the d-th unit vector picks the polynomial
    // coefficient of order d at the window center; ×d! converts it to the
    // derivative value.
    final rhs = List<double>.filled(m, 0.0)..[derivative] = 1.0;
    final c = _solve(n, rhs);
    var factorial = 1.0;
    for (var d = 2; d <= derivative; d++) {
      factorial *= d;
    }
    // Convolution coefficient for offset k = d!·Σ_p c[p]·k^p.
    return List<double>.generate(window, (r) {
      var s = 0.0;
      for (var p = 0; p < m; p++) {
        s += c[p] * math.pow(r - half, p);
      }
      return s * factorial;
    });
  }

  List<double> _solve(List<List<double>> a, List<double> b) {
    final n = b.length;
    final m = [for (var i = 0; i < n; i++) [...a[i], b[i]]];
    for (var col = 0; col < n; col++) {
      var pivot = col;
      for (var r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
      }
      final tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
      final pv = m[col][col];
      for (var r = 0; r < n; r++) {
        if (r == col || m[r][col] == 0) continue;
        final f = m[r][col] / pv;
        for (var c2 = col; c2 <= n; c2++) {
          m[r][c2] -= f * m[col][c2];
        }
      }
    }
    return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
  }
}

/// Differencing (`differencing`) — first/seasonal differences for trend and
/// seasonality removal.
///
/// Parameters: `column`, `order` (default 1), `lag` (default 1; set to the
/// seasonal period for seasonal differencing). Results: `values[]`
/// (length n − order·lag).
class DifferencingFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'differencing',
        description: 'First/seasonal differencing of a series',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to difference',
          ),
          'order': AnalysisParameterSchema(
            name: 'order',
            type: 'number',
            defaultValue: 1,
            description: 'How many times to apply the difference',
          ),
          'lag': AnalysisParameterSchema(
            name: 'lag',
            type: 'number',
            defaultValue: 1,
            description: 'Difference lag (seasonal period for seasonal)',
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
    var x = numericColumn(data, column);
    final order = math.max(1, (parameters['order'] as num?)?.toInt() ?? 1);
    final lag = math.max(1, (parameters['lag'] as num?)?.toInt() ?? 1);

    for (var o = 0; o < order; o++) {
      if (x.length <= lag) {
        throw ArgumentError(
            'differencing exhausted the series (need > $lag samples)');
      }
      x = [for (var i = lag; i < x.length; i++) x[i] - x[i - lag]];
    }

    return AnalysisFunctionResult(
      functionName: 'differencing',
      results: {
        'column': column,
        'values': x,
        'sampleCount': x.length,
      },
      executionTime: sw.elapsed,
    );
  }
}
