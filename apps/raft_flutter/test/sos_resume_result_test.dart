import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/sos_resume_result.dart';

void main() {
  test('old ok-only servers and empty channels still complete', () {
    for (final response in [
      {'ok': true},
      {'ok': true, 'started': 0, 'total': 0, 'results': []},
    ]) {
      expect(SosResumeResult.parse(response).succeeded, true);
    }
  });

  test(
    'each unsuccessful agent retains the server reason and retry identity',
    () {
      final result = SosResumeResult.parse({
        'ok': false,
        'started': 1,
        'total': 3,
        'results': [
          {'agentId': 'ready', 'ok': true},
          {'agentId': 'starting', 'ok': false, 'reason': 'start_in_flight'},
          {'agentId': 'offline', 'ok': false, 'error': 'Computer offline'},
        ],
      });
      expect(result.succeeded, false);
      expect(result.retryAgentIds, ['starting', 'offline']);
      expect(result.failures.map((f) => f.reason), ['start_in_flight', null]);
      expect(result.failures.last.error, 'Computer offline');
    },
  );

  test('malformed or inconsistent responses never acknowledge all agents', () {
    for (final response in <Object?>[
      null,
      {},
      {'ok': false},
      {'ok': true, 'results': null},
      {'ok': true, 'started': 1, 'total': 2},
      {'ok': true, 'results': 'invalid'},
      {'ok': true, 'total': 1, 'results': []},
      {
        'ok': true,
        'started': 0,
        'results': [
          {'agentId': 'a', 'ok': true},
        ],
      },
      {
        'ok': true,
        'results': [
          {'agentId': 'a', 'ok': false},
        ],
      },
      {
        'ok': true,
        'results': [
          {'agentId': 'a', 'ok': 'true'},
        ],
      },
      {
        'ok': true,
        'results': [null],
      },
      {
        'ok': true,
        'results': [
          {'agentId': 'a', 'ok': true},
          {'agentId': 'a', 'ok': true},
        ],
      },
    ]) {
      expect(
        SosResumeResult.parse(response).succeeded,
        false,
        reason: '$response',
      );
    }
  });

  test(
    'an incomplete response cannot authorize retrying successful agents',
    () {
      final result = SosResumeResult.parse({
        'ok': false,
        'total': 3,
        'results': [
          {'agentId': 'a', 'ok': true},
          {'agentId': 'b', 'ok': false},
        ],
      });
      expect(result.retryAgentIds, isNull);
      expect(result.failures.single.agentId, 'b');
    },
  );
}
