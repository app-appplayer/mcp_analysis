import 'dart:math' as math;

import 'package:mcp_bundle/ports.dart';

import 'transform_pipeline.dart';

/// Filter rows by condition.
class FilterTransform extends TransformHandler {
  @override
  String get name => 'filter';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final column = parameters['column'] as String?;
    final operator = parameters['operator'] as String? ?? '==';
    final value = parameters['value'];

    if (column == null) {
      throw AnalysisError(
        code: 'transform.parameter_error',
        message: 'Filter transform requires "column" parameter',
        step: 'transform:filter',
      );
    }

    final filtered = input.rows.where((row) {
      final cellValue = row[column];
      return _compare(cellValue, operator, value);
    }).toList();

    return AnalysisDataSet(
      columns: input.columns,
      rows: filtered,
      rowCount: filtered.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    final column = parameters['column'] as String?;
    if (column != null) {
      final columnNames = inputSchema.map((c) => c.name).toList();
      if (!columnNames.contains(column)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'Filter transform references non-existent column "$column"',
          step: 'transform:filter',
          details: {
            'transform': 'filter',
            'parameter': 'column',
            'value': column,
            'availableColumns': columnNames,
          },
        );
      }
    }
    return inputSchema;
  }

  bool _compare(dynamic cellValue, String operator, dynamic value) {
    if (operator == 'isNull') return cellValue == null;
    if (operator == 'isNotNull') return cellValue != null;
    if (cellValue == null) return false;

    switch (operator) {
      case '==':
        return cellValue == value;
      case '!=':
        return cellValue != value;
      case '>':
        return _toNum(cellValue) > _toNum(value);
      case '<':
        return _toNum(cellValue) < _toNum(value);
      case '>=':
        return _toNum(cellValue) >= _toNum(value);
      case '<=':
        return _toNum(cellValue) <= _toNum(value);
      case 'in':
        return value is List && value.contains(cellValue);
      case 'notIn':
        return value is List && !value.contains(cellValue);
      default:
        return false;
    }
  }

  num _toNum(dynamic v) {
    if (v is num) return v;
    return num.tryParse('$v') ?? 0;
  }
}

/// Sort rows by column(s).
class SortTransform extends TransformHandler {
  @override
  String get name => 'sort';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final columns = parameters['columns'];
    final ascending = parameters['ascending'] as bool? ?? true;

    final sortColumns = <String>[];
    if (columns is List) {
      sortColumns.addAll(columns.cast<String>());
    } else if (columns is String) {
      sortColumns.add(columns);
    }

    if (sortColumns.isEmpty) {
      throw AnalysisError(
        code: 'transform.parameter_error',
        message: 'Sort transform requires "columns" parameter',
        step: 'transform:sort',
      );
    }

    final sorted = List<Map<String, dynamic>>.from(input.rows);
    sorted.sort((a, b) {
      for (final col in sortColumns) {
        final va = a[col];
        final vb = b[col];
        final cmp = _compareValues(va, vb);
        if (cmp != 0) return ascending ? cmp : -cmp;
      }
      return 0;
    });

    return AnalysisDataSet(
      columns: input.columns,
      rows: sorted,
      rowCount: sorted.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    final columns = parameters['columns'];
    final sortColumns = <String>[];
    if (columns is List) {
      sortColumns.addAll(columns.cast<String>());
    } else if (columns is String) {
      sortColumns.add(columns);
    }

    final columnNames = inputSchema.map((c) => c.name).toList();
    for (final col in sortColumns) {
      if (!columnNames.contains(col)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'Sort transform references non-existent column "$col"',
          step: 'transform:sort',
          details: {
            'transform': 'sort',
            'parameter': 'columns',
            'value': col,
            'availableColumns': columnNames,
          },
        );
      }
    }
    return inputSchema;
  }

  int _compareValues(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is DateTime && b is DateTime) return a.compareTo(b);
    return '$a'.compareTo('$b');
  }
}

/// Fill missing values.
class FillnaTransform extends TransformHandler {
  @override
  String get name => 'fillna';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final method = parameters['method'] as String? ?? 'value';
    final column = parameters['column'] as String?;
    final fillValue = parameters['value'];

