import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

double _mean(List<double> x) =>
    x.isEmpty ? 0.0 : x.reduce((a, b) => a + b) / x.length;

double _sampleStd(List<double> x) {
  if (x.length < 2) return 0.0;
  final m = _mean(x);
  final v = x.map((e) => (e - m) * (e - m)).reduce((a, b) => a + b) /
      (x.length - 1);
  return math.sqrt(v);
}

/// Histogram (`histogram`) — fixed-width binning with optional explicit
/// range.
///
/// Parameters: `column`, `bins` (default 10), `min`/`max` (optional
/// explicit range; data range otherwise). Results: `binEdges[]` (length
/// bins+1), `counts[]`, `underflow`, `overflow`.
class HistogramFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'histogram',
        description: 'Fixed-width histogram binning',
        parameters: {
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'Numeric column to bin',
          ),
          'bins': AnalysisParameterSchema(
            name: 'bins',
            type: 'number',
            defaultValue: 10,
            description: 'Number of bins',
          ),
          'min': AnalysisParameterSchema(
            name: 'min',
            type: 'number',
            description: 'Explicit lower edge (data min otherwise)',
          ),
          'max': AnalysisParameterSchema(
            name: 'max',
            type: 'number',
            description: 'Explicit upper edge (data max otherwise)',
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
    if (x.isEmpty) throw ArgumentError('histogram requires samples');
    final bins = math.max(1, (parameters['bins'] as num?)?.toInt() ?? 10);
    final lo = (parameters['min'] as num?)?.toDouble() ?? x.reduce(math.min);
    final hi = (parameters['max'] as num?)?.toDouble() ?? x.reduce(math.max);
    final width = (hi - lo) <= 0 ? 1.0 : (hi - lo) / bins;

    final counts = List<int>.filled(bins, 0);
    var underflow = 0, overflow = 0;
    for (final v in x) {
      if (v < lo) {
        underflow++;
      } else if (v > hi) {
        overflow++;
      } else {
        counts[math.min(((v - lo) / width).floor(), bins - 1)]++;
      }
    }

    return AnalysisFunctionResult(
      functionName: 'histogram',
      results: {
        'column': column,
        'binEdges': [for (var i = 0; i <= bins; i++) lo + i * width],
        'counts': counts,
        'underflow': underflow,
        'overflow': overflow,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Covariance/correlation matrix over N columns (`covariance_matrix`).
///
/// Parameters: `columns` (default: all numeric). Results: `columns[]`,
/// `covariance[][]` (sample), `correlation[][]` (Pearson).
class CovarianceMatrixFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'covariance_matrix',
        description: 'Sample covariance + Pearson correlation matrices',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Numeric columns (default: all numeric)',
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
    final cols = (parameters['columns'] as List?)?.cast<String>() ??
        [
          for (final c in data.columns)
            if (c.type == 'double' || c.type == 'int') c.name,
        ];
    if (cols.length < 2) {
      throw ArgumentError('covariance_matrix requires ≥ 2 numeric columns');
    }
    final series = [for (final c in cols) numericColumn(data, c)];
    final n = series.map((s) => s.length).reduce(math.min);
    if (n < 2) throw ArgumentError('covariance_matrix requires ≥ 2 rows');
    final means = [for (final s in series) _mean(s.sublist(0, n))];

    final k = cols.length;
    final cov = List.generate(k, (_) => List<double>.filled(k, 0.0));
    for (var i = 0; i < k; i++) {
      for (var j = i; j < k; j++) {
        var s = 0.0;
        for (var r = 0; r < n; r++) {
          s += (series[i][r] - means[i]) * (series[j][r] - means[j]);
        }
        cov[i][j] = s / (n - 1);
        cov[j][i] = cov[i][j];
      }
    }
    final corr = List.generate(k, (i) {
      return List<double>.generate(k, (j) {
        final d = math.sqrt(cov[i][i] * cov[j][j]);
        return d > 0 ? cov[i][j] / d : 0.0;
      });
    });

    return AnalysisFunctionResult(
      functionName: 'covariance_matrix',
      results: {
        'columns': cols,
        'covariance': cov,
        'correlation': corr,
        'rowCount': n,
      },
      executionTime: sw.elapsed,
    );
  }
}

/// Least-squares polynomial regression (`regression`) — linear by default.
///
/// Parameters: `columns` ([x, y]; or `column` = y against sample index),
/// `degree` (default 1). Results: `coefficients[]` (ascending powers),
/// `rSquared`, `predictions[]` (fitted values).
class RegressionFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'regression',
        description:
            'Least-squares polynomial regression (linear by default)',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: '[x, y] columns (or use column= y vs index)',
          ),
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'y column regressed against the sample index',
          ),
          'degree': AnalysisParameterSchema(
            name: 'degree',
            type: 'number',
            defaultValue: 1,
            description: 'Polynomial degree',
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
    List<double> xs, ys;
    if (cols != null && cols.length == 2) {
      xs = numericColumn(data, cols[0]);
      ys = numericColumn(data, cols[1]);
    } else {
      ys = numericColumn(data, resolveColumn(parameters, data));
      xs = [for (var i = 0; i < ys.length; i++) i.toDouble()];
    }
    final n = math.min(xs.length, ys.length);
    final degree = math.max(1, (parameters['degree'] as num?)?.toInt() ?? 1);
    if (n < degree + 1) {
      throw ArgumentError('regression(degree=$degree) requires ≥ '
          '${degree + 1} samples');
    }

    // Normal equations XᵀX·c = Xᵀy over the Vandermonde design matrix.
    final m = degree + 1;
    final xtx = List.generate(m, (_) => List<double>.filled(m, 0.0));
    final xty = List<double>.filled(m, 0.0);
    for (var r = 0; r < n; r++) {
      final powers = List<double>.filled(2 * m - 1, 1.0);
      for (var p = 1; p < powers.length; p++) {
        powers[p] = powers[p - 1] * xs[r];
      }
      for (var i = 0; i < m; i++) {
        xty[i] += powers[i] * ys[r];
        for (var j = 0; j < m; j++) {
          xtx[i][j] += powers[i + j];
        }
      }
    }
    final coeffs = _solve(xtx, xty);

    final predictions = List<double>.generate(n, (r) {
      var acc = 0.0;
      var pw = 1.0;
      for (var p = 0; p < m; p++) {
        acc += coeffs[p] * pw;
        pw *= xs[r];
      }
      return acc;
    });
    final meanY = _mean(ys.sublist(0, n));
    var ssRes = 0.0, ssTot = 0.0;
    for (var r = 0; r < n; r++) {
      ssRes += math.pow(ys[r] - predictions[r], 2);
      ssTot += math.pow(ys[r] - meanY, 2);
    }
    final r2 = ssTot > 0 ? 1 - ssRes / ssTot : 1.0;

    return AnalysisFunctionResult(
      functionName: 'regression',
      results: {
        'coefficients': coeffs,
        'rSquared': r2,
        'predictions': predictions,
      },
      executionTime: sw.elapsed,
    );
  }

  List<double> _solve(List<List<double>> a, List<double> b) {
    final n = b.length;
    final mtx = [for (var i = 0; i < n; i++) [...a[i], b[i]]];
    for (var col = 0; col < n; col++) {
      var pivot = col;
      for (var r = col + 1; r < n; r++) {
        if (mtx[r][col].abs() > mtx[pivot][col].abs()) pivot = r;
      }
      final tmp = mtx[col];
      mtx[col] = mtx[pivot];
      mtx[pivot] = tmp;
      final pv = mtx[col][col];
      if (pv.abs() < 1e-12) {
        throw StateError('regression design matrix is singular');
      }
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final f = mtx[r][col] / pv;
        for (var c = col; c <= n; c++) {
          mtx[r][c] -= f * mtx[col][c];
        }
      }
    }
    return [for (var i = 0; i < n; i++) mtx[i][n] / mtx[i][i]];
  }
}

