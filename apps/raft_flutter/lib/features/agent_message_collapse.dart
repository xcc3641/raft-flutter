import 'package:raft_client/raft_client.dart';

import '../data/workspace_controller.dart';

/// Remembers expand and collapse for one viewing of one chat.
///
/// The first time an agent message is shown, it follows the read cursor:
/// unread opens, and read stays closed. That choice stays while the reader
/// remains in the conversation, including after the cursor moves past the
/// message. A manual toggle replaces it. The next visit follows the cursor
/// again.
///
/// This hangs off the chat state instead of being one of its fields. The
/// structure audit counts every new instance field on that state.
final _sessions = Expando<AgentMessageCollapseSession>();

/// The collapse memory for this mounted chat.
AgentMessageCollapseSession agentCollapseOf(Object chat) =>
    _sessions[chat] ??= AgentMessageCollapseSession();

/// Drops the memory when the chat state is disposed.
void releaseAgentCollapse(Object chat) {
  _sessions[chat] = null;
}

/// Binds this chat's visit to the channel, or to the thread channel.
void bindAgentCollapse(
  Object chat,
  WorkspaceController workspace,
  bool thread,
) {
  agentCollapseOf(chat)
      .bind(thread ? workspace.threadChannelId : workspace.channel?.id);
}

/// Collapse setting for this row, and whether it starts open.
/// A thread's parent row keeps today's collapse and does not follow the
/// thread cursor. Turning collapse off remembers nothing.
({bool collapse, bool open}) agentMessageOpens(
  AgentMessageCollapseSession session,
  bool parent,
  bool agent,
  RaftMessage message,
  WorkspaceController workspace,
  bool thread,
) {
  final collapse = longMessagesCollapse(message.json, workspace.channel?.json);
  if (parent || !collapse) return (collapse: collapse, open: false);
  return (
    collapse: true,
    open: session.startsOpen(
      messageId: message.id,
      agent: agent,
      seq: message.seq,
      maxReadSeq: scopeReadCursor(
        state: workspace.readState.state,
        serverId: workspace.client.serverId,
        principalId: workspace.client.user?.id,
        scopeId: thread ? workspace.threadChannelId : workspace.channel?.id,
      ),
    ),
  );
}

class AgentMessageCollapseSession {
  String? _scope;
  final _open = <String, bool>{};

  /// Clears remembered choices when [scope] changes. The same scope keeps
  /// them. Null is the gap between conversations.
  void bind(String? scope) {
    if (scope == _scope) return;
    _scope = scope;
    _open.clear();
  }

  /// The choice already made for [messageId], or the cursor rule for an
  /// agent message. Other messages stay closed and are not remembered until
  /// the reader toggles one.
  ///
  /// [maxReadSeq] is the accepted read cursor. Null means there is no cursor
  /// yet, which the unread count also treats as unread. A message is unread
  /// when its seq is greater than that cursor.
  bool startsOpen({
    required String messageId,
    required bool agent,
    required BigInt seq,
    required BigInt? maxReadSeq,
  }) {
    final remembered = _open[messageId];
    if (remembered != null) return remembered;
    if (!agent) return false;
    final open = maxReadSeq == null || seq > maxReadSeq;
    _open[messageId] = open;
    return open;
  }

  /// The reader's own toggle. It wins over the cursor for this visit.
  void choose(String messageId, bool open) {
    _open[messageId] = open;
  }
}

/// Channel "Collapse long messages", on unless the channel turns it off.
/// Action cards stay out of the collapse, as they do today.
bool longMessagesCollapse(
  Map<String, dynamic> message,
  Map<String, dynamic>? channel,
) {
  final metadata = message['actionMetadata'];
  return (metadata is! Map || metadata['kind'] != 'action-card') &&
      channel?['collapseLongMessages'] != false;
}

/// `maxReadSeq` from the accepted read fact the unread count uses.
/// Missing identity, or a missing fact, is null: not read yet.
BigInt? scopeReadCursor({
  required Map<String, dynamic>? Function(
    String server,
    String principal,
    String scope,
  )
  state,
  required String? serverId,
  required String? principalId,
  required String? scopeId,
}) {
  if (serverId == null || principalId == null || scopeId == null) return null;
  final seq = state(serverId, principalId, scopeId)?['maxReadSeq'];
  return seq is int ? BigInt.from(seq) : null;
}
