import 'dart:async';

import 'package:raft_ui/raft_ui.dart' show RaftIdleTimer;

import 'history_read_policy.dart';
import 'history_range_reads.dart';
import 'message_history_reconciliation.dart';
import 'history_gap_recovery.dart';
import 'message_history.dart';
import 'message_history_pages.dart';
import 'workspace_controller.dart';
import 'workspace_message_windows.dart';

/// Reconciles authorized saved ranges while preserving accepted projections.
class MessageHistoryVerification {
  static final _jobs = Expando<_HistoryVerificationJob>();

  /// One event-driven pass over saved ranges, including hidden conversations.
  /// Existing authorized pages supply the digest; no unsupported endpoint or
  /// wall-clock freshness can make a missed old edit appear verified.
  static void reconnect(WorkspaceController w) {
    HistoryRangeReads.of(w).restart();
    HistoryGapRecovery.reconnect(w);
    _resume(w);
  }

  static void _resume(WorkspaceController w) {
    final db = MessageHistoryPages.storage(w.deviceStore.cache);
    if (db == null ||
        !w.foreground ||
        !w.deviceStore.writable ||
        w.client.user == null ||
        w.client.serverId == null) {
      return;
    }
    final job = _jobs[w] ??= _HistoryVerificationJob();
    if (job.running) {
      job.again = true;
      return;
    }
    job.retry.cancel();
    job.running = true;
    db.reads.background(() async {
      var complete = false;
      try {
        do {
          job.again = false;
          complete = await _saved(w);
        } while (job.again &&
            w.deviceStore.writable &&
            w.foreground &&
            !db.reads.closed);
      } finally {
        job.running = false;
        if (identical(_jobs[w], job)) {
          if (complete || !w.deviceStore.writable || db.reads.closed) {
            job.retry.cancel();
            _jobs[w] = null;
          } else if (w.connected && w.foreground) {
            final seconds = 2 << job.attempt.clamp(0, 5);
            job.attempt++;
            job.zone.run(
              () =>
                  job.retry.start(Duration(seconds: seconds), () => _resume(w)),
            );
          }
        }
      }
    });
  }

  static void cancel(WorkspaceController w) {
    _jobs[w]?.retry.cancel();
    _jobs[w] = null;
    HistoryRangeReads.of(w).restart();
  }

  static Object _context(WorkspaceController w, MessageHistoryStorage db) => (
    w.client.origin,
    w.client.user?.id,
    w.client.serverId,
    w.ledger.generation,
    w.messageHistoryTicket(''),
    w.navigationRevision,
    w.channelGeneration,
    w.threadGeneration,
    w.foreground,
    db.gaps.retirement,
  );

  /// Both automatic consumers use the same full acceptance and its metadata.
  /// Navigating away retires even disk-backed proof; online-only acceptance
  /// can never be mistaken for durable coverage on a later window visit.
  static HistoryRangeRead ranges(
    WorkspaceController w,
    MessageHistoryScope scope,
  ) {
    final db = MessageHistoryPages.storage(w.deviceStore.cache)!;
    return HistoryRangeReads.of(w).scope(_context(w, db), (
      scope.origin,
      scope.principal,
      scope.server,
      scope.channel,
      scope.authority,
      scope.parentChannel,
      scope.parentMessage,
      w.messageHistoryTicket(scope.parentChannel),
    ));
  }

  static Future<HistoryRangeProof?> readRange(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryScope scope, {
    BigInt? before,
    required HistoryReadReason reason,
    void Function(Object cause)? failed,
  }) {
    final db = MessageHistoryPages.storage(w.deviceStore.cache)!;
    final context = _context(w, db), range = ranges(w, scope);
    final ticket = w.messageHistoryTicket(scope.parentChannel);
    final guarded = w.messageWindows.request(
      allowed: () =>
          request.current && range.current && context == _context(w, db),
    );
    return range.read(before, () async {
      Map<String, dynamic>? response;
      final accepted = await MessageHistoryReconciliation.read(
        w,
        guarded,
        scope,
        ticket,
        before: before,
        reason: reason,
        wireTicket: (ticket, range.token),
        allowOnlineOnly: true,
        received: (page) => response = page,
        failed: failed,
      );
      return accepted && guarded.current && response != null
          ? HistoryRangeProof.page(response!, before)
          : null;
    });
  }

