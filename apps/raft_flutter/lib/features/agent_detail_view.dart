// Agent detail panel, rebuilt from Web
// packages/web/src/components/agent/AgentDetailPanel.tsx: PanelHeader
// (back, avatar, name, overflow actions), the scrollable tab strip
// (Profile / Activity / Chat / Reminders / Workspace / Apps / MCP) and each
// tab's content. FleetDetail keeps the data loading, authority fencing and
// lifecycle commands and hands them to this view.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/runtime_config.dart';
import '../data/source_time_formatter.dart';
import '../data/workspace_controller.dart';
import '../data/workspace_entity_directory.dart';
import 'agent_apps_view.dart';
import 'external_agent_setup.dart';
import 'channel_form_fields.dart' show ChannelCandidateAvatar;
import 'create_channel_dialog.dart' show ChannelMemberCandidate;
import 'agent_trajectory_log.dart';
import 'runtime_usage_chip.dart';
import 'agent_metadata_catalog.dart';
import 'agent_runtime_catalog.dart' show reasoningEfforts;
import 'mcp_views.dart';
import 'agent_avatar_dialog.dart' show agentProfileAvatarUrl;
import 'resource_cards.dart' show resourceRelativeTime;

/// ProfilePanel.tsx:349–401: immediately usable blank header and loading
/// body until a real accepted profile exists. No avatar, status, tabs or facts.
class SourceProfileLoadingPanel extends StatelessWidget {
  const SourceProfileLoadingPanel({
    super.key,
    this.onBack,
    this.onClose,
    this.error,
    this.onRetry,
  });
  final VoidCallback? onBack, onClose, onRetry;
  final String? error;
  @override
  Widget build(BuildContext context) => RaftPanelTextScope(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftPanelHeaderBar(
          title: '',
          onBack: onBack,
          backTooltip: raftText(context, 'Back'),
          actions: [
            if (onClose != null)
              RaftPanelIconButton(
                glyph: RaftGlyph.x,
                tooltip: raftText(context, 'Close profile'),
                onPressed: onClose,
              ),
          ],
        ),
        Expanded(
          child: RaftPanelMessage(
            raftText(
              context,
              error == null ? 'Loading...' : 'Profile could not be loaded.',
            ),
            action: error == null || onRetry == null
                ? null
                : RaftButton(label: 'Retry', onPressed: onRetry),
          ),
        ),
      ],
    ),
  );
}

enum AgentDetailTab { profile, activity, chat, reminders, workspace, apps, mcp }

/// Lifecycle and edit commands owned by FleetDetail.
class AgentDetailActions {
  const AgentDetailActions({
    this.onBack,
    this.onClose,
    this.backAlways = false,
    this.onEditName,
    this.onEditDescription,
    this.onEditRole,
    this.onEditAvatar,
    this.onEditRuntime,
    this.onStartStop,
    this.onRestartReset,
    this.onDelete,
    this.onMessage,
    this.onMigrate,
    this.onPermissions,
    this.onReportIssue,
  });
  /// Keep the Back chevron at md+ (`backButtonVisibility="always"`).
  final bool backAlways;
  final VoidCallback? onBack,
      onClose,
      onEditName,
      onEditDescription,
      onEditRole,
      onEditAvatar,
      onEditRuntime,
      onStartStop,
      onRestartReset,
      onDelete,
      onMessage,
      onMigrate,
      onPermissions,
      /// Report Issue (offered only when the build names a feedback export
      /// worker, Web `FEEDBACK_EXPORT_ENABLED`).
      onReportIssue;
}

/// Shared runtime catalog (packages/shared/src/runtimeCatalog.ts RUNTIMES).
const sourceRuntimeDisplayNames = <String, String>{
  'claude': 'Claude Code',
  'codex': 'Codex CLI',
  'grok': 'Grok Build',
  'builtin': 'Built-in Pi',
  'antigravity': 'Antigravity CLI',
  'kimi-sdk': 'Kimi Code',
  'kimi': 'Kimi CLI',
  'copilot': 'Copilot CLI',
  'cursor': 'Cursor CLI',
  'gemini': 'Gemini CLI',
  'opencode': 'OpenCode',
  'pi': 'Pi',
};

/// Web `reasoningEffortLabelId`: the ladder label, else Default.
String _reasoningEffortLabel(String? effort) =>
    reasoningEfforts.where((e) => e.$1 == effort).firstOrNull?.$2 ?? 'Default';

const _activityLabels = {
  'online': 'Online',
  'thinking': 'Thinking',
  'working': 'Working',
  'error': 'Error',
  'offline': 'Offline',
};

