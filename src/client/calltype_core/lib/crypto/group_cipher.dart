import 'dart:convert';
import 'dart:typed_data';
import 'session_manager.dart';

/// Encrypts a separate pairwise envelope for each current group recipient.
class GroupCipher {
  GroupCipher({
    required SessionManager sessionManager,
    required Future<void> Function(String) ensureSession,
  }) : _sessions = sessionManager,
       _ensureSession = ensureSession;
  final SessionManager _sessions;
  final Future<void> Function(String) _ensureSession;

  Future<Map<String, Uint8List>> encryptForGroup(
    String groupId,
    List<String> memberDeviceIds,
    String plaintext,
  ) async {
    final payload = jsonDecode(plaintext) as Map<String, dynamic>;
    if (payload['groupId'] != groupId) {
      throw const FormatException(
        'Group context missing from encrypted payload',
      );
    }
    final result = <String, Uint8List>{};
    for (final member in memberDeviceIds.toSet()) {
      await _ensureSession(member);
      result[member] = Uint8List.fromList(
        utf8.encode(await _sessions.encryptMessage(member, plaintext)),
      );
    }
    return result;
  }

  Future<String> decryptGroupMessage(
    String groupId,
    String senderDeviceId,
    Uint8List ciphertext,
  ) async {
    final plaintext = await _sessions.decryptMessage(
      senderDeviceId,
      utf8.decode(ciphertext),
    );
    if ((jsonDecode(plaintext) as Map<String, dynamic>)['groupId'] != groupId) {
      throw const FormatException('Group context mismatch');
    }
    return plaintext;
  }
}
