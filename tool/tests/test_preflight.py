"""tool/preflight: argument handling, the affected-test cap, the portability scan and the JSON result.

Every subprocess is faked: nothing here runs git against a real remote, Flutter or the audits.
"""
import importlib.machinery
import pathlib
import importlib.util
import io
import json
import contextlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
LOADER = importlib.machinery.SourceFileLoader('preflight_tool', str(TOOL / 'preflight'))
pf = importlib.util.module_from_spec(importlib.util.spec_from_loader('preflight_tool', LOADER))
LOADER.exec_module(pf)
CHECK_LOADER = importlib.machinery.SourceFileLoader('check_project_for_preflight', str(TOOL / 'check-project'))
check_project = importlib.util.module_from_spec(importlib.util.spec_from_loader('check_project_for_preflight', CHECK_LOADER))
CHECK_LOADER.exec_module(check_project)

TEST = 'apps/raft_flutter/test/db_test.dart'


def scan(text, lines=None, path=TEST):
    return pf.scan_portability(path, text, lines)


class ArgumentTests(unittest.TestCase):
    def test_defaults(self):
        args = pf.parse_args([])
        self.assertEqual((args.base, args.max_tests, args.out), ('origin/cindy/integration', 40, '.local/preflight.json'))

    def test_base_max_tests_and_out_override(self):
        args = pf.parse_args(['--base', 'origin/main', '--max-tests', '7', '--out', '/tmp/x.json'])
        self.assertEqual((args.base, args.max_tests, args.out), ('origin/main', 7, '/tmp/x.json'))

    def test_max_tests_must_be_a_positive_integer(self):
        for bad in ('0', '-3', 'many'):
            with self.subTest(bad=bad), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                pf.parse_args(['--max-tests', bad])

    def test_unknown_options_are_rejected(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            pf.parse_args(['--nope'])


class ListsStayHonestTests(unittest.TestCase):
    def test_test_dirs_match_check_project(self):
        self.assertEqual(pf.TEST_DIRS, check_project.TEST_DIRS)

    def test_guard_tests_exist_and_are_dart_tests_of_the_app(self):
        for name in pf.GUARD_TESTS:
            self.assertTrue((pf.root / name).is_file(), name)
            self.assertTrue(name.startswith('apps/raft_flutter/test/') and name.endswith('_test.dart'))
        self.assertEqual(len(pf.GUARD_TESTS), len(set(pf.GUARD_TESTS)))
        self.assertTrue((pf.root / pf.DOCS_INDEX_TEST).is_file())


class PortabilityTests(unittest.TestCase):
    def test_hard_coded_tool_paths_are_findings_with_their_line(self):
        found = scan("void main() {\n  final sqlite = '/usr/bin/sqlite3';\n  final b = '/opt/homebrew/bin/jq';\n  final c = \"/usr/local/bin/ffmpeg\";\n}\n")
        self.assertEqual([(n) for _, n, _ in found], [2, 3, 4])
        self.assertTrue(all(p == TEST for p, _, _ in found))
        self.assertIn('/usr/bin/sqlite3', found[0][2])

    def test_process_of_a_system_cli_is_a_finding_even_over_two_lines(self):
        found = scan("test('x', () async {\n  await Process.run('sqlite3', ['a.db']);\n  final p = await Process.start(\n    \"xcrun\", ['simctl']);\n});\n")
        self.assertEqual([n for _, n, _ in found], [2, 3])
        self.assertIn("'sqlite3'", found[0][2])
        self.assertIn("'xcrun'", found[1][2])

    def test_other_process_forms_are_found(self):
        self.assertEqual([n for _, n, _ in scan("final r = Process.runSync('openssl', ['version']);\n")], [1])

    def test_path_entries_core_tools_and_computed_executables_are_fine(self):
        text = ("final env = {'PATH': '/usr/bin:/bin', 'X': '/usr/local/bin'};\n"
                "await Process.run('git', ['status']);\n"
                "await Process.run('chmod', ['+x', f]);\n"
                "await Process.start(Platform.resolvedExecutable, ['x']);\n"
                "await Process.run(tool, args);\n"
                "await Process.run('$dir/helper', []);\n"
                "// see /usr/bin/sqlite3 for the old way\n")
        self.assertEqual(scan(text), [])

    def test_allow_marker_on_the_line_or_the_line_above(self):
        text = ("final a = '/usr/bin/sqlite3'; // preflight-allow: mac-only test, skipped elsewhere\n"
                "// preflight-allow: darwin only\n"
                "await Process.run('xcrun', []);\n"
                "final b = '/usr/bin/sqlite3';\n")
        self.assertEqual([n for _, n, _ in scan(text)], [4])

    def test_one_finding_per_line(self):
        self.assertEqual(len(scan("await Process.run('/usr/bin/sqlite3', []);\n")), 1)

    def test_only_the_given_lines_are_reported(self):
        text = "final a = '/usr/bin/sqlite3';\nfinal b = '/opt/homebrew/bin/x';\n"
        self.assertEqual([n for _, n, _ in scan(text, {2})], [2])
        self.assertEqual(scan(text, set()), [])


class ChangedLinesTests(unittest.TestCase):
    def test_a_new_file_is_scanned_whole_and_an_edited_one_by_hunk(self):
        diff = '@@ -3,0 +4,2 @@ x\n@@ -10 +12 @@ y\n@@ -20,2 +22,0 @@ z\n'
        changes = pf.Changes('mb', [TEST], {'apps/new_test.dart'})
        with mock.patch.object(pf, 'git', return_value=diff) as git:
            self.assertEqual(pf.added_lines(changes, TEST), {4, 5, 12})
            self.assertEqual(git.call_args.args[:2], ('diff', '--no-renames'))
        self.assertIsNone(pf.added_lines(changes, 'apps/new_test.dart'))


class AffectedCapTests(unittest.TestCase):
    def make(self, tests, changed_dart=('apps/raft_flutter/lib/a.dart',)):
        """rank_tests with a fake import graph: `tests` maps test path -> import distance."""
        ranked = sorted((distance, name) for name, distance in tests.items())
        changes = pf.Changes('mb', list(changed_dart), set())
        patches = [mock.patch.object(pf.affected_tests, 'tracked_dart_sources', return_value={}),
                   mock.patch.object(pf.affected_tests, 'workspace_packages', return_value={}),
                   mock.patch.object(pf.affected_tests, 'ranked_affected_tests', return_value=ranked)]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        with mock.patch.object(pf, 'root', Path(tempfile.mkdtemp())):
            (pf.root / changed_dart[0]).parent.mkdir(parents=True, exist_ok=True)
            (pf.root / changed_dart[0]).write_text('')
            return pf.rank_tests(changes, self.cap)

    def test_under_the_cap_everything_runs_as_app_relative_paths(self):
        self.cap = 40
        files, skipped, total = self.make({'apps/raft_flutter/test/a_test.dart': 1, 'packages/raft_ui/test/b_test.dart': 2})
        self.assertEqual(files, ['test/a_test.dart', '../../packages/raft_ui/test/b_test.dart'])
        self.assertEqual((skipped, total), (0, 2))

    def test_over_the_cap_the_closest_run_and_the_rest_are_counted(self):
        self.cap = 3
        tests = {f'apps/raft_flutter/test/t{i}_test.dart': i for i in range(7)}
        files, skipped, total = self.make(tests)
        self.assertEqual(files, ['test/t0_test.dart', 'test/t1_test.dart', 'test/t2_test.dart'])
        self.assertEqual((skipped, total), (4, 7))

    def test_guard_tests_and_tests_outside_the_gate_suites_are_not_repeated(self):
        self.cap = 40
        files, skipped, total = self.make({pf.GUARD_TESTS[0]: 0, 'tool/raft_lints/test/x_test.dart': 1, 'apps/raft_flutter/test/real_test.dart': 2})
        self.assertEqual(files, ['test/real_test.dart'])
        self.assertEqual((skipped, total), (0, 1))


class FakeWorld:
    """A repo-shaped temp directory plus fakes for git and for every heavy child."""

    def __init__(self, case, files=None, failing=(), behind=0):
        tmp = tempfile.TemporaryDirectory()
        case.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.files = files or {'apps/raft_flutter/lib/a.dart': 'void a() {}\n', TEST: "void main() {}\n"}
        for name, text in self.files.items():
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text(text)
        self.failing, self.behind, self.commands = set(failing), behind, []
        self.changes = pf.Changes('mergebase1', sorted(self.files), set(self.files))
        patches = [
            mock.patch.object(pf, 'root', self.root), mock.patch.object(pf, 'app_dir', self.root / 'apps/raft_flutter'),
            mock.patch.object(pf, 'git', self.git), mock.patch.object(pf, 'execute', self.execute),
            mock.patch.object(pf, 'collect_changes', lambda base: self.changes),
            mock.patch.object(pf, 'workspace_resolved', lambda: True), mock.patch.object(pf, 'lints_resolved', lambda: True),
            mock.patch.object(pf, 'dart_executable', lambda: '/sdk/bin/dart'),
            mock.patch.object(pf, 'rank_tests', lambda changes, cap: (['test/a_test.dart'][:cap], 2, 3)),
            mock.patch.object(pf, 'run_tmp', lambda: self.root / 'tmp'),
        ]
        for patcher in patches:
            patcher.start()
            case.addCleanup(patcher.stop)

    def git(self, *args):
        if args[0] == 'rev-parse' and args[-1] == 'HEAD^{tree}':
            return 'treehash0123456789abcdef\n'
        if args[0] == 'rev-parse' and args[1] == 'HEAD':
            return 'headsha\n'
        if args[0] == 'rev-parse':
            return 'basesha000\n' if not self.behind else 'basesha111\n'
        if args[0] == 'rev-list':
            return f'{self.behind}\n'
        if args[0] == 'status':
            return ''
        if args[0] == 'diff':
            return ''
        return ''

    def execute(self, command, cwd, env):
        self.commands.append(command)
        text = ' '.join(command)
        for name in self.failing:
            if any(part == name or part.endswith('/' + name) for part in command) or (' ' in name and name in text):
                return 1, f'{name} blew up\nline two\n'
        return 0, 'ok\n'


class RunTests(unittest.TestCase):
    def run_main(self, world, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = pf.main(['--out', str(world.root / 'result.json'), *argv])
        return code, out.getvalue()

    def test_a_clean_run_passes_runs_every_step_and_writes_the_json(self):
        world = FakeWorld(self)
        code, out = self.run_main(world)
        self.assertEqual(code, 0)
        result = json.loads((world.root / 'result.json').read_text())
        self.assertTrue(result['passed'])
        self.assertEqual(result['tree'], 'treehash0123456789abcdef')
        self.assertEqual(result['head'], 'headsha')
        self.assertEqual([c['name'] for c in result['checks']],
                         ['structure-audit', 'ds-audit', 'docs-index', 'guard-tests', 'analyze', 'raft-lints', 'format', 'affected-tests', 'portability'])
        self.assertEqual(result['affectedTests'], {'maxTests': 40, 'selected': 1, 'total': 3, 'skipped': 2})
        self.assertEqual(result['changedDart'], 2)
        last = out.strip().splitlines()[-1]
        self.assertTrue(last.startswith('preflight: PASSED 9/9 checks'), last)
        self.assertIn('tree treehash0123', last)
        for check in ('structure-audit', 'ds-audit', 'portability'):
            self.assertIn(check, out)

    def test_every_check_runs_even_after_failures_and_the_exit_code_says_failed(self):
        world = FakeWorld(self, failing=('structure-audit', 'dart'))
        code, out = self.run_main(world)
        self.assertEqual(code, 1)
        result = json.loads((world.root / 'result.json').read_text())
        statuses = {c['name']: c['status'] for c in result['checks']}
        self.assertEqual(len(statuses), 9)
        self.assertEqual(statuses['structure-audit'], 'fail')
        self.assertEqual(statuses['ds-audit'], 'pass')
        self.assertEqual(statuses['format'], 'fail')
        self.assertFalse(result['passed'])
        self.assertIn('structure-audit blew up', out)  # the failing step's output tail is shown
        self.assertIn('preflight: FAILED (structure-audit, format)', out.strip().splitlines()[-1])

    def test_portability_findings_fail_the_run_with_file_and_line(self):
        world = FakeWorld(self, files={TEST: "void main() {\n  run('/usr/bin/sqlite3');\n}\n"})
        code, out = self.run_main(world)
        self.assertEqual(code, 1)
        result = json.loads((world.root / 'result.json').read_text())
        self.assertEqual(result['findings'], [{'file': TEST, 'line': 2, 'message': result['findings'][0]['message']}])
        self.assertIn(f'{TEST}:2:', out)

    def test_skips_are_not_failures_and_a_docs_only_change_runs_the_audits_only(self):
        world = FakeWorld(self, files={'docs/x.md': 'x'})
        code, out = self.run_main(world)
        self.assertEqual(code, 0)
        result = json.loads((world.root / 'result.json').read_text())
        statuses = {c['name']: c['status'] for c in result['checks']}
        self.assertEqual({n for n, s in statuses.items() if s == 'pass'}, {'structure-audit', 'ds-audit', 'docs-index', 'guard-tests'})
        self.assertEqual({n for n, s in statuses.items() if s == 'skip'}, {'analyze', 'raft-lints', 'format', 'affected-tests', 'portability'})
        self.assertIn('PASSED 4/4 checks', out)

    def test_analyze_format_and_lints_get_only_the_changed_files(self):
        world = FakeWorld(self)
        self.run_main(world)
        by = lambda word: next(c for c in world.commands if any(part.endswith(word) for part in c))
        self.assertEqual(by('analyze')[-2:], ['apps/raft_flutter/lib/a.dart', TEST])
        self.assertEqual(by('raft-lints')[-1], 'apps/raft_flutter/lib/a.dart')
        self.assertEqual(by('format')[-2:], ['apps/raft_flutter/lib/a.dart', TEST])
        self.assertIn('--set-exit-if-changed', by('format'))

    def test_a_branch_behind_the_base_is_warned_about_and_still_checked(self):
        world = FakeWorld(self, behind=3)
        code, out = self.run_main(world)
        self.assertEqual(code, 0)
        self.assertIn('3 commit(s) behind origin/cindy/integration', out)
        self.assertEqual(json.loads((world.root / 'result.json').read_text())['behindBase'], 3)
        self.assertIn('3 behind base', out.strip().splitlines()[-1])

    def test_max_tests_reaches_the_selection(self):
        world = FakeWorld(self)
        seen = []
        with mock.patch.object(pf, 'rank_tests', lambda changes, cap: seen.append(cap) or ([], 0, 0)):
            self.run_main(world, '--max-tests', '5')
        self.assertEqual(seen, [5])

    def test_an_unknown_base_is_a_usage_error(self):
        world = FakeWorld(self)

        def missing(*args):
            if args[0] == 'rev-parse' and '--verify' in args:
                raise pf.PreflightError('unknown revision')
            return world.git(*args)

        with mock.patch.object(pf, 'git', missing), contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(pf.main(['--base', 'origin/nope', '--out', str(world.root / 'r.json')]), 2)
        self.assertIn('origin/nope not found', err.getvalue())
        self.assertFalse((world.root / 'r.json').exists())

    def test_a_failed_pub_get_fails_the_dependent_checks_but_not_the_independent_ones(self):
        world = FakeWorld(self, failing=('pub get',))
        with mock.patch.object(pf, 'workspace_resolved', lambda: False):
            code, out = self.run_main(world)
        self.assertEqual(code, 1)
        statuses = {c['name']: c['status'] for c in json.loads((world.root / 'result.json').read_text())['checks']}
        self.assertEqual(statuses['pub-get'], 'fail')
        self.assertEqual((statuses['structure-audit'], statuses['affected-tests']), ('fail', 'fail'))
        self.assertEqual((statuses['docs-index'], statuses['format'], statuses['portability']), ('pass', 'pass', 'pass'))


class NiceTests(unittest.TestCase):
    def test_heavy_children_run_at_nice_10(self):
        done = subprocess.CompletedProcess([], 0, stdout='fine\n')
        with mock.patch.object(pf.shutil, 'which', lambda name: '/usr/bin/nice'), \
                mock.patch.object(pf.os, 'name', 'posix'), \
                mock.patch.object(pf.subprocess, 'run', return_value=done) as run:
            self.assertEqual(pf.execute(['tool/flutter', 'analyze'], '.', {}), (0, 'fine\n'))
        self.assertEqual(run.call_args.args[0], ['nice', '-n', '10', 'tool/flutter', 'analyze'])

    def test_without_nice_the_command_runs_as_is(self):
        with mock.patch.object(pf.shutil, 'which', lambda name: None):
            self.assertEqual(pf.with_nice(['x']), ['x'])

    def test_a_missing_tool_is_a_failed_check_not_a_crash(self):
        with mock.patch.object(pf.subprocess, 'run', side_effect=FileNotFoundError('nope')):
            code, output = pf.execute(['missing'], '.', {})
        self.assertEqual(code, 127)
        self.assertIn('cannot run missing', output)


class SummaryTests(unittest.TestCase):
    def test_a_failed_test_run_shows_the_failure_list_not_the_progress_noise(self):
        output = '\n'.join([f'01:0{i} +{i}: some test' for i in range(9)] + ['Some tests failed.', 'Failing tests:', '  a_test.dart: boom'])
        self.assertEqual(pf.tail_of(output), ['Failing tests:', '  a_test.dart: boom'])
        self.assertEqual(pf.tail_of('a\nb\nc', 2), ['b', 'c'])

    def test_an_unusable_sdk_fails_the_format_check_only(self):
        world = FakeWorld(self)
        with mock.patch.object(pf, 'dart_executable', side_effect=pf.PreflightError('tool/flutter --version failed')):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = pf.main(['--out', str(world.root / 'r.json')])
        statuses = {c['name']: c['status'] for c in json.loads((world.root / 'r.json').read_text())['checks']}
        self.assertEqual(code, 1)
        self.assertEqual((statuses['format'], statuses['analyze']), ('fail', 'pass'))

    def test_summary_line_and_table(self):
        results = [pf.Result('a', 'pass', 1.25, 'fine'), pf.Result('b', 'fail', 2.0, 'bad'), pf.Result('c', 'skip', 0, 'nothing')]
        table = pf.format_table(results)
        self.assertEqual(len(table), 4)
        self.assertIn('FAIL', table[2])
        self.assertIn('SKIP', table[3])
        line = pf.summary_line(results, 61.4, 'abcdef0123456789', 'origin/cindy/integration@1234abcd', 0)
        self.assertEqual(line, 'preflight: FAILED (b) 1/2 checks, 61s, tree abcdef012345, base origin/cindy/integration@1234abcd')


if __name__ == '__main__':
    unittest.main()


class FormatDebtTests(unittest.TestCase):
    """A file that was already unformatted at the merge-base is format debt, not a regression."""

    def run_with(self, clean_now, clean_before, new=()):
        changes = pf.Changes('base', sorted(clean_now), set(new))
        texts = {}

        def fake_clean(dart, path, text):
            return clean_before[path] if text == f'before:{path}' else clean_now[path]

        def fake_git(*args):
            path = args[1].split(':', 1)[1]
            return f'before:{path}'

        original_clean, original_git = pf.dart_format_clean, pf.git
        original_read = pathlib.Path.read_text
        pf.dart_format_clean, pf.git = fake_clean, fake_git
        pathlib.Path.read_text = lambda self, **kw: texts.setdefault(str(self), f'now:{self.name}')
        try:
            return pf.format_regressions('dart', changes, sorted(clean_now))
        finally:
            pf.dart_format_clean, pf.git = original_clean, original_git
            pathlib.Path.read_text = original_read

    def test_untouched_formatting_passes(self):
        self.assertEqual(self.run_with({'a.dart': True}, {'a.dart': True}), ([], []))

    def test_breaking_a_formatted_file_fails(self):
        self.assertEqual(self.run_with({'a.dart': False}, {'a.dart': True}), (['a.dart'], []))

    def test_inherited_debt_is_reported_not_failed(self):
        self.assertEqual(self.run_with({'a.dart': False}, {'a.dart': False}), ([], ['a.dart']))

    def test_a_new_unformatted_file_fails(self):
        self.assertEqual(self.run_with({'n.dart': False}, {'n.dart': False}, new={'n.dart'}), (['n.dart'], []))
