import importlib.machinery
import importlib.util
import json
import contextlib
import io
from pathlib import Path
import tempfile
import threading
import unittest
import unittest.mock

PATH = Path(__file__).resolve().parents[1] / 'check-project'
LOADER = importlib.machinery.SourceFileLoader('check_project', str(PATH))
SPEC = importlib.util.spec_from_loader('check_project', LOADER)
check = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(check)


def events(*items):
    return [json.dumps(item) for item in items]


SUITE = {'type': 'suite', 'suite': {'id': 1, 'platform': 'vm', 'path': '/repo/apps/raft_flutter/test/a_test.dart'}, 'time': 0}


def started(test_id, name, time, suite=1):
    return {'type': 'testStart', 'test': {'id': test_id, 'name': name, 'suiteID': suite}, 'time': time}


def done(test_id, time, result='success', skipped=False, hidden=False):
    return {'type': 'testDone', 'testID': test_id, 'result': result, 'skipped': skipped, 'hidden': hidden, 'time': time}


class PartitionTests(unittest.TestCase):
    def test_balances_by_weight_and_keeps_every_file_once(self):
        weights = {'a': 100, 'b': 60, 'c': 50, 'd': 40, 'e': 10}
        plan = check.partition(list(weights), weights, 2)
        self.assertEqual(sorted(sum((p['files'] for p in plan), [])), sorted(weights))
        self.assertLessEqual(max(p['weight'] for p in plan), 140)  # optimum 130

    def test_is_deterministic(self):
        weights = {f'f{i}': 1 + i % 7 for i in range(40)}
        self.assertEqual(check.partition(list(weights), weights, 4), check.partition(list(reversed(list(weights))), weights, 4))

    def test_unknown_files_get_a_share_by_size_not_zero(self):
        weights = {'known': 10}
        plan = check.partition(['known', 'new_big', 'new_small'], weights, 2, {'known': 100, 'new_big': 1000, 'new_small': 10})
        bins = {tuple(p['files']): p['weight'] for p in plan}
        self.assertIn(('new_big',), bins)
        self.assertEqual(bins[('new_big',)], 100.0)

    def test_without_history_everything_is_equal(self):
        plan = check.partition([f'f{i}' for i in range(10)], {}, 5)
        self.assertEqual([len(p['files']) for p in plan], [2] * 5)

    def test_never_more_shards_than_files(self):
        self.assertEqual(len(check.partition(['a', 'b'], {}, 8)), 2)
        self.assertEqual(check.partition([], {}, 4), [{'files': [], 'weight': 0.0}])


class StructurePreflightTests(unittest.TestCase):
    def test_growth_stops_before_assets_or_tests_and_records_a_failed_run(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            with unittest.mock.patch.object(check, 'local', folder), \
                    unittest.mock.patch.object(check.subprocess, 'check_output', return_value='hash\n'), \
                    unittest.mock.patch.object(check, 'discover_tests', return_value=[]), \
                    unittest.mock.patch.object(check, 'history_weights', return_value={}), \
                    unittest.mock.patch.object(check, 'run_logged', side_effect=[0, 1]) as run, \
                    unittest.mock.patch.object(check, 'clear_unit_test_assets') as assets, \
                    contextlib.redirect_stderr(io.StringIO()):
                result = check.run_gate({}, unittest.mock.Mock(), 0)
            self.assertFalse(result['ok'])
            self.assertEqual(result['failed_checks'], ['structure-audit.txt'])
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args.args[0][-1], '--check')
            self.assertTrue(any(str(arg).endswith('structure-audit') for arg in run.call_args.args[0]))
            assets.assert_not_called()
            receipt = json.loads((folder / 'engineering-run.json').read_text())
            self.assertFalse(receipt['completed'])
            self.assertEqual(receipt['shards'], [])


