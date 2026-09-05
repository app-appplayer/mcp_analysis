import 'dart:convert';

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
    final records = _csvRecords(content);

    if (records.isEmpty) {
      return AnalysisDataSet(columns: [], rows: [], rowCount: 0);
    }

    final headers = records.first;
    final rows = <Map<String, dynamic>>[];
    for (var i = 1; i < records.length; i++) {
      final values = records[i];
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

    // Infer each column from its first value that is actually there. The
    // first row alone types a column by whatever it happens to hold, so a
    // leading blank made every later number a string.
    final columns = headers.map((h) {
      for (final row in rows) {
        final value = row[h];
        if (value != null) {
          return AnalysisColumnInfo(name: h, type: _inferType(value));
        }
      }
      return AnalysisColumnInfo(name: h, type: 'string');
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

    // dart:convert, not a hand parser. The one this replaced dropped
    // escape sequences (`\n` arrived as `n`), accepted truncated input
    // without complaint, and looped without end on a tab where it expected
    // a value — synchronously, so a `Future.timeout` could not stop it.
    // Upload content is by definition not trusted.
    try {
      final decoded = jsonDecode(trimmed);
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
    } on FormatException catch (e) {
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'Failed to parse JSON: ${e.message}',
        details: {if (e.offset != null) 'offset': e.offset},
      );
    } catch (e) {
      if (e is AnalysisError) rethrow;
      throw AnalysisError(
        code: 'source.schema_mismatch',
        message: 'Failed to parse JSON: $e',
      );
    }
  }

  /// Split [content] into records and fields per RFC 4180.
  ///
  /// A quoted field may hold the delimiter, a newline, and `""` for a
  /// literal quote. Splitting on the delimiter — which is what this
  /// replaced — turned `"Smith, John"` into two fields and rejected the
  /// row for having the wrong field count.
  List<List<String>> _csvRecords(String content) {
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final firstLineEnd = normalized.indexOf('\n');
    final header =
        firstLineEnd < 0 ? normalized : normalized.substring(0, firstLineEnd);
    final delimiter = _detectDelimiter(header);

    final records = <List<String>>[];
    var fields = <String>[];
    final field = StringBuffer();
    var quoted = false;
    // Whether anything at all has been seen in the current record. Without
    // it a single-column record reads as a blank line and is dropped.
    var pending = false;

    void endField() {
      fields.add(field.toString().trim());
      field.clear();
      pending = true;
    }

    void endRecord() {
      if (!pending) return; // a blank line is not a record
      endField();
      records.add(fields);
      fields = <String>[];
      pending = false;
    }

    for (var i = 0; i < normalized.length; i++) {
      final ch = normalized[i];
      if (quoted) {
        if (ch != '"') {
          field.write(ch);
        } else if (i + 1 < normalized.length && normalized[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
        continue;
      }
      if (ch == '"') {
        quoted = true;
        pending = true;
      } else if (ch == delimiter) {
        endField();
      } else if (ch == '\n') {
        endRecord();
      } else {
        field.write(ch);
        pending = true;
      }
    }
    endRecord();

    return records;
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
