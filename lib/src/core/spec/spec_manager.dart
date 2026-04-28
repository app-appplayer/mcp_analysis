import 'package:mcp_bundle/ports.dart';

import 'parameter_resolver.dart';
import 'spec_operations.dart';
import 'spec_validator.dart';

/// Primary facade for AnalysisSpec lifecycle operations.
class SpecManager implements SpecOperations {
  final StoragePort<AnalysisSpec> _storage;
  final SpecValidator _validator;
  final ParameterResolver _parameterResolver;

  SpecManager({
    required StoragePort<AnalysisSpec> storage,
    required SpecValidator validator,
    required ParameterResolver parameterResolver,
  })  : _storage = storage,
        _validator = validator,
        _parameterResolver = parameterResolver;

  /// List Specs with optional search, pagination.
  Future<List<AnalysisSpec>> listSpecs({
    String? search,
    int? limit,
    int? offset,
  }) async {
    var results = await _storage.getAll();

    if (search != null && search.isNotEmpty) {
      final query = search.toLowerCase();
      results = results.where((s) {
        final matchId = s.specId.toLowerCase().contains(query);
        final matchDesc =
            s.metadata.description?.toLowerCase().contains(query) ?? false;
        return matchId || matchDesc;
      }).toList();
    }

    if (offset != null && offset > 0 && offset < results.length) {
      results = results.sublist(offset);
    }

    if (limit != null && limit > 0 && limit < results.length) {
      results = results.sublist(0, limit);
    }

    return results;
  }

  /// Retrieve a single Spec by specId.
  Future<AnalysisSpec?> getSpec(String specId) async {
    return _storage.get(specId);
  }

  /// Create and store a new Spec.
  Future<AnalysisSpec> createSpec(AnalysisSpec spec) async {
    final existing = await _storage.exists(spec.specId);
    if (existing) {
      throw AnalysisError(
        code: 'spec.duplicate',
        message:
            'Spec with specId "${spec.specId}" version "${spec.version}" already exists',
        details: {'specId': spec.specId, 'version': spec.version},
      );
    }

    final issues = _validator.validate(spec);
    if (issues.isNotEmpty) {
      throw AnalysisError(
        code: 'spec.invalid',
        message: 'Spec validation failed with ${issues.length} issue(s)',
        details: {
          'issues': issues
              .map((i) => {
                    'field': i.field,
                    'message': i.message,
                    'code': i.code,
                  })
              .toList(),
        },
      );
    }

    await _storage.save(spec.specId, spec);
    return spec;
  }

  /// Update an existing Spec.
  Future<AnalysisSpec> updateSpec(String specId, AnalysisSpec spec) async {
    final existing = await _storage.get(specId);
    if (existing == null) {
      throw AnalysisError(
        code: 'spec.not_found',
        message: 'Spec with specId "$specId" not found',
        details: {'specId': specId},
      );
    }

    final issues = _validator.validate(spec);
    if (issues.isNotEmpty) {
      throw AnalysisError(
        code: 'spec.invalid',
        message: 'Spec validation failed with ${issues.length} issue(s)',
        details: {
          'issues': issues
              .map((i) => {
                    'field': i.field,
                    'message': i.message,
                    'code': i.code,
                  })
              .toList(),
        },
      );
    }

    await _storage.save(specId, spec);
    return spec;
  }

  /// Resolve parameters: merge Spec defaults with runtime overrides.
  Map<String, dynamic> resolveParameters(
    AnalysisSpec spec,
    Map<String, dynamic> runtimeOverrides,
  ) {
    return _parameterResolver.resolve(spec.parameters, runtimeOverrides);
  }
}
