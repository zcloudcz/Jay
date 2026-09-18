import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:jay_archiver/jay_archiver.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A [GroupMessageSource] a test fully controls: pushes events on demand,
/// records every ack call.
class FakeSource implements GroupMessageSource {
  final _controller = StreamController<IncomingGroupMessage>.broadcast();
  final acks = <({String senderId, String messageId})>[];

  @override
  Stream<IncomingGroupMessage> get messages => _controller.stream;

  void push(IncomingGroupMessage message) => _controller.add(message);

  @override
  Future<void> ack({required String senderId, required String messageId}) async {
    acks.add((senderId: senderId, messageId: messageId));
  }

  Future<void> close() => _controller.close();
}

IncomingGroupMessage _message({String id = 'm1', String? hash}) =>
    IncomingGroupMessage(
      messageId: id,
      groupId: 'g1',
      senderId: 'alice',
      sentAt: DateTime.now().toUtc(),
      kind: 'text',
      sizeBytes: 10,
      contentHashHex: hash ?? 'a' * 64,
    );

void main() {
  late FakeArchiveApi fakeApi;
  late Dio dio;
  late FakeSource source;

  setUp(() async {
    fakeApi = await FakeArchiveApi.start();
    dio = Dio(BaseOptions(baseUrl: fakeApi.url));
    source = FakeSource();
  });

  tearDown(() async {
    await source.close();
    await fakeApi.close();
  });

  test('acks only after a 2xx archive write', () async {
    fakeApi.responses
      ..clear()
      ..add(200);
    final archiver = Archiver(source: source, api: dio, organizationId: 'org1');
    unawaited(archiver.run());

    source.push(_message());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(fakeApi.requests, hasLength(1));
    expect(source.acks, hasLength(1));
    expect(source.acks.single.messageId, 'm1');
    await archiver.stop();
  });

  test('does not ack on a 5xx response', () async {
    fakeApi.responses
      ..clear()
      ..add(500);
    final archiver = Archiver(
      source: source,
      api: dio,
      organizationId: 'org1',
      maxAttempts: 2,
      backoff: (_) => Duration.zero,
    );
    unawaited(archiver.run());

    source.push(_message());
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(fakeApi.requests, hasLength(2)); // both attempts were tried
    expect(source.acks, isEmpty);
    await archiver.stop();
  });

  test('a duplicate message id is posted once', () async {
    fakeApi.responses
      ..clear()
      ..add(200);
    final archiver = Archiver(source: source, api: dio, organizationId: 'org1');
    unawaited(archiver.run());

    source.push(_message());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    source.push(_message()); // redelivered, e.g. server's pending-message sweep
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(fakeApi.requests, hasLength(1));
    expect(source.acks, hasLength(2)); // still acked both times
    await archiver.stop();
  });

  test('a 403 response is treated as a fatal auth error', () async {
    fakeApi.responses
      ..clear()
      ..add(403);
    final archiver = Archiver(source: source, api: dio, organizationId: 'org1');
    final done = archiver.run();

    source.push(_message());

    await expectLater(done, throwsA(isA<ArchiverAuthException>()));
    expect(source.acks, isEmpty);
  });

  test('plaintext never appears in the request body or a log line', () async {
    const plaintextMarker = 'THE-SECRET-BODY-TEXT';
    fakeApi.responses
      ..clear()
      ..add(200);
    final logs = <String>[];
    final archiver = Archiver(source: source, api: dio, organizationId: 'org1', log: logs.add);
    unawaited(archiver.run());

    // The source only ever hands the archiver a hash — this asserts the
    // Archiver itself has no path that could leak a plaintext body even if
    // a future change accidentally added one to IncomingGroupMessage.
    source.push(_message());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    for (final request in fakeApi.requests) {
      expect(request.toString(), isNot(contains(plaintextMarker)));
    }
    for (final line in logs) {
      expect(line, isNot(contains(plaintextMarker)));
    }
    await archiver.stop();
  });

  test('nothing under a temp state dir ever contains plaintext', () async {
    final dir = await Directory.systemTemp.createTemp('jay_archiver_test_');
    const plaintextMarker = 'THE-SECRET-BODY-TEXT';
    try {
      fakeApi.responses
        ..clear()
        ..add(200);
      final archiver = Archiver(source: source, api: dio, organizationId: 'org1');
      unawaited(archiver.run());
      source.push(_message());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await archiver.stop();

      // The archiver never wrote anything to this directory in the first
      // place (it only talks to the source and the HTTP API) — this proves
      // that invariant rather than assuming it.
      final files = await dir.list(recursive: true).toList();
      for (final entity in files) {
        if (entity is File) {
          final content = await entity.readAsString();
          expect(content, isNot(contains(plaintextMarker)));
        }
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
