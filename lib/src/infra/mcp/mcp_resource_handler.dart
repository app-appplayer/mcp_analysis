import 'package:mcp_bundle/ports.dart';

import '../../feat/function/function_catalog.dart';

/// MCP resource template descriptor.
class McpResourceTemplate {
  const McpResourceTemplate({
    required this.uriTemplate,
    required this.name,
    required this.description,
    this.mimeType = 'application/json',
  });
  final String uriTemplate;
  final String name;
  final String description;
  final String mimeType;

  Map<String, dynamic> toJson() => {
        'uriTemplate': uriTemplate,
        'name': name,
        'description': description,
        'mimeType': mimeType,
      };
}

/// Resolves MCP resource URIs to analysis data.
class McpResourceHandler {
  McpResourceHandler({
    required AnalysisPort analysisPort,
    required FunctionCatalog functionCatalog,
  })  : _analysisPort = analysisPort,
        _functionCatalog = functionCatalog;
  final AnalysisPort _analysisPort;
  final FunctionCatalog _functionCatalog;

  /// Resolve a resource URI and return its content.
  Future<Map<String, dynamic>> resolveResource(String uri) async {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme != 'analysis') {
      throw AnalysisError(
        code: 'mcp.invalid_uri',
        message: 'Invalid resource URI: "$uri". Expected scheme "analysis://"',
      );
    }

    final segments = parsed.pathSegments;
    if (segments.isEmpty) {
      throw AnalysisError(
        code: 'mcp.invalid_uri',
        message: 'Empty resource path in URI: "$uri"',
      );
    }

    return switch (segments.first) {
      'spec' => _resolveSpec(segments),
      'artifact' => _resolveArtifact(segments),
      'job' => _resolveJob(segments),
      'catalog' => _resolveCatalog(),
      _ => throw AnalysisError(
          code: 'mcp.unknown_resource',
          message: 'Unknown resource type: "${segments.first}". '
              'Available: spec, artifact, job, catalog',
        ),
    };
  }

  Future<Map<String, dynamic>> _resolveSpec(List<String> segments) async {
    if (segments.length < 2) {
      throw AnalysisError(
        code: 'mcp.invalid_uri',
        message: 'Missing specId in spec resource URI',
      );
    }

    final specId = segments[1];

    // Check for versioned URI: spec/{specId}/v/{version}
    String? requestedVersion;
    if (segments.length >= 4 && segments[2] == 'v') {
      requestedVersion = segments[3];
    }

    final specs = await _analysisPort.listSpecs(search: specId, limit: 100);
    AnalysisSpec? spec;

    if (requestedVersion != null) {
      spec = specs
          .where((s) => s.specId == specId && s.version == requestedVersion)
          .firstOrNull;
      if (spec == null) {
        throw AnalysisError(
          code: 'mcp.resource_not_found',
          message: 'Spec "$specId" version "$requestedVersion" not found',
          details: {
            'resourceType': 'spec',
            'specId': specId,
            'version': requestedVersion,
          },
        );
      }
    } else {
      spec = specs.where((s) => s.specId == specId).firstOrNull;
      if (spec == null) {
        throw AnalysisError(
          code: 'mcp.resource_not_found',
          message: 'Spec "$specId" not found',
          details: {'resourceType': 'spec', 'specId': specId},
        );
      }
    }

    return spec.toJson();
  }

  Future<Map<String, dynamic>> _resolveArtifact(List<String> segments) async {
    if (segments.length < 2) {
      throw AnalysisError(
        code: 'mcp.invalid_uri',
        message: 'Missing artifactId in artifact resource URI',
      );
    }

    final artifactId = segments[1];
    final artifacts = await _analysisPort.getArtifacts(limit: 1000);
    final artifact =
        artifacts.where((a) => a.artifactId == artifactId).firstOrNull;

    if (artifact == null) {
      throw AnalysisError(
        code: 'mcp.resource_not_found',
        message: 'Artifact "$artifactId" not found',
        details: {'resourceType': 'artifact', 'artifactId': artifactId},
      );
    }

    return artifact.toJson();
  }

  Future<Map<String, dynamic>> _resolveJob(List<String> segments) async {
    if (segments.length < 2) {
      throw AnalysisError(
        code: 'mcp.invalid_uri',
        message: 'Missing jobId in job resource URI',
      );
    }

    final jobId = segments[1];
    final job = await _analysisPort.getJob(jobId);

    if (job == null) {
      throw AnalysisError(
        code: 'mcp.resource_not_found',
        message: 'Job "$jobId" not found',
        details: {'resourceType': 'job', 'jobId': jobId},
      );
    }

    return job.toJson();
  }

  Future<Map<String, dynamic>> _resolveCatalog() async {
    final functions = _functionCatalog.getAll();
    return {
      'functions': functions
          .map((f) => {
                'functionName': f.functionName,
                'description': f.description,
                'parameters': f.parameters.map(
                  (k, v) => MapEntry(k, {
                    'name': v.name,
                    'type': v.type,
                    'description': v.description,
                    if (v.defaultValue != null) 'defaultValue': v.defaultValue,
                  }),
                ),
                'supportedDataTypes': f.supportedDataTypes,
              })
          .toList(),
      'count': functions.length,
    };
  }

  /// Return available resource templates for MCP registration.
  static List<McpResourceTemplate> getResourceTemplates() => const [
        McpResourceTemplate(
          uriTemplate: 'analysis://spec/{specId}',
          name: 'Analysis Specification',
          description: 'Get analysis specification by ID',
        ),
        McpResourceTemplate(
          uriTemplate: 'analysis://spec/{specId}/v/{version}',
          name: 'Analysis Specification (versioned)',
          description: 'Get analysis specification by ID and version',
        ),
        McpResourceTemplate(
          uriTemplate: 'analysis://artifact/{artifactId}',
          name: 'Analysis Artifact',
          description: 'Get analysis artifact by ID',
        ),
        McpResourceTemplate(
          uriTemplate: 'analysis://job/{jobId}',
          name: 'Analysis Job',
          description: 'Get analysis job status and results',
        ),
        McpResourceTemplate(
          uriTemplate: 'analysis://catalog',
          name: 'Function Catalog',
          description: 'List all available analysis functions',
        ),
      ];
}
