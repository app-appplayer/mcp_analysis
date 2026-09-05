import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';
import 'package:test/test.dart';

/// Two sources, and what "more than one source" means.
///
/// Merging used to be one thing: columns union, rows concatenate. Two
/// channels both naming their column `value` collapsed into one column
/// with twice the rows, so every function that compares two columns
/// — `correlation_regression`, `cross_psd`, `cross_correlation`, `pca`,
/// `covariance_matrix` — had nothing to compare. The catalog advertised
/// capabilities the input model could not reach.
void main() {
  mergeEdgeTests();
  const merger = SourceMerger();

  AnalysisDataSet channel(String column, List<double> values, {int step = 1}) {
    final rows = <Map<String, dynamic>>[
      for (var i = 0; i < values.length; i++)
        {
          '_timestamp': DateTime.utc(2026).add(Duration(seconds: i * step)),
          column: values[i],
        },
    ];
    return AnalysisDataSet(
      columns: [
        const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        AnalysisColumnInfo(name: column, type: 'double'),
      ],
      rows: rows,
      rowCount: rows.length,
    );
  }

  AnalysisInputSource source({
    Map<String, String>? aliases,
    AnalysisSourceMerge merge = AnalysisSourceMerge.append,
  }) =>
      AnalysisInputSource(
        sourceType: AnalysisSourceType.synthetic,
        query: '{}',
        columnAliases: aliases,
        merge: merge,
      );

  group('aliases', () {
    test('rename a source\'s columns and its row keys', () {
      final aliased = merger.applyAliases(
        source(aliases: const {'value': 'sensor_b'}),
        channel('value', [1, 2, 3]),
      );

      expect(aliased.columns.map((c) => c.name), contains('sensor_b'));
      expect(aliased.columns.map((c) => c.name), isNot(contains('value')));
      expect(aliased.rows.first['sensor_b'], equals(1.0));
      expect(aliased.rows.first.containsKey('value'), isFalse);
    });

    test('a source with no aliases is untouched', () {
      final data = channel('value', [1, 2]);
      expect(identical(merger.applyAliases(source(), data), data), isTrue);
    });
  });

  group('append', () {
    test('stacks rows and keeps timestamp order', () {
      final merged = merger.merge(
        [source(), source()],
        [
          channel('value', [1, 2]),
          channel('value', [3, 4]),
        ],
      );

      expect(merged.rowCount, equals(4), reason: 'rows stack');
      expect(
          merged.columns.map((c) => c.name), equals(['_timestamp', 'value']));
      final ts = merged.rows.map((r) => r['_timestamp'] as DateTime).toList();
      expect(ts, orderedEquals(List.of(ts)..sort()));
    });
  });

  group('join', () {
    test('aligns a second channel onto the first as a column', () {
      final merged = merger.merge(
        [
          source(),
          source(
            aliases: const {'value': 'sensor_b'},
            merge: AnalysisSourceMerge.join,
          ),
        ],
        [
          channel('value', [1, 2, 3]),
          merger.applyAliases(
            source(aliases: const {'value': 'sensor_b'}),
            channel('value', [10, 20, 30]),
          ),
        ],
      );

      expect(merged.rowCount, equals(3), reason: 'columns join, rows do not');
      expect(merged.columns.map((c) => c.name),
          equals(['_timestamp', 'value', 'sensor_b']));
      for (final row in merged.rows) {
        expect(row['value'], isNotNull);
        expect(row['sensor_b'], isNotNull,
            reason: 'an aligned row carries both channels; an appended one '
                'would hold one and a null');
      }
      expect(merged.rows.map((r) => r['sensor_b']), equals([10.0, 20.0, 30.0]));
    });

    test('matches on the nearest timestamp, not on position', () {
      // Right channel sampled half as often: rows 0, 2, 4 of the left.
      final merged = merger.merge(
        [source(), source(merge: AnalysisSourceMerge.join)],
        [
          channel('value', [1, 2, 3, 4, 5]),
          channel('slow', [10, 20, 30], step: 2),
        ],
      );

      expect(merged.rows.map((r) => r['slow']),
          equals([10.0, 10.0, 20.0, 20.0, 30.0]));
    });

    test('two channels sharing a column name are refused, not collapsed', () {
      expect(
        () => merger.merge(
          [source(), source(merge: AnalysisSourceMerge.join)],
          [
            channel('value', [1, 2]),
            channel('value', [3, 4]),
          ],
        ),
        throwsA(isA<AnalysisError>()
            .having((e) => e.code, 'code', 'source.column_collision')),
      );
    });
  });

  test('two channels reach a function that compares two columns', () async {
    final port = AnalysisPortAdapter.inMemory();
    const tone = '{"samples":64,"sampleRate":32,"seed":%d,"components":['
        '{"kind":"sine","amplitude":1,"frequency":4}]}';

    await port.createSpec(
      AnalysisSpec(
        specId: 'two-channel',
        version: '1.0.0',
        inputSources: [
          AnalysisInputSource(
            sourceType: AnalysisSourceType.synthetic,
            query: tone.replaceFirst('%d', '1'),
            columnAliases: const {'value': 'channel_a'},
          ),
          AnalysisInputSource(
            sourceType: AnalysisSourceType.synthetic,
            query: tone.replaceFirst('%d', '2'),
            columnAliases: const {'value': 'channel_b'},
            merge: AnalysisSourceMerge.join,
          ),
        ],
        analysisSteps: [
          AnalysisStep(
            id: 'xcorr',
            function: 'cross_correlation',
            parameters: {
              'columns': ['channel_a', 'channel_b'],
              'maxLag': 8,
            },
          ),
        ],
        outputs: [
          AnalysisOutputDef(
            from: 'xcorr',
            field: 'correlations',
            indexField: 'lags',
            type: AnalysisArtifactType.series,
            name: 'cross_correlation',
          ),
        ],
        metadata: const AnalysisSpecMetadata(description: 'two channels'),
      ),
    );

    final job = await port.runAnalysis(specId: 'two-channel', parameters: {});
    final fresh = await port.getJob(job.jobId);
    expect(fresh?.status, equals(AnalysisJobStatus.completed),
        reason: 'errors: ${fresh?.errors.map((e) => e.toString()).toList()}');

    final artifacts = await port.getArtifacts(jobId: job.jobId);
    final series = artifacts.single as AnalysisSeriesArtifact;
    expect(series.points, isNotEmpty,
        reason: 'a cross-correlation over two appended channels would have '
            'had one column of nulls to work with');
  });
}

