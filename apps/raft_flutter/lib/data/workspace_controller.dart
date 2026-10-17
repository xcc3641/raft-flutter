import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_sync/raft_sync.dart';

import 'burst_reads.dart';
import 'announcement_store.dart';
import 'cause_notice.dart';
import 'message_task_cache.dart';
import 'message_translation_store.dart';
import 'thread_agent_followers.dart';
import 'thread_search.dart';
import 'thread_unread_hint.dart';
import 'workspace_services.dart';
import 'session_scope.dart';
import 'channel_revocation.dart';
import 'channel_repository.dart';
import 'panel_caches.dart';
import 'source_channel_files_store.dart';
import 'source_activity_unread_store.dart';
import 'reaction_toggle.dart';
import 'workspace_cache.dart';
import 'workspace_device_store.dart';
import 'sidebar_repository.dart';
import 'raft_api_gateway.dart';
import 'workspace_composer.dart';
import 'workspace_uploads.dart';
import 'workspace_sends.dart';
import 'conversation_read_repository.dart';
import 'conversation_window.dart';
import 'workspace_message_windows.dart';

export 'workspace_uploads.dart' show UploadDraft;
export 'thread_search.dart' show WorkspaceThreadIdentity;
export 'conversation_window.dart' show MessageContextLoadError;
export 'workspace_message_windows.dart' show ReadingAnchor;
import 'resource_snapshot_cache.dart';
import 'user_activity.dart';
import 'user_error.dart';
import 'workspace_entity_directory.dart';
import 'followed_threads_store.dart';
import 'raft_location.dart';
import 'raft_navigation_history.dart';
import 'navigation_registry.dart';
import 'workspace_navigation.dart';
import 'shared_draft_attachment.dart';
import 'message_window_snapshot.dart';
import 'message_history_pages.dart';
import 'message_history_events.dart';
import 'message_history_snapshots.dart';
import 'message_history_navigation.dart';
import 'message_history_positions.dart';
import 'message_history_summaries.dart';
import 'thread_window_snapshot.dart';
import 'attachment_image_repository.dart';
import 'cache_clear.dart';
import 'attachment_url_cache.dart';
import 'attachment_media.dart';
import 'attachment_retention_index.dart';

export 'attachment_media.dart' show WorkspaceAttachmentImageLease;
import '../platform/attachment_player_sessions.dart';
import 'upload_mime.dart';
import 'feature_flag_client_facts.dart';

/// Web `isThreadAbsentLookupError` (threadStore.ts): only the route's explicit
/// "no thread for this message" 404 means an empty thread. A 404 carrying a
/// `code` is absent only for `THREAD_NOT_FOUND`; without a `code` the legacy
/// error text decides. Every other failure (a lost parent channel is also a
/// 404) is a load error with Retry.
bool isThreadAbsentLookupError(Object? error) {
  if (error is! RaftApiException || error.status != 404) return false;
  if (error.details.containsKey('code')) {
    return error.details['code'] == 'THREAD_NOT_FOUND';
  }
  return error.message == 'No thread found for this message';
}

