// A parameter only some methods of a function read, or one the function
// fills itself, is optional at the dispatcher (`AnalysisParameterSchema
// .required: false`); the function checks it where it needs it. A parameter
// every call needs stays required.
import 'dart:math' as math;

import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

void main() {
  late FunctionDispatcher dispatcher;

  final wave = AnalysisDataSet(
    columns: [const AnalysisColumnInfo(name: 'value', type: 'double')],
    rows: [
      for (var i = 0; i < 64; i++)
        {'value': math.sin(i / 4) + (i == 40 ? 9.0 : 0.0)},
    ],
    rowCount: 64,
  );

  setUp(() {
    dispatcher = FunctionDispatcher(catalog: FunctionCatalog())
      ..registerBuiltins(standardBuiltinFunctions());
  });

  Future<AnalysisFunctionResult> run(
          String name, Map<String, dynamic> parameters) =>
      dispatcher.executeFunction(
          functionName: name, parameters: parameters, data: wave);

  test('anomaly_detect: methods other than threshold need no threshold',
      () async {
    for (final method in ['mad', 'zscore', 'iqr', 'ewma']) {
      final r = await run('anomaly_detect', {'method': method});
      expect(r.results['method'], method, reason: method);
    }
    final mad = await run('anomaly_detect', {'method': 'mad'});
    expect(mad.results['count'], greaterThan(0));
  });

  test('anomaly_detect: the threshold method still requires its threshold',
      () async {
    await expectLater(
        run('anomaly_detect', {'method': 'threshold'}),
        throwsA(isA<AnalysisError>().having(
            (e) => e.message, 'message', contains('requires "threshold"'))));
    final r =
        await run('anomaly_detect', {'method': 'threshold', 'threshold': 5});
    expect(r.results['count'], 1);
  });

  test(
      'method-dependent rates: filter and resample modes that do not read '
      'them', () async {
    final ma = await run('digital_filter', {'type': 'moving_average'});
    expect(ma.functionName, 'digital_filter');
    final dec = await run('resample', {'mode': 'decimate', 'factor': 2});
    expect(dec.functionName, 'resample');
    await expectLater(run('digital_filter', {'type': 'lowpass'}),
        throwsA(isA<AnalysisError>()));
  });

  test('a parameter every call needs is still refused at the dispatcher',
      () async {
    await expectLater(
        run('fft', const {}),
        throwsA(isA<AnalysisError>().having((e) => e.message, 'message',
            contains('Missing required parameter "sampleRate"'))));
  });

  test('every declared optional parameter can be left out', () async {
    final infos = await dispatcher.getFunctionCatalog();
    final optional = {
      for (final i in infos)
        i.functionName: [
          for (final p in i.parameters.values)
            if (!p.isRequired) p.name,
        ],
    };
    // The parameters of the report: all of them optional now.
    expect(optional['anomaly_detect'],
        containsAll(['column', 'threshold', 'sensitivity']));
    expect(optional['digital_filter'],
        containsAll(['column', 'sampleRate', 'cutoff']));
    expect(optional['resample'],
        containsAll(['column', 'sourceRate', 'targetRate']));
    expect(optional['psd_welch'], containsAll(['column', 'bands']));
    // A function given only its required parameters is not refused by the
    // dispatcher (it may still refuse a value it cannot use itself).
    for (final i in infos) {
      final required = {
        for (final p in i.parameters.values)
          if (p.isRequired) p.name: _sample(p),
      };
      try {
        await run(i.functionName, required);
      } on AnalysisError catch (e) {
        expect(e.message, isNot(startsWith('Missing required parameter')),
            reason: i.functionName);
      } on Object {
        // A function's own refusal of the sample data is not the
        // dispatcher's.
      }
    }
  });

  test('the sensitivity description names each method\'s default', () async {
    final info = (await dispatcher.getFunctionCatalog())
        .singleWhere((i) => i.functionName == 'anomaly_detect');
    final s = info.parameters['sensitivity']!;
    expect(s.defaultValue, isNull);
    expect(s.description,
        allOf(contains('2.0'), contains('1.5'), contains('3.5')));
  });
}

Object _sample(AnalysisParameterSchema p) => switch (p.type) {
      'string' => 'value',
      'array' => ['value', 'value'],
      'int' => 4,
      'boolean' => true,
      _ => 8.0,
    };
