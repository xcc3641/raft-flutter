import 'package:raft_client/raft_client.dart';

import 'message_window_snapshot.dart';

/// Accepted paging facts returned to the presentation adapter.
typedef ThreadPageBoundary = ({bool more, bool limited});

/// Cached identity and boundary facts are immutable; only this owner updates
/// independently resolved parent metadata through its admission boundary.
class CachedMessageThread {
  CachedMessageThread(
    this.parentChannelId,
    this.threadChannelId,
    this.token,
    this.authority,
    this.generation,
    this.hasMore,
    this.historyLimited,
    this.parent, {
    this.contextWindow = false,
  });
  final bool contextWindow;
  final String parentChannelId, threadChannelId, token;
  final String? authority;
  final int generation;
  final bool hasMore, historyLimited;
  final RaftMessage? parent;

  bool matches(
    String channel,
    String? replyToken,
    String? resourceAuthority,
    int epoch,
  ) =>
      parentChannelId == channel &&
      token == replyToken &&
      authority == resourceAuthority &&
      generation == epoch;

  CachedMessageThread withParent(RaftMessage? value) => CachedMessageThread(
    parentChannelId,
    threadChannelId,
    token,
    authority,
    generation,
    hasMore,
    historyLimited,
    value,
    contextWindow: contextWindow,
  );

  CachedMessageThread withBoundary({required bool more, required bool context}) =>
    CachedMessageThread(parentChannelId, threadChannelId, token, authority,
      generation, more, historyLimited, parent, contextWindow: context);
}

/// Tail refreshes retain only history before the refreshed page. A focused
/// context or an explicit access limit has its own authoritative membership.
({
  List<Map<String, dynamic>> rows,
  Set<String> visible,
  bool more,
  bool limited,
})
reconcileThreadPage(
  Map<String, dynamic> page,
  String id, {
  required Iterable<Map<String, dynamic>> retained,
  required bool retainedHasMore,
  required bool focused,
}) {
  final fresh = acceptedWindowRows(page['messages'], id);
  final limited = page['historyLimited'] == true;
  final visible = focused || limited
      ? fresh.map((row) => row['id'] as String).toSet()
      : reconcileTailWindow(retained, fresh);
  return (
    rows: fresh,
    visible: visible,
    more: focused
        ? page['hasOlder'] == true
        : !limited &&
              (visible.length > fresh.length
                  ? retainedHasMore
                  : fresh.length >= 50),
    limited: limited,
  );
}
