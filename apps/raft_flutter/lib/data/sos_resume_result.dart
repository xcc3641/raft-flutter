/// The mounted resume-all-agents response, including older ok-only servers.
class SosResumeResult {
  SosResumeResult._(this.succeeded, this.failures, this.retryAgentIds);

  final bool succeeded;
  final List<({String agentId, String? reason, String? error})> failures;

  /// A complete per-agent response can safely retry just the missed agents.
  /// An unknown response cannot establish which agents received the guidance.
  final List<String>? retryAgentIds;

  factory SosResumeResult.parse(Object? value) {
    if (value is! Map) return SosResumeResult._(false, [], null);
    final rows = value['results'];
    if (!value.containsKey('results')) {
      final countsMatch =
          value['total'] == null || value['started'] == value['total'];
      return SosResumeResult._(value['ok'] == true && countsMatch, [], null);
    }
    if (rows is! List) return SosResumeResult._(false, [], null);
    final failures = <({String agentId, String? reason, String? error})>[];
    final ids = <String>{};
    var complete = true;
    for (final row in rows) {
      if (row is! Map ||
          row['agentId'] is! String ||
          (row['agentId'] as String).isEmpty ||
          row['ok'] is! bool) {
        complete = false;
        continue;
      }
      final id = row['agentId'] as String;
      if (!ids.add(id)) complete = false;
      if (row['ok'] != true) {
        failures.add((
          agentId: id,
          reason: row['reason'] is String ? row['reason'] as String : null,
          error: row['error'] is String ? row['error'] as String : null,
        ));
      }
    }
    if (value['total'] != null && value['total'] != rows.length) {
      complete = false;
    }
    if (value['started'] != null &&
        value['started'] != ids.length - failures.length) {
      complete = false;
    }
    return SosResumeResult._(
      value['ok'] == true && complete && failures.isEmpty,
      failures,
      complete && failures.isNotEmpty
          ? failures.map((f) => f.agentId).toList()
          : null,
    );
  }
}
