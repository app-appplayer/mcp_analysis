import 'dart:convert';

import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Upload content is by definition not trusted, and the parser it used to
/// go through was hand-written: escape sequences were dropped, truncated
/// input was accepted, quoted CSV fields were split on the delimiter
/// inside them, and a tab where a value was expected made the JSON reader
/// loop without end — synchronously, so a `Future.timeout` could not stop
/// it.
void main() {
  late UploadSourceAdapter adapter;
  setUp(() => adapter = UploadSourceAdapter());

  Future<Map<String, dynamic>> firstRow(String content) async {
    final r = await adapter.queryData(query: content);
    return r.rows.first;
  }

  group('JSON', () {
    test('escape sequences survive', () async {
      final row = await firstRow(r'[{"msg":"a\nb\tc"}]');
      expect(row['msg'], equals('a\nb\tc'));
      expect(row['msg'], equals((jsonDecode(r'"a\nb\tc"') as String)));
    });

    test('unicode escapes survive', () async {
      final row = await firstRow(r'[{"msg":"café"}]');
      expect(row['msg'], equals('café'));
    });

    test('an embedded quote survives', () async {
      final row = await firstRow(r'[{"msg":"hello \"world\""}]');
      expect(row['msg'], equals('hello "world"'));
    });

    test('truncated input is refused, not half-parsed', () {
      expect(
        () => adapter.queryData(query: '[{"a": 1'),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'source.schema_mismatch')),
      );
    });

    test('tab-indented content parses and terminates', () async {
      // The hand parser consumed this without end, growing a list until
      // the isolate died. A timeout is meaningless against a synchronous
      // loop, so termination is the assertion.
      final row = await firstRow('[\n\t{\n\t\t"a": 1\n\t}\n]');
      expect(row['a'], equals(1));
    });

    test('nested structures survive', () async {
      final row = await firstRow('[{"a":{"b":[1,2]},"c":1.5e3}]');
      expect((row['a'] as Map)['b'], equals([1, 2]));
      expect(row['c'], equals(1500.0));
    });
  });

  group('CSV', () {
    test('a quoted field holds the delimiter', () async {
      final r = await adapter.queryData(
        query: 'name,city\n"Smith, John",Seoul',
      );
      expect(r.rows.first['name'], equals('Smith, John'));
      expect(r.rows.first['city'], equals('Seoul'));
    });

    test('a quoted field holds a newline', () async {
      final r = await adapter.queryData(
        query: 'note,n\n"line one\nline two",1',
      );
      expect(r.rowCount, equals(1), reason: 'one record, not two');
      expect(r.rows.first['note'], equals('line one\nline two'));
    });

    test('a doubled quote is one literal quote', () async {
      final r = await adapter.queryData(query: 'q\n"say ""hi"""');
      expect(r.rows.first['q'], equals('say "hi"'));
    });

    test('CRLF line endings are records, not stray characters', () async {
      final r = await adapter.queryData(query: 'a,b\r\n1,2\r\n3,4');
      expect(r.rowCount, equals(2));
      expect(r.rows.last['b'], equals(4));
    });

    test('a column typed by its first present value, not its first row',
        () async {
      // First data row leaves `n` empty, which parses to null. Typing off
      // row one alone called the whole column a string.
      final r = await adapter.queryData(query: 'n,m\n,1\n42,2');
      expect(r.rows.first['n'], isNull, reason: 'the case under test');
      final column = r.columns.firstWhere((c) => c.name == 'n');
      expect(column.type, equals('int'));
    });

    test('a column with no value anywhere stays a string', () async {
      final r = await adapter.queryData(query: 'n,m\n,1\n,2');
      expect(r.columns.firstWhere((c) => c.name == 'n').type, equals('string'));
    });

    test('semicolon and tab delimiters still auto-detect', () async {
      final semi = await adapter.queryData(query: 'a;b\n1;2');
      expect(semi.rows.first['b'], equals(2));
      final tab = await adapter.queryData(query: 'a\tb\n1\t2');
      expect(tab.rows.first['b'], equals(2));
    });
  });
}
