import 'package:calltype/core/network/push_service.dart';
import 'package:calltype/features/notifications/local_notifier.dart';
import 'package:calltype/features/notifications/notification_content.dart';
import 'package:calltype/features/notifications/notification_service.dart';
import 'package:calltype_core/network/group_dtos.dart' show MuteMode;
import 'package:flutter_test/flutter_test.dart';

import 'fake_notifications.dart';

void main() {
  group('messages', () {
    late NotificationHarness h;
    setUp(() async {
      h = NotificationHarness();
      h.directory.contacts['alice'] = (name: 'Alice', isBot: false);
      h.directory.contacts['bob'] = (name: 'Bob', isBot: false);
      h.directory.contacts['botty'] = (name: 'Botty', isBot: true);
      h.directory.groups['team'] = 'Team';
      await h.service.start();
    });

    test('a 1:1 message shows the contact and the preview', () async {
      await h.service.onMessage(message());
      final n = h.notifier.shown.single;
      expect(n.title, 'Alice');
      expect(n.body, 'Hello');
      expect(
        n.target,
        const NotificationTarget(NotificationKind.message, 'alice'),
      );
    });

    test('a group message names group and sender', () async {
      await h.service.onMessage(
        message(conversationId: 'team', senderId: 'bob', body: 'lunch?'),
      );
      final n = h.notifier.shown.single;
      expect(n.title, 'Team');
      expect(n.body, 'Bob: lunch?');
      expect(n.target!.kind, NotificationKind.groupMessage);
    });

    test('previews off: generic text only', () async {
      await h.service.setPreviews(false);
      await h.service.onMessage(message(body: 'secret'));
      expect(h.notifier.shown.single.body, 'New message');
      expect(h.prefs.values['ct_notifications_previews'], 'false');
    });

    test('own other device: nothing', () async {
      await h.service.onMessage(message(senderId: 'me', conversationId: 'x'));
      expect(h.notifier.shown, isEmpty);
    });

    test(
      'open and focused chat: nothing; same chat unfocused: shown',
      () async {
        h.path = '/chats/alice';
        await h.service.onMessage(message());
        expect(h.notifier.shown, isEmpty);

        h.focused = false;
        await h.service.onMessage(message(id: 'm2'));
        expect(h.notifier.shown, hasLength(1));
      },
    );

    test('muted conversation: nothing; bots mute only for bots', () async {
      h.mutes['alice'] = MuteMode.all;
      await h.service.onMessage(message());
      expect(h.notifier.shown, isEmpty);

      h.mutes['botty'] = MuteMode.bots;
      await h.service.onMessage(
        message(conversationId: 'botty', senderId: 'botty'),
      );
      expect(h.notifier.shown, isEmpty);

      h.mutes['team'] = MuteMode.bots;
      await h.service.onMessage(
        message(conversationId: 'team', senderId: 'bob'),
      );
      expect(h.notifier.shown, hasLength(1));
    });

    test('call-event log lines and tombstones never notify', () async {
      await h.service.onMessage(message(type: 'call-event'));
      await h.service.onMessage(message(deleted: true, body: null));
      expect(h.notifier.shown, isEmpty);
    });

    test('a file shows a type label, not its content', () async {
      await h.service.onMessage(
        message(type: 'file', body: '{"name":"cat.png","data":"AAAA"}'),
      );
      expect(h.notifier.shown.single.body, 'Photo');
    });

    test('notifications turned off: nothing at all', () async {
      await h.service.setEnabled(false);
      await h.service.onMessage(message());
      expect(h.notifier.shown, isEmpty);
    });

    test('no permission: nothing, and no crash', () async {
      h.notifier.current = NotifierPermission.denied;
      await h.service.refreshPermission();
      await h.service.onMessage(message());
      expect(h.notifier.shown, isEmpty);
    });
  });

  group('channel posts and calls', () {
    late NotificationHarness h;
    setUp(() async {
      h = NotificationHarness();
      h.directory.channels['c1'] = 'News';
      h.directory.contacts['alice'] = (name: 'Alice', isBot: false);
      h.directory.devices['alice-phone'] = 'alice';
      h.focused = false;
      await h.service.start();
    });

    test('a channel post shows channel name and text', () async {
      await h.service.onChannelPost(channelPost());
      final n = h.notifier.shown.single;
      expect(n.title, 'News');
      expect(n.body, 'Big news');
      expect(n.target!.route, '/channels/feed/c1');
    });

    test('a poll is labelled; the open feed is skipped', () async {
      await h.service.onChannelPost(channelPost(kind: 'poll', body: '{}'));
      expect(h.notifier.shown.single.body, 'Poll');

      h.focused = true;
      h.path = '/channels/feed/c1';
      await h.service.onChannelPost(channelPost());
      expect(h.notifier.shown, hasLength(1));
    });

    test('incoming call in the background rings, then is withdrawn', () async {
      await h.service.onIncomingCall('alice-phone');
      final n = h.notifier.shown.single;
      expect(n.title, 'Alice');
      expect(n.body, 'Incoming call');
      expect(
        n.target,
        const NotificationTarget(NotificationKind.incomingCall, 'alice'),
      );

      await h.service.onCallNotRinging();
      expect(h.notifier.cancelled, [n.target]);
    });

    test('incoming call while focused: the call screen is enough', () async {
      h.focused = true;
      await h.service.onIncomingCall('alice-phone');
      expect(h.notifier.shown, isEmpty);
    });

    test('missed call: named when the caller is known, shown even while '
        'focused, silenced only by a full mute', () async {
      h.focused = true;
      await h.service.onMissedCall('alice-phone');
      final n = h.notifier.shown.single;
      expect(n.title, 'Alice');
      expect(n.body, 'Missed call');
      expect(
        n.target,
        const NotificationTarget(NotificationKind.incomingCall, 'alice'),
      );

      // A ring push carries no caller (R4): generic text, no target.
      await h.service.onMissedCall(null);
      expect(h.notifier.shown.last.title, 'Jay');
      expect(h.notifier.shown.last.target, isNull);

      h.mutes['alice'] = MuteMode.all;
      await h.service.onMissedCall('alice-phone');
      expect(h.notifier.shown, hasLength(2));
    });
  });

  group('taps', () {
    test('local tap, launch tap and server push tap open the target', () async {
      final provider = FakePushProvider();
      final notifier = FakeNotifier()
        ..launch = {'type': 'message', 'conversationId': 'p0', 'v': '1'};
      final h = NotificationHarness(notifier: notifier, provider: provider);
      await h.service.start();
      await h.service.onConnected();

      notifier.tapController.add({
        'type': 'channel_post',
        'conversationId': 'c1',
        'v': '1',
      });
      provider.openedController.add({
        'type': 'group_message',
        'conversationId': 'g1',
        'v': '1',
      });
      notifier.tapController.add({}); // test notification
      await Future<void>.delayed(Duration.zero);

      expect(h.routes, [
        '/chats/p0',
        '/channels/feed/c1',
        '/chats/g1',
        '/chats',
      ]);
    });
  });

  group('permission and push registration', () {
    test('mobile: one automatic prompt after connect, then push with '
        'locale', () async {
      final notifier = FakeNotifier(
        current: NotifierPermission.denied, // Android 13 before asking
      );
      final h = NotificationHarness(
        notifier: notifier,
        provider: FakePushProvider(),
      );
      await h.service.start();
      expect(h.service.state, NotificationState.permissionRequired);
      expect(notifier.prompts, 0, reason: 'never on app start');

      await h.service.onConnected();
      expect(notifier.prompts, 1);
      expect(h.api.calls, ['PUT dev-1 fcm tok cs']);
      expect(h.service.state, NotificationState.active);

      // Reconnect: re-registers, never prompts again.
      await h.service.onConnected();
      expect(notifier.prompts, 1);
      expect(h.api.calls, hasLength(2));
    });

    test('mobile: a refusal is remembered and shown as denied', () async {
      final notifier = FakeNotifier(
        current: NotifierPermission.denied,
        answer: NotifierPermission.denied,
      );
      final h = NotificationHarness(notifier: notifier);
      await h.service.start();
      await h.service.onConnected();
      expect(h.service.state, NotificationState.permissionDenied);
      expect(h.api.calls, isEmpty);

      // A new app start does not prompt again.
      final again = NotificationHarness(notifier: notifier);
      again.prefs.values.addAll(h.prefs.values);
      await again.service.start();
      await again.service.onConnected();
      expect(notifier.prompts, 1);
    });

    test('web: never prompts by itself; banner, then the click', () async {
      final notifier = FakeNotifier(
        current: NotifierPermission.notDetermined,
        needsGesture: true,
      );
      final h = NotificationHarness(
        notifier: notifier,
        provider: FakePushProvider(platform: 'webpush'),
      );
      await h.service.start();
      await h.service.onConnected();
      expect(notifier.prompts, 0);
      expect(h.service.showPermissionBanner, isTrue);

      await h.service.requestPermission(); // the button
      expect(notifier.prompts, 1);
      expect(h.service.showPermissionBanner, isFalse);
      expect(h.api.calls, ['PUT dev-1 webpush tok cs']);
    });

    test('web: banner dismissal is remembered', () async {
      final h = NotificationHarness(
        notifier: FakeNotifier(
          current: NotifierPermission.notDetermined,
          needsGesture: true,
        ),
      );
      await h.service.start();
      await h.service.dismissBanner();
      expect(h.service.showPermissionBanner, isFalse);
      expect(h.prefs.values['ct_notifications_banner_dismissed'], 'true');
    });

    test('turning off unregisters (DELETE), turning on registers', () async {
      final provider = FakePushProvider();
      final h = NotificationHarness(provider: provider);
      await h.service.start();
      await h.service.onConnected();

      await h.service.setEnabled(false);
      expect(h.api.calls.last, 'DELETE dev-1');
      expect(provider.released, isTrue);
      expect(h.service.state, NotificationState.off);
      expect(h.prefs.values['ct_notifications_enabled'], 'false');

      // Off survives a restart: no registration on connect.
      await h.service.onConnected();
      expect(h.api.calls.last, 'DELETE dev-1');

      await h.service.setEnabled(true);
      expect(h.api.calls.last, 'PUT dev-1 fcm tok cs');
    });

    test('no registration before onboarding gave the device an id', () async {
      final h = NotificationHarness(
        provider: FakePushProvider(),
        deviceId: null,
      );
      await h.service.start();
      await h.service.onConnected();
      expect(h.api.calls, isEmpty);
      expect(h.service.state, NotificationState.pushPending);
    });

    test('status per platform: desktop, missing config, active', () async {
      final desktop = NotificationHarness();
      await desktop.service.start();
      await desktop.service.onConnected();
      expect(desktop.service.state, NotificationState.localOnly);

      final provider = FakePushProvider()
        ..unavailable = PushStatus.notConfigured;
      final noFirebase = NotificationHarness(provider: provider);
      await noFirebase.service.start();
      await noFirebase.service.onConnected();
      expect(noFirebase.service.state, NotificationState.pushNotConfigured);
      expect(noFirebase.api.calls, isEmpty);
    });

    test('a platform without the plugin is unsupported, not a crash', () async {
      final notifier = FakeNotifier()..failInitialize = true;
      final h = NotificationHarness(notifier: notifier);
      await h.service.start();
      expect(h.service.state, NotificationState.unsupported);
      await h.service.onMessage(message());
      expect(notifier.shown, isEmpty);
    });

    test('channel names reach the platform in the UI language', () async {
      final h = NotificationHarness();
      await h.service.start();
      expect(h.notifier.names!.messages, 'Messages');
      expect(h.notifier.names!.calls, 'Calls');
      expect(h.notifier.names!.channels, 'Channels');
    });
  });

  test('test notification needs the permission', () async {
    final h = NotificationHarness(
      notifier: FakeNotifier(current: NotifierPermission.denied),
    );
    await h.service.start();
    expect(await h.service.showTest(), isFalse);

    h.notifier.current = NotifierPermission.granted;
    await h.service.refreshPermission();
    expect(await h.service.showTest(), isTrue);
    expect(h.notifier.shown.single.body, 'Notifications are working.');
    expect(h.notifier.shown.single.target, isNull);
  });
}
