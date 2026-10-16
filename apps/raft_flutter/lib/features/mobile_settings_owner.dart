import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/device_preferences.dart';
import '../data/mobile_tabbar_preferences.dart';
import '../data/personal_presentation.dart';
import '../data/raft_location.dart';
import '../data/raft_navigation_history.dart';
import '../data/rail_side_preference.dart';
import '../data/workspace_controller.dart';
import '../data/workspace_mode_store.dart';
import '../data/workspace_navigation.dart';
import '../platform/app_services.dart';
import '../platform/native_notifications.dart';
import 'workspace_mode_settings_card.dart';
import 'workspace_settings.dart';

/// Device-local choice for migrated phone pages. Off keeps today's pages.
/// On, those pages read the workspace. Default is off. The key stays put.
class MobileSettingsPreference extends ChangeNotifier {
  MobileSettingsPreference._();
  static final instance = MobileSettingsPreference._();
  static const preferenceKey = 'raft.mobileSettingsDirect';

  /// Test override. Null reads the device preference.
  bool? _override;

  bool get enabled => _override ?? _stored();

  bool _stored() {
    try {
      return DevicePreferences.current?.getBool(preferenceKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  void setEnabled(bool next) {
    final changed = next != enabled;
    // Latch the choice even when it already matches storage. A later
    // preference reload must not drop a choice this session already made.
    _override = next;
    if (!changed) return;
    final loaded = DevicePreferences.current;
    Future<void> write(SharedPreferences prefs) async {
      try {
        next
            ? await prefs.setBool(preferenceKey, true)
            : await prefs.remove(preferenceKey);
      } catch (_) {
        /* optional local storage */
      }
    }

    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  /// Drops the in-memory override. Tests call this between cases.
  void resetForTest() {
    _override = null;
    try {
      DevicePreferences.current?.remove(preferenceKey);
    } catch (_) {}
  }
}

/// One visit to a migrated phone route. The preference is read when the route
/// becomes active and stays until it is inactive, so a switch flipped on the
/// open page waits for the next entry.
/// The phone shell reads this. Only the active settings route writes it.
final mobileSettingsDirectHost = Expando<bool>();

class MobileSettingsVisit {
  static final _open = Expando<bool>();
  static final _direct = Expando<bool>();

  static bool choose(
    Object visit, {
    required bool active,
    required bool enabled,
  }) {
    if (!active) {
      _open[visit] = false;
      return _direct[visit] ?? false;
    }
    if (_open[visit] != true) _direct[visit] = enabled;
    _open[visit] = true;
    return _direct[visit] ?? false;
  }

  static bool current(Object visit) => _direct[visit] ?? false;

  /// The covered settings route may not rebuild while a sub-page is open.
  static void noteHidden(Object visit) => _open[visit] = false;

  static void clear(Object visit) {
    _open[visit] = null;
    _direct[visit] = null;
  }
}

/// Notifies only when the settings page's workspace inputs change.
class MobileSettingsSelection extends ChangeNotifier {
  MobileSettingsSelection(this.controller) : _value = read(controller) {
    controller.addListener(_changed);
  }
  final WorkspaceController controller;
  Object? _value;
  bool _disposed = false;

  static Object read(WorkspaceController controller) => (
    controller.client.generation,
    controller.client.user?.id,
    _json(controller.client.user?.json),
    controller.server?.id,
    controller.server?.string('role'),
    _json(controller.server?.json),
    controller.location.serverSlug,
    controller.location.settingsPath.join('\u0000'),
  );

  static String _json(Object? value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return '';
    }
  }

  void _changed() {
    if (_disposed) return;
    final next = read(controller);
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_changed);
    super.dispose();
  }
}

/// Phone settings bound to the workspace controller. [builds] counts builds of
/// this surface, including the first one.
class MobileSettingsDirectPage extends StatefulWidget {
  const MobileSettingsDirectPage({
    super.key,
    required this.controller,
    required this.presentation,
    required this.workspaceMode,
    required this.buildPage,
    required this.active,
  });
  final WorkspaceController controller;
  final Listenable presentation;
  final Listenable workspaceMode;
  final Widget Function() buildPage;

  /// False while this phone route is covered. A covered route keeps the page
  /// it already showed. It does not build the workspace's current page.
  final bool Function() active;
  static int builds = 0;

  @override
  State<MobileSettingsDirectPage> createState() =>
      _MobileSettingsDirectPageState();
}

class _MobileSettingsDirectPageState extends State<MobileSettingsDirectPage> {
  late final MobileSettingsSelection selection = MobileSettingsSelection(
    widget.controller,
  );
  Widget? _leaf;

  @override
  void dispose() {
    selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        selection,
        widget.presentation,
        widget.workspaceMode,
      ]),
      builder: (context, _) {
        // The push animation still lays the covered route out. Building the
        // live page there mounts a second copy of the open panel.
        if (!widget.active()) return _leaf ?? const SizedBox.shrink();
        final next = widget.buildPage();
        // A parent rebuild that returns the same settings widget does not
        // rebuild the page. Messages take that path.
        if (!identical(next, _leaf)) {
          _leaf = next;
          MobileSettingsDirectPage.builds++;
        }
        return _leaf!;
      },
    );
  }
}

