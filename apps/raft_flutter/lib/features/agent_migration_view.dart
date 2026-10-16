import 'page_layout.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/migration_error.dart';
import '../data/raft_location.dart';
import '../data/user_error.dart' show logUserError;
import '../data/web_error.dart';
import '../data/workspace_controller.dart';
import 'agent_metadata_projection.dart' show nonEmptyOr;
import 'agent_detail_view.dart' show agentTimeFormatter;
import 'agent_migration_panel.dart';
import 'agent_migration_presentation.dart';
import 'billing_view.dart' show RaftBillingPlans;
import 'management_support.dart';

class AgentMigrationView extends StatefulWidget {
  const AgentMigrationView({
    super.key,
    required this.controller,
    required this.agentId,
    this.now,
  });
  final WorkspaceController controller;
  final String agentId;

  /// Clock for the free-trial Pro gate (tests freeze it).
  final DateTime Function()? now;
  @override
  State<AgentMigrationView> createState() => _AgentMigrationState();
}

class _AgentMigrationState extends ManagementState<AgentMigrationView> {
  @override
  WorkspaceController get w => widget.controller;
  Map<String, dynamic> agent = {}, migration = {};
  List<Map<String, dynamic>> machines = [];

  /// Web `useServerStore().billing`: GET /billing/subscription. Null until a
  /// read lands; a failed read leaves it as it was.
  Map<String, dynamic>? billing;
  bool loadingBilling = false;

  /// Web `billingChecking`: Move waits for the first billing answer.
  bool get billingChecking => billing == null && loadingBilling;
  bool get requiresUpgrade => agentMigrationRequiresUpgrade(
    billing?['plan'],
    trialActive: RaftBillingPlans.trialActive(
      (widget.now ?? DateTime.now)().toUtc(),
    ),
  );
  String get base => '/agents/${widget.agentId}';
  bool get manager =>
      w.can('migrateAgents') ||
      agent['creatorType'] == 'user' && agent['creatorId'] == w.client.user?.id;
  StreamSubscription<RaftEvent>? _events;

  /// The migration the cancel dialog shows and whether it can still be
  /// cancelled: they follow every read while the dialog is open.
  final _live = ValueNotifier<Map<String, dynamic>>({});
  final _cancellable = ValueNotifier<bool>(true);

  /// Web realtime.ts `pollMs`: while a migration is active the status is
  /// re-read this often, so a missed push cannot leave the page stale.
  static const pollInterval = Duration(seconds: 2);
  RaftForegroundPeriodic? _poll;
  int _reads = 0, _planRevision = 0;