  static Future<bool> _saved(WorkspaceController w) async {
    final db = MessageHistoryPages.storage(w.deviceStore.cache)!;
    final user = w.client.user!.id,
        server = w.client.serverId!,
        origin = w.client.origin;
    final context = _context(w, db), reads = HistoryRangeReads.of(w);
    reads.bind(context);
    final pass = reads.generation;
    final ticket = w.messageHistoryTicket(''), generation = w.ledger.generation;
    bool current() =>
        w.deviceStore.writable &&
        !db.reads.closed &&
        w.foreground &&
        w.client.user?.id == user &&
        w.client.serverId == server &&
        w.client.origin == origin &&
        context == _context(w, db) &&
        pass == reads.generation &&
        w.ledger.generation == generation &&
        w.messageHistoryTicket('') == ticket;
    var complete = true;
    final ranges = await db.savedRanges(origin, user, server);
    for (final range in ranges) {
      if (!current()) return false;
      final known = range.$1;
      final scope = MessageHistoryPages.scope(
        w,
        known.channel,
        parent: known.parentChannel,
        parentMessage: known.parentMessage,
      );
      if (scope == null || scope.authority != known.authority) continue;
      final seal = w.messageHistoryTicket(scope.parentChannel);
      final request = w.messageWindows.request(
        allowed: () =>
            current() && seal == w.messageHistoryTicket(scope.parentChannel),
      );
      BigInt? before;
      while (request.current) {
        final proof = await readRange(
          w,
          request,
          scope,
          before: before,
          reason: HistoryReadReason.reconnect,
        );
        if (proof == null) {
          complete = false;
          break;
        }
        if (proof.limited ||
            proof.lower <= range.$2 ||
            before != null && proof.lower >= before) {
          break;
        }
        before = proof.lower;
      }
    }
    return complete && current();
  }

  static void tail(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryScope scope,
  ) {
    final storage = MessageHistoryPages.storage(w.deviceStore.cache);
    if (storage == null) return;
    final ticket = w.messageHistoryTicket(scope.parentChannel);
    storage.reads.background(
      () => _verify(w, request, scope, ticket, reason: HistoryReadReason.tail),
    );
  }

  static void schedule(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryPage page,
  ) {
    final db = MessageHistoryPages.storage(w.deviceStore.cache);
    if (db == null || !request.current || !w.foreground || !w.deviceStore.writable) {
      return;
    }
    final ticket = w.messageHistoryTicket(page.scope.parentChannel);
    final key = historyReadKey(page.scope, ticket, page.queryKey);
    if (!db.reads.claim(w, w.resumes.value, key, page.verifiedAt)) return;
    db.reads.background(() async {
      await _verify(
        w,
        request,
        page.scope,
        ticket,
        before: page.before,
        after: page.after,
        target: page.target,
        limit: page.limit,
        reason: HistoryReadReason.aged,
      );
    });
  }

  static void retained(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryPage fresh,
  ) {
    final db = MessageHistoryPages.storage(w.deviceStore.cache);
    if (db == null || !request.current || !w.foreground) return;
    final raw = (fresh.remotePage?['messages'] as List? ?? const []);
    if (raw.isEmpty || fresh['historyLimited'] == true) return;
    final first = raw
        .map((row) => BigInt.parse('${row['seq']}'))
        .reduce((a, b) => a < b ? a : b);
    final rows = w.messageWindows
        .rows(fresh.scope.channel)
        .where((row) => row.seq < first)
        .toList();
    if (rows.isEmpty) return;
    db.reads.background(() async {
      for (var end = rows.length; end > 0 && request.current; end -= 50) {
        final before = rows[end - 1].seq + BigInt.one;
        final local = await db.readPage(fresh.scope, before: before);
        final verified = await db.lastVerified(
          fresh.scope,
          historyQueryKey(before: before),
        );
        if (!request.current) return;
        schedule(
          w,
          request,
          MessageHistoryPage(
            {'messages': const <dynamic>[]},
            scope: fresh.scope,
            revision: fresh.revision,
            before: before,
            after: null,
            local: true,
            verifiedAt: verified ?? local?.verifiedAt,
          ),
        );
      }
    });
  }