    final filled = <Map<String, dynamic>>[];
    for (var i = 0; i < input.rows.length; i++) {
      final row = Map<String, dynamic>.from(input.rows[i]);
      final cols = column != null ? [column] : row.keys.toList();

      for (final col in cols) {
        if (row[col] == null) {
          switch (method) {
            case 'value':
              row[col] = fillValue;
            case 'forward':
              if (i > 0) row[col] = filled.last[col];
            case 'backward':
              for (var j = i + 1; j < input.rows.length; j++) {
                if (input.rows[j][col] != null) {
                  row[col] = input.rows[j][col];
                  break;
                }
              }
            case 'interpolate':
              dynamic prev;
              dynamic next;
              if (i > 0) prev = filled.last[col];
              for (var j = i + 1; j < input.rows.length; j++) {
                if (input.rows[j][col] != null) {
                  next = input.rows[j][col];
                  break;
                }
              }
              if (prev is num && next is num) {
                row[col] = (prev + next) / 2;
              } else {
                row[col] = prev ?? next;
              }
          }
        }
      }
      filled.add(row);
    }

    return AnalysisDataSet(
      columns: input.columns,
      rows: filled,
      rowCount: filled.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    final column = parameters['column'] as String?;
    if (column != null) {
      final columnNames = inputSchema.map((c) => c.name).toList();
      if (!columnNames.contains(column)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'Fillna transform references non-existent column "$column"',
          step: 'transform:fillna',
          details: {
            'transform': 'fillna',
            'parameter': 'column',
            'value': column,
            'availableColumns': columnNames,
          },
        );
      }
    }
    return inputSchema;
  }
}

/// Clip values to range.
class ClipTransform extends TransformHandler {
  @override
  String get name => 'clip';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final column = parameters['column'] as String?;
    final minVal = (parameters['min'] as num?)?.toDouble();
    final maxVal = (parameters['max'] as num?)?.toDouble();

    if (column == null) {
      throw AnalysisError(
        code: 'transform.parameter_error',
        message: 'Clip transform requires "column" parameter',
        step: 'transform:clip',
      );
    }

    final clipped = input.rows.map((row) {
      final newRow = Map<String, dynamic>.from(row);
      final value = newRow[column];
      if (value is num) {
        var v = value.toDouble();
        if (minVal != null) v = math.max(v, minVal);
        if (maxVal != null) v = math.min(v, maxVal);
        newRow[column] = v;
      }
      return newRow;
    }).toList();

    return AnalysisDataSet(
      columns: input.columns,
      rows: clipped,
      rowCount: clipped.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    final column = parameters['column'] as String?;
    if (column != null) {
      final columnNames = inputSchema.map((c) => c.name).toList();
      if (!columnNames.contains(column)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'Clip transform references non-existent column "$column"',
          step: 'transform:clip',
          details: {
            'transform': 'clip',
            'parameter': 'column',
            'value': column,
            'availableColumns': columnNames,
          },
        );
      }
      final colInfo = inputSchema.firstWhere((c) => c.name == column);
      const numericTypes = {'int', 'double', 'num', 'number'};
      if (!numericTypes.contains(colInfo.type)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'Clip transform requires numeric column, '
              'but "$column" has type "${colInfo.type}"',
          step: 'transform:clip',
          details: {
            'transform': 'clip',
            'parameter': 'column',
            'value': column,
            'columnType': colInfo.type,
          },
        );
      }
    }
    return inputSchema;
  }
}

/// Resample time series to fixed interval.
class ResampleTransform extends TransformHandler {
  @override
  String get name => 'resample';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final interval = parameters['interval'] as String? ?? '5m';
    final aggregation = parameters['aggregation'] as String? ?? 'mean';
    final duration = _parseInterval(interval);

    if (input.rows.isEmpty) {
      return input;
    }

    // Find timestamp column
    final tsCol = input.columns
        .where((c) => c.type == 'datetime' || c.name.contains('timestamp'))
        .map((c) => c.name)
        .firstOrNull;

    if (tsCol == null) {
      return input; // No timestamp column, return as-is
    }

