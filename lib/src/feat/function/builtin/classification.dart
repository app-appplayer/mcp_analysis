import 'package:mcp_bundle/ports.dart';

import '../function_dispatcher.dart';

/// Rule-based classification: conditional label assignment.
class RuleBasedClassificationFunction implements AnalysisFunction {
  @override
  AnalysisFunctionInfo get info => AnalysisFunctionInfo(
        functionName: 'rule_based_classification',
        description: 'Apply rule-based classification labels to data',
        parameters: {
          'rules': AnalysisParameterSchema(
            name: 'rules',
            type: 'array',
            description:
                'List of rules: [{column, operator, value, label}]',
          ),
          'defaultLabel': AnalysisParameterSchema(
            name: 'defaultLabel',
            type: 'string',
            defaultValue: 'unclassified',
            description: 'Default label when no rule matches',
          ),
          'outputColumn': AnalysisParameterSchema(
            name: 'outputColumn',
            type: 'string',
            defaultValue: '_label',
            description: 'Name of the output label column',
          ),
        },
        supportedDataTypes: ['double', 'int', 'string'],
      );

  @override
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  ) async {
    final sw = Stopwatch()..start();
    final rules = (parameters['rules'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final defaultLabel = parameters['defaultLabel'] as String? ?? 'unclassified';
    final outputColumn = parameters['outputColumn'] as String? ?? '_label';

    final labeledRows = <Map<String, dynamic>>[];

    for (final row in data.rows) {
      var label = defaultLabel;

      for (final rule in rules) {
        final column = rule['column'] as String?;
        final operator = rule['operator'] as String? ?? '>';
        final value = rule['value'];
        final ruleLabel = rule['label'] as String?;

        if (column == null || ruleLabel == null) continue;

        if (!row.containsKey(column)) {
          throw AnalysisError(
            code: 'analysis.parameter_error',
            message: 'Column "$column" not found in data',
            step: 'function:rule_based_classification',
          );
        }

        final cellValue = row[column];
        if (_matches(cellValue, operator, value)) {
          label = ruleLabel;
          break; // First match wins
        }
      }

      labeledRows.add({
        ...row,
        outputColumn: label,
      });
    }

    // Summary of label distribution
    final distribution = <String, int>{};
    for (final row in labeledRows) {
      final label = row[outputColumn] as String;
      distribution[label] = (distribution[label] ?? 0) + 1;
    }

    sw.stop();
    return AnalysisFunctionResult(
      functionName: 'rule_based_classification',
      results: {
        'labeledRows': labeledRows,
        'distribution': distribution,
        'outputColumn': outputColumn,
        'totalRows': labeledRows.length,
      },
      executionTime: sw.elapsed,
    );
  }

  bool _matches(dynamic cellValue, String operator, dynamic value) {
    if (cellValue == null) return false;

    switch (operator) {
      case '>':
        return _toNum(cellValue) > _toNum(value);
      case '>=':
        return _toNum(cellValue) >= _toNum(value);
      case '<':
        return _toNum(cellValue) < _toNum(value);
      case '<=':
        return _toNum(cellValue) <= _toNum(value);
      case '==':
        return cellValue == value;
      case '!=':
        return cellValue != value;
      default:
        return false;
    }
  }

  num _toNum(dynamic v) {
    if (v is num) return v;
    return num.tryParse('$v') ?? 0;
  }
}
