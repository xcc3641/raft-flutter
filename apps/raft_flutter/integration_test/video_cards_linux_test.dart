// The real Linux build: a desktop video card without a thumbnail or a size
// shows the video's own first frame (read through libmpv by MpvVideoFrameProbe
// from a few ranged bytes) and the inline player still plays.
//
//   xvfb-run -a tool/flutter test integration_test/video_cards_linux_test.dart -d linux
//
// Makes its media with ffmpeg and serves it from a local byte-counting server.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/attachment_image_repository.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/inline_attachment_media.dart';
import 'package:raft_flutter/platform/video_frame_probe.dart';
import 'package:raft_flutter/platform/video_frame_probe_mpv.dart';
import 'package:raft_ui/raft_ui.dart';

/// The real probe, with its calls printed.
class _LoggingProbe implements VideoFrameProbe {
  final inner = MpvVideoFrameProbe();
  @override
  Future<VideoFrameInfo> probe({
    required String id,
    required Uri url,
    Map<String, String> headers = const {},
    int maxEdge = 640,
    Duration timeout = const Duration(seconds: 20),
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    // ignore: avoid_print
    print('VIDEO-CARDS-LINUX probe ${url.path} maxEdge=$maxEdge');
    try {
      final info = await inner.probe(id: id, url: url, headers: headers, maxEdge: maxEdge, timeout: timeout, maxBytes: maxBytes);
      // ignore: avoid_print
      print('VIDEO-CARDS-LINUX probe ${url.path} -> ${info.width}x${info.height} jpeg=${info.jpeg?.length}');
      return info;
    } on Object catch (error) {
      // ignore: avoid_print
      print('VIDEO-CARDS-LINUX probe ${url.path} failed $error');
      rethrow;
    }
  }

  @override
  Future<void> cancel(String id) => inner.cancel(id);
}

class _Client extends RaftClient {
  _Client(this.base)
    : super(origin: 'https://example.invalid', sessionStore: MemorySessionStore());
  final String base;
  @override
  Future<dynamic> get(String path, {Map<String, dynamic>? query}) async {
    final id = path.split('/')[2];
    return {'url': '$base/$id.mp4?X-Amz-Signature=fixture'};
  }

