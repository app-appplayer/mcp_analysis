import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Storage that survives the object holding it, and a spec version that
/// survives being edited.
///
/// Every store this package shipped was in memory, so a spec, a job, an
/// artifact and the audit trail lived exactly as long as the process — and
/// a spec was keyed by id alone, so editing it destroyed the version every
/// existing artifact's provenance pointed at.
class _MemoryKv implements KvStoragePort {
  final Map<String, dynamic> data = {};

  @override
  Future<void> set(String key, dynamic value) async => data[key] = value;

  @override
  Future<dynamic> get(String key) async => data[key];

  @override
  Future<void> remove(String key) async => data.remove(key);

  @override
  Future<bool> exists(String key) async => data.containsKey(key);

  @override
  Future<List<String>> keys({String? prefix}) async => data.keys
      .where((k) => prefix == null || prefix.isEmpty || k.startsWith(prefix))
      .toList();

  @override
  Future<void> clear() async => data.clear();
}

AnalysisSpec spec(String id, {String version = '1.0.0', String? note}) =>
    AnalysisSpec(
      specId: id,
      version: version,
      inputSources: [
        AnalysisInputSource(
          sourceType: AnalysisSourceType.synthetic,
          query: '{"samples":8,"sampleRate":8,"seed":1,'
              '"components":[{"kind":"sine","amplitude":1,"frequency":1}]}',
        ),
      ],
      analysisSteps: [
        AnalysisStep(
          id: 'stats',
          function: 'descriptive_stats',
          parameters: {
            'columns': ['value'],
          },
        ),
      ],
      outputs: [
        AnalysisOutputDef(
          from: 'stats',
          type: AnalysisArtifactType.summary,
          name: 'stats',
        ),
      ],
      metadata: AnalysisSpecMetadata(description: note ?? 'persisted'),
    );

void main() {
  group('KvBackedStorage', () {
    late _MemoryKv kv;
    KvBackedStorage<AnalysisSpec> store() => KvBackedStorage<AnalysisSpec>(
          kv: kv,
          namespace: 'spec',
          toJson: (s) => s.toJson(),
          fromJson: AnalysisSpec.fromJson,
        );

    setUp(() => kv = _MemoryKv());

    test('an item outlives the store object that wrote it', () async {
      await store().save('kept', spec('kept', note: 'written once'));

      // A different store instance over the same host storage — what a
      // restart looks like from the package's side.
      final reread = await store().get('kept');
      expect(reread, isNotNull);
      expect(reread!.specId, equals('kept'));
      expect(reread.metadata.description, equals('written once'));
    });

    test('namespaces do not collide', () async {
      final specs = store();
      final others = KvBackedStorage<AnalysisSpec>(
        kv: kv,
        namespace: 'draft',
        toJson: (s) => s.toJson(),
        fromJson: AnalysisSpec.fromJson,
      );
      await specs.save('x', spec('x'));
      await others.save('x', spec('x'));

      expect(await specs.getAll(), hasLength(1));
      expect(await others.getAll(), hasLength(1));
      expect(kv.data.keys, containsAll(['spec:x', 'draft:x']));
    });

    test('delete and exists reach the host storage', () async {
      final s = store();
      await s.save('gone', spec('gone'));
      expect(await s.exists('gone'), isTrue);
      await s.delete('gone');
      expect(await s.exists('gone'), isFalse);
      expect(await s.get('gone'), isNull);
    });

    test('a missing item is null, not a crash', () async {
      expect(await store().get('never-written'), isNull);
    });

    test(
        'query returns everything — criteria it cannot index are not '
        'silently dropped', () async {
      final s = store();
      await s.save('a', spec('a'));
      await s.save('b', spec('b'));
      expect(await s.query({'specId': 'a'}), hasLength(2),
          reason: 'a caller must apply what the storage cannot index; the '
              'store that pretended to filter returned other runs as this '
              "run's");
    });

    test('a value the host stored as something else is skipped, not thrown',
        () async {
      kv.data['spec:corrupt'] = 42;
      await store().save('ok', spec('ok'));
      final all = await store().getAll();
      expect(all.map((s) => s.specId), equals(['ok']));
    });

    test('a value already stored as a map decodes without re-parsing',
        () async {
      kv.data['spec:as-map'] = spec('as-map').toJson();
      expect((await store().get('as-map'))!.specId, equals('as-map'));
    });
  });

  group('spec versions', () {
    late AnalysisPortAdapter port;
    setUp(() => port = AnalysisPortAdapter.inMemory());

    test('an edited spec leaves its earlier version retrievable', () async {
      await port.createSpec(spec('evolving', note: 'first cut'));
      await port.updateSpec(
        'evolving',
        spec('evolving', version: '2.0.0', note: 'second cut'),
      );

      final current = await port.getSpec('evolving');
      expect(current!.version, equals('2.0.0'));

      final original = await port.getSpecVersion('evolving', '1.0.0');
      expect(original, isNotNull,
          reason: 'artifacts produced by 1.0.0 record that version in their '
              'provenance; without this the record they point at is gone');
      expect(original!.metadata.description, equals('first cut'));

      expect(
          await port.listSpecVersions('evolving'), equals(['1.0.0', '2.0.0']));
    });

    test('every version an edit passes through stays retrievable', () async {
      // Two successive edits: the middle version is the one only
      // archiving-on-update can keep, since create archived the first and
      // the store holds the last.
      await port.createSpec(spec('chain', note: 'v1'));
      await port.updateSpec(
        'chain',
        spec('chain', version: '2.0.0', note: 'v2'),
      );
      await port.updateSpec(
        'chain',
        spec('chain', version: '3.0.0', note: 'v3'),
      );

      expect(await port.listSpecVersions('chain'),
          equals(['1.0.0', '2.0.0', '3.0.0']));
      expect(
          (await port.getSpecVersion('chain', '2.0.0'))!.metadata.description,
          equals('v2'));
    });

    test('a version that never existed is null', () async {
      await port.createSpec(spec('single'));
      expect(await port.getSpecVersion('single', '9.9.9'), isNull);
    });

    test('an artifact can be traced back to the spec text that made it',
        () async {
      await port.createSpec(spec('traceable', note: 'as it ran'));
      final job = await port.runAnalysis(specId: 'traceable', parameters: {});
      await port.updateSpec(
        'traceable',
        spec('traceable', version: '2.0.0', note: 'edited afterwards'),
      );

      final artifact = (await port.getArtifacts(jobId: job.jobId)).single;
      final asItRan = await port.getSpecVersion(
        artifact.provenance.specId,
        artifact.provenance.specVersion,
      );
      expect(asItRan!.metadata.description, equals('as it ran'));
    });
  });
}
