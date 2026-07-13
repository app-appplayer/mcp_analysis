import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

/// Shared helpers for the DSP builtin family (standard-catalog step of the
/// roadmap). Pure Dart, no FFI — classical closed-form algorithms only.

/// Extract one numeric column as doubles (non-numeric rows skipped),
/// mirroring the extraction semantics of the statistical builtins.
List<double> numericColumn(AnalysisDataSet data, String column) => data.rows
    .map((r) => r[column])
    .whereType<num>()
    .map((v) => v.toDouble())
    .toList();

/// Resolve the column parameter: explicit `column`, else the first numeric
/// column in the dataset.
String resolveColumn(Map<String, dynamic> parameters, AnalysisDataSet data) {
  final explicit = parameters['column'] as String?;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  for (final c in data.columns) {
    if (c.type == 'double' || c.type == 'int') return c.name;
  }
  return data.columns.isNotEmpty ? data.columns.first.name : '';
}

/// Next power of two ≥ [n].
int nextPow2(int n) {
  var p = 1;
  while (p < n) {
    p <<= 1;
  }
  return p;
}

/// In-place iterative radix-2 Cooley–Tukey FFT over interleaved complex
/// arrays. [re]/[im] length must be a power of two.
void fftInPlace(List<double> re, List<double> im) {
  final n = re.length;
  assert((n & (n - 1)) == 0, 'FFT length must be a power of two');

  // Bit-reversal permutation.
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    while (j & bit != 0) {
      j ^= bit;
      bit >>= 1;
    }
    j |= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }

  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wRe = math.cos(ang);
    final wIm = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var curRe = 1.0, curIm = 0.0;
      final half = len >> 1;
      for (var k = 0; k < half; k++) {
        final uRe = re[i + k], uIm = im[i + k];
        final vRe = re[i + k + half] * curRe - im[i + k + half] * curIm;
        final vIm = re[i + k + half] * curIm + im[i + k + half] * curRe;
        re[i + k] = uRe + vRe;
        im[i + k] = uIm + vIm;
        re[i + k + half] = uRe - vRe;
        im[i + k + half] = uIm - vIm;
        final nextRe = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nextRe;
      }
    }
  }
}

/// Window functions for spectral estimation.
List<double> windowCoefficients(String name, int n) {
  switch (name) {
    case 'hamming':
      return List.generate(
          n, (i) => 0.54 - 0.46 * math.cos(2 * math.pi * i / (n - 1)));
    case 'rect':
    case 'rectangular':
      return List.filled(n, 1.0);
    case 'hann':
    default:
      return List.generate(
          n, (i) => 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1))));
  }
}
