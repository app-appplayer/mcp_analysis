import 'dart:async';

import 'package:mcp_bundle/ports.dart';

import 'datasource_registry.dart';

/// Bridges analysis data source interface to mcp_io telemetry.
class IoSourceAdapter extends DataSourceAdapter with StreamableDataSource {
  IoSourceAdapter({
    required IoStreamPort ioStreamPort,
    this.queryTimeout = const Duration(seconds: 30),
  }) : _ioStreamPort = ioStreamPort;
  final IoStreamPort _ioStreamPort;
  final Duration queryTimeout;

  @override
  AnalysisSourceType get sourceType => AnalysisSourceType.mcpIo;

  @override
  Future<AnalysisDataSet> queryData({
    required String query,
    Map<String, dynamic>? filter,
    AnalysisTimeRange? timeRange,
  }) async {
    final parsed = _parseIoUri(query);
    final spec = TopicSpec(
      uri: parsed.topic,
      mode: TopicMode.continuous,
    );

    try {
      final subscription = await _ioStreamPort.subscribe(
        spec,
        consumerId: 'mcp_analysis_batch',
      );

      final rows = <Map<String, dynamic>>[];
      final completer = Completer<void>();

      final streamSub = subscription.stream.listen(
        (envelope) {
          rows.add(<String, dynamic>{
            '_timestamp': envelope.payload.timestamp,
            '_deviceId': parsed.deviceId,
            'uri': envelope.uri,
            'value': envelope.payload.value is num
                ? (envelope.payload.value as num).toDouble()
                : envelope.payload.value,
            if (envelope.payload.unit != null) '_unit': envelope.payload.unit,
            '_quality': envelope.payload.quality.name,
          });
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (Object e) {
          if (!completer.isCompleted) completer.complete();
        },
      );

      // Wait with timeout
      await completer.future.timeout(
        queryTimeout,
        onTimeout: () {
          throw TimeoutException(
            'IoStream query timed out after ${queryTimeout.inSeconds}s',
          );
        },
      );
      await streamSub.cancel();
      await _ioStreamPort.unsubscribe(subscription.handle.subscriptionId);

      final columns = <AnalysisColumnInfo>[
        const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        const AnalysisColumnInfo(name: '_deviceId', type: 'string'),
        const AnalysisColumnInfo(name: 'uri', type: 'string'),
        const AnalysisColumnInfo(name: 'value', type: 'double'),
        const AnalysisColumnInfo(name: '_unit', type: 'string'),
        const AnalysisColumnInfo(name: '_quality', type: 'string'),
      ];

      return AnalysisDataSet(
        columns: columns,
        rows: rows,
        rowCount: rows.length,
        timeRange: timeRange,
      );
    } on TimeoutException {
      throw AnalysisError(
        code: 'source.timeout',
        message: 'IoStream query timed out after ${queryTimeout.inSeconds}s',
        details: {'query': query, 'timeoutSeconds': queryTimeout.inSeconds},
      );
    } catch (e) {
      if (e is AnalysisError) rethrow;
      final msg = e.toString().toLowerCase();
      if (msg.contains('unauthorized') ||
          msg.contains('forbidden') ||
          msg.contains('permission denied')) {
        throw AnalysisError(
          code: 'source.unauthorized',
          message: 'IoStream access denied: $e',
          details: {'query': query},
        );
      }
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'IoStream query failed: $e',
        details: {'query': query},
      );
    }
  }

  @override
  Stream<AnalysisDataSet> subscribe({
    required String query,
    Map<String, dynamic>? filter,
  }) {
    final controller = StreamController<AnalysisDataSet>();
    final parsed = _parseIoUri(query);

    () async {
      try {
        final spec = TopicSpec(
          uri: parsed.topic,
          mode: TopicMode.continuous,
        );

        final subscription = await _ioStreamPort.subscribe(
          spec,
          consumerId: 'mcp_analysis_stream',
        );

        subscription.stream.listen(
          (envelope) {
            final row = <String, dynamic>{
              '_timestamp': envelope.payload.timestamp,
              '_deviceId': parsed.deviceId,
              'uri': envelope.uri,
              'value': envelope.payload.value is num
                  ? (envelope.payload.value as num).toDouble()
                  : envelope.payload.value,
              if (envelope.payload.unit != null) '_unit': envelope.payload.unit,
              '_quality': envelope.payload.quality.name,
            };
            controller.add(AnalysisDataSet(
              columns: [
                const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
                const AnalysisColumnInfo(name: '_deviceId', type: 'string'),
                const AnalysisColumnInfo(name: 'uri', type: 'string'),
                const AnalysisColumnInfo(name: 'value', type: 'double'),
                const AnalysisColumnInfo(name: '_unit', type: 'string'),
                const AnalysisColumnInfo(name: '_quality', type: 'string'),
              ],
              rows: [row],
              rowCount: 1,
            ));
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      } catch (e) {
        if (e is AnalysisError) {
          controller.addError(e);
        } else {
          final msg = e.toString().toLowerCase();
          if (msg.contains('unauthorized') ||
              msg.contains('forbidden') ||
              msg.contains('permission denied')) {
            controller.addError(AnalysisError(
              code: 'source.unauthorized',
              message: 'IoStream subscribe denied: $e',
            ));
          } else {
            controller.addError(AnalysisError(
              code: 'source.unavailable',
              message: 'IoStream subscribe failed: $e',
            ));
          }
        }
        await controller.close();
      }
    }();

    return controller.stream;
  }

  @override
  Future<AnalysisSourceSchema> getSourceMetadata(String query) async {
    return const AnalysisSourceSchema(
      columns: [
        AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        AnalysisColumnInfo(name: '_deviceId', type: 'string'),
        AnalysisColumnInfo(name: 'value', type: 'double'),
      ],
      timestampField: '_timestamp',
    );
  }

  @override
  Future<bool> isAvailable() async {
    try {
      await _ioStreamPort.listSubscriptions();
      return true;
    } catch (_) {
      return false;
    }
  }

  _IoUriParts _parseIoUri(String query) {
    // io://{deviceId}/{metric}
    if (query.startsWith('io://')) {
      final path = query.substring(5);
      final parts = path.split('/');
      return _IoUriParts(
        deviceId: parts.isNotEmpty ? parts[0] : 'unknown',
        metric: parts.length > 1 ? parts[1] : 'value',
        topic: query,
      );
    }
    return _IoUriParts(deviceId: 'unknown', metric: 'value', topic: query);
  }
}

class _IoUriParts {
  const _IoUriParts({
    required this.deviceId,
    required this.metric,
    required this.topic,
  });
  final String deviceId;
  final String metric;
  final String topic;
}