class _AccountSettingsCache {
  Object? inputs;
  Widget? widget;
}

final _accountSettingsCache = Expando<_AccountSettingsCache>();

void clearWorkspaceSettingsCache(Object key) {
  final cache = _accountSettingsCache[key];
  if (cache == null) return;
  cache.inputs = null;
  cache.widget = null;
}

/// The settings surface shared by the desktop page and both phone paths.
Widget workspaceSettingsSurface({
  required Object cacheKey,
  required WorkspaceController controller,
  required String? authority,
  required String scope,
  required int revision,
  required int hostRevision,
  required RaftAppearance appearance,
  required Future<void> Function(RaftAppearance) onAppearance,
  required PersonalPresentationStore presentation,
  required NativeNotificationService? notifications,
  required Future<void> Function() onLogout,
  required MobileTabbarStore mobileTabbar,
  required RailSideStore railSide,
  required WorkspaceModeStore workspaceMode,
  required bool providerEnabled,
  required bool bridgeEnabled,
  required bool labsEnabled,
  required bool wide,
  required bool Function() allowed,
  required void Function() dismiss,
}) {
  final tab = WorkspaceNavigation.settingsTab(
    controller.location.settingsPath.firstOrNull ?? 'account',
  );
  final inputs = (
    authority,
    scope,
    jsonEncode(controller.client.user?.json),
    jsonEncode(controller.server?.json),
    tab,
    controller.location.settingsPath.isEmpty,
    revision,
    appearance.mode,
    appearance.light,
    onAppearance,
    notifications,
    onLogout,
    presentation,
    mobileTabbar.settings,
    railSide.side,
    workspaceMode,
    providerEnabled,
    bridgeEnabled,
    labsEnabled,
    wide,
  );
  final cache = _accountSettingsCache[cacheKey] ??= _AccountSettingsCache();
  final Widget page;
  if (tab == 'account' && inputs == cache.inputs && cache.widget != null) {
    page = cache.widget!;
  } else {
    page = KeyedSubtree(
      key: const Key('workspace-account-settings'),
      child: Builder(
        builder: (serviceContext) => WorkspaceSettings(
          key: ValueKey(
            'workspace-account-settings-${controller.client.generation}-${controller.client.user?.id}-${controller.server?.id}-${controller.server?.string('role')}',
          ),
          controller: controller,
          initialTab: tab,
          appUpdate: AppServicesScope.of(serviceContext).appUpdate,
          workspaceModeCard: WorkspaceModeSettingsCard(
            controller: controller,
            store: workspaceMode,
          ),
          appearance: appearance,
          onAppearance: (next) => onAppearance(next),
          presentation: presentation,
          notifications: notifications,
          onLogout: onLogout,
          mobileRoot: controller.location.settingsPath.isEmpty,
          mobileResetRevision: revision + hostRevision,
          mobileTabbar: mobileTabbar,
          railSide: railSide,
          onMobileLocationChanged: (next) => _openSettingsTab(
            controller: controller,
            allowed: allowed(),
            dismiss: dismiss,
            tab: next,
          ),
          providerEnabled: providerEnabled,
          bridgeEnabled: bridgeEnabled,
          labsEnabled: labsEnabled,
        ),
      ),
    );
    cache.inputs = tab == 'account' ? inputs : null;
    cache.widget = tab == 'account' ? page : null;
  }
  return page;
}

void _openSettingsTab({
  required WorkspaceController controller,
  required bool allowed,
  required void Function() dismiss,
  required String? tab,
}) {
  if (!allowed) return;
  if (tab == null) {
    dismiss();
    return;
  }
  final current = controller.location;
  controller.navigation.navigate(
    RaftLocation.at(
      serverSlug: current.serverSlug,
      route: RaftRoute.settings,
      settingsPath: [WorkspaceNavigation.settingsRouteSlug(tab)],
    ),
    kind: RaftNavigationKind.push,
  );
  controller.notifyListeners();
}

/// Device-local phone settings control. Labs shows it on a compact
/// debug or profile build. The settings page does not.
class MobileSettingsSwitch extends StatefulWidget {
  const MobileSettingsSwitch({super.key});

  @override
  State<MobileSettingsSwitch> createState() => _MobileSettingsSwitchState();
}

class _MobileSettingsSwitchState extends State<MobileSettingsSwitch> {
  final preference = MobileSettingsPreference.instance;

  @override
  void initState() {
    super.initState();
    preference.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    preference.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: RaftSpace.x4, top: RaftSpace.x2, right: RaftSpace.x4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              raftText(
                context,
                'Labs. Phone pages use the workspace directly. Applies the next time you open the page.',
              ),
            ),
          ),
          RaftSwitch(
            key: const Key('mobile-settings-direct-switch'),
            value: preference.enabled,
            semanticLabel: raftText(context, 'Labs'),
            onChanged: preference.setEnabled,
          ),
        ],
      ),
    );
  }
}
