import 'package:mcp_bundle/ports.dart';

import '../governance/audit_logger.dart';
import '../governance/data_masker.dart';
import '../governance/rbac_policy.dart';

/// Maps MCP tool calls to AnalysisPort operations with governance.
class McpToolHandler {
  final AnalysisPort _analysisPort;
  final RbacPolicy _rbac;
  final AuditLogger _auditLogger;
  final DataMasker _dataMasker;

  McpToolHandler({
    required AnalysisPort analysisPort,
    required RbacPolicy rbac,
    required AuditLogger auditLogger,
    required DataMasker dataMasker,
  })  : _analysisPort = analysisPort,
        _rbac = rbac,
        _auditLogger = auditLogger,
        _dataMasker = dataMasker;

  /// Route MCP tool call to appropriate handler.
  Future<Map<String, dynamic>> handleTool(
    String toolName,
    Map<String, dynamic> arguments, {
    RbacContext? rbacContext,
  }) async {
    try {
      return switch (toolName) {
        'analysis.list_specs' =>
          await listSpecs(arguments, rbacContext: rbacContext),
        'analysis.run' => await run(arguments, rbacContext: rbacContext),
        'analysis.get_job' =>
          await getJob(arguments, rbacContext: rbacContext),
        'analysis.get_artifacts' =>
          await getArtifacts(arguments, rbacContext: rbacContext),
        'analysis.create_spec' =>
          await createSpec(arguments, rbacContext: rbacContext),
        'analysis.update_spec' =>
          await updateSpec(arguments, rbacContext: rbacContext),
        'analysis.evaluate_alert' =>
          await evaluateAlert(arguments, rbacContext: rbacContext),
        _ => throw AnalysisError(
            code: 'mcp.unknown_tool',
            message: 'Unknown tool: "$toolName". Available: '
                'analysis.list_specs, analysis.run, analysis.get_job, '
                'analysis.get_artifacts, analysis.create_spec, '
                'analysis.update_spec, analysis.evaluate_alert',
          ),
      };
    } on AnalysisError catch (e) {
      return {'error': e.toJson()};
    }
  }

  Future<Map<String, dynamic>> listSpecs(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    if (rbacContext != null) {
      await _rbac.checkPermission(
          context: rbacContext, operation: 'list_specs');
    }

    final specs = await _analysisPort.listSpecs(
      search: args['search'] as String?,
      limit: args['limit'] as int?,
      offset: args['offset'] as int?,
    );
    return {'specs': specs.map((s) => s.toJson()).toList()};
  }

  Future<Map<String, dynamic>> run(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    final specId = args['specId'] as String?;
    if (specId == null) {
      throw AnalysisError(
        code: 'mcp.invalid_arguments',
        message: 'Missing required argument: specId',
      );
    }

    if (rbacContext != null) {
      await _rbac.canExecute(rbacContext, specId);
    }

    final mode = args['mode'] != null
        ? AnalysisExecutionMode.fromString(args['mode'] as String)
        : AnalysisExecutionMode.batch;

    AnalysisTimeRange? timeRange;
    if (args['timeRange'] is Map<String, dynamic>) {
      timeRange = AnalysisTimeRange.fromJson(
        args['timeRange'] as Map<String, dynamic>,
      );
    }

    final job = await _analysisPort.runAnalysis(
      specId: specId,
      parameters: args['parameters'] as Map<String, dynamic>? ?? {},
      mode: mode,
      timeRange: timeRange,
    );

    // Audit: record execution
    try {
      await _auditLogger.recordExecution(
        actorId: rbacContext?.actorId ?? 'anonymous',
        specId: specId,
        jobId: job.jobId,
        inputRange: timeRange,
        parameters: args['parameters'] as Map<String, dynamic>? ?? {},
      );
    } catch (_) {
      // Audit failures are non-blocking
    }

    return job.toJson();
  }

  Future<Map<String, dynamic>> getJob(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    final jobId = args['jobId'] as String?;
    if (jobId == null) {
      throw AnalysisError(
        code: 'mcp.invalid_arguments',
        message: 'Missing required argument: jobId',
      );
    }

    if (rbacContext != null) {
      await _rbac.checkPermission(
          context: rbacContext, operation: 'view_job');
    }

    final job = await _analysisPort.getJob(jobId);
    if (job == null) {
      return {'error': 'Job not found', 'jobId': jobId};
    }
    return job.toJson();
  }

  Future<Map<String, dynamic>> getArtifacts(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    if (rbacContext != null) {
      await _rbac.canViewArtifacts(rbacContext);
    }

    var artifacts = await _analysisPort.getArtifacts(
      jobId: args['jobId'] as String?,
      specId: args['specId'] as String?,
      type: args['type'] != null
          ? AnalysisArtifactType.fromString(args['type'] as String)
          : null,
      tags: (args['tags'] as List?)?.cast<String>(),
      limit: args['limit'] as int?,
    );

    // Apply data masking
    final maskConfig = args['maskConfig'] as Map<String, dynamic>?;
    if (maskConfig != null) {
      final boolConfig = maskConfig.map(
        (k, v) => MapEntry(k, v == true),
      );
      artifacts = _dataMasker.applyMasking(artifacts, boolConfig);
    }

    return {'artifacts': artifacts.map((a) => a.toJson()).toList()};
  }

