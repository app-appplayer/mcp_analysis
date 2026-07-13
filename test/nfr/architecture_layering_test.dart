import 'dart:io';

import 'package:test/test.dart';

/// Architecture invariants of the 2026-07-14 layering decision — ONE
/// package, three internal layers with a one-way dependency direction:
///
///   contract (core/spec · core/artifact)  ←  compute (feat/function ·
///   feat/transform)  ←  domain-1군 (feat/domain)
///
/// plus the package-wide purity rules the tree-shaking argument rests on.
/// These are compile-level locks, not documentation.
void main() {
  List<File> dartFilesUnder(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  group('layer direction (contract ← compute ← domain)', () {
    test('contract layer (core/spec, core/artifact) imports no feat/', () {
      for (final f in [
        ...dartFilesUnder('lib/src/core/spec'),
        ...dartFilesUnder('lib/src/core/artifact'),
      ]) {
        final src = f.readAsStringSync();
        expect(src.contains(RegExp(r"import\s+'[^']*feat/")), isFalse,
            reason: '${f.path} must not depend on the compute/domain layers');
      }
    });

    test('compute layer (feat/function, feat/transform) imports no domain',
        () {
      for (final f in [
        ...dartFilesUnder('lib/src/feat/function'),
        ...dartFilesUnder('lib/src/feat/transform'),
      ]) {
        final src = f.readAsStringSync();
        expect(src.contains(RegExp(r"import\s+'[^']*feat/domain")), isFalse,
            reason: '${f.path}: compute must not depend on domain-1군 '
                '(dependency direction is domain → compute)');
      }
    });

    test('domain-1군 reaches only compute helpers and ports', () {
      for (final f in dartFilesUnder('lib/src/feat/domain')) {
        final src = f.readAsStringSync();
        final imports = RegExp(r"import\s+'([^']+)'")
            .allMatches(src)
            .map((m) => m.group(1)!)
            .toList();
        for (final imp in imports) {
          final allowed = imp.startsWith('dart:math') ||
              imp.startsWith('package:mcp_bundle/') ||
              imp.contains('feat/function/') ||
              imp.startsWith('../function/');
          expect(allowed, isTrue,
              reason: '${f.path} imports "$imp" — domain-1군 may use only '
                  'ports and the compute layer');
        }
      }
    });
  });

  group('package purity (the tree-shaking / 1군 rules)', () {
    test('no FFI, no Flutter, no dart:ui anywhere in lib/', () {
      for (final f in dartFilesUnder('lib')) {
        final src = f.readAsStringSync();
        expect(
            src.contains(RegExp(
                r"import\s+'(dart:ffi|dart:ui|package:flutter)")),
            isFalse,
            reason: '${f.path} pulls a platform/FFI dependency — that is '
                '2군 territory (external pack)');
      }
    });

    test('runtime dependencies stay the frozen minimal set', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final depsSection = pubspec.split('dependencies:')[1].split('dev_dependencies:')[0];
      final deps = RegExp(r'^\s{2}(\w+):', multiLine: true)
          .allMatches(depsSection)
          .map((m) => m.group(1)!)
          .toSet();
      expect(deps, {'mcp_bundle', 'collection', 'meta'},
          reason: 'adding a runtime dependency breaks the 1군 embedding '
              'argument (pub resolves deps even when code is tree-shaken) — '
              'dependency-carrying features are 2군 external packs');
    });
  });
}
