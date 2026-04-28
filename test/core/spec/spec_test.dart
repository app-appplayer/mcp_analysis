import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

// ============================================================================
// Helper
// ============================================================================

/// Create a minimal valid AnalysisSpec for testing.
AnalysisSpec _createSpec({
  String specId = 'test-spec',
  String version = '1.0.0',
  String? description,
}) {
  return AnalysisSpec(
    specId: specId,
    version: version,
    inputSources: [
      AnalysisInputSource(
        sourceType: AnalysisSourceType.factgraph,
        query: 'temp',
      ),
    ],
    analysisSteps: [
      AnalysisStep(
        function: 'descriptive_stats',
        parameters: {
          'columns': ['temp'],
        },
      ),
    ],
    outputs: [
      AnalysisOutputDef(
        type: AnalysisArtifactType.metric,
        name: 'stats',
      ),
    ],
    metadata: AnalysisSpecMetadata(
      description: description ?? 'Test',
      tags: ['test'],
    ),
  );
}

void main() {
  // ==========================================================================
  // SpecManager Tests
  // ==========================================================================
  group('SpecManager', () {
    late InMemoryStorage<AnalysisSpec> storage;
    late SpecValidator validator;
    late ParameterResolver parameterResolver;
    late SpecManager manager;

    setUp(() {
      storage = InMemoryStorage<AnalysisSpec>();
      validator = SpecValidator();
      parameterResolver = ParameterResolver();
      manager = SpecManager(
        storage: storage,
        validator: validator,
        parameterResolver: parameterResolver,
      );
    });

    // TC-001
    test('listSpecs returns empty list when no specs exist', () async {
      final result = await manager.listSpecs();
      expect(result, isEmpty);
    });

    // TC-002
    test('listSpecs returns all specs', () async {
      final specA = _createSpec(specId: 'spec-a');
      final specB = _createSpec(specId: 'spec-b');
      await manager.createSpec(specA);
      await manager.createSpec(specB);

      final result = await manager.listSpecs();
      expect(result, hasLength(2));
    });

    // TC-003
    test('listSpecs filters by search keyword', () async {
      await manager.createSpec(
        _createSpec(specId: 'weather-analysis', description: 'Weather data'),
      );
      await manager.createSpec(
        _createSpec(specId: 'sales-report', description: 'Sales data'),
      );

      // Search by specId substring
      final byId = await manager.listSpecs(search: 'weather');
      expect(byId, hasLength(1));
      expect(byId.first.specId, 'weather-analysis');

      // Search by description substring
      final byDesc = await manager.listSpecs(search: 'Sales');
      expect(byDesc, hasLength(1));
      expect(byDesc.first.specId, 'sales-report');
    });

    // TC-004
    test('listSpecs respects limit/offset pagination', () async {
      for (var i = 0; i < 5; i++) {
        await manager.createSpec(_createSpec(specId: 'spec-$i'));
      }

      // Offset skips the first 2 items
      final offsetResult = await manager.listSpecs(offset: 2);
      expect(offsetResult, hasLength(3));

      // Limit caps the result count
      final limitResult = await manager.listSpecs(limit: 2);
      expect(limitResult, hasLength(2));

      // Offset + limit together
      final pagedResult = await manager.listSpecs(offset: 1, limit: 2);
      expect(pagedResult, hasLength(2));
    });

    // TC-005
    test('getSpec returns spec by specId', () async {
      final spec = _createSpec(specId: 'lookup-me');
      await manager.createSpec(spec);

      final result = await manager.getSpec('lookup-me');
      expect(result, isNotNull);
      expect(result!.specId, 'lookup-me');
    });

    // TC-006
    test('getSpec returns null for non-existent specId', () async {
      final result = await manager.getSpec('does-not-exist');
      expect(result, isNull);
    });

    // TC-007
    test('createSpec stores valid spec', () async {
      final spec = _createSpec(specId: 'new-spec');
      final created = await manager.createSpec(spec);

      expect(created.specId, 'new-spec');

      final fetched = await manager.getSpec('new-spec');
      expect(fetched, isNotNull);
      expect(fetched!.specId, 'new-spec');
    });

    // TC-008
    test('createSpec rejects duplicate specId with spec.duplicate', () async {
      await manager.createSpec(_createSpec(specId: 'dup-spec'));

      expect(
        () => manager.createSpec(_createSpec(specId: 'dup-spec')),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.duplicate',
          ),
        ),
      );
    });

    // TC-009
    test('createSpec rejects empty specId with spec.invalid', () async {
      // Empty specId fails validation, producing spec.invalid
      expect(
        () => manager.createSpec(_createSpec(specId: '')),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.invalid',
          ),
        ),
      );
    });

    // TC-010
    test('updateSpec updates existing spec', () async {
      await manager.createSpec(_createSpec(specId: 'evolving'));

      final updated = _createSpec(
        specId: 'evolving',
        version: '2.0.0',
        description: 'Updated description',
      );
      final result = await manager.updateSpec('evolving', updated);

      expect(result.version, '2.0.0');

      final fetched = await manager.getSpec('evolving');
      expect(fetched, isNotNull);
      expect(fetched!.version, '2.0.0');
      expect(fetched.metadata.description, 'Updated description');
    });

    // TC-011
    test('updateSpec throws spec.not_found for non-existent specId', () async {
      final spec = _createSpec(specId: 'ghost');
      expect(
        () => manager.updateSpec('ghost', spec),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.not_found',
          ),
        ),
      );
    });

    // TC-012
    test('resolveParameters merges defaults with overrides (override wins)',
        () async {
      final spec = AnalysisSpec(
        specId: 'param-spec',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temp',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {
              'columns': ['temp'],
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'stats',
          ),
        ],
        parameters: {'threshold': 0.5, 'window': 10},
        metadata: const AnalysisSpecMetadata(description: 'Param test'),
      );

      final resolved = manager.resolveParameters(
        spec,
        {'threshold': 0.9, 'extra': true},
      );

      // Override wins for threshold
      expect(resolved['threshold'], 0.9);
      // Default preserved for window
      expect(resolved['window'], 10);
      // New key from overrides is included
      expect(resolved['extra'], true);
    });

    // TC-013
    test('resolveParameters uses defaults when no overrides', () async {
      final spec = AnalysisSpec(
        specId: 'default-spec',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'temp',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {
              'columns': ['temp'],
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'stats',
          ),
        ],
        parameters: {'threshold': 0.5, 'window': 10},
        metadata: const AnalysisSpecMetadata(description: 'Defaults test'),
      );

      final resolved = manager.resolveParameters(spec, {});

      expect(resolved['threshold'], 0.5);
      expect(resolved['window'], 10);
    });
  });

  // ==========================================================================
  // SpecValidator Tests
  // ==========================================================================
  group('SpecValidator', () {
    late SpecValidator validator;

    setUp(() {
      validator = SpecValidator();
    });

    // TC-014
    test('validate accepts valid spec (empty issues)', () {
      final spec = _createSpec();
      final issues = validator.validate(spec);
      expect(issues, isEmpty);
    });

    // TC-015
    test('validate rejects empty specId', () {
      final spec = _createSpec(specId: '');
      final issues = validator.validate(spec);

      expect(issues, isNotEmpty);
      expect(
        issues.any((i) => i.field == 'specId'),
        isTrue,
        reason: 'Should report an issue on the specId field',
      );
    });

    // TC-016
    test('validate rejects non-semver version', () {
      final spec = _createSpec(version: 'abc');
      final issues = validator.validate(spec);

      expect(issues, isNotEmpty);
      expect(
        issues.any((i) => i.field == 'version'),
        isTrue,
        reason: 'Should report an issue on the version field',
      );
    });

    // TC-017
    test('validate rejects spec with no inputSources', () {
      final spec = AnalysisSpec(
        specId: 'no-sources',
        version: '1.0.0',
        inputSources: [],
        analysisSteps: [
          AnalysisStep(
            function: 'descriptive_stats',
            parameters: {'columns': ['x']},
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'No sources'),
      );

      final issues = validator.validate(spec);
      expect(issues, isNotEmpty);
      expect(
        issues.any((i) => i.field == 'inputSources'),
        isTrue,
        reason: 'Should report an issue on the inputSources field',
      );
    });

    // TC-018
    test('validateFunctionReferences detects unknown function', () {
      final spec = AnalysisSpec(
        specId: 'func-check',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            function: 'unknown_function',
            parameters: {},
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Func check'),
      );

      final available = ['descriptive_stats', 'anomaly_detect'];
      final issues = validator.validateFunctionReferences(spec, available);

      expect(issues, isNotEmpty);
      expect(
        issues.any((i) =>
            i.code == 'spec.invalid.unknown_function' &&
            i.message.contains('unknown_function')),
        isTrue,
        reason:
            'Should report unknown_function not found in available catalog',
      );
    });
  });

  // ==========================================================================
  // ParameterResolver Tests
  // ==========================================================================
  group('ParameterResolver', () {
    late ParameterResolver resolver;

    setUp(() {
      resolver = ParameterResolver();
    });

    test('substituteInString replaces single parameter placeholder', () {
      final result = resolver.substituteInString(
        'threshold is \${threshold}',
        {'threshold': 0.5},
      );
      expect(result, equals('threshold is 0.5'));
    });

    test('substituteInString replaces multiple parameter placeholders', () {
      final result = resolver.substituteInString(
        'min=\${min}, max=\${max}, unit=\${unit}',
        {'min': 10, 'max': 100, 'unit': 'F'},
      );
      expect(result, equals('min=10, max=100, unit=F'));
    });

    test('substituteInString returns template unchanged when no parameters match', () {
      final result = resolver.substituteInString(
        'no placeholders here',
        {'threshold': 0.5},
      );
      expect(result, equals('no placeholders here'));
    });

    test('substituteInString keeps unmatched placeholders', () {
      final result = resolver.substituteInString(
        'value=\${value}, missing=\${missing}',
        {'value': 42},
      );
      expect(result, equals('value=42, missing=\${missing}'));
    });

    test('substituteInString handles empty parameters map', () {
      final result = resolver.substituteInString(
        'template \${a} \${b}',
        {},
      );
      expect(result, equals('template \${a} \${b}'));
    });

    test('substituteInString handles empty template string', () {
      final result = resolver.substituteInString(
        '',
        {'key': 'value'},
      );
      expect(result, equals(''));
    });

    test('substituteInString replaces repeated occurrences of same parameter', () {
      final result = resolver.substituteInString(
        '\${x} + \${x} = 2*\${x}',
        {'x': 5},
      );
      expect(result, equals('5 + 5 = 2*5'));
    });
  });

  // ==========================================================================
  // SpecValidator coverage boost
  // ==========================================================================
  group('SpecValidator coverage boost', () {
    late SpecValidator validator;

    setUp(() {
      validator = SpecValidator();
    });

    // isValidSpecId directly: empty string
    test('isValidSpecId returns false for empty string', () {
      expect(validator.isValidSpecId(''), isFalse);
    });

    // isValidSpecId directly: valid alphanumeric with hyphens/underscores
    test('isValidSpecId returns true for valid id', () {
      expect(validator.isValidSpecId('my-spec_123'), isTrue);
    });

    // isValidSpecId: special characters
    test('isValidSpecId returns false for special characters', () {
      expect(validator.isValidSpecId('spec@#\$'), isFalse);
      expect(validator.isValidSpecId('spec with spaces'), isFalse);
      expect(validator.isValidSpecId('spec.dot'), isFalse);
    });

    // isValidSpecId: max length (128)
    test('isValidSpecId accepts id at max length 128', () {
      final maxId = 'a' * 128;
      expect(validator.isValidSpecId(maxId), isTrue);
    });

    // isValidSpecId: exceeds max length
    test('isValidSpecId returns false for id exceeding 128 chars', () {
      final longId = 'a' * 129;
      expect(validator.isValidSpecId(longId), isFalse);
    });

    // isValidVersion: valid semver
    test('isValidVersion returns true for valid semver', () {
      expect(validator.isValidVersion('1.0.0'), isTrue);
      expect(validator.isValidVersion('0.1.0'), isTrue);
      expect(validator.isValidVersion('10.20.30'), isTrue);
    });

    // isValidVersion: semver with pre-release
    test('isValidVersion returns true for semver with pre-release', () {
      expect(validator.isValidVersion('1.0.0-alpha'), isTrue);
      expect(validator.isValidVersion('1.0.0-beta.1'), isTrue);
    });

    // isValidVersion: semver with build metadata
    test('isValidVersion returns true for semver with build metadata', () {
      expect(validator.isValidVersion('1.0.0+build.42'), isTrue);
    });

    // isValidVersion: invalid formats
    test('isValidVersion returns false for invalid formats', () {
      expect(validator.isValidVersion('abc'), isFalse);
      expect(validator.isValidVersion('1.0'), isFalse);
      expect(validator.isValidVersion('1'), isFalse);
      expect(validator.isValidVersion(''), isFalse);
      expect(validator.isValidVersion('v1.0.0'), isFalse);
    });

    // validateFunctionReferences: all functions exist
    test('validateFunctionReferences returns empty when all exist', () {
      final spec = _createSpec();
      final issues = validator.validateFunctionReferences(
        spec,
        ['descriptive_stats', 'anomaly_detect'],
      );
      expect(issues, isEmpty);
    });

    // validateFunctionReferences: some missing
    test('validateFunctionReferences reports missing functions', () {
      final spec = AnalysisSpec(
        specId: 'multi-step',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(function: 'descriptive_stats', parameters: {}),
          AnalysisStep(function: 'missing_function', parameters: {}),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Test'),
      );

      final issues = validator.validateFunctionReferences(
        spec,
        ['descriptive_stats'],
      );
      expect(issues, hasLength(1));
      expect(issues.first.code, 'spec.invalid.unknown_function');
      expect(issues.first.message, contains('missing_function'));
    });

    // validateFunctionReferences: empty catalog
    test('validateFunctionReferences with empty catalog reports all missing',
        () {
      final spec = _createSpec();
      final issues = validator.validateFunctionReferences(spec, []);
      expect(issues, hasLength(1));
      expect(issues.first.code, 'spec.invalid.unknown_function');
    });

    // validate with empty analysisSteps
    test('validate rejects spec with empty analysisSteps', () {
      final spec = AnalysisSpec(
        specId: 'no-steps',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'No steps'),
      );

      final issues = validator.validate(spec);
      expect(issues, isNotEmpty);
      expect(issues.any((i) => i.field == 'analysisSteps'), isTrue);
    });

    // validate with empty outputs
    test('validate rejects spec with empty outputs', () {
      final spec = AnalysisSpec(
        specId: 'no-outputs',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(function: 'fn', parameters: {}),
        ],
        outputs: [],
        metadata: const AnalysisSpecMetadata(description: 'No outputs'),
      );

      final issues = validator.validate(spec);
      expect(issues, isNotEmpty);
      expect(issues.any((i) => i.field == 'outputs'), isTrue);
    });

    // validate with empty function name in step
    test('validate rejects step with empty function name', () {
      final spec = AnalysisSpec(
        specId: 'empty-fn',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(function: '', parameters: {}),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Empty fn'),
      );

      final issues = validator.validate(spec);
      expect(
        issues.any((i) => i.code == 'spec.invalid.empty_function'),
        isTrue,
      );
    });

    // validate with empty transform name
    test('validate rejects transform with empty name', () {
      final spec = AnalysisSpec(
        specId: 'empty-transform',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(function: 'fn', parameters: {}),
        ],
        transforms: [
          AnalysisTransform(name: '', parameters: {}),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Empty transform'),
      );

      final issues = validator.validate(spec);
      expect(
        issues.any((i) => i.code == 'spec.invalid.empty_transform'),
        isTrue,
      );
    });

    // validate with multiple issues
    test('validate reports multiple issues at once', () {
      final spec = AnalysisSpec(
        specId: '', // bad
        version: 'xyz', // bad
        inputSources: [], // bad
        analysisSteps: [], // bad
        outputs: [], // bad
        metadata: const AnalysisSpecMetadata(description: 'Bad spec'),
      );

      final issues = validator.validate(spec);
      // specId, version, inputSources, analysisSteps, outputs
      expect(issues.length, greaterThanOrEqualTo(5));
    });
  });

  // ==========================================================================
  // SpecManager coverage boost
  // ==========================================================================
  group('SpecManager coverage boost', () {
    late InMemoryStorage<AnalysisSpec> storage;
    late SpecValidator validator;
    late ParameterResolver parameterResolver;
    late SpecManager manager;

    setUp(() {
      storage = InMemoryStorage<AnalysisSpec>();
      validator = SpecValidator();
      parameterResolver = ParameterResolver();
      manager = SpecManager(
        storage: storage,
        validator: validator,
        parameterResolver: parameterResolver,
      );
    });

    // listSpecs with search matching description
    test('listSpecs matches on description substring', () async {
      await manager.createSpec(
        _createSpec(specId: 'spec-a', description: 'Temperature analysis'),
      );
      await manager.createSpec(
        _createSpec(specId: 'spec-b', description: 'Humidity tracking'),
      );

      final results = await manager.listSpecs(search: 'humidity');
      expect(results, hasLength(1));
      expect(results.first.specId, 'spec-b');
    });

    // listSpecs with search that matches nothing
    test('listSpecs search with no match returns empty', () async {
      await manager.createSpec(_createSpec(specId: 'spec-a'));

      final results = await manager.listSpecs(search: 'nonexistent');
      expect(results, isEmpty);
    });

    // listSpecs with offset=0 (no effect)
    test('listSpecs with offset 0 returns all', () async {
      for (var i = 0; i < 3; i++) {
        await manager.createSpec(_createSpec(specId: 'spec-$i'));
      }

      final results = await manager.listSpecs(offset: 0);
      expect(results, hasLength(3));
    });

    // createSpec with invalid spec (validation failure)
    test('createSpec with invalid version throws spec.invalid', () async {
      final badSpec = AnalysisSpec(
        specId: 'valid-id',
        version: 'not-semver',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(function: 'fn', parameters: {}),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Bad version'),
      );

      expect(
        () => manager.createSpec(badSpec),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.invalid',
          ),
        ),
      );
    });

    // updateSpec with invalid spec
    test('updateSpec with invalid spec throws spec.invalid', () async {
      await manager.createSpec(_createSpec(specId: 'updatable'));

      final badUpdate = AnalysisSpec(
        specId: 'updatable',
        version: 'bad',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.factgraph,
            query: 'data',
          ),
        ],
        analysisSteps: [
          AnalysisStep(function: 'fn', parameters: {}),
        ],
        outputs: [
          AnalysisOutputDef(
            type: AnalysisArtifactType.metric,
            name: 'out',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'Bad update'),
      );

      expect(
        () => manager.updateSpec('updatable', badUpdate),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.invalid',
          ),
        ),
      );
    });

    // listSpecs case-insensitive search
    test('listSpecs search is case-insensitive', () async {
      await manager.createSpec(
        _createSpec(specId: 'MySpec', description: 'Temperature Analysis'),
      );

      final byId = await manager.listSpecs(search: 'myspec');
      expect(byId, hasLength(1));

      final byDesc = await manager.listSpecs(search: 'TEMPERATURE');
      expect(byDesc, hasLength(1));
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('Integration', () {
    late InMemoryStorage<AnalysisSpec> storage;
    late SpecValidator validator;
    late ParameterResolver parameterResolver;
    late SpecManager manager;

    setUp(() {
      storage = InMemoryStorage<AnalysisSpec>();
      validator = SpecValidator();
      parameterResolver = ParameterResolver();
      manager = SpecManager(
        storage: storage,
        validator: validator,
        parameterResolver: parameterResolver,
      );
    });

    // IT-001
    test('Create -> Get -> List round-trip', () async {
      final spec = _createSpec(specId: 'round-trip');

      // Create
      final created = await manager.createSpec(spec);
      expect(created.specId, 'round-trip');

      // Get
      final fetched = await manager.getSpec('round-trip');
      expect(fetched, isNotNull);
      expect(fetched!.specId, 'round-trip');
      expect(fetched.version, '1.0.0');

      // List
      final all = await manager.listSpecs();
      expect(all, hasLength(1));
      expect(all.first.specId, 'round-trip');
    });

    // IT-002
    test('Create v1.0 -> Update -> Get returns updated', () async {
      // Create v1.0.0
      await manager.createSpec(
        _createSpec(specId: 'versioned', version: '1.0.0'),
      );

      // Update to v2.0.0
      final updated = _createSpec(
        specId: 'versioned',
        version: '2.0.0',
        description: 'Version 2',
      );
      await manager.updateSpec('versioned', updated);

      // Get should return the updated spec
      final fetched = await manager.getSpec('versioned');
      expect(fetched, isNotNull);
      expect(fetched!.version, '2.0.0');
      expect(fetched.metadata.description, 'Version 2');
    });

    // IT-003
    test('Duplicate creation fails after first create', () async {
      await manager.createSpec(_createSpec(specId: 'once-only'));

      // Second creation with the same specId should fail
      expect(
        () => manager.createSpec(_createSpec(specId: 'once-only')),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'spec.duplicate',
          ),
        ),
      );

      // Original spec should remain intact
      final fetched = await manager.getSpec('once-only');
      expect(fetched, isNotNull);
      expect(fetched!.specId, 'once-only');
    });
  });
}