class AgentDetailPanel extends StatefulWidget {
  const AgentDetailPanel({
    super.key,
    required this.controller,
    required this.agent,
    required this.machines,
    required this.actions,
    this.liveActivity,
    this.initialTrajectoryLog = const [],
    this.initialTab = AgentDetailTab.profile,
    this.canManage = false,
    this.canViewPrivate = false,
    this.canControlRuntime = false,
    this.busy = false,
    this.error,
    this.clock,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> agent;

  /// null while GET /servers/:id/machines is in flight.
  final List<Map<String, dynamic>>? machines;
  final AgentDetailActions actions;

  /// Latest `agent:activity` socket projection ({activity, detail}).
  final Map<String, dynamic>? liveActivity;

  /// Already admitted session trajectory; distinct from the REST response.
  final List<Map<String, dynamic>> initialTrajectoryLog;
  final AgentDetailTab initialTab;
  final bool canManage, canViewPrivate, canControlRuntime, busy;
  final String? error;
  final DateTime Function()? clock;
  @override
  State<AgentDetailPanel> createState() => _AgentDetailPanelState();
}

SourceTimeFormatter agentTimeFormatter(
  BuildContext context,
  WorkspaceController w,
) => SourceTimeFormatter(
  locale: Localizations.localeOf(context).toLanguageTag(),
  preferredTimezone:
      w.client.user?.string('preferredTimezone') ??
      w.client.user?.string('timezone'),
  preferredTimeFormat: sourceTimeFormatPreference(
    w.client.user?.string('preferredTimeFormat') ??
        w.client.user?.string('timeFormat'),
  ),
  systemTimeFormat: MediaQuery.alwaysUse24HourFormatOf(context)
      ? SourceTimeFormat.twentyFourHour
      : null,
);

class _AgentDetailPanelState extends State<AgentDetailPanel> {
  late AgentDetailTab tab = widget.initialTab;

  Map<String, dynamic> get a => widget.agent;
  String get displayName => '${a['displayName'] ?? a['name'] ?? ''}';
  bool get external => a['external'] == true || a['runtime'] == 'external';
  String get activity =>
      '${widget.liveActivity?['activity'] ?? a['activity'] ?? (a['status'] == 'active' ? 'online' : 'offline')}';
  bool get online => activity != 'offline';

  /// AGENT_PANEL_TABS filtered by visibility, then ordered like raft-ui
  /// `reconcileTabOrder`: the server's `agentPanelTabOrder` first (`channels` /
  /// `dms` are the legacy ids of Chat, `integrations` of Apps), the rest in
  /// their default order.
  List<AgentDetailTab> get tabs {
    final visible = [
      AgentDetailTab.profile,
      if (widget.canViewPrivate) ...[
        AgentDetailTab.activity,
        AgentDetailTab.chat,
        AgentDetailTab.reminders,
        AgentDetailTab.workspace,
        AgentDetailTab.apps,
      ],
      if (widget.canManage) AgentDetailTab.mcp,
    ];
    final stored = widget.controller.sidebarOrder['agentPanelTabOrder'];
    final ordered = <AgentDetailTab>[];
    for (final raw in stored is List ? stored : const []) {
      final id = switch (raw) {
        'channels' || 'dms' => AgentDetailTab.chat,
        'integrations' => AgentDetailTab.apps,
        _ => AgentDetailTab.values.where((t) => t.name == raw).firstOrNull,
      };
      if (id != null && visible.contains(id) && !ordered.contains(id)) {
        ordered.add(id);
      }
    }
    return [
      ...ordered,
      for (final id in visible)
        if (!ordered.contains(id)) id,
    ];
  }

  bool diagnosticCopied = false;
  Timer? diagnosticTimer;

  /// GET /agents/:id/external-status (external agents): the setup state the
  /// presence line and the External setup block share.
  Map<String, dynamic>? externalStatus;
  String? externalStatusError;
  String? externalStatusFor;

  @override
  void initState() {
    super.initState();
    unawaited(loadExternalStatus());
  }

  @override
  void didUpdateWidget(AgentDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent['id'] != a['id'] ||
        oldWidget.agent['runtime'] != a['runtime'] ||
        oldWidget.agent['external'] != a['external']) {
      unawaited(loadExternalStatus());
    }
  }

  Future<void> loadExternalStatus() async {
    final id = '${a['id']}';
    if (!external || externalStatusFor == id) return;
    externalStatusFor = id;
    try {
      final status = await widget.controller.client.get(
        '/agents/$id/external-status',
      );
      if (!mounted || externalStatusFor != id) return;
      if (status is Map) {
        setState(() {
          externalStatus = Map<String, dynamic>.from(status);
          externalStatusError = null;
        });
      }
    } catch (e) {
      if (!mounted || externalStatusFor != id) return;
      setState(
        () =>
            externalStatusError = e is RaftApiException && e.message.isNotEmpty
            ? e.message
            : raftText(context, 'Failed to load external setup status'),
      );
    }
  }

  @override
  void dispose() {
    diagnosticTimer?.cancel();
    super.dispose();
  }

  /// `buildAgentDiagnosticInfo`: the agent's identity, runtime, computer and
  /// live state as plain lines.
  String get diagnosticInfo {
    final m = machine;
    final lines = <String, Object?>{
      'Agent': displayName,
      'Handle': a['name'],
      'Agent ID': a['id'],
      'Server ID': widget.controller.server?.id,
      'Status': a['status'],
      'Activity': activity,
      'Runtime': a['runtime'],
      'Model': a['model'],
      'Reasoning effort': a['reasoningEffort'],
      'Computer': m?['name'],
      'Computer ID': a['machineId'],
      'Computer status': m?['status'],
      'Session ID': a['sessionId'],
    };
    return [
      for (final e in lines.entries)
        if (e.value != null && '${e.value}'.isNotEmpty) '${e.key}: ${e.value}',
    ].join('\n');
  }

  Future<void> copyDiagnosticInfo() async {
    await Clipboard.setData(ClipboardData(text: diagnosticInfo));
    if (!mounted) return;
    setState(() => diagnosticCopied = true);
    diagnosticTimer?.cancel();
    diagnosticTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => diagnosticCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!canRenderWorkspaceAgent(a, widget.controller.server?.id)) {
      return SourceProfileLoadingPanel(
        onBack: widget.actions.onBack,
        error: widget.error,
      );
    }
    final visible = tabs;
    final current = visible.contains(tab) ? tab : AgentDetailTab.profile;
    final menu = <RaftMenuEntry>[
      if (widget.actions.onMessage != null)
        RaftMenuEntry(
          label: raftText(context, 'Direct Message'),
          leading: const RaftDirectMessageIcon(size: 14),
          onPressed: widget.actions.onMessage,
        ),
      if (widget.canControlRuntime && !external) ...[
        RaftMenuEntry(
          label: raftText(context, online ? 'Stop Agent' : 'Start Agent'),
          glyph: online ? RaftGlyph.square : RaftGlyph.play,
          onPressed: widget.actions.onStartStop,
        ),
        RaftMenuEntry(
          label: raftText(context, 'Restart / Reset'),
          glyph: RaftGlyph.rotateCcw,
          onPressed: widget.actions.onRestartReset,
        ),
      ],
    ];
    return LayoutBuilder(
      builder: (context, box) =>
          _panel(context, current, visible, menu, box.maxWidth),
    );
  }

