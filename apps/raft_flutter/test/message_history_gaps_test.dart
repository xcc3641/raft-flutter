import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/message_history_gaps.dart';
import 'package:raft_flutter/data/message_history_pages.dart';
import 'package:raft_flutter/features/chat_view.dart';
import 'package:raft_flutter/features/message_timeline.dart';
import 'package:raft_flutter/platform/workspace_cache.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'history_gaps_test.dart' show GapClient, seedGap;
import 'history_memory_test.dart' show receiver;
import 'history_memory_viewport_test.dart' show drainIo;

void main() {
  testWidgets(
    'an actual gap button loads its interval without moving the reading row',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      t.view.physicalSize = const Size(900, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final (db, client, w, scope) = (await t.runAsync(() async {
        final db = DriftWorkspaceCache(NativeDatabase.memory()),
            client = GapClient();
        final w = receiver(client, db);
        final scope = MessageHistoryPages.scope(w, 'chat')!;
        await seedGap(db, scope);
        await w.selectChannel(w.channels.single, autoRead: false);
        await w.older();
        await w.flushCache();
        return (db, client, w, scope);
      }))!;
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.elegant),
            home: Scaffold(body: RaftChatView(controller: w)),
          ),
        );
        await drainIo(
          t,
          db.messageHistory.gaps.read(scope, [
            for (final row in w.messages) (row.id, row.seq),
          ]),
        );
        await t.pumpAndSettle();
        expect(find.text('Load this gap'), findsOneWidget);
        expect(client.beforeReads, isEmpty);
        final dynamic state = t.state(find.byType(RaftChatView));
        state.recenter(
          first: 'chat-925',
          alignment: RaftTimelineAlignment.start,
        );
        await t.pumpAndSettle();
        await t.drag(
          find.byKey(const ValueKey('current-timeline')),
          const Offset(0, -40),
        );
        await t.pumpAndSettle();
        state.saveReadingAnchor();
        final anchor = w.messageWindows.readingAnchor('chat')!;
        final readingRow = find.byKey(
          ValueKey('message-wrapper-${anchor.messageKey}'),
        );
        final top = t.getRect(readingRow).top;
        final gate = client.gate = Completer<void>();
        final loaded = Completer<void>();
        void finished() {
          if (!w.loadingOlder &&
              client.beforeReads.isNotEmpty &&
              !loaded.isCompleted) {
            loaded.complete();
          }
        }

        w.addListener(finished);
        try {
          await t.tap(find.text('Load this gap'));
          await drainIo(t, client.beforeArrived.future);
          expect(find.text('Loading...'), findsOneWidget);
          expect(w.loadingOlder, isTrue);
          gate.complete();
          await drainIo(t, loaded.future);
          await t.pumpAndSettle();
          expect(client.beforeReads, [BigInt.from(901)]);
          expect(w.messages.map((row) => row.id), contains('chat-851'));
          expect(w.error, isNull);
          for (var n = 0; n < 6; n++) {
            await t.pump(const Duration(milliseconds: 16));
            expect(t.getRect(readingRow).top, closeTo(top, 1));
          }
          expect(t.takeException(), isNull);
        } finally {
          w.removeListener(finished);
          if (!gate.isCompleted) gate.complete();
        }
      } finally {
        await t.pumpWidget(const SizedBox());
        await drainIo(t, w.flushCache());
        w.dispose();
        await drainIo(t, client.arrivals.close());
        await drainIo(t, db.close());
      }
    },
  );

  for (final theme in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    for (final scale in [1.0, 3.1]) {
      testWidgets('saved gap and retry controls fit $theme at $scale', (
        t,
      ) async {
        t.view.physicalSize = const Size(360, 700);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        var taps = 0;
        Future<void> pump({bool failed = false, bool busy = false}) async {
          await t.pumpWidget(
            MaterialApp(
              theme: raftTheme(theme.$1, dark: theme.$2),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(RaftSpace.x2),
                      child: HistoryGapNotice(
                        failed: failed,
                        busy: busy,
                        onLoad: () => taps++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        }

        final semantics = t.ensureSemantics();
        try {
          await pump();
          expect(find.text('已保存的消息片段之间可能还有消息。'), findsOneWidget);
          final button = find.text('补载这段消息');
          expect(
            t.getSemantics(button).getSemanticsData().label,
            contains('补载这段消息'),
          );
          await t.tap(button);
          expect(taps, 1);
          await pump(busy: true);
          expect(
            t.widget<RaftRecipeButton>(find.byType(RaftRecipeButton)).onPressed,
            isNull,
          );
          await pump(failed: true);
          expect(find.text('无法检查已保存的历史消息。'), findsOneWidget);
          await t.tap(find.text('重试'));
          expect(taps, 2);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
