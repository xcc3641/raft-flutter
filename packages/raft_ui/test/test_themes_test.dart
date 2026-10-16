import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/test_themes.dart';

const _three = ['brutal-light', 'elegant-light', 'elegant-dark'];
const _four = ['brutal-light', 'brutal-dark', 'elegant-light', 'elegant-dark'];

void main() {
  test('stableHash is FNV-1a and does not change between runs', () {
    expect(stableHash(''), 0x811c9dc5);
    expect(stableHash('a'), 0xe40c292c);
    expect(stableHash('test/foo_test.dart'), stableHash('test/foo_test.dart'));
  });

  test('every file keeps the default variant plus one other', () {
    for (final path in [
      'test/a_test.dart',
      'test/b_test.dart',
      'x/y_test.dart',
    ]) {
      final picked = sampleThemeVariants(_three, () => path);
      expect(picked, hasLength(2));
      expect(picked.first, 'brutal-light');
      expect(picked.last, isNot('brutal-light'));
      expect(
        sampleThemeVariants(_three, () => path),
        picked,
        reason: 'deterministic',
      );
    }
    expect(
      sampleThemeVariants([
        'brutal',
        'elegant-light',
      ], () => 'test/a_test.dart'),
      ['brutal', 'elegant-light'],
    );
  });

  test('extra axes ride along with their theme variant', () {
    const rows = [
      ('brutal', 1),
      ('elegant-light', 1),
      ('elegant-dark', 1),
      ('brutal', 2),
      ('elegant-light', 2),
      ('elegant-dark', 2),
    ];
    final picked = sampleThemeVariants(
      rows,
      () => 'test/a_test.dart',
      theme: (r) => r.$1,
    );
    expect(picked, hasLength(4));
    expect(picked.where((r) => r.$1 == 'brutal'), hasLength(2));
    expect(picked.map((r) => r.$1).toSet(), hasLength(2));
  });

  test('the suite covers every non-default variant across many files', () {
    final files = [
      for (final dir in Directory('test').listSync(recursive: true))
        if (dir is File && dir.path.endsWith('_test.dart')) dir.path,
    ];
    expect(files.length, greaterThan(50));
    final three = <String, int>{};
    final four = <String, int>{};
    for (final file in files) {
      three.update(
        sampleThemeVariants(_three, () => file).last,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      four.update(
        sampleThemeVariants(_four, () => file).last,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    expect(three.keys, containsAll(['elegant-light', 'elegant-dark']));
    expect(
      four.keys,
      containsAll(['brutal-dark', 'elegant-light', 'elegant-dark']),
    );
    for (final count in [...three.values, ...four.values]) {
      expect(count, greaterThan(files.length ~/ 6));
    }
  });

  test('the calling test file is found and made package relative', () {
    final file = callingTestFile();
    expect(file, endsWith('test_themes_test.dart'));
    expect(packageRelativePath(file), 'test/test_themes_test.dart');
  });

  group('calling test stack frames', () {
    for (final fixture in [
      (
        name: 'POSIX file URI',
        uri: 'file:///repo/test/a_test.dart',
        posix: '/repo/test/a_test.dart',
        windows: r'\repo\test\a_test.dart',
      ),
      (
        name: 'Windows drive URI',
        uri: 'file:///D:/repo/test/agent_menu_anchor_test.dart',
        posix: '/D:/repo/test/agent_menu_anchor_test.dart',
        windows: r'D:\repo\test\agent_menu_anchor_test.dart',
      ),
      (
        name: 'Windows spaces and parentheses',
        uri: 'file:///D:/Work%20(lab)/test/space%20name_test.dart',
        posix: '/D:/Work (lab)/test/space name_test.dart',
        windows: r'D:\Work (lab)\test\space name_test.dart',
      ),
      (
        name: 'POSIX spaces and parentheses',
        uri: 'file:///work%20(lab)/test/space%20name_test.dart',
        posix: '/work (lab)/test/space name_test.dart',
        windows: r'\work (lab)\test\space name_test.dart',
      ),
      (
        name: 'test suffix in a directory name',
        uri: 'file:///repo/nested_test.dart/test/actual_test.dart',
        posix: '/repo/nested_test.dart/test/actual_test.dart',
        windows: r'\repo\nested_test.dart\test\actual_test.dart',
      ),
    ]) {
      test(fixture.name, () {
        final stack = StackTrace.fromString(
          '#0 callingTestFile (package:raft_ui/test_themes.dart:97:3)\n'
          '#1 main (${fixture.uri}:8:32)\n',
        );
        expect(
          callingTestFile(stack),
          Platform.isWindows ? fixture.windows : fixture.posix,
        );
      });
    }

    test('the nearest test frame wins over its caller', () {
      final stack = StackTrace.fromString(
        '#0 main (file:///repo/test/nearest_test.dart:8:32)\n'
        '#1 main (file:///repo/test/outer_test.dart:3:1)\n',
      );
      expect(callingTestFile(stack), endsWith('nearest_test.dart'));
    });

    test('a directory or backup suffix does not make a test frame', () {
      for (final uri in [
        'file:///repo/nested_test.dart/helper.dart',
        'file:///repo/test/a_test.dart.backup',
      ]) {
        expect(
          () => callingTestFile(StackTrace.fromString('#0 main ($uri:1:2)')),
          throwsStateError,
        );
      }
      expect(() => callingTestFile(StackTrace.empty), throwsStateError);
    });

    test('a real package in a spaced path keeps its canonical sample', () {
      final directory = Directory.systemTemp.createTempSync(
        'raft themes (lab) ',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      File('${directory.path}/pubspec.yaml')
          .writeAsStringSync('name: theme_lab');
      final file = File('${directory.path}/test/space name_test.dart');
      file.parent.createSync();
      file.writeAsStringSync('');
      final stack = StackTrace.fromString('#0 main (${file.uri}:8:32)');
      final path = packageRelativePath(callingTestFile(stack));
      expect(path, 'test/space name_test.dart');
      expect(
        sampleThemeVariants(_three, () => path),
        sampleThemeVariants(_three, () => 'test/space name_test.dart'),
      );
    });
  });

  test('full: true keeps the whole matrix', () {
    expect(raftThemeMatrix(_three, full: true), _three);
    final sampled = raftThemeMatrix(_three);
    expect(sampled.first, 'brutal-light');
    expect(sampled, raftAllThemes ? _three : hasLength(2));
  });
}
