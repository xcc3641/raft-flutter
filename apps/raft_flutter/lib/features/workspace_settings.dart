import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_updater/raft_updater.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/mobile_tabbar_preferences.dart';
import '../data/rail_side_preference.dart';
import '../data/personal_presentation.dart';
import '../data/user_error.dart';
import '../data/workspace_controller.dart';
import '../platform/app_update.dart';
import '../platform/client_release_notes.dart';
import '../platform/content_links.dart';
import '../platform/linux_uri_scheme.dart';
import '../platform/native_notifications.dart';
import 'account_settings.dart';
import 'app_image_update_text.dart';
import 'desktop_links_settings.dart';
import 'administration_view.dart';
import 'resource_cards.dart' show resourceRelativeTime;
import 'appearance_section.dart';
import 'billing_view.dart';
import 'im_bridges_view.dart';
import 'integrations_views.dart';
import 'labs_view.dart';
import 'locale_settings_page.dart';
import 'mobile_tabbar_settings_page.dart';
import 'management_support.dart'
    show pageIdentity, readPageSnapshot, writePageSnapshot;
import 'mcp_views.dart';
import 'network_settings.dart';
import 'storage_settings.dart';
import 'notification_settings_view.dart';
import 'provider_views.dart';
import 'server_views.dart';
import 'settings_page.dart';
import 'source_feedback_view.dart';

/// The Settings tab: Sidebar.tsx `settingsSidebarGroups` (desktop Settings
/// rail, and the mobileInline Settings root) and the SettingsPanel tab each
/// row opens. Groups and gates follow settingsNavigation.ts
/// `canOpenSettingsTab` / WorkspaceSettingsModal hidden tabs.
class WorkspaceSettings extends StatefulWidget {
  const WorkspaceSettings({
    super.key,
    required this.controller,
    required this.appearance,
    required this.onAppearance,
    required this.presentation,
    this.notifications,
    this.mobileTabbar,
    this.railSide,
    this.onLogout,
    this.initialTab = 'account',
    this.mobileRoot = true,
    this.mobileResetRevision = 0,
    this.onMobileDetailChanged,
    this.onMobileLocationChanged,
    this.providerEnabled = false,
    this.bridgeEnabled = false,
    this.labsEnabled = false,
    this.appVersion,
    this.frontendOrigin,
    this.workspaceModeCard,
    this.now,
    this.appUpdate,
  });
  final WorkspaceController controller;

  /// Native update check: the red dot on About and the update row inside it.
  /// Null (tests, previews) shows neither.
  final AppUpdateService? appUpdate;

  /// Clock for date-dependent copy (the billing trial notice); tests and the
  /// parity harness freeze it.
  final DateTime Function()? now;
  final Widget? workspaceModeCard;
  final RaftAppearance appearance;
  final ValueChanged<RaftAppearance> onAppearance;
  final PersonalPresentationStore presentation;
  final NativeNotificationService? notifications;

  /// The device's bottom-bar choice; without it the mobile Bottom bar row is
  /// not offered.
  final MobileTabbarStore? mobileTabbar;

  /// The device's rail side choice; without it Appearance does not offer one.
  final RailSideStore? railSide;
  final Future<void> Function()? onLogout;
  final String initialTab;
  final bool mobileRoot;
  final int mobileResetRevision;
  final ValueChanged<bool>? onMobileDetailChanged;
  final ValueChanged<String?>? onMobileLocationChanged;

  /// Server feature flags (provider connections / Slack bridge / Labs UI).
  final bool providerEnabled, bridgeEnabled, labsEnabled;

  /// The running app version shown by About (Web: WEB_APP_VERSION); defaults
  /// to the `RAFT_APP_VERSION` define.
  final String? appVersion;

  /// Web origin for the mobile download QR (defaults to the content-link
  /// origin of the signed-in coordinator).
  final Uri? frontendOrigin;

  static const documentationUrl = 'https://docs.raft.build';
  static const personal = 'Personal', workspace = 'Workspace';
  static const resources = 'Resources';

  @override
  State<WorkspaceSettings> createState() => _WorkspaceSettingsState();
}

