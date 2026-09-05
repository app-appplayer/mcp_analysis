import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

// ============================================================================
// Helpers
// ============================================================================

AnalysisSpec _createTestSpec({
  String specId = 'test-spec',
  String version = '1.0.0',
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
          'columns': ['temp']
        },
      ),
    ],
    outputs: [
      AnalysisOutputDef(
        from: 'descriptive_stats',
        type: AnalysisArtifactType.metric,
        name: 'stats',
      ),
    ],
    metadata: const AnalysisSpecMetadata(description: 'Test'),
  );
}

// ============================================================================
// Tests
//
// TC mapping to infra-mcp spec (TC-017..TC-024):
//   RBAC TC-001..TC-005 → spec TC-017..TC-019 (RBAC boundary tests)
//   Audit TC-006..TC-008 → spec TC-023..TC-024 (audit logging at MCP boundary)
//   Masking TC-009..TC-010 → spec TC-020 (DataMasker integration)
// ============================================================================

void main() {
  // ==========================================================================
  // RBAC at MCP Boundary (spec TC-017..TC-019)
  // ==========================================================================
  group('McpToolHandler RBAC', () {
    late MockAnalysisPort mockPort;
    late InMemoryStorage<AuditRecord> auditStorage;
    late McpToolHandler handler;

    setUp(() {
      mockPort = MockAnalysisPort(
        specs: [_createTestSpec()],
        artifacts: [],
      );
      auditStorage = InMemoryStorage<AuditRecord>();
      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: AuditLogger(storage: auditStorage),
        dataMasker: DataMasker(),
      );
    });

    // TC-001: Operator can list specs
    test('TC-001: operator can list specs via RBAC', () async {
      const ctx = RbacContext(actorId: 'op-1', role: 'operator');

      final result = await handler.handleTool(
        'analysis.list_specs',
        {},
        rbacContext: ctx,
      );

      expect(result, containsPair('specs', isA<List<dynamic>>()));
    });

    // TC-002: Operator cannot create specs
    test('TC-002: operator cannot create specs (unauthorized)', () async {
      const ctx = RbacContext(actorId: 'op-1', role: 'operator');
      final newSpec = _createTestSpec(specId: 'new-spec');

      final result = await handler.handleTool(
        'analysis.create_spec',
        {'spec': newSpec.toJson()},
        rbacContext: ctx,
      );

      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'governance.unauthorized');
    });

    // TC-003: Engineer can create specs
    test('TC-003: engineer can create specs', () async {
      const ctx = RbacContext(actorId: 'eng-1', role: 'engineer');
      final newSpec = _createTestSpec(specId: 'eng-spec');

      final result = await handler.handleTool(
        'analysis.create_spec',
        {'spec': newSpec.toJson()},
        rbacContext: ctx,
      );

      expect(result, containsPair('specId', 'eng-spec'));
    });

    // TC-004: Group-based role elevation (operator in admins group)
    test('TC-004: operator in admins group gets elevated to admin', () async {
      const ctx = RbacContext(
        actorId: 'op-elevated',
        role: 'operator',
        groups: ['admins'],
      );
      final newSpec = _createTestSpec(specId: 'elevated-spec');

      // Operator alone cannot create spec, but with admins group they can
      final result = await handler.handleTool(
        'analysis.create_spec',
        {'spec': newSpec.toJson()},
        rbacContext: ctx,
      );

      expect(result, containsPair('specId', 'elevated-spec'));
    });

    // TC-005: Unknown role is denied
    test('TC-005: unknown role is denied', () async {
      const ctx = RbacContext(actorId: 'guest', role: 'viewer');

      final result = await handler.handleTool(
        'analysis.list_specs',
        {},
        rbacContext: ctx,
      );

      expect(result, containsPair('error', isA<Map<dynamic, dynamic>>()));
      final error = result['error'] as Map<String, dynamic>;
      expect(error['code'], 'governance.unauthorized');
    });
  });

  // ==========================================================================
  // Audit Logging at MCP Boundary
  // ==========================================================================
  group('McpToolHandler Audit', () {
    late MockAnalysisPort mockPort;
    late InMemoryStorage<AuditRecord> auditStorage;
    late McpToolHandler handler;

    setUp(() {
      mockPort = MockAnalysisPort(
        specs: [_createTestSpec()],
        artifacts: [],
      );
      auditStorage = InMemoryStorage<AuditRecord>();
      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: AuditLogger(storage: auditStorage),
        dataMasker: DataMasker(),
      );
    });

    // TC-006: Run tool records audit log
    test('TC-006: analysis.run records audit log', () async {
      const ctx = RbacContext(actorId: 'eng-1', role: 'engineer');

      await handler.handleTool(
        'analysis.run',
        {'specId': 'test-spec', 'parameters': <String, dynamic>{}},
        rbacContext: ctx,
      );

      final audits = await auditStorage.getAll();
      expect(audits, isNotEmpty);
      expect(audits.any((a) => a.action == 'execute'), isTrue);
      expect(audits.any((a) => a.actorId == 'eng-1'), isTrue);
    });

    // TC-007: Create spec records audit log
    test('TC-007: create_spec records audit log', () async {
      const ctx = RbacContext(actorId: 'eng-1', role: 'engineer');
      final spec = _createTestSpec(specId: 'audit-spec');

      await handler.handleTool(
        'analysis.create_spec',
        {'spec': spec.toJson()},
        rbacContext: ctx,
      );

      final audits = await auditStorage.getAll();
      expect(audits, isNotEmpty);
      expect(audits.any((a) => a.action == 'create_spec'), isTrue);
    });

    // TC-008: Update spec records audit log
    test('TC-008: update_spec records audit log', () async {
      const ctx = RbacContext(actorId: 'eng-1', role: 'engineer');
      final spec = _createTestSpec(specId: 'test-spec', version: '2.0.0');

      await handler.handleTool(
        'analysis.update_spec',
        {'specId': 'test-spec', 'spec': spec.toJson()},
        rbacContext: ctx,
      );

      final audits = await auditStorage.getAll();
      expect(audits, isNotEmpty);
      expect(audits.any((a) => a.action == 'update_spec'), isTrue);
    });
  });

  // ==========================================================================
  // Data Masking at MCP Boundary
  // ==========================================================================
  group('McpToolHandler Data Masking', () {
    late MockAnalysisPort mockPort;
    late McpToolHandler handler;

    setUp(() {
      final now = DateTime.now();
      final tableArtifact = AnalysisTableArtifact(
        artifactId: 'table-001',
        name: 'sensitive-table',
        provenance: AnalysisArtifactProvenance(
          version: '1.0.0',
          createdAt: now,
          specId: 'test-spec',
          specVersion: '1.0.0',
        ),
        columns: const ['name', 'ssn', 'score'],
        rows: [
          {'name': 'Alice', 'ssn': '123-45-6789', 'score': 95.0},
          {'name': 'Bob', 'ssn': '987-65-4321', 'score': 88.0},
        ],
      );

      mockPort = MockAnalysisPort(
        specs: [_createTestSpec()],
        artifacts: [tableArtifact],
      );

      handler = McpToolHandler(
        analysisPort: mockPort,
        rbac: RbacPolicy(),
        auditLogger: AuditLogger(storage: InMemoryStorage<AuditRecord>()),
        dataMasker: DataMasker(),
      );
    });

    // TC-009: Data masking masks specified columns
    test('TC-009: maskConfig masks specified columns', () async {
      final result = await handler.handleTool(
        'analysis.get_artifacts',
        {
          'maskConfig': {'ssn': true},
        },
      );

      expect(result, containsPair('artifacts', isA<List<dynamic>>()));
      final artifacts = result['artifacts'] as List;
      expect(artifacts, isNotEmpty);

      final artifact = artifacts.first as Map<String, dynamic>;
      if (artifact.containsKey('rows')) {
        final rows = artifact['rows'] as List;
        for (final row in rows) {
          final r = row as Map<String, dynamic>;
          expect(r['ssn'], DataMasker.maskedValue);
          // Non-masked columns should be preserved
          expect(r['name'], isNot(DataMasker.maskedValue));
        }
      }
    });

    // TC-010: No maskConfig returns unmasked data
    test('TC-010: no maskConfig returns unmasked data', () async {
      final result = await handler.handleTool(
        'analysis.get_artifacts',
        {},
      );

      final artifacts = result['artifacts'] as List;
      expect(artifacts, isNotEmpty);

      final artifact = artifacts.first as Map<String, dynamic>;
      if (artifact.containsKey('rows')) {
        final rows = artifact['rows'] as List;
        final firstRow = rows.first as Map<String, dynamic>;
        expect(firstRow['ssn'], isNot(DataMasker.maskedValue));
      }
    });
  });
}
