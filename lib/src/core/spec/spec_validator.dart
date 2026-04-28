import 'package:mcp_bundle/ports.dart';

/// Validation issue found during spec validation.
class SpecValidationIssue {
  /// Field path where the issue was found.
  final String field;

  /// Human-readable description.
  final String message;

  /// Error code for programmatic handling.
  final String code;

  const SpecValidationIssue({
    required this.field,
    required this.message,
    required this.code,
  });
}

/// Validates AnalysisSpec structural integrity.
class SpecValidator {
  static final RegExp _specIdPattern = RegExp(r'^[a-zA-Z0-9\-_]+$');
  static final RegExp _semverPattern =
      RegExp(r'^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$');

  /// Validate a Spec for correctness.
  /// Returns a list of validation issues (empty = valid).
  List<SpecValidationIssue> validate(AnalysisSpec spec) {
    final issues = <SpecValidationIssue>[];

    if (!isValidSpecId(spec.specId)) {
      issues.add(const SpecValidationIssue(
        field: 'specId',
        message:
            'specId must be non-empty, alphanumeric with hyphens/underscores, max 128 chars',
        code: 'spec.invalid.bad_spec_id',
      ));
    }

    if (!isValidVersion(spec.version)) {
      issues.add(const SpecValidationIssue(
        field: 'version',
        message: 'version must be valid semver (e.g., 1.0.0)',
        code: 'spec.invalid.bad_version',
      ));
    }

    if (spec.inputSources.isEmpty) {
      issues.add(const SpecValidationIssue(
        field: 'inputSources',
        message: 'At least one input source is required',
        code: 'spec.invalid.missing_field',
      ));
    }

    if (spec.analysisSteps.isEmpty) {
      issues.add(const SpecValidationIssue(
        field: 'analysisSteps',
        message: 'At least one analysis step is required',
        code: 'spec.invalid.missing_field',
      ));
    }

    if (spec.outputs.isEmpty) {
      issues.add(const SpecValidationIssue(
        field: 'outputs',
        message: 'At least one output definition is required',
        code: 'spec.invalid.missing_field',
      ));
    }

    for (var i = 0; i < spec.analysisSteps.length; i++) {
      final step = spec.analysisSteps[i];
      if (step.function.isEmpty) {
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].function',
          message: 'Analysis step function name must not be empty',
          code: 'spec.invalid.empty_function',
        ));
      }
    }

    for (var i = 0; i < spec.transforms.length; i++) {
      final transform = spec.transforms[i];
      if (transform.name.isEmpty) {
        issues.add(SpecValidationIssue(
          field: 'transforms[$i].name',
          message: 'Transform name must not be empty',
          code: 'spec.invalid.empty_transform',
        ));
      }
    }

    return issues;
  }

  /// Validate that specId conforms to naming rules.
  bool isValidSpecId(String specId) {
    if (specId.isEmpty || specId.length > 128) return false;
    return _specIdPattern.hasMatch(specId);
  }

  /// Validate that version is valid semver.
  bool isValidVersion(String version) {
    return _semverPattern.hasMatch(version);
  }

  /// Validate that all referenced function names exist in catalog.
  List<SpecValidationIssue> validateFunctionReferences(
    AnalysisSpec spec,
    List<String> availableFunctions,
  ) {
    final issues = <SpecValidationIssue>[];
    for (var i = 0; i < spec.analysisSteps.length; i++) {
      final funcName = spec.analysisSteps[i].function;
      if (!availableFunctions.contains(funcName)) {
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].function',
          message:
              'Function "$funcName" not found in catalog. Available: ${availableFunctions.join(", ")}',
          code: 'spec.invalid.unknown_function',
        ));
      }
    }
    return issues;
  }
}
