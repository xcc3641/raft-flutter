import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'background_inbox.dart';
import 'background_notifications.dart'
    show notificationInitialization, notificationDetails;
import 'windows_notifications.dart';

class NotificationPreferenceStore {
  Future<bool?> read(String key) async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p.getBool(key);
  }

  Future<bool> write(String key, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(key, value);
}

/// Local OS delivery for authenticated Socket events and scheduled inbox fetch.
class NativeNotificationService extends ChangeNotifier {
  NativeNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    NotificationPreferenceStore? preferences,
    TargetPlatform? platform,
    WindowsNotifications? windows,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _platform = platform ?? defaultTargetPlatform,
       _preferences = preferences ?? NotificationPreferenceStore(),
       _windows = windows ?? WindowsNotifications();
  final WindowsNotifications _windows;
  final TargetPlatform _platform;
  final FlutterLocalNotificationsPlugin _plugin;
  final NotificationPreferenceStore _preferences;
  Future<void> _preferenceTail = Future.value();
  int _preferenceRevision = 0;
  Future<void>? _initializing;
  Future<void> _tail = Future.value();
  String? _scope;
  int _epoch = 0, _id = 0;
  bool enabled = false, permitted = false, available = false;

  /// Set once [initialize] has finished; before that [available] is unknown.
  bool initialized = false;
  bool _wanted = false;
  String? error, backgroundError;
  void setBackgroundError(String? value) {
    if (backgroundError == value) return;
    backgroundError = value;
    notifyListeners();
  }

  void Function(String)? onTap;

  /// Rechecked at the final OS send for queued foreground arrivals.
  bool Function()? deliveryAllowed;
  TargetPlatform get platform => _platform;

  /// True once the latest permission request returned "denied" without the
  /// system having had time to show a prompt: the OS no longer asks (Android
  /// after two refusals, iOS after the first), so the only way forward is the
  /// system notification settings.
  bool permissionPromptSkipped = false;
  bool get receivesMessages =>
      _platform == TargetPlatform.android ||
      _platform == TargetPlatform.iOS ||
      _platform == TargetPlatform.macOS;
  bool get canOpenSettings =>
      _platform == TargetPlatform.android ||
      _platform == TargetPlatform.iOS ||
      _platform == TargetPlatform.macOS ||
      _platform == TargetPlatform.windows;

  bool get systemManaged =>
      _platform == TargetPlatform.macOS || _platform == TargetPlatform.windows;

  // Desktop has no app-owned opt-in; the system notification switch owns it.
  void _updateEnabled() {
    enabled =
        _scope != null && available && permitted && (systemManaged || _wanted);
  }