  /// Web `watchedActiveRef`: the run this page saw active.
  String? _watchedRef;
  @override
  void initState() {
    super.initState();
    startManagement();
    _planRevision = w.planRevision;
    w.addListener(_planChanged);
    _observeMigration();
    unawaited(loadBilling());
    _events = w.client.events.listen((e) {
      // Web realtime.ts: a migration update for this agent, a reconnect or the
      // rooms rejoin refetches the latest migration.
      final p = e.payload;
      if (e.name == 'connected' ||
          e.name == 'rooms:joined' ||
          e.name == 'agent:migration-updated' &&
              p is Map &&
              p['agentId'] == widget.agentId) {
        if (mounted) reload();
      }
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    w.removeListener(_planChanged);
    _poll?.dispose();
    _poll = null;
    _live.dispose();
    _cancellable.dispose();
    super.dispose();
  }

  /// Web `server:plan-updated` reloads billing.
  void _planChanged() {
    if (_planRevision == w.planRevision) return;
    _planRevision = w.planRevision;
    unawaited(loadBilling());
  }

  /// Web `loadBilling`: a failed read just leaves the gate undecided.
  Future<void> loadBilling() async {
    if (w.server == null) return;
    final generation = w.client.generation;
    loadingBilling = true;
    try {
      final value = await w.query('/billing/subscription');
      if (accepts(generation) && value is Map) {
        setState(() => billing = Map<String, dynamic>.from(value));
        saveSnapshot();
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => loadingBilling = false);
    }
  }

  @override
  Future<void> reload() async {
    _reads++;
    try {
      await super.reload();
    } finally {
      _reads--;
    }
    _observeMigration();
  }

  /// Follows the accepted migration after every read. An active run is polled
  /// until it ends. Web `AgentMigrationSection`: completion broadcasts no
  /// agent update, so when this page watched a run finish it re-reads agents
  /// (here: the entity directory, which feeds the agent detail Computer row,
  /// the computer's agent list and the fleet grouping, and the device
  /// record). Failed and canceled ends are covered too: a post-flip cancel
  /// leaves the agent on the target computer.
  void _observeMigration() {
    if (!mounted) return;
    _live.value = migration;
    _cancellable.value = canCancelMigration(migration);
    final phase = migrationPhase(migration['state'] as String?);
    final ref = migration['migrationRef'];
    if (phase == 'active') {
      _watchedRef = ref is String ? ref : null;
      _poll ??= RaftForegroundPeriodic(pollInterval, () {
        if (mounted && _reads == 0) unawaited(reload());
      });
      return;
    }
    _poll?.dispose();
    _poll = null;
    if (ref is String && ref == _watchedRef && phase != null) {
      _watchedRef = null;
      w.entityDirectory.reloadAgents();
    }
  }

  @override
  String get snapshotKey => 'agent-migration:${widget.agentId}';
  @override
  Map<String, Object?> captureSnapshot() => {
    'agent': agent,
    'migration': migration,
    'machines': machines,
    'billing': billing,
  };
  @override
  bool restoreSnapshot(Map<String, Object?> fields) {
    agent = fields['agent'] as Map<String, dynamic>;
    migration = fields['migration'] as Map<String, dynamic>;
    machines = fields['machines'] as List<Map<String, dynamic>>;
    billing = fields['billing'] as Map<String, dynamic>?;
    return true;
  }

  @override
  void clearData() {
    agent = {};
    migration = {};
    machines = [];
    billing = null;
    statusFailed = false;
  }

  /// Web `migrationErrorPresentation`: the failure's `code` picks the
  /// `migration.error.*` copy; the server's own sentence is never shown.
  Future<T> _migration<T>(
    MigrationErrorContext context,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on RaftUserError {
      rethrow;
    } catch (e) {
      if (e is RaftApiException && const [401, 403].contains(e.status)) {
        rethrow;
      }
      throw RaftUserError(migrationErrorText(e, context));
    }
  }

  /// The last status read failed (Web `statusError`): shown as a banner that
  /// leaves the move action available, unlike a failed agent or computers read.
  bool statusFailed = false;

  @override
  Future<void> loadData(int request, int generation) =>
      _migration(MigrationErrorContext.status, () async {
        if (w.server == null) return;
        // Web reads the status on its own: a failed status read must not
        // discard the agent and the computers.
        Object? statusError;
        final status = w
            .query('$base/migration')
            .then<dynamic>((value) => value)
            .catchError((Object e) {
              statusError = e;
              return null;
            });
        final responses = await Future.wait([
          w.query(base),
          w.query('/servers/${w.server!.id}/machines'),
          status,
        ]);
        if (!accepts(generation, request)) return;
        final failure = statusError;
        if (failure is RaftApiException &&
            const [401, 403].contains(failure.status)) {
          throw failure;
        }
        agent = managementMap(responses[0]);
        machines = managementRows(managementMap(responses[1])['machines']);
        if (failure != null) {
          statusFailed = true;
          // The accepted migration stays until a read succeeds.
          throw failure;
        }
        statusFailed = false;
        migration = managementMap(managementMap(responses[2])['migration']);
      });

  /// Web AgentMigrationUpgradeDialog: "Upgrade" opens Plan & Billing.
  Future<void> _showUpgrade() async {
    final viewPlans = await scopedDialog<bool>(
      (_) => RaftConfirmDialog(
        title: 'Upgrade to Pro to migrate agents',
        message: 'After upgrading, you can migrate an agent and its workspace to another computer.',
        confirmLabel: 'Upgrade',
        confirmVariant: RaftButtonRecipeVariant.accent,
        maxWidth: 448,
      ),
    );
    if (viewPlans != true || !mounted) return;
    // The migration page is a pushed route over the workspace: leave it so
    // the Settings section is what the user lands on.
    Navigator.of(context).popUntil((route) => route.isFirst);
    w.setSection('billing');
  }

  bool get active => migrationPhase(migration['state'] as String?) == 'active';

  MigrationComputers _computers(Object? targetId) {
    String? name(Object? id) =>
        machines.where((m) => m['id'] == id).firstOrNull?['name'] as String?;
    return MigrationComputers(
      sourceName: name(agent['machineId']),
      targetName: name(targetId),
      sourceId: agent['machineId'] as String?,
      targetId: targetId as String?,
    );
  }

  /// Web AgentMigrationDialog "Open computer settings" / "Open Computers":
  /// the migration page is a route over the workspace, so leave it for the
  /// Computers surface (Web opens a new tab so the dialog stays).
  void _openComputers(String? computerId) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (computerId != null && w.can('viewMachines')) {
      w.navigation.navigate(
        RaftLocation.at(
          serverSlug: w.location.serverSlug,
          route: RaftRoute.computer,
          entityId: computerId,
        ),
      );
      w.closeThread(navigate: false);
      w.notifyListeners();
    } else {
      w.setSection('computers');
    }
  }

  Future<void> move() async {
    if (!manager || agent['runtime'] == 'external') return;
    // Web openMigration: a known non-Pro plan gets the upgrade prompt instead.
    if (requiresUpgrade) {
      await _showUpgrade();
      return;
    }
    // Web AgentMigrationDialog: every other computer; an offline one is
    // listed and the server answers TARGET_COMPUTER_OFFLINE.
    final targets = machines
        .where((m) => m['isComputer'] == true && m['id'] != agent['machineId'])
        .toList();
    if (targets.isEmpty) {
      setState(
        // Web's target select is disabled with this placeholder.
        () => error = 'No other computers available',
      );
      return;
    }
    var proRequired = false;
    final generation = w.client.generation, sourceAuthority = authority;
    await scopedDialog<bool>(
      (dialogContext) => _StartDialog(
        targets: targets,
        openComputers: _openComputers,
        start: (target) async {
          if (!accepts(generation) || sourceAuthority != authority) {
            throw StateError('The active workspace changed. Reopen this form.');
          }
          try {
            await w.command(
              'POST',
              '$base/migrate',
              data: {'targetComputer': target},
            );
          } catch (e) {
            if (accepts(generation) &&
                sourceAuthority == authority &&
                invalidateDeniedMutation(e) &&
                dialogContext.mounted) {
              Navigator.of(dialogContext).pop(false);
            }
            // Web handleProRequired: the server is the authority on the
            // plan. Closing the form without an error hands over to the
            // upgrade prompt below.
            if (isMigrationProPlanRequiredError(e)) {
              proRequired = true;
              return;
            }
            if (e is RaftApiException && const [401, 403].contains(e.status)) {
              rethrow;
            }
            logUserError(e, where: 'agent migration start');
            throw _StartFailure(
              migrationStartErrorPresentation(e, _computers(target)),
            );
          }
        },
      ),
    );
    if (proRequired) {
      unawaited(loadBilling());
      await _showUpgrade();
      return;
    }
    await reload();
  }

  Future<void> assign() async {
    if (!manager) return;
    await form(
      'Assign computer',
      [
        RaftFormField(
          'machine',
          'Computer',
          initial: '${agent['machineId'] ?? ''}',
          choices: {
            '': 'Unassigned',
            for (final m in machines) '${m['id']}': '${m['name']}',
          },
        ),
      ],
      (values) => withWebError('Something went wrong', () async {
        await w.command(
          'POST',
          '$base/assign-machine',
          data: {
            'machineId': values['machine']!.isEmpty ? null : values['machine'],
          },
        );
      }, where: 'assign computer'),
      description:
          'Change the computer assignment. This does not transfer the existing workspace files.',
    );
    await reload();
  }

  /// Web AgentMigrationCancelDialog `MAX_CANCEL_ATTEMPTS`: a running migration
  /// bumps its revision at every step, so the revision the dialog opened with
  /// is often stale by the time it is confirmed.
  static const maxCancelAttempts = 3;

  /// Submits the cancellation for the migration shown in the dialog. A stale
  /// rejection re-reads the status and retries for the same migration while it
  /// is still cancellable; anything else refreshes and is surfaced.
  Future<void> _submitCancel(
    int generation,
    String sourceAuthority,
  ) async {
    if (!accepts(generation) || sourceAuthority != authority) {
      throw StateError('The active workspace changed. Reopen this form.');
    }
    final opened = _live.value;
    if (!canCancelMigration(opened)) return;
    final ref = opened['migrationRef'];
    var revision = opened['revision'];
    for (var attempt = 1; ; attempt++) {
      try {
        await w.command(
          'POST',
          '$base/migration/cancel',
          data: {'migrationRef': ref, 'expectedRevision': revision},
        );
        await reload();
        return;
      } catch (e) {
        if (accepts(generation) &&
            sourceAuthority == authority &&
            invalidateDeniedMutation(e)) {
          rethrow;
        }
        final code = e is RaftApiException ? e.details['code'] : null;
        if (code == 'MIGRATION_REVISION_STALE' &&
            attempt < maxCancelAttempts) {
          Map<String, dynamic>? latest;
          try {
            latest = managementMap(
              managementMap(await w.query('$base/migration'))['migration'],
            );
          } catch (_) {}
          if (latest != null &&
              latest['migrationRef'] == ref &&
              canCancelMigration(latest)) {
            revision = latest['revision'];
            continue;
          }
        }
        await reload();
        throw migrationCancelUserError(e);
      }
    }
  }

  Future<void> cancel() async {
    if (!manager || !canCancelMigration(migration)) return;
    final generation = w.client.generation, sourceAuthority = authority;
    _live.value = migration;
    _cancellable.value = true;
    await scopedDialog<bool>(
        (_) => ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: _live,
          builder: (context, current, _) {
            final source = MigrationText('{name}', {
              'name': migrationComputerLabel(
                machines,
                current['sourceMachineId'],
              ),
            }).text(context);
            final target = MigrationText('{name}', {
              'name': migrationComputerLabel(
                machines,
                current['targetMachineId'],
              ),
            }).text(context);
            final t = RaftTokens.of(context);
            return RaftConfirmDialog(
              title: 'Cancel migration?',
              confirmLabel: 'Stop',
              cancelLabel: 'Continue',
              loadingLabel: 'Canceling…',
              confirmVariant: RaftButtonRecipeVariant.warning,
              confirmEnabled: _cancellable,
              maxWidth: 448,
              onConfirm: () => _submitCancel(generation, sourceAuthority),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    raftText(context, 'Canceling is safe'),
                    style: RaftTypography.body(
                      t,
                      size: 14,
                      line: 14 * 1.625,
                      weight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    raftFormat(
                      context,
                      'Raft will stop the migration from {source} to {target} and clean up on both computers. Your agent and its workspace stay on whichever computer has them now.',
                      {'source': source, 'target': target},
                    ),
                    style: RaftTypography.body(
                      t,
                      size: 14,
                      line: 14 * 1.625,
                      color: t.strong,
                    ),
                  ),
                  const SizedBox(height: RaftSpace.x3),
                  MigrationReference(
                    migrationRef: '${current['migrationRef']}',
                  ),
                  const SizedBox(height: RaftSpace.x3),
                  Text(
                    raftText(
                      context,
                      'Canceling finishes only after both computers confirm. Keep both computers online until then.',
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    await reload();
  }

  String computerName(dynamic id) =>
      machines.where((m) => m['id'] == id).firstOrNull?['name']?.toString() ??
      id?.toString() ??
      'Unassigned';
  @override
  Widget build(BuildContext context) {
    final formatter = agentTimeFormatter(context, w);
    final failedPhase = migrationPhase(migration['state'] as String?) == 'failed';
    // Web AgentMigrationSection: the action is hidden only while a migration
    // runs; a status read error does not hide it.
    final canMove = manager && agent.isNotEmpty && !active;
    return Scaffold(
      appBar: raftPageAppBar(
        context,
        title: raftText(context, 'Agent migration'),
        actions: [
          RaftTooltip(
            message: raftText(context, 'Refresh'),
            child: IconButton(
              onPressed: busy ? null : reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: raftScrollPadding(context, const EdgeInsets.all(24)),
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: RaftSpace.x3),
                    child: statusFailed
                        ? RaftBanner(
                            status: RaftBannerRecipeStatus.warning,
                            size: RaftBannerRecipeSize.sm,
                            title: "Can't load migration status",
                            description: error!,
                          )
                        : RaftErrorBanner(error!, small: true),
                  ),
                if (agent.isNotEmpty) ...[
                  Text(
                    nonEmptyOr(agent['displayName'], agent['name']),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    '${raftText(context, 'Computer')}: ${computerName(agent['machineId'])}',
                  ),
                ],
                if (migration.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  MigrationProgressPanel(
                    migration: migration,
                    machines: machines,
                    now: (widget.now ?? DateTime.now)().toUtc(),
                    formatTimestamp: formatter.shortDateTime,
                    onCancel: manager ? () => run(cancel) : null,
                  ),
                ],
                if (canMove) ...[
                  const SizedBox(height: 20),
                  RaftButton(
                    label: raftText(
                      context,
                      failedPhase ? 'Try migration again' : 'Move agent',
                    ),
                    onPressed: busy || billingChecking ? null : () => run(move),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => run(assign),
                    child: Text(raftText(context, 'Assign computer')),
                  ),
                ],
              ],
            ),
    );
  }
}

/// Web AgentMigrationDialog: the target choice and, after a refused start, the
/// error block with its recovery; the submit action reads "Try again" once the
/// refusal asks for a fix on the computers.
class _StartDialog extends StatefulWidget {
  const _StartDialog({
    required this.targets,
    required this.start,
    required this.openComputers,
  });
  final List<Map<String, dynamic>> targets;
  final Future<void> Function(String target) start;
  final void Function(String? computerId) openComputers;
  @override
  State<_StartDialog> createState() => _StartDialogState();
}

class _StartDialogState extends State<_StartDialog> {
  MigrationPresentation? failure;

  @override
  Widget build(BuildContext context) => RaftFormDialog(
    title: 'Move agent',
    fields: [
      RaftFormField(
        'target',
        'Target computer',
        required: true,
        choices: {for (final m in widget.targets) '${m['id']}': '${m['name']}'},
        localizeChoices: false,
      ),
    ],
    description:
        'The source agent will stop while its workspace moves. Check progress for completion.',
    submitLabel: failure?.recoveryOpenComputers == true ? 'Try again' : 'Move',
    errorContent: (context, error) => error is _StartFailure
        ? _StartFailureView(error.presentation, widget.openComputers)
        : null,
    onSubmit: (values) async {
      try {
        await widget.start(values['target'] ?? '');
      } on _StartFailure catch (e) {
        if (mounted) setState(() => failure = e.presentation);
        rethrow;
      }
    },
  );
}

/// A failed start request, carried from the form's submit to its error slot.
class _StartFailure implements Exception {
  const _StartFailure(this.presentation);
  final MigrationPresentation presentation;
}

/// Web AgentMigrationDialog error block: the warning banner with the issues
/// and technical details, and the link to the computers that need a fix.
class _StartFailureView extends StatelessWidget {
  const _StartFailureView(this.presentation, this.openComputers);
  final MigrationPresentation presentation;
  final void Function(String? computerId) openComputers;

  @override
  Widget build(BuildContext context) {
    final recovery = presentation.recoveryOpenComputers;
    final computerId = presentation.recoveryComputerId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftBanner(
          status: RaftBannerRecipeStatus.warning,
          size: RaftBannerRecipeSize.sm,
          descriptionBuilder: (style) =>
              MigrationErrorContent(presentation: presentation, style: style),
        ),
        if (recovery)
          Align(
            alignment: Alignment.centerLeft,
            child: RaftButton(
              label: raftText(
                context,
                computerId != null
                    ? 'Open computer settings'
                    : 'Open Computers',
              ),
              glyph: RaftGlyph.externalLink,
              tone: RaftButtonRecipeVariant.link,
              size: RaftButtonRecipeSize.sm,
              onPressed: () => openComputers(computerId),
            ),
          ),
      ],
    );
  }
}
