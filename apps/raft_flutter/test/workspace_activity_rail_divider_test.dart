import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

import 'desktop_footer_sidebar_page_test.dart' show shellFonts;
import 'workspace_shell_contract_test.dart' show mountShell, retire;
import 'workspace_source_location_contract_test.dart' show pageFixture, frames;

// Activity retains its thin divider, but navigation slots keep the regular
// border-box geometry on every route (Kevin bd97261a).
void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets(
      '$family/$dark Activity divider does not move actual navigation slots',
      (t) async {
        final (w, _) = await pageFixture(t, section: 'activity');
        w.navigation.navigate(RaftLocation.parse('/s/demo/activity'));
        await shellFonts(t);
        await mountShell(t, w, family, dark);
        final help = find.byKey(const Key('rail-help'));
        final expectedCenter = family == RaftFamily.brutal ? 31.0 : 28.0;
        void checkGeometry(double borderWidth) {
          expect(t.getRect(help).width, 40);
          expect(t.getCenter(help).dx, expectedCenter);
          final rail = find.byType(RaftWorkspaceRail);
          final border = find.descendant(
            of: rail,
            matching: find.byWidgetPredicate((widget) {
              if (widget is! DecoratedBox ||
                  widget.decoration is! BoxDecoration) {
                return false;
              }
              final decoration = widget.decoration as BoxDecoration;
              return widget.position == DecorationPosition.foreground &&
                  decoration.border is Border;
            }),
          );
          if (family == RaftFamily.brutal) {
            expect(border, findsOneWidget);
            final decoration = t.widget<DecoratedBox>(border).decoration;
            expect(
              ((decoration as BoxDecoration).border! as Border).right.width,
              borderWidth,
            );
          } else {
            expect(border, findsNothing);
          }
        }

        expect(t.getRect(help).width, 40);
        checkGeometry(1);
        await t.tap(find.byKey(const Key('rail-chat')));
        await frames(t, () {});
        await t.pumpAndSettle();
        expect(w.location.route, RaftRoute.channel);
        expect(w.location.entityId, 'c1');
        checkGeometry(2);
        await t.tap(find.byKey(const Key('rail-activity')));
        await frames(t, () {});
        await t.pumpAndSettle();
        expect(w.location.route, RaftRoute.activity);
        checkGeometry(1);
        await retire(t);
      },
      variant: TargetPlatformVariant({TargetPlatform.linux}),
    );
  }
}