class _WorkspaceSettingsState extends State<WorkspaceSettings> {
  /// FeedbackUnreadDot: the account's `unread_total` from
  /// GET /product-feedback/tickets?limit=1, refreshed by the inbox.
  late int feedbackUnread =
      readPageSnapshot(widget.controller, _unreadKey)?['count'] as int? ?? 0;
  static const _unreadKey = 'settings:feedback-unread';

  void _setUnread(int count) {
    final w = widget.controller;
    writePageSnapshot(w, _unreadKey, pageIdentity(w), {'count': count});
    if (mounted && count != feedbackUnread) {
      setState(() => feedbackUnread = count);
    }
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.appUpdate?.addListener(_updateChanged);
    loadFeedbackUnread();
  }

  @override
  void didUpdateWidget(WorkspaceSettings old) {
    super.didUpdateWidget(old);
    if (!identical(old.appUpdate, widget.appUpdate)) {
      old.appUpdate?.removeListener(_updateChanged);
      widget.appUpdate?.addListener(_updateChanged);
    }
  }

  @override
  void dispose() {
    widget.appUpdate?.removeListener(_updateChanged);
    super.dispose();
  }

  Future<void> loadFeedbackUnread() async {
    final w = widget.controller;
    if (w.server == null || w.client.user == null) return;
    final identity = pageIdentity(w);
    try {
      final page = await w.client.get(
        '/product-feedback/tickets',
        query: {'limit': 1},
      );
      final unread = page is Map ? page['unread_total'] : null;
      if (!mounted || identity != pageIdentity(w) || unread is! int) return;
      _setUnread(unread < 0 ? 0 : unread);
    } catch (_) {
      // The dot is an accelerator; a failed read shows none.
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final w = widget.controller;
    final role = w.server?.string('role');
    final guest = role == 'guest';
    return RaftSettingsPage(
      initialTab: widget.initialTab,
      mobileRoot: widget.mobileRoot,
      mobileResetRevision: widget.mobileResetRevision,
      onMobileDetailChanged: widget.onMobileDetailChanged,
      onMobileLocationChanged: widget.onMobileLocationChanged,
      destinations: [
        RaftSettingsDestination(
          'account',
          'Account',
          RaftGlyph.user,
          (_) => AccountSettings(
            controller: w,
            onLogout: widget.onLogout,
            workspaceModeCard: widget.workspaceModeCard,
          ),
        ),
        RaftSettingsDestination(
          'language-region',
          'Language & Region',
          RaftGlyph.languages,
          (_) => LocaleSettingsPage(controller: w),
        ),
        RaftSettingsDestination(
          'appearance',
          'Appearance',
          RaftGlyph.type,
          (_) => RaftAppearanceSection(
            appearance: widget.appearance,
            onAppearance: widget.onAppearance,
            presentation: widget.presentation,
            railSide: widget.railSide,
          ),
        ),
        if (widget.mobileTabbar != null)
          RaftSettingsDestination(
            'bottom-bar',
            'Bottom bar',
            RaftGlyph.smartphone,
            (_) => MobileTabbarSettingsPage(
              controller: w,
              store: widget.mobileTabbar!,
            ),
            scroll: false,
            mobileOnly: true,
          ),
        if (widget.notifications != null)
          RaftSettingsDestination(
            'notifications',
            'Notifications',
            RaftGlyph.bell,
            (_) => NotificationSettingsView(
              service: widget.notifications!,
              controller: w,
            ),
          ),
        if (LinuxUriSchemeRegistration.instance.supported)
          RaftSettingsDestination(
            'desktop',
            'Desktop',
            RaftGlyph.monitor,
            (_) => const DesktopLinksSettings(),
          ),
        if (w.server != null) ...[
          RaftSettingsDestination(
            'server',
            'Server Profile',
            RaftGlyph.building2,
            (_) => ServerSettingsView(controller: w),
            group: WorkspaceSettings.workspace,
            scroll: false,
          ),
          if (w.can('viewBilling'))
            RaftSettingsDestination(
              'billing',
              'Plan & Billing',
              RaftGlyph.creditCard,
              (_) => BillingView(controller: w, now: widget.now),
              group: WorkspaceSettings.workspace,
            ),
          if (w.can('changeMemberRoles') ||
              w.can('changeChannelVisibility') ||
              w.can('inviteMembers') ||
              w.can('editServerSettings'))
            RaftSettingsDestination(
              'administration',
              'Administration',
              RaftGlyph.shield,
              (_) => AdministrationView(
                controller: w,
                frontendOrigin: widget.frontendOrigin,
              ),
              group: WorkspaceSettings.workspace,
            ),
          if (widget.bridgeEnabled)
            RaftSettingsDestination(
              'im-bridges',
              'IM Bridges',
              RaftGlyph.network,
              (_) => IMBridgesView(controller: w),
              group: WorkspaceSettings.workspace,
              scroll: false,
            ),
          if (!guest)
            RaftSettingsDestination(
              'integrations',
              'Applications',
              RaftGlyph.link2,
              (_) => IntegrationsView(controller: w),
              group: WorkspaceSettings.workspace,
              scroll: false,
            ),
          if (widget.labsEnabled)
            RaftSettingsDestination(
              'labs',
              'Labs',
              RaftGlyph.flaskConical,
              (_) => LabsView(controller: w),
              group: WorkspaceSettings.workspace,
            ),
          if (!guest)
            RaftSettingsDestination(
              'mcp',
              'MCP Servers',
              RaftGlyph.blocks,
              (_) => AgentMcpView(controller: w),
              group: WorkspaceSettings.workspace,
              scroll: false,
            ),
          if (widget.providerEnabled && w.can('manageExternalAuth'))
            RaftSettingsDestination(
              'providers',
              'AI Providers',
              RaftGlyph.keyRound,
              (_) => ProviderConnectionsView(controller: w),
              group: WorkspaceSettings.workspace,
              scroll: false,
            ),
          // Desktop has a dedicated Computers rail mode; the Settings
          // sub-nav lists it on mobile only (Sidebar.tsx mobileInline). A
          // Computers tab in the bottom bar replaces this entry.
          if (!guest &&
              widget.mobileTabbar?.settings
                      .effective(guest: guest, can: w.can)
                      .contains(MobileTabs.computers) !=
                  true)
            RaftSettingsDestination.action(
              'computers',
              'Computers',
              RaftGlyph.monitor,
              group: WorkspaceSettings.workspace,
              mobileOnly: true,
              onOpen: () {
                if (!w.can('viewMachines')) return;
                w.navigation.selectSection('computers');
                w.closeThread(navigate: false);
                w.notifyListeners();
              },
            ),
        ],
        RaftSettingsDestination(
          'about',
          'About',
          RaftGlyph.badgeInfo,
          (_) => WorkspaceAboutSection(
            controller: w,
            appVersion: widget.appVersion,
            frontendOrigin: widget.frontendOrigin,
            appUpdate: widget.appUpdate,
          ),
          group: WorkspaceSettings.resources,
          attention: widget.appUpdate?.hasUnseen ?? false,
          attentionDanger: true,
        ),
        // Native-only (no Web counterpart): Web uses the browser's proxy.
        if (!kIsWeb)
          RaftSettingsDestination(
            'network',
            'Network',
            RaftGlyph.network,
            (_) => NetworkSettingsPage(origin: w.client.origin),
            group: WorkspaceSettings.resources,
          ),
        // Native-only (no Web counterpart): Web leaves caching to the browser.
        if (!kIsWeb)
          RaftSettingsDestination(
            'storage',
            'Storage',
            RaftGlyph.hardDrive,
            (_) => StorageSettingsPage(workspace: w),
            group: WorkspaceSettings.resources,
          ),
        RaftSettingsDestination.action(
          'documentation',
          'Documentation',
          RaftGlyph.bookOpenText,
          group: WorkspaceSettings.resources,
          onOpen: () => launchUrl(
            Uri.parse(WorkspaceSettings.documentationUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
        if (w.server != null)
          RaftSettingsDestination(
            'feedback',
            'Feedback',
            RaftGlyph.messageSquare,
            (_) => SourceFeedbackView(
              controller: w,
              initialTicketId: _feedbackTicketId(w.location.settingsPath),
              onUnreadChanged: _setUnread,
            ),
            group: WorkspaceSettings.resources,
            scroll: false,
            attention: feedbackUnread > 0,
            ownHeader: true,
            contentColor: RaftSettingsPanelFrame.feedbackSurface,
          ),
        RaftSettingsDestination(
          'release-notes',
          'Release Notes',
          RaftGlyph.fileText,
          (_) => ReleaseNotesView(
            controller: w,
            source: widget.appUpdate?.releaseNotes,
          ),
          group: WorkspaceSettings.resources,
          // /release-notes renders outside SettingsPanel's attached Panel.
          attached: false,
        ),
      ],
    );
  }
}

/// SettingsPanel.tsx AboutSection: Version, Mobile app (desktop: download
/// buttons + the /download QR), and the current Workspace.
class WorkspaceAboutSection extends StatefulWidget {
  const WorkspaceAboutSection({
    super.key,
    required this.controller,
    this.appVersion,
    this.frontendOrigin,
    this.showMobileApp,
    this.appUpdate,
    this.updater,
  });
  final WorkspaceController controller;

  /// Performs the update behind the card's button on macOS and Windows (where
  /// [AppUpdater.available]); defaults to [AppUpdater.instance]. Whether the
  /// card appears at all stays decided by [appUpdate].
  final AppUpdater? updater;

  /// Native-only: shows the newer release (if any) and, once this page is
  /// open, marks it as seen so the red dots clear.
  final AppUpdateService? appUpdate;
  final String? appVersion;
  final Uri? frontendOrigin;

  /// Defaults to desktop platforms: on a phone the reader already runs the
  /// mobile app.
  final bool? showMobileApp;

  static const _version = String.fromEnvironment(
    'RAFT_APP_VERSION',
    defaultValue: 'development',
  );
  static const _build = String.fromEnvironment('RAFT_BUILD_NUMBER');

  /// What About shows as the running version: `0.1.0 (41)` for a CI build,
  /// the bare version when this build has no CI build number. Same
  /// `version (build)` shape as the Updates card's "New version available".
  static String versionLabel({
    String version = _version,
    String build = _build,
  }) => (int.tryParse(build) ?? 0) > 0 ? '$version ($build)' : version;

  @override
  State<WorkspaceAboutSection> createState() => _WorkspaceAboutSectionState();
}

class _WorkspaceAboutSectionState extends State<WorkspaceAboutSection> {
  @override
  void initState() {
    super.initState();
    // Opening About is what marks the release as seen. Deferred: the dots
    // listen to the service and must not rebuild during this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.appUpdate?.markSeen();
    });
  }

  AppUpdater get _updater => widget.updater ?? AppUpdater.instance;

  /// The Updates card under the Version card; null only where the build has
  /// no update service (Web, public pages).
  ///
  /// macOS and Windows: "Check for updates" runs the same manifest check as
  /// everywhere else and never calls Sparkle / WinSparkle. Their
  /// user-initiated check opens its own dialog ("You're up to date" or the
  /// update flow), which next to this card would answer the same question
  /// twice and, when a release exists, offer the install twice. So the card
  /// answers "is there a newer release?" itself, and "Update now" (shown only
  /// when there is one) hands over to the native updater for the download,
  /// verification, install and relaunch.
  RaftAboutUpdate? update(BuildContext context) {
    final service = widget.appUpdate;
    if (service == null || kIsWeb) return null;
    final platform = Theme.of(context).platform;
    final android = platform == TargetPlatform.android;
    final VoidCallback? check = service.checking
        ? null
        : () => unawaited(service.checkNow());
    switch (service.status) {
      case AppUpdateStatus.unsupported:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.unsupported,
          message: raftText(
            context,
            "Update checks aren't available for this build",
          ),
          detail: raftText(context, switch (service.unsupported) {
            AppUpdateUnsupported.ios =>
              "iOS builds aren't distributed through GitHub releases.",
            AppUpdateUnsupported.linuxPackage =>
              'Only the AppImage build can check for updates.',
            AppUpdateUnsupported.development =>
              'This is a development build without a CI build number.',
            _ => "This platform isn't updated from GitHub releases.",
          }),
        );
      case AppUpdateStatus.checking:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.checking,
          message: raftText(context, 'Checking for updates…'),
        );
      case AppUpdateStatus.idle:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.idle,
          message: raftText(context, 'Not checked for updates yet'),
          onCheck: check,
        );
      case AppUpdateStatus.upToDate:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.upToDate,
          message: raftText(context, "You're on the latest version"),
          detail: _lastChecked(context, service),
          onCheck: check,
        );
      case AppUpdateStatus.failed:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.failed,
          message: raftText(context, "Couldn't check for updates"),
          detail: raftText(
            context,
            userErrorText(
              service.failure,
              fallback: 'Check your connection and try again.',
              where: 'update check',
            ),
          ),
          onCheck: check,
        );
      case AppUpdateStatus.available:
        final release = service.available!;
        final appImage = platform == TargetPlatform.linux
            ? _updater.appImage
            : null;
        // Sparkle / WinSparkle run their own download and install dialogs;
        // this button only starts them. Only a build that can update in place.
        final inPlace =
            (platform == TargetPlatform.macOS ||
                platform == TargetPlatform.windows) &&
            _updater.available;
        Future<void> openReleasePage() => launchUrl(
          android ? release.downloadUrl : release.releasePage,
          mode: LaunchMode.externalApplication,
        );
        if (appImage != null) {
          return _appImageUpdate(
            context,
            service,
            release,
            appImage,
            check,
            openReleasePage,
          );
        }
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.available,
          message: raftFormat(
            context,
            'New version available: {version} ({build})',
            {'version': release.version, 'build': release.buildNumber},
          ),
          detail: _lastChecked(context, service),
          actionLabel: inPlace
              ? 'Update now'
              : android
              ? 'Download update'
              : 'View release',
          onAction: !inPlace
              ? openReleasePage
              : () async {
                  final outcome = await _updater.checkAndInstall();
                  // openedReleasePage: the plugin already opened the page.
                  if (outcome == AppUpdateOutcome.failed) {
                    await openReleasePage();
                  }
                },
          onCheck: check,
        );
    }
  }

  bool _restartFailed = false;

  /// Linux AppImage: the card itself runs the delta update and shows its
  /// progress, the restart offer and, on failure, the specific reason with the
  /// release page as the fallback.
  RaftAboutUpdate _appImageUpdate(
    BuildContext context,
    AppUpdateService service,
    AppRelease release,
    AppImageUpdater appImage,
    VoidCallback? check,
    Future<void> Function() openReleasePage,
  ) {
    final status = appImage.status.value;
    final label = raftFormat(
      context,
      'New version available: {version} ({build})',
      {'version': release.version, 'build': release.buildNumber},
    );
    switch (status.phase) {
      case AppImageUpdatePhase.idle:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.available,
          message: label,
          detail: _lastChecked(context, service),
          actionLabel: 'Update now',
          onAction: () => unawaited(() async {
            // A release remembered by an older app version has no checksum or
            // signature yet.
            var target = release;
            if (target.sha256.isEmpty || target.edSignature.isEmpty) {
              await service.checkNow();
              target = service.available ?? target;
            }
            await appImage.install(
              AppImageRelease(
                tag: target.releaseTag,
                artifact: target.artifact,
                sha256: target.sha256,
                bytes: target.bytes,
                edSignature: target.edSignature,
              ),
            );
          }()),
          onCheck: check,
        );
      case AppImageUpdatePhase.running:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.installing,
          message: raftFormat(context, 'Updating to {version} ({build})', {
            'version': release.version,
            'build': release.buildNumber,
          }),
          detail: appImageStageText(context, status),
          progress: status.progress,
          actionLabel: 'Cancel',
          onAction: appImage.cancel,
        );
      case AppImageUpdatePhase.ready:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.restart,
          message: raftFormat(
            context,
            'Raft {version} ({build}) is installed',
            {'version': release.version, 'build': release.buildNumber},
          ),
          detail: raftText(
            context,
            _restartFailed
                ? "Raft couldn't restart itself. Quit it and start it again to finish updating."
                : 'Restart Raft to finish updating.',
          ),
          actionLabel: 'Restart to finish',
          onAction: () async {
            final started = await appImage.restart();
            if (!started && mounted) setState(() => _restartFailed = true);
          },
        );
      case AppImageUpdatePhase.failed:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.failed,
          message: raftText(context, "Couldn't install the update"),
          detail: appImageFailureText(context, status.failure!),
          actionLabel: 'View release',
          onAction: openReleasePage,
          onCheck: () {
            appImage.reset();
            if (check != null) check();
          },
        );
    }
  }

  String? _lastChecked(BuildContext context, AppUpdateService service) {
    final at = service.lastChecked;
    if (at == null) return null;
    return raftFormat(context, 'Last checked: {time}', {
      'time': resourceRelativeTime(
        at.toIso8601String(),
        now: DateTime.now(),
        chinese: Localizations.localeOf(context).languageCode == 'zh',
      ),
    });
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([
      ?widget.appUpdate,
      _updater.availability,
      ?_updater.appImage?.status,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) => body(context),
    );
  }

  Widget body(BuildContext context) {
    final controller = widget.controller,
        appVersion = widget.appVersion,
        frontendOrigin = widget.frontendOrigin,
        showMobileApp = widget.showMobileApp;
    final server = controller.server;
    final api = controller.client.origin;
    Future<void> open(String platform) => launchUrl(
      Uri.parse('$api/api/mobile-download?platform=$platform'),
      mode: LaunchMode.externalApplication,
    );
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };
    final web = frontendOrigin ?? ContentLinks.originFor(api);
    final slug = server?.string('slug') ?? '';
    return RaftSettingsAbout(
      version: appVersion ?? WorkspaceAboutSection.versionLabel(),
      update: update(context),
      mobileApp: showMobileApp ?? desktop
          ? RaftAboutMobileApp(
              onAndroid: () => open('android'),
              onIos: () => open('ios'),
              qrUrl: '${web.origin}/download',
            )
          : null,
      workspaceName: server == null
          ? null
          : server.string('name').isEmpty
          ? raftText(context, 'Current workspace')
          : server.string('name'),
      workspaceDetail: slug.isEmpty
          ? raftText(
              context,
              'Workspace details and administration are available from Settings.',
            )
          : '/$slug',
    );
  }
}

