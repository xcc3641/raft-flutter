import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'shared_draft_attachment.dart';

typedef ComposerRecordRead = Future<dynamic> Function(
  String kind,
  String scope,
);
typedef ComposerRecordWrite = Future<void> Function(
  String kind,
  String scope,
  dynamic value, {
  required bool requiredSuccess,
});
typedef ComposerStoredFile = ({
  SharedDraftAttachment local,
  String? id,
  Map<String, dynamic>? metadata,
});

class ComposerSendAttempt {
  ComposerSendAttempt(this.fingerprint, this.randomId);
  final String fingerprint, randomId;

  // Shared editors may retry a settled attempt, but must reserve a fresh id
  // while another editor is sending it. This process-local flag is not saved.
  bool inFlight = false;
}

/// One draft/attempt record owner for a session, borrowed by its editors.
/// Each conversation has its own signal; typing never notifies other scopes.
class WorkspaceComposer {
  WorkspaceComposer({
    required this._owner,
    required this._read,
    required this._write,
  });

  final Object _owner;
  final ComposerRecordRead _read;
  final ComposerRecordWrite _write;
  final _text = <String, String>{};
  final _signals = <String?, ValueNotifier<int>>{};
  final attempts = <String, ComposerSendAttempt>{};
  final shareTokens = <String, Set<String>>{};
  final revisions = <String, int>{};
  late final Map<String, String> drafts = _DraftMap(this);
  Future<void> _pending = Future<void>.value();
  int _epoch = 0;
  bool _closed = false;

  bool ownedBy(Object owner) => identical(owner, _owner);
  Future<void> get flushed => _pending;

  ValueListenable<int> changes(String? scope) =>
      _signals.putIfAbsent(scope, () => ValueNotifier<int>(0));

  void _changed(String scope) {
    final signal = _signals[scope];
    if (signal != null && !_closed) signal.value++;
  }

  Future<void> _save(
    String kind,
    String scope,
    dynamic value, {
    bool requiredSuccess = false,
  }) {
    if (_closed) return Future<void>.value();
    // The supplied writer retains the session's existing write/purge queue.
    final writing = _write(
      kind,
      scope,
      value,
      requiredSuccess: requiredSuccess,
    );
    _pending = Future.wait([_pending, writing])
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return writing;
  }

  Future<void> saveDraft(
    String scope, {
    required Iterable<String> pendingText,
    required String queuedText,
    required List<ComposerStoredFile> files,
    bool requiredSuccess = false,
  }) => _save(
    'draft',
    scope,
    draftRecord(
      scope,
      pendingText: pendingText,
      queuedText: queuedText,
      files: files,
    ),
    requiredSuccess: requiredSuccess,
  );

  /// Encodes the existing disk format. Omitting files and share tokens gives
  /// revocation a snapshot containing only the user's unsent text.
  Map<String, dynamic>? draftRecord(
    String scope, {
    Iterable<String> pendingText = const [],
    String queuedText = '',
    List<ComposerStoredFile> files = const [],
    bool includeShareTokens = true,
  }) {
    final text = [
      if (files.isNotEmpty) ...pendingText,
      queuedText,
      drafts[scope] ?? '',
    ].where((s) => s.isNotEmpty).toSet().join('\n\n');
    return text.isEmpty && files.isEmpty
        ? null
        : {
            'text': text,
            'channelId': scope,
            'shareTokens': includeShareTokens
                ? shareTokens[scope]?.toList()
                : null,
            'files': [
              for (final file in files)
                {
                  'ref': file.local.reference,
                  'id': file.id,
                  'metadata': {
                    for (final key in [
                      'id',
                      'filename',
                      'mimeType',
                      'sizeBytes',
                    ])
                      if (file.metadata?.containsKey(key) == true)
                        key: file.metadata![key],
                  },
                },
            ],
          };
  }

  Future<void> saveAttempt(
    String scope,
    ComposerSendAttempt? attempt, {
    String? channelId,
  }) => _save(
    'attempt',
    scope,
    attempt == null
        ? null
        : {
            'fingerprint': attempt.fingerprint,
            'randomId': attempt.randomId,
            'channelId': channelId,
          },
  );

  Future<void> removeStoredDraft(String scope) => _save('draft', scope, null);

  Future<void> restore(
    String scope, {
    required bool Function() current,
    required Future<void> Function(List<Map> files) restoreFiles,
    required VoidCallback restored,
  }) async {
    final epoch = _epoch;
    bool accepted() => !_closed && epoch == _epoch && current();
    final value = await _read('draft', scope);
    if (!accepted() || drafts.containsKey(scope)) return;
    if (value is Map && value['text'] is String) {
      drafts[scope] = value['text'];
      if (value['shareTokens'] is List) {
        shareTokens[scope] = (value['shareTokens'] as List)
            .whereType<String>()
            .take(64)
            .toSet();
      }
      if (value['files'] is List) {
        await restoreFiles((value['files'] as List).whereType<Map>().toList());
      }
      if (!accepted()) return;
      restored();
    }
    final attempt = await _read('attempt', scope);
    if (accepted() && attempt is Map && !attempts.containsKey(scope)) {
      attempts[scope] = ComposerSendAttempt(
        attempt['fingerprint'],
        attempt['randomId'],
      );
    }
  }

  /// The existing thread-route path restores text only, without changing its
  /// attachment/attempt admission policy during this persistence extraction.
  Future<bool> restoreText(String scope, bool Function() current) async {
    final epoch = _epoch;
    final value = await _read('draft', scope);
    if (_closed || epoch != _epoch || !current() || drafts.containsKey(scope)) {
      return false;
    }
    if (value is! Map || value['text'] is! String) return false;
    drafts[scope] = value['text'];
    return true;
  }

  void clearOwnedBy(Object owner) {
    if (!ownedBy(owner) || _closed) return;
    _epoch++;
    drafts.clear();
    attempts.clear();
    revisions.clear();
    shareTokens.clear();
  }

  void disposeOwnedBy(Object owner) {
    if (!ownedBy(owner) || _closed) return;
    _closed = true;
    _epoch++;
    _text.clear();
    attempts.clear();
    revisions.clear();
    shareTokens.clear();
    for (final signal in _signals.values) {
      signal.dispose();
    }
    _signals.clear();
  }
}

class _DraftMap extends MapBase<String, String> {
  _DraftMap(this.owner);
  final WorkspaceComposer owner;
  @override
  String? operator [](Object? key) => owner._text[key];
  @override
  Iterable<String> get keys => owner._text.keys;
  @override
  void operator []=(String key, String value) {
    if (owner._closed || owner._text[key] == value) return;
    owner._text[key] = value;
    owner._changed(key);
  }

  @override
  String? remove(Object? key) {
    final previous = owner._text.remove(key);
    if (previous != null && key is String) owner._changed(key);
    return previous;
  }

  @override
  void clear() {
    for (final key in keys.toList()) {
      remove(key);
    }
  }
}
