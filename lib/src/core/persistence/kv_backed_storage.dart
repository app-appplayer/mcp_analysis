import 'dart:convert';

import 'package:mcp_bundle/ports.dart';

/// A [StoragePort] that keeps its items in a host's [KvStoragePort].
///
/// Every store this package shipped was in memory, so a spec, a job, an
/// artifact and the audit trail all lived exactly as long as the process.
/// Provenance recorded which spec and which run produced a number, and
/// then the record it pointed at was gone — reproducibility and audit both
/// ended at a restart.
///
/// The host supplies the actual storage. This package stays pure Dart on
/// every platform it declares; a filesystem store here would take web and
/// wasm away, which is the same mistake that costs the dependency chain
/// its wasm score.
class KvBackedStorage<T> implements StoragePort<T> {
  /// Items are keyed `<namespace>:<id>` so one store can hold several
  /// kinds without a key of one colliding with a key of another.
  KvBackedStorage({
    required KvStoragePort kv,
    required String namespace,
    required Map<String, dynamic> Function(T item) toJson,
    required T Function(Map<String, dynamic> json) fromJson,
  })  : _kv = kv,
        _namespace = namespace,
        _toJson = toJson,
        _fromJson = fromJson;

  final KvStoragePort _kv;
  final String _namespace;
  final Map<String, dynamic> Function(T) _toJson;
  final T Function(Map<String, dynamic>) _fromJson;

  String _key(String id) => '$_namespace:$id';

  @override
  Future<void> save(String id, T item) async {
    await _kv.set(_key(id), jsonEncode(_toJson(item)));
  }

  @override
  Future<T?> get(String id) async => _decode(await _kv.get(_key(id)));

  @override
  Future<void> delete(String id) => _kv.remove(_key(id));

  @override
  Future<bool> exists(String id) => _kv.exists(_key(id));

  @override
  Future<List<T>> getAll() async {
    final keys = await _kv.keys(prefix: '$_namespace:');
    final items = <T>[];
    for (final key in keys) {
      final item = _decode(await _kv.get(key));
      if (item != null) items.add(item);
    }
    return items;
  }

  /// Criteria this store cannot index are not silently dropped — it
  /// returns everything and leaves filtering to the caller, which is what
  /// a caller must assume of any storage.
  @override
  Future<List<T>> query(Map<String, dynamic> criteria) => getAll();

  T? _decode(dynamic raw) {
    if (raw == null) return null;
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) return null;
    return _fromJson(Map<String, dynamic>.from(decoded));
  }
}
