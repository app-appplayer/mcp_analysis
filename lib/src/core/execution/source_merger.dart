import 'package:mcp_bundle/ports.dart';

/// Combines the datasets read from a spec's input sources.
///
/// Two shapes of "more than one source" want opposite things. More of the
/// same reading — another day of one sensor — wants rows appended. A
/// second channel measured alongside the first wants columns aligned.
/// Appending a second channel leaves every row half empty, and the
/// functions that compare two columns then read a column that is mostly
/// null, so the mode is declared per source rather than guessed.
class SourceMerger {
  const SourceMerger();

  /// Name of the column merges align and sort on.
  static const String timestampColumn = '_timestamp';

  /// Apply a source's [AnalysisInputSource.columnAliases] to what it
  /// returned, so each source can carry a name of its own.
  AnalysisDataSet applyAliases(
    AnalysisInputSource source,
    AnalysisDataSet dataSet,
  ) {
    final aliases = source.columnAliases;
    if (aliases == null || aliases.isEmpty) return dataSet;

    String rename(String name) => aliases[name] ?? name;

    return AnalysisDataSet(
      columns: [
        for (final c in dataSet.columns)
          AnalysisColumnInfo(name: rename(c.name), type: c.type),
      ],
      rows: [
        for (final row in dataSet.rows)
          <String, dynamic>{
            for (final e in row.entries) rename(e.key): e.value,
          },
      ],
      rowCount: dataSet.rowCount,
      metadata: dataSet.metadata,
    );
  }

  /// Merge [dataSets], read in the order of [sources].
  ///
  /// The first source is the base; each later one is appended or aligned
  /// onto it according to its own [AnalysisInputSource.merge].
  AnalysisDataSet merge(
    List<AnalysisInputSource> sources,
    List<AnalysisDataSet> dataSets,
  ) {
    if (dataSets.isEmpty) {
      return AnalysisDataSet(columns: const [], rows: const [], rowCount: 0);
    }
    if (dataSets.length == 1) return dataSets.first;

    var merged = dataSets.first;
    var appended = 1;
    for (var i = 1; i < dataSets.length; i++) {
      final mode =
          i < sources.length ? sources[i].merge : AnalysisSourceMerge.append;
      if (mode == AnalysisSourceMerge.join) {
        merged = _align(merged, dataSets[i], i);
      } else {
        merged = _append(merged, dataSets[i]);
        appended++;
      }
    }

    return AnalysisDataSet(
      columns: merged.columns,
      rows: merged.rows,
      rowCount: merged.rows.length,
      metadata: {
        'mergedSourceCount': dataSets.length,
        'appendedSourceCount': appended,
      },
    );
  }

  /// Column union, rows concatenated with null fill, sorted by timestamp —
  /// the behaviour every merge had before the mode existed.
  AnalysisDataSet _append(AnalysisDataSet left, AnalysisDataSet right) {
    final columnMap = <String, AnalysisColumnInfo>{};
    for (final ds in [left, right]) {
      for (final col in ds.columns) {
        columnMap.putIfAbsent(col.name, () => col);
      }
    }
    final names = columnMap.keys.toSet();

    final rows = <Map<String, dynamic>>[];
    for (final ds in [left, right]) {
      for (final row in ds.rows) {
        rows.add(<String, dynamic>{
          for (final name in names) name: row[name],
        });
      }
    }
    _sortByTimestamp(rows);

    return AnalysisDataSet(
      columns: columnMap.values.toList(),
      rows: rows,
      rowCount: rows.length,
    );
  }

  /// Carry [right]'s columns onto [left]'s rows, matched on the nearest
  /// timestamp — by position when either side has no usable timestamp.
  AnalysisDataSet _align(
    AnalysisDataSet left,
    AnalysisDataSet right,
    int sourceIndex,
  ) {
    final existing = {for (final c in left.columns) c.name};
    final incoming = [
      for (final c in right.columns)
        if (c.name != timestampColumn) c,
    ];

    final collisions = [
      for (final c in incoming)
        if (existing.contains(c.name)) c.name,
    ];
    if (collisions.isNotEmpty) {
      throw AnalysisError(
        code: 'source.column_collision',
        message: 'inputSources[$sourceIndex] joins on column(s) '
            '${collisions.join(", ")}, which the merged data already has. '
            'Two channels cannot share a column name — set columnAliases on '
            'one of the sources.',
        details: {'sourceIndex': sourceIndex, 'columns': collisions},
      );
    }

    final rightTimestamped = <(DateTime, Map<String, dynamic>)>[
      for (final row in right.rows)
        if (row[timestampColumn] is DateTime)
          (row[timestampColumn] as DateTime, row),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < left.rows.length; i++) {
      final leftRow = left.rows[i];
      Map<String, dynamic>? match;
      final leftTs = leftRow[timestampColumn];
      if (leftTs is DateTime && rightTimestamped.isNotEmpty) {
        match = _nearest(rightTimestamped, leftTs);
      } else if (i < right.rows.length) {
        match = right.rows[i];
      }
      rows.add(<String, dynamic>{
        ...leftRow,
        for (final c in incoming) c.name: match?[c.name],
      });
    }

    return AnalysisDataSet(
      columns: [...left.columns, ...incoming],
      rows: rows,
      rowCount: rows.length,
    );
  }

  Map<String, dynamic> _nearest(
    List<(DateTime, Map<String, dynamic>)> sorted,
    DateTime target,
  ) {
    var best = sorted.first;
    var bestGap = (best.$1.difference(target)).abs();
    for (final candidate in sorted.skip(1)) {
      final gap = (candidate.$1.difference(target)).abs();
      if (gap >= bestGap) continue;
      best = candidate;
      bestGap = gap;
    }
    return best.$2;
  }

  void _sortByTimestamp(List<Map<String, dynamic>> rows) {
    rows.sort((a, b) {
      final aTs = a[timestampColumn];
      final bTs = b[timestampColumn];
      if (aTs is DateTime && bTs is DateTime) return aTs.compareTo(bTs);
      if (aTs is DateTime) return -1;
      if (bTs is DateTime) return 1;
      return 0;
    });
  }
}
