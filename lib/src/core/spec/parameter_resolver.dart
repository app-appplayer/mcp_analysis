/// Merges Spec-level default parameters with runtime overrides.
class ParameterResolver {
  /// Merge default parameters from Spec with runtime overrides.
  /// Runtime values take precedence over Spec defaults.
  Map<String, dynamic> resolve(
    Map<String, dynamic> specDefaults,
    Map<String, dynamic> runtimeOverrides,
  ) {
    return {
      ...specDefaults,
      ...runtimeOverrides,
    };
  }

  /// Substitute parameter references in string templates.
  /// e.g., "\${threshold}" in a transform step gets replaced with actual value.
  String substituteInString(
    String template,
    Map<String, dynamic> parameters,
  ) {
    var result = template;
    for (final entry in parameters.entries) {
      result = result.replaceAll('\${${entry.key}}', '${entry.value}');
    }
    return result;
  }
}
