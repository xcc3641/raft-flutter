import 'dart:async';

import 'package:raft_client/raft_client.dart';

import 'resource_row_reconcile.dart';
import 'resource_snapshot_cache.dart';

/// A private-like channel, including facts this snapshot does not have.
bool savedPrivateLike(Map<String, dynamic>? facts) =>
    facts == null ||
    facts['isPrivate'] == true ||
    facts['visibility'] == 'private' ||
    const {'private', 'dm', 'joint', 'thread'}.contains(facts['type']);

/// Saved totals stay in the same range the page already uses.
int savedBoundedCount(int value) {
  if (value < 0) return 0;
  final cap = 1 << 53;
  return value > cap ? cap : value;
}

/// Saved rows are keyed by `messageId`. Payloads name that id as `id` or
/// `messageId`.
String? savedPayloadMessageId(Object? payload) {
  if (payload is! Map) return null;
  final id = payload['messageId'] ?? payload['id'];
  return id is String && id.isNotEmpty ? id : null;
}

Map<String, dynamic> _mergeFields(Map<String, dynamic> row, Map payload) {
  final merged = Map<String, dynamic>.of(row);
  for (final entry in payload.entries) {
    final key = entry.key;
    if (key is! String) continue;
    if (const {'id', 'channelId', 'messageId'}.contains(key)) continue;
    if (key != 'content' && !row.containsKey(key)) continue;
    if (key == 'content' && entry.value == null) continue;
    merged[key] = entry.value;
  }
  return merged;
}

bool _rowHit(Map<String, dynamic> row, Object? payload, {required bool byMessageId}) {
  if (payload is! Map) return false;
  if (byMessageId) {
    final rowId = row['messageId'];
    final id = payload['id'];
    final messageId = payload['messageId'];
    return (id is String && rowId == id) ||
        (messageId is String && rowId == messageId);
  }
  final id = payload['id'];
  return id is String && row['id'] == id;
}

/// Merge [payload] into the one saved or search row it names.
///
/// Null when the payload names nothing or no row changes. Unchanged rows keep
/// their objects.
List<Map<String, dynamic>>? mergeSavedRow(
  List<Map<String, dynamic>> rows,
  Object? payload, {
  required bool byMessageId,
}) {
  if (payload is! Map) return null;
  final id = payload['id'];
  final messageId = payload['messageId'];
  if (byMessageId) {
    if (id is! String && messageId is! String) return null;
  } else if (id is! String) {
    return null;
  }
  var changed = false;
  final next = [
    for (final row in rows)
      if (!_rowHit(row, payload, byMessageId: byMessageId))
        row
      else
        () {
          final merged = _mergeFields(row, payload);
          if (rowDeepEquals(merged, row)) return row;
          changed = true;
          return merged;
        }(),
  ];
  return changed ? next : null;
}

typedef SavedMessageEdit = ({
  List<Map<String, dynamic>> rows,
  Map<String, ResourceViewWindow> windows,
  int? totalCount,
});

List<Map<String, dynamic>>? _withoutMessage(
  List<Map<String, dynamic>> rows,
  String id,
) {
  if (!rows.any((row) => row['messageId'] == id)) return null;
  return [for (final row in rows) if (row['messageId'] != id) row];
}

Map<String, ResourceViewWindow> _windowsWithoutMessage(
  Map<String, ResourceViewWindow> windows,
  String id,
) {
  var changed = false;
  final next = <String, ResourceViewWindow>{};
  for (final entry in windows.entries) {
    final rows = _withoutMessage(entry.value.rows, id);
    if (rows == null) {
      next[entry.key] = entry.value;
      continue;
    }
    changed = true;
    final total = entry.value.totalCount;
    next[entry.key] = ResourceViewWindow(
      rows: rows,
      hasMore: entry.value.hasMore,
      totalCount: total == null ? null : savedBoundedCount(total - 1),
      totalUnreadCount: entry.value.totalUnreadCount,
    );
  }
  return changed ? next : windows;
}