class ParallelismTests(unittest.TestCase):
    def test_default_scales_with_cpus_and_load(self):
        self.assertEqual(check.plan_parallelism(16, 0.0, {}, 'linux'), (5, 3))
        self.assertEqual(check.plan_parallelism(16, 0.0, {}, 'darwin'), (1, 8))
        self.assertEqual(check.plan_parallelism(16, 0.0, {'RAFT_CHECK_SHARDS': '2'}, 'darwin'), (2, 4))
        self.assertEqual(check.plan_parallelism(16, 10.0, {}, 'linux'), (2, 3))
        self.assertEqual(check.plan_parallelism(2, 8.0, {}, 'linux'), (1, 2))
        self.assertLessEqual(check.plan_parallelism(128, 0.0, {}, 'linux')[0], 8)

    def test_environment_overrides(self):
        self.assertEqual(check.plan_parallelism(16, 0.0, {'RAFT_CHECK_SHARDS': '3', 'RAFT_CHECK_JOBS': '1'}, 'linux'), (3, 1))

    def test_rejects_invalid_override(self):
        for bad in ('0', 'x', '-1'):
            with self.assertRaises(SystemExit):
                check.plan_parallelism(16, 0.0, {'RAFT_CHECK_SHARDS': bad}, 'linux')


class EventTests(unittest.TestCase):
    def parse(self, *items):
        return check.parse_test_events(events(*items), lambda p: p.replace('/repo/', ''))

    def test_passed_failed_skipped_and_durations(self):
        results = self.parse(
            SUITE,
            started(1, 'loading /repo/apps/raft_flutter/test/a_test.dart', 0), done(1, 4000, hidden=True),
            started(2, 'ok', 4000), done(2, 4500),
            started(3, 'bad', 4500), {'type': 'error', 'testID': 3, 'error': 'Expected: 1\n  Actual: 2', 'stackTrace': '', 'isFailure': True, 'time': 5000},
            done(3, 6500, result='failure'),
            started(4, 'skip me', 6500), done(4, 6500, skipped=True))
        summary = check.summarize_shard(results)
        self.assertEqual((summary['passed'], summary['skipped']), (1, 1))
        self.assertEqual([f['name'] for f in summary['failed']], ['bad'])
        self.assertEqual(summary['failed'][0]['error'], 'Expected: 1')
        self.assertEqual(summary['failed'][0]['file'], 'apps/raft_flutter/test/a_test.dart')
        files = check.file_durations(results, shard=2)
        self.assertEqual(files['apps/raft_flutter/test/a_test.dart'], {'seconds': 6.5, 'loadSeconds': 4.0, 'tests': 3, 'shard': 2})

    def test_load_failure_and_timeout_are_failures(self):
        results = self.parse(SUITE, started(1, 'loading /repo/x', 0), {'type': 'error', 'testID': 1, 'error': 'Compilation failed', 'stackTrace': '', 'isFailure': False, 'time': 10},
                             done(1, 20, result='error', hidden=True),
                             started(2, 'hangs', 30), {'type': 'error', 'testID': 2, 'error': 'TimeoutException after 0:01:00: Test timed out after 60 seconds.', 'stackTrace': '', 'isFailure': False, 'time': 60030},
                             done(2, 60030, result='error'))
        failed = check.summarize_shard(results)['failed']
        self.assertEqual([f['name'] for f in failed], ['loading /repo/x', 'hangs'])
        self.assertIn('timed out after 60 seconds', failed[1]['error'])

    def test_truncated_stream_reports_incomplete_test(self):
        lines = events(SUITE, started(1, 'killed mid-test', 100)) + ['{"type":"testDo']
        results = check.parse_test_events(lines)
        self.assertEqual([r['status'] for r in results], ['incomplete'])
        self.assertEqual(len(check.summarize_shard(results)['failed']), 1)

    def test_slowest_tests_are_sorted_capped_and_exclude_loading(self):
        items = [SUITE, started(1, 'loading /repo/x', 0), done(1, 99000, hidden=True)]
        for i in range(2, 32):
            items += [started(i, f't{i}', 0), done(i, i * 100)]
        slow = check.slowest_tests(self.parse(*items))
        self.assertEqual(len(slow), 20)
        self.assertEqual(slow[0]['name'], 't31')
        self.assertEqual([s['seconds'] for s in slow], sorted((s['seconds'] for s in slow), reverse=True))
        self.assertFalse(any(s['name'].startswith('loading') for s in slow))


