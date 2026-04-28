import 'package:mcp_bundle/ports.dart';

/// Audit log entry.
class AuditRecord {
  final String recordId;
  final String actorId;
  final String action; // execute, create_spec, update_spec
  final String? specId;
  final String? jobId;
  final AnalysisTimeRange? inputRange;
  final Map<String, dynamic>? parameters;
  final DateTime timestamp;

  const AuditRecord({
    required this.recordId,
    required this.actorId,
    required this.action,
    this.specId,
    this.jobId,
    this.inputRange,
    this.parameters,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'recordId': recordId,
        'actorId': actorId,
        'action': action,
        if (specId != null) 'specId': specId,
        if (jobId != null) 'jobId': jobId,
        if (inputRange != null) 'inputRange': inputRange!.toJson(),
        if (parameters != null) 'parameters': parameters,
        'timestamp': timestamp.toIso8601String(),
      };
}

/// Records audit entries for governance compliance.
class AuditLogger {
  final StoragePort<AuditRecord> _storage;
  int _counter = 0;

  AuditLogger({required StoragePort<AuditRecord> storage}) : _storage = storage;

  /// Record an audit entry for a Job execution.
  /// Returns [AnalysisError] with code `governance.audit_failed` on failure,
  /// or `null` on success. Audit failures are non-blocking per NFR.
  Future<AnalysisError?> recordExecution({
    required String actorId,
    required String specId,
    required String jobId,
    required AnalysisTimeRange? inputRange,
    required Map<String, dynamic> parameters,
    DateTime? timestamp,
  }) async {
    _counter++;
    final record = AuditRecord(
      recordId: 'audit-$_counter-${DateTime.now().millisecondsSinceEpoch}',
      actorId: actorId,
      action: 'execute',
      specId: specId,
      jobId: jobId,
      inputRange: inputRange,
      parameters: parameters,
      timestamp: timestamp ?? DateTime.now(),
    );

    try {
      await _storage.save(record.recordId, record);
      return null;
    } catch (e) {
      // Audit failures are non-blocking (NFR requirement)
      return AnalysisError(
        code: 'governance.audit_failed',
        message: 'Audit record failed to save: $e',
        details: {'action': 'execute', 'specId': specId, 'jobId': jobId},
        timestamp: DateTime.now(),
      );
    }
  }

  /// Record an audit entry for Spec management.
  /// Returns [AnalysisError] with code `governance.audit_failed` on failure,
  /// or `null` on success. Audit failures are non-blocking per NFR.
  Future<AnalysisError?> recordSpecChange({
    required String actorId,
    required String specId,
    required String action,
    DateTime? timestamp,
  }) async {
    _counter++;
    final record = AuditRecord(
      recordId: 'audit-$_counter-${DateTime.now().millisecondsSinceEpoch}',
      actorId: actorId,
      action: action,
      specId: specId,
      timestamp: timestamp ?? DateTime.now(),
    );

    try {
      await _storage.save(record.recordId, record);
      return null;
    } catch (e) {
      // Audit failures are non-blocking
      return AnalysisError(
        code: 'governance.audit_failed',
        message: 'Audit record failed to save: $e',
        details: {'action': action, 'specId': specId},
        timestamp: DateTime.now(),
      );
    }
  }

  /// Query audit records with filters.
  Future<List<AuditRecord>> query({
    String? actorId,
    String? specId,
    DateTime? startTime,
    DateTime? endTime,
    int? limit,
  }) async {
    final criteria = <String, dynamic>{};
    if (actorId != null) criteria['actorId'] = actorId;
    if (specId != null) criteria['specId'] = specId;

    var results = await _storage.query(criteria);

    if (startTime != null) {
      results = results.where((r) => !r.timestamp.isBefore(startTime)).toList();
    }
    if (endTime != null) {
      results = results.where((r) => !r.timestamp.isAfter(endTime)).toList();
    }

    if (limit != null && limit > 0 && limit < results.length) {
      results = results.sublist(0, limit);
    }

    return results;
  }
}