/// Two-sample hypothesis tests (`hypothesis_test`).
///
/// Parameters: `columns` ([a, b]), `test` (ttest|ks, default ttest).
/// Results — ttest: `statistic` (Welch t), `degreesOfFreedom`, `significant`
/// (|t| vs 1.96); ks: `statistic` (D), `criticalValue` (α=0.05),
/// `significant`.
class HypothesisTestFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'hypothesis_test',
        description:
            'Two-sample tests: Welch t-test, Kolmogorov–Smirnov',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Exactly two numeric columns [a, b]',
          ),
          'test': AnalysisParameterSchema(
            name: 'test',
            type: 'string',
            defaultValue: 'ttest',
            description: 'ttest | ks',
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
      throw ArgumentError('hypothesis_test requires columns: [a, b]');
    }
    final a = numericColumn(data, cols[0]);
    final b = numericColumn(data, cols[1]);
    if (a.length < 3 || b.length < 3) {
      throw ArgumentError('hypothesis_test requires ≥ 3 samples per column');
    }
    final testName = parameters['test'] as String? ?? 'ttest';

    final results = <String, dynamic>{'test': testName, 'columns': cols};
    if (testName == 'ks') {
      final sa = List<double>.from(a)..sort();
      final sb = List<double>.from(b)..sort();
      var i = 0, j = 0;
      var d = 0.0;
      while (i < sa.length && j < sb.length) {
        if (sa[i] <= sb[j]) {
          i++;
        } else {
          j++;
        }
        d = math.max(
            d, ((i / sa.length) - (j / sb.length)).abs());
      }
      final critical = 1.358 *
          math.sqrt((sa.length + sb.length) / (sa.length * sb.length));
      results['statistic'] = d;
      results['criticalValue'] = critical;
      results['significant'] = d > critical;
    } else {
      final ma = _mean(a), mb = _mean(b);
      final va = math.pow(_sampleStd(a), 2) / a.length;
      final vb = math.pow(_sampleStd(b), 2) / b.length;
      final se = math.sqrt(va + vb);
      final t = se > 0 ? (ma - mb) / se : 0.0;
      final df = se > 0
          ? math.pow(va + vb, 2) /
              (math.pow(va, 2) / (a.length - 1) +
                  math.pow(vb, 2) / (b.length - 1))
          : (a.length + b.length - 2).toDouble();
      results['statistic'] = t;
      results['degreesOfFreedom'] = df;
      results['significant'] = t.abs() > 1.96; // large-sample α≈0.05
    }

    return AnalysisFunctionResult(
      functionName: 'hypothesis_test',
      results: results,
      executionTime: sw.elapsed,
    );
  }
}

