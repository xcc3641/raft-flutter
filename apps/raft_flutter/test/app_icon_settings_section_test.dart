import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/features/app_icon_settings_section.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

import 'workspace_shell_contract_test.dart' show mountShell, retire;
import 'workspace_source_location_contract_test.dart' show pageFixture, frames;

void main() {
  const channel = MethodChannel('flutter_dynamic_icon_plus');
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets(
      '$family/$dark mounted mobile setting uses its standard header and returns to settings root',
      (t) async {
        String? actual = defaultTargetPlatform == TargetPlatform.iOS
            ? null
            : 'com.hugo.raft_mobile.IconYellow';
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'supportsAlternateIcons') return true;
          if (call.method == 'setAlternateIconName') {
            actual = (call.arguments as Map)['iconName'] as String?;
            return null;
          }
          return actual;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final (w, _) = await pageFixture(t, section: 'settings');
        w.navigation.navigate(RaftLocation.parse('/s/demo/settings'));
        await mountShell(t, w, family, dark, width: 390);
        final destination = find.byKey(
          const ValueKey('workspace-settings-nav-appearance'),
        );
        await t.ensureVisible(destination);
        await t.tap(destination);
        await frames(t, () {});
        await t.pumpAndSettle();
        expect(w.location.toString(), '/s/demo/settings/appearance');
        expect(find.byType(RaftSettingsPanelHeader), findsOneWidget);
        expect(find.byType(AppIconSettingsSection), findsOneWidget);
        final blue = find.byKey(const ValueKey('app-icon-blue'));
        await t.ensureVisible(blue);
        await t.pumpAndSettle();
        expect(blue.hitTestable(), findsOneWidget);
        await t.tap(blue);
        await t.pumpAndSettle();
        expect(
          actual,
          defaultTargetPlatform == TargetPlatform.iOS
              ? 'AppIconBlue'
              : 'com.hugo.raft_mobile.IconBlue',
        );
        await t.tap(find.byKey(const Key('mobile-settings-back')));
        await frames(t, () {});
        await t.pumpAndSettle();
        expect(w.location.toString(), '/s/demo/settings');
        expect(find.byType(AppIconSettingsSection), findsNothing);
        expect(t.takeException(), isNull);
        await retire(t);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}
