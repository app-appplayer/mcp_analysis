import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// The declaration lock for [AnalysisFunctionInfo.results].
///
/// An output binds to a result field by name, so the names a function
/// publishes are a contract with whoever writes the spec. A key that is
/// returned but never declared is unreachable through that binding and
/// invisible to spec validation, and nothing else in the suite notices —
/// the function's own tests read its result map directly.
///
/// The reverse direction is not an error: a field produced only under
/// some parameters or some data (`criticalValue` for the ks test,
/// `bandPowers` when bands are requested) is still part of the contract.
void main() {
  AnalysisDataSet fixture() {
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < 1024; i++) {
      rows.add({
        '_timestamp': DateTime.utc(2026).add(Duration(seconds: i)),
        'value': 1.0 + (i % 8) * 0.5,
        'other': 2.0 - (i % 5) * 0.3,
        'rr': 800.0 + (i % 7) * 10,
      });
    }
    return AnalysisDataSet(
      columns: const [
        AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        AnalysisColumnInfo(name: 'value', type: 'double'),
        AnalysisColumnInfo(name: 'other', type: 'double'),
        AnalysisColumnInfo(name: 'rr', type: 'double'),
      ],
      rows: rows,
      rowCount: rows.length,
    );
  }

  /// Parameters for the functions the default `column` shape does not fit.
  const overrides = <String, Map<String, dynamic>>{
    'cross_psd': {
      'columns': ['value', 'other'],
      'sampleRate': 64,
    },
    'cross_correlation': {
      'columns': ['value', 'other'],
    },
    'correlation_regression': {'xColumn': 'value', 'yColumn': 'other'},
    'covariance_matrix': {
      'columns': ['value', 'other'],
    },
    'pca': {
      'columns': ['value', 'other'],
    },
    'hypothesis_test': {
      'columns': ['value', 'other'],
      'test': 't_test',
    },
    'hrv_metrics': {'column': 'rr'},
    'interpolate': {
      'column': 'value',
      'queryPoints': [1.0, 2.0],
    },
    'digital_filter': {
      'column': 'value',
      'sampleRate': 64,
      'cutoff': 8.0,
      'type': 'lowpass',
    },
    'lockin': {'column': 'value', 'sampleRate': 64, 'referenceFrequency': 8.0},
    'anomaly_detect': {'column': 'value', 'method': 'zscore'},
    'seasonality_analysis': {'column': 'value', 'period': 8},
    'eeg_band_powers': {'column': 'value', 'sampleRate': 128},
  };

  test('every returned result key is declared', () async {
    final data = fixture();
    final undeclared = <String, List<String>>{};
    final unrun = <String>[];

    for (final fn in standardBuiltinFunctions()) {
      final name = fn.info.functionName;
      final declared = fn.info.results.keys.toSet();
      if (declared.isEmpty) continue; // result keys are data-dependent

      final parameters = <String, dynamic>{
        'column': 'value',
        'sampleRate': 64,
        ...?overrides[name],
      };

      try {
        final result = await fn.execute(parameters, data);
        final extra = result.results.keys.toSet().difference(declared).toList()
          ..sort();
        if (extra.isNotEmpty) undeclared[name] = extra;
      } on Object {
        unrun.add(name);
      }
    }

    expect(
      undeclared,
      isEmpty,
      reason: 'these functions return result keys they do not declare, so no '
          'output can bind to them: $undeclared',
    );
    // Named so a function that stops running here is visible rather than
    // silently uncovered.
    expect(unrun, equals(['lomb_scargle']),
        reason: 'functions this fixture could not exercise changed: $unrun');
  });

  test('a declared field carries a usable type', () {
    const known = {'number', 'array', 'object', 'string', 'boolean'};
    for (final fn in standardBuiltinFunctions()) {
      for (final entry in fn.info.results.entries) {
        expect(entry.value.name, equals(entry.key),
            reason: '${fn.info.functionName}: schema name must match its key');
        expect(known, contains(entry.value.type),
            reason: '${fn.info.functionName}.${entry.key} declares '
                '"${entry.value.type}"');
        if (entry.value.type == 'array') {
          expect(entry.value.itemType, isNotNull,
              reason: '${fn.info.functionName}.${entry.key} is an array and '
                  'must say what its elements are');
        }
      }
    }
  });

  test('the catalog publishes result schemas through the standard engine',
      () async {
    final port = AnalysisPortAdapter.inMemory();
    expect(port, isA<AnalysisPort>());

    final declared = {
      for (final fn in standardBuiltinFunctions())
        fn.info.functionName: fn.info.results.keys.toSet(),
    };
    expect(declared['fft'], containsAll(['frequencies', 'magnitudes']));
    expect(declared['vibration_indicators'], contains('isoZone'));
    // descriptive_stats keys its results by column name, so it has nothing
    // fixed to declare — the validator skips bindings it cannot check.
    expect(declared['descriptive_stats'], isEmpty);
  });
}
