import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/history_gaps.dart';
import '../data/message_history_pages.dart';
import '../data/workspace_controller.dart';

/// An overlay preserves message geometry while a retained gap is checked.
class MessageHistoryGapBanner extends StatefulWidget {
  const MessageHistoryGapBanner({
    super.key,
    required this.controller,
    this.thread = false,
  });
  final WorkspaceController controller;
  final bool thread;
  @override
  State<MessageHistoryGapBanner> createState() =>
      _MessageHistoryGapBannerState();
}

class _MessageHistoryGapBannerState extends State<MessageHistoryGapBanner> {
  HistoryGapQueries? source;
  Object? stamp, identity;
  List<HistoryGap> gaps = const [];
  bool failed = false, busy = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
    refresh(rebuild: false);
  }

  @override
  void didUpdateWidget(MessageHistoryGapBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(refresh);
      widget.controller.addListener(refresh);
    }
    refresh(rebuild: false);
  }

  @override
  void dispose() {
    widget.controller.removeListener(refresh);
    source?.removeListener(refresh);
    super.dispose();
  }

  void refresh({bool rebuild = true}) {
    final w = widget.controller,
        storage = MessageHistoryPages.storage(widget.controller.cache);
    if (!identical(source, storage?.gaps)) {
      source?.removeListener(refresh);
      source = storage?.gaps;
      source?.addListener(refresh);
    }
    final id = widget.thread ? w.threadChannelId : w.channel?.id;
    final visible = widget.thread
        ? w.threadWindow?.visible
        : w.messageWindow?.visible;
    final scope = id == null
        ? null
        : MessageHistoryPages.scope(
            w,
            id,
            parent: widget.thread ? w.threadParentChannelId : id,
            parentMessage: widget.thread ? w.threadParentMessageId : null,
          );
    if (source == null ||
        scope == null ||
        visible != true ||
        !w.cacheWritable) {
      if (gaps.isNotEmpty || failed) {
        gaps = const [];
        failed = false;
        stamp = null;
        if (rebuild) setState(() {});
      }
      return;
    }
    final rows = widget.thread ? w.replies : w.messages;
    final nextIdentity = (
      scope.origin,
      scope.principal,
      scope.server,
      scope.channel,
      scope.authority,
      w.messageHistoryTicket(scope.parentChannel),
      w.navigationRevision,
      widget.thread ? w.threadGeneration : w.channelGeneration,
    );
    final next = (
      nextIdentity,
      Object.hashAll(rows.map((row) => (row.id, row.json['seq']))),
      source!.revision(scope),
    );
    if (busy != w.loadingOlder) {
      busy = w.loadingOlder;
      if (rebuild) setState(() {});
    }
    if (stamp == next) return;
    stamp = next;
    if (identity != nextIdentity) {
      identity = nextIdentity;
      gaps = const [];
      failed = false;
      if (rebuild) setState(() {});
    }
    final captured = source!,
        points = [
          for (final row in rows)
            if (row.seq > BigInt.zero) (row.id, row.seq),
        ];
    bool current() =>
        mounted &&
        stamp == next &&
        identical(source, captured) &&
        w.cacheWritable &&
        w.client.origin == scope.origin &&
        w.client.user?.id == scope.principal &&
        w.client.serverId == scope.server &&
        w.messageHistoryTicket(scope.parentChannel) == nextIdentity.$6;
    captured
        .read(scope, points)
        .then(
          (value) {
            if (current()) {
              setState(() {
                gaps = value;
                failed = false;
              });
            }
          },
          onError: (Object _) {
            if (current()) {
              setState(() {
                failed = true;
              });
            }
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    if (gaps.isEmpty && !failed) return const SizedBox.shrink();
    final gap = gaps.firstOrNull;
    final controller = widget.controller;
    return Positioned(
      top: RaftSpace.x2,
      left: RaftSpace.x2,
      right: RaftSpace.x2,
      child: HistoryGapNotice(
        failed: failed,
        busy: busy,
        onLoad: busy
            ? null
            : () {
                if (failed) {
                  stamp = null;
                  refresh();
                } else if (gap != null && controller.presentationActive) {
                  controller.loadHistoryGap(gap.before, thread: widget.thread);
                }
              },
      ),
    );
  }
}

/// Feature composition of the shared banner/button recipes; no store in UI.
class HistoryGapNotice extends StatelessWidget {
  const HistoryGapNotice({
    super.key,
    this.failed = false,
    this.busy = false,
    this.onLoad,
  });
  final bool failed, busy;
  final VoidCallback? onLoad;
  @override
  Widget build(BuildContext context) => RaftBanner(
    key: const ValueKey('message-history-gap'),
    status: failed
        ? RaftBannerRecipeStatus.warning
        : RaftBannerRecipeStatus.info,
    size: RaftBannerRecipeSize.sm,
    description: raftText(
      context,
      failed
          ? "Couldn't check saved history."
          : 'There may be more messages between saved sections.',
    ),
    footer: Align(
      alignment: Alignment.centerRight,
      child: RaftRecipeButton(
        label: raftText(
          context,
          busy
              ? 'Loading...'
              : failed
              ? 'Retry'
              : 'Load this gap',
        ),
        onPressed: busy ? null : onLoad,
      ),
    ),
  );
}