/// Drop the saved row [payload] names from [rows] and from [windows].
///
/// Null when the payload names no id, or that id is not in the window.
SavedMessageEdit? omitSavedMessage({
  required List<Map<String, dynamic>> rows,
  required Map<String, ResourceViewWindow> windows,
  required int? totalCount,
  required Object? payload,
}) {
  final id = savedPayloadMessageId(payload);
  if (id == null) return null;
  final nextRows = _withoutMessage(rows, id);
  final nextWindows = _windowsWithoutMessage(windows, id);
  if (nextRows == null && identical(nextWindows, windows)) return null;
  final removed = nextRows == null ? 0 : rows.length - nextRows.length;
  return (
    rows: nextRows ?? rows,
    windows: nextWindows,
    totalCount: totalCount == null || removed == 0
        ? totalCount
        : savedBoundedCount(totalCount - removed),
  );
}

Map<String, ResourceViewWindow> _patchWindows(
  Map<String, ResourceViewWindow> windows,
  Object? payload,
) {
  var changed = false;
  final next = <String, ResourceViewWindow>{};
  for (final entry in windows.entries) {
    final rows = mergeSavedRow(entry.value.rows, payload, byMessageId: true);
    if (rows == null) {
      next[entry.key] = entry.value;
      continue;
    }
    changed = true;
    next[entry.key] = ResourceViewWindow(
      rows: rows,
      hasMore: entry.value.hasMore,
      totalCount: entry.value.totalCount,
      totalUnreadCount: entry.value.totalUnreadCount,
    );
  }
  return changed ? next : windows;
}

bool _keepChannel(Map row, Set<String> lost) =>
    !rowChannelIds(row).any(lost.contains);

Map<String, ResourceViewWindow> _windowsWithoutChannels(
  Map<String, ResourceViewWindow> windows,
  Set<String> lost,
) {
  var changed = false;
  final next = <String, ResourceViewWindow>{};
  for (final entry in windows.entries) {
    if (entry.value.rows.every((row) => _keepChannel(row, lost))) {
      next[entry.key] = entry.value;
      continue;
    }
    changed = true;
    final rows = [
      for (final row in entry.value.rows)
        if (_keepChannel(row, lost)) row,
    ];
    final removed = entry.value.rows.length - rows.length;
    final total = entry.value.totalCount;
    next[entry.key] = ResourceViewWindow(
      rows: rows,
      hasMore: entry.value.hasMore,
      totalCount: total == null ? null : savedBoundedCount(total - removed),
      totalUnreadCount: entry.value.totalUnreadCount,
    );
  }
  return changed ? next : windows;
}

/// The one accepted workspace Saved window.
///
/// While a page is attached it only stores the list. While none is, it
/// patches or drops rows and never fetches.
class ServerSavedWindow implements ServerSavedSlot {
  ServerSavedWindow({
    required this.client,
    required this.events,
    required this.snapshot,
    required this.serverId,
    required this.identity,
    required this.lostChannels,
  });

  final Object client;
  final Stream<RaftEvent> events;
  @override
  ResourceSnapshot snapshot;
  String? Function() serverId;
  String Function() identity;
  Set<String> Function(Map<String, Map<String, dynamic>> previous) lostChannels;
  @override
  bool needsRevalidate = false;
  @override
  int attached = 0;
  StreamSubscription<RaftEvent>? _events;
  var _disposed = false;

  bool get disposed => _disposed;
  bool get sameIdentity => identity() == snapshot.identity;

  void adopt({
    required ResourceSnapshot snapshot,
    required String? Function() serverId,
    required String Function() identity,
    required Set<String> Function(Map<String, Map<String, dynamic>> previous)
    lostChannels,
  }) {
    this.snapshot = snapshot;
    this.serverId = serverId;
    this.identity = identity;
    this.lostChannels = lostChannels;
    needsRevalidate = false;
  }

  @override
  void attach() {
    attached++;
    _events?.cancel();
    _events = null;
  }

  @override
  void detach() {
    if (attached == 0) return;
    attached--;
    if (attached == 0) ensureListening();
  }

  void ensureListening() {
    if (_disposed || attached != 0 || _events != null) return;
    _events = events.listen(_onEvent);
  }

  void dispose() {
    _disposed = true;
    _events?.cancel();
    _events = null;
    attached = 0;
  }

