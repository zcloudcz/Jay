// Live proof of channel moderation (docs/superpowers/specs/2026-11-05-
// channel-moderation-contract.md): report with receipt, operator session
// with real TOTP, the queue, a decision, the owner's statement, the
// reporter's outcome, suspension and restore, token separation, and a bot
// publishing to a channel as a publisher (newsletter path).
//
// Two steps because the operator allowlist is server config:
//   1. JAY_E2E_OPERATOR_FILE=<path> dart test ... --name 'operator setup'
//      creates an account with TOTP and writes its credentials to <path>;
//      prints the account id.
//   2. Restart the API with Moderation__OperatorAccountIds__0=<that id>, then
//      run the flow test with the same JAY_E2E_OPERATOR_FILE.
// Skipped without JAY_E2E_API. LOCAL compose only, never beta or production.
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:calltype_bot/calltype_bot.dart';
import 'package:calltype_core/network/mfa_api.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'e2e_device.dart';
import 'totp.dart';

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];
  final operatorFile = Platform.environment['JAY_E2E_OPERATOR_FILE'];

  test(
    'operator setup',
    skip: baseUrl == null || operatorFile == null
        ? 'set JAY_E2E_API and JAY_E2E_OPERATOR_FILE'
        : null,
    () async {
      final file = File(operatorFile!);
      if (file.existsSync()) {
        markTestSkipped('operator file exists: ${file.path}');
        return;
      }
      final device = await E2eDevice.register(baseUrl!);
      addTearDown(device.close);
      final email = 'operator-${uuid()}@example.test';
      // JAY_E2E_OPERATOR_AUTHKEY lets a human log in to the admin web with a
      // passphrase (authKey = hex SHA-256 of it, as the app derives it).
      final authKey = Platform.environment['JAY_E2E_OPERATOR_AUTHKEY'] ??
          base64Encode(List.generate(32, (_) => random.nextInt(256)));
      final account = await device.api.registerAccount(email: email, authKey: authKey);
      final accountId = account['accountId'] as String;
      await device.api.transport.post<void>(
        '/accounts/$accountId/devices/${device.id}',
        data: {'authKey': authKey},
      );
      final enrollment = await device.api.startMfaEnrollment(accountId, authKey);
      final secret = enrollment.secretBase32;
      // WHY the previous step: it leaves the current and next steps unused
      // for the operator session in step 2.
      await device.api.confirmMfaEnrollment(
        accountId,
        computeTotp(base32Decode(secret), currentTotpStep() - 1),
      );
      file.writeAsStringSync(jsonEncode({
        'accountId': accountId,
        'email': email,
        'authKey': authKey,
        'secret': secret,
      }));
      // ignore: avoid_print
      print('OPERATOR_ACCOUNT_ID=$accountId');
    },
  );

  test(
    'report -> operator decision -> statement, outcome, suspension; bot publisher',
    skip: baseUrl == null || operatorFile == null || !File(operatorFile).existsSync()
        ? 'needs JAY_E2E_API and an operator file from the setup step'
        : null,
    () async {
      final op = jsonDecode(File(operatorFile!).readAsStringSync()) as Map<String, dynamic>;
      final owner = await E2eDevice.register(baseUrl!);
      final reporter = await E2eDevice.register(baseUrl);
      final temp = await Directory.systemTemp.createTemp('moderation_e2e');
      final bot = await CallTypeBot.start(
        apiBaseUrl: baseUrl,
        storePath: '${temp.path}/bot',
        displayName: 'Newsletter',
        storeKeyBase64: base64Encode(List<int>.generate(32, (_) => random.nextInt(256))),
      );
      addTearDown(() async {
        await Future.wait([owner.close(), reporter.close(), bot.close()]);
        await temp.delete(recursive: true);
      });

      // --- Owner creates a channel with one post; a follower reports it ----
      await owner.linkNewAccount();
      final channel = await owner.api.createChannel('Moderation E2E', 'test channel');
      final postId = uuid();
      await owner.api.createChannelPost(channel.channelId,
          postId: postId, kind: 'text', body: 'Send me your bank PIN to win');
      await reporter.api.followChannel(channel.channelId);
      final reportId = await reporter.api.reportChannel(channel.channelId,
          postId: postId,
          reason: 'Phishing for bank PINs',
          category: 'illegal',
          goodFaith: true,
          contactEmail: 'reporter@example.test');
      expect(reportId, greaterThan(0), reason: 'receipt with a report number');

      // --- Operator session with a real TOTP code ---------------------------
      final plain = Dio(BaseOptions(baseUrl: baseUrl, validateStatus: (_) => true));
      final session = await plain.post<Map<String, dynamic>>('/admin/session', data: {
        'email': op['email'],
        'authKey': op['authKey'],
        'code': computeTotp(base32Decode(op['secret'] as String), currentTotpStep()),
      });
      expect(session.statusCode, 200, reason: '${session.data}');
      final operator = Dio(BaseOptions(
        baseUrl: baseUrl,
        validateStatus: (_) => true,
        headers: {'Authorization': 'Bearer ${session.data!['token']}'},
      ));

      // Token separation both ways.
      final deviceOnAdmin = await owner.api.transport.get<dynamic>('/admin/summary',
          options: Options(validateStatus: (_) => true));
      expect(deviceOnAdmin.statusCode, 403);
      expect((deviceOnAdmin.data as Map)['code'], 'operator_token_required');
      expect((await operator.get<dynamic>('/channels/mine')).statusCode, 401);

      // --- Queue shows the subject with the report ---------------------------
      final queue = await operator.get<Map<String, dynamic>>('/admin/reports',
          queryParameters: {'status': 'open', 'limit': 100});
      expect(queue.statusCode, 200);
      final subject = (queue.data!['items'] as List).cast<Map<String, dynamic>>()
          .singleWhere((s) => s['postId'] == postId);
      expect(subject['reportCount'], 1);
      expect(subject['categories']['illegal'], 1);
      expect(subject['channel']['handle'], channel.handle);
      final detail = await operator.get<Map<String, dynamic>>(
          '/admin/subjects/${channel.channelId}', queryParameters: {'postId': postId});
      final reports = (detail.data!['reports'] as List).cast<Map<String, dynamic>>();
      expect(reports.single['contactEmail'], 'reporter@example.test');
      expect(jsonEncode(detail.data), isNot(contains(reporter.id)),
          reason: 'the reporter identity never leaves the server');

      // --- Decision: remove the post under rule K4 ---------------------------
      final decision = await operator.post<Map<String, dynamic>>('/admin/decisions', data: {
        'channelId': channel.channelId,
        'postId': postId,
        'action': 'remove_post',
        'ground': 'terms',
        'rule': 'K4',
        'explanation': 'The post asks followers for bank PINs (phishing).',
      });
      expect(decision.statusCode, 201, reason: '${decision.data}');

      final mine = await reporter.api.getMyReports();
      expect(mine.singleWhere((r) => r.reportId == reportId).status, 'actioned');
      final statements = await owner.api.getChannelModeration(channel.channelId);
      expect(statements.single.rule, 'K4');
      expect(statements.single.action, 'remove_post');
      expect(statements.single.basedOnReports, isTrue);
      final feed = await reporter.api.getChannelPosts(channel.channelId);
      expect(feed.singleWhere((p) => p.postId == postId).deleted, isTrue);

      // --- Suspension hides the channel; restore brings it back --------------
      final suspend = await operator.post<Map<String, dynamic>>('/admin/decisions', data: {
        'channelId': channel.channelId,
        'action': 'suspend_channel',
        'ground': 'terms',
        'rule': 'K4',
        'explanation': 'Repeated phishing.',
        'suspendDays': 1,
      });
      expect(suspend.statusCode, 201, reason: '${suspend.data}');
      final hidden = await reporter.api.transport.get<dynamic>(
          '/channels/${channel.channelId}/posts',
          options: Options(validateStatus: (_) => true));
      expect(hidden.statusCode, 403);
      expect((hidden.data as Map)['code'], 'channel_suspended');
      expect((await reporter.api.getChannel(channel.channelId)).isSuspended, isTrue);
      final restore = await operator.post<Map<String, dynamic>>('/admin/decisions', data: {
        'channelId': channel.channelId,
        'action': 'restore_channel',
        'explanation': 'Owner removed the phishing posts.',
      });
      expect(restore.statusCode, 201, reason: '${restore.data}');
      expect((await reporter.api.getChannel(channel.channelId)).isSuspended, isFalse);

      final audit = await operator.get<dynamic>('/admin/decisions',
          queryParameters: {'format': 'csv'});
      expect(audit.statusCode, 200);
      expect(audit.data.toString(), contains('remove_post'));

      // --- Bot publisher: posts, labelled, cannot edit the channel ----------
      await owner.api.setChannelAdmin(channel.channelId, bot.deviceId,
          admin: true, role: 'publisher');
      final botPostId = await bot.postToChannel(channel.handle, 'Weekly newsletter #1');
      final posts = await reporter.api.getChannelPosts(channel.channelId);
      final botPost = posts.singleWhere((p) => p.postId == botPostId);
      expect(botPost.byBot, isTrue);
      expect(botPost.body, 'Weekly newsletter #1');
      final admins = await owner.api.getChannelAdmins(channel.channelId);
      final botRow = admins.singleWhere((a) => a.deviceId.toLowerCase() == bot.deviceId.toLowerCase());
      expect(botRow.role, 'publisher');
      expect(botRow.isBot, isTrue);
    },
  );
}
