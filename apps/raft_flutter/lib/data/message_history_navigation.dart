import 'message_history_pages.dart';
import 'message_history_positions.dart';
import 'message_window_snapshot.dart';
import 'workspace_controller.dart';
import 'workspace_message_windows.dart';
import 'user_error.dart';

/// Paging commands share the receiver's existing request and boundary owners.
class MessageHistoryNavigation {
  static Future<void> page(
    WorkspaceController w, {
    required bool thread,
    required bool newer,
    BigInt? gapBefore,
    required MessageWindowRequest Function(String) requestFor,
    required void Function(String, dynamic) summaries,
  }) async {
    final current = thread ? w.replies : w.messages;
    final id = thread ? w.threadChannelId : w.channel?.id;
    final more = newer
        ? (thread ? w.messageWindows.contextHasNewer(id) : w.hasNewer)
        : (thread ? w.threadHasMore : w.hasMore);
    if (id == null ||
        w.loadingOlder ||
        gapBefore == null && !more ||
        current.isEmpty) {
      return;
    }
    if (gapBefore != null && !current.any((row) => row.seq == gapBefore)) {
      return;
    }
    final request = requestFor(id);
    w.loadingOlder = true;
    w.notifyListeners();
    try {
      final page = await MessageHistoryPages.read(
        w,
        request,
        id,
        thread: thread,
        before: gapBefore ?? (newer ? null : current.first.seq),
        after: newer ? current.last.seq : null,
        gap: gapBefore != null,
      );
      if (!request.current) return;
      final rows = acceptedWindowRows(page['messages'], id);
      w.messageWindows.acceptRows(request, id, rows);
      await MessageHistoryPages.record(w, request, page);
      if (!request.current) return;
      final limited = page['historyLimited'] == true;
      final hasMore =
          !limited &&
          (page['hasMore'] is bool
              ? page['hasMore'] as bool
              : rows.length >= 50);
      if (newer) {
        w.messageWindows.setContextMode(request, id, hasMore ? true : null);
        if (!thread) w.hasNewer = hasMore;
      } else if (gapBefore != null) {
        // An interior gap has no authority over the oldest window boundary.
      } else if (thread) {
        w.threadHistoryLimited = limited;
        w.threadHasMore = hasMore;
      } else {
        w.historyLimited = limited;
        w.hasMore = hasMore;
      }
      if (!thread) summaries(id, page['threadSummariesByParentMessageId']);
      MessageHistoryPages.storage(w.cache)?.memory
          .direction(w, id, older: !newer);
      await w.saveHistoryWindow(id, thread: thread);
    } catch (cause) {
      if (request.current) {
        w.error = userErrorText(
          cause,
          where: newer ? 'load newer messages' : 'load older messages',
        );
      }
    } finally {
      if (request.current) {
        w.loadingOlder = false;
        w.notifyListeners();
      }
    }
  }

  static Future<void> latest(
    WorkspaceController w, {
    required bool thread,
    required bool navigate,
  }) async {
    final selectedId = thread ? w.threadChannelId : w.channel?.id;
    if (selectedId == null) return;
    final identity = w.threadIdentity;
    final positionScope = MessageHistoryPages.scope(
      w,
      selectedId,
      parent: thread ? w.threadParentChannelId : selectedId,
      parentMessage: thread ? w.threadParentMessageId : null,
    );
    if (thread) {
      w.messageWindows.threadGeneration++;
    } else {
      w.messageWindows.channelGeneration++;
    }
    final revision = w.navigationRevision, seal = w.messageHistoryTicket('');
    final request = w.messageWindows.request(
      thread: thread,
      allowed: () =>
          w.cacheWritable &&
          revision == w.navigationRevision &&
          seal == w.messageHistoryTicket('') &&
          selectedId == (thread ? w.threadChannelId : w.channel?.id),
    );
    MessageHistoryPages.storage(w.cache)?.memory
        .direction(w, selectedId, older: false);
    try {
      await MessageHistoryPositions.clear(
        w,
        selectedId,
        thread: thread,
        current: () => request.current,
        boundScope: positionScope,
      );
    } catch (cause) {
      if (request.current) {
        w.error = userErrorText(cause, where: 'load latest messages');
        w.notifyListeners();
      }
      return;
    }
    if (!request.current) return;
    w.clearHighlightedMessage(w.highlightedMessageId);
    if (thread) {
      final id = w.threadChannelId;
      if (identity != null &&
          id != null &&
          w.messageWindows.contextHasNewer(id)) {
        await w.openThreadIdentity(
          parentChannelId: identity.parentChannelId,
          parentMessageId: identity.parentMessageId,
          initialThreadChannelId: id,
          navigate: navigate,
        );
      }
    } else if (w.channel case final selected?) {
      if (w.hasNewer) {
        await w.selectChannel(
          selected,
          navigate: navigate,
          retainContextUntilAccepted: true,
        );
      }
    }
  }
}