  static void recheckContext(
    WorkspaceController w,
    MessageWindowRequest request,
    String id,
    String target,
  ) {
    final db = MessageHistoryPages.storage(w.deviceStore.cache);
    final scope = MessageHistoryPages.scope(w, id);
    if (db == null || scope == null || !request.current) return;
    db.reads.background(() async {
      final local = await db.readContext(scope, target);
      final verified = await db.lastVerified(
        scope,
        historyQueryKey(target: target),
      );
      if (!request.current) return;
      schedule(
        w,
        request,
        MessageHistoryPage(
          {'messages': const <dynamic>[]},
          scope: scope,
          revision: 0,
          before: null,
          after: null,
          local: true,
          focused: true,
          target: target,
          verifiedAt:
              verified ??
              (local is MessageHistoryPage ? local.verifiedAt : null),
        ),
      );
    });
  }

  /// Refreshes the visible saved rows and the latest page while preserving
  /// the existing timeline and context. Gap repair keeps its existing route.
  static Future<bool> refresh(WorkspaceController w) async {
    final db = MessageHistoryPages.storage(w.deviceStore.cache);
    if (db == null || !w.deviceStore.writable) return false;
    await w.syncVisibleScopes();
    var complete = true;
    for (final thread in [false, true]) {
      final id = thread ? w.threadChannelId : w.channel?.id;
      if (id == null) continue;
      final scope = MessageHistoryPages.scope(
        w,
        id,
        parent: thread ? w.threadParentChannelId : id,
        parentMessage: thread ? w.threadIdentity?.parentMessageId : null,
      );
      if (scope == null) continue;
      final ticket = w.messageHistoryTicket(scope.parentChannel);
      final request = w.messageWindows.request(
        thread: thread,
        allowed: () =>
            w.deviceStore.writable &&
            ticket == w.messageHistoryTicket(scope.parentChannel) &&
            w.messageWindows.notRevoked(id) &&
            w.messageWindows.notRevoked(scope.parentChannel) &&
            (thread ? w.threadChannelId == id : w.channel?.id == id),
      );
      final visible = w.messageWindows.rows(id);
      if (!await _verify(
        w,
        request,
        scope,
        ticket,
        reason: HistoryReadReason.manual,
      )) {
        complete = false;
      }
      for (var end = visible.length; end > 0 && request.current; end -= 50) {
        // Explicit refresh bypasses age and visit suppression. The shared
        // transport still coalesces an identical request already in flight.
        if (!await _verify(
          w,
          request,
          scope,
          ticket,
          before: visible[end - 1].seq + BigInt.one,
          reason: HistoryReadReason.manual,
        )) {
          complete = false;
        }
      }
    }
    return complete;
  }

  static Future<bool> _verify(
    WorkspaceController w,
    MessageWindowRequest request,
    MessageHistoryScope scope,
    Object ticket, {
    BigInt? before,
    BigInt? after,
    String? target,
    int limit = 50,
    required HistoryReadReason reason,
  }) => MessageHistoryReconciliation.read(
    w,
    request,
    scope,
    ticket,
    before: before,
    after: after,
    target: target,
    limit: limit,
    reason: reason,
  );
}

class _HistoryVerificationJob {
  bool again = false, running = false;
  int attempt = 0;
  final zone = Zone.current;
  final retry = RaftIdleTimer(yieldToAnimation: false);
}