  @override
  Future<dynamic> post(String path, {dynamic data}) async => {'urls': []};
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('no thumbnail, no size: first frame from ranged reads; inline player plays', (tester) async {
    final dir = Directory.systemTemp.createTempSync('raft-video-cards-linux');
    addTearDown(() => dir.deleteSync(recursive: true));
    Future<void> make(String name, String size) async {
      final r = await Process.run('ffmpeg', [
        '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=$size:rate=24:duration=40',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=40', '-c:v', 'libx264', '-b:v', '3M',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-movflags', '+faststart', '${dir.path}/$name.mp4',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    await tester.runAsync(() async {
      await make('landscape', '1280x720');
      await make('portrait', '720x1280');
    });
    final sent = <String, int>{};
    final requests = <String, int>{};
    final ranges = <String, List<String>>{};
    final server = (await tester.runAsync(() => HttpServer.bind(InternetAddress.loopbackIPv4, 0)))!;
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      final file = File('${dir.path}/$name');
      final size = file.lengthSync();
      var start = 0, end = size - 1, status = 200;
      final header = request.headers.value('range');
      final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(header ?? '');
      if (range != null) {
        if (range[1]!.isNotEmpty) start = int.parse(range[1]!);
        if (range[2]!.isNotEmpty) end = int.parse(range[2]!).clamp(0, size - 1);
        if (range[1]!.isEmpty && range[2]!.isNotEmpty) {
          start = size - int.parse(range[2]!);
          end = size - 1;
        }
        status = 206;
      }
      requests[name] = (requests[name] ?? 0) + 1;
      ranges.putIfAbsent(name, () => []).add(header ?? '-');
      request.response
        ..statusCode = status
        ..headers.set('accept-ranges', 'bytes')
        ..headers.contentType = ContentType('video', 'mp4')
        ..contentLength = end - start + 1;
      if (status == 206) request.response.headers.set('content-range', 'bytes $start-$end/$size');
      // A small send buffer, so the count is what the client read. An
      // open-ended range would otherwise fill the kernel buffer with the file.
      final socket = await request.response.detachSocket(writeHeaders: true);
      try {
        socket.setRawOption(RawSocketOption.fromInt(1, 7, 32768));
      } on Object {
        // best effort
      }
      final reader = await file.open();
      try {
        await reader.setPosition(start);
        var left = end - start + 1;
        while (left > 0) {
          final chunk = await reader.read(left < 16384 ? left : 16384);
          if (chunk.isEmpty) break;
          socket.add(chunk);
          await socket.flush();
          sent[name] = (sent[name] ?? 0) + chunk.length;
          left -= chunk.length;
        }
      } on Object {
        // the reader went away
      } finally {
        await reader.close();
        socket.destroy();
      }
    });
    addTearDown(() => server.close(force: true));

    final client = _Client('http://127.0.0.1:${server.port}')..user = RaftRecord({'id': 'alice'});
    client.selectServer('server');
    final store = AttachmentDiskCache(() async => dir);
    Map<String, dynamic> clip(String name) => {
      'id': name,
      'channelId': 'channel',
      'filename': '$name.mp4',
      'mimeType': 'video/mp4',
      // Declared large: a card does not prepare its player by itself (the
      // poster is then the only picture until the first Play).
      'sizeBytes': 60 * 1024 * 1024,
    };
    final w = WorkspaceController(client, attachmentImageStore: store)
      ..server = RaftRecord({'id': 'server', 'role': 'owner'})
      ..channel = RaftChannel({'id': 'channel', 'joined': true});
    w.channels = [w.channel!];
    w.ledger.switchServer('server');
    w.ledger.ingest([
      {
        'id': 'host',
        'channelId': 'channel',
        'seq': '1',
        'content': 'clips',
        'attachments': [clip('portrait'), clip('landscape')],
      },
    ], expectedGeneration: w.ledger.generation);
    w.visibleIds['channel'] = {'host'};
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      w.dispose();
      await client.dispose();
    });
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final probe = _LoggingProbe();
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final name in ['portrait', 'landscape'])
                InlineVideoAttachment(
                  key: ValueKey(name),
                  controller: w,
                  metadata: clip(name),
                  channelId: 'channel',
                  authorized: () => true,
                  pending: false,
                  onOpenPreview: () {},
                  frameProbe: probe,
                ),
            ],
          ),
        ),
      ),
    );
    Finder poster(String name) => find.descendant(
      of: find.byKey(ValueKey(name)),
      matching: find.byType(Image),
    );
    final clock = Stopwatch()..start();
    while ((poster('portrait').evaluate().isEmpty || poster('landscape').evaluate().isEmpty) &&
        clock.elapsed < const Duration(seconds: 60)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print('VIDEO-CARDS-LINUX after ${clock.elapsedMilliseconds} ms: images=${find.byType(Image).evaluate().length} raw=${find.byType(RawImage).evaluate().length} cards=${find.byType(RaftInlineVideo).evaluate().length} sessions.failed=${w.playerSessions.frameFailed.length} shapes=${w.playerSessions.shapes.length} stored=${await tester.runAsync(() => store.entryCount(namespace: AttachmentCacheNamespace.attachments))}');
    expect(poster('portrait'), findsOneWidget, reason: 'the first frame of the portrait clip');
    expect(poster('landscape'), findsOneWidget);
    final bytes = {for (final e in sent.entries) e.key: e.value};
    final sizes = {
      for (final name in ['portrait', 'landscape']) '$name.mp4': File('${dir.path}/$name.mp4').lengthSync(),
    };
    // ignore: avoid_print
    print('VIDEO-CARDS-LINUX posters after ${clock.elapsedMilliseconds} ms; bytes $bytes of $sizes; requests $requests; ranges $ranges');
    for (final name in sizes.keys) {
      expect(bytes[name] ?? 0, lessThan(sizes[name]! ~/ 4), reason: '$name: ranged reads, not the file');
    }
    // Desktop keeps the inline player. The centre Play disc is hover-only
    // (the widget test: paused, the bar is up, the big Play is not); a click
    // on the picture plays.
    expect(find.byType(RaftInlineVideo), findsNWidgets(2));
    expect(find.byType(RaftVideoPosterCard), findsNothing);
    final surface = find.descendant(
      of: find.byKey(const ValueKey('landscape')),
      matching: find.byKey(const Key('inline-video-surface')),
    );
    expect(surface, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('landscape')),
        matching: find.byKey(const Key('inline-video-play')),
      ),
      findsNothing,
    );
    await tester.tap(surface);
    final card = find.descendant(
      of: find.byKey(const ValueKey('landscape')),
      matching: find.byType(RaftInlineVideo),
    );
    final playClock = Stopwatch()..start();
    while (playClock.elapsed < const Duration(seconds: 40)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      final video = tester.widget<RaftInlineVideo>(card);
      if (video.playing && video.position > const Duration(seconds: 1)) break;
    }
    final video = tester.widget<RaftInlineVideo>(card);
    // ignore: avoid_print
    print('VIDEO-CARDS-LINUX inline playing=${video.playing} position=${video.position}');
    expect(video.playing, isTrue);
    expect(video.position, greaterThan(const Duration(seconds: 1)));
    await tester.pumpWidget(const SizedBox());
  });
}
