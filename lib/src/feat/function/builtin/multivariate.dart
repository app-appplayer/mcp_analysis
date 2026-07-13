import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';
import 'dsp_common.dart';

/// Principal component analysis (`pca`) — Jacobi eigendecomposition of the
/// covariance (or correlation) matrix. The chemometrics/POD gateway: POD of
/// snapshot data IS PCA over the snapshot covariance.
///
/// Parameters: `columns` (default: all numeric), `components` (default:
/// all), `standardize` (correlation-matrix PCA, default true). Results:
/// `explainedVariance[]`, `explainedVarianceRatio[]`, `components[][]`
/// (rows = components, columns = input variables), `scores[][]`
/// (rows = observations).
class PcaFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'pca',
        description:
            'Principal component analysis (Jacobi eigendecomposition)',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Numeric columns (default: all numeric)',
          ),
          'components': AnalysisParameterSchema(
            name: 'components',
            type: 'number',
            description: 'Components to keep (default: all)',
          ),
          'standardize': AnalysisParameterSchema(
            name: 'standardize',
            type: 'boolean',
            defaultValue: true,
            description: 'Correlation-matrix PCA (z-scored inputs)',
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
      throw ArgumentError('pca requires ≥ 2 numeric columns');
    }
    final series = [for (final c in cols) numericColumn(data, c)];
    final n = series.map((s) => s.length).reduce(math.min);
    if (n < 3) throw ArgumentError('pca requires ≥ 3 observations');
    final k = cols.length;
    final standardize = parameters['standardize'] as bool? ?? true;

    // Center (and optionally scale) the data.
    final means = List<double>.filled(k, 0.0);
    final stds = List<double>.filled(k, 1.0);
    for (var j = 0; j < k; j++) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += series[j][i];
      }
      means[j] = sum / n;
      if (standardize) {
        var v = 0.0;
        for (var i = 0; i < n; i++) {
          final d = series[j][i] - means[j];
          v += d * d;
        }
        stds[j] = math.sqrt(math.max(v / (n - 1), 1e-300));
      }
    }
    double cell(int i, int j) => (series[j][i] - means[j]) / stds[j];

    // Covariance of the (centered/scaled) data.
    final cov = List.generate(k, (_) => List<double>.filled(k, 0.0));
    for (var p = 0; p < k; p++) {
      for (var q = p; q < k; q++) {
        var s = 0.0;
        for (var i = 0; i < n; i++) {
          s += cell(i, p) * cell(i, q);
        }
        cov[p][q] = s / (n - 1);
        cov[q][p] = cov[p][q];
      }
    }

    final (eigenvalues, eigenvectors) = _jacobiEigen(cov);
    // Sort descending by eigenvalue.
    final order = List<int>.generate(k, (i) => i)
      ..sort((a, b) => eigenvalues[b].compareTo(eigenvalues[a]));
    final keep = math.min(
        (parameters['components'] as num?)?.toInt() ?? k, k);
    final total = eigenvalues.fold(0.0, (a, b) => a + math.max(b, 0.0));

    final explained = [for (var c = 0; c < keep; c++) math.max(eigenvalues[order[c]], 0.0)];
    final components = [
      for (var c = 0; c < keep; c++)
        [for (var j = 0; j < k; j++) eigenvectors[j][order[c]]],
    ];
    final scores = [
      for (var i = 0; i < n; i++)
        [
          for (var c = 0; c < keep; c++)
            () {
              var s = 0.0;
              for (var j = 0; j < k; j++) {
                s += cell(i, j) * components[c][j];
              }
              return s;
            }(),
        ],
    ];

    return AnalysisFunctionResult(
      functionName: 'pca',
      results: {
        'columns': cols,
        'explainedVariance': explained,
        'explainedVarianceRatio': [
          for (final e in explained) total > 0 ? e / total : 0.0,
        ],
        'components': components,
        'scores': scores,
      },
      executionTime: sw.elapsed,
    );
  }

  /// Cyclic Jacobi eigendecomposition for a symmetric matrix — deterministic
  /// quadratic convergence, pure Dart.
  (List<double>, List<List<double>>) _jacobiEigen(List<List<double>> input) {
    final k = input.length;
    final a = [for (final row in input) List<double>.from(row)];
    final v = List.generate(
        k, (i) => List<double>.generate(k, (j) => i == j ? 1.0 : 0.0));

    for (var sweep = 0; sweep < 100; sweep++) {
      var off = 0.0;
      for (var p = 0; p < k; p++) {
        for (var q = p + 1; q < k; q++) {
          off += a[p][q] * a[p][q];
        }
      }
      if (off < 1e-22) break;
      for (var p = 0; p < k; p++) {
        for (var q = p + 1; q < k; q++) {
          if (a[p][q].abs() < 1e-300) continue;
          final theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
          final t = (theta >= 0 ? 1.0 : -1.0) /
              (theta.abs() + math.sqrt(theta * theta + 1));
          final c = 1 / math.sqrt(t * t + 1);
          final s = t * c;
          for (var i = 0; i < k; i++) {
            final aip = a[i][p], aiq = a[i][q];
            a[i][p] = c * aip - s * aiq;
            a[i][q] = s * aip + c * aiq;
          }
          for (var i = 0; i < k; i++) {
            final api = a[p][i], aqi = a[q][i];
            a[p][i] = c * api - s * aqi;
            a[q][i] = s * api + c * aqi;
          }
          for (var i = 0; i < k; i++) {
            final vip = v[i][p], viq = v[i][q];
            v[i][p] = c * vip - s * viq;
            v[i][q] = s * vip + c * viq;
          }
        }
      }
    }
    return ([for (var i = 0; i < k; i++) a[i][i]], v);
  }
}

