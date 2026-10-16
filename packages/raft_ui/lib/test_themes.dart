/// Theme-matrix sampling for the Dart test suites (owner decision 2026-10-12).
///
/// Many tests run once per theme variant (brutal-light, elegant-light,
/// elegant-dark; a few also brutal-dark). The variants only re-skin the same
/// behaviour, so by default a test file keeps its FIRST variant (the default,
/// brutal-light, which every list in the suite puts first) and ONE other
/// variant picked by a stable hash of the file's package-relative path. The
/// pick spreads the suite across the variants: roughly half of the files
/// sample elegant-light, the other half elegant-dark.
///
/// Set `RAFT_TEST_ALL_THEMES=1` to run every variant of every test. Use it
/// before merging to main, and whenever theme, token or recipe code changes
/// (`python3 tool/check-project --all-themes` passes it on).
///
/// A test that is ABOUT theme differences (asserts per-family colours, token
/// values, contrast audits, recipe comparisons) passes `full: true` and always
/// runs the whole matrix.
///
/// This library is for test code only (it uses `dart:io`); do not import it
/// from app code.
library;

import 'dart:convert';
import 'dart:io';

/// The environment variable that turns sampling off.
const raftAllThemesVariable = 'RAFT_TEST_ALL_THEMES';

/// True when every test must run its whole theme matrix.
bool get raftAllThemes => Platform.environment[raftAllThemesVariable] == '1';

/// The variants of [variants] the calling test file should run.
///
/// The variant of the FIRST element is the default (brutal-light). With
/// `full: true`, or `RAFT_TEST_ALL_THEMES=1`, all elements are returned. The
/// calling test file is found from the stack, so call this while the file's
/// `main` runs, usually as the iterable of the `for` loop that declares the
/// tests: `for (final (family, dark) in raftThemeMatrix([...])) { ... }`.
///
/// When an element carries more than the theme (a width, a platform), pass
/// [theme] to extract the part that identifies the theme variant; elements
/// that share a variant are kept or dropped together.
List<T> raftThemeMatrix<T>(
  List<T> variants, {
  bool full = false,
  Object? Function(T variant)? theme,
}) {
  if (full || raftAllThemes) return variants;
  return sampleThemeVariants(
    variants,
    () => packageRelativePath(callingTestFile()),
    theme: theme,
  );
}

/// Pure sampling rule: the default variant plus one other chosen by the path.
///
/// [path] is only evaluated when there are at least three variants to choose
/// from, so a two-variant list needs no stack lookup.
List<T> sampleThemeVariants<T>(
  List<T> variants,
  String Function() path, {
  Object? Function(T variant)? theme,
}) {
  final keyOf = theme ?? (T variant) => variant;
  final keys = <Object?>[];
  for (final variant in variants) {
    final key = keyOf(variant);
    if (!keys.contains(key)) keys.add(key);
  }
  if (keys.length < 3) return variants;
  final others = keys.sublist(1);
  final kept = {keys.first, others[stableHash(path()) % others.length]};
  return [
    for (final variant in variants)
      if (kept.contains(keyOf(variant))) variant,
  ];
}

/// FNV-1a over the UTF-8 bytes of [text]: the same in every run and Dart version.
int stableHash(String text) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(text)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

// A drive colon or a parenthesis can belong to the URI. End at the VM frame's
// location suffix instead of treating those valid path characters as separators.
final _testFrame = RegExp(r'(file:///.*_test\.dart)(?::\d+(?::\d+)?)?\)\s*$');

/// The `*_test.dart` file nearest to the top of the current stack.
/// An explicit [stack] lets regression tests exercise other platforms' frames.
String callingTestFile([StackTrace? stack]) {
  for (final line in (stack ?? StackTrace.current).toString().split('\n')) {
    final match = _testFrame.firstMatch(line);
    if (match != null) return Uri.parse(match.group(1)!).toFilePath();
  }
  throw StateError(
    'raftThemeMatrix could not find the calling *_test.dart in the stack; '
    'call it while the test file is being declared, or pass full: true.',
  );
}

final _packageRelative = <String, String>{};

/// [file] relative to its package root (the nearest pubspec.yaml), with `/`.
String packageRelativePath(String file) {
  return _packageRelative.putIfAbsent(file, () {
    var dir = File(file).parent;
    while (!File('${dir.path}${Platform.pathSeparator}pubspec.yaml')
        .existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError('No pubspec.yaml above $file');
      }
      dir = parent;
    }
    var relative = file.substring(dir.path.length + 1);
    if (Platform.pathSeparator != '/') {
      relative = relative.replaceAll(Platform.pathSeparator, '/');
    }
    return relative;
  });
}
