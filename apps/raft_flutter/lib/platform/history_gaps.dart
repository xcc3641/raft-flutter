import 'package:drift/drift.dart';

import '../data/history_gaps.dart';
import '../data/message_history.dart';
import 'message_history.dart' show HistoryOperationOrder;

/// Proof checks use bounded indexed seeks, never sequence-distance guesses.
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
    for (var offset = 0; offset < visible.length - 1; offset += 200) {
      final end = (offset + 200).clamp(0, visible.length - 1);
      final pairs = [
        for (var n = offset; n < end; n++)
          (visible[n].$2, visible[n + 1].$2, visible[n + 1].$1),
      ];
      final gaps = await order(() async {
        await ready();
        if (_closed || !await allowed(scope)) return <HistoryGap>[];
        final rows = await db
            .customSelect(
              '''WITH pairs(older_key,newer_key,newer_id) AS (VALUES
          ${List.filled(pairs.length, '(?,?,?)').join(',')})
          SELECT newer_id,newer_key FROM pairs WHERE coalesce((
            SELECT upper_key FROM raft_history_ranges WHERE origin=? AND principal=?
              AND server=? AND channel=? AND lower_key<=pairs.older_key
              ORDER BY lower_key DESC LIMIT 1),'')<newer_key ORDER BY newer_key''',
              variables: [
                for (final pair in pairs) ...[
                  Variable(historySequenceKey(pair.$1)),
                  Variable(historySequenceKey(pair.$2)),
                  Variable(pair.$3),
                ],
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