/// Lomb–Scargle periodogram (`lomb_scargle`) — period detection for
/// UNEVENLY sampled series (astronomy, sparse sensors, event-driven logs)
/// where FFT/ACF assumptions break.
///
/// Parameters: `columns` ([time, value]; time in arbitrary consistent
/// units), `minFrequency`/`maxFrequency` (cycles per time unit; defaults
/// derived from the span), `frequencySteps` (default 500). Results:
/// `frequencies[]`, `power[]` (normalized), `bestFrequency`, `bestPeriod`,
/// `bestPower`.
class LombScargleFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'lomb_scargle',
        description:
            'Lomb–Scargle periodogram for unevenly sampled series',
        parameters: {
          'columns': AnalysisParameterSchema(
            name: 'columns',
            type: 'array',
            description: 'Exactly two columns [time, value]',
          ),
          'minFrequency': AnalysisParameterSchema(
            name: 'minFrequency',
            type: 'number',
            description: 'Lowest frequency to scan (default 1/span)',
          ),
          'maxFrequency': AnalysisParameterSchema(
            name: 'maxFrequency',
            type: 'number',
            description:
                'Highest frequency (default pseudo-Nyquist n/(2·span))',
          ),
          'frequencySteps': AnalysisParameterSchema(
            name: 'frequencySteps',
            type: 'number',
            defaultValue: 500,
            description: 'Frequency grid resolution',
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
      throw ArgumentError('lomb_scargle requires columns: [time, value]');
    }
    final t = numericColumn(data, cols[0]);
    final y = numericColumn(data, cols[1]);
    final n = math.min(t.length, y.length);
    if (n < 8) throw ArgumentError('lomb_scargle requires ≥ 8 samples');

    final span = t.sublist(0, n).reduce(math.max) -
        t.sublist(0, n).reduce(math.min);
    if (span <= 0) throw ArgumentError('lomb_scargle: zero time span');
    final fMin =
        (parameters['minFrequency'] as num?)?.toDouble() ?? 1.0 / span;
    final fMax = (parameters['maxFrequency'] as num?)?.toDouble() ??
        n / (2.0 * span);
    final steps =
        math.max(10, (parameters['frequencySteps'] as num?)?.toInt() ?? 500);

    final mean = y.sublist(0, n).reduce((a, b) => a + b) / n;
    final yc = [for (var i = 0; i < n; i++) y[i] - mean];
    final variance =
        yc.map((v) => v * v).reduce((a, b) => a + b) / (n - 1);

    final freqs = <double>[];
    final power = <double>[];
    var bestIdx = 0;
    for (var s = 0; s < steps; s++) {
      final f = fMin + (fMax - fMin) * s / (steps - 1);
      final omega = 2 * math.pi * f;
      // Time offset tau for the classic Lomb normalization.
      var s2 = 0.0, c2 = 0.0;
      for (var i = 0; i < n; i++) {
        s2 += math.sin(2 * omega * t[i]);
        c2 += math.cos(2 * omega * t[i]);
      }
      final tau = math.atan2(s2, c2) / (2 * omega);
      var cs = 0.0, cc = 0.0, ss = 0.0, sc = 0.0;
      for (var i = 0; i < n; i++) {
        final arg = omega * (t[i] - tau);
        final co = math.cos(arg), si = math.sin(arg);
        cs += yc[i] * co;
        sc += yc[i] * si;
        cc += co * co;
        ss += si * si;
      }
      final p = variance > 0
          ? ((cc > 0 ? cs * cs / cc : 0.0) + (ss > 0 ? sc * sc / ss : 0.0)) /
              (2 * variance)
          : 0.0;
      freqs.add(f);
      power.add(p);
      if (p > power[bestIdx]) bestIdx = power.length - 1;
    }

    return AnalysisFunctionResult(
      functionName: 'lomb_scargle',
      results: {
        'columns': cols,
        'frequencies': freqs,
        'power': power,
        'bestFrequency': freqs[bestIdx],
        'bestPeriod': freqs[bestIdx] > 0 ? 1 / freqs[bestIdx] : 0.0,
        'bestPower': power[bestIdx],
      },
      executionTime: sw.elapsed,
    );
  }
}
