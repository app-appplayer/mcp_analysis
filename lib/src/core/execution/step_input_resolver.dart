import 'package:mcp_bundle/ports.dart';

/// Builds the dataset a step reads when it consumes another step's result.
///
/// Steps run as a forward pass over one dataset unless they say otherwise.
/// A step with an [AnalysisStepInput] reads a named field of an earlier
/// step instead, which is what lets a spectrum be the thing the next step
/// looks at rather than the raw signal it was computed from.
class StepInputResolver {
  const StepInputResolver();

  /// Dataset for [input], read out of [functionResults].
  ///
  /// Throws `analysis.invalid_step_input` when the source step produced no
  /// usable field — a spec that reaches here has passed validation, so the
  /// remaining causes are runtime ones (a conditional field the run did
  /// not produce, a field holding something other than numbers).
  AnalysisDataSet resolve(
    AnalysisStepInput input,
    Map<String, dynamic> functionResults,
  ) {
    final source = functionResults[input.from];
    if (source is! Map) {
      throw AnalysisError(
        code: 'analysis.invalid_step_input',
        message: 'Step input reads "${input.from}", which produced no result '
            'map',
        details: {'from': input.from, 'field': input.field},
      );
    }

    final values = _numbers(source[input.field]);
    if (values == null) {
      throw AnalysisError(
        code: 'analysis.invalid_step_input',
        message: 'Step input reads "${input.from}.${input.field}", which is '
            'not a list of numbers in this run',
        details: {'from': input.from, 'field': input.field},
      );
    }

    final index =
        input.indexField == null ? null : _numbers(source[input.indexField]);

    final columns = <AnalysisColumnInfo>[
      if (index != null)
        AnalysisColumnInfo(name: input.indexColumn, type: 'double'),
      AnalysisColumnInfo(name: input.column, type: 'double'),
    ];

    final rows = <Map<String, dynamic>>[
      for (var i = 0; i < values.length; i++)
        <String, dynamic>{
          if (index != null && i < index.length) input.indexColumn: index[i],
          input.column: values[i],
        },
    ];

    return AnalysisDataSet(
      columns: columns,
      rows: rows,
      rowCount: rows.length,
    );
  }

  static List<double>? _numbers(dynamic v) {
    if (v is! List) return null;
    final out = <double>[];
    for (final e in v) {
      if (e is! num) return null;
      out.add(e.toDouble());
    }
    return out;
  }
}
