import 'dart:convert';
import 'dart:typed_data';

import 'package:calltype_core/network/api_client.dart';
import 'package:calltype_core/network/group_dtos.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// Records every request and answers with [respond]'s (status, body).
class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final (int, Object?) Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = respond(options);
    return ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _Adapter) _client((int, Object?) Function(RequestOptions) respond) {
  final adapter = _Adapter(respond);
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = adapter;
  return (ApiClient(baseUrl: 'https://api.test', dio: dio), adapter);
}

void main() {
  group('BotTalkSettings.fromJson', () {
    // Table: input -> expected (mode, ids, maxTurns, pause).
    final cases = <String, (Object?, BotTalkMode, List<String>, int, int)>{
      'missing (old server)': (null, BotTalkMode.off, [], 5, 30),
      'not a map': ('all', BotTalkMode.off, [], 5, 30),
      'unknown mode fails closed': (
        {'mode': 'chaos'},
        BotTalkMode.off,
        [],
        5,
        30,
      ),
      'all': (
        {'mode': 'all', 'maxBotTurns': 7, 'pauseMinutes': 0},
        BotTalkMode.all,
        [],
        7,
        0,
      ),
      'selected, ids lower-cased': (
        {
          'mode': 'selected',
          'allowedBotDeviceIds': ['AB-1', 'cd-2', 3],
        },
        BotTalkMode.selected,
        ['ab-1', 'cd-2'],
        5,
        30,
      ),
      'bad numbers fall back': (
        {'mode': 'all', 'maxBotTurns': 'x', 'pauseMinutes': null},
        BotTalkMode.all,
        [],
        5,
        30,
      ),
    };
    cases.forEach((name, c) {
      test(name, () {
        final s = BotTalkSettings.fromJson(c.$1);
        expect(s.mode, c.$2);
        expect(s.allowedBotDeviceIds, c.$3);
        expect(s.maxBotTurns, c.$4);
        expect(s.pauseMinutes, c.$5);
      });
    });

    test('updatedAt and allows() are parsed / case-insensitive', () {
      final s = BotTalkSettings.fromJson({
        'mode': 'selected',
        'allowedBotDeviceIds': ['aa'],
        'updatedAt': '2026-11-05T10:00:00Z',
      });
      expect(s.updatedAt, DateTime.utc(2026, 11, 5, 10));
      expect(s.allows('AA'), isTrue);
      expect(s.allows('bb'), isFalse);
    });
  });

  group('MuteSetting', () {
    test('parses, defaults to off, and expires', () {
      expect(MuteSetting.fromJson(null).mode, MuteMode.off);
      expect(MuteSetting.fromJson({'mode': 'weird'}).mode, MuteMode.off);
      final m = MuteSetting.fromJson({
        'mode': 'bots',
        'until': '2026-11-05T12:00:00Z',
      });
      expect(m.mode, MuteMode.bots);
      expect(m.effectiveMode(DateTime.utc(2026, 11, 5, 11)), MuteMode.bots);
      expect(m.effectiveMode(DateTime.utc(2026, 11, 5, 12)), MuteMode.off);
      expect(
        MuteSetting.fromJson({'mode': 'all'}).effectiveMode(DateTime.utc(3000)),
        MuteMode.all,
      );
    });

    test('toJson is the contract body', () {
      expect(const MuteSetting(mode: MuteMode.all).toJson(), {
        'mode': 'all',
        'until': null,
      });
      expect(
        MuteSetting(
          mode: MuteMode.bots,
          until: DateTime.utc(2026, 1, 1),
        ).toJson(),
        {'mode': 'bots', 'until': '2026-01-01T00:00:00.000Z'},
      );
    });
  });

  group('ApiClient', () {
    test('getGroup: new server shape', () async {
      final (api, adapter) = _client(
        (_) => (
          200,
          {
            'groupId': 'g1',
            'organizationId': null,
            'botTalk': {
              'mode': 'selected',
              'allowedBotDeviceIds': ['b1'],
              'maxBotTurns': 3,
              'pauseMinutes': 10,
              'updatedAt': null,
            },
            'myMute': {'mode': 'bots', 'until': null},
          },
        ),
      );
      final g = await api.getGroup('g1');
      expect(adapter.requests.single.path, '/groups/g1');
      expect(g.botTalk.mode, BotTalkMode.selected);
      expect(g.botTalk.allowedBotDeviceIds, ['b1']);
      expect(g.botTalk.maxBotTurns, 3);
      expect(g.botTalk.pauseMinutes, 10);
      expect(g.botTalk.updatedAt, isNull);
      expect(g.myMute.mode, MuteMode.bots);
    });

    test('getGroup: old server without botTalk/myMute reads as off', () async {
      final (api, _) = _client(
        (_) => (200, {'groupId': 'g1', 'organizationId': null}),
      );
      final g = await api.getGroup('g1');
      expect(g.botTalk.mode, BotTalkMode.off);
      expect(g.myMute.mode, MuteMode.off);
      expect(g.raw['organizationId'], isNull);
    });

    test('setGroupBotTalk PUTs the body and parses the answer', () async {
      final (api, adapter) = _client(
        (o) => (200, {...o.data as Map, 'updatedAt': '2026-11-05T10:00:00Z'}),
      );
      final stored = await api.setGroupBotTalk(
        'g1',
        const BotTalkSettings(
          mode: BotTalkMode.all,
          maxBotTurns: 9,
          pauseMinutes: 1,
        ),
      );
      final r = adapter.requests.single;
      expect((r.method, r.path), ('PUT', '/groups/g1/bot-talk'));
      expect(r.data, {
        'mode': 'all',
        'allowedBotDeviceIds': [],
        'maxBotTurns': 9,
        'pauseMinutes': 1,
      });
      expect(stored.mode, BotTalkMode.all);
      expect(stored.updatedAt, DateTime.utc(2026, 11, 5, 10));
    });

    test('mute PUTs hit the contract routes', () async {
      final (api, adapter) = _client((_) => (204, null));
      await api.setGroupMute('g1', const MuteSetting(mode: MuteMode.all));
      await api.setDirectMute('p1', const MuteSetting(mode: MuteMode.bots));
      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'PUT /groups/g1/mute',
        'PUT /mutes/direct/p1',
      ]);
      expect(adapter.requests.last.data, {'mode': 'bots', 'until': null});
    });

    test('getMutes parses group and direct rows', () async {
      final (api, _) = _client(
        (_) => (
          200,
          [
            {
              'groupId': 'g1',
              'peerDeviceId': null,
              'mode': 'all',
              'until': null,
            },
            {
              'groupId': null,
              'peerDeviceId': 'p1',
              'mode': 'bots',
              'until': '2026-11-06T00:00:00Z',
            },
          ],
        ),
      );
      final mutes = await api.getMutes();
      expect(mutes.first.groupId, 'g1');
      expect(mutes.first.setting.mode, MuteMode.all);
      expect(mutes.last.peerDeviceId, 'p1');
      expect(mutes.last.setting.until, DateTime.utc(2026, 11, 6));
    });

    test('getGroupMemberInfos keeps the role', () async {
      final (api, _) = _client(
        (_) => (
          200,
          [
            {'deviceId': 'd1', 'role': 'admin'},
            {'deviceId': 'd2'},
          ],
        ),
      );
      final members = await api.getGroupMemberInfos('g');
      expect(members.map((m) => m.role), ['admin', 'member']);
    });
  });
}