class PassGateTests(unittest.TestCase):
    def test_marker_is_required(self):
        self.assertTrue(check.has_pass_marker('00:01 +3: foo\n00:02 +4 ~1: All tests passed!\n'))
        self.assertFalse(check.has_pass_marker('00:01 +652: slow test\n'))
        self.assertFalse(check.has_pass_marker('00:01 +4 -1: Some tests failed.\n'))
        self.assertFalse(check.has_pass_marker(''))

    def test_marker_must_be_at_the_end_not_in_test_output(self):
        log = 'All tests passed!\n' + '\n'.join(f'00:0{i} +{i}: next' for i in range(9))
        self.assertFalse(check.has_pass_marker(log))

    def test_files_that_never_ran_are_found(self):
        results = [{'file': 'apps/raft_flutter/test/a_test.dart'}, {'file': ''}]
        self.assertEqual(check.unfinished_files(['apps/raft_flutter/test/a_test.dart', 'apps/raft_flutter/test/b_test.dart'], results),
                         ['apps/raft_flutter/test/b_test.dart'])

    def test_repo_path_maps_app_relative_package_paths(self):
        self.assertEqual(check.repo_path('test/a_test.dart'), 'apps/raft_flutter/test/a_test.dart')
        self.assertEqual(check.repo_path('../../packages/raft_ui/test/c_test.dart'), 'packages/raft_ui/test/c_test.dart')


class SummaryTests(unittest.TestCase):
    def test_lists_failed_test_names_and_slowest(self):
        shards = [{'index': 0, 'passed': False, 'seconds': 61.2, 'files': ['a'], 'log': 'test-shard-0.txt'}]
        failures = [{'name': 'group hangs', 'file': 'apps/raft_flutter/test/a_test.dart', 'status': 'failed', 'error': 'Test timed out after 60 seconds.', 'shard': 0},
                    {'name': 'cut off', 'file': 'apps/raft_flutter/test/b_test.dart', 'status': 'incomplete', 'error': '', 'shard': 0}]
        text = check.format_summary(shards, failures, {'passed': 9, 'skipped': 1}, [{'name': 'slow one', 'file': 'f', 'seconds': 12.3}])
        self.assertIn('9 passed, 1 skipped, 2 failed across 1 shard(s)', text)
        self.assertIn('[0] apps/raft_flutter/test/a_test.dart: group hangs -- Test timed out after 60 seconds.', text)
        self.assertIn('cut off -- did not finish', text)
        self.assertIn('12.3s  f: slow one', text)

    def test_limit_truncates_the_listing_not_the_count(self):
        failures = [{'name': f't{i}', 'file': 'f', 'status': 'failed', 'error': 'e', 'shard': 0} for i in range(5)]
        text = check.format_summary([], failures, {'passed': 0, 'skipped': 0}, [], limit=2)
        self.assertIn('5 failed', text)
        self.assertIn('f: t1', text)
        self.assertNotIn('f: t2', text)
        self.assertIn('and 3 more', text)

    def test_history_weights_read_previous_run(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / '.local').mkdir()
            (repo / '.local/check-durations.json').write_text(json.dumps({'files': {'a': {'seconds': 3.5}, 'b': {'seconds': 0}}}))
            self.assertEqual(check.history_weights(repo), {'a': 3.5})
            self.assertEqual(check.history_weights(repo / 'missing'), {})


class DiscoveryTests(unittest.TestCase):
    def test_finds_app_and_package_tests_relative_to_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ['apps/raft_flutter/test/a_test.dart', 'apps/raft_flutter/test/parity/b_test.dart', 'apps/raft_flutter/test/helper.dart', 'packages/raft_ui/test/c_test.dart']:
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_text('')
            self.assertEqual(check.discover_tests(base), ['test/a_test.dart', 'test/parity/b_test.dart', '../../packages/raft_ui/test/c_test.dart'])