    // Group by time bucket
    final buckets = <int, List<Map<String, dynamic>>>{};
    for (final row in input.rows) {
      final ts = row[tsCol];
      DateTime? dt;
      if (ts is DateTime) {
        dt = ts;
      } else if (ts is String) {
        dt = DateTime.tryParse(ts);
      }
      if (dt == null) continue;

      final bucketKey = dt.millisecondsSinceEpoch ~/ duration.inMilliseconds;
      buckets.putIfAbsent(bucketKey, () => []).add(row);
    }

    // Aggregate each bucket
    final resampled = <Map<String, dynamic>>[];
    final sortedKeys = buckets.keys.toList()..sort();
    for (final key in sortedKeys) {
      final rows = buckets[key]!;
      final newRow = <String, dynamic>{};

      // Set timestamp to bucket start
      newRow[tsCol] = DateTime.fromMillisecondsSinceEpoch(
        key * duration.inMilliseconds,
      );

      // Aggregate numeric columns
      for (final col in input.columns) {
        if (col.name == tsCol) continue;
        final values =
            rows.map((r) => r[col.name]).whereType<num>().cast<num>().toList();

        if (values.isEmpty) {
          newRow[col.name] = null;
          continue;
        }

        newRow[col.name] = switch (aggregation) {
          'mean' => values.reduce((a, b) => a + b) / values.length,
          'sum' => values.reduce((a, b) => a + b),
          'min' => values.reduce(math.min),
          'max' => values.reduce(math.max),
          'first' => values.first,
          'last' => values.last,
          'count' => values.length,
          _ => values.reduce((a, b) => a + b) / values.length,
        };
      }

      resampled.add(newRow);
    }

    return AnalysisDataSet(
      columns: input.columns,
      rows: resampled,
      rowCount: resampled.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    // Find timestamp column
    final tsCol = inputSchema
        .where((c) => c.type == 'datetime' || c.name.contains('timestamp'))
        .firstOrNull;

    if (tsCol == null) {
      final columnNames = inputSchema.map((c) => c.name).toList();
      throw AnalysisError(
        code: 'transform.schema_error',
        message: 'Resample transform requires a timestamp column '
            '(type "datetime" or name containing "timestamp")',
        step: 'transform:resample',
        details: {
          'transform': 'resample',
          'parameter': 'timestampColumn',
          'availableColumns': columnNames,
        },
      );
    }

    // Keep timestamp and numeric columns only
    const numericTypes = {'int', 'double', 'num', 'number'};
    return inputSchema.where((c) {
      if (c.name == tsCol.name) return true;
      return numericTypes.contains(c.type);
    }).toList();
  }

  Duration _parseInterval(String interval) {
    final match = RegExp(r'^(\d+)([smhd])$').firstMatch(interval);
    if (match == null) return const Duration(minutes: 5);

    final value = int.parse(match.group(1)!);
    return switch (match.group(2)!) {
      's' => Duration(seconds: value),
      'm' => Duration(minutes: value),
      'h' => Duration(hours: value),
      'd' => Duration(days: value),
      _ => Duration(minutes: value),
    };
  }
}

/// Join two DataSets by timestamp alignment.
class JoinTransform extends TransformHandler {
  @override
  String get name => 'join';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final method = parameters['method'] as String? ?? 'nearest';
    final tsColumn = parameters['timestampColumn'] as String? ?? '_timestamp';
    final rightDataRaw = parameters['rightData'];

    if (rightDataRaw == null) {
      throw AnalysisError(
        code: 'transform.parameter_error',
        message: 'Join transform requires "rightData" parameter',
        step: 'transform:join',
      );
    }

