import 'package:mcp_bundle/ports.dart';

/// Validation issue found during spec validation.
class SpecValidationIssue {
  const SpecValidationIssue({
    required this.field,
    required this.message,
    required this.code,
  });

  /// Field path where the issue was found.
  final String field;

  /// Human-readable description.
  final String message;

  /// Error code for programmatic handling.
  final String code;
}

/// Validates AnalysisSpec structural integrity.
class SpecValidator {
  /// Result keys the engine supplies itself rather than a step.
  ///
  /// A streaming job emits from the window it is accumulating, not from a
  /// function's results, so an output that reads one of these resolves
  /// even though no step produces it. The same spec runs batch or
  /// streaming — mode is chosen at `runAnalysis`, not declared here — so
  /// these are accepted for any spec.
  ///
  /// Kept beside the rest of the validation because a spec naming one of
  /// them is well-formed; `StreamExecutor` writes exactly these keys.
  static const Set<String> engineSuppliedResultKeys = {
    'windowState',
    'pointCount',
    'lateDropped',
    'overflowDropped',
  };

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

    // Two steps under one key would leave only the last result, and an
    // output pointing at no step would build an empty artifact from a
    // completed job. Both used to pass silently, so both are rejected here.
    final stepKeys = <String, int>{};
    for (var i = 0; i < spec.analysisSteps.length; i++) {
      final key = spec.analysisSteps[i].resultKey;
      final firstIndex = stepKeys[key];
      if (firstIndex != null) {
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i]',
          message: 'Step key "$key" is already used by analysisSteps'
              '[$firstIndex]. Give each step a distinct "id" when the same '
              'function runs more than once.',
          code: 'spec.invalid.duplicate_step_key',
        ));
      } else {
        stepKeys[key] = i;
      }
    }

    // A step reading another step's result must read one that already
    // ran. Requiring the source to appear earlier keeps execution a single
    // forward pass and makes a cycle unwritable rather than detected.
    for (var i = 0; i < spec.analysisSteps.length; i++) {
      final input = spec.analysisSteps[i].input;
      if (input == null) continue;

      final sourceIndex = stepKeys[input.from];
      if (sourceIndex == null) {
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].input.from',
          message: 'Step input reads "${input.from}", which no step '
              'produces. Available: ${stepKeys.keys.join(", ")}',
          code: 'spec.invalid.unresolved_step_input',
        ));
      } else if (sourceIndex >= i) {
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].input.from',
          message: 'Step input reads "${input.from}", which runs at '
              'analysisSteps[$sourceIndex] — at or after this step. Order '
              'the producing step first.',
          code: 'spec.invalid.step_input_order',
        ));
      }

      if (input.field.isEmpty) {
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].input.field',
          message: 'Step input must name the result field it reads',
          code: 'spec.invalid.missing_field',
        ));
      }
    }

    for (var i = 0; i < spec.outputs.length; i++) {
      final output = spec.outputs[i];
      if (stepKeys.isEmpty) continue;
      if (!stepKeys.containsKey(output.sourceKey) &&
          !engineSuppliedResultKeys.contains(output.sourceKey)) {
        issues.add(SpecValidationIssue(
          field: output.from != null ? 'outputs[$i].from' : 'outputs[$i].name',
          message: 'Output "${output.name}" reads step key '
              '"${output.sourceKey}", which no step produces. '
              'Available: ${stepKeys.keys.join(", ")}'
              ', or the streaming keys '
              '${engineSuppliedResultKeys.join(", ")}',
          code: 'spec.invalid.unresolved_output_source',
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

    for (var i = 0; i < spec.analysisSteps.length; i++) {
      final transforms = spec.analysisSteps[i].transforms;
      for (var t = 0; t < transforms.length; t++) {
        if (transforms[t].name.isNotEmpty) continue;
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].transforms[$t].name',
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

  /// Validate that every output's `field` / `indexField` names a result
  /// the source step's function declares.
  ///
  /// [declaredResultFields] maps a function name to the keys it publishes
  /// in [AnalysisFunctionInfo.results]; the contract layer takes it as
  /// plain data rather than reaching for the catalog. A function that
  /// declares nothing is skipped — there is nothing to check it against,
  /// and refusing the binding would punish the spec for the function's
  /// silence.
  List<SpecValidationIssue> validateResultBindings(
    AnalysisSpec spec,
    Map<String, Set<String>> declaredResultFields,
  ) {
    final issues = <SpecValidationIssue>[];
    final functionByStepKey = <String, String>{
      for (final step in spec.analysisSteps) step.resultKey: step.function,
    };

    for (var i = 0; i < spec.analysisSteps.length; i++) {
      final input = spec.analysisSteps[i].input;
      if (input == null) continue;
      final function = functionByStepKey[input.from];
      if (function == null) continue;
      final declared = declaredResultFields[function];
      if (declared == null || declared.isEmpty) continue;

      for (final entry in <(String, String?)>[
        ('field', input.field),
        ('indexField', input.indexField),
      ]) {
        final (label, value) = entry;
        if (value == null || declared.contains(value)) continue;
        issues.add(SpecValidationIssue(
          field: 'analysisSteps[$i].input.$label',
          message: 'Step input reads result field "$value", which '
              '"$function" does not produce. '
              'Available: ${(declared.toList()..sort()).join(", ")}',
          code: 'spec.invalid.unknown_result_field',
        ));
      }
    }

    for (var i = 0; i < spec.outputs.length; i++) {
      final output = spec.outputs[i];
      final function = functionByStepKey[output.sourceKey];
      if (function == null) continue;
      final declared = declaredResultFields[function];
      if (declared == null || declared.isEmpty) continue;

      for (final entry in <(String, String?)>[
        ('field', output.field),
        ('indexField', output.indexField),
      ]) {
        final (label, value) = entry;
        if (value == null || declared.contains(value)) continue;
        issues.add(SpecValidationIssue(
          field: 'outputs[$i].$label',
          message: 'Output "${output.name}" reads result field "$value", '
              'which "$function" does not produce. '
              'Available: ${(declared.toList()..sort()).join(", ")}',
          code: 'spec.invalid.unknown_result_field',
        ));
      }
    }
    return issues;
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
