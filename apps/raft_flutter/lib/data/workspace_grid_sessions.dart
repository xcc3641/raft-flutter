import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';

import 'workspace_controller.dart';

/// Source workspace thread tabs deduplicate by parent channel and message.
/// The tab owns replies independently of the retained channel editor.
class WorkspaceGridThreadRef {
  const WorkspaceGridThreadRef(this.channelId, this.parentMessageId);
  final String channelId;
  final String parentMessageId;
  String get id => 'thread:$channelId:$parentMessageId';
  String get messagePrefix =>
      parentMessageId.substring(0, parentMessageId.length.clamp(0, 8));
}

/// Independent accepted windows on the existing session. The root remains
/// the only socket/server/membership owner. No bootstrap or extra transport.
class WorkspaceGridSessions extends ChangeNotifier {
  WorkspaceGridSessions(this.parent) {
    parent.addListener(synchronize);
    parent.foregroundChanges.addListener(synchronize);
    scope = authority;
  }
  final WorkspaceController parent;
  final controllers = <String, WorkspaceController>{};
  final threadRefs = <String, WorkspaceGridThreadRef>{};
  final callbacks = <String, VoidCallback>{};
  final admitted = <String>{};
  final presentationOwner = Object();
  late String scope;
  bool ended = false;

  String get authority => jsonEncode([
    identityHashCode(parent.client),
    parent.client.origin,
    parent.client.generation,
    parent.client.user?.id,
    parent.client.serverId,
    parent.server?.id,
    parent.server?.string('role'),
    parent.server?.json['permissions'],
  ]);

  RaftChannel? channel(String id) => [...parent.channels, ...parent.dms]
      .where((c) => c.id == id && parent.can('viewChannel', resource: c))
      .firstOrNull;

  String parentChannelId(String id) => threadRefs[id]?.channelId ?? id;

  WorkspaceController? openThread(
    String channelId,
    String parentMessageId, {
    String? initialThreadChannelId,
  }) {
    if (parentMessageId.trim().isEmpty) return null;
    final ref = WorkspaceGridThreadRef(channelId, parentMessageId);
    return _open(
      ref.id,
      threadRef: ref,
      initialThreadChannelId: initialThreadChannelId,
    );
  }

  WorkspaceController? open(String id) => _open(id);

  WorkspaceController? _open(
    String id, {
    WorkspaceGridThreadRef? threadRef,
    String? initialThreadChannelId,
  }) {
    if (ended ||
        authority != scope ||
        parent.client.user == null ||
        parent.server == null ||
        parent.server?.id != parent.client.serverId) {
      return null;
    }
    if (controllers.containsKey(id)) return controllers[id];
    final row = channel(threadRef?.channelId ?? id);
    if (row == null) return null;
    final child = WorkspaceController(
      parent.client,
      cache: parent.cache,
      ownsClient: false,
      entityDirectory: parent.entityDirectory,
      followedThreads: parent.followedThreads,
      composer: parent.composer,
    );
    child.server = parent.server;
    child.channel = row;
    child.servers = [...parent.servers];
    child.channels = [...parent.channels];
    child.dms = [...parent.dms];
    child.connected = parent.connected;
    child.syncCoreMessagesEnabled = parent.syncCoreMessagesEnabled;
    child.ledger.switchServer(parent.server!.id);
    child.foreground = false;
    child.setConversationPresentation(
      presentationOwner,
      main: false,
      thread: false,
    );
    controllers[id] = child;
    if (threadRef != null) threadRefs[id] = threadRef;
    void changed() {
      if (ended || controllers[id] != child || authority != scope) return;
      notifyListeners();
    }

    callbacks[id] = changed;
    child.addListener(changed);
    // Select after the caller's layout frame, not during its build. The child
    // window fences every result; retirement rejects all late acknowledgments.
    // ignore: raft_lints/avoid_unreviewed_idle_work -- One-shot deferral out of a build or notification; the callback does not schedule another microtask itself.
    scheduleMicrotask(() {
      if (!ended && controllers[id] == child && scope == authority) {
        if (threadRef == null) {
          unawaited(child.selectChannel(row, autoRead: false));
        } else {
          // Source threadStore also admits an already accepted parent summary.
          // Task metadata alone never manufactures a reply-channel hint.
          unawaited(
            child.openThreadIdentity(
              parentChannelId: threadRef.channelId,
              parentMessageId: threadRef.parentMessageId,
              initialThreadChannelId: initialThreadChannelId,
              navigate: false,
            ),
          );
        }
      }
    });
    return child;
  }

  void present(Set<String> ids) {
    admitted
      ..clear()
      ..addAll(ids);
    for (final entry in controllers.entries) {
      final visible = ids.contains(entry.key) && parent.foreground;
      // This is tab admission, not the child's folded main/thread owner.
      // Resuming the parent must not replace a folded main:false projection
      // with main:true before that child's next layout frame.
      // Do not call setForeground: it acknowledges immediately.
      entry.value.foreground = visible;
    }
  }

  void close(String id) {
    final child = controllers.remove(id);
    if (child == null) return;
    child.removeListener(callbacks.remove(id)!);
    threadRefs.remove(id);
    // Retire the accepted private projection before detaching its listeners.
    // Owned dialogs/image leases see authority loss even though the shared
    // authenticated client intentionally remains alive for other panels.
    child.server = null;
    child.channel = null;
    child.threadParent = null;
    child.threadChannelId = null;
    child.visibleIds.clear();
    child.ledger.switchServer(null);
    child.foreground = false;
    child.notifyListeners();
    child.dispose();
  }

  void synchronize() {
    if (ended) return;
    if (authority != scope) {
      // Retire every borrowed editor; the root retains draft ownership.
      scope = authority;
      for (final id in controllers.keys.toList()) {
        close(id);
      }
      notifyListeners();
      return;
    }
    for (final entry in controllers.entries.toList()) {
      final fresh = channel(parentChannelId(entry.key));
      final old = entry.value.channel;
      if (fresh == null ||
          fresh.joined != old?.joined ||
          !mapEquals(
            fresh.json['channelCapabilities'] is Map
                ? Map<String, dynamic>.from(fresh.json['channelCapabilities'])
                : null,
            old?.json['channelCapabilities'] is Map
                ? Map<String, dynamic>.from(old!.json['channelCapabilities'])
                : null,
          )) {
        close(entry.key);
        continue;
      }
      entry.value.server = parent.server;
      entry.value.channels = [...parent.channels];
      entry.value.dms = [...parent.dms];
      entry.value.connected = parent.connected;
    }
    present({...admitted});
    notifyListeners();
  }

  @override
  void dispose() {
    if (ended) return;
    parent.removeListener(synchronize);
    parent.foregroundChanges.removeListener(synchronize);
    for (final id in controllers.keys.toList()) {
      close(id);
    }
    ended = true;
    super.dispose();
  }
}
