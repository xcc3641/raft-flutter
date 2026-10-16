import 'package:flutter/widgets.dart';
import 'package:raft_ui/previews.dart';

import 'message_history_gaps.dart';

@RaftPreviews('Saved history gap', size: Size(360, 250))
Widget savedHistoryGapPreview() =>
    Center(child: HistoryGapNotice(onLoad: () {}));
@RaftPreviews('Saved history gap loading', size: Size(360, 250))
Widget savedHistoryGapLoadingPreview() =>
    const Center(child: HistoryGapNotice(busy: true));
@RaftPreviews('Saved history gap retry', size: Size(360, 250))
Widget savedHistoryGapRetryPreview() =>
    Center(child: HistoryGapNotice(failed: true, onLoad: () {}));
