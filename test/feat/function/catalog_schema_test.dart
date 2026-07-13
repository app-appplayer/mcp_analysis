import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

/// Schema self-consistency across the ENTIRE builtin catalog — every
/// function's `info` must be well-formed (this is the surface agents and
/// hosts introspect), names must be unique, and each parameter map key must
/// match its schema's own `name`.
void main() {
  final catalog = <AnalysisFunction>[
    DescriptiveStatsFunction(),
    AnomalyDetectFunction(),
    EventAnalysisFunction(),
    TimeSeriesFunction(),
    CorrelationRegressionFunction(),
    RuleBasedClassificationFunction(),
    SeasonalityFunction(),
    FftFunction(),
    PsdWelchFunction(),
    DigitalFilterFunction(),
    PeakDetectFunction(),
    ZeroCrossingFunction(),
    ResampleFunction(),
    EnvelopeFunction(),
    AcfFunction(),
    CrossCorrelationFunction(),
    ChangepointCusumFunction(),
    HoltWintersFunction(),
    SmoothingFunction(),
    DifferencingFunction(),
    HistogramFunction(),
    CovarianceMatrixFunction(),
    RegressionFunction(),
    HypothesisTestFunction(),
    InterpolateFunction(),
    SpectrogramFunction(),
    CepstrumFunction(),
    HarmonicsFunction(),
    CrossPsdFunction(),
    PcaFunction(),
    LombScargleFunction(),
    KalmanFilterFunction(),
    VibrationIndicatorsFunction(),
    HrvMetricsFunction(),
    EegBandPowersFunction(),
  ];

  test('catalog size matches the documented inventory (35)', () {
    expect(catalog.length, 35);
  });

  test('every builtin exposes a well-formed, self-consistent schema', () {
    final seen = <String>{};
    for (final fn in catalog) {
      final info = fn.info;
      expect(info.functionName, isNotEmpty);
      expect(seen.add(info.functionName), isTrue,
          reason: 'duplicate functionName: ${info.functionName}');
      expect(info.description, isNotEmpty,
          reason: '${info.functionName} needs a description');
      expect(info.supportedDataTypes, isNotEmpty,
          reason: '${info.functionName} must declare supported types');
      info.parameters.forEach((key, schema) {
        expect(schema.name, key,
            reason: '${info.functionName}.$key: schema.name mismatch '
                '("${schema.name}")');
        expect(schema.type, isNotEmpty,
            reason: '${info.functionName}.$key needs a type');
        expect(schema.description, isNotEmpty,
            reason: '${info.functionName}.$key needs a description');
      });
    }
  });

  test('functions register cleanly into a FunctionCatalog + dispatcher', () {
    final cat = FunctionCatalog();
    final dispatcher = FunctionDispatcher(catalog: cat);
    for (final fn in catalog) {
      cat.register(fn.info);
      dispatcher.registerImplementation(fn.info.functionName, fn);
    }
    expect(cat.getAll().length, catalog.length);
  });
}
