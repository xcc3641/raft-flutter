import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../data/workspace_entity_directory.dart';
import 'management_support.dart';
import 'agent_detail_view.dart';
import 'public_avatar_url.dart';

/// Current-authority HumanRoute/ProfilePanel fallback contract. Entity payloads
/// remain in this loader's memory and are cleared on role/principal/workspace
/// changes; the shell stores only the selected user id.
class MemberProfileView extends StatefulWidget {
  const MemberProfileView({
    super.key,
    required this.controller,
    required this.userId,
    required this.onClose,
    this.onMessage,
    this.onBack,
    this.showClose = true,
  });
  final WorkspaceController controller;

  /// Web HumanRoute renders no close control (only the overlay presentation
  /// passes `onClose`); the desktop detail pane hides it.
  final bool showClose;
  final String userId;
  final VoidCallback onClose;

  /// Mobile route back (PanelHeader `onMobileBack`); without it the desktop
  /// pane shows a close action instead.
  final VoidCallback? onBack;
  final Future<void> Function()? onMessage;
  @override
  State<MemberProfileView> createState() => _MemberProfileViewState();
}

class _MemberProfileViewState extends ManagementState<MemberProfileView> {
  @override
  WorkspaceController get w => widget.controller;
  Map<String, dynamic> profile = {};
  @override
  String get authority =>
      '${super.authority}|${identityHashCode(w)}|${w.client.origin}|${widget.userId}|${w.can('viewMembers')}';
  @override
  String get snapshotKey => 'member-profile:${widget.userId}';
  @override
  Map<String, Object?> captureSnapshot() => {'profile': profile};
  @override
  bool restoreSnapshot(Map<String, Object?> fields) {
    // Accepted live membership still wins over the last detail projection.
    profile = {
      ...fields['profile'] as Map<String, dynamic>,
      ...?w.entityDirectory.member(widget.userId),
    };
    return true;
  }

  @override
  void initState() {
    super.initState();
    profile = w.entityDirectory.member(widget.userId) ?? {};
    w.entityDirectory.addListener(directoryChanged);
    startManagement();
  }

