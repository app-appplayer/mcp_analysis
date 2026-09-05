import 'dart:async';

import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// An API source's query is its whole configuration, headers included, and
/// an error's details are stored on the job and read back through
/// `analysis.get_job`. Echoing the query wrote whatever `Authorization`
/// the spec carried into the job record.
class _FailingClient implements HttpClientPort {
  _FailingClient(this._failure);
  final Object _failure;

  @override
  Future<HttpResponseData> request({
    required String method,
    required String url,
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async =>
      throw _failure;
}

void main() {
  const secret = 'Bearer sk-live-do-not-log-me';
  const query = '{"url":"https://example.com/data","method":"GET",'
      '"headers":{"Authorization":"$secret","X-Api-Key":"k-123"}}';

  Future<AnalysisError> failureFrom(Object thrown) async {
    final adapter = ApiSourceAdapter(httpClient: _FailingClient(thrown));
    try {
      await adapter.queryData(query: query);
    } on AnalysisError catch (e) {
      return e;
    }
    fail('expected the adapter to fail');
  }

  void expectNoSecret(AnalysisError error) {
    final rendered = error.details.toString() + error.message;
    expect(rendered, isNot(contains(secret)));
    expect(rendered, isNot(contains('k-123')));
  }

  test('a connection failure names the url, never the header values', () async {
    final error = await failureFrom(StateError('connection refused'));
    expectNoSecret(error);
    expect(error.details!['url'], equals('https://example.com/data'));
    expect(error.details!['headerNames'],
        containsAll(['Authorization', 'X-Api-Key']));
  });

  test('a timeout is redacted the same way', () async {
    final error = await failureFrom(TimeoutException('slow'));
    expectNoSecret(error);
    expect(error.details!['timeoutSeconds'], isNotNull);
  });

  test('a credential in the url query string does not reach the record',
      () async {
    const urlSecret = 'sk-live-in-the-query';
    final adapter =
        ApiSourceAdapter(httpClient: _FailingClient(StateError('x')));
    try {
      await adapter.queryData(
        query: '{"url":"https://api.example.com/data?api_key=$urlSecret",'
            '"method":"GET"}',
      );
      fail('expected a failure');
    } on AnalysisError catch (e) {
      final rendered = e.details.toString() + e.message;
      expect(rendered, isNot(contains(urlSecret)),
          reason: 'a credential travels in a query string as often as in a '
              'header');
      expect(e.details!['url'], equals('https://api.example.com/data'));
      expect(e.details!['queryNames'], equals(['api_key']));
    }
  });

  test('userinfo in the url is reported as present, never quoted', () async {
    final adapter =
        ApiSourceAdapter(httpClient: _FailingClient(StateError('x')));
    try {
      await adapter.queryData(
        query: '{"url":"https://user:hunter2@api.example.com/data"}',
      );
      fail('expected a failure');
    } on AnalysisError catch (e) {
      expect(e.details.toString(), isNot(contains('hunter2')));
      expect(e.details!['hasUserInfo'], isTrue);
    }
  });

  test('a url that will not parse reports its length only', () async {
    final adapter =
        ApiSourceAdapter(httpClient: _FailingClient(StateError('x')));
    try {
      await adapter.queryData(query: '{"url":"http://[::1"}');
      fail('expected a failure');
    } on AnalysisError catch (e) {
      expect(e.details.toString(), isNot(contains('[::1')));
      expect(e.details!.containsKey('urlLength'), isTrue);
    }
  });

  test('a config that is a JSON array reports its length only', () async {
    final adapter =
        ApiSourceAdapter(httpClient: _FailingClient(StateError('x')));
    try {
      await adapter.queryData(query: '["https://api.example.com/$secret"]');
      fail('expected a schema mismatch');
    } on AnalysisError catch (e) {
      expect(e.code, equals('source.schema_mismatch'));
      expect(e.details.toString(), isNot(contains(secret)));
      expect(e.details!['queryLength'], isNotNull);
    }
  });

  test('an unparseable config reports its length, not its content', () async {
    final adapter =
        ApiSourceAdapter(httpClient: _FailingClient(StateError('x')));
    try {
      await adapter.queryData(query: '{"url": "https://x", $secret');
      fail('expected a schema mismatch');
    } on AnalysisError catch (e) {
      expect(e.details.toString(), isNot(contains(secret)));
      expect(e.details!['queryLength'], isNotNull);
    }
  });
}