if __name__ == '__main__':
    unittest.main()


class UnitTestAssetsTests(unittest.TestCase):
    def test_clears_cached_test_assets_and_keeps_other_build_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'apps/raft_flutter/build/unit_test_assets/shaders'
            pkg = root / 'packages/raft_ui/build/unit_test_assets'
            apk = root / 'apps/raft_flutter/build/app/outputs'
            for d in (app, pkg, apk):
                d.mkdir(parents=True)
            (app / 'ink_sparkle.frag').write_text('vulkan only')
            removed = check.clear_unit_test_assets(root)
            self.assertEqual(len(removed), 2)
            self.assertFalse(app.parent.exists())
            self.assertFalse(pkg.exists())
            self.assertTrue(apk.is_dir())
            self.assertEqual(check.clear_unit_test_assets(root), [])


class RunTmpTests(unittest.TestCase):
    def test_creates_a_per_run_directory_and_removes_those_of_dead_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            local = Path(tmp) / '.local'
            local.mkdir()
            dead = local / 'tmp-4000000'  # no such pid
            dead.mkdir()
            (dead / 'flutter_tools.x').mkdir()
            alive = local / 'tmp-1'  # pid 1 exists
            alive.mkdir()
            (local / 'tmp-notanumber').mkdir()
            run = check.make_run_tmp(local, pid=777)
            self.assertEqual(run, local / 'tmp-777')
            self.assertTrue(run.is_dir())
            self.assertFalse(dead.exists())
            self.assertTrue(alive.exists())
            self.assertTrue((local / 'tmp-notanumber').exists())

    def test_children_get_the_directory_as_their_temp_dir(self):
        env = check.with_run_tmp({'PATH': '/bin', 'TMPDIR': '/tmp'}, Path('/w/.local/tmp-1'))
        self.assertEqual((env['TMPDIR'], env['TEMP'], env['TMP']), ('/w/.local/tmp-1',) * 3)
        self.assertEqual(env['PATH'], '/bin')

    def test_root_is_outside_the_checkout(self):
        # A throwaway git repository built in TMPDIR must not find the enclosing checkout.
        repo = Path(__file__).resolve().parents[2]
        with unittest.mock.patch.dict('os.environ', {'XDG_CACHE_HOME': '/c'}):
            self.assertEqual(check.run_tmp_root(), Path('/c/raft-flutter/gate-tmp'))
        root = check.run_tmp_root().resolve()
        self.assertFalse(root == repo or repo in root.parents)


class WarmupTests(unittest.TestCase):
    def test_picks_the_smallest_app_test(self):
        sizes = {'test/b_test.dart': 900, 'test/a_test.dart': 120, '../../packages/raft_ui/test/x_test.dart': 10}
        files = list(sizes) + ['test/missing_test.dart']
        self.assertEqual(check.smallest_app_test(files, sizes), 'test/a_test.dart')
        self.assertIsNone(check.smallest_app_test(['../../packages/x/test/y_test.dart'], {}))


class FakeChild:
    def __init__(self, exits_at=None, clock=None):
        self.exits_at, self.clock = exits_at, clock

    def poll(self):
        return 1 if self.exits_at is not None and self.clock.now >= self.exits_at else None


class FakeClock:
    """Time that only moves when the code under test sleeps."""

    def __init__(self, on_sleep=lambda now: None):
        self.now, self.on_sleep = 0.0, on_sleep

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        self.on_sleep(self.now)