  @override
  void didUpdateWidget(MemberProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != w) {
      oldWidget.controller.entityDirectory.removeListener(directoryChanged);
      w.entityDirectory.addListener(directoryChanged);
      rebindManagementController();
      profile = {...profile, ...?w.entityDirectory.member(widget.userId)};
    } else if (oldWidget.userId != widget.userId) {
      refreshAuthority();
      profile = {...profile, ...?w.entityDirectory.member(widget.userId)};
    }
  }

  void directoryChanged() {
    if (!mounted) return;
    final failure = w.entityDirectory.state(WorkspaceEntityKind.members).error;
    if (failure is RaftApiException && [401, 403].contains(failure.status)) {
      setState(() {
        profile = {};
        error = '$failure';
        loading = false;
      });
      return;
    }
    final live = w.entityDirectory.member(widget.userId);
    if (live != null) {
      setState(() => profile = {...profile, ...live});
      saveSnapshot();
    }
  }

  @override
  void dispose() {
    w.entityDirectory.removeListener(directoryChanged);
    super.dispose();
  }

  @override
  void clearData() => profile = {};
  @override
  Future<void> loadData(int request, int generation) async {
    if (w.server == null || !w.can('viewMembers')) {
      clearData();
      return;
    }
    final server = w.server!.id, id = widget.userId;
    final value = await w.query('/servers/$server/members/$id/profile');
    if (value is! Map || value['name'] is! String) {
      throw const FormatException('Invalid member profile response.');
    }
    if (accepts(generation, request)) {
      final failure = w.entityDirectory
          .state(WorkspaceEntityKind.members)
          .error;
      if (failure is RaftApiException && [401, 403].contains(failure.status)) {
        throw failure;
      }
      // resolveHumanProfile.ts:4–17: accepted live membership wins over a
      // fallback detail projection; preserve detail-only fields.
      profile = {
        ...Map<String, dynamic>.from(value),
        ...?w.entityDirectory.member(widget.userId),
      };
    }
  }

  /// HumanDetailPanel `ConfirmDialog` for removing the member.
  Future<void> remove() async {
    final server = w.server!.id, id = widget.userId;
    final name = '${profile['displayName'] ?? profile['name']}';
    final removed = await scopedDialog<bool>(
      (_) => RaftConfirmDialog(
        surfaceKey: const ValueKey('agent-dialog'),
        title: raftText(context, 'Remove Member'),
        message: raftFormat(
          context,
          '{name} will be removed from every channel on this server. Their past messages will remain in history.',
          {'name': name},
        ),
        confirmLabel: raftText(context, 'Remove'),
        loadingLabel: raftText(context, 'Removing…'),
        onConfirm: () async {
          await w.command('DELETE', '/servers/$server/members/$id');
        },
      ),
    );
    if (removed == true && mounted) {
      widget.onBack != null ? widget.onBack!() : widget.onClose();
    }
  }

  /// `getEditableHumanServerRoles`: the roles the viewer may assign
  /// (`canTransitionServerRole`; Guest only while guest invites are on).
  List<String> editableRoles({required bool self}) {
    final actor = w.server?.string('role');
    final target = '${profile['role'] ?? ''}';
    if (target.isEmpty) return const [];
    final owners = w.entityDirectory
        .rows(WorkspaceEntityKind.members)
        .where((m) => m['role'] == 'owner')
        .length;
    bool can(String next) {
      if (target == next || actor == null) return false;
      if (actor == 'owner') {
        return !(target == 'owner' && next != 'owner' && owners <= 1);
      }
      if (actor == 'admin') {
        return !self &&
            target != 'owner' &&
            target != 'admin' &&
            next != 'owner' &&
            (target == 'member' || target == 'guest');
      }
      return false;
    }

    return [
      for (final r in const ['owner', 'admin', 'member', 'guest'])
        if (can(r) && (r != 'guest' || guestEnabled)) r,
    ];
  }

  /// `useServerFeatureFlag(server_guest_v0)`: Guest is only assignable while
  /// guest invites are on (`getEditableHumanServerRoles` `serverGuestEnabled`).
  bool guestEnabled = false, guestFlagRequested = false;

  Future<void> loadGuestFlag() async {
    final server = w.server?.id;
    if (server == null) return;
    try {
      final result = await w.command(
        'POST',
        '/feature-flags/evaluate',
        data: {
          'keys': ['server_guest_v0'],
          'serverId': server,
          'platform': 'web',
        },
      );
      final on =
          result is Map &&
          (result['evaluations'] as List? ?? []).whereType<Map>().any(
            (f) => f['key'] == 'server_guest_v0' && f['enabled'] == true,
          );
      if (mounted && on != guestEnabled) setState(() => guestEnabled = on);
    } catch (_) {}
  }

  bool editingRole = false, rolePickerOpen = false, roleSaving = false;
  String roleValue = 'member';
  String? roleError;

  Future<void> saveRole() async {
    final server = w.server!.id, id = widget.userId;
    setState(() {
      roleSaving = true;
      roleError = null;
    });
    try {
      await w.command(
        'PATCH',
        '/servers/$server/members/$id',
        data: {'role': roleValue},
      );
      await reload();
      if (mounted) setState(() => editingRole = false);
    } catch (e) {
      if (mounted) setState(() => roleError = '$e');
    } finally {
      if (mounted) setState(() => roleSaving = false);
    }
  }

  /// InlineBadgeEditor + Save / Cancel.
  Widget _roleEditor(BuildContext context, RaftTokens t, List<String> roles) {
    String name(String r) =>
        raftText(context, '${r[0].toUpperCase()}${r.substring(1)}');
    return RaftInlineRoleEditor(
      saveKey: const ValueKey('member-edit-role-save'),
      label: name(roleValue),
      selectedId: roleValue,
      options: [
        for (final r in roles) RaftInlineBadgeOption(id: r, label: name(r)),
      ],
      onSelect: (id) => setState(() {
        roleValue = id;
        rolePickerOpen = false;
      }),
      open: rolePickerOpen,
      onOpenChanged: (open) => setState(() => rolePickerOpen = open),
      background: roleColor(t, roleValue),
      foreground: roleInk(t, roleValue),
      saveLabel: raftText(context, 'Save'),
      cancelLabel: raftText(context, 'Cancel'),
      canSave: !roleSaving && roleValue != profile['role'],
      canCancel: !roleSaving,
      onSave: saveRole,
      onCancel: () => setState(() {
        rolePickerOpen = false;
        roleError = null;
        editingRole = false;
      }),
      error: roleError,
    );
  }

  /// HumanDetailPanel.tsx ROLE_CONFIG brutal backgrounds (`theme-brutal:bg-*`)
  /// and elegant soft tokens.
  Color roleInk(RaftTokens t, String role) => t.brutal
      ? t.product.brutalBlack
      : switch (role) {
          'owner' => t.colors['warning-strong']!,
          'admin' => t.colors['accent-strong']!,
          'guest' => t.colors['info-strong']!,
          _ => t.colors['foreground-strong']!,
        };

  Color roleColor(RaftTokens t, String role) => t.brutal
      ? switch (role) {
          'owner' => t.product.brutalOrange,
          'admin' => t.product.brutalPink,
          'guest' => t.product.brutalCyan,
          _ => t.product.brutalLavender,
        }
      : switch (role) {
          'owner' => t.colors['warning-soft']!,
          'admin' => t.colors['accent-soft']!,
          'guest' => t.colors['info-soft']!,
          _ => t.colors['fill-muted']!,
        };

  /// Live agent activity (`agent:activity`) else the summary's status: the
  /// created-agent row's StatusDot (`computeAgentDisplayState`).
  String? _createdActivity(Map a) {
    final row = w.entityDirectory.agent('${a['id']}');
    final activity = row?['activity'];
    if (activity is String) return activity;
    return (row?['status'] ?? a['status']) == 'active' ? 'online' : 'offline';
  }

  @override
  Widget build(BuildContext context) {
    final name = '${profile['displayName'] ?? profile['name'] ?? ''}';
    final handle = '${profile['name'] ?? ''}';
    final self =
        profile['userId'] == w.client.user?.id ||
        widget.userId == w.client.user?.id;
    final avatarUrl = raftPublicAvatarUrl(
      w.client.origin,
      profile['avatarUrl'] as String?,
    );
    if (profile.isEmpty) {
      return SourceProfileLoadingPanel(
        onBack: widget.onBack,
        onClose: widget.onClose,
        error: loading ? null : error ?? 'Profile unavailable',
        onRetry: reload,
      );
    }
    return RaftPanelTextScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RaftPanelHeaderBar(
            title: name,
            subtitle: handle.isEmpty ? null : '@$handle',
            iconSlot: RaftAvatarSlot(
              name: name,
              agent: false,
              avatarUrl: avatarUrl,
              slot: RaftAvatarSlotContext.panelHeader,
            ),
            onBack: widget.onBack,
            iconAlwaysVisible: true,
            profileBody: true,
            backTooltip: raftText(context, 'Back'),
            actions: [
              // canMessageHuman: not for a guest (no existing DM known here).
              if (widget.onMessage != null &&
                  w.server?.string('role') != 'guest' &&
                  profile['role'] != 'guest')
                RaftPanelIconButton(
                  icon: (size, color) =>
                      RaftDirectMessageIcon(size: size, color: color),
                  tooltip: raftText(context, 'Message'),
                  onPressed: busy
                      ? null
                      : () => run(widget.onMessage!, refresh: false),
                ),
              if (widget.onBack == null && widget.showClose)
                RaftPanelIconButton(
                  glyph: RaftGlyph.x,
                  tooltip: raftText(context, 'Close profile'),
                  onPressed: widget.onClose,
                ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: raftScrollPadding(context),
              children: [
                if (error != null)
                  RaftPanelMessage(
                    raftText(context, 'Profile could not be loaded.'),
                    action: RaftButton(label: 'Retry', onPressed: reload),
                  ),
                ..._sections(context, name, handle, self, avatarUrl),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(
    BuildContext context,
    String name,
    String handle,
    bool self,
    String? avatarUrl,
  ) {
    final t = RaftTokens.of(context);
    final role = '${profile['role'] ?? ''}';
    final created = (profile['createdAgents'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final joinedRaw = profile['joinedAt'];
    final joined = joinedRaw is String && DateTime.tryParse(joinedRaw) != null
        ? DateFormat.yMMMd(
            Localizations.localeOf(context).toLanguageTag(),
          ).format(DateTime.parse(joinedRaw).toLocal())
        : null;
    final roles = w.can('changeMemberRoles')
        ? editableRoles(self: self)
        : const <String>[];
    final canRole = roles.isNotEmpty && profile['membershipStatus'] != 'left';
    final canRemove = !self && w.can('removeMembers');
    return [
      RaftProfileIdentity(
        name: name,
        handle: handle,
        agent: false,
        avatarUrl: avatarUrl,
        youLabel: self ? raftText(context, '(you)') : null,
      ),
      RaftPanelSection(
        children: [
          RaftDescriptionBlock(text: '${profile['description'] ?? ''}'),
        ],
      ),
      RaftPanelSection(
        children: [
          RaftSectionEyebrow(raftText(context, 'Info')),
          if (role.isNotEmpty)
            RaftRoleField(
              label: raftText(context, 'Role'),
              badge: RaftRecipeBadge(
                raftText(
                  context,
                  '${role[0].toUpperCase()}${role.substring(1)}',
                ),
                background: roleColor(t, role),
                foreground: roleInk(t, role),
              ),
              editKey: const ValueKey('member-edit-role'),
              helpKey: const ValueKey('member-role-help'),
              onHelp: () => showRaftRolePermissionHelp(context, agent: false),
              onEdit: canRole
                  ? () {
                      // `useServerFeatureFlag(server_guest_v0)`: read when the
                      // role editor is first needed.
                      if (!guestFlagRequested) {
                        guestFlagRequested = true;
                        unawaited(loadGuestFlag());
                      }
                      setState(() {
                        roleValue = role;
                        rolePickerOpen = true;
                        roleError = null;
                        editingRole = true;
                      });
                    }
                  : null,
              editor: canRole && editingRole
                  ? _roleEditor(context, t, roles)
                  : null,
            ),
          if (profile['email'] is String)
            RaftKeyValueRow(
              label: raftText(context, 'Email'),
              value: '${profile['email']}',
              mono: true,
              breakAll: true,
            ),
          if (joined != null)
            RaftKeyValueRow(
              label: raftText(context, 'Joined'),
              value: joined,
              mono: true,
            ),
        ],
      ),
      RaftPanelSection(
        children: [
          RaftSectionHeader(
            label: raftText(context, 'Created Agents'),
            count: created.length,
          ),
          if (created.isEmpty)
            RaftSpanPlaceholder(raftText(context, 'No created agents'))
          else
            RaftGapColumn(
              children: [
                for (final a in created)
                  RaftAvatarListRow(
                    avatar: RaftAvatarSlot(
                      name: '${a['displayName'] ?? a['name']}',
                      avatarUrl: raftPublicAvatarUrl(
                        w.client.origin,
                        a['avatarUrl'] as String?,
                      ),
                      slot: RaftAvatarSlotContext.surfaceList,
                    ),
                    name: '${a['displayName'] ?? a['name']}',
                    subtitle: sourceRuntimeDisplayNames['${a['runtime']}'],
                    rightContent: [
                      RaftActivityDot(
                        color: raftActivityDotColor(t, _createdActivity(a)),
                      ),
                    ],
                  ),
              ],
            ),
        ],
      ),
      if (canRemove)
        RaftPanelSection(
          children: [
            RaftSectionEyebrow(raftText(context, 'Actions')),
            // `<Button size="sm" variant="danger" className="flex w-full
            // items-center justify-center gap-2 px-4 py-2 text-sm font-bold">`.
            RaftRecipeTextButton(
              key: const ValueKey('member-remove'),
              label: raftText(context, 'Remove Member'),
              glyph: RaftGlyph.trash2,
              variant: RaftButtonRecipeVariant.danger,
              text: RaftButtonText.sm,
              bold: true,
              expand: true,
              horizontalPadding: 16,
              onPressed: busy ? null : remove,
            ),
          ],
        ),
    ];
  }
}