  /// An id that left the saved set. No row is invented, and nothing is fetched.
  void removeMessage(String id) {
    if (_disposed) return;
    final next = omitSavedMessage(
      rows: snapshot.rows,
      windows: snapshot.viewWindows,
      totalCount: snapshot.totalCount,
      payload: {'id': id},
    );
    if (next == null) return;
    snapshot = snapshot.replaceRows(
      rows: next.rows,
      totalCount: next.totalCount,
      viewWindows: next.windows,
    );
  }

  /// An id that entered the saved set. There is no row to insert.
  void noteSaved(String id) {
    if (_disposed) return;
    final known =
        snapshot.rows.any((row) => row['messageId'] == id) ||
        snapshot.viewWindows.values.any(
          (window) => window.rows.any((row) => row['messageId'] == id),
        );
    if (!known) needsRevalidate = true;
  }

  void _onEvent(RaftEvent event) {
    if (_disposed || attached != 0 || !sameIdentity) return;
    final name = event.name;
    if (name == 'connected') {
      needsRevalidate = true;
      return;
    }
    const handled = {
      'message:updated',
      'message:deleted',
      'channel:removed',
      'channel:authority-updated',
      'channel:members-updated',
      'channel:updated',
    };
    if (!handled.contains(name) || _otherServer(event.payload)) return;
    switch (name) {
      case 'message:updated':
        _patch(event.payload);
      case 'message:deleted':
        _delete(event.payload);
      case 'channel:removed':
        _onChannel(event.payload, removed: true);
      case 'channel:updated':
        _onChannel(event.payload, updated: true);
      default:
        _onChannel(event.payload, authority: true);
    }
  }

  bool _otherServer(Object? payload) {
    if (payload is! Map) return false;
    final id = payload['serverId'];
    return id is String && id != serverId();
  }

  void _patch(Object? payload) {
    if (payload is! Map ||
        (payload['id'] is! String && payload['messageId'] is! String)) {
      needsRevalidate = true;
      return;
    }
    final rows = mergeSavedRow(snapshot.rows, payload, byMessageId: true);
    final windows = _patchWindows(snapshot.viewWindows, payload);
    if (rows == null && identical(windows, snapshot.viewWindows)) return;
    snapshot = snapshot.replaceRows(
      rows: rows ?? snapshot.rows,
      totalCount: snapshot.totalCount,
      viewWindows: windows,
    );
  }

  void _delete(Object? payload) {
    final next = omitSavedMessage(
      rows: snapshot.rows,
      windows: snapshot.viewWindows,
      totalCount: snapshot.totalCount,
      payload: payload,
    );
    if (next == null) {
      if (savedPayloadMessageId(payload) == null) needsRevalidate = true;
      return;
    }
    snapshot = snapshot.replaceRows(
      rows: next.rows,
      totalCount: next.totalCount,
      viewWindows: next.windows,
    );
  }

  void _onChannel(
    Object? payload, {
    bool removed = false,
    bool updated = false,
    bool authority = false,
  }) {
    final id = _channelId(payload);
    final drop = <String>{...lostChannels(snapshot.channelAccess)};
    if (id == null) {
      needsRevalidate = true;
    } else if (removed) {
      drop.add(id);
    } else if (authority && savedPrivateLike(snapshot.channelAccess[id])) {
      drop.add(id);
    }
    if (updated) needsRevalidate = true;
    _drop(drop);
  }

  String? _channelId(Object? payload) {
    if (payload is! Map) return null;
    final id = payload['channelId'] ?? payload['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  void _drop(Set<String> ids) {
    if (_disposed || ids.isEmpty) return;
    final kept = [
      for (final row in snapshot.rows)
        if (_keepChannel(row, ids)) row,
    ];
    final removed = snapshot.rows.length - kept.length;
    final windows = _windowsWithoutChannels(snapshot.viewWindows, ids);
    if (removed == 0 && identical(windows, snapshot.viewWindows)) return;
    final total = snapshot.totalCount;
    snapshot = snapshot.replaceRows(
      rows: removed == 0 ? snapshot.rows : kept,
      totalCount: total == null || removed == 0
          ? total
          : savedBoundedCount(total - removed),
      viewWindows: windows,
    );
  }
}