/// Interpolation (`interpolate`) — linear or natural cubic spline over
/// (x, y) pairs onto a query grid.
///
/// Parameters: `columns` ([x, y]; or `column`= y vs index), `method`
/// (linear|spline, default linear), `queryPoints[]` (x positions; default
/// midpoints). Results: `queryPoints[]`, `values[]`.
class InterpolateFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'interpolate',
        description: 'Linear / natural cubic-spline interpolation',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: '[x, y] columns (or use column= y vs index)',
          ),
          'column': AnalysisParameterSchema(
            name: 'column',
            type: 'string',
            description: 'y column against the sample index',
          ),
          'method': AnalysisParameterSchema(
            name: 'method',
            type: 'string',
            defaultValue: 'linear',
            description: 'linear | spline',
          ),
          'queryPoints': AnalysisParameterSchema(
            name: 'queryPoints',
            type: 'array',
            description: 'x positions to evaluate (default: midpoints)',
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
    List<double> xs, ys;
    if (cols != null && cols.length == 2) {
      xs = numericColumn(data, cols[0]);
      ys = numericColumn(data, cols[1]);
    } else {
      ys = numericColumn(data, resolveColumn(parameters, data));
      xs = [for (var i = 0; i < ys.length; i++) i.toDouble()];
    }
    final n = math.min(xs.length, ys.length);
    if (n < 2) throw ArgumentError('interpolate requires ≥ 2 points');
    final method = parameters['method'] as String? ?? 'linear';
    final queries = (parameters['queryPoints'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList() ??
        [for (var i = 0; i < n - 1; i++) (xs[i] + xs[i + 1]) / 2];

    List<double> values;
    if (method == 'spline') {
      values = _spline(xs.sublist(0, n), ys.sublist(0, n), queries);
    } else {
      values = [
        for (final q in queries) _linear(xs.sublist(0, n), ys.sublist(0, n), q),
      ];
    }

    return AnalysisFunctionResult(
      functionName: 'interpolate',
      results: {
        'method': method,
        'queryPoints': queries,
        'values': values,
      },
      executionTime: sw.elapsed,
    );
  }

  double _linear(List<double> xs, List<double> ys, double q) {
    if (q <= xs.first) return ys.first;
    if (q >= xs.last) return ys.last;
    var lo = 0, hi = xs.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (xs[mid] <= q) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final frac = (q - xs[lo]) / (xs[hi] - xs[lo]);
    return ys[lo] * (1 - frac) + ys[hi] * frac;
  }

  /// Natural cubic spline (second derivative 0 at both ends), Thomas
  /// algorithm over the tridiagonal system.
  List<double> _spline(List<double> xs, List<double> ys, List<double> qs) {
    final n = xs.length;
    if (n < 3) return [for (final q in qs) _linear(xs, ys, q)];
    final h = [for (var i = 0; i < n - 1; i++) xs[i + 1] - xs[i]];
    final alpha = List<double>.filled(n, 0.0);
    for (var i = 1; i < n - 1; i++) {
      alpha[i] = 3 * ((ys[i + 1] - ys[i]) / h[i] - (ys[i] - ys[i - 1]) / h[i - 1]);
    }
    final l = List<double>.filled(n, 1.0);
    final mu = List<double>.filled(n, 0.0);
    final z = List<double>.filled(n, 0.0);
    for (var i = 1; i < n - 1; i++) {
      l[i] = 2 * (xs[i + 1] - xs[i - 1]) - h[i - 1] * mu[i - 1];
      mu[i] = h[i] / l[i];
      z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i];
    }
    final c = List<double>.filled(n, 0.0);
    final bC = List<double>.filled(n - 1, 0.0);
    final dC = List<double>.filled(n - 1, 0.0);
    for (var j = n - 2; j >= 0; j--) {
      c[j] = z[j] - mu[j] * c[j + 1];
      bC[j] = (ys[j + 1] - ys[j]) / h[j] - h[j] * (c[j + 1] + 2 * c[j]) / 3;
      dC[j] = (c[j + 1] - c[j]) / (3 * h[j]);
    }
    return [
      for (final q in qs)
        () {
          if (q <= xs.first) return ys.first;
          if (q >= xs.last) return ys.last;
          var lo = 0, hi = n - 1;
          while (hi - lo > 1) {
            final mid = (lo + hi) ~/ 2;
            if (xs[mid] <= q) {
              lo = mid;
            } else {
              hi = mid;
            }
          }
          final dx = q - xs[lo];
          return ys[lo] + bC[lo] * dx + c[lo] * dx * dx + dC[lo] * dx * dx * dx;
        }(),
    ];
  }
}
