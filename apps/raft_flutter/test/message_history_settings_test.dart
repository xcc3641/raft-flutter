import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/history_capacity.dart';
import 'package:raft_flutter/features/message_history_settings.dart';
import 'package:raft_ui/raft_ui.dart';

const account = HistoryAccount('https://history.invalid', 'alice');

class _Capacity implements HistoryCapacity {
  int budget = 1 << 30;
  bool kept = false, full = false, pending = false, fail = false;
  int cleanups = 0;
  bool fullAllowed = false;
  HistoryCompactionPlan plan = const HistoryCompactionPlan(fullVacuum: false);
  Completer<void>? gate;
  @override
  Future<HistoryDiskUsage> usage(HistoryAccount account) async {
    await gate?.future;
    if (fail) throw StateError('synthetic');
    return HistoryDiskUsage(
      budget: budget,
      accountBytes: 80 << 20,
      databaseBytes: 100 << 20,
      walBytes: 2 << 20,
      indexBytes: 2 << 20,
      freeBytes: 0,
      rows: 1000,
      pendingCompaction: pending,
      protectedFull: full,
    );
  }

  @override
  Future<void> setBudget(HistoryAccount account, int bytes) async {
    if (fail) throw StateError('synthetic');
    budget = bytes;
  }

  @override
  Future<bool> isKept(
    HistoryAccount account,
    String server,
    String channel,
  ) async => kept;
  @override
  Future<void> keep(
    HistoryAccount account,
    String server,
    String channel,
    bool value,
  ) async => kept = value;
  @override
  Future<HistoryDiskUsage> maintain(
    HistoryAccount account, {
    bool compact = false,
    bool allowFullVacuum = false,
  }) async {
    if (fail) throw StateError('synthetic');
    if (compact) {
      cleanups++;
      fullAllowed = allowFullVacuum;
    }
    pending = false;
    return usage(account);
  }

  @override
  Future<HistoryCompactionPlan> compactionPlan(HistoryAccount account) async =>
      plan;

  @override
  void protect(
    Object owner,
    Iterable<HistoryProtectedRows> Function() current,
  ) {}
  @override
  void release(Object owner) {}
}

