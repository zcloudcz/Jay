// Deterministic pairwise session scenario for the protocol test vectors.
//
// The same runner both GENERATES `session_v2.json` (see
// generate_vectors.dart) and REPLAYS it (session_vectors_test.dart), so a
// replay proves byte for byte that the current code still produces exactly
// the recorded envelopes and session keys. Key material is fixed and every
// random draw (ephemeral keys, ratchet keys, AES-GCM nonces) is recorded in
// the order it is consumed, so another implementation can feed the same
// bytes and compare its own output.
import 'dart:convert';
import 'dart:io';

import 'package:calltype_core/crypto/key_manager.dart';
import 'package:calltype_core/crypto/session_manager.dart';
import 'package:calltype_core/crypto/signal_protocol.dart';
import 'package:calltype_core/storage/secret_store.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

/// Where the vectors live, relative to the package root (`dart test` and
/// `dart run` both run from there).
const vectorFile = 'test/vectors/session_v2.json';

/// Reads the active session state of [address] as the JSON map the
/// SessionManager persisted, or null.
typedef StateReader = Future<Map<String, dynamic>?> Function(String address);

/// Builds a SessionManager over some store for one device.
typedef DeviceFactory =
    Future<({SessionManager sessions, StateReader readState})> Function(
      KeyManager keys,
    );

/// Source of the bytes [SignalProtocol.testRandomBytes] hands out.
abstract class DrawSource {
  void beginStep(int index);
  List<int> take(int length);

  /// Draws of the current step as base64, in consumption order.
  List<String> endStep();
}

/// Generation: a counter-based DRBG, `SHA-256("jay-vectors-v1|<n>")`.
class GeneratingDraws implements DrawSource {
  int _counter = 0;
  final _step = <String>[];

  @override
  void beginStep(int index) => _step.clear();

  @override
  List<int> take(int length) {
    final out = <int>[];
    while (out.length < length) {
      out.addAll(
        sha256.convert(utf8.encode('jay-vectors-v1|${_counter++}')).bytes,
      );
    }
    final bytes = out.sublist(0, length);
    _step.add(base64Encode(bytes));
    return bytes;
  }

  @override
  List<String> endStep() => List.of(_step);
}

/// Replay: hands out exactly the recorded draws of each step.
class ReplayDraws implements DrawSource {
  ReplayDraws(this._steps);
  final List<dynamic> _steps;
  List<String> _queue = [];
  final _used = <String>[];

  @override
  void beginStep(int index) {
    final step = _steps[index] as Map<String, dynamic>;
    _queue = List.of((step['draws'] as List).cast<String>());
    _used.clear();
  }

  @override
  List<int> take(int length) {
    if (_queue.isEmpty) {
      throw StateError('The code consumed more random draws than recorded.');
    }
    final bytes = base64Decode(_queue.removeAt(0));
    if (bytes.length != length) {
      throw StateError(
        'Recorded draw has ${bytes.length} bytes, code wants '
        '$length.',
      );
    }
    _used.add(base64Encode(bytes));
    return bytes;
  }

  @override
  List<String> endStep() {
    if (_queue.isNotEmpty) {
      throw StateError('The code consumed fewer random draws than recorded.');
    }
    return List.of(_used);
  }
}

class _MapSecrets extends SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

List<int> _fixed(String label) =>
    sha256.convert(utf8.encode('jay-vector-v1|$label')).bytes;

Future<Map<String, String>> _x25519Pair(String label) async {
  final priv = _fixed(label);
  final pair = await X25519().newKeyPairFromSeed(priv);
  return {
    'privateKey': base64Encode(priv),
    'publicKey': base64Encode((await pair.extractPublicKey()).bytes),
  };
}

class _Device {
  _Device(this.name, this.deviceId, this.keys, this.sessions, this.readState);
  final String name;
  final String deviceId;
  final KeyManager keys;
  final SessionManager sessions;
  final StateReader readState;
}