/// ReleaseNotesPanel.tsx body over the client's own release notes (the
/// `release-notes.json` asset of the latest GitHub release, in the shape of a
/// Web `GET /release-notes` page and validated like `parseReleaseNotesPage`);
/// the first published release is Current. Intended difference from Web,
/// which lists the server's release notes.
class ReleaseNotesView extends StatefulWidget {
  const ReleaseNotesView({super.key, required this.controller, this.source});
  final WorkspaceController controller;

  /// Where the notes come from: the client's own release notes (GitHub
  /// release asset). Null (tests, previews) shows the unavailable state.
  final ClientReleaseNotes? source;
  @override
  State<ReleaseNotesView> createState() => _ReleaseNotesViewState();
}

class _ReleaseNotesViewState extends State<ReleaseNotesView> {
  List<RaftReleaseNote>? releases;
  bool failed = false;
  int attempt = 0;
  static const snapshotKey = 'release-notes';

  @override
  void initState() {
    super.initState();
    // Revisit: the accepted list renders at once and revalidates quietly.
    releases =
        readPageSnapshot(widget.controller, snapshotKey)?['releases']
            as List<RaftReleaseNote>?;
    load();
  }

  Future<void> load() async {
    final w = widget.controller;
    final identity = pageIdentity(w);
    final ticket = ++attempt;
    try {
      final next = await widget.source?.load();
      if (next == null) throw const FormatException('no release notes source');
      if (identity != pageIdentity(w) || ticket != attempt) return;
      writePageSnapshot(w, snapshotKey, identity, {'releases': next});
      if (mounted) {
        setState(() {
          releases = next;
          failed = false;
        });
      }
    } catch (_) {
      // A failed revalidation keeps the accepted list; only a cold read
      // shows the unavailable banner.
      if (mounted && ticket == attempt && releases == null) {
        setState(() => failed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => RaftReleaseNotesView(
    status: failed
        ? RaftReleaseNotesStatus.error
        : releases == null
        ? RaftReleaseNotesStatus.loading
        : RaftReleaseNotesStatus.ready,
    releases: releases ?? const [],
    onRetry: () {
      setState(() => failed = false);
      load();
    },
  );
}

/// `settings/feedback/ticket/<id>` -> `<id>`.
String? _feedbackTicketId(List<String> path) =>
    path.length == 3 && path[0] == 'feedback' && path[1] == 'ticket'
    ? path[2]
    : null;
