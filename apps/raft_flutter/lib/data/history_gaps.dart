import 'package:flutter/foundation.dart';

import 'message_history.dart';

/// The unverified interval ends immediately before this newer saved row.
class HistoryGap {
  const HistoryGap(this.newerId, this.before);
  final String newerId;
  final BigInt before;
}

abstract class HistoryGapQueries extends ChangeNotifier {
  Object revision(MessageHistoryScope scope);
  Future<List<HistoryGap>> read(
    MessageHistoryScope scope,
    List<(String, BigInt)> visible,
  );
}
