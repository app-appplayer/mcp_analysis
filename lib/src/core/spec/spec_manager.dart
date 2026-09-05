import 'package:mcp_bundle/ports.dart';

import 'parameter_resolver.dart';
import 'spec_operations.dart';
import 'spec_validator.dart';

/// Primary facade for AnalysisSpec lifecycle operations.
class SpecManager implements SpecOperations {
  SpecManager({
    required StoragePort<AnalysisSpec> storage,
    required SpecValidator validator,
    required ParameterResolver parameterResolver,
    Map<String, Set<String>> Function()? declaredResultFields,
    StoragePort<AnalysisSpec>? versionStorage,
  })  : _versionStorage = versionStorage,
        _storage = storage,
        _validator = validator,
        _parameterResolver = parameterResolver,
        _declaredResultFields = declaredResultFields;
  final StoragePort<AnalysisSpec> _storage;
  final SpecValidator _validator;
  final ParameterResolver _parameterResolver;

  /// Result field names each function publishes, read at validation time.
  ///
  /// A callback rather than a snapshot because the catalog can gain
  /// functions after this manager is built. Absent when the host wires no
  /// catalog — output field bindings then go unchecked.
  final Map<String, Set<String>> Function()? _declaredResultFields;

  /// Every version ever stored, keyed `<specId>@<version>`.
  ///
  /// An artifact's provenance records the spec version that produced it,
  /// but the spec store keys by id alone and `updateSpec` overwrites — so
  /// the version an artifact pointed at stopped existing the moment the
  /// spec was edited. Reproducibility was a claim the storage could not
  /// answer. Absent when a host wires no history; [getSpecVersion] then
  /// serves only the current one.
  final StoragePort<AnalysisSpec>? _versionStorage;

  static String _versionKey(String specId, String version) =>
      '$specId@$version';

  Future<void> _archive(AnalysisSpec spec) async {
    await _versionStorage?.save(_versionKey(spec.specId, spec.version), spec);
  }

  /// Retrieve a specific version of a Spec.
  ///
  /// Falls back to the current spec when it happens to be that version, so
  /// a host with no history still answers for what it holds rather than
  /// reporting the version missing.
  Future<AnalysisSpec?> getSpecVersion(String specId, String version) async {
    final archived = await _versionStorage?.get(_versionKey(specId, version));
    if (archived != null) return archived;
    final current = await _storage.get(specId);
    return current != null && current.version == version ? current : null;
  }

  /// Versions of [specId] that can still be retrieved, newest stored last.
  Future<List<String>> listSpecVersions(String specId) async {
    final history = _versionStorage;
    final versions = <String>{};
    final current = await _storage.get(specId);
    if (current != null) versions.add(current.version);
    if (history != null) {
      for (final spec in await history.getAll()) {
        if (spec.specId == specId) versions.add(spec.version);
      }
    }
    return versions.toList()..sort();
  }

  List<SpecValidationIssue> _validateAll(AnalysisSpec spec) {
    final issues = _validator.validate(spec);
    final declared = _declaredResultFields?.call();
    if (declared != null) {
      issues.addAll(_validator.validateResultBindings(spec, declared));
    }
    return issues;
  }

  /// List Specs with optional search, pagination.
  @override
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
  @override
  Future<AnalysisSpec?> getSpec(String specId) async {
    return _storage.get(specId);
  }

  /// Create and store a new Spec.
  @override
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

    final issues = _validateAll(spec);
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
    await _archive(spec);
    return spec;
  }

  /// Delete a Spec.
  ///
  /// Absent from the port until now, so a spec written by mistake — or by
  /// a model exploring — stayed for the life of the process with no way
  /// to take it back.
  Future<void> deleteSpec(String specId) async {
    final existing = await _storage.get(specId);
    if (existing == null) {
      throw AnalysisError(
        code: 'spec.not_found',
        message: 'Spec with specId "$specId" not found',
        details: {'specId': specId},
      );
    }
    await _storage.delete(specId);
  }

  /// Update an existing Spec.
  @override
  Future<AnalysisSpec> updateSpec(String specId, AnalysisSpec spec) async {
    final existing = await _storage.get(specId);
    if (existing == null) {
      throw AnalysisError(
        code: 'spec.not_found',
        message: 'Spec with specId "$specId" not found',
        details: {'specId': specId},
      );
    }

    final issues = _validateAll(spec);
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
    // The version being replaced stays retrievable — an artifact already
    // points at it.
    await _archive(spec);
    return spec;
  }

  /// Resolve parameters: merge Spec defaults with runtime overrides.
  @override
  Map<String, dynamic> resolveParameters(
    AnalysisSpec spec,
    Map<String, dynamic> runtimeOverrides,
  ) {
    return _parameterResolver.resolve(spec.parameters, runtimeOverrides);
  }
}
