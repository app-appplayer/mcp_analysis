import 'package:mcp_bundle/ports.dart';

/// Maintains registry of all available analysis functions.
class FunctionCatalog {
  final Map<String, AnalysisFunctionInfo> _functions = {};

  /// Register a function. Throws if duplicate.
  void register(AnalysisFunctionInfo info) {
    if (_functions.containsKey(info.functionName)) {
      throw AnalysisError(
        code: 'analysis.duplicate_function',
        message: 'Function "${info.functionName}" is already registered',
      );
    }
    _functions[info.functionName] = info;
  }

  /// Get function by name. Returns null if not found.
  AnalysisFunctionInfo? get(String functionName) {
    return _functions[functionName];
  }

  /// Check if a function is registered.
  bool has(String functionName) {
    return _functions.containsKey(functionName);
  }

  /// Get all registered functions.
  List<AnalysisFunctionInfo> getAll() {
    return _functions.values.toList();
  }

  /// Get all registered function names.
  List<String> getAvailableNames() {
    return _functions.keys.toList();
  }

  /// Unregister a function. Returns false if not found.
  bool unregister(String functionName) {
    return _functions.remove(functionName) != null;
  }

  /// Search functions by category or supported data type.
  List<AnalysisFunctionInfo> search({
    String? category,
    String? dataType,
  }) {
    return _functions.values.where((f) {
      if (category != null) {
        // Check description or function name for category match
        if (!f.functionName.toLowerCase().contains(category.toLowerCase()) &&
            !f.description.toLowerCase().contains(category.toLowerCase())) {
          return false;
        }
      }
      if (dataType != null && !f.supportedDataTypes.contains(dataType)) {
        return false;
      }
      return true;
    }).toList();
  }
}
