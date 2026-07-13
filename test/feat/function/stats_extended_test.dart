import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

AnalysisDataSet _cols(Map<String, List<double>> series) {
  final names = series.keys.toList();
  final n = series.values.map((v) => v.length).reduce(math.min);
  return AnalysisDataSet(
    columns: [
      for (final name in names) AnalysisColumnInfo(name: name, type: 'double'),
    ],
    rows: [
      for (var i = 0; i < n; i++)
        <String, dynamic>{for (final name in names) name: series[name]![i]},
    ],
    rowCount: n,
  );
}

void main() {
  group('histogram', () {
    test('bins a uniform ramp evenly', () async {
      final r = await HistogramFunction().execute(
          {'bins': 5, 'min': 0, 'max': 100},
          _cols({'v': [for (var i = 0; i < 100; i++) i.toDouble()]}));
      expect((r.results['counts'] as List).cast<int>(), [20, 20, 20, 20, 20]);
      expect(r.results['underflow'], 0);
      expect(r.results['overflow'], 0);
    });
  });

  group('covariance_matrix', () {
    test('perfectly correlated columns → correlation 1', () async {
      final x = [for (var i = 0; i < 50; i++) i.toDouble()];
      final r = await CovarianceMatrixFunction().execute({}, _cols({
        'a': x,
        'b': [for (final v in x) 2 * v + 3],
      }));
      final corr = (r.results['correlation'] as List);
      expect((corr[0] as List)[1], closeTo(1.0, 1e-9));
    });

    test('independent noise → correlation near 0', () async {
      final rng = math.Random(4);
      final r = await CovarianceMatrixFunction().execute({}, _cols({
        'a': [for (var i = 0; i < 2000; i++) rng.nextDouble()],
        'b': [for (var i = 0; i < 2000; i++) rng.nextDouble()],
      }));
      final corr = (r.results['correlation'] as List);
      expect(((corr[0] as List)[1] as double).abs(), lessThan(0.1));
    });
  });

  group('regression', () {
    test('recovers linear coefficients exactly', () async {
      final x = [for (var i = 0; i < 30; i++) i.toDouble()];
      final r = await RegressionFunction().execute({'columns': ['x', 'y']},
          _cols({'x': x, 'y': [for (final v in x) 4.0 * v - 7.0]}));
      final c = (r.results['coefficients'] as List).cast<double>();
      expect(c[0], closeTo(-7.0, 1e-6));
      expect(c[1], closeTo(4.0, 1e-8));
      expect(r.results['rSquared'], closeTo(1.0, 1e-12));
    });

    test('degree-2 fits a parabola', () async {
      final x = [for (var i = -10; i <= 10; i++) i.toDouble()];
      final r = await RegressionFunction().execute(
          {'columns': ['x', 'y'], 'degree': 2},
          _cols({'x': x, 'y': [for (final v in x) 0.5 * v * v + v - 3]}));
      final c = (r.results['coefficients'] as List).cast<double>();
      expect(c[2], closeTo(0.5, 1e-8));
      expect(c[1], closeTo(1.0, 1e-8));
      expect(c[0], closeTo(-3.0, 1e-6));
    });
  });

  group('hypothesis_test', () {
    test('t-test separates shifted means, accepts equal means', () async {
      final rng = math.Random(6);
      List<double> noise(double mu) =>
          [for (var i = 0; i < 200; i++) mu + (rng.nextDouble() - 0.5)];
      final shifted = await HypothesisTestFunction().execute(
          {'columns': ['a', 'b']},
          _cols({'a': noise(0.0), 'b': noise(1.0)}));
      expect(shifted.results['significant'], isTrue);

      final same = await HypothesisTestFunction().execute(
          {'columns': ['a', 'b']},
          _cols({'a': noise(5.0), 'b': noise(5.0)}));
      expect(same.results['significant'], isFalse);
    });

    test('KS flags different distributions', () async {
      final rng = math.Random(8);
      final uniform = [for (var i = 0; i < 300; i++) rng.nextDouble()];
      final squashed = [for (var i = 0; i < 300; i++) rng.nextDouble() * 0.3];
      final r = await HypothesisTestFunction().execute(
          {'columns': ['a', 'b'], 'test': 'ks'},
          _cols({'a': uniform, 'b': squashed}));
      expect(r.results['significant'], isTrue);
    });
  });

  group('interpolate', () {
    test('linear midpoints of a ramp', () async {
      final r = await InterpolateFunction().execute(
          {'columns': ['x', 'y'], 'queryPoints': [1.5, 2.5]},
          _cols({
            'x': [0.0, 1.0, 2.0, 3.0],
            'y': [0.0, 10.0, 20.0, 30.0],
          }));
      expect((r.results['values'] as List).cast<double>(),
          [closeTo(15.0, 1e-9), closeTo(25.0, 1e-9)]);
    });

    test('spline reproduces a smooth curve better than clamping', () async {
      // y = sin(x) sampled coarsely; spline at π/2-ish should be near 1.
      final xs = [for (var i = 0; i <= 6; i++) i * 0.5];
      final r = await InterpolateFunction().execute(
          {
            'columns': ['x', 'y'],
            'method': 'spline',
            'queryPoints': [math.pi / 2],
          },
          _cols({'x': xs, 'y': [for (final v in xs) math.sin(v)]}));
      final v = (r.results['values'] as List).cast<double>().single;
      expect(v, closeTo(1.0, 0.01));
    });
  });
}
