import 'dart:async';

import 'package:mcp_bundle/ports.dart';

import 'function_catalog.dart';
import 'function_dispatcher.dart';

/// Plugin manifest metadata.
class PluginManifest {
  const PluginManifest({
    required this.functionName,
    required this.description,
    required this.category,
    required this.version,
    this.supportedSpecRange,
    this.parameters = const [],
    this.supportedDataTypes = const [],
    this.executionTimeout = const Duration(seconds: 60),
  });
  final String functionName;
  final String description;
  final String category;
  final String version;
  final String? supportedSpecRange;
  final List<AnalysisParameterSchema> parameters;
  final List<String> supportedDataTypes;
  final Duration executionTimeout;
}

/// Enables extensibility by loading external function plugins.
class PluginLoader {
  PluginLoader({
    required FunctionCatalog catalog,
    required FunctionDispatcher dispatcher,
    this.currentSpecVersion = '1.0.0',
  })  : _catalog = catalog,
        _dispatcher = dispatcher {
    // Wire this loader into the dispatcher for timeout enforcement
    _dispatcher.setPluginLoader(this);
  }
  final FunctionCatalog _catalog;
  final FunctionDispatcher _dispatcher;
  final String currentSpecVersion;
  final Set<String> _loadedPlugins = {};
  final Map<String, PluginManifest> _manifests = {};

  /// Load a plugin from manifest and implementation.
  void loadPlugin(PluginManifest manifest, AnalysisFunction implementation) {
    // Validate manifest
    if (manifest.functionName.isEmpty) {
      throw AnalysisError(
        code: 'plugin.invalid_manifest',
        message: 'Plugin function name must not be empty',
      );
    }

    if (manifest.supportedSpecRange == null) {
      throw AnalysisError(
        code: 'plugin.invalid_manifest',
        message: 'Plugin must declare supportedSpecRange',
      );
    }

    // Validate version compatibility
    if (!_isVersionCompatible(
        manifest.supportedSpecRange!, currentSpecVersion)) {
      throw AnalysisError(
        code: 'plugin.incompatible_version',
        message: 'Plugin "${manifest.functionName}" requires spec version '
            '${manifest.supportedSpecRange} but current is $currentSpecVersion',
        details: {
          'plugin': manifest.functionName,
          'supportedRange': manifest.supportedSpecRange,
          'currentVersion': currentSpecVersion,
        },
      );
    }

    if (_catalog.has(manifest.functionName)) {
      throw AnalysisError(
        code: 'analysis.duplicate_function',
        message: 'Function "${manifest.functionName}" is already registered',
      );
    }

    // Register function info
    final info = AnalysisFunctionInfo(
      functionName: manifest.functionName,
      description: manifest.description,
      parameters: {
        for (final p in manifest.parameters) p.name: p,
      },
      supportedDataTypes: manifest.supportedDataTypes,
      plugin: manifest.functionName,
      specVersionRange: manifest.supportedSpecRange,
    );

    _catalog.register(info);
    _dispatcher.registerImplementation(manifest.functionName, implementation);
    _loadedPlugins.add(manifest.functionName);
    _manifests[manifest.functionName] = manifest;
  }

  /// Unload a plugin by function name.
  void unloadPlugin(String functionName) {
    _catalog.unregister(functionName);
    _loadedPlugins.remove(functionName);
    _manifests.remove(functionName);
  }

  /// Check if a function was loaded as a plugin.
  bool isPlugin(String functionName) {
    return _loadedPlugins.contains(functionName);
  }

  /// Get the manifest for a loaded plugin. Returns null if not a plugin.
  PluginManifest? getManifest(String functionName) {
    return _manifests[functionName];
  }

  /// Get loaded plugin names.
  List<String> getLoadedPlugins() {
    return _loadedPlugins.toList();
  }

  /// Execute a plugin function with timeout enforcement.
  /// Wraps plugin execution with Future.timeout to prevent runaway plugins.
  Future<AnalysisFunctionResult> executeWithTimeout(
    AnalysisFunction plugin,
    AnalysisDataSet data,
    Map<String, dynamic> parameters,
    Duration timeout,
  ) async {
    try {
      return await plugin.execute(parameters, data).timeout(
            timeout,
            onTimeout: () => throw AnalysisError(
              code: 'analysis.execution_error',
              message:
                  'Plugin execution exceeded timeout of ${timeout.inSeconds}s',
              details: {'timeout': timeout.inSeconds},
            ),
          );
    } catch (e) {
      if (e is AnalysisError) rethrow;
      throw AnalysisError(
        code: 'plugin.execution_error',
        message: 'Plugin execution failed: $e',
      );
    }
  }

  /// Check if currentVersion satisfies the version range constraint.
  /// Supports formats: ">=1.0.0 <2.0.0", "^1.0.0", ">=1.0.0"
  bool _isVersionCompatible(String range, String currentVersion) {
    final current = _parseVersion(currentVersion);
    if (current == null) return false;

    // Handle caret syntax: ^1.2.3 means >=1.2.3 <2.0.0
    if (range.startsWith('^')) {
      final base = _parseVersion(range.substring(1).trim());
      if (base == null) return false;
      final nextMajor = [base[0] + 1, 0, 0];
      return _compareVersions(current, base) >= 0 &&
          _compareVersions(current, nextMajor) < 0;
    }

    // Handle space-separated constraints: ">=1.0.0 <2.0.0"
    final constraints = range.split(RegExp(r'\s+'));
    for (final constraint in constraints) {
      if (constraint.isEmpty) continue;
      if (!_satisfiesConstraint(current, constraint)) return false;
    }
    return true;
  }

  bool _satisfiesConstraint(List<int> current, String constraint) {
    if (constraint.startsWith('>=')) {
      final v = _parseVersion(constraint.substring(2));
      return v != null && _compareVersions(current, v) >= 0;
    } else if (constraint.startsWith('>')) {
      final v = _parseVersion(constraint.substring(1));
      return v != null && _compareVersions(current, v) > 0;
    } else if (constraint.startsWith('<=')) {
      final v = _parseVersion(constraint.substring(2));
      return v != null && _compareVersions(current, v) <= 0;
    } else if (constraint.startsWith('<')) {
      final v = _parseVersion(constraint.substring(1));
      return v != null && _compareVersions(current, v) < 0;
    } else if (constraint.startsWith('=')) {
      final v = _parseVersion(constraint.substring(1));
      return v != null && _compareVersions(current, v) == 0;
    }
    // Plain version means exact match
    final v = _parseVersion(constraint);
    return v != null && _compareVersions(current, v) == 0;
  }

  List<int>? _parseVersion(String version) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version.trim());
    if (match == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  int _compareVersions(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }
}
