import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:app_badge_plus/app_badge_plus.dart';

import '../data/activity_attention.dart';
import '../data/source_activity_unread_store.dart';
import '../data/source_server_unread.dart';
import '../data/workspace_controller.dart';

/// The app icon badge: the macOS Dock tile and the iOS home screen icon. One
/// app-wide Activity count ([activityBadgeTotal]): the selected server's shared
/// inbox replaces its summary count; channel/thread counters are never added a
/// second time. It is the number the in-app Activity badge shows (summed over
/// member servers, like the server's own push badge) and it follows that badge
/// on every change: foreground, resume, socket events and reads anywhere.
/// Android launchers derive their badge from the notifications instead
/// (native_notifications.dart sets each one's number to its Activity count).
class MacOSDockUnread {
  MacOSDockUnread({
    TargetPlatform? platform,
    Future<void> Function(int)? write,
    this.refreshInterval = const Duration(seconds: 30),
  }) : supported =
           !kIsWeb &&
           const {
             TargetPlatform.macOS,
             TargetPlatform.iOS,
           }.contains(platform ?? defaultTargetPlatform),
       _write = write ?? _writeNative;

  static Future<void> _writeNative(int count) =>
      AppBadgePlus.updateBadge(count);

  final bool supported;
  final Duration refreshInterval;
  final Future<void> Function(int) _write;
  WorkspaceController? _workspace;
  SourceActivityUnreadStore? _activity;
  SourceServerUnreadStore? _servers;
  Interceptor? _reads;
  StreamSubscription<dynamic>? _events;
  Timer? _periodic, _debounce;
  String? _scope;
  bool _closed = false;
  int? _wanted, _written;
  int _revision = 0;
  Future<void> _tail = Future.value();
  Future<void> get settled => _tail;

  void bind(WorkspaceController? next) {
    if (!supported || _closed) return;
    if (!identical(next, _workspace)) {
      _detach();
      _workspace = next;
      if (next != null) {
        _servers = SourceServerUnreadStore(next)..addListener(_publish);
        next.addListener(_sync);
        next.foregroundChanges.addListener(_foregroundChanged);
        _events = next.client.events.listen((event) {
          _sync();
          if (const {
            'rooms:joined',
            'message:new',
            'message:deleted',
            'thread:updated',
            'dm:new',
            'notification_prefs:updated',
            'server:membership-removed',
          }.contains(event.name)) {
            _scheduleRefresh();
          }
        });
        // Reconcile cross-server totals after a persisted read, including
        // read-all performed elsewhere in this process.
        _reads = InterceptorsWrapper(
          onResponse: (response, handler) {
            final request = response.requestOptions;
            if (request.method == 'POST' &&
                (RegExp(
                      r'^/channels/[^/]+/read(?:-all)?$',
                    ).hasMatch(request.path) ||
                    request.path == '/channels/inbox/read-all')) {
              _scheduleRefresh();
            }
            handler.next(response);
          },
        );
        next.client.http.interceptors.add(_reads!);
        // ignore: raft_lints/avoid_unreviewed_idle_work -- Dock badge reconcile every 30 s. It must keep running while the app is hidden (the badge is how the user sees unread), and it builds no UI so it requests no frames.
        _periodic = Timer.periodic(
          refreshInterval,
          (_) => unawaited(refresh()),
        );
      }
    }
    _sync();
  }

  /// Return to the foreground: the other servers' counts are read again (the
  /// socket only reports the selected server), unless read a moment ago.
  void _foregroundChanged() {
    if (_closed || _scope == null || _workspace?.foreground != true) return;
    final servers = _servers;
    if (servers != null) {
      unawaited(servers.refreshOnResume().then((_) => _sync()));
    }
  }

  void _sync() {
    if (_closed) return;
    final w = _workspace;
    final activity = w?.activityUnreadIfBound;
    if (!identical(activity, _activity)) {
      _activity?.removeListener(_publish);
      _activity = activity?..addListener(_publish);
    }
    final next = w?.client.signedIn == true ? _activity?.scope : null;
    final changed = next != _scope;
    _scope = next;
    _servers?.synchronize();
    _publish();
    if (changed && next != null) unawaited(refresh());
  }

  void _publish() {
    if (_closed) return;
    final w = _workspace;
    var total = 0;
    if (w != null &&
        w.client.signedIn &&
        _scope == _activity?.scope &&
        _scope != null) {
      // Membership directory bounds the receipt: revoked/unknown servers
      // cannot contribute. Push muting affects alerts, not unread state.
      total = activityBadgeTotal(
        currentServerId: w.server!.id,
        currentTotal: _activity!.totalUnreadCount,
        memberServerIds: [for (final server in w.servers) server.id],
        summaryCount: (id) => _servers?[id]?.activityUnreadCount,
      );
    }
    _set(total);
  }

  void _scheduleRefresh() {
    if (_closed || _scope == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      _debounce = null;
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (_closed || _scope == null) return;
    await _servers?.refresh();
    _sync();
  }

  void _set(int count) {
    if (_wanted == count && _written == count) return;
    _wanted = count;
    final ticket = ++_revision;
    _tail = _tail.then((_) async {
      // A late queued count must not restore a badge after logout/retirement.
      if (ticket != _revision) return;
      try {
        await _write(count);
        _written = count;
      } catch (_) {
        // Optional platform service. The next synchronization retries it.
        _written = null;
      }
    });
  }

  void _detach() {
    _workspace?.removeListener(_sync);
    _workspace?.foregroundChanges.removeListener(_foregroundChanged);
    if (_reads != null) _workspace?.client.http.interceptors.remove(_reads);
    _reads = null;
    unawaited(_events?.cancel());
    _events = null;
    _activity?.removeListener(_publish);
    _activity = null;
    _servers?.removeListener(_publish);
    _servers?.dispose();
    _servers = null;
    _periodic?.cancel();
    _debounce?.cancel();
    _workspace = null;
    _scope = null;
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _detach();
    if (supported) _set(0);
    await _tail;
  }
}
