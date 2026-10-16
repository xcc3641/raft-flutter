import 'package:drift/drift.dart';

import '../data/history_gaps.dart';
import '../data/message_history.dart';
import 'message_history.dart' show HistoryOperationOrder;

/// Checks open intervals between saved rows with bounded indexed seeks.
class SqliteHistoryGaps extends HistoryGapQueries {
  SqliteHistoryGaps(
    this.db,
    this.order, {
    required this.ready,
    required this.allowed,
  });
  final GeneratedDatabase db;
  final HistoryOperationOrder order;
  final Future<void> Function() ready;
  final Future<bool> Function(MessageHistoryScope) allowed;
  final _versions = <(String, String, String, String), int>{};
  int _epoch = 0;
  bool _closed = false;
  (String, String, String, String) key(MessageHistoryScope scope) =>
      (scope.origin, scope.principal, scope.server, scope.channel);
  @override
  Object revision(MessageHistoryScope scope) =>
      (_epoch, _versions[key(scope)] ?? 0);
  void changed(MessageHistoryScope? scope) {
    if (_closed) return;
    if (scope == null) {
      _epoch++;
    } else {
      _versions.update(key(scope), (value) => value + 1, ifAbsent: () => 1);
    }
    notifyListeners();
  }

  void forgetAccount(String origin, String principal) {
    _versions.removeWhere((key, _) => key.$1 == origin && key.$2 == principal);
    changed(null);
  }

  @override
  Future<List<HistoryGap>> read(
    MessageHistoryScope scope,
    List<(String, BigInt)> visible,
  ) async {
    if (_closed || visible.length < 2) return const [];
    final result = <HistoryGap>[];
    // Five values per pair plus scope keys stay below SQLite's 999-bind limit.
    for (var offset = 0; offset < visible.length - 1; offset += 160) {
      final end = (offset + 160).clamp(0, visible.length - 1);
      final pairs = [
        for (var n = offset; n < end; n++)
          if (visible[n + 1].$2 > visible[n].$2 + BigInt.one)
            (
              visible[n].$2,
              visible[n + 1].$2,
              visible[n + 1].$1,
              visible[n].$2 + BigInt.one,
              visible[n + 1].$2 - BigInt.one,
            ),
      ];
      if (pairs.isEmpty) continue;
      final gaps = await order(() async {
        await ready();
        if (_closed || !await allowed(scope)) return <HistoryGap>[];
        final rows = await db
            .customSelect(
              // Endpoints already exist. A before=N response proves through
              // N-1 even when N came from a legacy window without its own proof.
              // Completely unverified legacy pairs are unknown, not separate
              // fetched fragments. They still cannot answer cached pagination.
              '''WITH pairs(older_key,newer_key,newer_id,first_key,last_key) AS (VALUES
          ${List.filled(pairs.length, '(?,?,?,?,?)').join(',')})
          SELECT newer_id,newer_key FROM pairs WHERE coalesce((
            SELECT upper_key FROM raft_history_ranges WHERE origin=? AND principal=?
              AND server=? AND channel=? AND lower_key<=pairs.first_key
              ORDER BY lower_key DESC LIMIT 1),'')<last_key
          AND (coalesce((
            SELECT upper_key FROM raft_history_ranges WHERE origin=? AND principal=?
              AND server=? AND channel=? AND lower_key<=pairs.older_key
              ORDER BY lower_key DESC LIMIT 1),'')>=older_key
            OR coalesce((
            SELECT upper_key FROM raft_history_ranges WHERE origin=? AND principal=?
              AND server=? AND channel=? AND lower_key<=pairs.newer_key
              ORDER BY lower_key DESC LIMIT 1),'')>=newer_key)
          ORDER BY newer_key''',
              variables: [
                for (final pair in pairs) ...[
                  Variable(historySequenceKey(pair.$1)),
                  Variable(historySequenceKey(pair.$2)),
                  Variable(pair.$3),
                  Variable(historySequenceKey(pair.$4)),
                  Variable(historySequenceKey(pair.$5)),
                ],
                for (var n = 0; n < 3; n++)
                  for (final value in scope.key) Variable(value),
              ],
            )
            .get();
        return [
          for (final row in rows)
            HistoryGap(
              row.read<String>('newer_id'),
              BigInt.parse(row.read<String>('newer_key')),
            ),
        ];
      });
      result.addAll(gaps);
      if (end < visible.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    return result;
  }

  @override
  void dispose() {
    _closed = true;
    _versions.clear();
    super.dispose();
  }
}
