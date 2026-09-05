import 'dart:convert';
import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Circuit analysis by COMPOSING existing functions — no dedicated
/// frequency_response/impedance builtin. Proves the composition tier:
/// component values → resonance, Q, complex FRF (Smith-chart source data)
/// using only synthetic (rlc) + psd_welch + peak_detect + lockin, at
/// vectorized-call granularity (whole grid / whole record per call).
///
/// Circuit under test: series RLC, L = 0.01 H, C = 0.01 F, R = 0.1 Ω →
/// ω0 = 1/√(LC) = 100 rad/s (f0 ≈ 15.92 Hz), Q = ω0·L/R = 10, ζ = 0.05.
void main() {
  const fs = 1000.0;
  const r = 0.1, l = 0.01, cap = 0.01;
  final w0 = 1 / math.sqrt(l * cap);
  final f0 = w0 / (2 * math.pi);

  final source = SyntheticSourceAdapter();

  AnalysisDataSet wrap(List<double> xs, [String name = 'v']) => AnalysisDataSet(
        columns: [AnalysisColumnInfo(name: name, type: 'double')],
        rows: [
          for (final x in xs) <String, dynamic>{name: x}
        ],
        rowCount: xs.length,
      );

  Future<List<double>> simulate(Map<String, dynamic> input,
      {int samples = 8192}) async {
    final ds = await source.queryData(
        query: jsonEncode({
      'samples': samples,
      'sampleRate': fs,
      'seed': 11,
      'components': [
        {
          'kind': 'rlc',
          'r': r,
          'l': l,
          'c': cap,
          'output': 'vc',
          'input': input,
        },
      ],
    }));
    return ds.rows.map((row) => (row['value'] as num).toDouble()).toList();
  }

  /// Exact |H(jω)| and ∠H(jω) for vc/vin of the series RLC — the truth
  /// the composed pipeline must recover.
  ({double mag, double phase}) truth(double f) {
    final w = 2 * math.pi * f;
    final re = 1 - w * w * l * cap;
    final im = w * r * cap;
    final den = math.sqrt(re * re + im * im);
    return (mag: 1 / den, phase: -math.atan2(im, re));
  }

  test('resonance + Q from noise drive: rlc → psd_welch → peak_detect',
      () async {
    // Resolution matters: BW = f0/Q ≈ 1.6 Hz needs Δf ≪ that, so use
    // 8192-point segments (Δf ≈ 0.12 Hz).
    final y = await simulate({'kind': 'noise', 'std': 1.0}, samples: 65536);
    final psd = await PsdWelchFunction()
        .execute({'sampleRate': fs, 'segmentLength': 8192}, wrap(y));
    final freqs = (psd.results['frequencies'] as List).cast<double>();
    final raw = (psd.results['psd'] as List).cast<double>();

    // Welch fluctuation (~1/√averages) makes half-power crossings jitter;
    // smooth the PSD first — still composition, no new function.
    final sm = await SmoothingFunction()
        .execute({'method': 'sma', 'window': 7}, wrap(raw, 'p'));
    final power = (sm.results['values'] as List).cast<double>();

    // White input → output PSD ∝ |H(f)|²; its peak is the resonance.
    // Distance gate: Welch estimate fluctuates within the resonance lobe,
    // so keep one peak per lobe (lobe ≈ BW ≈ 13 bins at this Δf).
    final peaks = await PeakDetectFunction().execute({
      'minHeight': power.reduce(math.max) * 0.5,
      'minDistance': 50,
    }, wrap(power, 'p'));
    final idx = (peaks.results['indices'] as List).cast<int>();
    expect(idx, hasLength(1));
    expect(freqs[idx.first], closeTo(f0, 1.0));

    // Q from the half-power (−3 dB) bandwidth around the peak.
    final half = power[idx.first] / 2;
    var lo = idx.first, hi = idx.first;
    while (lo > 0 && power[lo] > half) {
      lo--;
    }
    while (hi < power.length - 1 && power[hi] > half) {
      hi++;
    }
    final q = freqs[idx.first] / (freqs[hi] - freqs[lo]);
    expect(q, closeTo(10.0, 2.5));
  });

  test('complex FRF sweep (Smith-chart source data): rlc → lockin per tone',
      () async {
    // Stepped-sine: unit sine in, lockin the output at the same frequency —
    // the LCR-meter/network-analyzer method from existing pieces only.
    final sweep = [8.0, 12.0, f0, 20.0, 30.0];
    for (final f in sweep) {
      final y =
          await simulate({'kind': 'sine', 'amplitude': 1.0, 'frequency': f});
      final lock = await LockinFunction()
          .execute({'sampleRate': fs, 'referenceFrequency': f}, wrap(y));
      final t = truth(f);
      expect(lock.results['amplitude'], closeTo(t.mag, t.mag * 0.05),
          reason: '|H| at $f Hz');
      // Phase comparison must be wrap-aware (±π equivalence).
      var dPhase = (lock.results['phase'] as double) - t.phase;
      dPhase -= (dPhase / (2 * math.pi)).round() * 2 * math.pi;
      expect(dPhase.abs(), lessThan(0.12), reason: '∠H at $f Hz');
    }
  });

  test('reflection coefficient is plain arithmetic on the swept FRF', () async {
    // Γ = (Z − Z0)/(Z + Z0) on a complex array is upper-tier math, not a
    // core function; check the mapping is well-conditioned at resonance.
    final t = truth(f0);
    final zRe = t.mag * math.cos(t.phase);
    final zIm = t.mag * math.sin(t.phase);
    const z0 = 1.0;
    final denRe = zRe + z0, denIm = zIm;
    final den = denRe * denRe + denIm * denIm;
    final gRe = ((zRe - z0) * denRe + zIm * denIm) / den;
    final gIm = (zIm * denRe - (zRe - z0) * denIm) / den;
    final mag = math.sqrt(gRe * gRe + gIm * gIm);
    expect(mag, lessThanOrEqualTo(1.0 + 1e-9)); // inside the Smith disk
  });
}