Future<void> _pump(
  WidgetTester t,
  _Capacity cap, {
  RaftFamily family = RaftFamily.elegant,
  bool dark = false,
  double scale = 1,
  Locale locale = const Locale('en'),
  Future<bool> Function()? refresh,
}) async {
  t.view.physicalSize = const Size(360, 1500);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: raftTheme(family, dark: dark),
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(RaftSpace.x4),
              child: MessageHistorySettings(
                capacity: cap,
                account: account,
                server: 'one',
                channel: 'chat',
                refresh: refresh,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'usage does not hold the first frame and measurement can be retried',
    (t) async {
      final cap = _Capacity()..gate = Completer<void>();
      await _pump(t, cap);
      expect(
        t.widget<Text>(find.byKey(const Key('history-size'))).data,
        'Calculating…',
      );
      expect(
        t
            .widget<RaftSettingsRecipeButton>(
              find.byKey(const Key('history-clean')),
            )
            .onPressed,
        isNull,
      );
      cap.gate!.complete();
      await t.pumpAndSettle();
      expect(find.text('Estimated message storage: 80.0 MB'), findsOneWidget);
      expect(
        find.text('Shared database and pending writes: 102.0 MB'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('history-device-size')), findsOneWidget);
    },
  );

  for (final theme in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    for (final scale in [1.0, 3.1]) {
      testWidgets('history controls fit phone width in $theme at $scale', (
        t,
      ) async {
        final cap = _Capacity()
          ..full = true
          ..pending = true;
        await _pump(
          t,
          cap,
          family: theme.$1,
          dark: theme.$2,
          scale: scale,
          refresh: () async => true,
        );
        await t.pumpAndSettle();
        expect(find.byKey(const Key('history-protected-full')), findsOneWidget);
        await t.ensureVisible(find.byKey(const Key('history-refresh')));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'budget choices, retention and cleanup invoke the account controls',
    (t) async {
      final cap = _Capacity();
      await _pump(t, cap);
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('history-budget')));
      await t.tap(find.byKey(const Key('history-budget')));
      await t.pumpAndSettle();
      await t.tap(find.text('512 MiB').last);
      await t.pumpAndSettle();
      expect(cap.budget, 1 << 30);
      await t.tap(find.byKey(const Key('history-lower-confirm')));
      await t.pumpAndSettle();
      expect(cap.budget, 512 << 20);
      await t.ensureVisible(find.byKey(const Key('history-keep')));
      await t.tap(find.byKey(const Key('history-keep')));
      await t.pumpAndSettle();
      expect(cap.kept, isTrue);
      await t.ensureVisible(find.byKey(const Key('history-clean')));
      await t.tap(find.byKey(const Key('history-clean')));
      await t.pumpAndSettle();
      expect(cap.cleanups, 1);
    },
  );

  testWidgets(
    'lowering the limit waits for confirmation and cancellation keeps it',
    (t) async {
      final cap = _Capacity();
      await _pump(t, cap);
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('history-budget')));
      await t.tap(find.byKey(const Key('history-budget')));
      await t.pumpAndSettle();
      await t.tap(find.text('512 MiB').last);
      await t.pumpAndSettle();
      expect(cap.budget, 1 << 30);
      expect(find.byKey(const Key('history-lower-dialog')), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(cap.budget, 1 << 30);
    },
  );

  for (final theme in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    testWidgets(
      'full cleanup warns and requires consent in $theme at large text',
      (t) async {
        final cap = _Capacity()
          ..plan = const HistoryCompactionPlan(
            fullVacuum: true,
            requiredBytes: 200 << 20,
            availableBytes: 1 << 30,
          );
        await _pump(t, cap, family: theme.$1, dark: theme.$2, scale: 3.1);
        await t.pumpAndSettle();
        await t.ensureVisible(find.byKey(const Key('history-clean')));
        await t.tap(find.byKey(const Key('history-clean')));
        await t.pumpAndSettle();
        expect(
          find.byKey(const Key('history-full-clean-dialog')),
          findsOneWidget,
        );
        expect(cap.cleanups, 0);
        expect(t.takeException(), isNull);
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        expect(cap.cleanups, 0);
        await t.tap(find.byKey(const Key('history-clean')));
        await t.pumpAndSettle();
        await t.ensureVisible(
          find.byKey(const Key('history-full-clean-confirm')),
        );
        await t.tap(find.byKey(const Key('history-full-clean-confirm')));
        await t.pumpAndSettle();
        expect(cap.cleanups, 1);
        expect(cap.fullAllowed, isTrue);
      },
    );
  }
  for (final available in <int?>[0, null]) {
    testWidgets(
      'full cleanup stays untouched when free space is unavailable: $available',
      (t) async {
        final cap = _Capacity()
          ..plan = HistoryCompactionPlan(
            fullVacuum: true,
            requiredBytes: 200 << 20,
            availableBytes: available,
          );
        await _pump(t, cap);
        await t.pumpAndSettle();
        await t.ensureVisible(find.byKey(const Key('history-clean')));
        await t.tap(find.byKey(const Key('history-clean')));
        await t.pumpAndSettle();
        expect(cap.cleanups, 0);
        expect(
          find.byKey(const Key('history-full-clean-dialog')),
          findsNothing,
        );
        expect(
          find.textContaining(
            available == null
                ? 'Available disk space could not'
                : 'Full cleanup needs',
          ),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'refresh reports its real result and leaves old usage visible while pending',
    (t) async {
      final cap = _Capacity(), gate = Completer<bool>();
      await _pump(t, cap, refresh: () => gate.future);
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('history-refresh')));
      await t.tap(find.byKey(const Key('history-refresh')));
      await t.pump();
      expect(find.text('Estimated message storage: 80.0 MB'), findsOneWidget);
      expect(
        t
            .widget<RaftSettingsRecipeButton>(
              find.byKey(const Key('history-refresh')),
            )
            .onPressed,
        isNull,
      );
      gate.complete(false);
      await t.pumpAndSettle();
      expect(
        find.text(
          'Some messages could not be refreshed. Saved messages are still available. Check your connection and try again.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'measurement errors have a retry action and Chinese controls are translated',
    (t) async {
      final cap = _Capacity()..fail = true;
      await _pump(t, cap, locale: const Locale('zh', 'CN'));
      await t.pumpAndSettle();
      expect(find.text('无法计算消息占用，请重试。'), findsOneWidget);
      expect(find.text('重新计算'), findsOneWidget);
      cap.fail = false;
      await t.ensureVisible(find.byKey(const Key('history-measure')));
      await t.tap(find.byKey(const Key('history-measure')));
      await t.pumpAndSettle();
      expect(find.text('消息占用估算：80.0 MB'), findsOneWidget);
      expect(find.text('保留当前会话'), findsOneWidget);
    },
  );

  testWidgets('a retired settings action cannot publish into another scope', (
    t,
  ) async {
    final first = _Capacity(), gate = Completer<bool>();
    await _pump(t, first, refresh: () => gate.future);
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('history-refresh')));
    await t.tap(find.byKey(const Key('history-refresh')));
    await t.pump();
    final next = _Capacity()..budget = 5 << 30;
    await _pump(t, next, refresh: () async => true);
    await t.pumpAndSettle();
    gate.complete(false);
    await t.pumpAndSettle();
    expect(
      find.text(
        'Some messages could not be refreshed. Saved messages are still available. Check your connection and try again.',
      ),
      findsNothing,
    );
    expect(
      t
          .widget<RaftSelectField<int>>(find.byKey(const Key('history-budget')))
          .value,
      5 << 30,
    );
    expect(
      t
          .widget<RaftSettingsRecipeButton>(
            find.byKey(const Key('history-refresh')),
          )
          .onPressed,
      isNotNull,
    );
  });
}