/// Fixed long-term key material of one device, in the KeyManager's own
/// secret-store layout, plus the public description for the vector file.
Future<({_MapSecrets secrets, Map<String, dynamic> description})> _material(
  String name,
  String deviceId, {
  required int oneTimeCount,
}) async {
  final secrets = _MapSecrets();
  final identity = await _x25519Pair('$name|identity');
  final spk = await _x25519Pair('$name|signed-prekey');
  final signingSeed = _fixed('$name|signing');
  final signing = await Ed25519().newKeyPairFromSeed(signingSeed);
  final otks = <Map<String, dynamic>>[];
  for (var i = 1; i <= oneTimeCount; i++) {
    final pair = await _x25519Pair('$name|one-time-prekey|$i');
    otks.add({'keyId': i, ...pair});
  }
  secrets.values
    ..['ct_identity_public_key'] = identity['publicKey']!
    ..['ct_identity_private_key'] = identity['privateKey']!
    ..['ct_signed_prekey'] = jsonEncode({'keyId': 1, ...spk})
    ..['ct_one_time_prekeys'] = jsonEncode(otks)
    ..['ct_signing_seed'] = base64Encode(signingSeed);
  return (
    secrets: secrets,
    description: <String, dynamic>{
      'deviceId': deviceId,
      'identityKey': identity,
      'signedPreKey': {'keyId': 1, ...spk},
      'signingKey': {
        'seed': base64Encode(signingSeed),
        'publicKey': base64Encode((await signing.extractPublicKey()).bytes),
      },
      'oneTimePreKeys': otks,
    },
  );
}

Map<String, dynamic> _stateSummary(Map<String, dynamic> state) => {
  'sid': state['sid'],
  'rk': state['rk'],
  'dhsPub': state['dhsPub'],
  'dhr': state['dhr'],
  'cks': state['cks'],
  'ckr': state['ckr'],
  'ns': state['ns'],
  'nr': state['nr'],
  'pn': state['pn'],
  'skippedKeys': (state['skipped'] as Map).length,
  'pending': state['pending'] != null,
};

Future<List<int>> _hkdf(List<int> ikm, List<int> salt, String info, int n) =>
    SignalProtocol.deriveKey(ikm, salt, utf8.encode(info), n);

