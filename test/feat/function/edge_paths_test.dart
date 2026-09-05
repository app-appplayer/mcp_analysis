import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Audit-pass edge coverage: paths the known-value suites did not touch —
/// non-power-of-two FFT input (zero-padding), tumbling × maxPoints
/// interplay, non-standardized PCA, harmonics fundamental auto-detection.
AnalysisDataSet _series(List<double> samples, {String name = 'v'}) =>
    AnalysisDataSet(
      columns: [AnalysisColumnInfo(name: name, type: 'double')],
      rows: [
        for (final s in samples) <String, dynamic>{name: s},
      ],
      rowCount: samples.length,
    );

void main() {
  final base = DateTime.utc(2026, 1, 1);

  test('fft: non-power-of-two input (zero-padded) still finds the tone',
      () async {
    const fs = 1000.0;
    final x = List.generate(
        1000, (i) => math.sin(2 * math.pi * 50 * i / fs)); // 1000 ≠ 2^k
    final r = await FftFunction().execute({'sampleRate': fs}, _series(x));
    expect(r.results['fftSize'], 1024);
    expect(r.results['dominantFrequency'], closeTo(50.0, 1.5));
  });

  test('tumbling + maxPoints: cap applies inside the interval', () {
    final agg = WindowAggregator(
      windowSize: const Duration(seconds: 100),
      kind: WindowKind.tumbling,
      maxPoints: 5,
    );
    for (var i = 0; i < 20; i++) {
      agg.add(AnalysisTimePoint(
          t: base.add(Duration(seconds: i)), v: i.toDouble()));
    }
    expect(agg.aggregate('v', 'count'), 5.0);
    expect(agg.overflowDropped, 15);
    expect(agg.aggregate('v', 'min'), 15.0); // oldest evicted
    // Boundary crossing still resets.
    agg.add(
        AnalysisTimePoint(t: base.add(const Duration(seconds: 100)), v: 99.0));
    expect(agg.aggregate('v', 'count'), 1.0);
    expect(agg.aggregate('v', 'sum'), 99.0);
  });

  test('pca standardize=false uses raw covariance scale', () async {
    final rng = math.Random(21);
    // 'big' has ×100 the variance of 'small' — without standardization the
    // first component must align with 'big'.
    final data = AnalysisDataSet(
      columns: const [
        AnalysisColumnInfo(name: 'big', type: 'double'),
        AnalysisColumnInfo(name: 'small', type: 'double'),
      ],
      rows: [
        for (var i = 0; i < 300; i++)
          <String, dynamic>{
            'big': (rng.nextDouble() - 0.5) * 100,
            'small': rng.nextDouble() - 0.5,
          },
      ],
      rowCount: 300,
    );
    final r = await PcaFunction().execute({'standardize': false}, data);
    final pc1 =
        ((r.results['components'] as List).first as List).cast<double>();
    expect(pc1[0].abs(), greaterThan(0.99),
        reason: 'raw-scale PCA must load PC1 on the high-variance column');
  });

  test('harmonics auto-detects the fundamental when omitted', () async {
    const fs = 6400.0;
    final x = List.generate(4096, (i) {
      final t = i / fs;
      return math.sin(2 * math.pi * 100 * t) +
          0.2 * math.sin(2 * math.pi * 300 * t);
    });
    final r = await HarmonicsFunction().execute({'sampleRate': fs}, _series(x));
    expect(r.results['fundamental'], closeTo(100.0, fs / 4096 + 0.1));
    expect(r.results['thd'], closeTo(0.2, 0.03));
  });

  test('reorder buffer keeps working after flush (stream resume)', () {
    final buf = ReorderBuffer(allowedLateness: const Duration(seconds: 5));
    AnalysisTimePoint pt(int s) =>
        AnalysisTimePoint(t: base.add(Duration(seconds: s)), v: 1.0);
    buf.add(pt(10));
    buf.flush();
    final released = buf.add(pt(30)); // resume after flush
    expect(released, isEmpty); // held until watermark passes
    expect(buf.add(pt(40)).map((p) => p.t.second), [30]);
    expect(buf.add(pt(5)), isEmpty); // pre-flush time → dropped
    expect(buf.lateDropped, 1);
  });
}