class WorkspaceController extends ChangeNotifier
    implements WorkspaceServiceAuthority, SessionScopeBinding {
  /// High-frequency socket events that never change workspace state.
  static const presenceEvents = {
    'agent:activity',
    'agent:seen',
    'agent:session',
    'machine:status',
    'machine:capabilities',
  };

  WorkspaceController(
    this.client, {
    WorkspaceCache? cache,
    this.presentationSource,
    this.mobileNavigation = false,
    this.ownsClient = true,
    this.restoreSharedAttachment,
    this.discardSharedScope,
    WorkspaceEntityDirectory? entityDirectory,
    FollowedThreadsStore? followedThreads,
    AttachmentImageByteStore? attachmentImageStore,
    AttachmentUrlCache? attachmentUrls,
    WorkspaceComposer? composer,
  }) : _presentationAuthority = presentationSource?.navigationAuthority {
    conversationReads = ConversationReadRepository(
      client,
      readState: () => readState,
      revokedChannels: () => _revokedChannels,
      channelId: () => channel?.id,
      threadChannelId: () => threadChannelId,
      mobileNavigation: () => mobileNavigation,
      mayMarkRead: _mayMarkRead,
      markRead: (id) => markRead(id),
      channelRows: () => [...channels, ...dms],
      messages: (id) => ledger.messages(id),
      isContext: (id) => messageWindows.isContext(id),
      hasNewer: () => hasNewer,
      save: (kind, id, value) => _save(kind, id, value),
      changed: notifyListeners,
      prefetch: () => prefetchLikelyChannels(),
      isDiskOnly: (id) => messageWindows.isDiskOnly(id),
      visibleIds: (id) => visibleIds[id],
      generation: () => ledger.generation,
      windowGeneration: (thread) =>
          thread ? threadGeneration : channelGeneration,
      isDisposed: () => _disposed,
      refreshUnread: () => refreshUnread(),
    );
    sessionScope = SessionScope(this, ownsMedia: presentationSource == null);
    channelRepository = ChannelRepository(
      client,
      channels: () => channels,
      dms: () => dms,
      generation: () => ledger.generation,
      identity: _syncIdentity,
      isDisposed: () => _disposed,
      revokedChannels: () => _revokedChannels,
      acceptLists: _acceptChannelLists,
      saveDirectory: (record) {
        _save('channels', '', record);
      },
      acceptSelection: _adoptAcceptedChannelSelection,
      patchSelected: (patch) {
        if (channel != null) channel = patch(channel!);
      },
      reloadLists: () => refreshChannels(),
      reloadRow: (id) => refreshChannel(id),
      revokeChannel: _revokeChannel,
      closeDeniedThread: (id) {
        if (_threadIdentity?.parentChannelId == id) closeThread();
      },
      changed: notifyListeners,
      setError: setError,
      quietFailure: _quietFailure,
    );
    apiGateway =
        presentationSource?.apiGateway ??
        RaftApiGateway(
          client,
          savedChanged: () {
            ++savedRevision;
            notifyListeners();
          },
          refreshUnread: () => refreshUnread(),
        );
    deviceStore = WorkspaceDeviceStore(
      client,
      cache: cache,
      isDisposed: () => _disposed,
      isChannelRevoked: (id) => _revokedChannels.contains(id),
      isServerRevoked: (id) => _revokedServers.contains(id),
      historyTicket: messageHistoryTicket,
      readFailed: () {
        if (!_disposed) error ??= 'Local workspace history is unavailable.';
      },
      writeFailed: (cause) {
        if (!_disposed) {
          error ??= MessageHistoryPages.saveError(cause);
          notifyListeners();
        }
      },
      purgeFailed: () {
        if (!_disposed) {
          // ignore: raft_lints/avoid_imperative_notice_state -- Cache-purge device failures raise the existing one-shot notice; the device service reports failure without owning UI state.
          setError(
            'Revoked workspace data could not be removed from this device.',
          );
        }
      },
    );
    sidebarRepository =
        presentationSource?.sidebarRepository ??
        SidebarRepository(
          client,
          order: () => sidebarOrder,
          setOrder: (value) => sidebarOrder = value,
          serverId: () => server?.id,
          loadAuthority: () =>
              jsonEncode([client.user?.id, server?.id, server?.string('role')]),
          isDisposed: () => _disposed,
          readDevice: () => _cached('sidebar-order', ''),
          saveDevice: (value) => _save('sidebar-order', '', value),
          changed: notifyListeners,
          reload: () => loadSidebar(),
        );
    this.composer =
        composer ??
        presentationSource?.composer ??
        WorkspaceComposer(
          owner: this,
          read: _cached,
          write: _save,
          authority: () => (
            client.origin,
            client.generation,
            client.user?.id,
            client.serverId,
            server?.string('role'),
            jsonEncode(server?.json['permissions']),
          ),
        );
    attachmentMedia =
        presentationSource?.attachmentMedia ??
        AttachmentMedia(
          scope: () => attachmentImageScope,
          get: (path, {query}) => client.get(path, query: query),
          post: (path, {data}) => client.post(path, data: data),
          isDisposed: () => _disposed,
          admitsImages: () =>
              client.user != null && server?.id == client.serverId,
          isRevoked: (id) => _revokedChannels.contains(id),
          retainedByHistory: _retainsAttachmentByHistory,
          imageStore: attachmentImageStore ?? AttachmentDiskCache.installed,
          urls: attachmentUrls,
        );
    MessageHistoryPages.attach(this);
    services = WorkspaceServices(
      this,
      source: presentationSource,
      isDisposed: () => _disposed,
      entityScope: _entityScope,
      panelIdentity: _panelCacheIdentity,
      channelFilesAuthority: _channelFilesAuthority,
      readEntities: cache == null ? null : _readEntities,
      writeEntities: cache == null ? null : _writeEntities,
      entityDirectory: entityDirectory,
      followedThreads: followedThreads,
    );
    // Directory changes are not forwarded to this notifier: agent heartbeats,
    // last-seen and machine status patches would rebuild every workspace
    // listener. Surfaces that render entities listen to [entityDirectory]
    // (or a [WorkspaceEntitySelection] of it) directly.
    if (services.ownsEntityDirectory) addListener(_entityAuthorityChanged);
    if (presentationSource == null) {
      this.composer.sends.attach(this, _sendChanged);
    }
    subscription = presentationSource == null
        ? client.events.listen(_event)
        : const Stream<RaftEvent>.empty().listen((_) {});
    // A route-local presentation shares its source's layers, which register.
    if (presentationSource == null) {
      _removeCacheClear = CacheClear.instance.register(
        'workspace-memory',
        clearRebuildableMemory,
      );
    }
  }

  VoidCallback? _removeCacheClear;
  late final SessionScope sessionScope;
  @override
  late final WorkspaceComposer composer;
  late final SidebarRepository sidebarRepository;
  late final ChannelRepository channelRepository;
  @override
  late final WorkspaceMessageWindows messageWindows =
      presentationSource?.messageWindows ??
      WorkspaceMessageWindows(
        authority: _messageWindowAuthority,
        presentation: _messageWindowPresentation,
        layout: _messageWindowLayout,
        sends: composer.sends,
        notRevoked: (id) => !_revokedChannels.contains(id),
      );

  WorkspaceController get _windowReceiver =>
      presentationSource?._windowReceiver ?? this;

  ConversationWindow? get messageWindow => messageWindows.channel(channel?.id);
  ConversationWindow? get threadWindow =>
      messageWindows.thread(threadParentChannelId, threadParentMessageId);

  MessageWindowAuthority? _messageWindowAuthority(
    ConversationWindowScope scope,
  ) {
    final resource = _threadChannelResource(scope.channelId);
    if (_disposed ||
        client.user == null ||
        server == null ||
        server!.id != client.serverId ||
        _revokedServers.contains(server!.id) ||
        _revokedChannels.contains(scope.channelId) ||
        resource == null ||
        !can('viewChannel', resource: resource)) {
      return null;
    }
    final accepted = messageWindows.accepted[scope.channelId];
    final authority = messageWindowAuthority(
      server!.string('role'),
      resource.json,
    );
    if (accepted != null &&
        !accepted.matches(authority, _replyToken(scope.channelId))) {
      return null;
    }
    return (
      navigationAuthority,
      ledger.generation,
      _replyToken(scope.channelId),
      authority,
      jsonEncode(server!.json['permissions']),
    );
  }

  (bool, bool) _messageWindowLayout(ConversationWindowScope scope) {
    final selected = scope.parentMessageId == null
        ? channel?.id == scope.channelId
        : threadParentChannelId == scope.channelId &&
              threadParentMessageId == scope.parentMessageId;
    return (
      selected,
      selected &&
          foreground &&
          _chatTabPresented &&
          (scope.parentMessageId == null ? _mainPresented : _threadPresented),
    );
  }

  ConversationWindowSnapshot _messageWindowPresentation(bool thread) {
    final rows = thread ? replies : messages;
    return ConversationWindowSnapshot(
      channelId: thread ? threadChannelId : channel?.id,
      rows: rows,
      timeline: timeline(thread: thread, rows: rows),
      parent: thread ? presentedThreadParent : null,
      loading: thread ? threadLoading : channelLoading,
      loadingOlder: loadingOlder,
      parentLoading: thread && threadParentLoading,
      resolving: thread && threadResolutionLoading,
      error: thread ? threadResolutionError : error,
      hasMore: thread ? threadHasMore : hasMore,
      hasNewer: thread ? messageWindows.contextHasNewer(threadChannelId) : hasNewer,
      historyLimited: thread ? threadHistoryLimited : historyLimited,
      highlightedMessageId: highlightedMessageId,
      contextLoadError: thread ? null : contextLoadError,
    );
  }

  /// "Clear cache": lets go of what this workspace keeps in memory and can
  /// rebuild: decoded attachment pictures nobody shows, signed attachment URLs
  /// already resolved, and the kept still pictures of videos. Pictures a
  /// widget holds, requests in flight and playing or held players stay.
  @visibleForTesting
  void clearRebuildableMemory() {
    attachmentMedia.trimRebuildable();
  }

  /// Borrowed editor controllers project messages but never own the session,
  /// membership recovery, server selection, socket resume, or client teardown.
  final bool ownsClient;
  @override
  final RaftClient client;
  late final RaftApiGateway apiGateway;
  @override
  late final WorkspaceDeviceStore deviceStore;
  @override
  WorkspaceCache? get cache => deviceStore.cache;

  /// Route-local presentation borrows the session and accepted stores. Only
  /// the source reduces socket events and owns server/bootstrap lifecycle.
  final WorkspaceController? presentationSource;
  final String? _presentationAuthority;
  bool presentationActive = true;
  final RestoreSharedDraftAttachment? restoreSharedAttachment;
  @override
  final Future<void> Function(
    String origin,
    String principal,
    String server,
    String? channel,
  )?
  discardSharedScope;
  late final WorkspaceServices services;
  @override
  WorkspaceEntityDirectory get entityDirectory => services.entityDirectory;

  /// Server-scoped followed threads, shared with borrowed controllers.
  @override
  FollowedThreadsStore get followedThreads => services.followedThreads;

  /// Web `useTranslationStore`: translation settings and the in-memory
  /// translation cache, created on first use.
  @override
  MessageTranslationStore get translations => services.translations;

  /// Web ThreadPanel in-thread search state (bar, query, matches), created on
  /// first use; a presentation mirror shares its source's.
  @override
  ThreadSearch get threadSearch => services.threadSearch;

  /// Web `useThreadAgentFollowerStore`: the agents following each thread.
  @override
  ThreadAgentFollowers get threadFollowers => services.threadFollowers;

  /// Web `useAnnouncementStore`: the account-level announcement queue,
  /// living as long as this account session.
  @override
  AnnouncementStore get announcements => services.announcements;

  /// Web `useOnboardingAnnouncementGateStore` (session memory per account).
  @override
  AnnouncementOnboardingGate get announcementGate => services.announcementGate;
  WorkspaceEntityScope? _entityScope() {
    final principal = client.user?.id;
    final serverId = client.serverId;
    if (_disposed ||
        principal == null ||
        serverId == null ||
        server?.id != serverId) {
      return null;
    }
    return WorkspaceEntityScope(
      origin: client.origin,
      principal: principal,
      serverId: serverId,
      generation: client.generation,
      role: server?.string('role') ?? '',
      capabilities: {
        if (can('viewAgents')) WorkspaceEntityKind.agents,
        if (can('viewMachines')) WorkspaceEntityKind.computers,
        if (can('viewMembers')) WorkspaceEntityKind.members,
      },
    );
  }

  Future<dynamic> _readEntities(
    WorkspaceEntityScope scope,
    WorkspaceEntityKind kind,
  ) => deviceStore.readEntities(scope, kind);

  void _writeEntities(
    WorkspaceEntityScope scope,
    WorkspaceEntityKind kind,
    Map<String, dynamic>? record,
  ) => deviceStore.writeEntities(scope, kind, record);

  @override
  Future<List<Map<String, dynamic>>> readDeviceTranslations(String serverId) =>
      deviceStore.readDeviceTranslations(serverId);

  @override
  void writeDeviceTranslations(
    String serverId,
    List<Map<String, dynamic>> entries,
  ) => deviceStore.writeDeviceTranslations(serverId, entries);

  @override
  Future<dynamic> readTranslationGate(String serverId) =>
      deviceStore.readTranslationGate(serverId);

  @override
  void saveTranslationGate(String serverId, Map<String, dynamic>? gate) =>
      deviceStore.saveTranslationGate(serverId, gate);

  void _entityAuthorityChanged() {
    if (_disposed || !services.ownsEntityDirectory) return;
    if (entityDirectory.synchronize() && entityDirectory.started) {
      // ignore: raft_lints/avoid_unreviewed_idle_work -- One-shot deferral out of a build or notification; the callback does not schedule another microtask itself.
      scheduleMicrotask(() {
        if (!_disposed) unawaited(entityDirectory.preload());
      });
    }
  }

  /// One media owner for the session and all borrowed presentations.
  @override
  late final AttachmentMedia attachmentMedia;

  /// Compatibility facade while attachment surfaces move to [attachmentMedia].
  int get retainedImageDecodedBytes =>
      attachmentMedia.retainedImageDecodedBytes;
  int get retainedImageCount => attachmentMedia.retainedImageCount;
  int get retainedImageEncodedBytes =>
      attachmentMedia.retainedImageEncodedBytes;
  AttachmentImageScope get attachmentImageScope => AttachmentImageScope(
    origin: client.origin,
    principal: client.user?.id ?? '',
    server: client.serverId ?? '',
    generation: client.generation,
    role: server?.string('role') ?? '',
  );

  /// Server-identity key for panel caches (account, origin, server, role and
  /// authentication generation). Channel switches, threads and tab changes do
  /// not change it; null while no signed-in server is selected.
  String? _panelCacheIdentity() {
    final principal = client.user?.id;
    final serverId = client.serverId;
    if (_disposed ||
        principal == null ||
        serverId == null ||
        server?.id != serverId) {
      return null;
    }
    return jsonEncode([
      client.origin,
      principal,
      serverId,
      client.generation,
      server?.string('role'),
    ]);
  }

  @override
  ServerBoundCache<String, Object> get agentTabCache => services.agentTabCache;
  @override
  ServerBoundCache<String, TaskHistorySnapshot> get taskHistoryCache =>
      services.taskHistoryCache;

  /// Channel access behind a cached Files list: the server identity plus the
  /// member's current capabilities for that channel. null (nothing shown, list
  /// dropped on the next synchronization) once the channel is gone, revoked or
  /// no longer viewable. Channel switches and thread windows are not part of it.
  String? _channelFilesAuthority(String channelId) {
    final identity = _panelCacheIdentity();
    if (identity == null || _revokedChannels.contains(channelId)) return null;
    final current = channel?.id == channelId ? channel : null;
    final row =
        current ??
        [...channels, ...dms].where((c) => c.id == channelId).firstOrNull;
    if (row == null || !can('viewChannel', resource: row)) return null;
    return jsonEncode([identity, row.id, row.json['channelCapabilities']]);
  }

  /// The controller-owned Files projection of [channelId]. The same store is
  /// returned on every visit, so a revisit paints the last list immediately
  /// and a refresh replaces it in place.
  @override
  SourceChannelFilesStore channelFilesStore(String channelId) =>
      services.channelFilesStore(channelId);

  // Per receiver, even when its media owner is borrowed from another page.
  late final AttachmentRetentionIndex attachmentRetentionIndex =
      AttachmentRetentionIndex(
        ledgerRevision: () => ledger.revision,
        stateStamp: () => _stateStamp,
        scope: () => attachmentImageScope,
        channels: () => channels,
        dms: () => dms,
        revokedChannels: () => _revokedChannels,
        canView: (row) => can('viewChannel', resource: row),
        messages: (id) => ledger.messages(id),
      );

  bool _retainsAttachmentByHistory(AttachmentImageKey key) =>
      attachmentRetentionIndex.retains(key);

  /// Number of complete history scans used for attachment retention.
  @visibleForTesting
  int get debugRetainedAttachmentIndexBuilds =>
      attachmentRetentionIndex.debugBuilds;

  WorkspaceAttachmentImageLease acquireAttachmentImage(
    AttachmentImageKey key, {
    required AttachmentImageLoader load,
    required bool Function() authorized,
    bool foreground = false,
    bool bestAvailable = false,
  }) => attachmentMedia.acquireImage(
    key,
    load: load,
    authorized: authorized,
    foreground: foreground,
    bestAvailable: bestAvailable,
  );

  /// Synchronous lookup; never loads an image.
  WorkspaceAttachmentImageLease? peekAttachmentImage(
    AttachmentImageKey key, {
    required bool Function() authorized,
  }) => attachmentMedia.peekImage(key, authorized: authorized);

  AttachmentDiskCache? get attachmentDiskCache => attachmentMedia.diskCache;

  AttachmentImageStoreKey attachmentCacheKey(
    Map<String, dynamic> metadata,
    String kind, {
    required String channelId,
  }) => attachmentMedia.cacheKey(metadata, kind, channelId: channelId);

  /// Set by the host from its actual logical width before bootstrap. Home
  /// retains selection/drafts, but is not an open conversation/read surface.
  bool mobileNavigation;
  @override
  final messageSync = MessageSync();
  @override
  final threadRepliesSync = ThreadRepliesSync();
  @override
  final notificationPrefsSync = NotificationPrefsSync();
  bool syncCoreNotificationPrefsEnabled = false;
  String? _replyIdentity;

  /// Fail-closed fallback for an authority event without a channel id.
  int _replyAuthorityEpoch = 0;

  /// Per-channel authority epochs. A membership/authority change for one
  /// channel retires only that channel's windows, thread windows, reply
  /// scopes and in-flight loads; every other channel keeps its cache.
  final Map<String, int> _channelReplyEpochs = {};

  String _syncIdentity() => jsonEncode([
    client.origin,
    client.generation,
    client.serverId,
    client.user?.id,
    server?.string('role'),
  ]);

  /// Authority token for data owned by [channelId] (its message window, its
  /// thread windows and reply summaries).
  String _replyToken(String? channelId) => jsonEncode([
    _syncIdentity(),
    _replyAuthorityEpoch,
    channelId,
    _channelReplyEpochs[channelId] ?? 0,
  ]);
  void _ensureSyncIdentity() {
    final next = _syncIdentity();
    if (_replyIdentity == next) return;
    final hadIdentity = _replyIdentity != null;
    _messageFlagRequest++;
    _replyIdentity = next;
    threadRepliesSync.reset();
    notificationPrefsSync.reset();
    syncCoreNotificationPrefsEnabled = false;
    if (hadIdentity) _summariesByChannel.clear();
  }

  /// Retires one channel's reply authority (Source refreshes only the
  /// affected channel row on a membership event). Its reply scopes and
  /// thread windows go now; its message window is dropped on next use by the
  /// token mismatch. The open channel keeps its displayed summaries until its
  /// own refresh replaces them; a real revocation clears them in
  /// [_revokeChannel].
  void _invalidateChannelReplies(String id) {
    _channelReplyEpochs[id] = (_channelReplyEpochs[id] ?? 0) + 1;
    threadRepliesSync.revokeChannel(id);
    messageWindows.invalidateParentThreads(id);
    if (channel?.id != id) _summariesByChannel.remove(id);
  }

  void _invalidateAllChannelReplies() {
    _replyAuthorityEpoch++;
    threadRepliesSync.reset();
    messageWindows.clearThreads();
    _summariesByChannel.removeWhere((id, _) => id != channel?.id);
  }

  /// Whether a member list change can change this principal's visibility of
  /// the channel (Source resource views fail closed on the same rule).
  bool _membershipScoped(String id) {
    final known = [...channels, ...dms].where((c) => c.id == id).firstOrNull;
    if (known == null) return true;
    return const {'private', 'dm', 'joint', 'thread'}.contains(known.type);
  }

  void mergeThreadSummaries(String id, dynamic rows) => _summariesByChannel
      .putIfAbsent(id, () => {})
      .addAll(
        _hydrateThreadSummaries(rows, id, expectedToken: _replyToken(id)),
      );

  Map<String, dynamic> _hydrateThreadSummaries(
    dynamic raw,
    String parentChannelId, {
    String? expectedToken,
  }) {
    _ensureSyncIdentity();
    if (expectedToken != null &&
        expectedToken != _replyToken(parentChannelId)) {
      return {};
    }
    if (raw is! Map) return {};
    final id = client.serverId, principal = client.user?.id;
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: id == null || principal == null
              ? Map<String, dynamic>.from(entry.value)
              : threadRepliesSync.hydrateSummary(
                  id,
                  principal,
                  parentChannelId,
                  entry.key as String,
                  Map<String, dynamic>.from(entry.value),
                ),
    };
  }

  bool _replyCurrent(String token, ThreadRebaselineRequest request) =>
      !_disposed &&
      token == _replyToken(request.parentChannelId) &&
      !_revokedChannels.contains(request.parentChannelId) &&
      !_revokedChannels.contains(request.threadChannelId);

  Future<void> _rebaselineThread(ThreadRebaselineRequest request) async {
    final token = _replyToken(request.parentChannelId);
    try {
      // Exact mounted compatibility snapshot used by threadRepliesSyncDomain.
      final values = await Future.wait([
        client.get(
          '/messages/channel/${request.threadChannelId}',
          query: {'limit': inlineReplyCap},
        ),
        client.get(
          '/channels/${request.parentChannelId}/threads/${request.parentMessageId}',
        ),
      ]);
      if (!_replyCurrent(token, request)) return;
      final page = values[0], summary = values[1];
      if (page is! Map ||
          page['messages'] is! List ||
          summary is! Map ||
          summary['threadChannelId'] != request.threadChannelId ||
          summary['replyCount'] is! int ||
          summary['replyCount'] < 0) {
        return;
      }
      final previews = (page['messages'] as List)
          .map((m) => projectThreadReply(m, snapshot: true))
          .whereType<Map<String, dynamic>>();
      final result = threadRepliesSync.completeRebaseline(
        request,
        replies: previews,
        replyCount: summary['replyCount'],
        historyLimited: page['historyLimited'] == true,
      );
      if (result.kind != 'applied' || result.summary == null) return;
      _summariesByChannel.putIfAbsent(
        request.parentChannelId,
        () => {},
      )[request.parentMessageId] = result.summary;
      MessageHistorySummaries.rebaselined(this, request, result.summary);
      _applyThreadUnread(request.threadChannelId, result.summary);
      if (channel?.id == request.parentChannelId) _saveWindow(channel!.id);
      notifyListeners();
    } catch (_) {
      // No guessed transport or fabricated completion. The next eligible
      // producer frame can retry its authorized compatibility snapshot.
    } finally {
      threadRepliesSync.release(request);
    }
  }

  void _consumeThreadUpdate(Map<String, dynamic> payload) {
    _ensureSyncIdentity();
    final id = client.serverId, principal = client.user?.id;
    if (id == null || principal == null) return;
    if (payload['serverId'] != null && payload['serverId'] != id) return;
    final parentId = payload['parentMessageId'];
    final latest = payload['latestReply'];
    final anchor = latest is Map ? latest['conversationContext'] : null;
    final parentChannel = anchor is Map ? anchor['parentChannelId'] : null;
    if (_revokedChannels.contains(payload['threadChannelId']) ||
        _revokedChannels.contains(parentChannel)) {
      return;
    }
    if (parentId is String &&
        channel != null &&
        _revokedChannels.contains(channel!.id)) {
      return;
    }
    final result = threadRepliesSync.consume(
      payload,
      serverId: id,
      principalId: principal,
    );
    if (result.summary != null && parentId is String) {
      final owner = _summaryOwner(payload, parentId);
      if (owner != null && !_revokedChannels.contains(owner)) {
        _summariesByChannel.putIfAbsent(owner, () => {})[parentId] =
            result.summary;
        MessageHistorySummaries.store(this, owner, {parentId: result.summary});
      }
      _applyThreadUnread(payload['threadChannelId'], payload);
    }
    if (result.request != null) unawaited(_rebaselineThread(result.request!));
  }

  /// The parent channel whose reply rows a `thread:updated` summary belongs
  /// to: the wire anchor first, else the channel already holding the parent.
  String? _summaryOwner(Map<String, dynamic> payload, String parentId) {
    final latest = payload['latestReply'];
    final anchor = latest is Map ? latest['conversationContext'] : null;
    if (anchor is Map && anchor['parentChannelId'] is String) {
      return anchor['parentChannelId'] as String;
    }
    final window = payload['syncCoreReplyWindow'];
    final discussion = window is Map ? window['discussion'] : null;
    final scope = discussion is Map ? discussion['parentScopeKey'] : null;
    if (scope is Map && scope['scopeId'] is String) {
      return scope['scopeId'] as String;
    }
    final current = channel?.id;
    if (current != null &&
        (_summariesByChannel[current]?.containsKey(parentId) == true ||
            ledger.contains(current, parentId))) {
      return current;
    }
    for (final entry in _summariesByChannel.entries) {
      if (entry.value.containsKey(parentId)) return entry.key;
    }
    for (final entry in visibleIds.entries) {
      if (entry.value.contains(parentId)) return entry.key;
    }
    return null;
  }

  /// A thread summary carries the server's own per-thread unread count; it
  /// replaces only a count the unread snapshot already tracks.
  void _applyThreadUnread(dynamic threadChannelId, dynamic summary) =>
      conversationReads.applyThreadUnread(threadChannelId, summary);

  void _consumeNotificationPrefs(dynamic payload) {
    _ensureSyncIdentity();
    var update = readNotificationPrefsUpdate(payload);
    if (update == null ||
        update['serverId'] != client.serverId ||
        client.user == null) {
      return;
    }
    if (syncCoreNotificationPrefsEnabled) {
      update = notificationPrefsSync.consume(update);
      if (update == null) return;
    }
    final accepted = update;
    if (accepted['type'] == 'server') {
      final version = accepted['prefsVersion'];
      RaftRecord patch(RaftRecord value) {
        if (value.id != accepted['serverId']) return value;
        final prior = value.json['notificationPrefsVersion'];
        if (prior is int && version is int && version < prior) return value;
        return RaftRecord({
          ...value.json,
          'serverPushMuted': accepted['serverPushMuted'],
          'notificationPrefsVersion': ?version,
        });
      }

      servers = servers.map(patch).toList();
      if (server != null) server = patch(server!);
    } else if (!channelRepository.applyNotificationPrefs(accepted)) {
      return;
    }
    refreshUnread();
  }

  /// Source socketBridge `readMessageDisplayPrefsUpdate`: null unless the
  /// frame carries a string `serverId`/`scopeId` and a boolean
  /// `prefs.collapseLongMessages`.
  static ({String serverId, String channelId, bool collapse, int? version})?
  readMessageDisplayPrefsUpdate(dynamic payload) =>
      ChannelRepository.readMessageDisplayPrefsUpdate(payload);

  /// Source `applyMessageDisplayPrefsState` for one row: a patch older than
  /// the row's `displayPrefsVersion` is ignored.
  static RaftChannel applyMessageDisplayPrefsToChannel(
    RaftChannel value, {
    required bool collapse,
    int? version,
  }) => ChannelRepository.applyMessageDisplayPrefsToChannel(
    value,
    collapse: collapse,
    version: version,
  );

  /// Source socketBridge `message_display_prefs:updated`: written onto the
  /// channel row so chat folding follows another device's toggle.
  void _consumeMessageDisplayPrefs(dynamic payload) =>
      channelRepository.consumeMessageDisplayPrefs(payload);

  @override
  bool syncCoreMessagesEnabled = false;

  /// Web serverFeatureFlags `remote_computer_upgrade_v2`: whether the
  /// Computer detail may offer the one-click upgrade (fail-closed).
  static const remoteComputerUpgradeFlag = 'remote_computer_upgrade_v2';
  bool remoteComputerUpgradeEnabled = false;

  /// Web `AGENT_MIGRATION_FEATURE_FLAG_KEY` (`useAgentMigrationUiEnabled`):
  /// the "Move to another computer" action exists only while it is on.
  static const agentMigrationFlag = 'agent_migration_v0';

  /// Web `RUNTIME_FORM_V2_WEB_FLAG_KEY` (default off): the agent runtime
  /// editor presents the protocol-v2 server form only while it is on.
  static const runtimeFormV2WebFlag = 'runtime_form_v2_web';

  /// Both fail closed and ride the same evaluation as the sync flags (no
  /// request of their own).
  bool agentMigrationEnabled = false, runtimeFormV2WebEnabled = false;
  int _messageFlagRequest = 0;

  @override
  Future<void> refreshMessageSyncFlag() async {
    _ensureSyncIdentity();
    final request = ++_messageFlagRequest;
    final generation = client.generation, principal = client.user?.id;
    final identity = _syncIdentity();
    final id = client.serverId;
    if (id == null || principal == null) return;
    try {
      final result = await client.post(
        '/feature-flags/evaluate',
        data: featureFlagEvaluateBody(
          keys: [
            'sync_core_messages_v0',
            notificationPrefsFlag,
            remoteComputerUpgradeFlag,
            agentMigrationFlag,
            runtimeFormV2WebFlag,
          ],
          serverId: id,
        ),
      );
      if (_disposed ||
          request != _messageFlagRequest ||
          generation != client.generation ||
          principal != client.user?.id ||
          id != client.serverId ||
          identity != _syncIdentity()) {
        return;
      }
      final enabled =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == 'sync_core_messages_v0' && f['enabled'] == true,
          );
      if (enabled != syncCoreMessagesEnabled) messageSync.reset();
      syncCoreMessagesEnabled = enabled;
      final prefsEnabled =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == notificationPrefsFlag && f['enabled'] == true,
          );
      if (prefsEnabled != syncCoreNotificationPrefsEnabled) {
        notificationPrefsSync.reset();
      }
      syncCoreNotificationPrefsEnabled = prefsEnabled;
      remoteComputerUpgradeEnabled =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) =>
                f['key'] == remoteComputerUpgradeFlag && f['enabled'] == true,
          );
      bool evaluated(String key) =>
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == key && f['enabled'] == true,
          );
      final migration = evaluated(agentMigrationFlag);
      final runtimeV2 = evaluated(runtimeFormV2WebFlag);
      final flagsChanged =
          migration != agentMigrationEnabled ||
          runtimeV2 != runtimeFormV2WebEnabled;
      agentMigrationEnabled = migration;
      runtimeFormV2WebEnabled = runtimeV2;
      if (flagsChanged) notifyListeners();
    } catch (_) {
      if (!_disposed &&
          request == _messageFlagRequest &&
          identity == _syncIdentity()) {
        syncCoreNotificationPrefsEnabled = false;
        notificationPrefsSync.reset();
        if (agentMigrationEnabled || runtimeFormV2WebEnabled) {
          agentMigrationEnabled = runtimeFormV2WebEnabled = false;
          notifyListeners();
        }
      }
      // Unknown capability never authorizes the gated preference path.
    }
  }

  /// Writes every pending (debounced) change and completes once all queued
  /// device writes have landed.
  Future<void> flushCache() async {
    await MessageHistorySnapshots.flush(this);
    await MessageHistoryPages.storage(cache)?.receiver.settled;
    await MessageHistoryPages.storage(cache)?.positionsSettled;
    services.flushDevice();
    await Future.wait([deviceStore.settled, composer.flushed]);
  }

  /// Stops all further device writes of this workspace and completes once
  /// the writes already queued have landed. The caller then clears the
  /// account's device data.
  Future<void> retireCache() {
    return Future.wait([deviceStore.retire(), composer.flushed]);
  }

  Map<String, String> get drafts =>
      !composer.ownedBy(this) && (server == null || _disposed)
      ? const {}
      : composer.drafts;
  Set<String> get _revokedChannels => sessionScope.revokedChannels;
  Set<String> get _revokedServers => sessionScope.revokedServers;
  Object? _presentationOwner;
  bool _mainPresented = true, _threadPresented = true;
  Object? _tabPresentationOwner;
  bool _chatTabPresented = true;

  /// Channel tabs and folded panels are independent presentation owners.
  /// Neither loaded data nor an offstage retained editor admits a read receipt.
  void setChatTabPresentation(Object owner, bool visible) {
    _tabPresentationOwner = owner;
    _chatTabPresented = visible;
    if (presentationSource != null) {
      if (presentationActive) {
        presentationSource!.setChatTabPresentation(owner, visible);
      }
    }
  }

  void releaseChatTabPresentation(Object owner) {
    presentationSource?.releaseChatTabPresentation(owner);
    if (!identical(owner, _tabPresentationOwner)) return;
    _tabPresentationOwner = null;
    _chatTabPresented = true;
  }

  /// Mounted layout admission, separate from accepted message windows. This
  /// changes synchronously without notifying/rebuilding the controller tree.
  void setConversationPresentation(
    Object owner, {
    required bool main,
    required bool thread,
  }) {
    _presentationOwner = owner;
    _mainPresented = main;
    _threadPresented = thread;
    if (presentationSource != null) {
      if (presentationActive) {
        presentationSource!.setConversationPresentation(
          owner,
          main: main,
          thread: thread,
        );
      }
    }
  }

  void releaseConversationPresentation(Object owner) {
    presentationSource?.releaseConversationPresentation(owner);
    if (!identical(owner, _presentationOwner)) return;
    _presentationOwner = null;
    _mainPresented = _threadPresented = true;
  }

  /// This session owns one window; pages and platform adapters only borrow it.
  /// Server selection creates it before UI; standalone views can borrow a
  /// passive projection before selection. Neither path starts work by reading.
  @override
  @override
  SourceActivityUnreadStore get activityUnread => services.activityUnread;

  /// The existing session projection; reading it never constructs or starts it.
  @override
  SourceActivityUnreadStore? get activityUnreadIfBound =>
      services.activityUnreadIfBound;

  final foregroundChanges = ValueNotifier<bool>(true);

  /// Counts returns to the foreground that reached [resumeLiveSession]; views
  /// that own live summaries (the server menu's Activity count) refresh on it.
  final resumes = ValueNotifier<int>(0);
  bool foreground = true;
  void setForeground(bool value) {
    foreground = value;
    if (!value) RaftUserActivity.forget();
    foregroundChanges.value = value;
    if (value) {
      if (channel != null && !hasNewer) markRead(channel!.id);
      if (threadChannelId != null) markRead(threadChannelId!);
    }
  }

  @override
  void resetServerProjection() {
    historyLimited = threadHistoryLimited = false;
    channel = null;
    channels = [];
    dms = [];
    unread = {};
    mentions = {};
    newFlags = {};
    _latestActivity.clear();
    threadParent = null;
    threadChannelId = null;
    _summariesByChannel.clear();
    highlightedMessageId = null;
  }

  @override
  void clearSessionPrefetch() => _prefetched.clear();

  void revokeServer(String id) => sessionScope.revokeServer(id);

  @override
  void closeRevokedServerProjection() {
    server = null;
    sidebarOrder = {};
    error = null;
    _messageFlagRequest++;
    if (ownsClient) client.selectServer(null);
    loading = false;
    channelLoading = false;
    threadLoading = false;
  }

  Future<dynamic> _cached(String kind, String id, {String? server}) =>
      deviceStore.read(kind, id, server: server);

  Future<void> _save(
    String kind,
    String id,
    dynamic value, {
    String? server,
    bool requiredSuccess = false,
  }) => deviceStore.write(
    kind,
    id,
    value,
    server: server,
    requiredSuccess: requiredSuccess,
  );

  void saveDraft(String text, {bool thread = false}) {
    final source = presentationSource;
    if (source != null) {
      if (_presentationAuthority == source.navigationAuthority) {
        source._savePresentedDraft(draftScope(thread: thread), text);
      }
      return;
    }
    _savePresentedDraft(draftScope(thread: thread), text);
  }

  void _savePresentedDraft(String? scope, String text) {
    if (scope == null || _disposed || _revokedChannels.contains(scope)) return;
    drafts[scope] = text;
    unawaited(_saveDraftScope(scope));
  }

  Future<void> _saveDraftScope(String scope, {bool requiredSuccess = false}) =>
      composer.saveScope(scope, requiredSuccess: requiredSuccess);

  Future<void> stageSharedDraft(
    String text,
    List<SharedDraftAttachment> files, {
    String? sourceToken,
  }) {
    final scope = draftScope();
    if (scope == null) throw const RaftApiException('Choose a conversation.');
    return composer.stageSharedDraft(
      scope,
      text,
      files,
      sourceToken: sourceToken,
      persist: _saveDraftScope,
    );
  }

  void updateDraftFromShare(String text) {
    final scope = draftScope();
    if (scope == null) return;
    saveDraft(text);
    _draftRevisions[scope] = (_draftRevisions[scope] ?? 0) + 1;
    notifyListeners();
  }

  Map<String, int> get _draftRevisions => composer.revisions;
  int draftRevision({bool thread = false}) =>
      _draftRevisions[draftScope(thread: thread)] ?? 0;
  ValueListenable<int> draftChanges({bool thread = false}) =>
      composer.changes(draftScope(thread: thread));

  /// Capture the common session facts once; the window owner captures its
  /// own epochs. A caller supplies only the operation-specific selection rule.
  MessageWindowRequest _windowRequest(
    String id, {
    bool thread = false,
    bool checkNavigation = false,
    bool Function()? allowed,
  }) {
    final parent = thread ? threadParentChannelId : id;
    final reply = _replyToken(parent), authority = _windowAuthority();
    final revision = navigationRevision;
    return messageWindows.request(
      thread: thread,
      allowed: () =>
          reply == _replyToken(parent) &&
          authority == _windowAuthority() &&
          !_revokedChannels.contains(id) &&
          (!checkNavigation || revision == navigationRevision) &&
          (allowed?.call() ?? true),
    );
  }

  Future<void> _restoreDraft(String scope) async {
    final generation = ledger.generation;
    await composer.restore(
      scope,
      current: () => generation == ledger.generation && !_disposed,
      restoreFiles: (files) async {
        final principal = client.user?.id, origin = client.origin;
        if (restoreSharedAttachment == null || principal == null) return;
        await composer.uploads.restore(
          scope,
          files,
          read: (reference) =>
              restoreSharedAttachment!(reference, origin, principal),
        );
      },
      restored: notifyListeners,
    );
  }

  String _windowAuthority() =>
      messageWindowAuthority(server?.string('role'), channel?.json ?? const {});

  /// Device writes stop before logout purges are queued.
  bool get cacheWritable => deviceStore.writable;
  Object messageHistoryTicket(String id) => _replyToken(id);
  void rejectHistoryRead(String id) => _windowReceiver._revokeChannel(id);
  Future<void> saveHistoryWindow(String id, {bool thread = false}) =>
      _windowReceiver._saveWindow(id, thread: thread);

  Future<void> _saveWindow(String id, {bool thread = false, bool coalesce = false}) =>
      MessageHistorySnapshots.save(
        this, id, thread: thread, coalesce: coalesce,
        identity: _threadIdentity, replyToken: _replyToken, write: _save,
      );

  /// Disk windows retain canonical versions already held in memory. Only the
  /// bootstrap replaces visible membership and starts from disk summaries.
  bool _restoreCachedTail(
    String id,
    dynamic page,
    MessageWindowRequest request, {
    String? replyAuthority,
    bool replace = false,
  }) {
    if (!MessageHistorySnapshots.restore(this, id, page, request, replace: replace,
        allowed: () => !_revokedServers.contains(server?.id))) {
      return false;
    }
    _summariesByChannel[id] = {
      ..._hydrateThreadSummaries(
        page['threadSummaries'],
        id,
        expectedToken: replyAuthority ?? _replyToken(id),
      ),
      if (!replace) ...?_summariesByChannel[id],
    };
    return true;
  }

  late final StreamSubscription<RaftEvent> subscription;
  MessageLedger get ledger => messageWindows.ledger;
  final _reactionViewer = ReactionViewerLedger();
  @override
  ReactionViewerLedger get reactionViewer =>
      presentationSource?.reactionViewer ?? _reactionViewer;
  final Map<String, Future<void>> _reactionWrites = {};
  final Map<String, Future<void>> _viewerLoads = {};
  Map<String, List<UploadDraft>> get _uploads => composer.uploads.byScope;

  bool _disposed = false;
  int _stateStamp = 0;
  @override
  void notifyListeners() {
    _stateStamp++;
    if (presentationSource == null) attachmentMedia.synchronize();
    if (!_disposed) {
      _syncScopeVisits();
      _ensureSyncIdentity();
      if (presentationSource == null) messageWindows.synchronize();
      super.notifyListeners();
    }
  }

  /// Outside-channel mention actions from the latest send per draft scope
  /// (Web MessageInput `pendingMentionActions`).
  final Map<String, List<Map<String, dynamic>>> pendingMentionActions = {};

  List<Map<String, dynamic>> pendingMentionsFor({bool thread = false}) =>
      (presentationSource?.pendingMentionActions ??
          pendingMentionActions)[draftScope(thread: thread)] ??
      const [];

  void dismissPendingMention(String resolutionId, {bool thread = false}) {
    if (presentationSource != null) {
      presentationSource!.dismissPendingMention(resolutionId, thread: thread);
      return;
    }
    final scope = draftScope(thread: thread);
    final list = pendingMentionActions[scope];
    if (list == null) return;
    pendingMentionActions[scope!] = [
      for (final a in list)
        if (a['resolutionId'] != resolutionId) a,
    ];
    notifyListeners();
  }

  /// Send-receipt warnings of the latest send per draft scope (Web MessageInput
  /// `unresolvedMentionHandles` / `deliveryWarnings`): handles the server could
  /// not resolve to a member, and whether a DM's agent is stopped.
  final Map<String, ({List<String> unresolved, bool agentStopped})>
  sendWarnings = {};

  ({List<String> unresolved, bool agentStopped}) sendWarningsFor({
    bool thread = false,
  }) =>
      (presentationSource?.sendWarnings ?? sendWarnings)[draftScope(
        thread: thread,
      )] ??
      (unresolved: const [], agentStopped: false);

  /// The banner's X (Web `dismissUnresolvedMentionWarning` /
  /// `dismissDeliveryWarning`).
  void dismissSendWarnings({bool thread = false}) {
    if (presentationSource != null) {
      presentationSource!.dismissSendWarnings(thread: thread);
      return;
    }
    final scope = draftScope(thread: thread);
    if (scope == null || sendWarnings.remove(scope) == null) return;
    notifyListeners();
  }

  /// `POST /messages/mention-actions/execute`; returns ids whose result
  /// status matches the action (`queued` for notify, `delivered` for add).
  Future<Set<String>> executeMentionActions(
    String action,
    List<String> resolutionIds,
  ) async => (await executeMentionActionResults(action, resolutionIds)).entries
      .where((r) => mentionActionSucceeded(action, r.value))
      .map((r) => r.key)
      .toSet();

  /// Web `mentionActionSucceeded`.
  static bool mentionActionSucceeded(String action, Map? result) =>
      result?['status'] == (action == 'notify' ? 'queued' : 'delivered');

  /// The per-row results of `POST /messages/mention-actions/execute`, by
  /// resolution id (a row the server did not answer for is absent).
  Future<Map<String, Map<String, dynamic>>> executeMentionActionResults(
    String action,
    List<String> resolutionIds,
  ) async {
    final value = await command(
      'POST',
      '/messages/mention-actions/execute',
      data: {'action': action, 'resolutionIds': resolutionIds},
    );
    return {
      if (value is Map && value['results'] is List)
        for (final r in (value['results'] as List).whereType<Map>())
          if (r['resolutionId'] is String)
            r['resolutionId'] as String: Map<String, dynamic>.from(r),
    };
  }

  String? draftScope({bool thread = false}) => thread
      ? (threadParentMessageId == null ? null : 'thread:$threadParentMessageId')
      : channel?.id;
  bool get conversationPaused =>
      channel != null && channelConversionBlocksSending(channel!.json);
  List<UploadDraft> uploads({bool thread = false}) =>
      (presentationSource?._uploads ?? _uploads)[draftScope(thread: thread)] ??
      [];
  bool uploadsReady({bool thread = false}) =>
      !composer.sends.queued(draftScope(thread: thread)) &&
      uploads(thread: thread)
          .every((u) => u.id != null || u.queued && u.error == null);

  /// Web MessageInput composer error banner per draft scope. Each message is a
  /// [CauseNotice] bound to the composer visit that raised it (Web resets the
  /// banner when the channel changes) and, for send blocks, to the upload
  /// state that caused it, so it cannot outlive its cause. The store lives on
  /// the session source; the visit is this controller's.
  final CauseNotices<String> _composerNotices = CauseNotices<String>();
  String? composerErrorFor({bool thread = false}) {
    final scope = draftScope(thread: thread);
    return scope == null
        ? null
        : (presentationSource?._composerNotices ?? _composerNotices).messageFor(
            scope,
          );
  }

  /// Web MessageInput `setError` outside a file selection (for example the
  /// folder notices of a drop). Null clears the banner. [whileTrue] is the
  /// cause: the banner disappears the moment it turns false.
  void setComposerError(
    String? message, {
    bool thread = false,
    bool Function()? whileTrue,
  }) {
    final scope = draftScope(thread: thread);
    if (scope == null) return;
    if (_raiseComposerNotice(scope, message, whileTrue: whileTrue)) {
      notifyListeners();
    }
  }

  bool _raiseComposerNotice(
    String scope,
    String? message, {
    bool Function()? whileTrue,
  }) {
    final visit = _visitOf(scope);
    return (presentationSource?._composerNotices ?? _composerNotices).raise(
      scope,
      message,
      whileTrue: () => visit == _visitOf(scope) && (whileTrue?.call() ?? true),
    );
  }

  /// Composer visits: a draft scope is "visited" from the moment it becomes
  /// the open channel / thread until another one replaces it. Notices record
  /// the visit they were raised in and read as gone in a later one (Web
  /// MessageInput resets its banners on channel change).
  final Map<String, int> _scopeVisits = {};
  String? _visitedChannelScope, _visitedThreadScope;

  int _visitOf(String scope) {
    _syncScopeVisits();
    return _scopeVisits[scope] ?? 0;
  }

  void _syncScopeVisits() {
    final channelScope = draftScope(), threadScope = draftScope(thread: true);
    if (channelScope != _visitedChannelScope) {
      _leaveScope(_visitedChannelScope);
      _visitedChannelScope = channelScope;
    }
    if (threadScope != _visitedThreadScope) {
      _leaveScope(_visitedThreadScope);
      _visitedThreadScope = threadScope;
    }
  }

  void _leaveScope(String? scope) {
    if (scope == null) return;
    _scopeVisits[scope] = (_scopeVisits[scope] ?? 0) + 1;
    // Web resets the delivery warnings with the channel.
    (presentationSource?.sendWarnings ?? sendWarnings).remove(scope);
  }

  /// Shared content hand-off (docs/sharing-evidence.md): the composer opens
  /// from device data and the destination is checked afterwards. While a scope
  /// is held, Send is off: `null` = still checking, a string = the check
  /// refused it and this notice (an English key) shows on the composer. The
  /// draft and the staged files stay either way.
  Map<String, String?> get _shareHolds => composer.uploads.holds;
  Map<String, String?> get shareHolds =>
      presentationSource?.shareHolds ?? _shareHolds;
  bool sharedBlocked({bool thread = false}) =>
      !thread && shareHolds.containsKey(draftScope());
  String? shareNoticeFor({bool thread = false}) =>
      thread ? null : shareHolds[draftScope()];

  void holdShared(String scope) {
    final source = presentationSource;
    if (source != null) return source.holdShared(scope);
    if (_shareHolds.containsKey(scope)) return;
    _shareHolds[scope] = null;
    notifyListeners();
  }

  /// The check passed (or could not be made: the server still decides on send).
  void releaseShared(String scope) {
    final source = presentationSource;
    if (source != null) return source.releaseShared(scope);
    if (!_shareHolds.containsKey(scope) || _shareHolds[scope] != null) return;
    _shareHolds.remove(scope);
    notifyListeners();
  }

  /// The check refused the destination: Send stays off and [notice] shows.
  void blockShared(String scope, String notice) {
    final source = presentationSource;
    if (source != null) return source.blockShared(scope, notice);
    if (_disposed || _shareHolds[scope] == notice) return;
    _shareHolds[scope] = notice;
    notifyListeners();
  }

  /// A destination that does not exist on the server yet (a new DM): the
  /// composer opens on this local row; [adoptResolvedDm] swaps in the real one.
  static RaftChannel pendingDm({
    required String key,
    required String serverId,
    required String name,
  }) => RaftChannel({
    'id': 'pending-dm:$key',
    'name': name,
    'type': 'dm',
    'joined': true,
    'serverId': serverId,
    'peerDisplayName': name,
    'pendingDm': true,
  });
  static bool isPendingDm(RaftChannel? c) => c?.json['pendingDm'] == true;

  /// The new DM exists now: its draft, staged files and hold move from the
  /// local row to [real], which takes its place in the lists and, when open,
  /// as the selection.
  Future<void> adoptResolvedDm(String pendingId, RaftChannel real) async {
    final source = presentationSource;
    if (source != null) return source.adoptResolvedDm(pendingId, real);
    if (_disposed) return;
    final wasOpen = channel?.id == pendingId;
    composer.adoptScope(pendingId, real.id);
    channelRepository.recordRowWrite(real.id);
    if (wasOpen) channel = real;
    _putChannelRow(real);
    notifyListeners();
    if (wasOpen) {
      await selectChannel(
        [
          ...channels,
          ...dms,
        ].firstWhere((c) => c.id == real.id, orElse: () => real),
        autoRead: false,
      );
    }
  }

  /// A joined copy of a public channel's row while its join is in flight; the
  /// original goes back when [joined] is false.
  void putSharedChannelRow(RaftChannel row) {
    final source = presentationSource;
    if (source != null) return source.putSharedChannelRow(row);
    channelRepository.recordRowWrite(row.id);
    _putChannelRow(row);
  }

  /// Server `LEGACY_ATTACHMENT_SAFE_LIMIT_BYTES`: the multipart request must
  /// stay below the edge request-body boundary.
  static const multipartUploadSafeLimitBytes = 90 * 1024 * 1024;

  /// The file ceiling this client can honour from an upload-capabilities
  /// body. With direct uploads enabled the server advertises the plan's
  /// single-file `maxBytes`, but this client always posts multipart, so the
  /// legacy transport ceiling applies. Null when the body is unusable.
  static int? uploadLimitFromCapabilities(dynamic value) {
    final max = value is Map ? value['maxBytes'] : null;
    if (max is! num || !max.isFinite || max <= 0) return null;
    final bytes = max.toInt();
    return value['directUploadEnabled'] == true &&
            bytes > multipartUploadSafeLimitBytes
        ? multipartUploadSafeLimitBytes
        : bytes;
  }

  /// Web `resolveAttachmentUploadLimitBytes`: the server ceiling from
  /// `GET /attachments/upload-capabilities`, or null when it is unusable.
  Future<int?> uploadLimitBytes() async {
    try {
      return uploadLimitFromCapabilities(
        await query('/attachments/upload-capabilities'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> attachSelection(
    List<({String name, Uint8List bytes})> files, {
    bool thread = false,
    required String Function(String key, Map<String, Object> args) text,
  }) {
    final source = presentationSource;
    if (source != null) {
      return source.attachSelection(files, thread: thread, text: text);
    }
    if (draftScope(thread: thread) == null || _disposed) {
      return Future<void>.value();
    }
    return composer.uploads.select(files, _uploadVisit(thread), text: text);
  }

  String _uploadAuthority() => jsonEncode([
    client.generation,
    client.user?.id,
    client.serverId,
    server?.id,
    server?.string('role'),
    channel?.joined,
    channel?.archived,
    channel?.json['channelCapabilities'],
  ]);

  @visibleForTesting
  static String uploadErrorText(Object failure) =>
      WorkspaceUploads.uploadErrorText(failure);

  /// A 403 whose reason is membership revocation (not a transient failure).
  static bool _isNotServerMember(Object failure) =>
      failure is RaftApiException &&
      failure.status == 403 &&
      failure.message == 'Not a member of this server';

  ComposerUploadVisit _uploadVisit(bool thread) {
    final scope = draftScope(thread: thread)!;
    final generation = ledger.generation, authority = _uploadAuthority();
    return ComposerUploadVisit(
      scope: scope,
      channelId: channel?.id,
      thread: thread,
      selectionCurrent: () =>
          !_disposed &&
          generation == ledger.generation &&
          scope == draftScope(thread: thread) &&
          authority == _uploadAuthority(),
      resolveThread: ensureThread,
      limit: uploadLimitBytes,
      upload: (id, draft, progress) => draft.local != null
          ? client.uploadStream(
              id,
              draft.local!.openRead,
              draft.sizeBytes,
              draft.filename,
              cancellation: draft.cancel,
              onProgress: progress,
              mimeType: composerMimeType(draft.filename),
            )
          : client.upload(
              id,
              draft.bytes,
              draft.filename,
              cancellation: draft.cancel,
              onProgress: progress,
              mimeType: composerMimeType(draft.filename),
            ),
      persist: _saveDraftScope,
      notice: (message) => _raiseComposerNotice(scope, message),
    );
  }

  Future<void> attachUpload(
    String name,
    Uint8List bytes, {
    bool thread = false,
  }) async {
    final source = presentationSource;
    if (source != null) return source.attachUpload(name, bytes, thread: thread);
    if (draftScope(thread: thread) == null || _disposed) return;
    await composer.uploads.attach(name, bytes, _uploadVisit(thread));
  }

  Future<void> retryUpload(UploadDraft draft, {bool thread = false}) async {
    final source = presentationSource;
    if (source != null) return source.retryUpload(draft, thread: thread);
    if (draftScope(thread: thread) == null || _disposed) return;
    await composer.uploads.retry(draft, _uploadVisit(thread));
  }

  Future<void> _transferUpload(
    UploadDraft draft, {
    required bool thread,
  }) async {
    if (draftScope(thread: thread) == null || _disposed) return;
    await composer.uploads.transfer(draft, _uploadVisit(thread));
  }

  void removeUpload(UploadDraft draft, {bool thread = false}) {
    final source = presentationSource;
    if (source != null) return source.removeUpload(draft, thread: thread);
    composer.uploads.remove(draft, _saveDraftScope);
  }

  late final ConversationReadRepository conversationReads;
  ReadStateLedger get _readState => conversationReads.localReadState;
  @override
  ReadStateLedger get readState => presentationSource?.readState ?? _readState;

  /// Workspace-owned page snapshots (Activity, Saved) that survive
  /// navigation; dropped on every server or account switch.
  final _resourceSnapshots = ResourceSnapshotCache();
  @override
  ResourceSnapshotCache get resourceSnapshots =>
      presentationSource?.resourceSnapshots ?? _resourceSnapshots;
  Map<String, Set<String>> get visibleIds => messageWindows.visibleIds;
  bool hasNewer = false;
  @override
  bool threadHasMore = false;
  bool threadHistoryLimited = false, historyLimited = false;
  String? highlightedMessageId;

  /// Pending unknown context; cross-channel cached tails are not that context.
  String? get pendingMessageContextChannelId =>
      messageWindows.pendingContextChannelId;
  @override
  List<RaftRecord> servers = [];
  @override
  List<RaftChannel> get channels => channelRepository.channels;
  set channels(List<RaftChannel> value) => channelRepository.channels = value;
  @override
  List<RaftChannel> get dms => channelRepository.dms;
  set dms(List<RaftChannel> value) => channelRepository.dms = value;
  Map<String, int> get unread => conversationReads.unread;
  set unread(Map<String, int> value) => conversationReads.unread = value;

  /// Source messageStore `mentionFlags`: conversations whose unread messages
  /// mention the member (unread snapshot `hasMention`, a live `message:new`
  /// that mentions the member). Cleared with the unread count.
  Set<String> get mentions => conversationReads.mentions;
  set mentions(Set<String> value) => conversationReads.mentions = value;

  /// Unread summary `hasNew`: non-joined public channels with messages past
  /// the cursor (no exact count). Lights the quiet dot of a non-joined row;
  /// cleared with the unread count (Web `newFlags`).
  Set<String> get newFlags => conversationReads.newFlags;
  set newFlags(Set<String> value) => conversationReads.newFlags = value;
  Map<String, dynamic> sidebarOrder = {};
  @override
  RaftRecord? server;
  bool can(String capability, {RaftChannel? resource}) => raftCan(
    server?.string('role'),
    capability,
    channelCapabilities: resource?.json['channelCapabilities'] is Map
        ? Map<String, dynamic>.from(resource!.json['channelCapabilities'])
        : null,
  );
  RaftChannel? channel;
  WorkspaceThreadIdentity? _threadIdentity;
  MessageWindowRequest? _threadVisit;
  bool _threadResolutionLoading = false, _threadParentLoading = false;
  // ignore: raft_lints/avoid_imperative_notice_state -- Cleared when a thread opens or closes and hidden whenever threadIdentity is stale.
  String? _threadResolutionError;

  @override
  WorkspaceThreadIdentity? get threadIdentity =>
      _threadVisit?.current == true ? _threadIdentity : null;
  bool get threadResolutionLoading =>
      threadIdentity != null && _threadResolutionLoading;
  bool get threadParentLoading =>
      threadIdentity != null && _threadParentLoading;
  String? get threadResolutionError =>
      threadIdentity == null ? null : _threadResolutionError;
  @override
  RaftMessage? get presentedThreadParent => _threadIdentity == null
      ? threadParent
      : threadIdentity != null &&
            threadParent?.id == threadIdentity!.parentMessageId &&
            threadParent?.channelId == threadIdentity!.parentChannelId
      ? threadParent
      : null;
  String? get threadParentMessageId =>
      threadIdentity?.parentMessageId ??
      (_threadIdentity == null ? threadParent?.id : null);
  String? get threadParentChannelId =>
      threadIdentity?.parentChannelId ??
      (_threadIdentity == null ? threadParent?.channelId : null);

  RaftChannel? _threadChannelResource(String? id) => [
    ?channel,
    ...channels,
    ...dms,
  ].where((value) => value.id == id).firstOrNull;
  String? _threadResourceAuthority(String? id) {
    final resource = _threadChannelResource(id);
    return resource == null
        ? null
        : messageWindowAuthority(server?.string('role'), resource.json);
  }

  RaftChannel? get threadSourceChannel =>
      _threadChannelResource(threadParentChannelId);

  RaftMessage? threadParent;
  @override
  String? threadChannelId;
  bool loading = false,
      channelLoading = false,
      threadLoading = false,
      loadingOlder = false,
      hasMore = false;
  bool connected = false;
  // ignore: raft_lints/avoid_imperative_notice_state -- One-shot toast consumed by WorkspaceView; cleared on channel open, jump, send start, server switch and server revoke.
  String? error;

  /// Source messageStore `contextLoadError` for the open channel: the jump
  /// target's context failed to load and the latest window replaced it.
  /// `notFound` -> ChatPanel's "Message not found" banner; `beyondHistory` ->
  /// the plan history-limit banner. Cleared by the next channel open or jump.
  /// Bound to the channel and server it was raised for: it reads as null in
  /// any other one (a channel replaced without a re-open, a server switch).
  MessageContextLoadError? get contextLoadError {
    if (_contextFailure?.$2 != (channel?.id, server?.id)) {
      _contextFailure = null;
    }
    return _contextFailure?.$1;
  }

  set contextLoadError(MessageContextLoadError? value) => _contextFailure =
      value == null ? null : (value, (channel?.id, server?.id));

  (MessageContextLoadError, (String?, String?))? _contextFailure;

  final navigation = WorkspaceNavigation();
  String _unboundSection = 'chat';
  String? _navigationAuthority;
  String get navigationAuthority => jsonEncode([
    client.origin,
    client.generation,
    client.user?.id,
    server?.id,
    client.serverId,
    server?.string('role'),
  ]);
  void bindNavigation() {
    if (server == null) return;
    final authority = navigationAuthority;
    if (_navigationAuthority == authority) return;
    final slug =
        [
          server!.string('slug'),
          server!.id,
          client.serverId,
        ].whereType<String>().where((value) => value.isNotEmpty).firstOrNull ??
        '_';
    final initial = _navigationAuthority == null
        ? WorkspaceNavigation.locationForSection(
            slug,
            _unboundSection,
            channelId: channel?.id,
            dm: channel?.type == 'dm',
          )
        : navigation.location.serverSlug == slug
        ? navigation.location
        : WorkspaceNavigation.locationForSection(
            slug,
            mobileNavigation ? 'home' : _unboundSection,
            channelId: null,
          );
    _navigationAuthority = authority;
    navigation.bind(authority, initial);
  }

  RaftLocation get location {
    bindNavigation();
    return navigation.location;
  }

  int get navigationRevision {
    bindNavigation();
    return navigation.revision;
  }

  String get section {
    bindNavigation();
    if (server == null) return _unboundSection;
    final projected = navigation.section;
    // SettingsPanel.tsx:7882–7894 retains the requested URL while a denied
    // tab resolves to Account. It does not redirect the entire workspace.
    return navigation.location.route == RaftRoute.settings &&
            !canVisitSection(projected)
        ? 'settings'
        : projected;
  }

  set section(String value) {
    _unboundSection = value;
    final firstBind = _navigationAuthority == null && server != null;
    bindNavigation();
    if (server != null && !firstBind) {
      navigation.selectSection(
        value,
        channelId: channel?.id,
        dm: channel?.type == 'dm',
      );
    }
  }

  int get channelGeneration => messageWindows.channelGeneration;
  int get threadGeneration => messageWindows.threadGeneration;

  /// Accepted thread summaries ("N replies" rows) per parent channel, keyed
  /// by parent message. Like the channel's message window they outlive a
  /// channel switch, so a revisit or a prefetched first open renders its
  /// reply rows in the same frame as the messages.
  final Map<String, Map<String, dynamic>> _pageSummariesByChannel = {};
  Map<String, Map<String, dynamic>> get _summariesByChannel =>
      presentationSource?._summariesByChannel ?? _pageSummariesByChannel;

  /// Summaries of the selected channel's messages.
  Map<String, dynamic> get threadSummaries {
    final id = channel?.id;
    return id == null
        ? <String, dynamic>{}
        : _summariesByChannel.putIfAbsent(id, () => {});
  }

  set threadSummaries(Map<String, dynamic> value) {
    final id = channel?.id;
    if (id != null) _summariesByChannel[id] = value;
  }

  /// Summaries held for [channelId] (selected or not).
  Map<String, dynamic> threadSummariesFor(String channelId) =>
      Map.unmodifiable(_summariesByChannel[channelId] ?? const {});
  List<RaftMessage> get messages => messageWindows.rows(channel?.id);

  /// Same membership as [messages], in constant time (no list projection).
  bool presentsMessage(String? id) =>
      messageWindows.retainsContextRows(channel?.id) &&
      messageWindows.containsVisible(channel?.id, id);

  /// Same membership as [replies], in constant time.
  bool presentsReply(String? id) =>
      messageWindows.containsVisible(threadChannelId, id);

  @override
  List<RaftMessage> get replies => messageWindows.rows(threadChannelId);

  /// Web display order uses server sequence, with a display-only coordinate
  /// for pending rows. Context windows keep their existing admission policy.
  List<RaftMessage> timeline({bool thread = false, List<RaftMessage>? rows}) =>
      messageWindows.project(
        rows ?? (thread ? replies : messages),
        draftScope(thread: thread),
        context:
            !thread &&
            (hasNewer || pendingMessageContextChannelId == channel?.id),
      );

  /// Stable presentation identity: a row sent from this session keeps its
  /// optimistic key after the server copy replaces it, so the timeline
  /// updates that row in place instead of removing and inserting one.
  String messageKey(RaftMessage message) {
    if (presentationSource != null) {
      return presentationSource!.messageKey(message);
    }
    final randomId = message.json['randomId'];
    return randomId is String && composer.sends.localId(randomId)
        ? 'optimistic-$randomId'
        : message.id;
  }

  /// Whether [message] is an optimistic row still waiting for the server.
  static bool isPendingSend(RaftMessage message) =>
      message.json['pendingSend'] == true;

  static bool _rateLimited(Object e) => e is RaftApiException && e.rateLimited;

  /// A background refresh that failed is only an error worth showing when its
  /// scope is still the open one: a rate limit, or a fence tripped because the
  /// account or workspace changed (a deleted or left server), is not.
  static bool _quietFailure(Object e) => _rateLimited(e) || _staleScope(e);

  /// A request fenced by an account or workspace change: its owner moved on,
  /// so it reports nothing (also for the user's own actions, which are
  /// otherwise reported, rate limits included).
  static bool _staleScope(Object e) => e is RaftApiException && e.staleScope;

  void setError(String? value) {
    final source = presentationSource;
    if (source != null) {
      // ignore: raft_lints/avoid_imperative_notice_state -- Delegates to the session source.
      source.setError(value);
      return;
    }
    error = value;
    notifyListeners();
  }

  /// Hydrates the account's real server directory without selecting a server.
  /// The app root uses this before exposing the global chooser. Offline rows
  /// retain the existing account-scoped cache contract; fresh authority and
  /// cache writes share the membership reducer's request/revocation fences.
  ///
  /// With [cachedFirst] (cold start) an accepted on-device directory is
  /// adopted at once, so the remembered server and its cached channels paint
  /// without waiting for the network; [revalidateServerDirectory] then
  /// replaces it in the background.
  Future<bool> loadServerDirectory({
    bool cachedFirst = false,
    void Function()? onCacheMiss,
  }) => _burstAt.directoryRead(() async {
    if (!ownsClient) {
      throw StateError('A borrowed editor cannot load the server directory.');
    }
    final generation = client.generation,
        principal = client.user?.id,
        request = ++_membershipRequest,
        revision = _membershipRevision;
    bool current() =>
        !_disposed &&
        generation == client.generation &&
        principal == client.user?.id &&
        request == _membershipRequest &&
        revision == _membershipRevision;
    if (principal == null) return false;
    if (client.restoredOffline || cachedFirst) {
      final cached = await _cached('servers', '', server: '');
      if (!current()) return false;
      if (cached is List && cached.isNotEmpty) {
        servers = cached
            .map((row) => RaftRecord(Map<String, dynamic>.from(row)))
            .where((server) => !_revokedServers.contains(server.id))
            .toList();
        notifyListeners();
        if (cachedFirst) unawaited(revalidateServerDirectory());
        return true;
      }
    }
    onCacheMiss?.call();
    final accepted = await client.servers();
    if (!current()) return false;
    _revokedServers.removeAll(accepted.map((server) => server.id));
    servers = accepted;
    await _save(
      'servers',
      '',
      accepted.map((server) => server.json).toList(),
      server: '',
    );
    if (!current()) return false;
    notifyListeners();
    return true;
  });

  /// Channel and DM rows saved on this device for [serverId], or null. A
  /// display seed (for example the share picker) and never an authorization
  /// grant: callers revalidate before acting on a row.
  Future<List<RaftChannel>?> cachedChannelDirectory(String serverId) async {
    if (_disposed || _revokedServers.contains(serverId)) return null;
    final cached = await _cached('channels', '', server: serverId);
    if (cached is! Map || _disposed || _revokedServers.contains(serverId)) {
      return null;
    }
    try {
      return [
        for (final key in const ['channels', 'dms'])
          for (final row in cached[key] as List)
            RaftChannel(Map<String, dynamic>.from(row as Map)),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Background replacement of a cache-first directory once the restored
  /// session is validated. A server missing from the fresh directory is
  /// revoked (its on-device data is purged and, when selected, its workspace
  /// closes); a changed role replaces the selected server's authority, which
  /// retires role-bound windows and revalidates the open channel. A failure
  /// keeps the accepted directory (offline).
  Future<void> revalidateServerDirectory() => _burstAt.directoryRead(() async {
    final principal = client.user?.id,
        request = ++_membershipRequest,
        revision = _membershipRevision;
    bool current() =>
        !_disposed &&
        principal != null &&
        principal == client.user?.id &&
        request == _membershipRequest &&
        revision == _membershipRevision;
    await client.sessionValidated;
    if (!current() || client.restoredOffline) return;
    final List<RaftRecord> accepted;
    try {
      accepted = await client.accountServers();
    } catch (_) {
      return;
    }
    if (!current()) return;
    final ids = {for (final s in accepted) s.id};
    for (final held in [...servers]) {
      if (!ids.contains(held.id)) revokeServer(held.id);
    }
    final selected = server;
    if (selected != null && !ids.contains(selected.id)) {
      revokeServer(selected.id);
    }
    _revokedServers.removeAll(ids);
    servers = accepted;
    _save('servers', '', accepted.map((s) => s.json).toList(), server: '');
    final held = server;
    final fresh = held == null
        ? null
        : accepted.where((s) => s.id == held.id).firstOrNull;
    if (held != null && fresh != null) {
      final role = fresh.string('role');
      if (role != held.string('role')) {
        applyMembershipRole({
          'userId': principal,
          'serverId': held.id,
          'role': role,
        });
        server = fresh;
        notifyListeners();
        await refreshChannels();
        final open = channel;
        if (!_disposed && open != null && server?.id == held.id) {
          unawaited(
            selectChannel(
              open,
              navigate: false,
              preserveThread: true,
              autoRead: false,
            ),
          );
        }
        return;
      }
      if (jsonEncode(fresh.json) != jsonEncode(held.json)) server = fresh;
    }
    notifyListeners();
  });

  Future<void> bootstrap() async {
    final source = presentationSource;
    if (source != null) {
      return source.bootstrap();
    }
    if (!ownsClient) {
      throw StateError('A borrowed editor cannot bootstrap a session.');
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final cached = await _cached('servers', '', server: '');
      if (cached is List) {
        servers = cached
            .map((e) => RaftRecord(Map<String, dynamic>.from(e)))
            .where((s) => !_revokedServers.contains(s.id))
            .toList();
      }
      notifyListeners();
      if (servers.isNotEmpty && client.restoredOffline) {
        await selectServer(servers.first);
        return;
      }
      servers = await client.servers();
      _revokedServers.removeAll(servers.map((s) => s.id));
      await _save(
        'servers',
        '',
        servers.map((s) => s.json).toList(),
        server: '',
      );
      if (servers.isNotEmpty) await selectServer(servers.first);
    } catch (e) {
      if (!_staleScope(e)) error = userErrorText(e, where: 'load servers');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  @override
  void beginServerSelectionProjection(RaftRecord next) {
    server = next;
    // A workspace error belongs to the server where it was raised.
    error = null;
    _burstAt.clear();
    if (mobileNavigation) section = 'home';
    if (!canVisitSection(section)) section = 'chat';
    sidebarOrder = {};
    client.selectServer(next.id);
  }

  @override
  void resetServerSelectionState() {
    channelRepository.resetRowAuthority();
    // The new server's socket connects for the first time.
    _connectedBefore = _roomsJoinedPending = false;
    _gapSyncedThrough = null;
    hasNewer = false;
  }

  /// [onHydrated] runs once the on-device channels, selection window and
  /// unread counts of [next] are painted, before any network response; it
  /// does not run when nothing is cached. The returned future still settles
  /// only after the fresh channel lists (and the selected page) are applied.
  Future<void> selectServer(
    RaftRecord next, {
    void Function()? onHydrated,
    void Function()? onCacheMiss,
  }) async {
    // A live mobile page presents the source's session; the source selects.
    final source = presentationSource;
    if (source != null) {
      return source.selectServer(
        next,
        onHydrated: onHydrated,
        onCacheMiss: onCacheMiss,
      );
    }
    if (!ownsClient) {
      throw StateError('A borrowed editor cannot select a server.');
    }
    if (_revokedServers.contains(next.id)) return;
    final selection = sessionScope.selectServer(next);
    final selectionAtStart = channelGeneration,
        threadAtStart = threadGeneration,
        navigationAtStart = navigationRevision;
    notifyListeners();
    final generation = client.generation;
    final replyIdentity = _syncIdentity();
    final cached = await _cached('channels', '');
    await selection.restoredEntities;
    await selection.restoredTranslations;
    if (generation != client.generation) return;
    if (cached is Map) {
      channels = (cached['channels'] as List)
          .map((e) => RaftChannel(Map<String, dynamic>.from(e)))
          .toList();
      dms = (cached['dms'] as List)
          .map((e) => RaftChannel(Map<String, dynamic>.from(e)))
          .toList();
      final last = await _cached('selection', '');
      final initial =
          [...channels, ...dms].where((c) => c.id == last).firstOrNull ??
          channels.where((c) => c.joined && !c.archived).firstOrNull;
      if (initial != null) {
        channel = initial;
        // A principal/role change before this point retires its summaries.
        final replyAuthority = replyIdentity == _syncIdentity()
            ? _replyToken(initial.id)
            : '';
        final request = messageWindows.request(
          allowed: () => generation == client.generation,
        );
        final page = await _cached('window', initial.id);
        if (generation != client.generation) return;
        if (_restoreCachedTail(
          initial.id,
          page,
          request,
          replyAuthority: replyAuthority,
          replace: true,
        )) {
          await _restoreDraft(initial.id);
        }
      }
      notifyListeners();
    }
    final cachedFrontiers = await _cached('read-frontiers', '');
    if (generation != client.generation) return;
    readState.restore(
      cachedFrontiers,
      serverId: next.id,
      principalId: client.user!.id,
    );
    final cachedUnread = await _cached('unread', '');
    if (generation != client.generation) return;
    if (cachedUnread is Map) {
      unread = {
        for (final entry in cachedUnread.entries)
          if (entry.value is int && entry.value >= 0)
            '${entry.key}': entry.value,
      };
    }
    notifyListeners();
    if (cached is Map) {
      onHydrated?.call();
    } else {
      onCacheMiss?.call();
    }
    final readGeneration = readState.generation;
    List<List<RaftChannel>> values;
    try {
      values = await Future.wait([
        client.channels(),
        client.channels(dm: true),
      ]);
    } catch (e) {
      if (_isNotServerMember(e) && generation == client.generation) {
        revokeServer(next.id);
        await recoverMembership();
        loading = false;
        notifyListeners();
        return;
      }
      if (generation == client.generation) {
        error = userErrorText(e, where: 'load channels');
        loading = false;
        notifyListeners();
      }
      return;
    }
    if (generation != client.generation) return;
    final accessible = [...values[0], ...values[1]].map((c) => c.id).toSet();
    for (final old in [...channels, ...dms]) {
      if (!accessible.contains(old.id)) _revokeChannel(old.id);
    }
    channels = values[0];
    dms = values[1];
    // A cached selection adopts its fresh row. When the fresh row changes
    // the window authority, the cached rows are not shown under it: the
    // selection is revalidated below (or by the newer selection in flight).
    final held = channel;
    final freshHeld = held == null
        ? null
        : [...channels, ...dms].where((c) => c.id == held.id).firstOrNull;
    var heldAuthorityChanged = false;
    if (held != null && freshHeld != null && !identical(held, freshHeld)) {
      final before = _windowAuthority();
      channel = freshHeld;
      heldAuthorityChanged = before != _windowAuthority();
    }
    // The cache-painted workspace is already on screen: show the fresh lists
    // (and any revocation) now, not after the unread read below.
    notifyListeners();
    await _save('channels', '', {
      'channels': channels.map((c) => c.json).toList(),
      'dms': dms.map((c) => c.json).toList(),
    });
    // The cache write yields: a sign-out meanwhile clears `client.user`.
    if (generation != client.generation) return;
    final principalId = client.user?.id;
    if (principalId == null) return;
    for (final c in [...channels, ...dms]) {
      readState.consumeSnapshot(
        c.json['readState'],
        serverId: next.id,
        principalId: principalId,
        scopeId: c.id,
        generationAtRequest: readGeneration,
      );
    }
    client.connect();
    await refreshUnread();
    final joined = channels.where((c) => c.joined && !c.archived).toList();
    if (joined.isNotEmpty &&
        selectionAtStart == channelGeneration &&
        threadAtStart == threadGeneration) {
      final selected =
          joined.where((c) => c.id == channel?.id).firstOrNull ?? joined.first;
      if (mobileNavigation && section == 'home') {
        channel = selected;
        await _restoreDraft(selected.id);
      } else {
        // A location the app root applied over the cache-painted workspace
        // (e.g. a remembered non-chat page) keeps its section.
        await selectChannel(
          selected,
          navigate: navigationAtStart == navigationRevision,
        );
      }
    } else if (heldAuthorityChanged &&
        channel != null &&
        identical(channel, freshHeld)) {
      await selectChannel(
        channel!,
        navigate: false,
        preserveThread: true,
        autoRead: false,
      );
    }
    notifyListeners();
  }

  void _persistReadState() => conversationReads.persistReadState();

  void _persistUnread() => conversationReads.persistUnread();

  /// Latest activity seq per scope from the last unread snapshot; live
  /// messages raise it. Lets a read receipt clear a count without a GET.
  Map<String, BigInt> get _latestActivity => conversationReads.latestActivity;

  /// Source messageStore `message:new`: +1 for a conversation the member is
  /// not reading, never for the member's own message. Counts only what the
  /// unread snapshot counts (joined channels, DMs, tracked threads).
  void _receiveUnread(Map<String, dynamic> row) =>
      conversationReads.receiveUnread(row);

  void _clearMention(String id) => conversationReads.clearMention(id);

  /// Source `applyAcceptedReadStateProjection`: an accepted read frontier
  /// recounts the scope from held messages when they cover it, and clears
  /// it when it reaches the latest known activity. Otherwise the count
  /// waits for the next reconcile.
  void _projectReadState(String id) => conversationReads.projectReadState(id);

  Future<void> refreshUnread() async {
    final source = presentationSource;
    if (source != null) {
      return source.refreshUnread();
    }
    return conversationReads.refreshUnread();
  }

  final _prefetched = <String>{};
  bool _prefetching = false;

  /// Loads the latest page of channels the member is likely to open next
  /// (those with unread messages) in the background, so a first open shows
  /// content at once instead of waiting for the network. Never selects,
  /// joins or marks anything read; each channel is prefetched once per
  /// session, sequentially, and only while the same account/server/role and
  /// view permission hold.
  Future<void> prefetchLikelyChannels({int limit = 6}) async {
    // Not during startup: the restored selection (possibly hidden behind
    // mobile Home) is decided first and is never prefetched.
    if (_prefetching || _disposed || loading || channel == null) return;
    _prefetching = true;
    try {
      // A window's authority is per channel (role + that channel's record).
      String authorityOf(RaftChannel c) =>
          messageWindowAuthority(server?.string('role'), c.json);
      final role = server?.string('role'),
          identity = _syncIdentity(),
          generation = ledger.generation;
      bool stillCurrent() =>
          !_disposed &&
          role == server?.string('role') &&
          identity == _syncIdentity() &&
          generation == ledger.generation;
      final candidates = [
        for (final c in [...channels, ...dms])
          if (c.id != channel?.id &&
              !_prefetched.contains(c.id) &&
              !_revokedChannels.contains(c.id) &&
              messageWindows.accepted[c.id] == null &&
              (unread[c.id] ?? 0) > 0 &&
              can('viewChannel', resource: c))
            c,
      ].take(limit).toList();
      for (final c in candidates) {
        if (!stillCurrent()) return;
        _prefetched.add(c.id);
        final authority = authorityOf(c), reply = _replyToken(c.id);
        final request = messageWindows.request(
          allowed: () =>
              stillCurrent() &&
              reply == _replyToken(c.id) &&
              channel?.id != c.id &&
              messageWindows.accepted[c.id] == null &&
              !_revokedChannels.contains(c.id) &&
              authority == authorityOf(c) &&
              can('viewChannel', resource: c),
        );
        try {
          // The channel's task chips load with its first page.
          unawaited(MessageTaskCache.of(client).warm(this, c.id));
          final page = await MessageHistoryPages.read(this, request, c.id);
          if (!request.current) continue;
          final rows = acceptedWindowRows(page['messages'], c.id);
          if (rows.isEmpty) continue;
          final limited = page['historyLimited'] == true;
          messageWindows.acceptRows(request, c.id, rows, replace: true);
          await MessageHistoryPages.record(this, request, page);
          if (!request.current) continue;
          messageWindows.rememberWindow(
            request,
            c.id,
            authority,
            !limited && rows.length >= 50,
            reply,
            historyLimited: limited,
          );
          // Reply rows are part of the window: a first open renders them in
          // the same frame as the prefetched messages.
          mergeThreadSummaries(c.id, page['threadSummariesByParentMessageId']);
        } catch (_) {
          // Best effort: the channel opens normally on demand.
        }
      }
    } finally {
      _prefetching = false;
    }
  }

  void _revokeChannel(String id) => sessionScope.revokeChannel(id);

  @override
  ChannelRevocationPlan planChannelRevocation(String id) =>
      ChannelRevocationPlan.discover(
        channelId: id,
        messages: ledger.messages(id),
        parentMessageIds: threadRepliesSync.parentMessageIdsForChannel(id),
        summaries: _summariesByChannel,
        identity: _threadIdentity,
        parent: threadParent,
        threadChannelId: threadChannelId,
      );

  @override
  void clearRevokedChannelProjection(String scope) {
    unread.remove(scope);
    _clearMention(scope);
    _latestActivity.remove(scope);
    _summariesByChannel.remove(scope);
  }

  @override
  void removeRevokedParentSummary(dynamic messageId) {
    for (final bucket in _summariesByChannel.values) {
      bucket.remove(messageId);
    }
  }

  @override
  void closeRevokedChannelProjection(ChannelRevocation event) {
    final id = event.plan.channelId;
    if (channel?.id == id && !event.keepShared) {
      channel = null;
      _missingConversationChannelId = id;
      messageWindows.channelGeneration++;
    }
    if (threadParent?.channelId == id ||
        _threadIdentity?.parentChannelId == id ||
        event.plan.threadIds.contains(threadChannelId) ||
        threadChannelId == id) {
      closeThread();
    }
  }

  @override
  void persistSessionReadState() => _persistReadState();

  @override
  Future<void> loadSidebar() async {
    if (presentationSource != null) return presentationSource!.loadSidebar();
    return sidebarRepository.load();
  }

  // ---- sidebar-order writes (Source serverStore.updateSidebarOrder) -------

  /// Applies [updates] to [sidebarOrder] at once (the row moves before the
  /// request returns), then PATCHes `/servers/:id/sidebar-order`. A request
  /// that touches sections carries the `sectionsVersion` the server demands
  /// (409 otherwise) and is queued behind the previous section write; a
  /// failure restores the previous order, a 409 reloads it. Never throws.
  Future<void> updateSidebarOrder(Map<String, dynamic> updates) async {
    final source = presentationSource;
    if (source != null) return source.updateSidebarOrder(updates);
    return sidebarRepository.update(updates);
  }

  /// Source channelStore.setActivityMuteState: patches the mute fields of one
  /// row in place (channels, DMs and the open channel).
  void setActivityMuteState(String id, Map<String, dynamic> state) {
    final source = presentationSource;
    if (source != null) return source.setActivityMuteState(id, state);
    channelRepository.setActivityMuteState(id, state);
  }

  /// The channel row [id] as currently held (channels first, then DMs).
  RaftChannel? channelById(String id) =>
      [...channels, ...dms].where((c) => c.id == id).firstOrNull;

  /// Optimistic local unread for Mark as Unread (Source markUnread).
  void markUnreadLocally(String id) {
    final source = presentationSource;
    if (source != null) return source.markUnreadLocally(id);
    conversationReads.markUnreadLocally(id);
  }

  /// Full channel and DM list reload (Source `loadChannels` +
  /// `loadDMChannels`): server selection, `rooms:joined`, a role change, or a
  /// channel event without an id. Unchanged rows keep their objects.
  Future<void> refreshChannels() async {
    final source = presentationSource;
    if (source != null) {
      return source.refreshChannels();
    }
    return channelRepository.refreshChannels();
  }

  /// The one place channel lists change after selection. A row missing from
  /// the next lists lost access and is revoked; [readmit] are rows the
  /// server just confirmed readable.
  void _acceptChannelLists(
    List<RaftChannel> nextChannels,
    List<RaftChannel> nextDms, {
    required Set<String> readmit,
  }) => channelRepository.acceptLists(nextChannels, nextDms, readmit: readmit);

  void _adoptAcceptedChannelSelection(Set<String> accessible) {
    // A held share's destination (and a DM that is not on the server yet)
    // stays open when the lists do not carry it: the composer says why.
    if (channel != null &&
        !isPendingDm(channel) &&
        !(_shareHolds.containsKey(channel!.id) &&
            !accessible.contains(channel!.id))) {
      channel = [
        ...channels,
        ...dms,
      ].where((c) => c.id == channel!.id).firstOrNull;
      if (channel == null) {
        if (threadChannelId != null) {
          messageWindows.revokeChannel(threadChannelId!);
        }
        closeThread();
        messageWindows.channelGeneration++;
      }
    }
  }

  /// Replaces [next]'s row in place, or adds it (a new DM goes first, as the
  /// server's recency-ordered DM list would place it).
  void _putChannelRow(RaftChannel next) => channelRepository.putRow(next);

  /// Source channelRealtimeSync: a channel event changes one row. A carried
  /// row is patched in place; an id re-reads that one channel; only an event
  /// without an id reloads both lists.
  void _channelRealtime(String name, dynamic payload) =>
      channelRepository.consumeRealtime(name, payload);

  /// Web `patchChannel` `hiddenAllChannel`: an admin hiding `#all` turns it
  /// into a private channel named `all`, which leaves the list.
  static bool isHiddenAllChannelRow(Map<String, dynamic> row) =>
      ChannelRepository.isHiddenAllChannelRow(row);

  /// Source `ensureChannel(id, {refresh: true})`: reads one channel and
  /// upserts its row. Lost access (403/404, or a private row the lists would
  /// not carry) revokes that channel through the list revocation path.
  Future<void> refreshChannel(String id) =>
      channelRepository.refreshChannel(id);

  bool _roomsJoinedPending = false, _connectedBefore = false;
  DateTime? _lastHeartbeat, _lastServerEvent;
  (int, BigInt)? _gapSyncedThrough;

  /// Source socketBridge `roomsJoined`: the server joined this socket's
  /// rooms, so missed messages can be resumed and the lists re-read.
  void _roomsJoined() {
    SourceActivityUnreadStore.activateForRooms(this);
    _roomsJoinedPending = false;
    unawaited(MessageHistoryEvents.resume(this));
    // A reconnect and a resume can both ask within a second; the tail read a
    // moment ago already covers them.
    if (_due('gap', freshness: const Duration(seconds: 3))) {
      unawaited(syncVisibleScopes());
    }
    if (_due('channels')) unawaited(refreshChannels());
    if (_due('unread')) unawaited(refreshUnread());
  }

  /// Server reads started by events and by returning to the foreground (not
  /// by the person asking) are skipped while the last one is this fresh.
  static const _burstFreshness = Duration(seconds: 15);
  final _burstAt = BurstReads();
  bool _due(String name, {Duration freshness = _burstFreshness}) =>
      _burstAt.due(name, freshness);

  /// Source `recordHeartbeat`: a server seq past the ledger watermark means
  /// a push was missed; the visible scopes read their gap.
  void _heartbeat(dynamic payload) {
    _lastHeartbeat = DateTime.now();
    // A lost `rooms:joined`: the connection's first heartbeat stands in.
    if (_roomsJoinedPending) {
      _roomsJoined();
      return;
    }
    final seq = payload is Map ? BigInt.tryParse('${payload['seq']}') : null;
    final synced = _gapSyncedThrough;
    if (seq == null ||
        seq <= ledger.watermark ||
        synced != null && synced.$1 == ledger.generation && seq <= synced.$2) {
      return;
    }
    unawaited(syncVisibleScopes(through: seq));
  }

  /// Source `recoverLiveSession` on return to the foreground: reconnect a
  /// dropped or silent socket (its `rooms:joined` resumes and gap-syncs), or
  /// resume and gap-sync on the live one; then refresh live counts.
  void resumeLiveSession() {
    if (_disposed || !ownsClient || client.serverId == null) return;
    // The Activity window and the cross-server summary are read at once, in
    // parallel with the resume handshake below (not after its reply).
    unawaited(activityUnreadIfBound?.refreshOnResume());
    resumes.value++;
    final now = DateTime.now();
    final heartbeat = _lastHeartbeat, inbound = _lastServerEvent;
    final silent =
        heartbeat != null &&
        inbound != null &&
        now.difference(heartbeat) > const Duration(seconds: 90) &&
        now.difference(inbound) > const Duration(seconds: 120);
    if (!client.connected || silent) {
      client.connect();
    } else {
      unawaited(MessageHistoryEvents.resume(this));
      if (_due('gap', freshness: const Duration(seconds: 3))) {
        unawaited(syncVisibleScopes());
      }
    }
    // Returning to the foreground (alt-tab on a desktop does it often): the
    // counts, sidebar and directory read less than 15 s ago are still fresh.
    if (_due('unread')) unawaited(refreshUnread());
    if (_due('sidebar')) loadSidebar();
    if (entityDirectory.started && _due('authors')) {
      entityDirectory.revalidateAuthors();
    }
    // Another session of this account may have joined or created a server;
    // the server tells only that server's room, so this is the one moment the
    // directory is re-read. On a desktop the engine reports window focus as
    // inactive/resumed, so this also runs when the window regains focus.
    if (_due('membership', freshness: _membershipResumeFreshness)) {
      unawaited(recoverMembership(coalesce: true));
    }
  }

  /// Focus flickers and quick app switches must not re-read the server list.
  static const _membershipResumeFreshness = Duration(seconds: 60);

  static const _gapPageLimit = 200;
  bool _gapSyncing = false;

  /// Source `syncVisibleScopes`: the open thread and the presented channel
  /// tail each read the messages after their newest row and append them to
  /// the held window. Nothing is cleared or reloaded.
  Future<void> syncVisibleScopes({BigInt? through}) async {
    if (_gapSyncing || _disposed) return;

    final thread = threadChannelId, main = channel?.id;
    final targets = [
      if (thread != null && !threadLoading && !messageWindows.contextHasNewer(thread)) thread,
      if (main != null &&
          main != thread &&
          !hasNewer &&
          !channelLoading &&
          pendingMessageContextChannelId != main)
        main,
    ];
    if (targets.isEmpty) return;
    final generation = ledger.generation;
    var complete = true;
    _gapSyncing = true;
    try {
      for (final id in targets) {
        if (!await _syncGap(id)) complete = false;
      }
    } finally {
      _gapSyncing = false;
    }
    if (complete && through != null && generation == ledger.generation) {
      _gapSyncedThrough = (generation, through);
    }
  }

  Future<bool> _syncGap(String id) async {
    final thread = id == threadChannelId;
    var cursor = messageWindows.newestVisibleSequence(id);
    if (cursor == BigInt.zero) return true;
    final owner = thread ? threadParentChannelId : id;
    final request = _windowRequest(
      id,
      thread: thread,
      allowed: () =>
          thread ? threadChannelId == id && !messageWindows.contextHasNewer(id) : channel?.id == id && !hasNewer,
    );
    try {
      while (true) {
        final page = await MessageHistoryPages.read(
          this, request, id,
          thread: thread, after: cursor, limit: _gapPageLimit, localFirst: false,
          remote: () async => {
            'messages': await client.get('/messages/sync', query: {
              'since_seq': '$cursor', 'channel_id': id, 'limit': _gapPageLimit,
            }),
          },
        );
        if (!request.current) return false;
        final listed = page['messages'] is List ? page['messages'] as List : const [];
        final rows = [
          for (final row in listed.whereType<Map>())
            if (row['channelId'] == id && row['id'] is String)
              Map<String, dynamic>.from(row),
        ];
        if (rows.isEmpty) break;
        final arrived = [
          for (final row in rows)
            if (!ledger.contains(id, row['id'] as String)) row,
        ];
        messageWindows.acceptRows(request, id, rows);
        if (!await MessageHistoryPages.record(this, request, page)) return false;
        if (!request.current) return false;
        var next = cursor;
        for (final row in rows) {
          final seq = RaftMessage(row).seq;
          if (seq > next) next = seq;
        }
        if (_mayMarkRead(id) && !_scrolledAway.away(id)) {
          unawaited(markRead(id));
        } else {
          arrived.forEach(_receiveUnread);
        }
        unawaited(_saveWindow(id, thread: thread));
        notifyListeners();
        if (listed.length < _gapPageLimit || next <= cursor) break;
        cursor = next;
      }
      return true;
    } on RaftApiException catch (e) {
      // Lost access is decided by the channel read and its revocation path.
      if (request.current &&
          owner != null &&
          (e.status == 403 || e.status == 404)) {
        unawaited(refreshChannel(owner));
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  int _membershipRevision = 0, _membershipRequest = 0;

  bool canVisitSection(String name) {
    final capability = const {
      'agents': 'viewAgents',
      'computers': 'viewMachines',
      'members': 'viewMembers',
      'providers': 'manageExternalAuth',
      'integrations': 'manageIntegrations',
      'im-bridges': 'manageIntegrations',
      'administration': 'viewServerSettings',
      'billing': 'viewBilling',
      'workspace-settings': 'viewServerSettings',
    }[name];
    if (capability != null) return can(capability);
    return const {
      'home',
      'chat',
      'activity',
      'search',
      'saved',
      'tasks',
      'settings',
    }.contains(name);
  }

  /// Apply the mounted receiver's own authoritative role event synchronously.
  /// Any earlier HTTP membership snapshot loses its request revision fence.
  void applyMembershipRole(dynamic payload) {
    if (payload is! Map ||
        payload['userId'] != client.user?.id ||
        payload['serverId'] is! String ||
        payload['role'] is! String) {
      return;
    }
    final id = payload['serverId'] as String, role = payload['role'] as String;
    if (!servers.any((s) => s.id == id) && server?.id != id) return;
    _membershipRevision++;
    _membershipRequest++;
    servers = [
      for (final s in servers)
        s.id == id ? RaftRecord({...s.json, 'role': role}) : s,
    ];
    if (server?.id == id) {
      if (server?.string('role') != role) {
        _replyAuthorityEpoch++;
      }
      server = RaftRecord({...server!.json, 'role': role});
      _ensureSyncIdentity();
      refreshMessageSyncFlag();
      if (!canVisitSection(section)) section = 'chat';
    }
    _save('servers', '', servers.map((s) => s.json).toList(), server: '');
    notifyListeners();
  }

  /// Bumped by every `server:plan-updated`. Views that hold billing / usage
  /// reads (Web `loadBilling` + `loadUsage`) reload when it changes.
  int planRevision = 0;

  /// Web socketBridge `server:plan-updated`: patch the server row's plan, or
  /// re-read the servers when the payload is incomplete; billing and usage
  /// are then reloaded by [planRevision] observers.
  void _consumeServerPlanUpdated(dynamic payload) {
    final id = payload is Map ? payload['serverId'] : null;
    final plan = payload is Map ? payload['plan'] : null;
    if (id is String && id.isNotEmpty && plan is String) {
      RaftRecord patch(RaftRecord value) =>
          value.id == id ? RaftRecord({...value.json, 'plan': plan}) : value;
      servers = servers.map(patch).toList();
      if (server != null) server = patch(server!);
      _save('servers', '', servers.map((s) => s.json).toList(), server: '');
    } else {
      unawaited(recoverMembership());
    }
    planRevision++;
    notifyListeners();
  }

  /// Web serverStore `uploadServerAvatar`: the upload response's avatar URL is
  /// upserted into the server row everywhere (rail, switcher, settings) with
  /// no re-read. A mirrored presentation source re-reads instead.
  void applyServerAvatar(String serverId, String? avatarUrl) {
    if (presentationSource != null) {
      unawaited(recoverMembership());
      return;
    }
    if (_disposed) return;
    RaftRecord patch(RaftRecord value) => value.id == serverId
        ? RaftRecord({...value.json, 'avatarUrl': avatarUrl})
        : value;
    servers = servers.map(patch).toList();
    if (server != null) server = patch(server!);
    _save('servers', '', servers.map((s) => s.json).toList(), server: '');
    notifyListeners();
  }

  /// With [coalesce] (a refresh nobody asked for), a directory read already in
  /// flight stands in for it: starting another would retire that read.
  Future<void> recoverMembership({bool coalesce = false}) async {
    if (presentationSource != null) {
      return presentationSource!.recoverMembership();
    }
    if (!ownsClient || coalesce && _burstAt.directoryReading) return;
    final generation = client.generation,
        request = ++_membershipRequest,
        revision = _membershipRevision;
    try {
      final current = await client.servers();
      if (generation != client.generation ||
          _disposed ||
          request != _membershipRequest ||
          revision != _membershipRevision) {
        return;
      }
      _revokedServers.removeAll(current.map((s) => s.id));
      servers = current;
      await _save(
        'servers',
        '',
        current.map((s) => s.json).toList(),
        server: '',
      );
      if (server != null && !current.any((s) => s.id == server!.id)) {
        revokeServer(server!.id);
        await flushCache();
      }
      if (server == null && current.isNotEmpty) {
        await selectServer(current.first);
      }
      if (server != null) {
        server = current.where((s) => s.id == server!.id).firstOrNull;
        if (!canVisitSection(section)) section = 'chat';
      }
      notifyListeners();
    } catch (e) {
      // A refresh superseded by a newer one, or outrun by a server switch
      // (deleting the open server selects the next), is not a failure.
      if (!_disposed &&
          !_quietFailure(e) &&
          generation == client.generation &&
          request == _membershipRequest) {
        // ignore: raft_lints/avoid_imperative_notice_state -- Raised only for the latest membership request on the current client generation and not for rate-limited or stale-scope failures.
        setError(userErrorText(e, where: 'refresh servers'));
      }
    }
  }

  bool _rejectRevokedConversation(String id) {
    if (_disposed || !_revokedChannels.contains(id)) return false;
    if (location.entityId == id) {
      _missingConversationChannelId = id;
      _resolvingConversationChannelId = null;
      notifyListeners();
    }
    return true;
  }

  String? _resolvingConversationChannelId, _missingConversationChannelId;
  int _conversationResolutionRequest = 0;
  String? get missingConversationChannelId => _missingConversationChannelId;

  /// MainLayout ChannelById/ensureChannel: hydrate a real channel without
  /// treating the thread's focused reply as a message in its parent channel.
  /// URI, principal/server epoch and request ownership fence late arrival.
  Future<void> resolveConversationChannel(
    String id, {
    bool preserveThread = false,
  }) async {
    final source = presentationSource;
    if (source != null) {
      return source.resolveConversationChannel(
        id,
        preserveThread: preserveThread,
      );
    }
    final request = ++_conversationResolutionRequest,
        revision = navigationRevision,
        scope = navigationAuthority,
        reply = _replyToken(id),
        generation = ledger.generation;
    bool current() =>
        !_disposed &&
        request == _conversationResolutionRequest &&
        revision == navigationRevision &&
        scope == navigationAuthority &&
        reply == _replyToken(id) &&
        generation == ledger.generation &&
        !_revokedChannels.contains(id);
    if (_disposed ||
        _rejectRevokedConversation(id) ||
        id.isEmpty ||
        !can('viewChannel')) {
      return;
    }
    _resolvingConversationChannelId = id;
    _missingConversationChannelId = null;
    notifyListeners();
    try {
      var real = [...channels, ...dms].where((c) => c.id == id).firstOrNull;
      if (real == null) {
        final data = await client.get('/channels/$id');
        if (!current()) return;
        if (data is! Map ||
            data['id'] != id ||
            data['serverId'] != null && data['serverId'] != server?.id) {
          throw const RaftApiException('This channel is not available.');
        }
        real = RaftChannel(Map<String, dynamic>.from(data));
        if (!can('viewChannel', resource: real)) return;
        if (real.type == 'dm') {
          dms = [...dms.where((c) => c.id != id), real];
        } else {
          channels = [...channels.where((c) => c.id != id), real];
        }
      }
      if (!current() || !can('viewChannel', resource: real)) return;
      await selectChannel(
        real,
        navigate: false,
        preserveThread: preserveThread,
      );
    } catch (_) {
      if (current()) _missingConversationChannelId = id;
    } finally {
      if (current() && _resolvingConversationChannelId == id) {
        _resolvingConversationChannelId = null;
        notifyListeners();
      }
    }
  }

  Future<void> selectChannel(
    RaftChannel next, {
    bool autoRead = true,
    bool navigate = true,
    bool retainContextUntilAccepted = false,
    bool preserveThread = false,
    VoidCallback? onDraftRestored,
  }) async {
    final source = presentationSource;
    if (source != null) {
      return source.selectChannel(
        next,
        autoRead: autoRead,
        navigate: navigate,
        retainContextUntilAccepted: retainContextUntilAccepted,
        preserveThread: preserveThread,
        onDraftRestored: onDraftRestored,
      );
    }
    final retainThread =
        preserveThread &&
        threadIdentity?.parentChannelId == next.id &&
        location.thread?.channelId == next.id;
    if (!retainContextUntilAccepted && channel?.id != next.id) {
      contextLoadError = null;
    }
    channel = next;
    hasNewer = false;
    if (!retainThread) highlightedMessageId = null;
    final priorWindow = messageWindows.accepted[next.id];
    final replyAuthority = _replyToken(next.id);
    final compatible =
        priorWindow != null &&
        priorWindow.matches(_windowAuthority(), replyAuthority);
    if (priorWindow != null && !compatible) {
      messageWindows.discardWindow(next.id);
      _summariesByChannel.remove(next.id);
    }
    hasMore = compatible && priorWindow.hasMore;
    historyLimited = compatible && priorWindow.historyLimited;
    // Keep the accepted context kind until its replacement tail is accepted.
    if (!retainContextUntilAccepted &&
        messageWindows.setContextMode(liveWindowWrite, next.id, null)) {
      messageWindows.hideWindow(next.id);
    }
    if (navigate) section = 'chat';
    if (!retainThread) {
      threadParent = null;
      threadChannelId = null;
      messageWindows.threadGeneration++;
    }
    loadingOlder = false;
    channelLoading = true;
    error = null;
    // Source messageStore selectChannel: opening a conversation clears its
    // local unread at once; the read receipt follows the first page. A load
    // that never sends the receipt reconciles with the server in `finally`.
    final optimisticRead =
        autoRead &&
        navigate &&
        !retainContextUntilAccepted &&
        ((unread[next.id] ?? 0) != 0 || mentions.contains(next.id));
    final readPostsBefore = _readPosts[next.id] ?? 0;
    _scrolledAway.reset(next.id);
    if (optimisticRead) {
      // Web `clearUnread`: the count and the mention flag clear together.
      if ((unread[next.id] ?? 0) != 0) unread = {...unread, next.id: 0};
      _clearMention(next.id);
      _persistUnread();
    }
    messageWindows.channelGeneration++;
    final request = _windowRequest(
      next.id,
      checkNavigation: true,
      allowed: () =>
          channel?.id == next.id && can('viewChannel', resource: channel),
    );
    notifyListeners();
    if (isPendingDm(next)) {
      // A DM that is not on the server yet has nothing to read: only its
      // saved draft, then the composer.
      await _restoreDraft(next.id);
      onDraftRestored?.call();
      if (request.current) {
        channelLoading = false;
        notifyListeners();
      }
      return;
    }
    // Source ChatPanel loads the channel's tasks with its messages: start the
    // bucket read now so the chips are cached when the rows first render.
    unawaited(MessageTaskCache.of(client).warm(this, next.id));
    await _restoreDraft(next.id);
    // The composer can take staged content from here on; the message page
    // below is still loading.
    onDraftRestored?.call();
    if (!request.current) return;
    try {
      final page = retainContextUntilAccepted && MessageHistoryPages.storage(cache) == null
          ? null
          : await _cached('window', next.id);
      if (!request.current) return;
      if (!retainContextUntilAccepted && await MessageHistoryPositions.restoreMain(this, request, next.id, cached: page)) {
        if (request.current) await _save('selection', '', next.id);
        return;
      }
      if (_restoreCachedTail(next.id, page, request, replace: retainContextUntilAccepted)) {
        notifyListeners();
      }
      final retained = retainContextUntilAccepted
          ? <Map<String, dynamic>>[]
          : messages.map((m) => m.json).toList();
      final retainedHasMore = hasMore;
      client.joinChannel(next.id);
      final fresh = await MessageHistoryPages.read(this, request, next.id);
      if (!request.current) return;
      _acceptFreshTail(
        next.id,
        fresh,
        retained: retained,
        retainedHasMore: retainedHasMore,
        request: request,
      );
      await MessageHistoryPages.record(this, request, fresh);
      if (!request.current) return;
      channelLoading = false;
      notifyListeners();
      await _saveWindow(next.id);
      if (!request.current) return;
      await _save('selection', '', next.id);
      if (request.current && autoRead) await markRead(next.id);
    } catch (e) {
      if (request.current) {
        if (e is RaftApiException && (e.status == 403 || e.status == 404)) {
          _revokeChannel(next.id);
        } else {
          error = userErrorText(e, where: 'select channel');
        }
      }
    } finally {
      if (request.current) {
        channelLoading = false;
        notifyListeners();
      }
      if (optimisticRead &&
          !_disposed &&
          (_readPosts[next.id] ?? 0) == readPostsBefore) {
        unawaited(refreshUnread());
      }
    }
  }

  /// Reconciles a freshly read first page into the open channel's window: the
  /// page is authoritative over its own range, older retained rows stay, and
  /// nothing outside the page range is dropped. Shared by the open and by the
  /// silent revalidation of a retained window.
  void _acceptFreshTail(
    String id,
    Map<String, dynamic> fresh, {
    required List<Map<String, dynamic>> retained,
    required bool retainedHasMore,
    required MessageWindowRequest request,
  }) {
    if (!request.current) return;
    final rows = acceptedWindowRows(fresh['messages'], id);
    messageWindows.setDiskOnly(request, id, false);
    historyLimited = fresh['historyLimited'] == true;
    messageWindows.acceptRows(
      request,
      id,
      rows,
      visible: historyLimited
          ? rows.map((e) => e['id'] as String)
          : reconcileTailWindow(retained, rows),
      replace: true,
    );
    MessageHistorySummaries.accept(this, id, retained, rows, fresh);
    hasMore =
        fresh['historyLimited'] != true &&
        (visibleIds[id]!.length > rows.length
            ? retainedHasMore
            : rows.length >= 50);
  }

  /// Source ChatPanel shows a retained bucket at once and re-reads the tail
  /// behind it. Used where a held window is shown without [selectChannel]
  /// (a jump to a message the window holds, a live seq gap): the first page is
  /// merged into the open window by [_acceptFreshTail], so rows already shown
  /// keep their place and only the missing newer rows are added.
  Future<void> _revalidateTail(String id) async {
    if (channel?.id != id || !messageWindows.beginTailRevalidation(id)) {
      return;
    }
    final request = _windowRequest(
      id,
      allowed: () =>
          channel?.id == id &&
          !hasNewer &&
          can('viewChannel', resource: channel),
    );
    try {
      final retained = messages.map((m) => m.json).toList();
      final retainedHasMore = hasMore;
      final fresh = await MessageHistoryPages.read(this, request, id);
      if (!request.current) return;
      _acceptFreshTail(
        id,
        fresh,
        retained: retained,
        retainedHasMore: retainedHasMore,
        request: request,
      );
      await MessageHistoryPages.record(this, request, fresh);
      if (!request.current) return;
      notifyListeners();
      await _saveWindow(id);
    } catch (e) {
      if (request.current &&
          e is RaftApiException &&
          (e.status == 403 || e.status == 404)) {
        _revokeChannel(id);
      }
      // Any other failure leaves the shown window as it was.
    } finally {
      messageWindows.endTailRevalidation(id);
    }
  }

  Future<void> older({bool thread = false}) => _windowReceiver._older(thread);

  Future<void> newer({bool thread = false}) =>
      _windowReceiver._pageHistory(thread, newer: true);
  Future<void> loadHistoryGap(BigInt before, {bool thread = false}) =>
      _windowReceiver._pageHistory(thread, gapBefore: before);
  Future<void> _older(bool thread) => _pageHistory(thread);
  Future<void> _pageHistory(bool thread, {bool newer = false, BigInt? gapBefore}) =>
      MessageHistoryNavigation.page(this, thread: thread, newer: newer,
        gapBefore: gapBefore,
        requestFor: (id) => _windowRequest(id, thread: thread),
        summaries: mergeThreadSummaries);

  bool _mayMarkRead(String id) {
    if (!foreground ||
        id == channel?.id &&
            (!_mainPresented ||
                !_chatTabPresented ||
                hasNewer ||
                channelLoading) ||
        id == threadChannelId && !_threadPresented ||
        id != channel?.id && id != threadChannelId) {
      return false;
    }
    final current = location, content = current.content;
    final previewMounted =
        current.route == RaftRoute.search ||
        current.route == RaftRoute.activity;
    if (id == channel?.id) {
      // Source mobile thread folds the parent channel immediately from the URI.
      // A prior Activity layout callback cannot admit its concurrently loaded tail.
      if (mobileNavigation && current.thread != null) return false;
      return (current.route == RaftRoute.channel ||
                  current.route == RaftRoute.dm) &&
              current.entityId == channel?.id ||
          previewMounted &&
              (content?.kind == RaftContentKind.channel ||
                  content?.kind == RaftContentKind.dm) &&
              content?.id == channel?.id;
    }
    // The initial admission guard already restricted this id to the open thread.
    return current.thread != null &&
            current.thread?.channelId == threadParentChannelId &&
            current.thread?.itemId == threadParentMessageId ||
        previewMounted &&
            content?.kind == RaftContentKind.thread &&
            content?.id == threadChannelId;
  }

  /// Open conversations whose timeline is scrolled above the latest end
  /// (reported by the chat view on the edge only, never per frame).
  RaftTimelineBottoms get _scrolledAway => conversationReads.scrolledAway;

  void setTimelineAtBottom(String id, bool atBottom) =>
      conversationReads.setTimelineAtBottom(id, atBottom);

  /// Where the reader was in a conversation when its timeline is about to be
  /// rebuilt for another layout (fold / unfold). The next timeline that
  /// mounts for [conversationId] shortly after resumes there; an anchor that
  /// is not claimed promptly is a stale position and is ignored.
  void saveReadingAnchor(String conversationId, ReadingAnchor anchor) {
    messageWindows.saveReadingAnchor(conversationId, anchor);
    MessageHistoryPositions.save(this, conversationId, anchor);
  }
  ReadingAnchor? takeReadingAnchor(String conversationId) =>
      messageWindows.takeReadingAnchor(conversationId);

  /// Read receipts sent per scope: lets an optimistic open-time clear know
  /// whether the receipt that backs it was ever sent.
  Map<String, int> get _readPosts => conversationReads.readPosts;

  Future<void> markRead(String id) => _windowReceiver._markRead(id);

  /// Windows painted from disk whose first fresh page has not arrived yet.
  /// Their tail may be stale, so they never send a read receipt (nor clear
  /// the unread count) until revalidated.

  Future<void> _markRead(String id) => conversationReads.markRead(id);

  /// Source acceptActivityReadAllAck: an Activity row's persisted read-all
  /// receipt is a read-state fact for [scopeId]. Folding it into the ledger is
  /// what keeps a stale inbox response from re-presenting the row as unread.
  /// Returns false for an invalid receipt or a changed identity.
  bool acceptReadAllAck(
    String scopeId,
    dynamic receipt, {
    required String serverId,
    required String principalId,
  }) => conversationReads.acceptReadAllAck(
    scopeId,
    receipt,
    serverId: serverId,
    principalId: principalId,
  );

  Future<bool> send(
    String text, {
    bool thread = false,
    List<String>? attachments,
    List<Map<String, dynamic>>? mentions,
    String? randomId,
    bool asTask = false,
    String Function(int count)? attachmentsOnlyBody,
    void Function(int window)? onWindowRefreshed,
  }) async {
    final source = presentationSource;
    if (source != null) {
      return source.send(
        text,
        thread: thread,
        attachments: attachments,
        mentions: mentions,
        randomId: randomId,
        asTask: asTask,
        attachmentsOnlyBody: attachmentsOnlyBody,
        onWindowRefreshed: onWindowRefreshed,
      );
    }
    if (conversationPaused) {
      error = 'Channel conversion in progress';
      notifyListeners();
      return false;
    }
    // Shared content whose destination is not confirmed yet is never sent.
    if (sharedBlocked(thread: thread)) return false;
    error = null;
    final intendedScope = draftScope(thread: thread);
    if (intendedScope == null) return false;
    final scope = intendedScope, intendedChannel = channel?.id;
    final intendedParent = threadParentMessageId, role = server?.string('role');
    var window = thread ? threadGeneration : channelGeneration;
    bool current() =>
        !_disposed &&
        scope == draftScope(thread: thread) &&
        intendedChannel == channel?.id &&
        (!thread || intendedParent == threadParentMessageId) &&
        window == (thread ? threadGeneration : channelGeneration) &&
        role == server?.string('role') &&
        !conversationPaused;
    final selectedMentions = [
      for (final mention in mentions ?? <Map<String, dynamic>>[])
        Map<String, dynamic>.unmodifiable({
          'type': mention['type'],
          'id': mention['id'],
          'name': mention['name'],
        }),
    ];
    return composer.sends.send(
      text,
      client: client,
      attachments: attachments,
      mentions: selectedMentions,
      randomId: randomId,
      asTask: asTask,
      attachmentsOnlyBody:
          attachmentsOnlyBody ??
          (count) => count == 1 ? '[1 attachment]' : '[$count attachments]',
      visit: ComposerSendVisit(
        scope: scope,
        channelId: thread ? threadChannelId : intendedChannel,
        parentChannelId: intendedChannel,
        displaySeq: ledger.watermark,
        author: {
          'senderId': client.user?.id ?? '',
          'senderType': 'user',
          'senderName':
              client.user?.firstNonEmpty(const ['displayName', 'name']) ?? '',
        },
        current: current,
        prepare: () async {
          if (!thread && hasNewer && channel != null) {
            final refreshing = selectChannel(channel!);
            window = channelGeneration;
            await refreshing;
            if (!current()) return null;
            onWindowRefreshed?.call(window);
          }
          if (!current()) return null;
          return thread ? await ensureThread() : intendedChannel;
        },
        limit: uploadLimitBytes,
        transfer: (file) => _transferUpload(file, thread: thread),
        started: () {
          _composerNotices.clear(scope);
          sendWarnings.remove(scope);
        },
        failed: (cause) {
          error = userErrorText(
            cause,
            fallback: 'Failed to send message',
            where: 'send message',
          );
          notifyListeners();
        },
        received: (sent) {
          pendingMentionActions[scope] = normalizePendingMentionActions(
            sent.receipt['pendingMentionActions'],
          );
          sendWarnings[scope] = (
            unresolved: [
              for (final handle
                  in (sent.receipt['unresolvedMentionHandles'] as List? ??
                      const []))
                if (handle is String) handle,
            ],
            agentStopped:
                (sent.receipt['deliveryWarnings'] as List? ?? const []).any(
                  (w) =>
                      w is Map &&
                      w['targetType'] == 'agent' &&
                      w['reason'] == 'agent_stopped' &&
                      w['targetId'] is String &&
                      (w['targetId'] as String).isNotEmpty,
                ),
          );
        },
      ),
    );
  }

  /// Project session delivery into each existing accepted window. This does
  /// not create another ledger or move a page's current selection.
  void _sendChanged(String scope, RaftMessage? accepted) {
    if (_disposed) return;
    final selected = scope == draftScope() || scope == draftScope(thread: true);
    if (accepted != null && !_revokedChannels.contains(accepted.channelId)) {
      final id = accepted.channelId;
      if (id == channel?.id && !hasNewer ||
          id == threadChannelId ||
          messageWindows.retainsLiveTail(id)) {
        messageWindows.acceptRows(liveWindowWrite, id, [accepted.json]);
        unawaited(_saveWindow(id, thread: id == threadChannelId));
      }
    }
    if (selected) notifyListeners();
  }

  Future<String?> ensureThread() async {
    if (presentationSource != null) return presentationSource!.ensureThread();
    if (threadChannelId != null) return threadChannelId;
    return messageWindows.createThread(_createThread);
  }

  Future<String?> _createThread() async {
    final parentId = threadParentMessageId,
        parentChannelId = threadParentChannelId;
    if (parentId == null || parentChannelId == null) return null;
    final request = _windowRequest(
      parentChannelId,
      thread: true,
      checkNavigation: true,
      allowed: () =>
          parentId == threadParentMessageId &&
          parentChannelId == threadParentChannelId,
    );
    final value = await client.post(
      '/channels/$parentChannelId/threads',
      data: {'parentMessageId': parentId},
    );
    if (!request.current) {
      throw const RaftApiException('The thread changed. Please retry.');
    }
    threadChannelId = value['threadChannelId'];
    client.joinChannel(threadChannelId!);
    notifyListeners();
    return threadChannelId;
  }

  Future<void> openThread(
    RaftMessage parent, {
    String? focusedMessageId,
    bool navigate = true,
  }) => _windowReceiver._openThreadIdentity(
    parent.channelId,
    parent.id,
    focusedMessageId: focusedMessageId,
    navigate: navigate,
    acceptedParent: parent,
  );

  /// Opens a real thread identity independently of its parent metadata.
  /// [initialThreadChannelId] is the accepted inbox row's existing channel;
  /// Source opens that channel immediately without a resolution lookup.
  @override
  Future<void> openThreadIdentity({
    required String parentChannelId,
    required String parentMessageId,
    String? focusedMessageId,
    String? initialThreadChannelId,
    bool navigate = true,
  }) => _windowReceiver._openThreadIdentity(
    parentChannelId,
    parentMessageId,
    focusedMessageId: focusedMessageId,
    initialThreadChannelId: initialThreadChannelId,
    navigate: navigate,
  );

  Future<void> _openThreadIdentity(
    String parentChannelId,
    String parentMessageId, {
    String? focusedMessageId,
    String? initialThreadChannelId,
    bool navigate = true,
    RaftMessage? acceptedParent,
  }) async {
    if (parentChannelId.trim().isEmpty || parentMessageId.trim().isEmpty) {
      return;
    }
    final knownThreadChannelId = initialThreadChannelId?.trim().isEmpty == false
        ? initialThreadChannelId
        : null;
    if (_revokedChannels.contains(parentChannelId) ||
        _revokedChannels.contains(knownThreadChannelId) ||
        !can(
          'viewChannel',
          resource: _threadChannelResource(parentChannelId),
        )) {
      return;
    }
    if (navigate) {
      final next = location.withQuery({
        'thread': '$parentChannelId:$parentMessageId',
        'msg': ?focusedMessageId,
      });
      navigation.navigate(next, kind: location.panelNavigationKindTo(next));
    }
    final navigationWindow = navigationRevision,
        requestAuthority = _replyToken(parentChannelId),
        messageAuthority = _threadResourceAuthority(parentChannelId),
        generation = ledger.generation;
    messageWindows.threadGeneration++;
    final request = messageWindows.request(
      thread: true,
      allowed: () =>
          navigationWindow == navigationRevision &&
          requestAuthority == _replyToken(parentChannelId) &&
          (messageAuthority == null ||
              messageAuthority == _threadResourceAuthority(parentChannelId)) &&
          !_revokedChannels.contains(parentChannelId) &&
          !_revokedChannels.contains(threadChannelId) &&
          can('viewChannel', resource: _threadChannelResource(parentChannelId)),
    );
    _threadIdentity = WorkspaceThreadIdentity(
      parentChannelId: parentChannelId,
      parentMessageId: parentMessageId,
      focusedMessageId: focusedMessageId,
    );
    _threadVisit = request;
    final held = messageWindows.matchingThread(
      parentChannelId,
      parentMessageId,
      requestAuthority,
      messageAuthority,
    );
    final cached =
        held != null &&
            (knownThreadChannelId == null ||
                knownThreadChannelId == held.threadChannelId) &&
            (visibleIds[held.threadChannelId]?.isNotEmpty ?? false) &&
            (focusedMessageId == null ||
                visibleIds[held.threadChannelId]!.contains(focusedMessageId))
        ? held
        : null;
    if (cached == null) messageWindows.forgetThread(parentMessageId);
    threadParent = acceptedParent ?? cached?.parent;
    threadChannelId = knownThreadChannelId ?? cached?.threadChannelId;
    threadLoading = cached == null;
    _threadResolutionLoading = threadChannelId == null;
    _threadParentLoading = threadParent == null;
    _threadResolutionError = null;
    threadHasMore = cached?.hasMore ?? false;
    threadHistoryLimited = cached?.historyLimited ?? false;
    highlightedMessageId = focusedMessageId;
    notifyListeners();
    Future<void> restoreCurrentDraft() async {
      final scope = 'thread:$parentMessageId';
      if (await composer.restoreText(scope, () => request.current)) {
        notifyListeners();
      }
    }

    unawaited(restoreCurrentDraft());

    Future<void> resolveParent() async {
      if (acceptedParent != null) return;
      try {
        final page = await client.get(
          '/messages/context/$parentMessageId',
          query: {'channelId': parentChannelId},
        );
        if (!request.current) return;
        final rows = acceptedWindowRows(page['messages'], parentChannelId);
        final parent = rows
            .where((row) => row['id'] == parentMessageId)
            .firstOrNull;
        // Independently fetched parent metadata is not an accepted outer window.
        final liveParent = channel?.id == parentChannelId
            ? messages.where((row) => row.id == parentMessageId).firstOrNull
            : null;
        final resolved =
            liveParent ?? (parent == null ? null : RaftMessage(parent));
        // A background revalidation never takes away a shown parent.
        if (resolved != null || threadParent == null) threadParent = resolved;
        messageWindows.cacheThreadParent(
          request,
          parentMessageId,
          threadParent,
        );
      } catch (_) {
        if (!request.current) return;
        if (cached?.parent == null) threadParent = null;
      } finally {
        if (request.current) {
          _threadParentLoading = false;
          notifyListeners();
        }
      }
    }

    Map<String, dynamic>? readingPage;
    Future<void> resolveReplies() async {
      try {
        if (threadChannelId == null) {
          dynamic info;
          try {
            info = await client.get(
              '/channels/$parentChannelId/threads/$parentMessageId',
            );
          } on RaftApiException catch (e) {
            // Only the route's explicit "no thread for this message" 404 is an
            // empty thread; any other failure raises the in-panel Retry.
            if (!isThreadAbsentLookupError(e)) rethrow;
          }
          if (!request.current) return;
          _threadResolutionLoading = false;
          if (info == null) return;
          threadChannelId = info['threadChannelId'];
          if (!request.current) return;
          notifyListeners();
        }
        readingPage ??= focusedMessageId == null ? await MessageHistoryPositions.restore(this, request, threadChannelId!, thread: true) : null;
        final focused = focusedMessageId != null || readingPage != null;
        final page = readingPage ?? (focusedMessageId == null
            ? await MessageHistoryPages.read(this, request, threadChannelId!, thread: true)
            : await MessageHistoryPages.context(this, request, threadChannelId!, focusedMessageId, thread: true));
        if (!request.current) return;
        final boundary = messageWindows.acceptThreadPage(
          request, threadChannelId!, page,
          focused: focused,
          retainOlder: cached?.contextWindow == false || cached == null && messageWindows.isDiskOnly(threadChannelId),
          retainedHasMore: threadHasMore,
        );
        await MessageHistoryPages.record(this, request, page);
        if (!request.current) return;
        threadHistoryLimited = boundary.limited;
        threadHasMore = boundary.more;
        client.joinChannel(threadChannelId!);
        threadLoading = false;
        messageWindows.cacheThread(
          request,
          parentMessageId,
          CachedMessageThread(
            parentChannelId,
            threadChannelId!,
            requestAuthority,
            messageAuthority,
            generation,
            threadHasMore,
            threadHistoryLimited,
            threadParent ?? cached?.parent,
            contextWindow: focused,
          ),
        );
        messageWindows.setContextMode(request, threadChannelId!,
          focused ? page['hasNewer'] == true : null);
        notifyListeners();
        await markRead(threadChannelId!);
        if (request.current) _saveWindow(threadChannelId!, thread: true);
      } catch (e) {
        final denied = threadChannelId;
        if (request.current && denied != null && e is RaftApiException &&
            (e.status == 403 || e.status == 404)) {
          _revokeChannel(denied);
          threadLoading = false;
          _threadResolutionLoading = false;
          notifyListeners();
        }
        // A cached window stays readable when its revalidation fails.
        if (request.current && cached == null) {
          // ThreadPanel's in-panel "Couldn't load this thread" + Retry; Web raises
          // no workspace-level error for it.
          _threadResolutionError = userErrorText(
            e,
            fallback: "Couldn't load this thread",
            where: 'open thread',
          );
        }
      } finally {
        if (request.current) {
          _threadResolutionLoading = false;
          threadLoading = false;
          notifyListeners();
        }
      }
    }

    /// A tail thread with no window in memory paints its on-device window
    /// (previous visit or previous process) while the lookup revalidates.
    Future<void> restoreDiskWindow() async {
      if (cached != null && !cached.contextWindow || focusedMessageId != null) return;
      final page = await _cached('thread-window', parentMessageId);
      if (!request.current || !threadLoading && cached?.contextWindow != true || page is! Map) return;
      final threadId = page['threadChannelId'];
      if (page['version'] != 1 ||
          page['windowKind'] != 'tail' ||
          messageAuthority == null ||
          page['authority'] != messageAuthority ||
          page['parentChannelId'] != parentChannelId ||
          threadId is! String ||
          (threadChannelId != null && threadChannelId != threadId) ||
          _revokedChannels.contains(threadId)) {
        return;
      }
      readingPage = await MessageHistoryPositions.restoreThread(this, request, threadId, page);
      if (readingPage != null) { _threadResolutionLoading = false; _threadParentLoading = threadParent == null; return; }
      final rows = acceptedWindowRows(page['messages'], threadId);
      if (rows.isEmpty) return;
      messageWindows.acceptRows(request, threadId, rows, replace: true);
      messageWindows.setDiskOnly(request, threadId, true);
      messageWindows.setContextMode(request, threadId, null);
      threadChannelId = threadId;
      final parent = page['parent'];
      if (threadParent == null &&
          parent is Map &&
          parent['id'] == parentMessageId &&
          parent['channelId'] == parentChannelId) {
        threadParent = RaftMessage(Map<String, dynamic>.from(parent));
        _threadParentLoading = false;
      }
      threadHasMore = page['hasMore'] == true;
      threadHistoryLimited = page['historyLimited'] == true;
      threadLoading = false;
      _threadResolutionLoading = false;
      notifyListeners();
    }

    await restoreDiskWindow();
    if (!request.current) return;
    // Source threadStore opens an accepted inbox row's known channel directly,
    // without a lookup. Parent metadata and focused replies load independently.
    final replies = resolveReplies();
    unawaited(resolveParent());
    await replies;
  }

  /// Clears only the focus owned by the mounted timeline's highlight timer.
  void clearHighlightedMessage(
    String? expectedId, {
    int? expectedNavigationRevision,
  }) {
    if (presentationSource != null) {
      if (presentationActive) {
        presentationSource!.clearHighlightedMessage(
          expectedId,
          expectedNavigationRevision: expectedNavigationRevision,
        );
      }
      return;
    }
    if (highlightedMessageId != expectedId ||
        expectedNavigationRevision != null &&
            expectedNavigationRevision != navigationRevision) {
      return;
    }
    final identity = threadIdentity;
    if (expectedId != null &&
        expectedNavigationRevision != null &&
        identity != null &&
        identity.focusedMessageId == expectedId &&
        threadChannelId != null) {
      navigation.consumeThreadFocus(
        threadChannelId: threadChannelId!,
        parentChannelId: identity.parentChannelId,
        parentMessageId: identity.parentMessageId,
        expectedMessageId: expectedId,
        expectedRevision: expectedNavigationRevision,
      );
    }
    highlightedMessageId = null;
    notifyListeners();
  }

  /// Source ChatPanel.handleBackToBottom reloads latest when newer is unloaded.
  Future<void> returnToLatest({bool navigate = true, bool thread = false}) =>
      MessageHistoryNavigation.latest(_windowReceiver, thread: thread, navigate: navigate);

  /// [replaceEntry] makes the destination take over the current history
  /// entry instead of pushing (Web openThreadParentMessageRoute, mobile).
  Future<void> jumpToMessage(
    String channelId,
    String? messageId, {
    bool navigate = true,
    bool replaceEntry = false,
  }) async {
    final source = presentationSource;
    if (source != null) {
      return source.jumpToMessage(
        channelId,
        messageId,
        navigate: navigate,
        replaceEntry: replaceEntry,
      );
    }
    contextLoadError = null;
    final generation = ledger.generation;
    var navigationWindow = navigationRevision;
    var authority = _windowAuthority();
    final replyAuthority = _replyToken(channelId);
    messageWindows.channelGeneration++;
    final request = messageWindows.request(
      thread: false,
      allowed: () =>
          navigationWindow == navigationRevision &&
          authority == _windowAuthority() &&
          replyAuthority == _replyToken(channelId) &&
          !_revokedChannels.contains(channelId),
    );
    if (_rejectRevokedConversation(channelId) || !request.current) return;
    var next = [
      ...channels,
      ...dms,
    ].where((c) => c.id == channelId).firstOrNull;
    try {
      next ??= RaftChannel(
        Map<String, dynamic>.from(await client.get('/channels/$channelId')),
      );
    } catch (_) {
      // Source ChannelById/ensureChannel resolves failed metadata to its
      // unavailable body. UI callbacks may not await this request; neither a
      // global async exception nor a retained conversation owns the failure.
      if (request.current) {
        _missingConversationChannelId = channelId;
        notifyListeners();
      }
      return;
    }
    if (!request.current || !can('viewChannel', resource: next)) return;
    if (messageId == null) {
      await selectChannel(next, navigate: navigate);
      return;
    }
    final sameChannel = channel?.id == channelId;
    authority = messageWindowAuthority(server?.string('role'), next.json);
    final knownWindow = messageWindows.accepted[channelId];
    final compatibleWindow =
        knownWindow?.matches(authority, replyAuthority) == true;
    final cachedTarget =
        compatibleWindow &&
        messageWindows.containsVisible(channelId, messageId);
    channel = next;
    if (navigate) {
      if (replaceEntry && server != null) {
        _unboundSection = 'chat';
        bindNavigation();
        navigation.selectSection(
          'chat',
          channelId: channelId,
          dm: next.type == 'dm',
          kind: RaftNavigationKind.replace,
        );
      } else {
        section = 'chat';
      }
      navigation.navigate(
        location.withQuery({'msg': messageId}),
        kind: RaftNavigationKind.replace,
      );
      navigationWindow = navigationRevision;
    }
    threadParent = null;
    threadChannelId = null;
    messageWindows.threadGeneration++;
    loadingOlder = false;
    error = null;
    highlightedMessageId = messageId;
    if (cachedTarget) {
      MessageHistoryPages.recheckContext(this, request, channelId, messageId);
      hasMore = sameChannel ? hasMore : knownWindow!.hasMore;
      hasNewer = sameChannel
          ? hasNewer
          : messageWindows.contextHasNewer(channelId);
      historyLimited = messageWindows.historyLimit(channelId);
      channelLoading = false;
      messageWindows.finishContextVisit(request);
      notifyListeners();
      // The held window is shown at once, but a window this channel left (or
      // that came from disk) may be behind the server: read the tail quietly
      // and merge it without moving the reading position.
      if ((!sameChannel || messageWindows.isDiskOnly(channelId)) &&
          !hasNewer &&
          !messageWindows.isContext(channelId)) {
        unawaited(_revalidateTail(channelId));
      }
      return;
    }
    channelLoading = true;
    // Source preserves the destination's already accepted memory bucket while
    // its context GET waits. A disk/unaccepted bucket or an earlier principal,
    // server or capability epoch cannot grant this cross-channel projection.
    messageWindows.beginContextVisit((
      channelId: channelId,
      request: request,
      retainRows: sameChannel || compatibleWindow,
    ));
    if (!sameChannel) {
      // Held summaries belong to the held window; an incompatible window
      // takes its summaries with it.
      if (!compatibleWindow) _summariesByChannel.remove(channelId);
      if (compatibleWindow) {
        hasMore = knownWindow!.hasMore;
        hasNewer = messageWindows.contextHasNewer(channelId);
        historyLimited = messageWindows.historyLimit(channelId);
      }
    }
    bool current() =>
        request.current &&
        channel?.id == channelId &&
        can('viewChannel', resource: channel);
    void settled() {
      messageWindows.finishContextVisit(request);
      channelLoading = false;
      notifyListeners();
    }

    notifyListeners();
    try {
      final context = await MessageHistoryPages.context(this, request, channelId, messageId);
      if (!current()) return;
      final target = context['canonicalTarget'];
      if (target is Map && target['kind'] == 'thread') {
        final parentId = target['threadParentMessageId'] as String;
        final parentChannelId = target['channelId'] as String? ?? channelId;
        final opening = openThreadIdentity(
          parentChannelId: parentChannelId,
          parentMessageId: parentId,
          focusedMessageId: target['messageId'] as String? ?? messageId,
          navigate: navigate,
        );
        if (navigate) navigationWindow = navigationRevision;
        await opening;
        if (!current()) return;
        // Source loadMessageContext opens the canonical thread, then loads the
        // outer channel tail. Keep both accepted rows and reply focus while it
        // is pending; do not pass through selectChannel's thread reset/cache.
        try {
          final tail = await MessageHistoryPages.read(this, request, channelId);
          if (!current()) return;
          final accepted = _acceptContextPage(
            request,
            channelId,
            tail,
            context: false,
          );
          await MessageHistoryPages.record(this, request, tail);
          if (!current()) return;
          final refreshedParent = accepted
              .where((row) => row['id'] == parentId)
              .firstOrNull;
          if (parentChannelId == channelId && refreshedParent != null) {
            threadParent = RaftMessage(refreshedParent);
          }
          settled();
          await markRead(channelId);
          if (current()) await _saveWindow(channelId);
        } catch (e) {
          if (!current()) return;
          if (e is RaftApiException && e.status == 403) {
            _revokeChannel(channelId);
          } else {
            error = userErrorText(e, where: 'load message context');
            settled();
          }
        }
      } else {
        _acceptContextPage(request, channelId, context);
        await MessageHistoryPages.record(this, request, context);
        if (!current()) return;
        final targetId = context['targetMessageId'] as String? ?? messageId;
        highlightedMessageId = targetId;
        settled();
        await markRead(channelId);
      }
    } catch (e) {
      if (!current()) return;
      if (e is RaftApiException && e.status == 403) {
        _revokeChannel(channelId);
      } else {
        messageWindows.finishContextVisit(request);
        highlightedMessageId = null;
        // Source falls back to latest after a missing/unavailable context.
        final fallback = selectChannel(
          next,
          navigate: navigate,
          retainContextUntilAccepted: true,
        );
        await fallback;
        if (!_disposed &&
            channel?.id == channelId &&
            generation == ledger.generation &&
            authority == _windowAuthority()) {
          contextLoadError = historyLimited
              ? MessageContextLoadError.beyondHistory
              : MessageContextLoadError.notFound;
          notifyListeners();
        }
      }
    } finally {
      if (current()) {
        settled();
      }
    }
  }

  /// Context and canonical-thread fallback pages publish the same accepted
  /// row versions, boundaries and reply summaries before any notification.
  List<Map<String, dynamic>> _acceptContextPage(
    MessageWindowRequest request,
    String id,
    dynamic page, {
    bool context = true,
  }) {
    if (!request.current) return [];
    final rows = acceptedWindowRows(page['messages'], id);
    historyLimited = !context && page['historyLimited'] == true;
    hasMore = context
        ? page['hasOlder'] == true
        : !historyLimited && rows.length >= 50;
    hasNewer = context && page['hasNewer'] == true;
    messageWindows.rememberWindow(
      request,
      id,
      _windowAuthority(),
      hasMore,
      _replyToken(id),
      historyLimited: historyLimited,
      rows: rows,
      replace: true,
    );
    messageWindows.setContextMode(request, id, context ? hasNewer : null);
    mergeThreadSummaries(id, page['threadSummariesByParentMessageId']);
    return rows;
  }

  /// Web ChatPanel `joinChannel(channel.id)`: join the open channel, then
  /// re-read the channel list so the sidebar and composer see the membership.
  Future<void> joinOpenChannel() async {
    try {
      final c = channel!;
      await command('POST', '/channels/${c.id}/join');
      await refreshChannels();
      await selectChannel(channels.firstWhere((next) => next.id == c.id));
    } catch (e) {
      if (!_disposed && !_staleScope(e)) {
        // ignore: raft_lints/avoid_imperative_notice_state -- User-initiated join; stale-scope failures are not reported; cleared on server switch or revoke.
        setError(userErrorText(e, where: 'join channel'));
      }
    }
  }

  /// Web ThreadPanel `handleJoinParentChannel`: join the thread's parent
  /// channel (the CTA that replaces the composer for a non-member).
  Future<void> joinThreadParentChannel() async {
    final id = threadParentChannelId;
    if (id == null) return;
    try {
      await command('POST', '/channels/$id/join');
      await refreshChannels();
    } catch (e) {
      if (!_disposed && !_staleScope(e)) {
        // ignore: raft_lints/avoid_imperative_notice_state -- User-initiated join; stale-scope failures are not reported; cleared on server switch or revoke.
        setError(userErrorText(e, where: 'join thread parent channel'));
      }
    }
  }

  // Web profileStore: the profile side panel is a URL slot (`profile=`); an
  // external author's frozen attribution payload lives beside it.
  final Map<String, Map<String, dynamic>> _externalProfiles = {};

  /// The provider attribution frozen when an external author's panel opened.
  Map<String, dynamic>? externalProfile(String messageId) =>
      presentationSource?.externalProfile(messageId) ??
      _externalProfiles[messageId];

  /// Web `openProfile` / `openExternalProfile`: a human or agent (optionally
  /// landing on an agent [agentTab]) or an external message author
  /// ([id] = message id, [channelId] its channel, [externalAuthor] the
  /// attribution). Adding a panel pushes history; retargeting replaces.
  void openProfile(
    RaftProfileKind kind,
    String id, {
    String? agentTab,
    String? channelId,
    Map<String, dynamic>? externalAuthor,
  }) {
    final source = presentationSource;
    if (source != null) {
      source.openProfile(
        kind,
        id,
        agentTab: agentTab,
        channelId: channelId,
        externalAuthor: externalAuthor,
      );
      return;
    }
    if (id.trim().isEmpty ||
        kind == RaftProfileKind.external && (channelId?.isEmpty ?? true)) {
      return;
    }
    if (externalAuthor != null) _externalProfiles[id] = externalAuthor;
    final next = location.withQuery({
      'profile': RaftProfileLocation(kind, id, channelId: channelId).toString(),
      'agentTab': kind == RaftProfileKind.agent ? agentTab : null,
    });
    if (next.uri == location.uri) return;
    navigation.navigateProfile(
      next,
      kind: location.panelNavigationKindTo(next),
    );
    notifyListeners();
  }

  /// Web `closeProfile`: removing a slot replaces the history entry.
  void closeProfile() {
    final source = presentationSource;
    if (source != null) {
      source.closeProfile();
      return;
    }
    if (location.profile == null) return;
    final next = location.withQuery({'profile': null, 'agentTab': null});
    navigation.navigateProfile(
      next,
      kind: location.panelNavigationKindTo(next),
    );
    notifyListeners();
  }

  void closeThread({bool navigate = true}) =>
      _windowReceiver._closeThread(navigate);

  void _closeThread(bool navigate) {
    if (navigate && location.thread != null) {
      final next = location.withQuery({'thread': null});
      navigation.navigate(next, kind: location.panelNavigationKindTo(next));
    }
    messageWindows.threadGeneration++;
    _threadIdentity = null;
    _threadVisit = null;
    _threadResolutionLoading = _threadParentLoading = false;
    _threadResolutionError = null;
    threadParent = null;
    threadChannelId = null;
    threadLoading = false;
    threadHistoryLimited = false;
    notifyListeners();
  }

  void setSection(String next) {
    if (!NavigationRegistry.knowsSection(next)) {
      NavigationRegistry.reportFallback(
        'section',
        next,
        NavigationRegistry.unsupportedSections[next],
      );
      return;
    }
    final source = presentationSource;
    if (source != null) {
      source.setSection(next);
      return;
    }
    if (!canVisitSection(next)) return;
    section = next;
    notifyListeners();
  }

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) =>
      presentationSource?.sharedQuery(path, query: query) ??
      apiGateway.query(path, query: query);

  /// Compatibility facade; all presentations share [attachmentMedia].
  PlayerSessions get playerSessions => attachmentMedia.playerSessions;

  @visibleForTesting
  AttachmentUrlCache get debugAttachmentUrls => attachmentMedia.debugUrls;

  Future<String> attachmentUrl(
    String id, {
    String? disposition = 'inline',
    String? channelId,
    bool refresh = false,
    bool coalesce = false,
  }) => attachmentMedia.url(
    id,
    disposition: disposition,
    channelId: channelId,
    refresh: refresh,
    coalesce: coalesce,
  );

  Future<bool> attachmentPreviewEnabled() => attachmentMedia.previewEnabled();

  /// Coalesce identical concurrent reads, retaining this facade's query
  /// override and giving each caller its own copy of the decoded response.
  @override
  Future<dynamic> sharedQuery(String path, {Map<String, dynamic>? query}) =>
      apiGateway.sharedQuery(
        path,
        query: query,
        readerKey: this,
        scopeClient: client,
        read: this.query,
      );

  /// A deep copy of a decoded response, so consumers never share its maps.
  static dynamic copyDecoded(dynamic value) =>
      RaftApiGateway.copyDecoded(value);

  int savedRevision = 0;
  @override
  Future<dynamic> command(String method, String path, {dynamic data}) async {
    if (presentationSource != null) {
      return presentationSource!.command(method, path, data: data);
    }
    return apiGateway.command(method, path, data: data);
  }

  Future<void> hydrateReactionViewer(RaftMessage message) async {
    if (presentationSource != null) {
      return presentationSource!.hydrateReactionViewer(message);
    }
    if (reactionViewer.reacted(message.id) != null ||
        _viewerLoads.containsKey(message.id) ||
        channel?.archived == true) {
      return;
    }
    final generation = ledger.generation, serverId = client.serverId;
    if (serverId == null) return;
    Future<void> load() async {
      try {
        final snapshot = await client.get(
          '/messages/${message.id}/reactions/viewer',
        );
        if (_disposed ||
            generation != ledger.generation ||
            _revokedChannels.contains(message.channelId)) {
          return;
        }
        if (reactionViewer.accept(snapshot, serverId: serverId) == 'accepted') {
          notifyListeners();
        }
      } catch (_) {
        /* A click retries explicitly and reports an actionable error. */
      }
    }

    final pending = load();
    _viewerLoads[message.id] = pending;
    try {
      await pending;
    } finally {
      if (identical(_viewerLoads[message.id], pending)) {
        _viewerLoads.remove(message.id);
      }
    }
  }

  /// Reaction toggles in flight per message, so a presented row shows the
  /// viewer's own state at once (Web `pendingReactionTargetsRef`).
  final Map<String, Map<String, PendingReaction>> _pendingReactions = {};

  /// The state each pending toggle is heading for (null when none).
  Map<String, bool>? pendingReactionTargets(String messageId) {
    if (presentationSource != null) {
      return presentationSource!.pendingReactionTargets(messageId);
    }
    final pending = _pendingReactions[messageId];
    return pending == null || pending.isEmpty
        ? null
        : {for (final e in pending.entries) e.key: e.value.target};
  }

  String get _reactionViewerName => client.user?.name ?? '';

  /// Replace a held message's reactions (and the open thread's parent copy).
  /// Not persisted: optimistic state never reaches the disk cache.
  bool _setMessageReactions(
    String channelId,
    String messageId,
    List<Map<String, dynamic>> reactions,
  ) {
    var changed = false;
    if (ledger.contains(channelId, messageId)) {
      changed = ledger.ingestUpdate({
        'id': messageId,
        'channelId': channelId,
        'reactions': reactions,
      }, expectedGeneration: ledger.generation);
    }
    final parent = threadParent;
    if (parent != null && parent.id == messageId) {
      threadParent = RaftMessage({...parent.json, 'reactions': reactions});
      changed = true;
    }
    return changed;
  }

  List<Map<String, dynamic>> _heldReactions(RaftMessage message) =>
      reactionList(
        (ledger.message(message.channelId, message.id) ??
            message.json)['reactions'],
      );

  /// Socket rows carry server state that may predate a pending write: lay the
  /// pending toggles back over the row's reactions.
  void _overlayPendingReactions(Map<String, dynamic> row) {
    final id = row['id'], channelId = row['channelId'];
    final pending = _pendingReactions[id];
    final viewerId = client.user?.id;
    if (pending == null ||
        pending.isEmpty ||
        viewerId == null ||
        id is! String ||
        channelId is! String ||
        !row.containsKey('reactions')) {
      return;
    }
    final held = reactionList(ledger.message(channelId, id)?['reactions']);
    final next = overlayPendingReactions(
      held,
      pending,
      viewerId: viewerId,
      viewerName: _reactionViewerName,
    );
    if (!identical(next, held)) _setMessageReactions(channelId, id, next);
  }

  /// Web MessageItem `handleToggleReaction`: the chip and the viewer's own
  /// state change at once, the write follows, the server row reconciles and a
  /// failure puts the previous reaction back. A second toggle of the same
  /// emoji while one is in flight is ignored (Web `pendingReactionEmojisRef`).
  Future<void> toggleReaction(RaftMessage message, String emoji) {
    if (presentationSource != null) {
      return presentationSource!.toggleReaction(message, emoji);
    }
    final key = '${message.id}:$emoji';
    final inFlight = _reactionWrites[key];
    if (inFlight != null) return inFlight;
    final generation = ledger.generation,
        serverId = client.serverId,
        viewerId = client.user?.id;
    if (serverId == null || viewerId == null) return Future.value();
    Future<void> change() async {
      var reacted =
          reactionViewer.reacted(message.id)?.contains(emoji) ??
          ownReactionFromRow(_heldReactions(message), emoji, viewerId);
      if (reacted == null) {
        // Canonical chip without a private snapshot: read it first.
        final viewer = await client.get(
          '/messages/${message.id}/reactions/viewer',
        );
        if (_disposed || generation != ledger.generation) return;
        reactionViewer.accept(viewer, serverId: serverId);
        reacted = reactionViewer.reacted(message.id)?.contains(emoji);
        if (reacted == null) {
          throw StateError('Your reaction state could not be loaded.');
        }
      }
      final target = !reacted;
      final before = _heldReactions(message);
      final pending = beginReaction(before, emoji, target: target);
      (_pendingReactions[message.id] ??= {})[emoji] = pending;
      _setMessageReactions(
        message.channelId,
        message.id,
        setOwnReaction(
          before,
          emoji,
          reacted: target,
          viewerId: viewerId,
          viewerName: _reactionViewerName,
        ),
      );
      notifyListeners();
      bool stale() =>
          _disposed ||
          generation != ledger.generation ||
          _revokedChannels.contains(message.channelId);
      try {
        final value = await client.request(
          target ? 'POST' : 'DELETE',
          '/messages/${message.id}/reactions',
          data: {'emoji': emoji},
        );
        _clearPendingReaction(message.id, emoji);
        if (stale()) return;
        if (value is Map) {
          final accepted = reactionViewer.accept(
            value['reactionViewer'],
            serverId: serverId,
          );
          final row = Map<String, dynamic>.from(value)
            ..remove('reactionViewer');
          ledger.ingest([row], expectedGeneration: generation);
          // Other emojis still in flight keep their optimistic state.
          _overlayPendingReactions(row);
          final snapshot = reactionViewer.reacted(message.id);
          if (accepted != 'accepted' &&
              snapshot != null &&
              snapshot.contains(emoji) != target) {
            // A snapshot older than the write would show the old state.
            reactionViewer.remove(message.id);
            unawaited(hydrateReactionViewer(message));
          }
          final held = ledger.message(message.channelId, message.id);
          if (held != null && threadParent?.id == message.id) {
            threadParent = RaftMessage(held);
          }
          _saveWindow(
            message.channelId,
            thread: message.channelId == threadChannelId,
          );
        }
        notifyListeners();
      } catch (_) {
        _clearPendingReaction(message.id, emoji);
        if (!stale()) {
          _setMessageReactions(
            message.channelId,
            message.id,
            restoreReaction(_heldReactions(message), emoji, pending),
          );
          notifyListeners();
        }
        rethrow;
      }
    }

    final pending = change();
    _reactionWrites[key] = pending;
    return pending.whenComplete(() {
      if (identical(_reactionWrites[key], pending)) _reactionWrites.remove(key);
    });
  }

  void _clearPendingReaction(String messageId, String emoji) {
    final pending = _pendingReactions[messageId];
    pending?.remove(emoji);
    if (pending != null && pending.isEmpty) _pendingReactions.remove(messageId);
  }

  void _event(RaftEvent event) {
    if (_disposed) return;
    _ensureSyncIdentity();
    if (!ownsClient &&
        !const {
          'message:new',
          'message:updated',
          'thread:updated',
          'reaction_viewer:updated',
          'channel:removed',
        }.contains(event.name)) {
      return;
    }
    _lastServerEvent = DateTime.now();
    // Presence patches are owned by the entity directory and the agent
    // presentations; no workspace state changes, so nothing is notified.
    if (presenceEvents.contains(event.name)) return;
    if (event.name == 'connected') {
      connected = true;
      // Source socketBridge reconnectSnapshot: server-level reads only. The
      // channel list, unread counts and the resume/gap sync wait for
      // `rooms:joined`, once the server has joined this socket's rooms.
      _roomsJoinedPending = true;
      _lastHeartbeat = _lastServerEvent;
      // A socket that flaps (a bad network reconnects every few seconds) must
      // not repeat the whole refresh burst each time: what was read less than
      // [_burstFreshness] ago is still fresh, and the resume sync below
      // brings messages up to date.
      if (_due('membership')) recoverMembership(coalesce: true);
      if (_due('syncFlag')) refreshMessageSyncFlag();
      if (_due('sidebar')) loadSidebar();
      // A reconnect refreshes agents and members in place; the first connect
      // reuses the reads the selection already started.
      if (_connectedBefore && entityDirectory.started && _due('authors')) {
        entityDirectory.revalidateAuthors();
      }
      _connectedBefore = true;
    }
    if (event.name == 'rooms:joined') _roomsJoined();
    if (event.name == 'heartbeat') {
      final joining = _roomsJoinedPending;
      _heartbeat(event.payload);
      // A heartbeat only records liveness; a missed-push gap sync notifies
      // when its rows arrive.
      if (!joining) return;
    }
    if (event.name == 'disconnected' || event.name == 'connection:error') {
      connected = false;
    }
    if (event.name == 'server:membership-removed' &&
        event.payload is Map &&
        event.payload['serverId'] is String) {
      revokeServer(event.payload['serverId']);
      recoverMembership();
    }
    if (event.name == 'connection:error' &&
        event.payload is Map &&
        event.payload['notServerMember'] == true) {
      final id = client.serverId;
      if (id != null) revokeServer(id);
      recoverMembership();
    }
    if (event.name == 'server:member-updated') {
      applyMembershipRole(event.payload);
      recoverMembership();
      refreshChannels();
    }
    if (event.name == 'channel:members-updated' ||
        event.name == 'channel:authority-updated' ||
        event.name == 'channel:removed') {
      final payload = event.payload;
      final id = payload is Map ? payload['channelId'] ?? payload['id'] : null;
      if (id is! String || id.isEmpty) {
        // Unknown scope: fail closed for every channel.
        _invalidateAllChannelReplies();
      } else if (event.name != 'channel:members-updated' ||
          _membershipScoped(id)) {
        // Only the named channel's authority may have changed. A public
        // channel's member list never changes who can read it.
        _invalidateChannelReplies(id);
      }
    }
    if (event.name == 'channel:updated' ||
        event.name == 'channel:members-updated' ||
        event.name == 'dm:new' ||
        event.name == 'channel:authority-updated') {
      _channelRealtime(event.name, event.payload);
    }
    if (event.name == 'pinned:updated') loadSidebar();
    if (event.name == 'thread:updated' && event.payload is Map) {
      _consumeThreadUpdate(Map<String, dynamic>.from(event.payload));
    }
    if (event.name == 'notification_prefs:updated') {
      _consumeNotificationPrefs(event.payload);
    }
    if (event.name == 'message_display_prefs:updated') {
      _consumeMessageDisplayPrefs(event.payload);
    }
    if (event.name == 'server:plan-updated') {
      _consumeServerPlanUpdated(event.payload);
    }
    if ((event.name == 'message:new' || event.name == 'message:updated') &&
        event.payload is Map) {
      final row = Map<String, dynamic>.from(event.payload);
      if (_revokedChannels.contains(row['channelId'])) return;
      composer.sends.confirm(row);
      final duplicate =
          row['channelId'] is String &&
          row['id'] is String &&
          ledger.contains(row['channelId'], row['id']);
      if (event.name == 'message:updated') {
        MessageHistoryEvents.store(this, row, updateOnly: true);
        if (!ledger.ingestUpdate(row, expectedGeneration: ledger.generation)) {
          return;
        }
        _overlayPendingReactions(row);
      } else {
        final projection = syncCoreMessagesEnabled
            ? messageSync.consumeNew(row)
            : row;
        if (projection == null) return;
        MessageHistoryEvents.store(this, projection);
        ledger.ingest([projection], expectedGeneration: ledger.generation);
      }
      final id = row['channelId'];
      if (id == channel?.id && !hasNewer ||
          id == threadChannelId && !messageWindows.contextHasNewer(id)) {
        if (event.name == 'message:new' && id == channel?.id) {
          if (messageWindows.fillWindowGap(id, row['id'])) {
            unawaited(_revalidateTail(id));
          }
        }
        messageWindows.reveal(liveWindowWrite, id, [row['id']]);
        _saveWindow(id, thread: id == threadChannelId, coalesce: event.name == 'message:updated');
      } else if (event.name == 'message:new' &&
          id is String &&
          row['id'] is String &&
          messageWindows.retainsLiveTail(id)) {
        messageWindows.reveal(liveWindowWrite, id, [row['id']]);
      }
      // Source messageStore: counts move per event; only a first delivery
      // counts, and an edit never does.
      if (event.name == 'message:new' && !duplicate) _receiveUnread(row);
    }
    if (event.name == 'sync:resume:response' && event.payload is Map) {
      unawaited(MessageHistoryEvents.resumeResponse(this, event.payload as Map,
        refreshUnread: () {
          if (_due('unread', freshness: const Duration(seconds: 5))) refreshUnread();
        }));
    }
    if (event.name == 'channel:removed') {
      final p = event.payload;
      if (p is Map && p['channelId'] is String) {
        final id = p['channelId'] as String;
        _revokeChannel(id);
        channels.removeWhere((c) => c.id == id);
        dms.removeWhere((c) => c.id == id);
        if (channel?.id == id) {
          channel = null;
          closeThread();
        }
      }
    }
    if (event.name == 'read_state:updated' ||
        event.name == 'read_state:updated_bulk') {
      final payload = event.payload;
      if (payload is Map && client.serverId != null && client.user != null) {
        final updates = event.name.endsWith('_bulk')
            ? (payload['scopes'] as List? ?? [])
            : [payload];
        for (final update in updates) {
          if (update is Map) {
            final fact = {...update, 'serverId': payload['serverId']};
            final outcome = readState.consumeUpdate(
              fact,
              serverId: client.serverId!,
              principalId: client.user!.id,
            );
            if (outcome == 'accepted' && fact['scopeId'] is String) {
              _projectReadState(fact['scopeId'] as String);
              applyReadStateUnreadHint(_summariesByChannel, fact);
            }
          }
        }
      }
      _persistReadState();
    }
    if (event.name == 'reaction_viewer:updated' && client.serverId != null) {
      reactionViewer.accept(event.payload, serverId: client.serverId!);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sessionScope.dispose();
    MessageHistoryPages.detach(this);
    if (presentationSource == null) messageWindows.dispose();
    composer.sends.detach(this);
    composer.disposeOwnedBy(this);
    if (services.ownsEntityDirectory) {
      removeListener(_entityAuthorityChanged);
    }
    services.disposeOwnedStores();
    _removeCacheClear?.call();
    _removeCacheClear = null;
    if (presentationSource == null) attachmentMedia.dispose();
    services.retireChannelFiles();
    subscription.cancel();
    services.disposeActivityUnread();
    foregroundChanges.dispose();
    resumes.dispose();
    if (ownsClient) client.dispose();
    super.dispose();
  }
}

/// Web `normalizePendingMentionActions`: keep well-formed rows only.
List<Map<String, dynamic>> normalizePendingMentionActions(dynamic value) => [
  if (value is List)
    for (final row in value.whereType<Map>())
      if (row['resolutionId'] is String &&
          row['targetType'] is String &&
          row['availableActions'] is List)
        Map<String, dynamic>.from(row),
];
