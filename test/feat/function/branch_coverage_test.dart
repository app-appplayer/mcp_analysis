import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Coverage-hardening pass (audit follow-up): functional branches the
/// known-value suites skipped — highpass/bandpass/zero-phase filtering,
/// seasonal Holt–Winters, ISO machine classes, window variants — plus the
/// ArgumentError guards.
AnalysisDataSet _series(List<double> samples, {String name = 'v'}) =>
    AnalysisDataSet(
      columns: [AnalysisColumnInfo(name: name, type: 'double')],
      rows: [
        for (final s in samples) <String, dynamic>{name: s},
      ],
      rowCount: samples.length,
    );

List<double> _sine(double f, double fs, int n, {double amp = 1.0}) =>
    List.generate(n, (i) => amp * math.sin(2 * math.pi * f * i / fs));

double _tailAmp(List<double> xs) =>
    xs.sublist(xs.length ~/ 2).map((v) => v.abs()).reduce(math.max);

void main() {
  group('digital_filter — remaining branches', () {
    const fs = 1000.0;
    final f = DigitalFilterFunction();

    test('highpass blocks low and passes high', () async {
      final low = await f.execute(
          {'type': 'highpass', 'sampleRate': fs, 'cutoff': 100.0},
          _series(_sine(10, fs, 2000)));
      final high = await f.execute(
          {'type': 'highpass', 'sampleRate': fs, 'cutoff': 100.0},
          _series(_sine(300, fs, 2000)));
      expect(_tailAmp((low.results['values'] as List).cast<double>()),
          lessThan(0.1));
      expect(_tailAmp((high.results['values'] as List).cast<double>()),
          closeTo(1.0, 0.1));
    });

    test('bandpass passes center, rejects both sides', () async {
      Future<double> amp(double freq) async {
        final r = await f.execute(
            {'type': 'bandpass', 'sampleRate': fs, 'cutoff': 100.0, 'q': 2.0},
            _series(_sine(freq, fs, 4000)));
        return _tailAmp((r.results['values'] as List).cast<double>());
      }

      expect(await amp(100), greaterThan(0.7));
      expect(await amp(10), lessThan(0.2));
      expect(await amp(400), lessThan(0.2));
    });

    test('zeroPhase (filtfilt) preserves phase of a passband tone', () async {
      final x = _sine(10, fs, 2000);
      final r = await f.execute({
        'type': 'lowpass',
        'sampleRate': fs,
        'cutoff': 50.0,
        'zeroPhase': true,
      }, _series(x));
      final out = (r.results['values'] as List).cast<double>();
      // Zero-phase → output aligned with input (same sign at mid-cycle).
      var dot = 0.0;
      for (var i = 500; i < 1500; i++) {
        dot += out[i] * x[i];
      }
      expect(dot, greaterThan(0));
      expect(_tailAmp(out), closeTo(1.0, 0.15));
    });

    test('guards: missing cutoff and above-Nyquist cutoff throw', () {
      expect(
          () => f.execute({'type': 'lowpass', 'sampleRate': fs},
              _series(_sine(10, fs, 64))),
          throwsArgumentError);
      expect(
          () => f.execute(
              {'type': 'lowpass', 'sampleRate': fs, 'cutoff': 600.0},
              _series(_sine(10, fs, 64))),
          throwsArgumentError);
    });
  });

  group('holt_winters — seasonal branch', () {
    test('additive seasonal forecast reproduces the cycle', () async {
      // Period-4 seasonal pattern on a flat base.
      final season = [10.0, 20.0, 30.0, 20.0];
      final x = [for (var i = 0; i < 48; i++) season[i % 4]];
      final r = await HoltWintersFunction().execute(
          {'period': 4, 'horizon': 4, 'alpha': 0.2, 'beta': 0.05, 'gamma': 0.3},
          _series(x));
      final f = (r.results['forecast'] as List).cast<double>();
      // Forecast continues the seasonal shape (peak at position 2 of cycle).
      final maxIdx = f.indexOf(f.reduce(math.max));
      expect(season[(48 + maxIdx) % 4], 30.0,
          reason: 'seasonal peak position must be preserved');
    });

    test('guard: too-short series for the seasonal setting throws', () {
      expect(
          () => HoltWintersFunction()
              .execute({'period': 12}, _series(List.filled(20, 1.0))),
          throwsArgumentError);
    });
  });

  group('vibration_indicators — machine classes', () {
    Future<String> zoneFor(double rms, int mc) async {
      // Constant-amplitude sine with RMS = rms → amplitude = rms·√2.
      final x = _sine(50, 1000, 1000, amp: rms * math.sqrt2);
      final r = await VibrationIndicatorsFunction()
          .execute({'machineClass': mc}, _series(x));
      return r.results['isoZone'] as String;
    }

    test('zone boundaries differ by machine class', () async {
      // RMS 2.0 mm/s: class1 → C (>1.8), class3 → B (≤4.5), class4 → A? (≤2.8 → B? bounds4 A/B=2.8 → A)
      expect(await zoneFor(2.0, 1), 'C');
      expect(await zoneFor(2.0, 3), 'B');
      expect(await zoneFor(2.0, 4), 'A');
      expect(await zoneFor(20.0, 4), 'D');
    });
  });

  group('hrv_metrics — unit seconds branch', () {
    test('unit=s converts to ms', () async {
      final r = await HrvMetricsFunction()
          .execute({'unit': 's'}, _series([0.8, 0.81, 0.79, 0.87], name: 'rr'));
      expect(r.results['meanRR'], closeTo(817.5, 0.1));
    });
  });

  group('spectral window variants', () {
    test('fft hamming window still recovers the tone', () async {
      final r = await FftFunction().execute(
          {'sampleRate': 1000, 'window': 'hamming'},
          _series(_sine(125, 1000, 1024)));
      expect(r.results['dominantFrequency'], closeTo(125.0, 1.5));
    });

    test('psd_welch rect window + zero overlap', () async {
      final r = await PsdWelchFunction().execute({
        'sampleRate': 256,
        'segmentLength': 128,
        'overlap': 0.0,
        'window': 'rect',
      }, _series(_sine(32, 256, 1024)));
      final psd = (r.results['psd'] as List).cast<double>();
      final freqs = (r.results['frequencies'] as List).cast<double>();
      final peak = freqs[psd.indexOf(psd.reduce(math.max))];
      expect(peak, closeTo(32.0, 2.5));
    });
  });

  group('resample/envelope remaining branches', () {
    test('envelope peak mode tracks rectified maxima', () async {
      final r = await EnvelopeFunction().execute({'mode': 'peak', 'window': 50},
          _series(_sine(20, 1000, 1000, amp: 3.0)));
      final out = (r.results['values'] as List).cast<double>();
      expect(out.last, closeTo(3.0, 0.05));
    });

    test('resample linear guard: missing rates throw', () {
      expect(
          () => ResampleFunction()
              .execute({'mode': 'linear'}, _series([1.0, 2.0, 3.0])),
          throwsArgumentError);
    });
  });

  group('interpolate spline fallback + guards', () {
    test('2-point spline falls back to linear', () async {
      final data = AnalysisDataSet(
        columns: const [
          AnalysisColumnInfo(name: 'x', type: 'double'),
          AnalysisColumnInfo(name: 'y', type: 'double'),
        ],
        rows: const [
          {'x': 0.0, 'y': 0.0},
          {'x': 2.0, 'y': 4.0},
        ],
        rowCount: 2,
      );
      final r = await InterpolateFunction().execute({
        'columns': ['x', 'y'],
        'method': 'spline',
        'queryPoints': [1.0]
      }, data);
      expect((r.results['values'] as List).cast<double>().single,
          closeTo(2.0, 1e-9));
    });
  });

  group('argument guards (uniform error behavior)', () {
    final tiny = _series([1.0]);
    test('spectrum/period functions reject insufficient input', () {
      expect(() => FftFunction().execute({'sampleRate': 10}, tiny),
          throwsArgumentError);
      expect(() => FftFunction().execute({}, _series(_sine(1, 10, 32))),
          throwsArgumentError); // missing sampleRate
      expect(() => AcfFunction().execute({}, tiny), throwsArgumentError);
      expect(() => CepstrumFunction().execute({'sampleRate': 10}, tiny),
          throwsArgumentError);
      expect(() => HarmonicsFunction().execute({'sampleRate': 10}, tiny),
          throwsArgumentError);
      expect(
          () => KalmanFilterFunction().execute({}, tiny), throwsArgumentError);
      expect(() => ChangepointCusumFunction().execute({}, tiny),
          throwsArgumentError);
      expect(
          () => LombScargleFunction().execute({
                'columns': ['t', 'v']
              }, tiny),
          throwsArgumentError);
    });

    test('two-column functions reject missing columns param', () {
      expect(() => CrossCorrelationFunction().execute({}, tiny),
          throwsArgumentError);
      expect(() => HypothesisTestFunction().execute({}, tiny),
          throwsArgumentError);
      expect(() => CrossPsdFunction().execute({'sampleRate': 10}, tiny),
          throwsArgumentError);
    });
  });

  group('cepstrum — periodic signal', () {
    test('finds the repetition period of a pulse train', () async {
      const fs = 1000.0;
      final x = List<double>.filled(2048, 0.0);
      for (var i = 0; i < 2048; i += 100) {
        x[i] = 1.0; // pulse every 100 samples = 0.1 s
      }
      final r =
          await CepstrumFunction().execute({'sampleRate': fs}, _series(x));
      expect(r.results['peakQuefrency'], closeTo(0.1, 0.02));
    });
  });

  group('spectrogram/cross_psd guards', () {
    test('too-short input throws', () {
      expect(
          () => SpectrogramFunction().execute(
              {'sampleRate': 100, 'segmentLength': 256},
              _series(List.filled(64, 0.0))),
          throwsArgumentError);
      expect(
          () => CrossPsdFunction().execute({
                'columns': ['a', 'b'],
                'sampleRate': 100,
                'segmentLength': 256,
              }, _twoCol(List.filled(64, 0.0), List.filled(64, 0.0))),
          throwsArgumentError);
      expect(
          () =>
              SpectrogramFunction().execute({}, _series(List.filled(512, 0.0))),
          throwsArgumentError); // missing sampleRate
    });
  });

  group('synthetic source remainder', () {
    final adapter = SyntheticSourceAdapter();
    test('uniform noise + impulse + metadata/availability', () async {
      final d = await adapter.queryData(
          query:
              '{"samples":2000,"seed":9,"components":[{"kind":"noise","std":1.0,"distribution":"uniform"},{"kind":"impulse","at":100,"level":50}]}');
      final xs = d.rows.map((r) => r['value'] as double).toList();
      expect(xs[100], greaterThan(40.0)); // impulse landed
      final mean =
          xs.where((v) => v < 40).reduce((a, b) => a + b) / (xs.length - 1);
      expect(mean.abs(), lessThan(0.15)); // uniform centered

      final schema = await adapter.getSourceMetadata('{}');
      expect(schema.columns.length, 2);
      expect(await adapter.isAvailable(), isTrue);
    });

    test('guards: bad JSON and bad sample count throw AnalysisError', () {
      expect(() => adapter.queryData(query: 'not-json'),
          throwsA(isA<AnalysisError>()));
      expect(() => adapter.queryData(query: '{"samples":0,"seed":1}'),
          throwsA(isA<AnalysisError>()));
    });
  });
}

AnalysisDataSet _twoCol(List<double> a, List<double> b) => AnalysisDataSet(
      columns: const [
        AnalysisColumnInfo(name: 'a', type: 'double'),
        AnalysisColumnInfo(name: 'b', type: 'double'),
      ],
      rows: [
        for (var i = 0; i < a.length; i++)
          <String, dynamic>{'a': a[i], 'b': b[i]},
      ],
      rowCount: a.length,
    );
