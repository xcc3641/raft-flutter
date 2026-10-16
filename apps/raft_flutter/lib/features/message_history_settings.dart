import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/history_capacity.dart';
import '../data/cause_notice.dart';
import '../data/message_history_pages.dart';
import '../data/message_history_verification.dart';
import '../data/workspace_controller.dart';
import 'computer_detail_view.dart' show computerFileSize;

/// Account-wide history controls, separate from the attachment cache action.
class MessageHistorySettings extends StatefulWidget {
  const MessageHistorySettings({
    super.key,
    required this.capacity,
    required this.account,
    this.server,
    this.channel,
    this.refresh,
  });
  final HistoryCapacity capacity;
  final HistoryAccount account;
  final String? server, channel;
  final Future<bool> Function()? refresh;

  static Widget forWorkspace(WorkspaceController w) {
    final db = MessageHistoryPages.storage(w.cache), user = w.client.user?.id;
    if (db == null || user == null) return const SizedBox.shrink();
    final account = HistoryAccount(w.client.origin, user);
    final channel = w.threadChannelId ?? w.channel?.id;
    return MessageHistorySettings(
      key: ValueKey((account, w.client.serverId, channel)),
      capacity: db.capacity,
      account: account,
      server: w.client.serverId,
      channel: channel,
      refresh: channel == null
          ? null
          : () => MessageHistoryVerification.refresh(w),
    );
  }

  @override
  State<MessageHistorySettings> createState() => _MessageHistorySettingsState();
}

class _MessageHistorySettingsState extends State<MessageHistorySettings> {
  HistoryDiskUsage? usage;
  bool busy = false, kept = false;
  final _measurement = CauseNotice(),
      _action = CauseNotice(),
      _success = CauseNotice();
  String? get error => _measurement.message ?? _action.message;
  String? get notice => _success.message;
  int _read = 0, _operation = 0;
  Object get _identity =>
      (widget.capacity, widget.account, widget.server, widget.channel);

  void raise(CauseNotice target, String message, {int? read}) {
    final identity = _identity, operation = _operation;
    target.raise(
      message,
      whileTrue: () =>
          mounted &&
          identity == _identity &&
          operation == _operation &&
          (read == null || read == _read),
    );
  }

  @override
  void initState() {
    super.initState();
    measure();
  }