    // Parse right dataset from parameter
    final rightRows = (rightDataRaw is List)
        ? rightDataRaw.cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];

    if (rightRows.isEmpty) return input;

    // Extract timestamps from right dataset
    final rightTimestamped = <(DateTime, Map<String, dynamic>)>[];
    for (final row in rightRows) {
      final ts = _parseTimestamp(row[tsColumn]);
      if (ts != null) rightTimestamped.add((ts, row));
    }
    rightTimestamped.sort((a, b) => a.$1.compareTo(b.$1));

    // Join each left row with the best matching right row
    final joinedRows = <Map<String, dynamic>>[];
    for (final leftRow in input.rows) {
      final leftTs = _parseTimestamp(leftRow[tsColumn]);
      if (leftTs == null) {
        joinedRows.add(leftRow);
        continue;
      }

      final matchedRight = switch (method) {
        'exact' => _findExact(leftTs, rightTimestamped),
        'forward' => _findForward(leftTs, rightTimestamped),
        'backward' => _findBackward(leftTs, rightTimestamped),
        _ => _findNearest(leftTs, rightTimestamped),
      };

      final merged = Map<String, dynamic>.from(leftRow);
      if (matchedRight != null) {
        for (final entry in matchedRight.entries) {
          if (!merged.containsKey(entry.key)) {
            merged[entry.key] = entry.value;
          }
        }
      }
      joinedRows.add(merged);
    }

    // Build union columns
    final columnNames = <String>{};
    final columns = <AnalysisColumnInfo>[];
    for (final c in input.columns) {
      columnNames.add(c.name);
      columns.add(c);
    }
    if (rightRows.isNotEmpty) {
      for (final key in rightRows.first.keys) {
        if (!columnNames.contains(key)) {
          columnNames.add(key);
          columns.add(AnalysisColumnInfo(name: key, type: 'string'));
        }
      }
    }

    return AnalysisDataSet(
      columns: columns,
      rows: joinedRows,
      rowCount: joinedRows.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    final rightColumns = parameters['rightColumns'];
    if (rightColumns == null || rightColumns is! List) {
      return inputSchema;
    }

    final leftNames = inputSchema.map((c) => c.name).toSet();
    final result = List<AnalysisColumnInfo>.from(inputSchema);

    for (final rc in rightColumns) {
      if (rc is! Map<String, dynamic>) continue;
      final name = rc['name'] as String? ?? '';
      final type = rc['type'] as String? ?? 'string';
      final unit = rc['unit'] as String?;

      if (leftNames.contains(name)) {
        // Name conflict: prefix with "_right_"
        result.add(AnalysisColumnInfo(
          name: '_right_$name',
          type: type,
          unit: unit,
        ));
      } else {
        result.add(AnalysisColumnInfo(
          name: name,
          type: type,
          unit: unit,
        ));
      }
    }
    return result;
  }

  DateTime? _parseTimestamp(dynamic value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  Map<String, dynamic>? _findExact(
    DateTime ts,
    List<(DateTime, Map<String, dynamic>)> right,
  ) {
    for (final (rTs, row) in right) {
      if (rTs == ts) return row;
    }
    return null;
  }

  Map<String, dynamic>? _findNearest(
    DateTime ts,
    List<(DateTime, Map<String, dynamic>)> right,
  ) {
    if (right.isEmpty) return null;
    Map<String, dynamic>? best;
    var bestDiff = double.infinity;
    for (final (rTs, row) in right) {
      final diff = (rTs.difference(ts).inMilliseconds).abs().toDouble();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = row;
      }
    }
    return best;
  }

  Map<String, dynamic>? _findForward(
    DateTime ts,
    List<(DateTime, Map<String, dynamic>)> right,
  ) {
    for (final (rTs, row) in right) {
      if (!rTs.isBefore(ts)) return row;
    }
    return null;
  }

  Map<String, dynamic>? _findBackward(
    DateTime ts,
    List<(DateTime, Map<String, dynamic>)> right,
  ) {
    Map<String, dynamic>? best;
    for (final (rTs, row) in right) {
      if (rTs.isAfter(ts)) break;
      best = row;
    }
    return best;
  }
}

