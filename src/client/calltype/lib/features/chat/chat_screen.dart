import 'package:flutter/material.dart';

import 'message_bubble.dart';
import 'message_input.dart';

/// Full-screen chat view for a single conversation.
///
/// Shows messages in a reversed ListView (newest at bottom, scroll up for
/// history) with a message input bar pinned at the bottom. The AppBar
/// displays the contact name and action buttons for voice/video calls.
///
/// Currently uses placeholder sample messages. In Phase 4 this will read
/// from the local Drift database (decrypted messages) and receive new
/// messages via SignalR in real time.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.contactId});

  /// The device ID or conversation ID of the chat partner.
  final String contactId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  /// Local list of messages for this placeholder implementation.
  /// Will be replaced by a Drift query stream in Phase 4.
  final List<_SampleMessage> _messages = List.of(_placeholderMessages);

  void _handleSend(String text) {
    setState(() {
      _messages.insert(
        0,
        _SampleMessage(
          text: text,
          time: '${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}',
          isMine: true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Derive a display name from the contact ID. In the real app this
    // will come from the Contacts table in the local database.
    final contactName = 'Contact ${widget.contactId}';

    return Scaffold(
      appBar: AppBar(
        title: Text(contactName),
        actions: [
          // Voice call — will trigger WebRTC offer flow in Phase 6.
          IconButton(
            icon: const Icon(Icons.call_rounded),
            tooltip: 'Voice call',
            onPressed: () {
              // TODO: Initiate WebRTC voice call in Phase 6.
            },
          ),
          // Video call — same WebRTC flow but with video track enabled.
          IconButton(
            icon: const Icon(Icons.videocam_rounded),
            tooltip: 'Video call',
            onPressed: () {
              // TODO: Initiate WebRTC video call in Phase 6.
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Message list fills available space. Using Expanded ensures
          // the input bar stays at the bottom even with few messages.
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text('No messages yet. Say hello!'),
                  )
                : ListView.builder(
                    // Reversed so new messages appear at the bottom and
                    // the list auto-scrolls to show them. This is the
                    // standard pattern for chat UIs in Flutter.
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      return MessageBubble(
                        text: msg.text,
                        time: msg.time,
                        isMine: msg.isMine,
                      );
                    },
                  ),
          ),
          // Input bar pinned at bottom of the screen.
          MessageInput(onSend: _handleSend),
        ],
      ),
    );
  }
}

/// Placeholder message data for visual development.
class _SampleMessage {
  const _SampleMessage({
    required this.text,
    required this.time,
    required this.isMine,
  });

  final String text;
  final String time;
  final bool isMine;
}

/// Sample messages to show in the chat view during development.
/// Listed in reverse chronological order (newest first) because the
/// ListView is reversed.
const _placeholderMessages = [
  _SampleMessage(text: 'See you then!', time: '10:32', isMine: true),
  _SampleMessage(text: 'Sure, let\'s meet at 3pm.', time: '10:31', isMine: false),
  _SampleMessage(text: 'Are you free this afternoon?', time: '10:30', isMine: true),
  _SampleMessage(text: 'Hey, how are you?', time: '10:28', isMine: false),
];
