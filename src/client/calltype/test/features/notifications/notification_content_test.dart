import 'package:calltype/features/notifications/notification_content.dart';
import 'package:calltype/features/notifications/notification_service.dart'
    show openConversationOf;
import 'package:calltype/l10n/l10n.dart';
import 'package:calltype_core/network/group_dtos.dart' show MuteMode;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/localized_app.dart';

/// Pure rules of notifications spec section 2 (decision, texts, routing).
void main() {
  NotificationSkip? skip({
    bool enabled = true,
    NotificationKind kind = NotificationKind.message,
    String conversationId = 'peer-1',
    bool fromSelf = false,
    bool appFocused = false,
    String? open,
    MuteMode mute = MuteMode.off,
    bool bot = false,
  }) => notificationSkip(
    enabled: enabled,
    kind: kind,
    conversationId: conversationId,
    fromSelf: fromSelf,
    appFocused: appFocused,
    openConversationId: open,
    mute: mute,
    senderIsBot: bot,
  );

  group('decision', () {
    test('a plain message from a contact is shown', () {
      expect(skip(), isNull);
    });

    test('notifications off', () {
      expect(skip(enabled: false), NotificationSkip.disabled);
    });

    test('own other device never notifies', () {
      expect(skip(fromSelf: true), NotificationSkip.ownDevice);
    });

    test('the open conversation is skipped only while the app is focused', () {
      expect(
        skip(appFocused: true, open: 'PEER-1'),
        NotificationSkip.conversationOpen,
      );
      // Minimized / unfocused window: the user does not see the chat.
      expect(skip(appFocused: false, open: 'peer-1'), isNull);
      // Focused, but another chat on screen.
      expect(skip(appFocused: true, open: 'other'), isNull);
    });

    test('mute all silences messages and calls', () {
      expect(skip(mute: MuteMode.all), NotificationSkip.muted);
      expect(
        skip(kind: NotificationKind.groupMessage, mute: MuteMode.all),
        NotificationSkip.muted,
      );
      expect(
        skip(kind: NotificationKind.incomingCall, mute: MuteMode.all),
        NotificationSkip.muted,
      );
    });

    test('mute bots silences only bot senders, never a call', () {
      expect(skip(mute: MuteMode.bots, bot: true), NotificationSkip.muted);
      expect(skip(mute: MuteMode.bots, bot: false), isNull);
      expect(
        skip(kind: NotificationKind.incomingCall, mute: MuteMode.bots),
        isNull,
      );
    });

    test('a call while the app is focused is left to the call screen', () {
      expect(
        skip(kind: NotificationKind.incomingCall, appFocused: true),
        NotificationSkip.conversationOpen,
      );
      expect(skip(kind: NotificationKind.incomingCall), isNull);
    });

    test('channel posts know no mute but respect the open feed', () {
      expect(
        skip(kind: NotificationKind.channelPost, mute: MuteMode.all),
        isNull,
      );
      expect(
        skip(
          kind: NotificationKind.channelPost,
          conversationId: 'c1',
          appFocused: true,
          open: 'c1',
        ),
        NotificationSkip.conversationOpen,
      );
    });
  });

  group('open conversation from the route', () {
    test('chat and channel feed count, anything else does not', () {
      expect(openConversationOf('/chats/abc'), 'abc');
      expect(openConversationOf('/channels/feed/c1'), 'c1');
      expect(openConversationOf('/chats'), isNull);
      expect(openConversationOf('/chats/abc/bot-talk'), isNull);
      expect(openConversationOf('/settings'), isNull);
      expect(openConversationOf(null), isNull);
    });
  });

  group('payload -> route', () {
    test('every contract type opens its screen', () {
      Map<String, String> data(String type, String id) => {
        'type': type,
        'conversationId': id,
        'v': '1',
      };
      expect(NotificationTarget.routeFor(data('message', 'p1')), '/chats/p1');
      expect(
        NotificationTarget.routeFor(data('group_message', 'g1')),
        '/chats/g1',
      );
      expect(
        NotificationTarget.routeFor(data('incoming_call', 'p1')),
        '/chats/p1',
      );
      expect(
        NotificationTarget.routeFor(data('channel_post', 'c1')),
        '/channels/feed/c1',
      );
    });

    test('unusable data falls back to the chat list', () {
      expect(NotificationTarget.routeFor({}), '/chats');
      expect(
        NotificationTarget.routeFor({'type': 'x', 'conversationId': 'a'}),
        '/chats',
      );
      // Route injection attempt.
      expect(
        NotificationTarget.routeFor({
          'type': 'message',
          'conversationId': '../settings/account',
        }),
        '/chats',
      );
    });

    test('a local notification carries the same data as a server push', () {
      const target = NotificationTarget(NotificationKind.groupMessage, 'g1');
      expect(target.toData(), {
        'type': 'group_message',
        'conversationId': 'g1',
        'v': '1',
      });
      expect(NotificationTarget.fromData(target.toData()), target);
    });

    test('Android channel ids match contract 1.3', () {
      expect(NotificationKind.message.androidChannelId, 'messages');
      expect(NotificationKind.groupMessage.androidChannelId, 'messages');
      expect(NotificationKind.incomingCall.androidChannelId, 'calls');
      expect(NotificationKind.channelPost.androidChannelId, 'channels');
    });
  });

  group('texts', () {
    test('preview on: name as title, text as body', () {
      final text = notificationText(
        l10n: l10nEn,
        kind: NotificationKind.message,
        title: 'Alice',
        previews: true,
        preview: const MessagePreview.text('Hi\nthere'),
      );
      expect(text.title, 'Alice');
      expect(text.body, 'Hi there');
    });

    test('preview off: generic text, never the content', () {
      final text = notificationText(
        l10n: l10nEn,
        kind: NotificationKind.groupMessage,
        title: 'Team',
        previews: false,
        preview: const MessagePreview.text('secret plan'),
        senderName: 'Bob',
      );
      expect(text.title, 'Team');
      expect(text.body, 'New message in a group');
    });

    test('group body names the sender', () {
      final text = notificationText(
        l10n: l10nEn,
        kind: NotificationKind.groupMessage,
        title: 'Team',
        previews: true,
        preview: const MessagePreview.text('lunch?'),
        senderName: 'Bob',
      );
      expect(text.body, 'Bob: lunch?');
    });

    test('attachments and polls become a label', () {
      String body(PreviewKind kind) => notificationText(
        l10n: l10nEn,
        kind: NotificationKind.message,
        title: 'A',
        previews: true,
        preview: MessagePreview.label(kind),
      ).body;
      expect(body(PreviewKind.photo), 'Photo');
      expect(body(PreviewKind.file), 'File');
      expect(body(PreviewKind.poll), 'Poll');
      expect(attachmentPreviewKind('IMG_1.JPG'), PreviewKind.photo);
      expect(attachmentPreviewKind('report.pdf'), PreviewKind.file);
    });

    test('unknown name falls back to Jay; generic texts per kind', () {
      final call = notificationText(
        l10n: l10nEn,
        kind: NotificationKind.incomingCall,
        title: null,
        previews: true,
      );
      expect(call.title, 'Jay');
      expect(call.body, 'Incoming call');
      expect(
        genericNotificationBody(l10nEn, NotificationKind.channelPost),
        'New post in a channel',
      );
      expect(
        genericNotificationBody(l10nEn, NotificationKind.message),
        'New message',
      );
    });

    test('Czech generic texts equal the server texts (contract 1.3)', () {
      final cs = lookupCs();
      expect(cs.notificationNewMessage, 'Nová zpráva');
      expect(cs.notificationNewGroupMessage, 'Nová zpráva ve skupině');
      expect(cs.notificationIncomingCall, 'Příchozí hovor');
      expect(cs.notificationNewChannelPost, 'Nový příspěvek v kanálu');
    });

    test('preview is cut at 120 characters without splitting an emoji', () {
      final long = '${'a' * 118}\u{1F600}\u{1F600}\u{1F600}';
      final cut = truncatePreview(long);
      expect(cut.runes.length, lessThanOrEqualTo(maxPreviewLength));
      expect(cut.endsWith('\u2026'), isTrue);
      expect(cut.contains('\u{1F600}'), isTrue);
      expect(truncatePreview('short'), 'short');
    });
  });

  test('notification ids are stable per conversation and kind', () {
    final a = notificationIdFor(NotificationKind.message, 'Peer-1');
    expect(a, notificationIdFor(NotificationKind.message, 'peer-1'));
    expect(a, notificationIdFor(NotificationKind.groupMessage, 'peer-1'));
    expect(
      a,
      isNot(notificationIdFor(NotificationKind.incomingCall, 'peer-1')),
    );
    expect(a, isNot(notificationIdFor(NotificationKind.message, 'peer-2')));
    expect(a, inInclusiveRange(0, 0x7fffffff));
  });
}

AppLocalizations lookupCs() => lookupAppLocalizations(const Locale('cs'));