/// Convert units for a column.
class UnitConvertTransform extends TransformHandler {
  static const Map<String, Map<String, double>> _conversionFactors = {
    'C_to_F': {'multiply': 9.0 / 5.0, 'add': 32.0},
    'F_to_C': {'multiply': 5.0 / 9.0, 'subtract': 32.0},
    'C_to_K': {'add': 273.15},
    'K_to_C': {'subtract': 273.15},
    'm/s_to_km/h': {'multiply': 3.6},
    'km/h_to_m/s': {'multiply': 1.0 / 3.6},
    'km/h_to_mph': {'multiply': 0.621371},
    'mph_to_km/h': {'multiply': 1.60934},
    'Pa_to_kPa': {'multiply': 0.001},
    'kPa_to_Pa': {'multiply': 1000.0},
    'bar_to_Pa': {'multiply': 100000.0},
    'Pa_to_bar': {'multiply': 0.00001},
    'm_to_km': {'multiply': 0.001},
    'km_to_m': {'multiply': 1000.0},
    'ft_to_m': {'multiply': 0.3048},
    'm_to_ft': {'multiply': 3.28084},
  };

  @override
  String get name => 'unit_convert';

  @override
  Future<AnalysisDataSet> apply(
    AnalysisDataSet input,
    Map<String, dynamic> parameters,
  ) async {
    final column = parameters['column'] as String?;
    final from = parameters['from'] as String?;
    final to = parameters['to'] as String?;

    if (column == null || from == null || to == null) {
      throw AnalysisError(
        code: 'transform.parameter_error',
        message: 'unit_convert requires "column", "from", and "to" parameters',
        step: 'transform:unit_convert',
      );
    }

    final key = '${from}_to_$to';
    final factors = _conversionFactors[key];

    final converted = input.rows.map((row) {
      final newRow = Map<String, dynamic>.from(row);
      final value = newRow[column];
      if (value is num && factors != null) {
        var v = value.toDouble();
        if (factors.containsKey('subtract')) {
          v -= factors['subtract']!;
        }
        if (factors.containsKey('multiply')) {
          v *= factors['multiply']!;
        }
        if (factors.containsKey('add')) {
          v += factors['add']!;
        }
        newRow[column] = v;
      }
      return newRow;
    }).toList();

    // Update column unit
    final newColumns = input.columns.map((c) {
      if (c.name == column) {
        return AnalysisColumnInfo(name: c.name, type: c.type, unit: to);
      }
      return c;
    }).toList();

    return AnalysisDataSet(
      columns: newColumns,
      rows: converted,
      rowCount: converted.length,
      timeRange: input.timeRange,
      metadata: input.metadata,
    );
  }

  @override
  List<AnalysisColumnInfo> computeOutputSchema(
    List<AnalysisColumnInfo> inputSchema,
    Map<String, dynamic> parameters,
  ) {
    final column = parameters['column'] as String?;
    final from = parameters['from'] as String?;
    final to = parameters['to'] as String?;

    if (column != null) {
      final columnNames = inputSchema.map((c) => c.name).toList();
      if (!columnNames.contains(column)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'unit_convert transform references non-existent '
              'column "$column"',
          step: 'transform:unit_convert',
          details: {
            'transform': 'unit_convert',
            'parameter': 'column',
            'value': column,
            'availableColumns': columnNames,
          },
        );
      }

      final colInfo = inputSchema.firstWhere((c) => c.name == column);
      const numericTypes = {'int', 'double', 'num', 'number'};
      if (!numericTypes.contains(colInfo.type)) {
        throw AnalysisError(
          code: 'transform.schema_error',
          message: 'unit_convert transform requires numeric column, '
              'but "$column" has type "${colInfo.type}"',
          step: 'transform:unit_convert',
          details: {
            'transform': 'unit_convert',
            'parameter': 'column',
            'value': column,
            'columnType': colInfo.type,
          },
        );
      }

      if (from != null && to != null) {
        final key = '${from}_to_$to';
        if (!_conversionFactors.containsKey(key)) {
          throw AnalysisError(
            code: 'transform.schema_error',
            message: 'unit_convert: unsupported conversion "$from" to "$to"',
            step: 'transform:unit_convert',
            details: {
              'transform': 'unit_convert',
              'parameter': 'from/to',
              'value': key,
              'supportedConversions': _conversionFactors.keys.toList(),
            },
          );
        }
      }
    }

    return inputSchema.map((c) {
      if (c.name == column && to != null) {
        return AnalysisColumnInfo(name: c.name, type: c.type, unit: to);
      }
      return c;
    }).toList();
  }
}
