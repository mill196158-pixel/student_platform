import 'package:sqflite/sqflite.dart';

/// Delegates the database API while making ordinary `close()` release the
/// associated process guard. Callers must finish all work before closing.
class GuardedDatabase implements Database {
  GuardedDatabase(this.inner, this.onClose, {this.retryClosed});
  final Database inner;
  final Future<void> Function() onClose;
  final bool Function()? retryClosed;
  Future<void>? _closing;

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    late final Future<void> operation;
    operation = onClose().catchError((Object error, StackTrace stack) {
      if ((inner.isOpen || (retryClosed?.call() ?? false)) && identical(_closing, operation)) _closing = null;
      Error.throwWithStackTrace(error, stack);
    });
    _closing = operation;
    return operation;
  }
  @override
  String get path => inner.path;
  @override
  bool get isOpen => inner.isOpen;
  @override
  Database get database => this;
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action, {bool? exclusive}) =>
      inner.transaction(action, exclusive: exclusive);
  @override
  Future<T> readTransaction<T>(Future<T> Function(Transaction) action) => inner.readTransaction(action);
  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) => inner.execute(sql, arguments);
  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) => inner.rawInsert(sql, arguments);
  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      inner.insert(table, values, nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct, List<String>? columns, String? where, List<Object?>? whereArgs,
      String? groupBy, String? having, String? orderBy, int? limit, int? offset}) =>
      inner.query(table, distinct: distinct, columns: columns, where: where,
          whereArgs: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy,
          limit: limit, offset: offset);
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) =>
      inner.rawQuery(sql, arguments);
  @override
  Future<QueryCursor> rawQueryCursor(String sql, List<Object?>? arguments, {int? bufferSize}) =>
      inner.rawQueryCursor(sql, arguments, bufferSize: bufferSize);
  @override
  Future<QueryCursor> queryCursor(String table,
      {bool? distinct, List<String>? columns, String? where, List<Object?>? whereArgs,
      String? groupBy, String? having, String? orderBy, int? limit, int? offset, int? bufferSize}) =>
      inner.queryCursor(table, distinct: distinct, columns: columns, where: where,
          whereArgs: whereArgs, groupBy: groupBy, having: having, orderBy: orderBy,
          limit: limit, offset: offset, bufferSize: bufferSize);
  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) => inner.rawUpdate(sql, arguments);
  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) =>
      inner.update(table, values, where: where, whereArgs: whereArgs, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) => inner.rawDelete(sql, arguments);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      inner.delete(table, where: where, whereArgs: whereArgs);
  @override
  Batch batch() => inner.batch();
  @override
  // The interface requires delegation of its development-only methods.
  // ignore: deprecated_member_use
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) => inner.devInvokeMethod<T>(method, arguments);
  @override
  Future<T> devInvokeSqlMethod<T>(String method, String sql, [List<Object?>? arguments]) =>
      // ignore: deprecated_member_use
      inner.devInvokeSqlMethod<T>(method, sql, arguments);
}