/// Runs the scenario. With [expected] (a loaded vector file), decrypt steps
/// read the RECORDED envelope instead of the one this run produced, so the
/// receive side is checked against the golden bytes independently.
Future<Map<String, dynamic>> runSessionScenario({
  required DeviceFactory factory,
  required DrawSource draws,
  Map<String, dynamic>? expected,
}) async {
  const aliceId = '00000000-0000-4000-8000-00000000000a';
  const bobId = '00000000-0000-4000-8000-00000000000b';
  final aliceMat = await _material('alice', aliceId, oneTimeCount: 0);
  final bobMat = await _material('bob', bobId, oneTimeCount: 2);

  Future<_Device> device(String name, String id, _MapSecrets secrets) async {
    final keys = KeyManager(secureStorage: secrets);
    final built = await factory(keys);
    return _Device(name, id, keys, built.sessions, built.readState);
  }

  final alice = await device('alice', aliceId, aliceMat.secrets);
  final bob = await device('bob', bobId, bobMat.secrets);
  _Device byName(String n) => n == 'alice' ? alice : bob;
  _Device peerOf(_Device d) => d == alice ? bob : alice;

  // The key bundle the server serves for Bob (one-time pre-key 1).
  final bobOtk = (bobMat.description['oneTimePreKeys'] as List).first as Map;
  final bobBundle = <String, dynamic>{
    ...await bob.keys.getSignedIdentityBundle(),
    'oneTimePreKey': {
      'keyId': bobOtk['keyId'],
      'publicKey': bobOtk['publicKey'],
    },
  };

  final steps = <Map<String, dynamic>>[];
  final envelopes = <String, String>{};
  final expectedSteps = expected?['steps'] as List<dynamic>?;

  Future<void> step(
    Map<String, dynamic> head,
    Future<Map<String, dynamic>> Function() body,
  ) async {
    final index = steps.length;
    draws.beginStep(index);
    SignalProtocol.testRandomBytes = draws.take;
    final Map<String, dynamic> out;
    try {
      out = await body();
    } finally {
      SignalProtocol.testRandomBytes = null;
    }
    steps.add({...head, 'draws': draws.endStep(), ...out});
  }

  Future<void> encrypt(String from, String label, String plaintext) =>
      step({'op': 'encrypt', 'by': from, 'label': label}, () async {
        final d = byName(from);
        final envelope = await d.sessions.encryptMessage(
          peerOf(d).deviceId,
          plaintext,
        );
        envelopes[label] = envelope;
        final state = await d.readState(peerOf(d).deviceId);
        return {
          'plaintext': plaintext,
          'envelope': envelope,
          'stateAfter': _stateSummary(state!),
        };
      });

  String recorded(String label) {
    if (expectedSteps == null) return envelopes[label]!;
    final source = expectedSteps.cast<Map<String, dynamic>>().firstWhere(
      (s) => s['op'] == 'encrypt' && s['label'] == label,
    );
    return source['envelope'] as String;
  }

  Future<void> decrypt(String to, String label) =>
      step({'op': 'decrypt', 'by': to, 'label': label}, () async {
        final d = byName(to);
        final envelope = recorded(label);
        final plaintext = await d.sessions.decryptMessage(
          peerOf(d).deviceId,
          envelope,
        );
        final state = await d.readState(peerOf(d).deviceId);
        return {'plaintext': plaintext, 'stateAfter': _stateSummary(state!)};
      });

  Future<void> rejectTampered(String to, String label, String field) => step(
    {'op': 'decrypt-rejects', 'by': to, 'label': label, 'tamper': field},
    () async {
      final d = byName(to);
      final envelope = jsonDecode(recorded(label)) as Map<String, dynamic>;
      envelope[field] = (envelope[field] as int) + 1;
      final tampered = jsonEncode(envelope);
      Object? error;
      try {
        await d.sessions.decryptMessage(peerOf(d).deviceId, tampered);
      } catch (e) {
        error = e;
      }
      if (error == null) {
        throw StateError('Tampered envelope $label was accepted.');
      }
      return {'envelope': tampered, 'rejected': true};
    },
  );

  // 1. Alice runs X3DH against Bob's bundle (draws: EK_a, first ratchet key).
  await step({'op': 'initiate', 'by': 'alice'}, () async {
    await alice.sessions.initiateSession(bobId, bobBundle);
    final state = await alice.readState(bobId);
    return {'stateAfter': _stateSummary(state!)};
  });

  // Reference X3DH computed here from the primitives, independently of
  // SessionManager, so the vector file states the intermediate values and
  // the replay fails if the implementation drifts from the documented steps.
  final initDraws = steps.first['draws'] as List;
  final ekPriv = initDraws[0] as String;
  final ratchetPriv = initDraws[1] as String;
  final ek = await X25519().newKeyPairFromSeed(base64Decode(ekPriv));
  final ekPub = base64Encode((await ek.extractPublicKey()).bytes);
  final aIk = aliceMat.description['identityKey'] as Map<String, String>;
  final bIk = bobMat.description['identityKey'] as Map<String, String>;
  final bSpk = bobMat.description['signedPreKey'] as Map<String, dynamic>;
  final dh1 = await SignalProtocol.keyAgreement(
    aIk['privateKey']!,
    bSpk['publicKey'] as String,
  );
  final dh2 = await SignalProtocol.keyAgreement(ekPriv, bIk['publicKey']!);
  final dh3 = await SignalProtocol.keyAgreement(
    ekPriv,
    bSpk['publicKey'] as String,
  );
  final dh4 = await SignalProtocol.keyAgreement(
    ekPriv,
    bobOtk['publicKey'] as String,
  );
  final sk = await _hkdf(
    [...List.filled(32, 0xFF), ...dh1, ...dh2, ...dh3, ...dh4],
    List.filled(32, 0),
    'CallType-X3DH-v1',
    32,
  );
  final firstDh = await SignalProtocol.keyAgreement(
    ratchetPriv,
    bSpk['publicKey'] as String,
  );
  final root = await _hkdf(firstDh, sk, 'CallType-DR-Root-v1', 64);
  final sid = sha256
      .convert(utf8.encode('CallType-session-v2|${aIk['publicKey']}|$ekPub'))
      .toString();
  final x3dh = <String, dynamic>{
    'ephemeralPublicKey': ekPub,
    'dh1': base64Encode(dh1),
    'dh2': base64Encode(dh2),
    'dh3': base64Encode(dh3),
    'dh4': base64Encode(dh4),
    'sk': base64Encode(sk),
    'firstRatchetDh': base64Encode(firstDh),
    'rootKey': base64Encode(root.sublist(0, 32)),
    'sendingChainKey': base64Encode(root.sublist(32)),
    'sid': sid,
  };
  final aliceInit = steps.first['stateAfter'] as Map<String, dynamic>;
  if (aliceInit['rk'] != x3dh['rootKey'] ||
      aliceInit['cks'] != x3dh['sendingChainKey'] ||
      aliceInit['sid'] != sid) {
    throw StateError('SessionManager disagrees with the reference X3DH.');
  }

  // 2. Two pre-key messages before Bob answers, then Bob reads both.
  await encrypt('alice', 'A0', 'Hello Bob, this is the first pre-key message.');
  await encrypt('alice', 'A1', 'A second pre-key message, same chain.');
  await decrypt('bob', 'A0');
  await decrypt('bob', 'A1');
  // 3. Bob answers three times (his first send = new ratchet key); Alice
  //    receives them out of order: B2 first stores the keys of B0 and B1.
  await encrypt('bob', 'B0', 'Bob reply 0');
  await encrypt('bob', 'B1', 'Bob reply 1 (umlaut \u00fc, emoji \u{1F600})');
  await encrypt('bob', 'B2', 'Bob reply 2');
  await decrypt('alice', 'B2');
  await decrypt('alice', 'B0');
  await decrypt('alice', 'B1');
  // 4. Alice's next message carries her NEW ratchet key and no prologue.
  await encrypt('alice', 'A2', 'Alice after the ratchet step.');
  await decrypt('bob', 'A2');
  // 5. Bob again rotates; a header tampered in pn or n is rejected (AAD),
  //    and the genuine message still decrypts afterwards.
  await encrypt('bob', 'B3', 'Bob after the second ratchet step.');
  await rejectTampered('alice', 'B3', 'pn');
  await rejectTampered('alice', 'B3', 'n');
  await decrypt('alice', 'B3');

  return {
    'description':
        'CallType pairwise session v2 (X3DH + Double Ratchet) test vectors. '
        'Generated by test/vectors/generate_vectors.dart from the Dart '
        'implementation. Keys and base64 are standard base64 with padding; '
        '"draws" are the random bytes the implementation consumed in that '
        'step, in order (X25519 private keys: 32 bytes, AES-GCM nonces: 12 '
        'bytes). See docs/protocol/.',
    'version': 1,
    'devices': {'alice': aliceMat.description, 'bob': bobMat.description},
    'bobBundle': bobBundle,
    'x3dh': x3dh,
    'steps': steps,
  };
}

/// Loads the committed vector file.
Map<String, dynamic> loadVectors() =>
    jsonDecode(File(vectorFile).readAsStringSync()) as Map<String, dynamic>;

/// Pretty JSON with a trailing newline, as committed.
String encodeVectors(Map<String, dynamic> v) =>
    '${const JsonEncoder.withIndent('  ').convert(v)}\n';