/// Edges of the merge that the main cases do not reach.
void mergeEdgeTests() {
  const merger = SourceMerger();

  AnalysisInputSource src({
    AnalysisSourceMerge merge = AnalysisSourceMerge.append,
  }) =>
      AnalysisInputSource(
        sourceType: AnalysisSourceType.synthetic,
        query: '{}',
        merge: merge,
      );

  AnalysisDataSet untimed(String column, List<double> values) {
    final rows = [
      for (final v in values) <String, dynamic>{column: v},
    ];
    return AnalysisDataSet(
      columns: [AnalysisColumnInfo(name: column, type: 'double')],
      rows: rows,
      rowCount: rows.length,
    );
  }

  AnalysisDataSet timed(String column, List<double> values) {
    final rows = [
      for (var i = 0; i < values.length; i++)
        <String, dynamic>{
          '_timestamp': DateTime.utc(2026).add(Duration(seconds: i)),
          column: values[i],
        },
    ];
    return AnalysisDataSet(
      columns: [
        const AnalysisColumnInfo(name: '_timestamp', type: 'datetime'),
        AnalysisColumnInfo(name: column, type: 'double'),
      ],
      rows: rows,
      rowCount: rows.length,
    );
  }

  group('merge edges', () {
    test('no sources at all is an empty dataset, not a crash', () {
      final merged = merger.merge(const [], const []);
      expect(merged.rowCount, isZero);
      expect(merged.columns, isEmpty);
    });

    test('one source is returned untouched', () {
      final only = timed('value', [1, 2]);
      expect(identical(merger.merge([src()], [only]), only), isTrue);
    });

    test('a join with no timestamps falls back to position', () {
      final merged = merger.merge(
        [src(), src(merge: AnalysisSourceMerge.join)],
        [
          untimed('a', [1, 2, 3]),
          untimed('b', [10, 20, 30])
        ],
      );
      expect(merged.rowCount, equals(3));
      expect(merged.rows.map((r) => r['b']), equals([10.0, 20.0, 30.0]));
    });

    test('a join with fewer rows on the right leaves the tail null', () {
      final merged = merger.merge(
        [src(), src(merge: AnalysisSourceMerge.join)],
        [
          untimed('a', [1, 2, 3]),
          untimed('b', [10])
        ],
      );
      expect(merged.rows.map((r) => r['b']), equals([10.0, null, null]));
    });

    test('appending rows that carry no timestamp keeps them all', () {
      final merged = merger.merge(
        [src(), src()],
        [
          timed('value', [1, 2]),
          untimed('value', [3])
        ],
      );
      expect(merged.rowCount, equals(3));
      // Timestamped rows sort ahead of untimed ones; none are dropped.
      expect(
        merged.rows.map((r) => r['value']).toSet(),
        equals({1.0, 2.0, 3.0}),
      );
    });

    test('a source beyond the declared list appends by default', () {
      final merged = merger.merge(
        [src()],
        [
          timed('value', [1]),
          timed('value', [2])
        ],
      );
      expect(merged.rowCount, equals(2));
    });
  });
}
