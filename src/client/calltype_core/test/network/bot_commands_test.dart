import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/bot_dtos.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Records the request and answers with [body].
class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  final Object body;
  final requests = <({String method, String path, Object? data})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add((
      method: options.method,
      path: options.path,
      data: options.data,
    ));
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _Adapter) _client(Object body) {
  final adapter = _Adapter(body);
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = adapter;
  return (ApiClient(baseUrl: 'https://api.test', dio: dio), adapter);
}

void main() {
  test('getBotCommands reads the list and skips malformed rows', () async {
    final (api, adapter) = _client({
      'commands': [
        {'command': 'help', 'description': 'Show help'},
        {'command': 5},
        'junk',
        {'command': 'status', 'description': 'Status'},
      ],
    });
    expect(await api.getBotCommands('dev-1'), const [
      BotCommand(command: 'help', description: 'Show help'),
      BotCommand(command: 'status', description: 'Status'),
    ]);
    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/devices/dev-1/bot-commands');
  });

  test('getBotCommands: missing list is empty', () async {
    final (api, _) = _client(<String, dynamic>{});
    expect(await api.getBotCommands('dev-1'), isEmpty);
  });

  test(
    'setBotCommands PUTs {"commands": [...]} and returns the stored list',
    () async {
      final (api, adapter) = _client({
        'commands': [
          {'command': 'help', 'description': 'Show help'},
        ],
      });
      final stored = await api.setBotCommands('dev-1', const [
        BotCommand(command: 'help', description: 'Show help'),
      ]);
      expect(stored.single.command, 'help');
      final request = adapter.requests.single;
      expect(request.method, 'PUT');
      expect(request.path, '/devices/dev-1/bot-commands');
      expect(request.data, {
        'commands': [
          {'command': 'help', 'description': 'Show help'},
        ],
      });
    },
  );

  test('BotCommand.isValid mirrors the server rules', () {
    expect(const BotCommand(command: 'a_1', description: 'x').isValid, isTrue);
    expect(
      const BotCommand(command: 'Help', description: 'x').isValid,
      isFalse,
    );
    expect(
      const BotCommand(command: 'help', description: ' ').isValid,
      isFalse,
    );
    expect(BotCommand(command: 'h', description: 'd' * 101).isValid, isFalse);
    expect(BotCommand(command: 'c' * 33, description: 'd').isValid, isFalse);
  });
}
