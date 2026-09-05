import 'dart:io';

import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../helpers/mocks.dart';
import '../helpers/test_data.dart';

void main() {
  group('NFR-PORT-001: No ML Library Dependency', () {
    // TC-001: Core imports contain no ML libraries
    test('TC-001: core imports contain no ML libraries', () {
      final coreDir = Directory('lib/src/core');
      expect(coreDir.existsSync(), isTrue,
          reason: 'lib/src/core directory must exist');

      final mlPackages = [
        'ml_algo',
        'ml_linalg',
        'statistics',
        'dart_numerics',
        'ml_dataframe',
        'ml_preprocessing',
        'tensorflow',
        'onnxruntime',
      ];

      final coreFiles = coreDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final file in coreFiles) {
        final content = file.readAsStringSync();
        for (final pkg in mlPackages) {
          expect(
            content.contains("package:$pkg"),
            isFalse,
            reason: '${file.path} must not import ML library "$pkg"',
          );
        }
      }
    });

    // TC-002: All computation via AnalysisFunctionPort
    test('TC-002: all computation routed via AnalysisFunctionPort', () {
      // Verify built-in functions are in feat/function/builtin/
      final builtinDir = Directory('lib/src/feat/function/builtin');
      expect(builtinDir.existsSync(), isTrue,
          reason: 'Built-in function directory must exist');

      final builtinFiles = builtinDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(builtinFiles.length, greaterThanOrEqualTo(6),
          reason: 'At least 6 built-in functions expected');

      // Verify pubspec.yaml has no ML dependencies
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue);
      final pubspecContent = pubspec.readAsStringSync();
      final mlDeps = [
        'ml_algo',
        'ml_linalg',
        'statistics',
        'dart_numerics',
      ];
      for (final dep in mlDeps) {
        expect(
          pubspecContent.contains('$dep:'),
          isFalse,
          reason: 'pubspec.yaml must not depend on ML library "$dep"',
        );
      }

      // Verify core modules only call executeFunction (not direct algorithms)
      final coreDir = Directory('lib/src/core');
      final executionFiles = coreDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      for (final file in executionFiles) {
        final content = file.readAsStringSync();
        // Core should not import builtin function files directly
        expect(
          content.contains("import '../../feat/function/builtin/"),
          isFalse,
          reason: '${file.path} must not directly import built-in functions',
        );
      }
    });
  });

  group('NFR-PORT-002: Multi-Deployment Support', () {
    // TC-003: Core operates in server and local configurations
    test('TC-003: core operates with in-memory storage (local config)',
        () async {
      final specStorage = InMemoryStorage<AnalysisSpec>();
      final jobStorage = InMemoryStorage<AnalysisJob>();
      final artifactStorage = InMemoryStorage<AnalysisArtifact>();

      final specManager = SpecManager(
        storage: specStorage,
        validator: SpecValidator(),
        parameterResolver: ParameterResolver(),
      );

      final jobManager = JobManager(storage: jobStorage);
      final artifactStore = ArtifactStore(storage: artifactStorage);

      // Create and retrieve spec
      final spec = createTestSpec();
      final created = await specManager.createSpec(spec);
      expect(created.specId, spec.specId);

      final retrieved = await specManager.getSpec(spec.specId);
      expect(retrieved, isNotNull);
      expect(retrieved!.specId, spec.specId);

      // Create and retrieve job
      final job = await jobManager.createJob(
        specId: spec.specId,
        specVersion: spec.version,
        mode: AnalysisExecutionMode.batch,
      );
      expect(job.status, AnalysisJobStatus.queued);

      final retrievedJob = await jobManager.getJob(job.jobId);
      expect(retrievedJob, isNotNull);

      // Save and retrieve artifact
      final now = DateTime.now();
      final provenance = createTestProvenance();
      final artifact = AnalysisMetricArtifact(
        artifactId: 'artifact-001',
        name: 'test-metric',
        provenance: provenance,
        value: 42.0,
        unit: 'count',
        timeRange: AnalysisTimeRange(
          start: now.subtract(const Duration(hours: 1)),
          end: now,
        ),
      );
      await artifactStore.save(artifact);

      final retrievedArtifact = await artifactStore.get('artifact-001');
      expect(retrievedArtifact, isNotNull);
      expect(retrievedArtifact, isA<AnalysisMetricArtifact>());
    });
  });

  group('NFR-COMP-001: Backward Compatibility', () {
    // TC-004: v1.0 Spec executes on v1.x engine
    test('TC-004: v1.0 spec is accepted by current engine', () async {
      final specStorage = InMemoryStorage<AnalysisSpec>();
      final specManager = SpecManager(
        storage: specStorage,
        validator: SpecValidator(),
        parameterResolver: ParameterResolver(),
      );

      // Create spec with version 1.0.0
      final spec = createTestSpec(
        specId: 'compat-spec',
        version: '1.0.0',
      );
      final created = await specManager.createSpec(spec);
      expect(created.version, '1.0.0');

      // Verify it's retrievable and intact
      final retrieved = await specManager.getSpec('compat-spec');
      expect(retrieved, isNotNull);
      expect(retrieved!.version, '1.0.0');
      expect(retrieved.specId, 'compat-spec');
      expect(retrieved.inputSources, isNotEmpty);
      expect(retrieved.analysisSteps, isNotEmpty);
      expect(retrieved.outputs, isNotEmpty);
    });

    // TC-005: v1.0 artifacts queryable by v1.x ArtifactStore
    test('TC-005: v1.0 artifacts queryable by ArtifactStore', () async {
      final artifactStorage = InMemoryStorage<AnalysisArtifact>();
      final store = ArtifactStore(storage: artifactStorage);

      final provenance = AnalysisArtifactProvenance(
        version: '1.0.0',
        createdAt: DateTime.now(),
        specId: 'compat-spec',
        specVersion: '1.0.0',
        sourceUri: 'factgraph://test',
        sourceQuery: 'temperature',
      );

      // Create artifacts of different types
      final now = DateTime.now();
      final metric = AnalysisMetricArtifact(
        artifactId: 'a-metric-001',
        name: 'avg_temp',
        provenance: provenance,
        value: 72.5,
        unit: 'F',
        timeRange: AnalysisTimeRange(
          start: now.subtract(const Duration(hours: 1)),
          end: now,
        ),
      );
      final table = AnalysisTableArtifact(
        artifactId: 'a-table-001',
        name: 'raw_data',
        provenance: provenance,
        columns: ['temperature'],
        rows: [
          {'temperature': 72.5},
        ],
      );

      await store.save(metric);
      await store.save(table);

      // Query by artifactId
      final byId = await store.get('a-metric-001');
      expect(byId, isNotNull);
      expect(byId, isA<AnalysisMetricArtifact>());
      expect((byId as AnalysisMetricArtifact).value, 72.5);

      // Query by specId
      final bySpec = await store.query(specId: 'compat-spec');
      expect(bySpec.length, 2);

      // Query by type
      final byType = await store.query(type: AnalysisArtifactType.metric);
      expect(byType, isNotEmpty);

      // Verify all fields are accessible
      final tableResult = await store.get('a-table-001');
      expect(tableResult, isA<AnalysisTableArtifact>());
      final tableArtifact = tableResult as AnalysisTableArtifact;
      expect(tableArtifact.columns, isNotEmpty);
      expect(tableArtifact.rows, isNotEmpty);
      expect(tableArtifact.provenance.specVersion, '1.0.0');
    });
  });

  group('NFR-COMP-003: Dart SDK Compatibility', () {
    // TC-006: Package SDK constraint matches NFR-COMP-003
    test('TC-006: pubspec.yaml declares Dart SDK ^3.0.0', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue);

      final content = pubspec.readAsStringSync();
      // Verify the SDK constraint exists and targets 3.x
      expect(content.contains('sdk:'), isTrue,
          reason: 'pubspec.yaml must declare SDK constraint');
      expect(
        RegExp(r'sdk:\s*[\^>=]*3\.0\.0').hasMatch(content),
        isTrue,
        reason: 'SDK constraint must target ^3.0.0',
      );
    });
  });

  group('NFR-COMP-004: mcp_bundle Dependency', () {
    // TC-007: All port contracts resolved from mcp_bundle
    test('TC-007: all port contracts resolved from mcp_bundle', () {
      final pubspec = File('pubspec.yaml');
      expect(pubspec.existsSync(), isTrue);

      final content = pubspec.readAsStringSync();
      // Verify mcp_bundle dependency exists
      expect(content.contains('mcp_bundle:'), isTrue,
          reason: 'pubspec.yaml must declare mcp_bundle dependency');

      // Verify port types are imported from mcp_bundle (not locally defined)
      // by checking barrel export file
      final barrel = File('lib/mcp_analysis.dart');
      expect(barrel.existsSync(), isTrue);
      final barrelContent = barrel.readAsStringSync();

      // Barrel should NOT re-export port types from local files
      expect(
        barrelContent.contains("export 'src/core/analysis_port.dart'"),
        isFalse,
        reason: 'AnalysisPort should come from mcp_bundle, not local file',
      );

      // Verify that AnalysisPortAdapter implements AnalysisPort from mcp_bundle
      final adapterFile = File('lib/src/core/analysis_port_adapter.dart');
      expect(adapterFile.existsSync(), isTrue);
      final adapterContent = adapterFile.readAsStringSync();
      expect(
        adapterContent.contains("import 'package:mcp_bundle/ports.dart'"),
        isTrue,
        reason: 'AnalysisPortAdapter must import from mcp_bundle',
      );
      expect(
        adapterContent.contains('implements AnalysisPort'),
        isTrue,
        reason:
            'AnalysisPortAdapter must implement AnalysisPort from mcp_bundle',
      );
    });
  });
}