  @override
  void didUpdateWidget(MessageHistorySettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capacity != widget.capacity ||
        oldWidget.account != widget.account ||
        oldWidget.server != widget.server ||
        oldWidget.channel != widget.channel) {
      usage = null;
      _operation++;
      busy = false;
      measure();
    }
  }

  Future<void> measure() async {
    final read = ++_read;
    try {
      final value = await widget.capacity.usage(widget.account);
      final selected =
          widget.server != null &&
          widget.channel != null &&
          await widget.capacity.isKept(
            widget.account,
            widget.server!,
            widget.channel!,
          );
      if (!mounted || read != _read) return;
      setState(() {
        usage = value;
        kept = selected;
        _measurement.clear();
      });
    } catch (_) {
      if (mounted && read == _read) {
        setState(
          () => raise(
            _measurement,
            'Message storage could not be measured. Try again.',
            read: read,
          ),
        );
      }
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    final operation = ++_operation, identity = _identity;
    _read++;
    bool current() =>
        mounted && operation == _operation && identity == _identity;
    setState(() {
      busy = true;
    });
    try {
      await action();
      if (current()) await measure();
    } catch (cause) {
      if (current()) {
        setState(
          () => raise(
            _action,
            raftDefaultErrorText(
              cause,
              fallback: 'Message storage could not be updated. Existing messages and drafts are kept. Try again.',
            ),
          ),
        );
      }
    } finally {
      if (current()) setState(() => busy = false);
    }
  }

  Future<void> chooseBudget(int tier) => run(() async {
    final identity = _identity, operation = _operation;
    final capacity = widget.capacity, account = widget.account;
    bool current() =>
        mounted && identity == _identity && operation == _operation;
    Future<void> apply() async {
      if (!current()) {
        throw const RaftUserError(
          'The account changed. Close this dialog and try again.',
        );
      }
      await capacity.setBudget(account, tier);
    }

    final previous = usage!.budget;
    if (tier != 0 && (previous == 0 || tier < previous)) {
      await RaftConfirmDialog.show(
        context,
        RaftConfirmDialog(
          surfaceKey: const ValueKey('history-lower-dialog'),
          confirmKey: const Key('history-lower-confirm'),
          title: raftText(context, 'Lower message history limit?'),
          message: raftText(
            context,
            'Older unused messages may be removed immediately and will need an internet connection to open again. Messages in use, draft references and conversations you keep are protected.',
          ),
          confirmLabel: raftText(context, 'Lower limit'),
          loadingLabel: raftText(context, 'Updating…'),
          onConfirm: apply,
        ),
      );
    } else {
      await apply();
    }
  });

  String spaceError(HistoryCompactionPlan plan) => plan.availableBytes == null
      ? 'Available disk space could not be checked. No full cleanup was run. Try again.'
      : raftFormat(
          context,
          'Full cleanup needs {needed} of free disk space; {available} is available. Free up device space and try again.',
          {
            'needed': computerFileSize(plan.requiredBytes),
            'available': computerFileSize(plan.availableBytes!),
          },
        );

  Future<void> clean() => run(() async {
    final identity = _identity, operation = _operation;
    final capacity = widget.capacity, account = widget.account;
    bool current() =>
        mounted && identity == _identity && operation == _operation;
    final plan = await capacity.compactionPlan(account);
    if (!mounted || !current()) return;
    if (!plan.enoughSpace) throw RaftUserError(spaceError(plan));
    Future<void> apply() async {
      if (!current()) {
        throw const RaftUserError(
          'The account changed. Close this dialog and try again.',
        );
      }
      try {
        await capacity.maintain(
          account,
          compact: true,
          allowFullVacuum: plan.fullVacuum,
        );
      } on HistoryCompactionSpaceRequired catch (cause) {
        if (!mounted || !current()) return;
        throw RaftUserError(spaceError(cause.plan));
      }
    }

    if (plan.fullVacuum) {
      await RaftConfirmDialog.show(
        context,
        RaftConfirmDialog(
          surfaceKey: const ValueKey('history-full-clean-dialog'),
          confirmKey: const Key('history-full-clean-confirm'),
          title: raftText(context, 'Rebuild message storage?'),
          message: raftFormat(
            context,
            'This older database needs a full rebuild to release space. It may take a while and pause local message reads and saves. At least {needed} of free disk space is required; {available} is available. Drafts and saved files are kept.',
            {
              'needed': computerFileSize(plan.requiredBytes),
              'available': computerFileSize(plan.availableBytes!),
            },
          ),
          confirmLabel: raftText(context, 'Rebuild storage'),
          loadingLabel: raftText(context, 'Rebuilding…'),
          onConfirm: apply,
        ),
      );
    } else {
      await apply();
    }
  });

  Future<void> refresh() => run(() async {
    final operation = _operation, identity = _identity;
    final complete = await widget.refresh!();
    if (mounted && operation == _operation && identity == _identity) {
      setState(
        () => complete
            ? raise(_success, 'Shown messages refreshed.')
            : raise(
                _action,
                'Some messages could not be refreshed. Saved messages are still available. Check your connection and try again.',
              ),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final text = RaftSettingsText(RaftTokens.of(context));
    final value = usage;
    final disabled = busy || value == null;
    Widget button(String key, String label, VoidCallback? action) =>
        RaftSettingsRecipeButton(
          key: Key(key),
          label: label,
          onPressed: action,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const RaftSettingsSectionHeader(
          label: 'Messages on this device',
          glyph: RaftGlyph.messageSquareText,
        ),
        RaftSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RaftSettingsPreference(
                title: 'Message history',
                description: 'Messages you open are kept within this limit across all servers for this account. No age limit applies. Attachments and previews use the separate cache below.',
                error: error,
                notice: notice,
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(
                    value == null
                        ? raftText(context, 'Calculating…')
                        : raftFormat(
                            context,
                            'Estimated message storage: {size}',
                            {'size': computerFileSize(value.budgetCharge)},
                          ),
                    key: const Key('history-size'),
                    style: text.description,
                  ),
                ),
              ),
              if (value != null) ...[
                const SizedBox(height: RaftSpace.x2),
                Text(
                  raftFormat(
                    context,
                    'Shared database and pending writes: {size}',
                    {
                      'size': computerFileSize(
                        value.databaseBytes + value.walBytes,
                      ),
                    },
                  ),
                  key: const Key('history-device-size'),
                  style: text.description,
                ),
                Text(
                  raftText(
                    context,
                    'The account estimate includes message indexes and space reserved for writes. The shared database also holds drafts, settings and other accounts.',
                  ),
                  style: text.description,
                ),
                if (value.protectedFull)
                  Padding(
                    padding: const EdgeInsets.only(top: RaftSpace.x2),
                    child: Text(
                      raftText(
                        context,
                        'Protected messages fill the limit. Existing messages and drafts stay available. Increase the limit or stop keeping a conversation to save new messages.',
                      ),
                      key: const Key('history-protected-full'),
                      style: text.alert,
                    ),
                  ),
                if (value.pendingCompaction)
                  Padding(
                    padding: const EdgeInsets.only(top: RaftSpace.x2),
                    child: Text(
                      raftText(
                        context,
                        'Freed space is still reserved on this device. Clean up message storage to reclaim it.',
                      ),
                      style: text.description,
                    ),
                  ),
              ],
              const SizedBox(height: RaftSpace.x4),
              RaftSettingsPreference(
                title: 'Message history limit',
                description: 'When full, the oldest unused messages are removed first. Messages in use, draft references and conversations you keep are protected.',
                child: RaftSelectField<int>(
                  key: const Key('history-budget'),
                  label: 'Message history limit',
                  value: value?.budget ?? historyBudgetTiers.first,
                  items: [
                    for (final tier in historyBudgetTiers)
                      // ds-allow: RaftSelectField items are DropdownMenuItem
                      DropdownMenuItem(
                        value: tier,
                        child: Text(
                          tier == 0
                              ? raftText(context, 'Keep all')
                              : tier < (1 << 30)
                              ? '512 MiB'
                              : '${tier >> 30} GiB',
                          key: Key('history-budget-$tier'),
                        ),
                      ),
                  ],
                  onChanged: disabled
                      ? null
                      : (tier) {
                          if (tier != null) {
                            chooseBudget(tier);
                          }
                        },
                ),
              ),
              if (widget.server != null && widget.channel != null) ...[
                const SizedBox(height: RaftSpace.x4),
                RaftSettingsPreference(
                  title: 'Keep the open conversation',
                  description: 'Excludes this conversation from automatic cleanup on this device. Permission changes and signing out still remove its saved messages.',
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: RaftSwitch(
                      key: const Key('history-keep'),
                      value: kept,
                      semanticLabel: raftText(
                        context,
                        'Keep the open conversation',
                      ),
                      onChanged: disabled
                          ? null
                          : (keep) => run(() async {
                              await widget.capacity.keep(
                                widget.account,
                                widget.server!,
                                widget.channel!,
                                keep,
                              );
                              await widget.capacity.maintain(widget.account);
                            }),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: RaftSpace.x4),
              RaftSettingsPreference(
                title: 'Clean up message storage',
                description: 'Removes old unprotected messages when over the limit and reclaims freed space. Drafts, sign-in and files you saved are kept.',
                child: Wrap(
                  spacing: RaftSpace.x2,
                  runSpacing: RaftSpace.x2,
                  children: [
                    button(
                      'history-clean',
                      busy ? 'Working…' : 'Clean up',
                      disabled ? null : clean,
                    ),
                    button(
                      'history-measure',
                      'Measure again',
                      busy ? null : () => run(() async {}),
                    ),
                  ],
                ),
              ),
              if (widget.refresh != null) ...[
                const SizedBox(height: RaftSpace.x4),
                RaftSettingsPreference(
                  title: 'Refresh shown messages',
                  description: 'Checks the open conversations against the server. Saved messages stay visible while it runs. An internet connection is required.',
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: button(
                      'history-refresh',
                      'Refresh messages',
                      disabled ? null : refresh,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x6),
      ],
    );
  }
}