  Widget _panel(
    BuildContext context,
    AgentDetailTab current,
    List<AgentDetailTab> visible,
    List<RaftMenuEntry> menu,
    double panelWidth,
  ) {
    return RaftPanelTextScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RaftPanelHeaderBar(
            title: displayName,
            profileBody: true,
            iconAlwaysVisible: true,
            // `useMobileBack` renders the chevron below `md` only.
            onBack:
                MediaQuery.sizeOf(context).width >= 768 &&
                    !widget.actions.backAlways
                ? null
                : widget.actions.onBack,
            backTooltip: raftText(context, 'Back'),
            iconSlot: RaftAvatarSlot(
              name: displayName,
              avatarUrl: agentProfileAvatarUrl(
                widget.controller.client.origin,
                a['avatarUrl'] as String?,
              ),
              slot: RaftAvatarSlotContext.panelHeader,
            ),
            actions: [
              if (a['deletedAt'] == null && menu.isNotEmpty)
                // AgentProfileOverflowMenu `responsive`: the inline command
                // buttons while the panel is wider than 480px (container
                // query), else the overflow menu.
                if (panelWidth > 480)
                  ..._inlineActions(context)
                else
                  RaftOverflowMenuButton(
                    key: const Key('agent-profile-overflow-trigger'),
                    entries: menu,
                    tooltip: raftText(context, 'More actions'),
                  ),
              // AgentDetailHeader `onClose` (`hidden md:flex`): the profile
              // overlay's close action once the back chevron is gone.
              if (widget.actions.onClose != null &&
                  MediaQuery.sizeOf(context).width >= 768)
                RaftPanelIconButton(
                  glyph: RaftGlyph.x,
                  tooltip: raftText(context, 'Close profile'),
                  onPressed: widget.actions.onClose,
                ),
            ],
          ),
          RaftPanelTabBar<AgentDetailTab>(
            tabs: [for (final id in visible) _tabSpec(context, id)],
            value: current,
            onChanged: (v) => setState(() => tab = v),
          ),
          if (widget.error != null) RaftPanelError(widget.error!),
          Expanded(
            child: RaftSectionPager<AgentDetailTab>(
              key: ValueKey((
                widget.controller.client.origin,
                widget.controller.client.generation,
                widget.controller.client.user?.id,
                widget.controller.server?.id,
                widget.controller.server?.string('role'),
                a['id'],
              )),
              sections: visible,
              value: current,
              onChanged: (value) => setState(() => tab = value),
              swipeEnabled:
                  MediaQuery.sizeOf(context).width <
                  RaftLayoutMetrics.desktopBreakpoint,
              builder: _content,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _inlineActions(BuildContext context) => [
    if (widget.actions.onMessage != null)
      RaftPanelIconButton(
        key: const Key('agent-profile-inline-message'),
        icon: (size, color) => RaftDirectMessageIcon(size: size, color: color),
        tooltip: raftText(context, 'Direct Message'),
        onPressed: widget.actions.onMessage,
      ),
    if (widget.canControlRuntime && !external) ...[
      RaftPanelIconButton(
        key: const Key('agent-profile-inline-start-stop'),
        glyph: online ? RaftGlyph.square : RaftGlyph.play,
        tooltip: raftText(context, online ? 'Stop Agent' : 'Start Agent'),
        onPressed: widget.actions.onStartStop,
      ),
      RaftPanelIconButton(
        key: const Key('agent-profile-inline-restart-reset'),
        glyph: RaftGlyph.rotateCcw,
        tooltip: raftText(context, 'Restart / Reset'),
        onPressed: widget.actions.onRestartReset,
      ),
    ],
  ];

  RaftPanelTab<AgentDetailTab> _tabSpec(
    BuildContext context,
    AgentDetailTab id,
  ) => switch (id) {
    AgentDetailTab.profile => RaftPanelTab(
      id,
      raftText(context, 'Profile'),
      RaftGlyph.bot,
    ),
    AgentDetailTab.activity => RaftPanelTab(
      id,
      raftText(context, 'Activity'),
      RaftGlyph.activity,
    ),
    // raft-ui ChatIcon: a speech bubble with three dots.
    AgentDetailTab.chat => RaftPanelTab.custom(
      id,
      raftText(context, 'Chat'),
      iconBuilder: (size, color, strokeWidth) =>
          RaftChatIcon(size: size, color: color, strokeWidth: strokeWidth),
    ),
    AgentDetailTab.reminders => RaftPanelTab(
      id,
      raftText(context, 'Reminders'),
      RaftGlyph.bellRing,
    ),
    AgentDetailTab.workspace => RaftPanelTab(
      id,
      raftText(context, 'Workspace'),
      RaftGlyph.folderOpen,
    ),
    AgentDetailTab.apps => RaftPanelTab(
      id,
      raftText(context, 'Apps'),
      RaftGlyph.link2,
    ),
    AgentDetailTab.mcp => RaftPanelTab(
      id,
      raftText(context, 'MCP'),
      RaftGlyph.blocks,
    ),
  };

  Widget _content(BuildContext context, AgentDetailTab id) {
    final w = widget.controller;
    final agentId = a['id'] as String;
    return switch (id) {
      AgentDetailTab.profile => _profile(context),
      AgentDetailTab.activity => AgentActivityTab(
        key: ValueKey('agent-activity-$agentId'),
        controller: w,
        agentId: agentId,
        initialEntries: widget.initialTrajectoryLog,
      ),
      AgentDetailTab.chat => AgentChatTab(
        key: ValueKey('agent-chat-$agentId'),
        controller: w,
        agentId: agentId,
        clock: widget.clock,
      ),
      AgentDetailTab.reminders => AgentRemindersTab(
        key: ValueKey('agent-reminders-$agentId'),
        controller: w,
        agentId: agentId,
        clock: widget.clock,
      ),
      AgentDetailTab.workspace => AgentWorkspaceTab(
        key: ValueKey('agent-workspace-$agentId'),
        controller: w,
        agentId: agentId,
      ),
      AgentDetailTab.apps => AgentAppAccessView(
        controller: w,
        agentId: agentId,
      ),
      AgentDetailTab.mcp => AgentMcpView(controller: w, agentId: agentId),
    };
  }

  // ------------------------------------------------------------- profile

  Map<String, dynamic>? get machine {
    final id = a['machineId'];
    if (id is! String) return null;
    return widget.machines?.where((m) => m['id'] == id).firstOrNull;
  }

  /// components/machine MachineRunLabel descriptor.
  String runLabel(Map<String, dynamic> m) {
    if (m['status'] != 'online') {
      return m['isComputer'] == true ? 'computer offline' : 'legacy offline';
    }
    return m['isComputer'] == true && m['computerVersion'] != null
        ? 'computer v${m['computerVersion']}'
        : 'legacy v${m['daemonVersion'] ?? '?'}';
  }

  String createdDate(BuildContext context) {
    final raw = a['createdAt'];
    final date = raw is String ? DateTime.tryParse(raw) : null;
    if (date == null) return '';
    return DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(agentTimeFormatter(context, widget.controller).wallTime(date));
  }

  /// EXTERNAL_AGENT_ONLINE_WINDOW_MS (store/presenceClock.ts).
  static const _externalOnlineWindow = Duration(milliseconds: 120000);

  /// Web `AgentStatusBadge` for an external agent: presence is the credential
  /// seen within the online window, and managers also see the setup state.
  /// While seen with a non-idle activity the badge reads like a managed
  /// agent's (null here).
  (Color, String)? _externalPresence(BuildContext context, RaftTokens t) {
    if (!external) return null;
    final seen = a['lastSeenAt'] is String
        ? DateTime.tryParse(a['lastSeenAt'] as String)
        : null;
    final now = (widget.clock ?? DateTime.now)();
    final online = seen != null && now.difference(seen) < _externalOnlineWindow;
    final live = widget.liveActivity?['activity'];
    if (online && live is String && live != 'online' && live != 'offline') {
      return null;
    }
    final setup = externalStatus?['setupState'];
    final detail = widget.canViewPrivate;
    final color = online
        ? t.product.brutalLime
        : setup == 'waiting_for_login'
        ? raftGray400
        : t.product.brutalCyan;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final relative = !online && seen != null
        ? resourceRelativeTime(
            a['lastSeenAt'] as String,
            now: now,
            chinese: chinese,
          )
        : null;
    final text = detail && setup == 'waiting_for_login'
        ? raftText(context, 'External · Setup required')
        : online
        ? raftText(context, 'External · Online')
        : relative != null
        ? raftFormat(context, 'External · Last active {time}', {
            'time': relative,
          })
        : detail && (setup == 'credential_minted' || setup == 'connected')
        ? raftText(context, 'External · No Raft activity yet')
        : detail && externalStatus != null
        ? raftText(context, 'External · Not configured')
        : raftText(context, 'External');
    return (color, text);
  }

  Widget _profile(BuildContext context) {
    final t = RaftTokens.of(context);
    final canEdit = widget.canManage && a['deletedAt'] == null;
    final detail = widget.liveActivity?['detail'] ?? a['activityDetail'];
    final status =
        widget.canViewPrivate && detail is String && detail.isNotEmpty
        ? detail
        : raftText(context, _activityLabels[activity] ?? activity);
    final agentId = '${a['id']}';
    final externalPresence = _externalPresence(context, t);
    final role = a['serverRole'];
    final pending =
        a['machineId'] is String && widget.machines == null && !external;
    final m = machine;
    final creator = a['creator'];
    // Web `currentRuntimeConfig = hydrateRuntimeConfigForm(agent)`: the
    // structured runtimeConfig (mode, reasoning, model), flat columns as the
    // fallback. Never read the flat columns directly for these rows.
    final config = RuntimeConfig.fromAgent(a);
    final runtime = config.runtime;
    final model = config.model;
    final env = {
      if (a['envVars'] is Map)
        for (final e in (a['envVars'] as Map).entries) '${e.key}': '${e.value}',
    };
    final created = (a['createdAgents'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final buttons = <Widget>[
      if (!external) ...[
        if (widget.actions.onMigrate != null)
          RaftButton(
            label: raftText(context, 'Move to another computer'),
            glyph: RaftGlyph.moveRight,
            tone: RaftButtonRecipeVariant.outline,
            size: RaftButtonRecipeSize.md,
            expand: true,
            onPressed: widget.busy ? null : widget.actions.onMigrate,
          ),
        if (widget.canControlRuntime) ...[
          RaftButton(
            label: raftText(context, online ? 'Stop Agent' : 'Start Agent'),
            glyph: online ? RaftGlyph.square : RaftGlyph.play,
            tone: RaftButtonRecipeVariant.outline,
            size: RaftButtonRecipeSize.md,
            expand: true,
            onPressed: widget.busy ? null : widget.actions.onStartStop,
          ),
          RaftButton(
            label: raftText(context, 'Restart / Reset'),
            glyph: RaftGlyph.rotateCcw,
            tone: RaftButtonRecipeVariant.outline,
            size: RaftButtonRecipeSize.md,
            expand: true,
            onPressed: widget.busy ? null : widget.actions.onRestartReset,
          ),
        ],
      ],
      // AgentDetailPanel Actions: `CopyButton` "Copy Diagnostic Info" (outline,
      // Clipboard / Check icon), between Restart / Reset and Delete.
      RaftButton(
        key: const ValueKey('agent-copy-diagnostic'),
        label: raftText(
          context,
          diagnosticCopied ? 'Diagnostic Info Copied' : 'Copy Diagnostic Info',
        ),
        glyph: diagnosticCopied ? RaftGlyph.check : RaftGlyph.clipboard,
        tone: RaftButtonRecipeVariant.outline,
        size: RaftButtonRecipeSize.md,
        expand: true,
        onPressed: copyDiagnosticInfo,
      ),
      // `FEEDBACK_EXPORT_ENABLED && <Button variant="warning">` (Bug icon).
      if (widget.actions.onReportIssue != null)
        RaftButton(
          key: const ValueKey('agent-report-issue'),
          label: raftText(context, 'Report Issue'),
          glyph: RaftGlyph.bug,
          tone: RaftButtonRecipeVariant.warning,
          size: RaftButtonRecipeSize.md,
          expand: true,
          onPressed: widget.busy ? null : widget.actions.onReportIssue,
        ),
      if (widget.actions.onDelete != null)
        RaftButton(
          label: raftText(context, 'Delete Agent'),
          glyph: RaftGlyph.trash2,
          tone: RaftButtonRecipeVariant.danger,
          size: RaftButtonRecipeSize.md,
          expand: true,
          onPressed: widget.busy ? null : widget.actions.onDelete,
        ),
    ];
    return ListView(
      key: const Key('fleet-detail'),
      padding: raftScrollPadding(context),
      children: [
        RaftProfileIdentity(
          name: displayName,
          handle: '${a['name'] ?? ''}',
          avatarUrl: agentProfileAvatarUrl(
            widget.controller.client.origin,
            a['avatarUrl'] as String?,
          ),
          avatarButton: canEdit,
          onAvatar: canEdit ? widget.actions.onEditAvatar : null,
          onEditName: canEdit ? widget.actions.onEditName : null,
          statusColor:
              externalPresence?.$1 ?? raftActivityDotColor(t, activity),
          statusText: a['deletedAt'] == null
              ? externalPresence?.$2 ?? status
              : null,
          // `min-h-[66px] theme-brutal:min-h-[72px]`.
          minHeight: t.brutal ? 72 : 66,
        ),
        // Description: `px-5 py-3` (no top border).
        RaftPanelSection(
          topBorder: false,
          vertical: 12,
          children: [
            RaftDescriptionBlock(
              text: '${a['description'] ?? ''}',
              onEdit: canEdit ? widget.actions.onEditDescription : null,
              editKey: const ValueKey('agent-edit-description'),
            ),
          ],
        ),
        // `showOperationalInfo && isExternalAgent && canManageAgent`
        if (external && widget.canManage)
          ExternalAgentSetup(
            key: ValueKey('external-setup-$agentId'),
            controller: widget.controller,
            agent: a,
            setupState: externalStatus?['setupState'] as String?,
            credentialLastUsedAt:
                externalStatus?['credentialLastUsedAt'] as String?,
            statusError: externalStatusError,
          ),
        RaftPanelSection(
          children: [
            RaftSectionEyebrow(raftText(context, 'Info')),
            RaftInfoRow(
              label: raftText(context, 'Role'),
              actions: [
                RaftInlineIconButton(
                  key: const ValueKey('agent-role-help'),
                  glyph: RaftGlyph.circleHelp,
                  tooltip: raftText(context, 'Role permissions'),
                  onPressed: () =>
                      showRaftRolePermissionHelp(context, agent: true),
                ),
                if (canEdit && role != null && role != 'owner')
                  RaftInlineIconButton(
                    key: const ValueKey('agent-edit-role'),
                    glyph: RaftGlyph.pencil,
                    tooltip: raftText(context, 'Edit role'),
                    onPressed: widget.actions.onEditRole,
                  ),
              ],
              child: role == null
                  ? const SizedBox.shrink()
                  : RaftInlineBadge(
                      badge: RaftRecipeBadge(
                        raftText(context, role == 'admin' ? 'Admin' : 'Member'),
                        variant: role == 'admin'
                            ? RaftBadgeRecipeVariant.accent
                            : RaftBadgeRecipeVariant.muted,
                      ),
                    ),
            ),
            RaftInfoRow(
              label: raftText(context, 'Computer'),
              child: external
                  ? RaftCssText(
                      raftText(context, 'External runtime'),
                      style: RaftPanelText.muted(t),
                    )
                  : pending
                  ? const SizedBox.shrink()
                  : m != null
                  ? RaftCssText(
                      '${m['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RaftPanelText.monoSemibold(t),
                    )
                  : RaftCssText(
                      raftText(context, 'No computer assigned'),
                      style: RaftPanelText.muted(t),
                    ),
            ),
            if (!external && m != null) ...[
              RaftInfoRow(
                label: raftText(context, 'Computer status'),
                child: RaftConnectionValue(online: m['status'] == 'online'),
              ),
              RaftInfoRow(
                label: raftText(context, 'Computer Version'),
                child: RaftCssText(runLabel(m), style: RaftPanelText.mono(t)),
              ),
            ],
            RaftInfoRow(
              label: raftText(context, 'Created'),
              child: RaftCssText(createdDate(context)),
            ),
            RaftInfoRow(
              label: raftText(context, 'Creator'),
              child: creator is Map
                  ? RaftCreatorLink(
                      name: '${creator['displayName'] ?? creator['name']}',
                      handle: '${creator['name']}',
                      human: creator['type'] == 'human',
                      avatarUrl: agentProfileAvatarUrl(
                        widget.controller.client.origin,
                        creator['avatarUrl'] as String?,
                      ),
                    )
                  : RaftCssText(
                      raftText(context, 'No creator assigned'),
                      style: RaftPanelText.muted(t),
                    ),
            ),
          ],
        ),
        if (!external)
          RaftPanelSection(
            children: [
              RaftEditableEyebrow(
                raftText(context, 'Runtime Config'),
                onEdit: canEdit ? widget.actions.onEditRuntime : null,
                editLabel: raftText(context, 'Edit runtime config'),
                editKey: const ValueKey('agent-edit-runtime'),
              ),
              RaftInfoRow(
                label: raftText(context, 'Runtime'),
                child: RaftInlineBadge(
                  // RuntimeAccountUsageGateChip: the agent's Computer usage.
                  badge: runtimeUsageGateChip(
                    controller: widget.controller,
                    enabled: canViewRuntimeUsage(widget.controller, machine),
                    runtimeId: runtime,
                    machineId: '${machine?['id'] ?? ''}',
                    label: sourceRuntimeDisplayNames[runtime] ?? runtime,
                    runtimeVersion: machine?['runtimeVersions'] is Map
                        ? (machine!['runtimeVersions'] as Map)[runtime]
                              as String?
                        : null,
                    chip: (status) => RaftRecipeBadge(
                      sourceRuntimeDisplayNames[runtime] ?? runtime,
                      appearance: RaftBadgeRecipeAppearance.solid,
                      variant: RaftBadgeRecipeVariant.information,
                      trailing: status,
                    ),
                  ),
                ),
              ),
              RaftInfoRow(
                label: raftText(context, 'Model'),
                child: RaftInlineBadge(
                  badge: RaftRecipeBadge(
                    model.isEmpty
                        ? raftText(context, 'Default')
                        : sourceRuntimeModelLabels[runtime]?[model] ?? model,
                    variant: RaftBadgeRecipeVariant.accent,
                  ),
                ),
              ),
              if (config.supportsReasoning)
                RaftInfoRow(
                  label: raftText(context, 'Reasoning'),
                  child: RaftInlineBadge(
                    badge: RaftRecipeBadge(
                      raftText(
                        context,
                        _reasoningEffortLabel(config.reasoningEffort),
                      ),
                      variant: RaftBadgeRecipeVariant.primary,
                    ),
                  ),
                ),
              if (config.supportsFastMode)
                RaftInfoRow(
                  label: raftText(context, 'Mode'),
                  child: RaftInlineBadge(
                    badge: RaftRecipeBadge(
                      raftText(
                        context,
                        config.fastMode ? 'Fast mode' : 'Default',
                      ),
                      variant: RaftBadgeRecipeVariant.warning,
                    ),
                  ),
                ),
              if (env.isNotEmpty) RaftEnvVarsBlock(vars: env),
            ],
          ),
        RaftPanelSection(
          children: [
            RaftSectionHeader(
              label: raftText(context, 'Created Agents'),
              count: created.length,
            ),
            if (created.isNotEmpty)
              RaftGapColumn(
                children: [
                  for (final c in created)
                    RaftAvatarListRow(
                      avatar: RaftAvatarSlot(
                        name: '${c['displayName'] ?? c['name']}',
                        avatarUrl: agentProfileAvatarUrl(
                          widget.controller.client.origin,
                          c['avatarUrl'] as String?,
                        ),
                        slot: RaftAvatarSlotContext.surfaceList,
                      ),
                      name: '${c['displayName'] ?? c['name']}',
                      subtitle:
                          sourceRuntimeDisplayNames['${c['runtime']}'] ??
                          '${c['runtime'] ?? ''}',
                      rightContent: [
                        RaftActivityDot(
                          color: raftActivityDotColor(
                            t,
                            c['status'] == 'active' ? 'online' : 'offline',
                          ),
                        ),
                      ],
                    ),
                ],
              ),
          ],
        ),
        // Web AgentDetailPanel `{canViewPrivateAgentSurfaces && <AgentSkills
        // embedded />}`, between the profile info and Actions.
        if (widget.canViewPrivate)
          AgentSkillsSection(
            controller: widget.controller,
            agentId: '${a['id']}',
          ),
        if (canEdit && buttons.isNotEmpty)
          RaftPanelSection(
            children: [
              RaftSectionEyebrow(raftText(context, 'Actions')),
              RaftGapColumn(children: buttons),
            ],
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- tabs

class _SkillsSnapshot extends _AgentTabSnapshot {
  List<Map<String, dynamic>> global = [], workspace = [];
}

/// Web AgentSkills `embedded`: `GET /agents/:id/skills` ({global, workspace})
/// as a "Skills" section of the profile, grouped by source path.
class AgentSkillsSection extends StatefulWidget {
  const AgentSkillsSection({
    super.key,
    required this.controller,
    required this.agentId,
  });
  final WorkspaceController controller;
  final String agentId;
  @override
  State<AgentSkillsSection> createState() => _AgentSkillsSectionState();
}

class _AgentSkillsSectionState extends State<AgentSkillsSection>
    with _AgentTabLoader {
  @override
  WorkspaceController get w => widget.controller;
  late _SkillsSnapshot snapshot = _snapshot();
  _SkillsSnapshot _snapshot() =>
      w.agentTabCache.putIfAbsent(
            'skills/${widget.agentId}',
            _SkillsSnapshot.new,
          )
          as _SkillsSnapshot;
  @override
  bool get hasContent => snapshot.loaded;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(AgentSkillsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId != widget.agentId) {
      snapshot = _snapshot();
      reload();
    }
  }

  List<Map<String, dynamic>> _rows(Object? v) => [
    for (final r in (v is List ? v : const []))
      if (r is Map) Map<String, dynamic>.from(r),
  ];

  @override
  Future<void> fetch() async {
    final result = await w.query('/agents/${widget.agentId}/skills');
    final data = result is Map ? result : const {};
    snapshot.global = _rows(data['global']);
    snapshot.workspace = _rows(data['workspace']);
    snapshot.loaded = true;
  }

  List<RaftSkillItem> _items(List<Map<String, dynamic>> rows) => [
    for (final s in rows)
      RaftSkillItem(
        name: '${s['name'] ?? ''}',
        displayName: '${s['displayName'] ?? s['name'] ?? ''}',
        description: '${s['description'] ?? ''}',
        sourcePath: '${s['sourcePath'] ?? ''}',
        userInvocable: s['userInvocable'] == true,
      ),
  ];

  @override
  Widget build(BuildContext context) => RaftSkillsSection(
    global: _items(snapshot.global),
    workspace: _items(snapshot.workspace),
    loading: loading,
    error: loadError,
    onRetry: reload,
  );
}

/// Last accepted data of one agent tab, kept in the controller's
/// server-identity-bound cache. A tab opens with it at its first frame, a
/// reload replaces it in place, and view state (expanded folders, the open
/// file) survives tab switches and leaving the agent.
abstract class _AgentTabSnapshot {
  bool loaded = false;
}

class _ActivitySnapshot extends _AgentTabSnapshot {
  List<Map<String, dynamic>> entries = [];
}

/// The agent's live activity window the Activity tab holds (Web
/// `getActivityLog`); empty until that tab was opened.
List<Map<String, dynamic>> agentCachedActivityEntries(
  WorkspaceController w,
  String agentId,
) {
  final snapshot = w.agentTabCache.peek('activity/$agentId');
  return snapshot is _ActivitySnapshot ? snapshot.entries : const [];
}

class _ChatSnapshot extends _AgentTabSnapshot {
  List<Map<String, dynamic>> channels = [], dms = [];
}

class _RemindersSnapshot extends _AgentTabSnapshot {
  List<Map<String, dynamic>> reminders = [];
}

class _WorkspaceSnapshot extends _AgentTabSnapshot {
  final children = <String, List<Map<String, dynamic>>>{};
  final expanded = <String>{};
  bool showHidden = false;
  String? openFile, openContent;
}

mixin _AgentTabLoader<T extends StatefulWidget> on State<T> {
  WorkspaceController get w;
  int _ticket = 0;

  /// Skeleton/"Loading…" only while there is nothing to show yet.
  bool loading = true;
  String? loadError;
  bool tabActive = true, reloadWhenActive = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasActive = tabActive;
    tabActive = TickerMode.valuesOf(context).enabled;
    if (tabActive && (!wasActive || reloadWhenActive)) {
      reloadWhenActive = false;
      unawaited(reload());
    }
  }

  /// An earlier accepted result is on screen; reloads keep it.
  bool get hasContent;
  Future<void> fetch();
  Future<void> reload() async {
    if (!tabActive) {
      reloadWhenActive = true;
      return;
    }
    final ticket = ++_ticket;
    setState(() {
      loading = !hasContent;
      loadError = null;
    });
    try {
      await fetch();
      if (!mounted || ticket != _ticket) return;
      setState(() => loading = false);
    } catch (e) {
      if (!mounted || ticket != _ticket) return;
      setState(() {
        loading = false;
        // A failed background refresh never replaces rows already shown.
        loadError = hasContent ? null : '$e';
      });
    }
  }
}

/// AgentDetailPanel activity tab: `/agents/:id/activity-log` rendered as
/// AgentActivityLog rows.
class AgentActivityTab extends StatefulWidget {
  const AgentActivityTab({
    super.key,
    required this.controller,
    required this.agentId,
    this.initialEntries = const [],
  });
  final WorkspaceController controller;
  final String agentId;
  final List<Map<String, dynamic>> initialEntries;
  @override
  State<AgentActivityTab> createState() => _AgentActivityTabState();
}

class _AgentActivityTabState extends State<AgentActivityTab>
    with _AgentTabLoader {
  @override
  WorkspaceController get w => widget.controller;
  List<Map<String, dynamic>> entries = [];
  StreamSubscription<RaftEvent>? events;
  Timer? reloadTimer;
  int readRevision = 0;
  late String openingScope;
  late _ActivitySnapshot snapshot;
  @override
  bool get hasContent => snapshot.loaded;
  String get scope =>
      '${w.client.origin}|${w.client.generation}|${w.client.user?.id}|${w.client.serverId}|${w.server?.id}|${w.server?.string('role')}|${widget.agentId}';
  @override
  void initState() {
    super.initState();
    openingScope = scope;
    snapshot =
        w.agentTabCache.putIfAbsent(
              'activity/${widget.agentId}',
              _ActivitySnapshot.new,
            )
            as _ActivitySnapshot;
    entries = mergeAgentTrajectoryLog(
      snapshot.entries,
      admittedAgentTrajectoryRows(widget.initialEntries),
    );
    snapshot.entries = entries;
    w.addListener(scopeChanged);
    listenEvents();
    reload();
  }

  void listenEvents() {
    events = w.client.events.listen((e) {
      if (e.name == 'connected') {
        scheduleReload();
        return;
      }
      if (e.name != 'agent:activity' ||
          e.payload is! Map ||
          (e.payload as Map)['agentId'] != widget.agentId) {
        return;
      }
      final payload = e.payload as Map;
      if (payload['isHeartbeat'] == true ||
          payload['isRefreshOnly'] == true ||
          (payload['sourceServerId'] != null &&
              payload['sourceServerId'] != w.server?.id)) {
        return;
      }
      final raw = payload['entries'];
      if (raw is List && raw.isNotEmpty && payload['timestamp'] is num) {
        final rows = admittedAgentTrajectoryRows([
          for (final entry in raw.whereType<Map>())
            {
              'timestamp': payload['timestamp'],
              'entry': entry,
              for (final key in [
                'serverSeq',
                'launchId',
                'clientSeq',
                'probeId',
              ])
                if (payload[key] != null) key: payload[key],
            },
        ]);
        if (mounted && openingScope == scope) {
          setState(() {
            entries = mergeAgentTrajectoryLog(entries, rows);
            snapshot.entries = entries;
          });
        }
      } else {
        scheduleReload();
      }
    });
  }

  void scheduleReload() {
    reloadTimer?.cancel();
    reloadTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && openingScope == scope) reload();
    });
  }

  void scopeChanged() {
    if (openingScope == scope) return;
    openingScope = scope;
    readRevision++;
    reloadTimer?.cancel();
    snapshot =
        w.agentTabCache.putIfAbsent(
              'activity/${widget.agentId}',
              _ActivitySnapshot.new,
            )
            as _ActivitySnapshot;
    setState(() => entries = snapshot.entries);
    reload();
  }

  @override
  void didUpdateWidget(AgentActivityTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.agentId != widget.agentId) {
      oldWidget.controller.removeListener(scopeChanged);
      w.addListener(scopeChanged);
      events?.cancel();
      openingScope = scope;
      readRevision++;
      reloadTimer?.cancel();
      snapshot =
          w.agentTabCache.putIfAbsent(
                'activity/${widget.agentId}',
                _ActivitySnapshot.new,
              )
              as _ActivitySnapshot;
      entries = snapshot.entries;
      listenEvents();
      reload();
    }
  }

  @override
  void dispose() {
    readRevision++;
    w.removeListener(scopeChanged);
    reloadTimer?.cancel();
    events?.cancel();
    super.dispose();
  }

  @override
  Future<void> fetch() async {
    final captured = scope, owner = w, revision = ++readRevision;
    final result = await owner.query(
      '/agents/${widget.agentId}/activity-log',
      query: {'limit': '50'},
    );
    if (!mounted ||
        revision != readRevision ||
        captured != scope ||
        !identical(owner, w)) {
      return;
    }
    entries = mergeAgentTrajectoryLog(
      entries,
      admittedAgentTrajectoryRows(result),
    );
    snapshot
      ..entries = entries
      ..loaded = true;
  }

  static String _toolLabel(String name) => switch (name) {
    'shell' || 'bash' || 'Bash' => 'Running command',
    'read' || 'Read' => 'Reading file',
    'write' || 'Write' => 'Writing file',
    'edit' || 'Edit' => 'Editing file',
    _ => 'Using $name',
  };

  RaftActivityLogEntry _entry(
    BuildContext context,
    RaftTokens t,
    SourceTimeFormatter f,
    Map<String, dynamic> item,
  ) {
    final entry = item['entry'] is Map
        ? Map<String, dynamic>.from(item['entry'] as Map)
        : <String, dynamic>{};
    final time = f.clock(item['timestamp'], seconds: true).toUpperCase();
    final kind = entry['kind'];
    final text = '${entry['text'] ?? ''}';
    final status = agentTrajectoryStatusDisplay(
      '${entry['activity']}',
      '${entry['detail'] ?? ''}',
      entry['detailKind'] as String?,
    );
    return switch (kind) {
      'status' => RaftActivityLogEntry(
        time: time,
        dot: raftActivityDotColor(t, '${entry['activity']}'),
        title: raftText(context, status.primary),
        inlineDetail: status.secondary,
        compact: true,
      ),
      'tool_start' => RaftActivityLogEntry(
        time: time,
        dot: t.product.statusBusy,
        title: raftText(context, _toolLabel('${entry['toolName']}')),
        inlineDetail: '${entry['toolInput'] ?? ''}',
        inlineMono: true,
      ),
      _ => RaftActivityLogEntry(
        time: time,
        dot: switch (kind) {
          'thinking' => t.product.statusBusy,
          'text' => t.product.brutalCyan,
          'slock_action' => raftBlue300,
          _ => t.product.brutalOrange,
        },
        title: switch (kind) {
          'thinking' => raftText(context, 'Thinking'),
          'text' => raftText(context, 'Message'),
          _ => '${entry['title'] ?? entry['kind'] ?? ''}',
        },
        detail: text,
        clamp: text.length > 200,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final f = agentTimeFormatter(context, w);
    return RaftActivityLogView(
      entries: [for (final e in entries) _entry(context, t, f, e)],
      emptyLabel: loading ? raftText(context, 'Loading…') : loadError,
      onCopy: () => Clipboard.setData(
        ClipboardData(
          text: [
            for (final e in entries) '${e['timestamp']} ${e['entry']}',
          ].join('\n'),
        ),
      ),
    );
  }
}

/// AgentChatTab: the agent's channels and DMs (`/agents/:id/channels`,
/// `/agents/:id/agent-dms`).
class AgentChatTab extends StatefulWidget {
  const AgentChatTab({
    super.key,
    required this.controller,
    required this.agentId,
    this.clock,
  });
  final WorkspaceController controller;
  final String agentId;
  final DateTime Function()? clock;
  @override
  State<AgentChatTab> createState() => _AgentChatTabState();
}

class _AgentChatTabState extends State<AgentChatTab> with _AgentTabLoader {
  @override
  WorkspaceController get w => widget.controller;
  late final _ChatSnapshot snapshot =
      w.agentTabCache.putIfAbsent('chat/${widget.agentId}', _ChatSnapshot.new)
          as _ChatSnapshot;
  List<Map<String, dynamic>> get channels => snapshot.channels;
  List<Map<String, dynamic>> get dms => snapshot.dms;
  @override
  bool get hasContent => snapshot.loaded;
  @override
  void initState() {
    super.initState();
    reload();
  }

  List<Map<String, dynamic>> _rows(dynamic v, String key) => [
    for (final r
        in (v is Map
            ? v[key] ?? const []
            : v is List
            ? v
            : const []))
      if (r is Map) Map<String, dynamic>.from(r),
  ];

  @override
  Future<void> fetch() async {
    final results = await Future.wait([
      w.query('/agents/${widget.agentId}/channels'),
      w.query('/agents/${widget.agentId}/agent-dms'),
    ]);
    snapshot
      ..channels = _rows(results[0], 'channels')
      ..dms = _rows(results[1], 'dms')
      ..loaded = true;
  }

  @override
  Widget build(BuildContext context) {
    // Nothing accepted yet: no "Channels 0" counts that would then fill in.
    if (!hasContent) {
      return RaftPanelMessage(
        loadError ?? raftText(context, 'Loading…'),
        action: loadError == null
            ? null
            : RaftButton(label: raftText(context, 'Retry'), onPressed: reload),
      );
    }
    final origin = w.client.origin;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return RaftAgentChatView(
      // visibleAgentChatChannels: archived memberships are not listed.
      channels: [
        for (final c in channels)
          if (c['archivedAt'] == null)
            RaftAgentChannelRow(
              id: '${c['id']}',
              name: '${c['name'] ?? c['id']}',
              description: c['description'] as String?,
              type: '${c['type'] ?? 'channel'}',
              activityMuted: c['activityMuted'] == true,
              muteFromSeq: c['muteFromSeq'],
            ),
      ],
      dms: [
        for (final d in dms)
          RaftAgentDmRow(
            id: '${d['id']}',
            name: '${d['peerDisplayName'] ?? d['peerName'] ?? d['id']}',
            handle: '@${d['peerName'] ?? ''}',
            avatar: ChannelCandidateAvatar(
              candidate: ChannelMemberCandidate(
                kind: 'agent',
                id: '${d['peerId'] ?? d['id']}',
                name: '${d['peerName'] ?? ''}',
                displayName: d['peerDisplayName'] as String?,
                avatarUrl: d['peerAvatarUrl'] as String?,
              ),
              avatarContext: RaftMountedAvatarContext.previewMini,
              origin: origin,
            ),
            timestamp: resourceRelativeTime(
              '${d['lastMessageAt'] ?? d['createdAt']}',
              now: widget.clock?.call(),
              chinese: chinese,
            ),
            preview: (d['lastMessagePreview'] as String?)?.isNotEmpty == true
                ? d['lastMessagePreview'] as String
                : null,
          ),
      ],
    );
  }
}

/// AgentRemindersSection variant="tab": `GET /reminders?ownerAgentId=&status=
/// scheduled`, kept current by reminder socket events.
class AgentRemindersTab extends StatefulWidget {
  const AgentRemindersTab({
    super.key,
    required this.controller,
    required this.agentId,
    this.clock,
  });
  final WorkspaceController controller;
  final String agentId;
  final DateTime Function()? clock;
  @override
  State<AgentRemindersTab> createState() => _AgentRemindersTabState();
}

class _AgentRemindersTabState extends State<AgentRemindersTab>
    with _AgentTabLoader {
  @override
  WorkspaceController get w => widget.controller;
  late final _RemindersSnapshot snapshot =
      w.agentTabCache.putIfAbsent(
            'reminders/${widget.agentId}',
            _RemindersSnapshot.new,
          )
          as _RemindersSnapshot;
  List<Map<String, dynamic>> get reminders => snapshot.reminders;
  set reminders(List<Map<String, dynamic>> value) => snapshot.reminders = value;
  @override
  bool get hasContent => snapshot.loaded;
  StreamSubscription<RaftEvent>? events;

  @override
  void initState() {
    super.initState();
    reload();
    events = w.client.events.listen(_event);
  }

  @override
  void dispose() {
    events?.cancel();
    super.dispose();
  }

  void _event(RaftEvent e) {
    final p = e.payload;
    if (e.name == 'connected') {
      reload();
      return;
    }
    if (p is! Map) return;
    switch (e.name) {
      case 'reminder:fired':
        if (p['ownerAgentId'] != widget.agentId) return;
        final next = p['nextFireAt'];
        setState(() {
          reminders = next is String
              ? [
                  for (final r in reminders)
                    r['reminderId'] == p['reminderId']
                        ? {...r, 'fireAt': next}
                        : r,
                ]
              : reminders
                    .where((r) => r['reminderId'] != p['reminderId'])
                    .toList();
        });
      case 'reminder:scheduled' || 'reminder:updated':
        final r = p['reminder'];
        if (r is! Map || r['ownerAgentId'] != widget.agentId) return;
        setState(() {
          reminders = [
            ...reminders.where((x) => x['reminderId'] != r['reminderId']),
            if (r['status'] == 'scheduled') Map<String, dynamic>.from(r),
          ]..sort((a, b) => '${a['fireAt']}'.compareTo('${b['fireAt']}'));
        });
      case 'reminder:canceled':
        if (p['ownerAgentId'] != widget.agentId) return;
        setState(() {
          reminders = reminders
              .where((r) => r['reminderId'] != p['reminderId'])
              .toList();
        });
    }
  }

  @override
  Future<void> fetch() async {
    final result = await w.query(
      '/reminders',
      query: {'ownerAgentId': widget.agentId, 'status': 'scheduled'},
    );
    final rows = result is Map ? result['reminders'] : result;
    reminders = [
      for (final r in (rows is List ? rows : const []))
        if (r is Map) Map<String, dynamic>.from(r),
    ];
    snapshot.loaded = true;
  }

  @override
  Widget build(BuildContext context) {
    final f = agentTimeFormatter(context, w);
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return RaftReminderListView(
      loading: loading,
      error: loadError,
      reminders: [
        for (final r in reminders)
          RaftReminderItem(
            title: '${r['title'] ?? ''}',
            relative: resourceRelativeTime(
              '${r['fireAt']}',
              now: widget.clock?.call(),
              chinese: chinese,
            ),
            dateTime: f.shortDateTime(r['fireAt']),
            recurrence: r['recurrence'] is Map
                ? '${(r['recurrence'] as Map)['description'] ?? ''}'
                : null,
          ),
      ],
    );
  }
}

/// AgentWorkspace: path bar + expandable file tree
/// (`/agents/:id/workspace-files?dirPath=`), file preview via `/read`.
class AgentWorkspaceTab extends StatefulWidget {
  const AgentWorkspaceTab({
    super.key,
    required this.controller,
    required this.agentId,
  });
  final WorkspaceController controller;
  final String agentId;
  @override
  State<AgentWorkspaceTab> createState() => _AgentWorkspaceTabState();
}

class _AgentWorkspaceTabState extends State<AgentWorkspaceTab>
    with _AgentTabLoader {
  @override
  WorkspaceController get w => widget.controller;
  late final _WorkspaceSnapshot snapshot =
      w.agentTabCache.putIfAbsent(
            'workspace/${widget.agentId}',
            _WorkspaceSnapshot.new,
          )
          as _WorkspaceSnapshot;
  Map<String, List<Map<String, dynamic>>> get children => snapshot.children;
  Set<String> get expanded => snapshot.expanded;
  bool get showHidden => snapshot.showHidden;
  set showHidden(bool value) => snapshot.showHidden = value;
  String? get openFile => snapshot.openFile;
  set openFile(String? value) => snapshot.openFile = value;
  String? get openContent => snapshot.openContent;
  set openContent(String? value) => snapshot.openContent = value;
  @override
  bool get hasContent => snapshot.loaded;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<List<Map<String, dynamic>>> list(String dir) async {
    final result = await w.query(
      '/agents/${widget.agentId}/workspace-files',
      query: {if (dir.isNotEmpty) 'dirPath': dir},
    );
    final files = result is Map ? result['files'] : result;
    return [
      for (final f in (files is List ? files : const []))
        if (f is Map) Map<String, dynamic>.from(f),
    ];
  }

  @override
  Future<void> fetch() async {
    // Refresh in place: the tree and the folders the member opened stay
    // exactly as shown until each listing is replaced.
    final root = await list('');
    final open = expanded.toList();
    final refreshed = await Future.wait([
      for (final dir in open)
        list(dir).then<List<Map<String, dynamic>>?>(
          (rows) => rows,
          onError: (Object _) => null,
        ),
    ]);
    children[''] = root;
    for (var i = 0; i < open.length; i++) {
      final rows = refreshed[i];
      if (rows != null) children[open[i]] = rows;
    }
    snapshot.loaded = true;
  }

  Future<void> toggle(String path) async {
    if (expanded.remove(path)) {
      setState(() {});
      return;
    }
    setState(() => expanded.add(path));
    // A remembered listing shows at once; the read refreshes it in place.
    try {
      final rows = await list(path);
      if (mounted) setState(() => children[path] = rows);
    } catch (_) {
      // Keep whatever listing is already shown for this folder.
    }
  }

  Future<void> open(String path) async {
    final result = await w.query(
      '/agents/${widget.agentId}/workspace-files/read',
      query: {'path': path},
    );
    if (!mounted) return;
    setState(() {
      openFile = path;
      openContent = result is Map ? '${result['content'] ?? ''}' : '$result';
    });
  }

  List<RaftWorkspaceNode> nodes(String dir, int depth) => [
    for (final f in children[dir] ?? const <Map<String, dynamic>>[])
      if (showHidden || !'${f['name']}'.startsWith('.')) ...[
        RaftWorkspaceNode(
          name: '${f['name']}',
          depth: depth,
          directory: f['isDirectory'] == true,
          open: expanded.contains(f['path']),
          bold: f['name'] == 'memory.md',
          onTap: () => f['isDirectory'] == true
              ? toggle('${f['path']}')
              : open('${f['path']}'),
        ),
        if (f['isDirectory'] == true && expanded.contains(f['path']))
          ...nodes('${f['path']}', depth + 1),
      ],
  ];

  @override
  Widget build(BuildContext context) {
    final path = '~/.slock/agents/${widget.agentId}/';
    final wide = MediaQuery.sizeOf(context).width >= 768;
    if (openFile != null && !wide) {
      return RaftWorkspaceFilePreview(
        path: openFile!,
        content: openContent ?? '',
        onBack: () => setState(() => openFile = null),
      );
    }
    return RaftWorkspaceTreeView(
      preview: openFile == null
          ? null
          : RaftWorkspaceFilePreview(
              embedded: true,
              path: openFile!,
              content: openContent ?? '',
            ),
      path: path,
      nodes: nodes('', 0),
      loading: loading,
      error: loadError,
      showHidden: showHidden,
      onCopyPath: () => Clipboard.setData(ClipboardData(text: path)),
      onToggleHidden: () => setState(() => showHidden = !showHidden),
      onRefresh: reload,
    );
  }
}