  Future<Map<String, dynamic>> createSpec(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    final specJson = args['spec'] as Map<String, dynamic>?;
    if (specJson == null) {
      throw AnalysisError(
        code: 'mcp.invalid_arguments',
        message: 'Missing required argument: spec',
      );
    }

    if (rbacContext != null) {
      await _rbac.canManageSpec(rbacContext);
    }

    final spec = AnalysisSpec.fromJson(specJson);
    final created = await _analysisPort.createSpec(spec);

    // Audit: record spec change
    try {
      await _auditLogger.recordSpecChange(
        actorId: rbacContext?.actorId ?? 'anonymous',
        specId: created.specId,
        action: 'create_spec',
      );
    } catch (_) {
      // Audit failures are non-blocking
    }

    return created.toJson();
  }

  Future<Map<String, dynamic>> updateSpec(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    final specId = args['specId'] as String?;
    final specJson = args['spec'] as Map<String, dynamic>?;
    if (specId == null || specJson == null) {
      throw AnalysisError(
        code: 'mcp.invalid_arguments',
        message: 'Missing required arguments: specId, spec',
      );
    }

    if (rbacContext != null) {
      await _rbac.canManageSpec(rbacContext);
    }

    final spec = AnalysisSpec.fromJson(specJson);
    final updated = await _analysisPort.updateSpec(specId, spec);

    // Audit: record spec change
    try {
      await _auditLogger.recordSpecChange(
        actorId: rbacContext?.actorId ?? 'anonymous',
        specId: specId,
        action: 'update_spec',
      );
    } catch (_) {
      // Audit failures are non-blocking
    }

    return updated.toJson();
  }

  Future<Map<String, dynamic>> evaluateAlert(
    Map<String, dynamic> args, {
    RbacContext? rbacContext,
  }) async {
    final alertRuleId = args['alertRuleId'] as String?;
    if (alertRuleId == null) {
      throw AnalysisError(
        code: 'mcp.invalid_arguments',
        message: 'Missing required argument: alertRuleId',
      );
    }

    if (rbacContext != null) {
      await _rbac.checkPermission(
          context: rbacContext, operation: 'execute');
    }

    final alert = await _analysisPort.evaluateAlert(alertRuleId);
    return alert.toJson();
  }

  /// Return MCP tool definitions for registration.
  static List<Map<String, dynamic>> getToolDefinitions() => [
        {
          'name': 'analysis.list_specs',
          'description': 'List available analysis specifications',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'search': {'type': 'string', 'description': 'Search filter'},
              'limit': {'type': 'integer', 'description': 'Max results'},
              'offset': {
                'type': 'integer',
                'description': 'Pagination offset',
              },
            },
          },
        },
        {
          'name': 'analysis.run',
          'description': 'Execute an analysis specification',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'specId': {
                'type': 'string',
                'description': 'Specification ID',
              },
              'parameters': {
                'type': 'object',
                'description': 'Runtime parameter overrides',
              },
              'mode': {
                'type': 'string',
                'enum': ['batch', 'streaming', 'adhoc'],
              },
              'timeRange': {
                'type': 'object',
                'properties': {
                  'start': {'type': 'string', 'format': 'date-time'},
                  'end': {'type': 'string', 'format': 'date-time'},
                },
              },
            },
            'required': ['specId'],
          },
        },
        {
          'name': 'analysis.get_job',
          'description': 'Get job status and results',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'jobId': {'type': 'string', 'description': 'Job ID'},
            },
            'required': ['jobId'],
          },
        },
        {
          'name': 'analysis.get_artifacts',
          'description': 'Query result artifacts',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'jobId': {'type': 'string'},
              'specId': {'type': 'string'},
              'type': {'type': 'string'},
              'tags': {'type': 'array', 'items': {'type': 'string'}},
              'limit': {'type': 'integer'},
            },
          },
        },
        {
          'name': 'analysis.create_spec',
          'description': 'Create a new analysis specification',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'spec': {
                'type': 'object',
                'description': 'Full spec as JSON',
              },
            },
            'required': ['spec'],
          },
        },
        {
          'name': 'analysis.update_spec',
          'description': 'Update an existing specification',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'specId': {'type': 'string'},
              'spec': {'type': 'object'},
            },
            'required': ['specId', 'spec'],
          },
        },
        {
          'name': 'analysis.evaluate_alert',
          'description': 'Manually evaluate an alert rule',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'alertRuleId': {'type': 'string'},
            },
            'required': ['alertRuleId'],
          },
        },
      ];
}