class StartupGateTests(unittest.TestCase):
    def make_gate(self, tmp, timeout=30, on_sleep=lambda now: None):
        clock = FakeClock(on_sleep)
        return check.StartupGate(timeout=timeout, poll=1, clock=clock, sleep=clock.sleep), clock, Path(tmp) / 'events.json'

    def test_slot_is_released_once_the_event_file_has_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = Path(tmp) / 'events.json'
            gate, clock, _ = self.make_gate(tmp, on_sleep=lambda now: events.write_text('{"type":"start"}') if now >= 4 else None)
            self.assertEqual(gate.wait_started(FakeChild(), events), 'started')
            self.assertEqual(clock.now, 4)

    def test_an_empty_event_file_does_not_count_as_started(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = Path(tmp) / 'events.json'
            events.touch()
            gate, clock, _ = self.make_gate(tmp, timeout=5)
            self.assertEqual(gate.wait_started(FakeChild(), events), 'timeout')
            self.assertEqual(clock.now, 5)

    def test_a_shard_that_exits_during_startup_gives_the_slot_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            gate, clock, events = self.make_gate(tmp)
            self.assertEqual(gate.wait_started(FakeChild(exits_at=2, clock=clock), events), 'exited')
            self.assertEqual(clock.now, 2)

    def test_stop_request_ends_the_wait(self):
        with tempfile.TemporaryDirectory() as tmp:
            gate, clock, events = self.make_gate(tmp)
            self.assertEqual(gate.wait_started(FakeChild(), events, stopping=lambda: clock.now >= 3), 'stopped')

    def test_second_shard_waits_for_the_first_to_finish_starting(self):
        gate = check.StartupGate()
        order, first_in, second_tried = [], threading.Event(), threading.Event()

        def second():
            first_in.wait()
            second_tried.set()
            gate.enter()
            order.append('second in')
            gate.leave()

        thread = threading.Thread(target=second)
        thread.start()
        gate.enter()
        first_in.set()
        second_tried.wait()
        thread.join(0.2)  # the second shard stays blocked while the first holds the slot
        self.assertTrue(thread.is_alive())
        self.assertEqual(order, [])
        gate.leave()
        thread.join(5)
        self.assertEqual(order, ['second in'])

    def test_leave_is_idempotent_and_only_for_the_holder(self):
        gate = check.StartupGate()
        gate.leave()  # not held: no error
        gate.enter()
        gate.leave()
        gate.leave()
        gate.enter()  # the slot is free again
        gate.leave()

    def test_run_shard_holds_the_slot_until_startup_ends_but_not_while_tests_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            gate = check.StartupGate(timeout=5, poll=0.01)
            seen = {}

            def fake_run_logged(args, cwd, log, env, timeout, outcome, after_start):
                events = Path(args[args.index('--file-reporter') + 1].removeprefix('json:'))
                threading.Timer(0.1, lambda: events.write_text('{}')).start()
                after_start(FakeChild())
                seen['free_after_start'] = gate._slot.acquire(blocking=False)
                if seen['free_after_start']:
                    gate._slot.release()
                return 0

            with unittest.mock.patch.object(check, 'local', Path(tmp)), unittest.mock.patch.object(check, 'run_logged', fake_run_logged):
                shard = check.run_shard(3, ['test/a_test.dart'], 2, {}, 60, gate)
            self.assertTrue(seen['free_after_start'])
            self.assertEqual(shard['startup'][0], 'started')
            self.assertEqual(shard['code'], 0)

    def test_a_queued_shard_does_not_show_the_last_runs_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            stale = Path(tmp) / 'test-shard-1.txt'
            stale.write_text('00:01 +0 -1: test/old_test.dart: from the last run [E]\n')
            (Path(tmp) / 'test-shard-1.json').write_text('{}')
            with unittest.mock.patch.object(check, 'local', Path(tmp)):
                logs, events = check.fresh_shard_outputs(2)
            self.assertEqual([p.name for p in logs], ['test-shard-0.txt', 'test-shard-1.txt'])
            self.assertEqual(check.LogTail(logs[1]).read(), '')  # still waiting for its startup turn
            self.assertFalse(events[1].exists())

    def test_run_shard_gives_the_slot_back_when_the_child_cannot_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            gate = check.StartupGate()

            def failing(*args, **kwargs):
                raise OSError('no flutter')

            with unittest.mock.patch.object(check, 'local', Path(tmp)), unittest.mock.patch.object(check, 'run_logged', failing):
                with self.assertRaises(OSError):
                    check.run_shard(0, [], 2, {}, 60, gate)
            gate.enter()  # not deadlocked
            gate.leave()