  Future<bool> _permission({bool request = false}) async {
    // Windows has no app-owned permission prompt. Read the notifier's actual
    // setting on every delivery, including OS/user/group-policy restrictions.
    if (_platform == TargetPlatform.windows) return _windows.permitted();
    if (_platform == TargetPlatform.iOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (request) {
        return await ios?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
      return (await ios?.checkPermissions())?.isEnabled ?? false;
    }
    if (_platform == TargetPlatform.macOS) {
      final mac = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (request) {
        return await mac?.requestPermissions(alert: true, sound: true) ?? false;
      }
      return (await mac?.checkPermissions())?.isEnabled ?? false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return (request
            ? await android?.requestNotificationsPermission()
            : await android?.areNotificationsEnabled()) ??
        false;
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      if (_platform == TargetPlatform.windows) {
        _windows.onTap = (payload) => onTap?.call(payload);
        await _windows.initialize();
        available = true;
        permitted = await _permission();
      } else {
        final result = await _plugin.initialize(
          settings: notificationInitialization,
          onDidReceiveNotificationResponse: (response) {
            try {
              if (response.payload != null) onTap?.call(response.payload!);
            } catch (_) {}
          },
        );
        // Darwin returns the authorization result, including false when all
        // permission requests are deferred. It still initialized successfully.
        available =
            _platform == TargetPlatform.macOS || _platform == TargetPlatform.iOS
            ? result != null
            : result == true;
        if (canOpenSettings) {
          permitted = await _permission();
          final launch = await _plugin.getNotificationAppLaunchDetails();
          final payload = launch?.notificationResponse?.payload;
          if (launch?.didNotificationLaunchApp == true && payload != null) {
            try {
              onTap?.call(payload);
            } catch (_) {}
          }
        } else {
          // Desktop policy is owned by the freedesktop notification daemon.
          permitted = available;
        }
      }
    } catch (_) {
      error = 'System notifications are unavailable on this device.';
    }
    initialized = true;
    // Drop previous-process OS alerts before restoring any principal. The
    // launch target above has already been captured in memory for fresh checks.
    if (available) {
      try {
        await _cancelAll();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> bind(String? scope) async {
    if (_scope == scope) return;
    _scope = scope;
    final epoch = ++_epoch;
    final revision = ++_preferenceRevision;
    enabled = false;
    _wanted = false;
    _tail = _tail.then((_) async {
      await initialize();
      if (available) {
        try {
          await _cancelAll();
        } catch (_) {
          /* Daemon may be offline. */
        }
      }
    });
    await _tail;
    if (scope != null && !systemManaged) {
      try {
        await _preferenceTail;
        final wanted = await _preferences.read(_key(scope)) ?? false;
        if (epoch != _epoch || revision != _preferenceRevision) return;
        _wanted = wanted;
      } catch (_) {
        if (epoch != _epoch || revision != _preferenceRevision) return;
        _wanted = false;
        error = 'Notification settings could not be loaded on this device.';
      }
    }
    _updateEnabled();
    notifyListeners();
  }

  String _key(String scope) => notificationPreferenceKey(scope);

  Future<void> requestEnable(bool value) async {
    final scope = _scope, epoch = _epoch, revision = ++_preferenceRevision;
    if (scope == null) return;
    bool current() =>
        scope == _scope && epoch == _epoch && revision == _preferenceRevision;
    // A disable action takes effect before an older permission prompt returns.
    if (!value) {
      _wanted = false;
      enabled = false;
      notifyListeners();
    }
    await initialize();
    if (value && available && canOpenSettings) {
      try {
        final asked = Stopwatch()..start();
        final permission = await _permission(request: true);
        if (!current()) return;
        permitted = permission;
        // A person cannot answer a system prompt within this window.
        permissionPromptSkipped =
            !permission && asked.elapsed < const Duration(milliseconds: 400);
      } catch (_) {
        if (!current()) return;
        permitted = false;
        enabled = false;
        _wanted = false;
        error = 'System notification permission could not be checked.';
        notifyListeners();
        return;
      }
    }
    if (!current()) return;
    if (systemManaged) {
      _updateEnabled();
      error = value && !permitted
          ? 'Allow notifications in system settings to receive alerts.'
          : null;
      notifyListeners();
      return;
    }
    enabled = value && available && permitted;
    _wanted = enabled;
    error = value && !enabled
        ? 'Allow notifications in system settings to receive alerts.'
        : null;
    final savedValue = enabled;
    _preferenceTail = _preferenceTail.then((_) async {
      if (!current()) return;
      try {
        if (!await _preferences.write(_key(scope), savedValue)) {
          throw StateError('Preference write failed.');
        }
      } catch (_) {
        if (current()) {
          enabled = false;
          _wanted = false;
          error = 'Notification settings could not be saved on this device.';
        }
      }
    });
    await _preferenceTail;
    if (!current()) return;
    if (!enabled) {
      _tail = _tail.then((_) async {
        if (available) {
          try {
            await _cancelAll();
          } catch (_) {
            /* Keep the delivery queue usable while the OS is offline. */
          }
        }
      });
      try {
        await _tail;
      } catch (_) {
        /* Stay disabled while the OS is offline. */
      }
    }
    if (current()) notifyListeners();
  }

  Future<void> refreshPermission() async {
    await initialize();
    if (!canOpenSettings || !available) return;
    final epoch = _epoch, revision = _preferenceRevision;
    try {
      final permission = await _permission();
      if (epoch != _epoch || revision != _preferenceRevision) return;
      permitted = permission;
      _updateEnabled();
      if ((_wanted || systemManaged) && !permitted) {
        error = 'Allow notifications in system settings to receive alerts.';
      } else if (permitted) {
        error = null;
      }
      notifyListeners();
    } catch (_) {
      if (epoch != _epoch || revision != _preferenceRevision) return;
      enabled = false;
      permitted = false;
      error = 'System notification permission could not be checked.';
      notifyListeners();
    }
  }

  Future<void> show({
    required String title,
    required String body,
    required String payload,
  }) async {
    final epoch = _epoch;
    _tail = _tail.then((_) async {
      await refreshPermission();
      if (epoch != _epoch ||
          !enabled ||
          !permitted ||
          !available ||
          deliveryAllowed?.call() == false) {
        return;
      }
      try {
        error = null;
        await _show(
          id: _notificationId(payload),
          title: title,
          body: body,
          payload: payload,
        );
      } catch (_) {
        error = 'The system notification could not be delivered.';
        notifyListeners();
      }
    });
    await _tail;
  }

  int _notificationId(String payload) {
    try {
      final p = jsonDecode(payload);
      final uri = Uri.parse(p['uri'] as String);
      final message = uri.queryParameters['messageId'] ?? uri.pathSegments.last;
      return messageNotificationId(_scope!, message);
    } catch (_) {
      return ++_id;
    }
  }

  /// Posts one test notification and reports whether the system accepted it.
  /// It does not depend on the member's opt-in: desktop notifications are owned
  /// by the system, and a phone only needs the permission to be granted.
  Future<bool> test({
    String title = 'Test notification',
    String body = 'System notifications are enabled. Click to return to Raft.',
  }) async {
    await initialize();
    if (!available) return false;
    try {
      if (canOpenSettings) {
        // macOS asks the first time; phones re-check what the person changed
        // in system settings.
        permitted = await _permission() || await _permission(request: true);
        if (systemManaged) {
          _updateEnabled();
          notifyListeners();
        }
        if (!permitted) {
          enabled = false;
          notifyListeners();
          return false;
        }
      }
      await _show(
        id: ++_id,
        title: title,
        body: body,
        payload: 'raft-notification-test',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> openSettings() async {
    if (_platform == TargetPlatform.windows) {
      if (!await launchUrl(Uri.parse('ms-settings:notifications'))) {
        throw StateError('Windows notification settings could not be opened.');
      }
      return;
    }
    if (_platform == TargetPlatform.iOS) {
      await launchUrl(Uri.parse('app-settings:'));
      return;
    }
    if (_platform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.openAppNotificationSettings();
    } else if (_platform == TargetPlatform.macOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.openAppNotificationSettings();
    }
  }

  Future<void> presentWindow() async {
    if (_platform == TargetPlatform.windows) await _windows.present();
  }

  Future<void> _cancelAll() => _platform == TargetPlatform.windows
      ? _windows.cancelAll()
      : _plugin.cancelAll();

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => _platform == TargetPlatform.windows
      ? _windows.show(id: id, title: title, body: body, payload: payload)
      : _plugin.show(
          id: id,
          title: title,
          body: body,
          payload: payload,
          notificationDetails: notificationDetails,
        );

  bool receiveWindowsActivation(Uri uri) =>
      _platform == TargetPlatform.windows && _windows.receiveLink(uri);
}
