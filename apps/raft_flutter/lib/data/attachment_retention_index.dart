import 'package:flutter/foundation.dart';
import 'package:raft_client/raft_client.dart';

import 'attachment_image_repository.dart';

/// Receiver-local history metadata for retaining images after their leases end.
/// Reads current admission and ledger facts without subscribing or owning media.
class AttachmentRetentionIndex {
  AttachmentRetentionIndex({
    required this._ledgerRevision,
    required this._stateStamp,
    required this._scope,
    required this._channels,
    required this._dms,
    required this._revokedChannels,
    required this._canView,
    required this._messages,
  });

  final int Function() _ledgerRevision, _stateStamp;
  final AttachmentImageScope Function() _scope;
  final List<RaftChannel> Function() _channels, _dms;
  final Set<String> Function() _revokedChannels;
  final bool Function(RaftChannel) _canView;
  final List<Map<String, dynamic>> Function(String) _messages;

  Object? _retainedIndexStamp;
  Map<String, Map<String, List<Map<String, dynamic>>>> _retainedIndex = {};
  Object? _retainedAdmissionStamp;
  List<String> _retainedChannelIds = const [];
  int _retainedIndexBuilds = 0;

  /// Number of complete history scans, excluding admission-only checks.
  int get debugBuilds => _retainedIndexBuilds;

  bool retains(AttachmentImageKey key) {
    final candidates =
        _retainedAttachmentIndex()[key.channelId]?[key.attachmentId] ??
        const <Map<String, dynamic>>[];
    for (final metadata in candidates) {
      final canonical = AttachmentImageKey.fromMetadata(
        scope: key.scope,
        channelId: key.channelId,
        metadata: metadata,
        rendition: key.rendition,
        target: key.target,
      );
      if (canonical == key) return true;
    }
    return false;
  }

  List<String> _admittedAttachmentChannels() {
    // Keep every former index invalidation boundary. In particular a normal
    // notification still reevaluates can() and revocations before reusing any
    // metadata, even when the channel list has the same identity and length.
    final stamp = (
      _ledgerRevision(),
      _stateStamp(),
      _scope(),
      identityHashCode(_channels()),
      _channels().length,
      identityHashCode(_dms()),
      _dms().length,
      _revokedChannels().length,
    );
    if (stamp == _retainedAdmissionStamp) return _retainedChannelIds;
    final admitted = [
      for (final channel in [..._channels(), ..._dms()])
        if (!_revokedChannels().contains(channel.id) && _canView(channel))
          channel.id,
    ];
    if (!listEquals(admitted, _retainedChannelIds)) {
      _retainedChannelIds = List.unmodifiable(admitted);
    }
    _retainedAdmissionStamp = stamp;
    return _retainedChannelIds;
  }

  Map<String, Map<String, List<Map<String, dynamic>>>>
  _retainedAttachmentIndex() {
    final admitted = _admittedAttachmentChannels();
    final stamp = (_ledgerRevision(), _scope(), admitted);
    if (stamp == _retainedIndexStamp) return _retainedIndex;
    ++_retainedIndexBuilds;
    final index = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final id in admitted) {
      final channelIds = <String>{id};
      for (final message in _messages(id)) {
        final thread = RaftMessage(message).threadId;
        if (thread != null) channelIds.add(thread);
      }
      for (final channelId in channelIds) {
        if (index.containsKey(channelId)) continue;
        final byAttachment = index[channelId] = {};
        for (final message in _messages(channelId)) {
          for (final metadata in RaftMessage(message).attachments) {
            final id = metadata['id'];
            if (id is String) (byAttachment[id] ??= []).add(metadata);
          }
        }
      }
    }
    _retainedIndexStamp = stamp;
    return _retainedIndex = index;
  }
}
