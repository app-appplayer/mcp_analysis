import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

double _mean(List<double> x) =>
    x.isEmpty ? 0.0 : x.reduce((a, b) => a + b) / x.length;

/// Autocorrelation with automatic period detection (`acf`) — completes the
/// `seasonality` builtin's half-contract (which only VERIFIES a user-given
/// period).
///
/// Parameters: `column`, `maxLag` (default min(n/2, 500)). Results:
/// `acf[]` (lag 0..maxLag, normalized), `detectedPeriod` (lag of the
/// highest ACF local maximum above the significance floor, 0 = none),
/// `periodConfidence` (that ACF value), `significanceLevel` (±2/√n).
class AcfFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'acf',
        description:
            'Autocorrelation function with automatic period detection',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to analyze',
          ),
          'maxLag': AnalysisParameterSchema(
            name: 'maxLag',
            type: 'number',
            description: 'Maximum lag (default min(n/2, 500))',
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
    if (x.length < 4) {
      throw ArgumentError('acf requires at least 4 samples');
    }
    final maxLag = math.min(
        (parameters['maxLag'] as num?)?.toInt() ?? math.min(x.length ~/ 2, 500),
        x.length - 1);

    final mean = _mean(x);
    final centered = [for (final v in x) v - mean];
    final denom =
        centered.map((v) => v * v).reduce((a, b) => a + b);

    final acf = List<double>.filled(maxLag + 1, 0.0);
    if (denom > 0) {
      for (var lag = 0; lag <= maxLag; lag++) {
        var s = 0.0;
        for (var i = 0; i + lag < centered.length; i++) {
          s += centered[i] * centered[i + lag];
        }
        acf[lag] = s / denom;
      }
    }

    // Detected period = lag of the highest local ACF maximum above the
    // white-noise significance floor.
    final significance = 2 / math.sqrt(x.length);
    var detected = 0;
    var confidence = 0.0;
    for (var lag = 2; lag < maxLag; lag++) {
      final isLocalMax = acf[lag] > acf[lag - 1] && acf[lag] >= acf[lag + 1];
      if (isLocalMax && acf[lag] > significance && acf[lag] > confidence) {
        detected = lag;
        confidence = acf[lag];
      }
    }

    return AnalysisFunctionResult(
      functionName: 'acf',
      results: {
        'column': column,
        'acf': acf,
        'detectedPeriod': detected,
        'periodConfidence': confidence,
        'significanceLevel': significance,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Cross-correlation between two columns (`cross_correlation`) — lag
/// analysis ("pressure follows temperature by k samples").
///
/// Parameters: `columns` ([a, b]), `maxLag` (default min(n/2, 200)).
/// Results: `lags[]` (−maxLag..+maxLag), `correlations[]` (normalized;
/// positive lag = b lags behind a), `bestLag`, `bestCorrelation`.
class CrossCorrelationFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'cross_correlation',
        description: 'Normalized cross-correlation over a lag range',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Exactly two numeric columns [a, b]',
          ),
          'maxLag': AnalysisParameterSchema(
            name: 'maxLag',
            type: 'number',
            description: 'Maximum |lag| (default min(n/2, 200))',
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
    final cols = (parameters['columns'] as List?)?.cast<String>();
    if (cols == null || cols.length != 2) {
      throw ArgumentError('cross_correlation requires columns: [a, b]');
    }
    final a = numericColumn(data, cols[0]);
    final b = numericColumn(data, cols[1]);
    final n = math.min(a.length, b.length);
    if (n < 4) {
      throw ArgumentError('cross_correlation requires at least 4 samples');
    }
    final maxLag = math.min(
        (parameters['maxLag'] as num?)?.toInt() ?? math.min(n ~/ 2, 200),
        n - 1);

    final ma = _mean(a.sublist(0, n)), mb = _mean(b.sublist(0, n));
    var va = 0.0, vb = 0.0;
    for (var i = 0; i < n; i++) {
      va += (a[i] - ma) * (a[i] - ma);
      vb += (b[i] - mb) * (b[i] - mb);
    }
    final norm = math.sqrt(va * vb);

    final lags = <int>[];
    final corrs = <double>[];
    var bestLag = 0;
    var bestCorr = 0.0;
    for (var lag = -maxLag; lag <= maxLag; lag++) {
      var s = 0.0;
      for (var i = 0; i < n; i++) {
        final j = i + lag;
        if (j < 0 || j >= n) continue;
        s += (a[i] - ma) * (b[j] - mb);
      }
      final c = norm > 0 ? s / norm : 0.0;
      lags.add(lag);
      corrs.add(c);
      if (c.abs() > bestCorr.abs()) {
        bestCorr = c;
        bestLag = lag;
      }
    }

    return AnalysisFunctionResult(
      functionName: 'cross_correlation',
      results: {
        'columns': cols,
        'lags': lags,
        'correlations': corrs,
        'bestLag': bestLag,
        'bestCorrelation': bestCorr,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// CUSUM mean-shift changepoint detection (`changepoint_cusum`).
///
/// Parameters: `column`, `threshold` (in σ units, default 5), `drift`
/// (allowed slack in σ, default 0.5). Results: `changepoints[]` (indices),
/// `count`.
class ChangepointCusumFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'changepoint_cusum',
        description: 'CUSUM mean-shift changepoint detection',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to analyze',
          ),
          'threshold': AnalysisParameterSchema(
            name: 'threshold',
            type: 'number',
            defaultValue: 5,
            description: 'Decision threshold in σ units',
          ),
          'drift': AnalysisParameterSchema(
            name: 'drift',
            type: 'number',
            defaultValue: 0.5,
            description: 'Allowed drift (slack) in σ units',
          ),
          'baselineWindow': AnalysisParameterSchema(
            name: 'baselineWindow',
            type: 'number',
            description:
                'Calibration window for the baseline mean/std '
                '(default min(50, n/4); monitoring starts after it)',
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
    if (x.length < 8) {
      throw ArgumentError('changepoint_cusum requires at least 8 samples');
    }
    final hSigma = (parameters['threshold'] as num?)?.toDouble() ?? 5.0;
    final kSigma = (parameters['drift'] as num?)?.toDouble() ?? 0.5;
    // Self-starting CUSUM: the baseline mean/std MUST come from a
    // calibration window, never the whole series — a shift inside the data
    // would contaminate a global baseline and turn the pre-shift segment
    // into a sustained false deviation.
    final baselineWindow = math.max(
        8,
        (parameters['baselineWindow'] as num?)?.toInt() ??
            math.min(50, x.length ~/ 4));

    (double, double) calibrate(int from) {
      final seg = x.sublist(from, math.min(x.length, from + baselineWindow));
      final m = _mean(seg);
      final v = seg.length > 1
          ? seg.map((e) => (e - m) * (e - m)).reduce((a, b) => a + b) /
              (seg.length - 1)
          : 0.0;
      return (m, math.sqrt(math.max(v, 1e-12)));
    }

    var (mean, std) = calibrate(0);
    final changepoints = <int>[];
    var hi = 0.0, lo = 0.0;
    var i = baselineWindow;
    while (i < x.length) {
      final z = (x[i] - mean) / std;
      hi = math.max(0, hi + z - kSigma);
      lo = math.min(0, lo + z + kSigma);
      if (hi > hSigma || lo < -hSigma) {
        changepoints.add(i);
        // Re-baseline on the post-change segment so later shifts detect too.
        (mean, std) = calibrate(i);
        hi = 0.0;
        lo = 0.0;
        i += baselineWindow; // monitored again after recalibration
        continue;
      }
      i++;
    }

    return AnalysisFunctionResult(
      functionName: 'changepoint_cusum',
      results: {
        'column': column,
        'changepoints': changepoints,
        'count': changepoints.length,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Holt–Winters forecasting (`holt_winters`) — additive triple exponential
/// smoothing; seasonal component optional (period 0 → Holt's double
/// smoothing).
///
/// Parameters: `column`, `horizon` (steps ahead, default 10), `period`
/// (seasonal length, 0 = non-seasonal), `alpha`/`beta`/`gamma` (defaults
/// 0.3/0.1/0.1). Results: `forecast[]`, `fittedLast`, `level`, `trend`.
class HoltWintersFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'holt_winters',
        description:
            'Additive Holt–Winters exponential-smoothing forecast',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to forecast',
          ),
          'horizon': AnalysisParameterSchema(
            name: 'horizon',
            type: 'number',
            defaultValue: 10,
            description: 'Steps ahead to forecast',
          ),
          'period': AnalysisParameterSchema(
            name: 'period',
            type: 'number',
            defaultValue: 0,
            description: 'Seasonal period (0 = non-seasonal)',
          ),
          'alpha': AnalysisParameterSchema(
            name: 'alpha',
            type: 'number',
            defaultValue: 0.3,
            description: 'Level smoothing factor',
          ),
          'beta': AnalysisParameterSchema(
            name: 'beta',
            type: 'number',
            defaultValue: 0.1,
            description: 'Trend smoothing factor',
          ),
          'gamma': AnalysisParameterSchema(
            name: 'gamma',
            type: 'number',
            defaultValue: 0.1,
            description: 'Seasonal smoothing factor',
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
    final period = (parameters['period'] as num?)?.toInt() ?? 0;
    final horizon = math.max(1, (parameters['horizon'] as num?)?.toInt() ?? 10);
    final alpha = (parameters['alpha'] as num?)?.toDouble() ?? 0.3;
    final beta = (parameters['beta'] as num?)?.toDouble() ?? 0.1;
    final gamma = (parameters['gamma'] as num?)?.toDouble() ?? 0.1;

    final minLen = period > 0 ? 2 * period : 4;
    if (x.length < minLen) {
      throw ArgumentError(
          'holt_winters requires at least $minLen samples for these settings');
    }

    var level = x[0];
    var trend = x.length > 1 ? x[1] - x[0] : 0.0;
    final seasonal = period > 0
        ? List<double>.generate(period, (i) {
            // Initial seasonal indices: deviation of each phase mean from
            // the first-cycle mean.
            final firstCycleMean = _mean(x.sublist(0, period));
            return x[i] - firstCycleMean;
          })
        : <double>[];

    var fitted = level;
    for (var i = 0; i < x.length; i++) {
      final s = period > 0 ? seasonal[i % period] : 0.0;
      fitted = level + trend + s;
      final prevLevel = level;
      level = alpha * (x[i] - s) + (1 - alpha) * (level + trend);
      trend = beta * (level - prevLevel) + (1 - beta) * trend;
      if (period > 0) {
        seasonal[i % period] = gamma * (x[i] - level) + (1 - gamma) * s;
      }
    }

    final forecast = List<double>.generate(horizon, (h) {
      final s = period > 0 ? seasonal[(x.length + h) % period] : 0.0;
      return level + (h + 1) * trend + s;
    });

    return AnalysisFunctionResult(
      functionName: 'holt_winters',
      results: {
        'column': column,
        'forecast': forecast,
        'fittedLast': fitted,
        'level': level,
        'trend': trend,
      },
      executionTime: sw.elapsed,
    );
  }
}
