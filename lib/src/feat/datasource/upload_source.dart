import 'package:mcp_bundle/ports.dart';

import 'datasource_registry.dart';

/// Parses user-uploaded CSV/JSON files into AnalysisDataSet.
class UploadSourceAdapter extends DataSourceAdapter {
  String? _content;
  String? _format;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.upload;

  /// Set upload content for parsing.
  void setContent(String content, {String? format}) {
    _content = content;
    _format = format ?? _detectFormat(content);
  }

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    final content = _content ?? query;
    final format = _format ?? _detectFormat(content);

    switch (format) {
      case 'csv':
        return _parseCsv(content);
      case 'json':
        return _parseJson(content);
      default:
        throw AnalysisError(
          code: 'source.schema_mismatch',
          message: 'Unsupported upload format: $format',
        );
    }
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    final content = _content ?? query;
    final format = _format ?? _detectFormat(content);
    final dataSet = format == 'csv' ? _parseCsv(content) : _parseJson(content);
    return AnalysisSourceSchema(columns: dataSet.columns);
  }

  @override
  Future<bool> isAvailable() async => true;

  String _detectFormat(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) return 'json';
    return 'csv';
  }

  AnalysisDataSet _parseCsv(String content) {
    final lines = content
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return AnalysisDataSet(columns: [], rows: [], rowCount: 0);
    }

    // Detect delimiter
    final delimiter = _detectDelimiter(lines.first);
    final headers = lines.first.split(delimiter).map((h) => h.trim()).toList();

    final rows = <Map<String, dynamic>>[];
    for (var i = 1; i < lines.length; i++) {
      final values = lines[i].split(delimiter).map((v) => v.trim()).toList();
      if (values.length != headers.length) {
        throw AnalysisError(
          code: 'source.schema_mismatch',
          message:
              'Row ${i + 1} has ${values.length} fields but header has ${headers.length}',
          details: {'row': i + 1},
        );
      }

      final row = <String, dynamic>{};
      for (var j = 0; j < headers.length; j++) {
        row[headers[j]] = _parseValue(values[j]);
      }
      rows.add(row);
    }

    // Infer column types from data
    final columns = headers.map((h) {
      String type = 'string';
      if (rows.isNotEmpty) {
        final value = rows.first[h];
        type = _inferType(value);
      }
      return AnalysisColumnInfo(name: h, type: type);
    }).toList();

    return AnalysisDataSet(
      columns: columns,
      rows: rows,
      rowCount: rows.length,
    );
  }

  AnalysisDataSet _parseJson(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('[')) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'JSON content must be an array of objects',
      );
    }

    // Simple JSON array parsing
    // In production, would use dart:convert
    try {
      final decoded = _simpleJsonParse(trimmed);
      if (decoded is! List) {
        throw AnalysisError(
          code: 'source.schema_mismatch',
          message: 'JSON content must be an array',
        );
      }

      final rows = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          rows.add(item);
        }
      }

      final columns = <AnalysisColumnInfo>[];
      if (rows.isNotEmpty) {
        for (final entry in rows.first.entries) {
          columns.add(AnalysisColumnInfo(
            name: entry.key,
            type: _inferType(entry.value),
          ));
        }
      }

      return AnalysisDataSet(
        columns: columns,
        rows: rows,
        rowCount: rows.length,
      );
    } catch (e) {
      if (e is AnalysisError) rethrow;
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'Failed to parse JSON: $e',
      );
    }
  }

  dynamic _simpleJsonParse(String content) {
    // Use dart:convert for real parsing
    // This is a placeholder that delegates to a basic parser
    return _parseJsonValue(content.trim(), 0).value;
  }

  _JsonParseResult _parseJsonValue(String s, int pos) {
    while (pos < s.length && s[pos] == ' ') pos++;
    if (pos >= s.length) return _JsonParseResult(null, pos);

    switch (s[pos]) {
      case '[':
        return _parseJsonArray(s, pos);
      case '{':
        return _parseJsonObject(s, pos);
      case '"':
        return _parseJsonString(s, pos);
      default:
        return _parseJsonPrimitive(s, pos);
    }
  }

  _JsonParseResult _parseJsonArray(String s, int pos) {
    final result = <dynamic>[];
    pos++; // skip [
    while (pos < s.length) {
      while (pos < s.length && (s[pos] == ' ' || s[pos] == '\n' || s[pos] == '\r')) pos++;
      if (pos < s.length && s[pos] == ']') return _JsonParseResult(result, pos + 1);
      if (result.isNotEmpty) {
        if (pos < s.length && s[pos] == ',') pos++;
      }
      final item = _parseJsonValue(s, pos);
      result.add(item.value);
      pos = item.endPos;
    }
    return _JsonParseResult(result, pos);
  }

  _JsonParseResult _parseJsonObject(String s, int pos) {
    final result = <String, dynamic>{};
    pos++; // skip {
    while (pos < s.length) {
      while (pos < s.length && (s[pos] == ' ' || s[pos] == '\n' || s[pos] == '\r')) pos++;
      if (pos < s.length && s[pos] == '}') return _JsonParseResult(result, pos + 1);
      if (result.isNotEmpty) {
        if (pos < s.length && s[pos] == ',') pos++;
      }
      while (pos < s.length && (s[pos] == ' ' || s[pos] == '\n' || s[pos] == '\r')) pos++;
      final key = _parseJsonString(s, pos);
      pos = key.endPos;
      while (pos < s.length && (s[pos] == ' ' || s[pos] == ':')) pos++;
      final value = _parseJsonValue(s, pos);
      result[key.value as String] = value.value;
      pos = value.endPos;
    }
    return _JsonParseResult(result, pos);
  }

  _JsonParseResult _parseJsonString(String s, int pos) {
    pos++; // skip opening quote
    final buf = StringBuffer();
    while (pos < s.length && s[pos] != '"') {
      if (s[pos] == '\\' && pos + 1 < s.length) {
        pos++;
        buf.write(s[pos]);
      } else {
        buf.write(s[pos]);
      }
      pos++;
    }
    if (pos < s.length) pos++; // skip closing quote
    return _JsonParseResult(buf.toString(), pos);
  }

  _JsonParseResult _parseJsonPrimitive(String s, int pos) {
    final start = pos;
    while (pos < s.length && s[pos] != ',' && s[pos] != ']' && s[pos] != '}' && s[pos] != ' ' && s[pos] != '\n') {
      pos++;
    }
    final token = s.substring(start, pos).trim();
    if (token == 'null') return _JsonParseResult(null, pos);
    if (token == 'true') return _JsonParseResult(true, pos);
    if (token == 'false') return _JsonParseResult(false, pos);
    final intVal = int.tryParse(token);
    if (intVal != null) return _JsonParseResult(intVal, pos);
    final doubleVal = double.tryParse(token);
    if (doubleVal != null) return _JsonParseResult(doubleVal, pos);
    return _JsonParseResult(token, pos);
  }

  String _detectDelimiter(String header) {
    if (header.contains('\t')) return '\t';
    if (header.contains(',')) return ',';
    if (header.contains(';')) return ';';
    return ',';
  }

  dynamic _parseValue(String value) {
    if (value.isEmpty) return null;
    final intVal = int.tryParse(value);
    if (intVal != null) return intVal;
    final doubleVal = double.tryParse(value);
    if (doubleVal != null) return doubleVal;
    if (value.toLowerCase() == 'true') return true;
    if (value.toLowerCase() == 'false') return false;
    final dateVal = DateTime.tryParse(value);
    if (dateVal != null) return dateVal;
    return value;
  }

  String _inferType(dynamic value) {
    if (value is int) return 'int';
    if (value is double) return 'double';
    if (value is num) return 'double';
    if (value is bool) return 'bool';
    if (value is DateTime) return 'datetime';
    if (value is String) {
      if (DateTime.tryParse(value) != null) return 'datetime';
      if (double.tryParse(value) != null) return 'double';
    }
    return 'string';
  }
}

class _JsonParseResult {
  final dynamic value;
  final int endPos;

  const _JsonParseResult(this.value, this.endPos);
}
