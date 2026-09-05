import 'package:mcp_bundle/ports.dart';

import 'function_catalog.dart';
import 'plugin_loader.dart';

/// Interface for analysis function implementations.
abstract class AnalysisFunction {
  /// Function metadata.
  AnalysisFunctionInfo get info;

  /// Execute the function against data.
  Future<AnalysisFunctionResult> execute(
    Map<String, dynamic> parameters,
    AnalysisDataSet data,
  );
}

/// Routes analysis function execution requests.
class FunctionDispatcher implements AnalysisFunctionPort {
  FunctionDispatcher({required FunctionCatalog catalog}) : _catalog = catalog;
  final FunctionCatalog _catalog;
  final Map<String, AnalysisFunction> _implementations = {};
  PluginLoader? _pluginLoader;

  /// Set the plugin loader for timeout enforcement on plugin functions.
  void setPluginLoader(PluginLoader loader) {
    _pluginLoader = loader;
  }

  /// Register a function implementation.
  void registerImplementation(String functionName, AnalysisFunction impl) {
    _implementations[functionName] = impl;
  }

  /// Register all built-in function implementations.
  void registerBuiltins(List<AnalysisFunction> builtins) {
    for (final builtin in builtins) {
      _catalog.register(builtin.info);
      _implementations[builtin.info.functionName] = builtin;
    }
  }

  @override
  Future<void> registerFunction(AnalysisFunctionInfo function) async {
    _catalog.register(function);
  }

  @override
  Future<List<AnalysisFunctionInfo>> getFunctionCatalog() async {
    return _catalog.getAll();
  }

  @override
  Future<AnalysisFunctionResult> executeFunction({
    required String functionName,
    required Map<String, dynamic> parameters,
    required AnalysisDataSet data,
  }) async {
    // Lookup in catalog
    final functionInfo = _catalog.get(functionName);
    if (functionInfo == null) {
      throw AnalysisError(
        code: 'analysis.unsupported_function',
        message:
            'Function "$functionName" not found. Available: ${_catalog.getAvailableNames().join(", ")}',
        details: {'available': _catalog.getAvailableNames()},
      );
    }

    // Validate required parameters
    for (final entry in functionInfo.parameters.entries) {
      final schema = entry.value;
      if (schema.defaultValue == null && !parameters.containsKey(entry.key)) {
        throw AnalysisError(
          code: 'analysis.parameter_error',
          message:
              'Missing required parameter "${entry.key}" for function "$functionName"',
          details: {
            'function': functionName,
            'parameter': entry.key,
            'type': schema.type,
          },
        );
      }
    }

    // Lookup implementation
    final impl = _implementations[functionName];
    if (impl == null) {
      throw AnalysisError(
        code: 'analysis.unsupported_function',
        message: 'No implementation registered for function "$functionName"',
      );
    }

    // Execute with timeout wrapping for plugin functions, direct call for builtins
    try {
      final pluginLoader = _pluginLoader;
      if (pluginLoader != null && pluginLoader.isPlugin(functionName)) {
        final manifest = pluginLoader.getManifest(functionName)!;
        return await pluginLoader.executeWithTimeout(
          impl,
          data,
          parameters,
          manifest.executionTimeout,
        );
      }
      return await impl.execute(parameters, data);
    } catch (e) {
      if (e is AnalysisError) rethrow;
      throw AnalysisError(
        code: 'analysis.execution_error',
        message: 'Function "$functionName" execution failed: $e',
        step: 'function:$functionName',
        details: {'parameters': parameters},
      );
    }
  }

  @override
  Future<void> unregisterFunction(String functionName) async {
    _catalog.unregister(functionName);
    _implementations.remove(functionName);
  }
}
