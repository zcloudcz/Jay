# Multi-device sync, plan 1 of 2: protocol (core + server + live E2E)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A device can sign a list of its companion devices, the server stores and serves that list and fans messages out to every device of both identities, and a live E2E test proves it with three real devices.

**Architecture:** Trust lives in a device list signed by the primary device's Ed25519 signing key (already pinned by peers). The server only stores the signed bytes and uses the device IDs for routing; it can cause an outage, never add a reader. All protocol logic is in `calltype_core` so the Flutter app (plan 2) and the bots share it.

**Tech Stack:** Dart (`cryptography`, drift), ASP.NET Core 10 minimal API + SignalR, EF Core/Npgsql, xUnit + Testcontainers, `package:test`.

**Spec:** `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`. Plan 2 wires this into the Flutter app and the bot runtime; it is written after this plan lands, against the real core API (scope at the end of this file).

**Rules for every task**
- Branch `feat/multi-device-sync`. Start with `git log --oneline -1` and make sure the spec commit is in the history.
- Comments explain WHY (project rule). Never rename existing `CallType-*` strings in `calltype_core/lib/crypto`.
- No U+2014 dash anywhere in new text.
- Minimal diff: change only what the task names. Anything else: mention, do not change.
- Server tests need Docker and must run sequentially (one `dotnet test` at a time).
- `database.g.dart` is git-ignored: after touching `tables.dart` / `database.dart` run `dart run build_runner build --delete-conflicting-outputs` in `src/client/calltype_core`.

## Deviations from the spec, decided while planning

1. **Two hub methods instead of one with nullable arguments.** The Dart hub transport takes `List<Object>` and cannot send `null`: `SendReliableDirectFanout` and `SendReliableGroupFanout`.
2. **`allRecipients` argument.** A 256 KB attachment for three devices does not fit in the hub's 1 MiB frame. Each call therefore carries the full set of target device IDs (completeness is checked on that set) and may carry only a part of the payloads. One call is one transaction; a split send is not atomic, exactly like group attachments today.
3. **`device_list_stale:<ids>`.** The error carries the device IDs the server requires. The client sends to the intersection of `required` and its verified devices; it refuses when `required` contains a device it cannot verify. That also covers a companion that deleted itself (still in the signed list, gone on the server).
4. **Business groups reject the new method** (`fanout_unsupported_in_business_group`). Clients keep using `SendReliableGroupMessage` there (primary device only, per spec).
5. **A companion pins its primary from the primary's key bundle**, not from the list (the list contains companions only). It needs a session with the primary anyway.
6. **Server-side consent gate (found in Task 1 review).** The server does not verify signatures, so without a gate any user could upload a list naming somebody else's device; clients would reject the list, but the server would route that device as the uploader's and the victim could no longer send (DoS). The companion's authenticated `LinkConsent` hub call is therefore recorded (memory cache, 10 minutes; the API is a single instance by design) and PUT accepts a NEW companion only with that record.
7. **`assertListedKeys` fails closed** when the device has no pinned keys (found in Task 1 review). Consent only proves that the key written in the entry agreed; the binding to the real device is the comparison with the pinned keys, so "nothing pinned" must not pass. Both session paths pin (`initiateSession`, and `decryptMessage` for a pre-key message), so callers always call it after a session exists.
8. **`DeviceDirectory.refresh` refuses hijacking lists (found in Task 6 review; the plan's code was vulnerable).** A list is accepted only if it concerns the device that was asked about (`unrelated_list`); a list naming OUR device must carry our own keys (`self_not_consented`, consent alone is signed with a key the list author chooses); a list may not claim a device already attributed to another identity or a known primary (`device_claimed_by_other_identity`); refreshes are serialized and the version is re-checked inside the write transaction. The constructor therefore also takes `selfIdentityKey`. The code in the repo (commit "fix(core): device directory refuses hijacking lists") supersedes the Task 6 code below.
9. **`FanoutSender` owns session setup and refreshes lazily (found in Task 7 review).** It compares a companion's key bundle with the signed entry BEFORE creating a session (a pin cannot be taken back), tolerates one identity's failed refresh in `encrypt` (keeps its stored verified list), and refreshes in `encrypt` only identities without a stored list; changes arrive through `device_list_stale` -> `reconcile`, which re-reads the lists on EVERY stale answer (also when it only drops devices, so a removal takes effect on our side). Constructor: `FanoutSender({directory, sessions, apiClient})`. The code in the repo supersedes the Task 7 code below.

## File map

| File | Responsibility |
|---|---|
| `src/client/calltype_core/lib/crypto/device_list.dart` (new) | Signed list + consent: encode, sign, verify. Pure functions. |
| `src/client/calltype_core/lib/crypto/key_manager.dart` | Expose the signing key pair. |
| `src/client/calltype_core/lib/storage/tables.dart`, `database.dart` | Local schema v5: verified lists and device to identity map. |
| `src/client/calltype_core/lib/network/api_client.dart` | `getDeviceList`, `putDeviceList`. |
| `src/client/calltype_core/lib/network/signalr_client.dart` | Fan-out sends, link relay, new event streams. |
| `src/client/calltype_core/lib/devices/device_directory.dart` (new) | Verified lists on this device: refresh, identity lookup, fan-out targets, inbound routing. |
| `src/client/calltype_core/lib/devices/fanout_sender.dart` (new) | Encrypt per device, reconcile after `device_list_stale`. |
| `src/server/CallType.Api/Models/DeviceList.cs` (new) | `DeviceList`, `DeviceListMember` entities. |
| `src/server/CallType.Api/Services/DeviceListService.cs` (new) | Identity and device lookups for routing. |
| `src/server/CallType.Api/Endpoints/DeviceListEndpoints.cs` (new) | PUT / GET device list. |
| `src/server/CallType.Api/Hubs/MessengerHub.cs` | Fan-out methods, link relay. |
| `src/server/CallType.Api/Endpoints/PrivacyEndpoints.cs` | Export includes device lists. |
| `src/bots/jay_archiver/test/e2e/multi_device_e2e_test.dart` (new) | Live proof with three devices. |

---

### Task 1: Core - signed device list codec

**Files:**
- Create: `src/client/calltype_core/lib/crypto/device_list.dart`
- Modify: `src/client/calltype_core/lib/crypto/key_manager.dart:34-56`
- Test: `src/client/calltype_core/test/crypto/device_list_test.dart`

- [ ] **Step 1: Expose the signing key pair in `KeyManager`**

Replace the body of `getSignedIdentityBundle` so the seed handling lives in one new method (behaviour unchanged):

```dart
  /// The device's Ed25519 signing key pair. Besides the signed identity
  /// bundle it signs the device list (multi-device) and a companion's link
  /// consent. Peers pin its public half as part of `peer_identity:<id>`.
  Future<SimpleKeyPair> getSigningKeyPair() async {
    final algorithm = Ed25519();
    var seed = await _secureStorage.read('ct_signing_seed');
    if (seed == null) {
      final generated = await algorithm.newKeyPair();
      seed = base64Encode(await generated.extractPrivateKeyBytes());
      await _secureStorage.write('ct_signing_seed', seed);
    }
    return algorithm.newKeyPairFromSeed(base64Decode(seed));
  }

  Future<Map<String, String>> getSignedIdentityBundle() async {
    final signing = await getSigningKeyPair();
    final identityKey = await getPublicIdentityKey();
    final signedPreKey =
        (await getOrCreateSignedPreKey())['publicKey'] as String;
    final signature = await Ed25519().sign(
      signedIdentityPayload(identityKey, signedPreKey),
      keyPair: signing,
    );
    return {
      'identityKey': identityKey,
      'signedPreKey': signedPreKey,
      'signingKey': base64Encode((await signing.extractPublicKey()).bytes),
      'signature': base64Encode(signature.bytes),
    };
  }
```

Run: `cd src/client/calltype_core && dart test test/crypto` - Expected: all existing tests PASS.

- [ ] **Step 2: Write the failing tests**

`test/crypto/device_list_test.dart`:

```dart
import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

const primaryId = '11111111-1111-4111-8111-111111111111';
const companionId = '22222222-2222-4222-8222-222222222222';
const strangerId = '33333333-3333-4333-8333-333333333333';

Future<String> publicKeyOf(SimpleKeyPair pair) async =>
    base64Encode((await pair.extractPublicKey()).bytes);

void main() {
  late SimpleKeyPair primary;
  late SimpleKeyPair companion;
  late String primaryKey;

  setUp(() async {
    primary = await Ed25519().newKeyPair();
    companion = await Ed25519().newKeyPair();
    primaryKey = await publicKeyOf(primary);
  });

  Future<DeviceListEntry> entry({
    String deviceId = companionId,
    String consentFor = primaryId,
  }) async => DeviceListEntry(
    deviceId: deviceId,
    identityKey: base64Encode(List.filled(32, 7)),
    signingKey: await publicKeyOf(companion),
    consentSig: await signDeviceLinkConsent(
      companionSigningKey: companion,
      primaryDeviceId: consentFor,
      companionDeviceId: deviceId,
    ),
  );

  Future<SignedDeviceList> signed(List<DeviceListEntry> devices, {int version = 1}) =>
      signDeviceList(
        primarySigningKey: primary,
        list: DeviceList(primaryDeviceId: primaryId, version: version, devices: devices),
      );

  Future<DeviceList> verify(SignedDeviceList list, {int minVersion = 1}) =>
      verifyDeviceList(
        signed: list,
        primarySigningKey: primaryKey,
        expectedPrimaryDeviceId: primaryId,
        minVersion: minVersion,
      );

  test('a signed list round-trips and exposes every device', () async {
    final list = await verify(await signed([await entry()]));
    expect(list.version, 1);
    expect(list.allDeviceIds, [primaryId, companionId]);
  });

  test('one flipped payload byte fails verification', () async {
    final good = await signed([await entry()]);
    final bytes = base64Decode(good.payload);
    bytes[bytes.length - 2] ^= 1;
    expect(
      verify(SignedDeviceList(base64Encode(bytes), good.signature)),
      throwsA(isA<DeviceListException>()),
    );
  });

  test('a list signed by another key is rejected', () async {
    final good = await signed([await entry()]);
    expect(
      verifyDeviceList(
        signed: good,
        primarySigningKey: await publicKeyOf(companion),
        expectedPrimaryDeviceId: primaryId,
      ),
      throwsA(isA<DeviceListException>()),
    );
  });

  test('a list for another primary is rejected', () async {
    final good = await signed([await entry()]);
    expect(
      verifyDeviceList(
        signed: good,
        primarySigningKey: primaryKey,
        expectedPrimaryDeviceId: strangerId,
      ),
      throwsA(isA<DeviceListException>()),
    );
  });

  test('a replayed lower version is rejected', () async {
    final old = await signed([await entry()], version: 2);
    expect(verify(old, minVersion: 3), throwsA(isA<DeviceListException>()));
  });

  test('a device that consented to a different primary is rejected', () async {
    // Without this check a user could list a stranger's device and the
    // stranger's messages would be shown to peers as the user's own.
    final list = await signed([await entry(consentFor: strangerId)]);
    expect(verify(list), throwsA(isA<DeviceListException>()));
  });

  test('more than five companions, duplicates and self-listing are rejected', () async {
    final six = [
      for (var i = 0; i < 6; i++)
        await entry(deviceId: '4444444$i-4444-4444-8444-444444444444'),
    ];
    expect(verify(await signed(six)), throwsA(isA<DeviceListException>()));
    final twice = [await entry(), await entry()];
    expect(verify(await signed(twice)), throwsA(isA<DeviceListException>()));
    final self = [await entry(deviceId: primaryId)];
    expect(verify(await signed(self)), throwsA(isA<DeviceListException>()));
  });

  test('a consent signature does not verify as a list signature', () async {
    // Domain separation: the two signatures must never be interchangeable.
    final consent = (await entry()).consentSig;
    final good = await signed([]);
    expect(
      verify(SignedDeviceList(good.payload, consent)),
      throwsA(isA<DeviceListException>()),
    );
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd src/client/calltype_core && dart test test/crypto/device_list_test.dart`
Expected: FAIL, `device_list.dart` does not exist.

- [ ] **Step 4: Implement `lib/crypto/device_list.dart`**

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Multi-device trust: the list of companion devices an identity vouches for.
///
/// WHY it exists: fan-out to several devices needs somebody to say "this is
/// also my device". If the server said it, the server could add a reader.
/// So the PRIMARY device signs the list with its Ed25519 signing key, which
/// peers already pin (`peer_identity:<deviceId>`), and every client verifies
/// before encrypting for any listed device.
///
/// WHY the signature covers the exact stored bytes: there is then no JSON
/// canonicalization to get wrong. Verify first, parse second.

/// Protocol domain separators. Like the other `CallType-*` strings in this
/// folder they must never be renamed: every existing list would stop verifying.
const _listDomain = 'CallType-DeviceList-v1\u0000';
const _consentDomain = 'CallType-DeviceLink-v1\u0000';

const maxCompanionDevices = 5;

class DeviceListException implements Exception {
  const DeviceListException(this.reason);
  final String reason;
  @override
  String toString() => 'DeviceListException: $reason';
}

class DeviceListEntry {
  const DeviceListEntry({
    required this.deviceId,
    required this.identityKey,
    required this.signingKey,
    required this.consentSig,
  });

  final String deviceId;

  /// X25519 identity key and Ed25519 signing key of the companion (base64).
  /// Listing them stops the server from swapping the companion's key bundle.
  final String identityKey;
  final String signingKey;

  /// The companion's own signature over (primary, companion): proof it agreed.
  final String consentSig;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'identityKey': identityKey,
    'signingKey': signingKey,
    'consentSig': consentSig,
  };
}

class DeviceList {
  const DeviceList({
    required this.primaryDeviceId,
    required this.version,
    required this.devices,
  });

  final String primaryDeviceId;
  final int version;

  /// Companions only. The primary is implicit.
  final List<DeviceListEntry> devices;

  List<String> get allDeviceIds => [
    primaryDeviceId,
    ...devices.map((d) => d.deviceId),
  ];
}

/// The list as it travels and is stored: base64 payload + base64 signature.
class SignedDeviceList {
  const SignedDeviceList(this.payload, this.signature);
  final String payload;
  final String signature;
}

Uint8List _uuidBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) throw const DeviceListException('bad_device_id');
  try {
    return Uint8List.fromList([
      for (var i = 0; i < 32; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  } on FormatException {
    throw const DeviceListException('bad_device_id');
  }
}

List<int> _consentMessage(String primaryDeviceId, String companionDeviceId) => [
  ...utf8.encode(_consentDomain),
  ..._uuidBytes(primaryDeviceId),
  ..._uuidBytes(companionDeviceId),
];

/// Called on the COMPANION: "I agree to be a device of [primaryDeviceId]".
Future<String> signDeviceLinkConsent({
  required SimpleKeyPair companionSigningKey,
  required String primaryDeviceId,
  required String companionDeviceId,
}) async => base64Encode(
  (await Ed25519().sign(
    _consentMessage(primaryDeviceId, companionDeviceId),
    keyPair: companionSigningKey,
  )).bytes,
);

Future<bool> verifyDeviceLinkConsent({
  required String consentSig,
  required String companionSigningKey,
  required String primaryDeviceId,
  required String companionDeviceId,
}) async {
  try {
    final key = base64Decode(companionSigningKey);
    final signature = base64Decode(consentSig);
    if (key.length != 32 || signature.length != 64) return false;
    return Ed25519().verify(
      _consentMessage(primaryDeviceId, companionDeviceId),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  }
}

/// Called on the PRIMARY.
Future<SignedDeviceList> signDeviceList({
  required SimpleKeyPair primarySigningKey,
  required DeviceList list,
}) async {
  final payload = utf8.encode(
    jsonEncode({
      'primaryDeviceId': list.primaryDeviceId,
      'version': list.version,
      'devices': [for (final d in list.devices) d.toJson()],
    }),
  );
  final signature = await Ed25519().sign([
    ...utf8.encode(_listDomain),
    ...payload,
  ], keyPair: primarySigningKey);
  return SignedDeviceList(base64Encode(payload), base64Encode(signature.bytes));
}

/// Parses a payload WITHOUT verifying it. Only for bytes that were verified
/// before they were stored (see DeviceDirectory).
DeviceList parseDeviceListPayload(String payload) {
  try {
    final json = jsonDecode(utf8.decode(base64Decode(payload)));
    if (json is! Map<String, dynamic>) {
      throw const DeviceListException('malformed');
    }
    return DeviceList(
      primaryDeviceId: (json['primaryDeviceId'] as String).toLowerCase(),
      version: json['version'] as int,
      devices: [
        for (final d in json['devices'] as List)
          DeviceListEntry(
            deviceId: ((d as Map)['deviceId'] as String).toLowerCase(),
            identityKey: d['identityKey'] as String,
            signingKey: d['signingKey'] as String,
            consentSig: d['consentSig'] as String,
          ),
      ],
    );
  } on DeviceListException {
    rethrow;
  } catch (_) {
    // FormatException, TypeError on a wrong shape: all the same to a caller.
    throw const DeviceListException('malformed');
  }
}

/// Verifies signature, owner, version floor, size and every consent.
/// [minVersion] is "highest version already accepted + 1" (1 for a first
/// list): a lower one is a replay of a list with a removed device.
Future<DeviceList> verifyDeviceList({
  required SignedDeviceList signed,
  required String primarySigningKey,
  required String expectedPrimaryDeviceId,
  int minVersion = 1,
}) async {
  late final List<int> payload;
  late final List<int> signature;
  late final List<int> key;
  try {
    payload = base64Decode(signed.payload);
    signature = base64Decode(signed.signature);
    key = base64Decode(primarySigningKey);
  } on FormatException {
    throw const DeviceListException('malformed');
  }
  if (signature.length != 64 || key.length != 32) {
    throw const DeviceListException('malformed');
  }
  final valid = await Ed25519().verify(
    [...utf8.encode(_listDomain), ...payload],
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
    ),
  );
  if (!valid) throw const DeviceListException('bad_signature');

  final list = parseDeviceListPayload(signed.payload);
  if (list.primaryDeviceId != expectedPrimaryDeviceId.toLowerCase()) {
    throw const DeviceListException('wrong_primary');
  }
  if (list.version < minVersion) throw const DeviceListException('rollback');
  if (list.devices.length > maxCompanionDevices) {
    throw const DeviceListException('too_many_devices');
  }
  final ids = list.devices.map((d) => d.deviceId).toSet();
  if (ids.length != list.devices.length ||
      ids.contains(list.primaryDeviceId)) {
    throw const DeviceListException('duplicate_device');
  }
  for (final device in list.devices) {
    final consented = await verifyDeviceLinkConsent(
      consentSig: device.consentSig,
      companionSigningKey: device.signingKey,
      primaryDeviceId: list.primaryDeviceId,
      companionDeviceId: device.deviceId,
    );
    if (!consented) throw const DeviceListException('missing_consent');
  }
  return list;
}
```

- [ ] **Step 5: Run the tests**

Run: `cd src/client/calltype_core && dart test test/crypto`
Expected: PASS (new file and all existing crypto tests).

- [ ] **Step 6: Commit**

```bash
git add src/client/calltype_core/lib/crypto src/client/calltype_core/test/crypto/device_list_test.dart
git commit -m "feat(core): signed device list and link consent"
```

---

### Task 2: Server - device list storage and endpoints

**Files:**
- Create: `src/server/CallType.Api/Models/DeviceList.cs`
- Create: `src/server/CallType.Api/Services/DeviceListService.cs`
- Create: `src/server/CallType.Api/Endpoints/DeviceListEndpoints.cs`
- Modify: `src/server/CallType.Api/Data/AppDbContext.cs`, `src/server/CallType.Api/Program.cs`, `src/server/CallType.Api/Hubs/MessengerHub.cs`
- Test: `src/server/CallType.Api.Tests/Endpoints/DeviceListEndpointsTests.cs`

- [ ] **Step 1: Write the failing tests**

`DeviceListEndpointsTests.cs` (the server never verifies signatures, so the tests use arbitrary 64 signature bytes):

```csharp
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Endpoints;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Endpoints;

public class DeviceListEndpointsTests : IntegrationTestBase
{
    private static readonly string Signature = Convert.ToBase64String(new byte[64]);

    private static object Body(Guid primary, int version, params Guid[] companions) => new
    {
        payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            primaryDeviceId = primary,
            version,
            devices = companions.Select(c => new { deviceId = c, identityKey = "a", signingKey = "b", consentSig = "c" })
        }))),
        signature = Signature
    };

    private HttpClient As(string token)
    {
        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>What MessengerHub.LinkConsent records when the companion consents.</summary>
    private void Consent(Guid companion, Guid primary) =>
        Factory.Services.GetRequiredService<IMemoryCache>()
            .Set(DeviceListEndpoints.ConsentKey(companion, primary), true, TimeSpan.FromMinutes(10));

    [Fact]
    public async Task Primary_stores_a_list_and_both_devices_read_the_same_bytes()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        var body = Body(primary.DeviceId, 1, companion.DeviceId);
        Consent(companion.DeviceId, primary.DeviceId);

        var put = await As(primary.Token).PutAsJsonAsync($"/devices/{primary.DeviceId}/device-list", body);
        put.StatusCode.Should().Be(HttpStatusCode.NoContent);

        foreach (var id in new[] { primary.DeviceId, companion.DeviceId })
        {
            var json = await As(companion.Token).GetFromJsonAsync<JsonElement>($"/devices/{id}/device-list");
            json.GetProperty("primaryDeviceId").GetGuid().Should().Be(primary.DeviceId);
            json.GetProperty("version").GetInt32().Should().Be(1);
            json.GetProperty("payload").GetString().Should().Be(
                JsonSerializer.SerializeToElement(body).GetProperty("payload").GetString());
        }
    }

    [Fact]
    public async Task Only_the_primary_itself_may_write_its_list()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        var put = await As(other.Token).PutAsJsonAsync(
            $"/devices/{primary.DeviceId}/device-list", Body(primary.DeviceId, 1, other.DeviceId));
        put.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Version_must_grow()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";
        Consent(companion.DeviceId, primary.DeviceId);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 2, companion.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 2)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        // Removing the companion with a higher version works and frees it.
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 3)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        (await db.DeviceListMembers.AnyAsync()).Should().BeFalse();
    }

    [Fact]
    public async Task A_device_belongs_to_at_most_one_identity()
    {
        var a = await RegisterAndAuthenticateAsync();
        var b = await RegisterAndAuthenticateAsync();
        var shared = await RegisterAndAuthenticateAsync();
        // Consents everywhere, so every 409 below comes from the membership rule.
        Consent(shared.DeviceId, a.DeviceId);
        Consent(shared.DeviceId, b.DeviceId);
        Consent(a.DeviceId, b.DeviceId);
        Consent(b.DeviceId, shared.DeviceId);
        (await As(a.Token).PutAsJsonAsync($"/devices/{a.DeviceId}/device-list", Body(a.DeviceId, 1, shared.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        // Already somebody's companion.
        (await As(b.Token).PutAsJsonAsync($"/devices/{b.DeviceId}/device-list", Body(b.DeviceId, 1, shared.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        // A primary with companions cannot become a companion.
        (await As(b.Token).PutAsJsonAsync($"/devices/{b.DeviceId}/device-list", Body(b.DeviceId, 1, a.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        // A companion cannot start a list of its own.
        (await As(shared.Token).PutAsJsonAsync($"/devices/{shared.DeviceId}/device-list", Body(shared.DeviceId, 1, b.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
    }

    [Fact]
    public async Task Malformed_oversized_and_unknown_members_are_rejected()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";
        (await client.PutAsJsonAsync(url, new { payload = "!!", signature = Signature }))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await client.PutAsJsonAsync(url, Body(Guid.NewGuid(), 1)))
            .StatusCode.Should().Be(HttpStatusCode.BadRequest);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, Guid.NewGuid())))
            .StatusCode.Should().Be(HttpStatusCode.Conflict);
        var six = new List<Guid>();
        for (var i = 0; i < 6; i++) six.Add((await RegisterAndAuthenticateAsync()).DeviceId);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, six.ToArray())))
            .StatusCode.Should().Be(HttpStatusCode.UnprocessableEntity);
    }

    [Fact]
    public async Task A_new_companion_needs_its_own_consent_but_an_existing_one_does_not()
    {
        // Without this gate anybody could upload a list naming a victim's
        // device: clients reject the list, but the server would route the
        // victim as the uploader's device and the victim could not send.
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        var client = As(primary.Token);
        var url = $"/devices/{primary.DeviceId}/device-list";

        var refused = await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, companion.DeviceId));
        refused.StatusCode.Should().Be(HttpStatusCode.Conflict);
        (await refused.Content.ReadAsStringAsync()).Should().Contain("device_list_consent_missing");

        Consent(companion.DeviceId, primary.DeviceId);
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 1, companion.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        // The record is consumed, and a device already in the list needs none.
        (await client.PutAsJsonAsync(url, Body(primary.DeviceId, 2, companion.DeviceId)))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
    }

    [Fact]
    public async Task No_list_is_404_and_deleting_devices_cleans_up()
    {
        var primary = await RegisterAndAuthenticateAsync();
        var companion = await RegisterAndAuthenticateAsync();
        (await As(primary.Token).GetAsync($"/devices/{primary.DeviceId}/device-list"))
            .StatusCode.Should().Be(HttpStatusCode.NotFound);
        Consent(companion.DeviceId, primary.DeviceId);
        await As(primary.Token).PutAsJsonAsync(
            $"/devices/{primary.DeviceId}/device-list", Body(primary.DeviceId, 1, companion.DeviceId));

        // GDPR delete of the companion removes its routing row (FK cascade).
        (await As(companion.Token).DeleteAsync($"/devices/{companion.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            (await db.DeviceListMembers.AnyAsync()).Should().BeFalse();
            (await db.DeviceLists.AnyAsync()).Should().BeTrue();
        }
        // GDPR delete of the primary removes the list.
        (await As(primary.Token).DeleteAsync($"/devices/{primary.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.NoContent);
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            (await db.DeviceLists.AnyAsync()).Should().BeFalse();
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~DeviceListEndpointsTests`
Expected: build FAIL (`DeviceListMembers` does not exist).

- [ ] **Step 3: Entities**

`Models/DeviceList.cs`:

```csharp
// ---------------------------------------------------------------------------
// DeviceList.cs - multi-device: the signed list of an identity's companions
// ---------------------------------------------------------------------------
// The server is storage and routing only. Payload + Signature are the exact
// bytes the primary device signed; clients verify them, the server never
// does and is never trusted to. DeviceListMember is derived from the payload
// on every write and exists purely so the hub can answer "which devices
// belong to this identity" without parsing JSON on the hot path.
// ---------------------------------------------------------------------------

namespace CallType.Api.Models;

public class DeviceList
{
    public Guid PrimaryDeviceId { get; set; }

    /// <summary>Only grows. Also the EF concurrency token (two writers race, one gets 409).</summary>
    public int Version { get; set; }

    public byte[] Payload { get; set; } = [];
    public byte[] Signature { get; set; } = [];
    public DateTimeOffset UpdatedAt { get; set; }

    public List<DeviceListMember> Members { get; set; } = [];
}

public class DeviceListMember
{
    /// <summary>Primary key: a device is a companion of at most one identity.</summary>
    public Guid DeviceId { get; set; }

    public Guid PrimaryDeviceId { get; set; }
}
```

In `AppDbContext.cs` add the two `DbSet`s next to the others:

```csharp
    public DbSet<DeviceList> DeviceLists => Set<DeviceList>();
    public DbSet<DeviceListMember> DeviceListMembers => Set<DeviceListMember>();
```

and, in `OnModelCreating` after the `AccountDevice` block:

```csharp
        // -----------------------------------------------------------------
        // DeviceList / DeviceListMember - multi-device routing
        // -----------------------------------------------------------------
        // Cascades are DB-level on purpose: PrivacyEndpoints deletes a Device
        // with raw SQL, and a deleted companion must disappear from routing
        // (a deleted primary takes the whole list with it).
        modelBuilder.Entity<DeviceList>(entity =>
        {
            entity.HasKey(l => l.PrimaryDeviceId);
            entity.Property(l => l.Version).IsConcurrencyToken();
            entity.HasOne<Device>()
                  .WithOne()
                  .HasForeignKey<DeviceList>(l => l.PrimaryDeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<DeviceListMember>(entity =>
        {
            entity.HasKey(m => m.DeviceId);
            entity.HasIndex(m => m.PrimaryDeviceId);
            entity.HasOne<Device>()
                  .WithOne()
                  .HasForeignKey<DeviceListMember>(m => m.DeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
            entity.HasOne<DeviceList>()
                  .WithMany(l => l.Members)
                  .HasForeignKey(m => m.PrimaryDeviceId)
                  .OnDelete(DeleteBehavior.Cascade);
        });
```

- [ ] **Step 4: Lookup service**

`Services/DeviceListService.cs`:

```csharp
using Microsoft.EntityFrameworkCore;
using CallType.Api.Data;

namespace CallType.Api.Services;

/// <summary>
/// Routing lookups over device lists. "Identity" = primary device ID; a
/// device that is in no list is its own identity.
/// </summary>
public class DeviceListService(AppDbContext db)
{
    public async Task<Guid> PrimaryOfAsync(Guid deviceId, CancellationToken ct) =>
        await db.DeviceListMembers.Where(m => m.DeviceId == deviceId)
            .Select(m => (Guid?)m.PrimaryDeviceId).FirstOrDefaultAsync(ct) ?? deviceId;

    /// <summary>
    /// Every device of the given identities: the primaries themselves plus
    /// their companions. A companion that deleted itself is already gone here
    /// (FK cascade), which is what lets a sender drop it without a new list.
    /// </summary>
    public async Task<HashSet<Guid>> DevicesOfAsync(IReadOnlyCollection<Guid> primaryIds, CancellationToken ct)
    {
        var devices = primaryIds.ToHashSet();
        devices.UnionWith(await db.DeviceListMembers
            .Where(m => primaryIds.Contains(m.PrimaryDeviceId))
            .Select(m => m.DeviceId).ToListAsync(ct));
        return devices;
    }
}
```

Register it in `Program.cs` next to `MessageQueueService`:

```csharp
builder.Services.AddScoped<DeviceListService>();
```

- [ ] **Step 5: Let endpoints reach online connections**

In `MessengerHub.cs`, right under the `OnlineDevices` field:

```csharp
    /// <summary>
    /// Lets REST endpoints push an event to a device that is connected right
    /// now (device list changes). Read-only view of the connection map.
    /// </summary>
    internal static bool TryGetConnection(Guid deviceId, out string connectionId) =>
        OnlineDevices.TryGetValue(deviceId, out connectionId!);
```

- [ ] **Step 6: Endpoints**

`Endpoints/DeviceListEndpoints.cs`:

```csharp
// ---------------------------------------------------------------------------
// DeviceListEndpoints.cs - multi-device: store and serve signed device lists
// ---------------------------------------------------------------------------
// PUT /devices/{primaryId}/device-list - the primary uploads a new version.
// GET /devices/{id}/device-list        - anyone fetches the list an id is in.
//
// The server checks shape and bookkeeping only (who may write, version grows,
// a device is in one list). It does NOT verify the signature: clients do,
// against a key they pinned themselves. A server that lies here can cause
// failed sends, never an extra reader.
// ---------------------------------------------------------------------------

using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.SignalR;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;
using Npgsql;
using CallType.Api.Data;
using CallType.Api.Hubs;
using CallType.Api.Models;

namespace CallType.Api.Endpoints;

public static class DeviceListEndpoints
{
    /// <summary>Mirrors maxCompanionDevices in calltype_core/lib/crypto/device_list.dart.</summary>
    private const int MaxCompanions = 5;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Cache key written by MessengerHub.LinkConsent: the companion itself,
    /// authenticated, said "I join this primary". In memory on purpose: the
    /// API is exactly one instance and linking is interactive (minutes).
    /// </summary>
    internal static string ConsentKey(Guid companion, Guid primary) => $"link-consent:{companion}:{primary}";

    public static WebApplication MapDeviceListEndpoints(this WebApplication app)
    {
        app.MapPut("/devices/{primaryId:guid}/device-list", PutDeviceList).RequireAuthorization().RequireRateLimiting("api");
        app.MapGet("/devices/{id:guid}/device-list", GetDeviceList).RequireAuthorization().RequireRateLimiting("api");
        return app;
    }

    private static IResult Bad(string error) => Results.BadRequest(new { error });
    private static IResult Conflict(string error) => Results.Conflict(new { error });

    private static async Task<IResult> PutDeviceList(
        Guid primaryId, PutDeviceListRequest request, ClaimsPrincipal user,
        AppDbContext db, IHubContext<MessengerHub> hub, IMemoryCache cache, CancellationToken ct)
    {
        if (AccountEndpoints.CallerDeviceId(user) != primaryId) return Results.Forbid();

        byte[] payload, signature;
        try
        {
            payload = Convert.FromBase64String(request.Payload ?? "");
            signature = Convert.FromBase64String(request.Signature ?? "");
        }
        catch (FormatException) { return Bad("device_list_malformed"); }
        if (payload.Length == 0 || payload.Length > 8 * 1024 || signature.Length != 64)
            return Bad("device_list_malformed");

        DeviceListPayload? parsed;
        try { parsed = JsonSerializer.Deserialize<DeviceListPayload>(payload, JsonOptions); }
        catch (JsonException) { parsed = null; }
        if (parsed?.Devices is null || parsed.PrimaryDeviceId != primaryId || parsed.Version < 1)
            return Bad("device_list_malformed");

        var companions = parsed.Devices.Select(d => d.DeviceId).ToList();
        if (companions.Count > MaxCompanions)
            return Results.UnprocessableEntity(new { error = "device_list_too_large" });
        if (companions.Distinct().Count() != companions.Count || companions.Contains(primaryId))
            return Bad("device_list_malformed");

        var existing = await db.DeviceLists.Include(l => l.Members)
            .FirstOrDefaultAsync(l => l.PrimaryDeviceId == primaryId, ct);
        if (existing is not null && parsed.Version <= existing.Version)
            return Conflict("device_list_version_conflict");

        // A device is in at most one identity, in either role.
        if (await db.DeviceListMembers.AnyAsync(m => m.DeviceId == primaryId, ct))
            return Conflict("device_list_member_conflict");
        if (await db.Devices.CountAsync(d => companions.Contains(d.DeviceId), ct) != companions.Count)
            return Conflict("device_list_unknown_device");
        if (await db.DeviceListMembers.AnyAsync(
                m => companions.Contains(m.DeviceId) && m.PrimaryDeviceId != primaryId, ct)
            || await db.DeviceLists.AnyAsync(
                l => companions.Contains(l.PrimaryDeviceId) && l.Members.Any(), ct))
            return Conflict("device_list_member_conflict");

        // The server cannot check signatures, so it asks the device directly:
        // a NEW companion must have consented through its own authenticated
        // hub call (LinkConsent). Without this, anybody could claim a
        // victim's device and break the victim's routing.
        var newCompanions = companions
            .Where(id => existing is null || existing.Members.All(m => m.DeviceId != id)).ToList();
        if (newCompanions.Any(id => !cache.TryGetValue(ConsentKey(id, primaryId), out _)))
            return Conflict("device_list_consent_missing");

        // Old AND new members hear about the change: a removed device must
        // learn it was removed.
        var notify = (existing?.Members.Select(m => m.DeviceId) ?? [])
            .Concat(companions).Append(primaryId).Distinct().ToList();

        if (existing is null)
        {
            existing = new DeviceList { PrimaryDeviceId = primaryId };
            db.DeviceLists.Add(existing);
        }
        // Diff instead of clear + re-add: EF cannot track a deleted and an
        // added row with the same key in one SaveChanges.
        existing.Members.RemoveAll(m => !companions.Contains(m.DeviceId));
        foreach (var id in companions.Where(id => existing.Members.All(m => m.DeviceId != id)))
            existing.Members.Add(new DeviceListMember { DeviceId = id, PrimaryDeviceId = primaryId });
        existing.Version = parsed.Version;
        existing.Payload = payload;
        existing.Signature = signature;
        existing.UpdatedAt = DateTimeOffset.UtcNow;

        try { await db.SaveChangesAsync(ct); }
        catch (DbUpdateConcurrencyException) { return Conflict("device_list_version_conflict"); }
        catch (DbUpdateException ex)
            when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
        { return Conflict("device_list_member_conflict"); }

        foreach (var id in newCompanions)
            cache.Remove(ConsentKey(id, primaryId));

        foreach (var deviceId in notify)
            if (MessengerHub.TryGetConnection(deviceId, out var connectionId))
                await hub.Clients.Client(connectionId).SendAsync("DeviceListChanged",
                    new { primaryDeviceId = primaryId, version = parsed.Version }, ct);

        return Results.NoContent();
    }

    private static async Task<IResult> GetDeviceList(Guid id, AppDbContext db, CancellationToken ct)
    {
        var primaryId = await db.DeviceListMembers.Where(m => m.DeviceId == id)
            .Select(m => (Guid?)m.PrimaryDeviceId).FirstOrDefaultAsync(ct) ?? id;
        var list = await db.DeviceLists.AsNoTracking().FirstOrDefaultAsync(l => l.PrimaryDeviceId == primaryId, ct);
        return list is null
            ? Results.NotFound()
            : Results.Ok(new DeviceListResponse(list.PrimaryDeviceId, list.Version,
                Convert.ToBase64String(list.Payload), Convert.ToBase64String(list.Signature)));
    }
}

public record PutDeviceListRequest(string? Payload, string? Signature);

public record DeviceListResponse(Guid PrimaryDeviceId, int Version, string Payload, string Signature);

/// <summary>Only the fields the server routes by; the rest of the payload is the clients' business.</summary>
public record DeviceListPayload(Guid PrimaryDeviceId, int Version, List<DeviceListPayloadEntry>? Devices);

public record DeviceListPayloadEntry(Guid DeviceId);
```

`existing.Members.RemoveAll` on a tracked collection needs orphan deletion; because `DeviceListMember.PrimaryDeviceId` is a required FK, EF deletes the removed rows. If the `Version_must_grow` test shows rows left behind, replace the `RemoveAll` line with:

```csharp
        db.DeviceListMembers.RemoveRange(existing.Members.Where(m => !companions.Contains(m.DeviceId)).ToList());
```

Register in `Program.cs` after `app.MapDeviceEndpoints();`:

```csharp
app.MapDeviceListEndpoints();
```

- [ ] **Step 7: Run the tests**

Run: `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~DeviceListEndpointsTests`
Expected: 7 PASS.

- [ ] **Step 8: Migration**

```bash
dotnet ef migrations add AddDeviceLists --project src/server/CallType.Api
dotnet build src/server/CallType.Api
```

Open the generated migration and check it creates `DeviceLists` and `DeviceListMembers` with three `ON DELETE CASCADE` foreign keys and touches nothing else. It runs at startup (`Database__ApplyMigrationsOnStartup`); the Audit database is not involved.

- [ ] **Step 9: Commit**

```bash
git add src/server
git commit -m "feat(api): store and serve signed device lists"
```

---

### Task 3: Server - fan-out hub methods and link relay

**Files:**
- Modify: `src/server/CallType.Api/Hubs/MessengerHub.cs`
- Test: `src/server/CallType.Api.Tests/Hubs/FanoutHubTests.cs`

- [ ] **Step 1: Write the failing tests**

`FanoutHubTests.cs`:

```csharp
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.SignalR;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
using CallType.Api.Tests.TestFixtures;

namespace CallType.Api.Tests.Hubs;

public class FanoutHubTests : IntegrationTestBase
{
    private static readonly string Body = Convert.ToBase64String([1, 2, 3]);

    private HubConnection Hub(string token) => new HubConnectionBuilder()
        .WithUrl($"{Factory.Server.BaseAddress}hub?access_token={token}",
            o => o.HttpMessageHandlerFactory = _ => Factory.Server.CreateHandler())
        .Build();

    private async Task LinkAsync(Guid primary, params Guid[] companions)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.DeviceLists.Add(new DeviceList
        {
            PrimaryDeviceId = primary, Version = 1, Payload = [1], Signature = new byte[64],
            UpdatedAt = DateTimeOffset.UtcNow,
            Members = companions.Select(c => new DeviceListMember { DeviceId = c, PrimaryDeviceId = primary }).ToList()
        });
        await db.SaveChangesAsync();
    }

    private async Task<List<Guid>> QueuedForAsync(Guid messageId)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        return await db.QueuedMessages.Where(m => m.MessageId == messageId).Select(m => m.RecipientId).ToListAsync();
    }

    private static Dictionary<Guid, string> Payloads(params Guid[] ids) => ids.ToDictionary(id => id, _ => Body);

    [Fact]
    public async Task Direct_fanout_reaches_every_device_of_both_identities()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();

        var messageId = Guid.NewGuid();
        var targets = new[] { bPhone.DeviceId, bWeb.DeviceId, aPhone.DeviceId };
        // Sent from A's COMPANION: its own primary is a required recipient too.
        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, messageId, targets, Payloads(targets));

        (await QueuedForAsync(messageId)).Should().BeEquivalentTo(targets);
    }

    [Fact]
    public async Task Missing_or_extra_device_is_stale_and_names_the_required_set()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        var stranger = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();

        var missing = new[] { bPhone.DeviceId };
        var tooFew = await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, messageId, missing, Payloads(missing)))
            .Should().ThrowAsync<HubException>();
        tooFew.Which.Message.Should().Contain("device_list_stale:")
            .And.Contain(bPhone.DeviceId.ToString()).And.Contain(bWeb.DeviceId.ToString());

        var extra = new[] { bPhone.DeviceId, bWeb.DeviceId, stranger.DeviceId };
        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, messageId, extra, Payloads(extra)))
            .Should().ThrowAsync<HubException>().WithMessage("*device_list_stale:*");

        (await QueuedForAsync(messageId)).Should().BeEmpty();
    }

    [Fact]
    public async Task A_large_send_may_be_split_but_never_leaves_the_declared_set()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        var stranger = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var all = new[] { bPhone.DeviceId, bWeb.DeviceId };

        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, messageId, all, Payloads(bPhone.DeviceId));
        await hub.InvokeAsync("SendReliableDirectFanout", bPhone.DeviceId, messageId, all, Payloads(bWeb.DeviceId));
        (await QueuedForAsync(messageId)).Should().BeEquivalentTo(all);

        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bPhone.DeviceId, Guid.NewGuid(), all, Payloads(stranger.DeviceId)))
            .Should().ThrowAsync<HubException>();
    }

    [Fact]
    public async Task Recipient_must_be_a_primary()
    {
        var a = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        await using var hub = Hub(a.Token);
        await hub.StartAsync();
        var all = new[] { bPhone.DeviceId, bWeb.DeviceId };
        await FluentActions.Awaiting(() => hub.InvokeAsync(
            "SendReliableDirectFanout", bWeb.DeviceId, Guid.NewGuid(), all, Payloads(all)))
            .Should().ThrowAsync<HubException>().WithMessage("*recipient_is_not_primary*");
    }

    [Fact]
    public async Task Group_fanout_covers_companions_of_members_and_sender()
    {
        var aPhone = await RegisterAndAuthenticateAsync();
        var aWeb = await RegisterAndAuthenticateAsync();
        var bPhone = await RegisterAndAuthenticateAsync();
        var bWeb = await RegisterAndAuthenticateAsync();
        await LinkAsync(aPhone.DeviceId, aWeb.DeviceId);
        await LinkAsync(bPhone.DeviceId, bWeb.DeviceId);
        var groupId = Guid.NewGuid();
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.Groups.Add(new Group { GroupId = groupId, Name = "g", CreatedBy = aPhone.DeviceId, CreatedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = aPhone.DeviceId, Role = "admin", JoinedAt = DateTimeOffset.UtcNow });
            db.GroupMembers.Add(new GroupMember { GroupId = groupId, DeviceId = bPhone.DeviceId, Role = "member", JoinedAt = DateTimeOffset.UtcNow });
            await db.SaveChangesAsync();
        }
        await using var hub = Hub(aWeb.Token);
        await hub.StartAsync();
        var messageId = Guid.NewGuid();
        var targets = new[] { aPhone.DeviceId, bPhone.DeviceId, bWeb.DeviceId };

        // A's companion is not a GroupMember row; it sends on behalf of its identity.
        await hub.InvokeAsync("SendReliableGroupFanout", groupId, messageId, targets, Payloads(targets));

        (await QueuedForAsync(messageId)).Should().BeEquivalentTo(targets);
    }

    [Fact]
    public async Task Link_offer_and_consent_are_relayed_and_an_offline_target_is_reported()
    {
        var phone = await RegisterAndAuthenticateAsync();
        var web = await RegisterAndAuthenticateAsync();
        await using var phoneHub = Hub(phone.Token);
        await using var webHub = Hub(web.Token);
        var offer = new TaskCompletionSource<JsonElement>();
        var consent = new TaskCompletionSource<JsonElement>();
        webHub.On<JsonElement>("LinkOffer", offer.SetResult);
        phoneHub.On<JsonElement>("LinkConsent", consent.SetResult);
        await phoneHub.StartAsync();

        await FluentActions.Awaiting(() => phoneHub.InvokeAsync("LinkOffer", web.DeviceId))
            .Should().ThrowAsync<HubException>().WithMessage("*link_target_offline*");

        await webHub.StartAsync();
        await phoneHub.InvokeAsync("LinkOffer", web.DeviceId);
        (await offer.Task.WaitAsync(TimeSpan.FromSeconds(5)))
            .GetProperty("primaryDeviceId").GetGuid().Should().Be(phone.DeviceId);

        await webHub.InvokeAsync("LinkConsent", phone.DeviceId, "c2ln");
        var received = await consent.Task.WaitAsync(TimeSpan.FromSeconds(5));
        received.GetProperty("deviceId").GetGuid().Should().Be(web.DeviceId);
        received.GetProperty("consentSig").GetString().Should().Be("c2ln");
        Factory.Services.GetRequiredService<Microsoft.Extensions.Caching.Memory.IMemoryCache>()
            .TryGetValue(CallType.Api.Endpoints.DeviceListEndpoints.ConsentKey(web.DeviceId, phone.DeviceId), out _)
            .Should().BeTrue();
    }
}
```

If `Group` / `GroupMember` have different required properties than used above, read `Models/Group.cs` and `Models/GroupMember.cs` and fill what they require; do not change the models.

- [ ] **Step 2: Run to verify it fails**

Run: `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~FanoutHubTests`
Expected: FAIL, hub methods do not exist.

- [ ] **Step 3: Implement**

In `MessengerHub.cs` add `DeviceListService deviceLists` to the primary constructor parameter list (after `OrgCommunicationPolicy communicationPolicy`; `IMemoryCache cache` is already injected) and `using CallType.Api.Endpoints;`. Then add, after `SendReliableGroupMessage`:

```csharp
    // -----------------------------------------------------------------------
    // Multi-device fan-out
    // -----------------------------------------------------------------------
    // An identity is a primary device plus the companions in its signed list.
    // The sender encrypts one copy per device; this hub checks that the set
    // of target devices is exactly "every device of the recipient identities
    // and of the sender's own identity". It never looks at the signed list
    // itself: clients verify it. If the hub and a client disagree, the send
    // fails (device_list_stale) and the client re-reads the list. The hub can
    // therefore withhold a device, but it cannot make a client encrypt for
    // one the client did not verify.

    public async Task SendReliableDirectFanout(Guid recipientPrimaryId, Guid messageId,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
    {
        var ct = Context.ConnectionAborted;
        var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        var senderPrimary = await deviceLists.PrimaryOfAsync(sender, ct);
        // Conversations are keyed by identity: addressing a companion would
        // open a second conversation with the same person on the other side.
        if (await deviceLists.PrimaryOfAsync(recipientPrimaryId, ct) != recipientPrimaryId)
            throw new HubException("recipient_is_not_primary");
        // Policy over identities: otherwise an enrolled employee would step
        // around RequireBusinessConversations through a companion device.
        if (!await communicationPolicy.IsAllowedAsync(senderPrimary, recipientPrimaryId, ct))
            throw new HubException("business_conversation_required");
        var required = await deviceLists.DevicesOfAsync([recipientPrimaryId, senderPrimary], ct);
        await FanoutAsync(sender, messageId, null, required, allRecipients, encryptedPayloads);
    }

    public async Task SendReliableGroupFanout(Guid groupId, Guid messageId,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
    {
        var ct = Context.ConnectionAborted;
        var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        var senderPrimary = await deviceLists.PrimaryOfAsync(sender, ct);
        var membership = await db.GroupMembers.Where(m => m.GroupId == groupId)
            .Select(m => new { m.DeviceId, m.Group.OrganizationId }).ToListAsync(ct);
        var members = membership.Select(m => m.DeviceId).ToList();
        if (!members.Contains(senderPrimary))
            throw new HubException("Sender and recipients must be group members");
        // Business groups stay on SendReliableGroupMessage (primary devices
        // only): KB2 auditor rules and the archive are defined over members,
        // and companions there need their own analysis.
        if (membership[0].OrganizationId is not null)
            throw new HubException("fanout_unsupported_in_business_group");
        foreach (var member in members.Where(id => id != senderPrimary))
            if (!await communicationPolicy.IsAllowedAsync(senderPrimary, member, ct))
                throw new HubException("business_conversation_required");
        var required = await deviceLists.DevicesOfAsync(members, ct);
        await FanoutAsync(sender, messageId, groupId, required, allRecipients, encryptedPayloads);
    }

    private async Task FanoutAsync(Guid sender, Guid messageId, Guid? groupId, HashSet<Guid> required,
        List<Guid> allRecipients, Dictionary<Guid, string> encryptedPayloads)
    {
        required.Remove(sender);
        if (required.Count > 256)
            throw new HubException("Group message exceeds maximum member count");
        // Completeness is checked on the declared set, not on the payloads of
        // this call: an attachment for several devices does not fit one 1 MiB
        // frame, so a client may split the payloads over several calls.
        if (!required.SetEquals(allRecipients))
            throw new HubException("device_list_stale:" + string.Join(',', required));
        if (encryptedPayloads.Count == 0 || encryptedPayloads.Keys.Any(id => !required.Contains(id)))
            throw new HubException("Fan-out payloads must target declared recipients");
        var decoded = encryptedPayloads.ToDictionary(p => p.Key, p => DecodePayload(p.Value));
        var messages = new List<QueuedMessage>();
        await using (var transaction = await db.Database.BeginTransactionAsync(Context.ConnectionAborted))
        {
            foreach (var (recipient, body) in decoded)
                messages.Add(await queueService.EnqueueReliableAsync(recipient, sender, messageId,
                    body, groupId, Context.ConnectionAborted));
            await transaction.CommitAsync(Context.ConnectionAborted);
        }
        foreach (var message in messages)
            await DeliverAsync(message);
    }

    // -----------------------------------------------------------------------
    // Device linking relay
    // -----------------------------------------------------------------------
    // Two tiny messages between a primary and the device it is about to
    // link. Nothing is stored and nothing here is trusted: the primary got
    // the new device's keys from a QR code, and the consent is a signature
    // the primary verifies. Both sides must be online, linking is interactive.

    public async Task LinkOffer(Guid targetDeviceId)
    {
        var caller = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        if (!OnlineDevices.TryGetValue(targetDeviceId, out var connectionId))
            throw new HubException("link_target_offline");
        await Clients.Client(connectionId).SendAsync("LinkOffer",
            new { primaryDeviceId = caller }, Context.ConnectionAborted);
    }

    public async Task LinkConsent(Guid primaryDeviceId, string consentSig)
    {
        var caller = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        // An Ed25519 signature is 88 base64 chars; anything longer is not one.
        if (string.IsNullOrEmpty(consentSig) || consentSig.Length > 128)
            throw new HubException("Invalid consent");
        // The server-side half of consent: PUT device-list accepts this
        // device as a NEW companion of primaryDeviceId only while this
        // record exists (see DeviceListEndpoints.ConsentKey).
        cache.Set(DeviceListEndpoints.ConsentKey(caller, primaryDeviceId), true, TimeSpan.FromMinutes(10));
        if (!OnlineDevices.TryGetValue(primaryDeviceId, out var connectionId))
            throw new HubException("link_target_offline");
        await Clients.Client(connectionId).SendAsync("LinkConsent",
            new { deviceId = caller, consentSig }, Context.ConnectionAborted);
    }
```

- [ ] **Step 4: Run the tests**

Run: `dotnet test src/server/CallType.Api.Tests --filter "FullyQualifiedName~FanoutHubTests|FullyQualifiedName~MessengerHubTests"`
Expected: PASS (6 new, all existing hub tests still green).

- [ ] **Step 5: Commit**

```bash
git add src/server
git commit -m "feat(hub): per-device fan-out and device linking relay"
```

---

### Task 4: Server - GDPR export includes device lists

**Files:**
- Modify: `src/server/CallType.Api/Endpoints/PrivacyEndpoints.cs` (`ExportAccount`)
- Test: `src/server/CallType.Api.Tests/Endpoints/PrivacyEndpointsTests.cs`

Deletion is already covered by the FK cascades and tested in Task 2.

- [ ] **Step 1: Write the failing test**

Add to `PrivacyEndpointsTests.cs`, reusing whatever helper the existing export tests in that file use to create an account, link a device and call the export (read the nearest existing `Export...` test first and copy its arrange/act lines):

```csharp
    [Fact]
    public async Task Export_includes_the_device_lists_the_accounts_devices_are_in()
    {
        // arrange: account + linked device exactly as the existing export test does,
        // giving `accountId`, `deviceId` and an authorized `client`
        using (var scope = Factory.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            db.DeviceLists.Add(new DeviceList
            {
                PrimaryDeviceId = deviceId, Version = 4, Payload = [9, 9], Signature = new byte[64],
                UpdatedAt = DateTimeOffset.UtcNow
            });
            await db.SaveChangesAsync();
        }

        var export = await client.GetFromJsonAsync<JsonElement>($"/accounts/{accountId}/export");

        var list = export.GetProperty("deviceLists").EnumerateArray().Single();
        list.GetProperty("primaryDeviceId").GetGuid().Should().Be(deviceId);
        list.GetProperty("version").GetInt32().Should().Be(4);
        list.GetProperty("payload").GetString().Should().Be(Convert.ToBase64String([9, 9]));
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~Export_includes_the_device_lists`
Expected: FAIL, `deviceLists` property missing.

- [ ] **Step 3: Implement**

In `ExportAccount`, after the `reportsFiled` query:

```csharp
        // Multi-device: the signed lists these devices are part of, as a
        // primary or as a companion. The payload is the subject's own data
        // (their device IDs and public keys).
        var deviceLists = await db.DeviceLists
            .Where(l => deviceIds.Contains(l.PrimaryDeviceId) || l.Members.Any(m => deviceIds.Contains(m.DeviceId)))
            .Select(l => new { primaryDeviceId = l.PrimaryDeviceId, version = l.Version, payload = l.Payload, updatedAt = l.UpdatedAt })
            .ToListAsync(ct);
```

and add `deviceLists = deviceLists.Select(l => new { l.primaryDeviceId, l.version, payload = Convert.ToBase64String(l.payload), l.updatedAt })` as a new property of the anonymous object the method returns (same place the other collections are listed).

- [ ] **Step 4: Run the tests**

Run: `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~PrivacyEndpointsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/server
git commit -m "feat(api): GDPR export includes device lists"
```

---

### Task 5: Core - local schema v5, API client, hub client

**Files:**
- Modify: `src/client/calltype_core/lib/storage/tables.dart`, `lib/storage/database.dart`
- Modify: `src/client/calltype_core/lib/network/api_client.dart`, `lib/network/signalr_client.dart`
- Test: `src/client/calltype_core/test/storage/migration_test.dart`, `test/network/signalr_client_test.dart`

- [ ] **Step 1: Write the failing migration test**

Append to `migration_test.dart` inside `main()`:

```dart
  test('v4 -> v5 adds the device list tables and keeps existing rows', () async {
    final db = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          for (final ddl in _schemaV1) {
            raw.execute(ddl);
          }
          raw.execute(
            "INSERT INTO conversations (id, type, unread_count) "
            "VALUES ('bob', 'direct', 3)",
          );
          // Oldest shipped schema: proves the v5 step also runs at the end
          // of the full upgrade chain, not only from v4.
          raw.execute('PRAGMA user_version = 1');
        },
      ),
    );
    addTearDown(db.close);

    expect((await db.select(db.conversations).getSingle()).unreadCount, 3);
    await db.into(db.knownDeviceLists).insert(
      KnownDeviceListsCompanion.insert(
        primaryDeviceId: 'p',
        version: 1,
        payload: 'cGF5',
        signature: 'c2ln',
      ),
    );
    await db.into(db.knownDeviceListMembers).insert(
      KnownDeviceListMembersCompanion.insert(deviceId: 'c', primaryDeviceId: 'p'),
    );
    expect(await db.select(db.knownDeviceListMembers).get(), hasLength(1));
  });
```

Run: `cd src/client/calltype_core && dart test test/storage/migration_test.dart`
Expected: FAIL to compile (`knownDeviceLists` missing).

- [ ] **Step 2: Tables and migration**

Append to `tables.dart`:

```dart
/// Multi-device: the last VERIFIED signed device list of an identity (a
/// contact's, or our own). The row class is `KnownDeviceList` on purpose:
/// `DeviceList` is the parsed list in crypto/device_list.dart.
class KnownDeviceLists extends Table {
  /// The identity: the primary device ID contacts and conversations use.
  TextColumn get primaryDeviceId => text()();

  /// Highest verified version. A list below it is a replay and is rejected.
  IntColumn get version => integer()();

  /// Exact signed bytes (base64) and signature, kept so the entry of a
  /// companion (its keys) can be re-read later without the network.
  TextColumn get payload => text()();
  TextColumn get signature => text()();

  @override
  Set<Column> get primaryKey => {primaryDeviceId};
}

/// Multi-device: device ID -> identity, derived from [KnownDeviceLists].
/// Answers "whose device sent this?" with one indexed lookup per message.
class KnownDeviceListMembers extends Table {
  TextColumn get deviceId => text()();
  TextColumn get primaryDeviceId => text()();

  @override
  Set<Column> get primaryKey => {deviceId};
}
```

In `database.dart`: add `KnownDeviceLists, KnownDeviceListMembers,` to the `tables:` list, set `schemaVersion => 5`, add to the schema history comment:

```dart
  ///   5 - known_device_lists / known_device_list_members (multi-device:
  ///       verified signed device lists of contacts and of this identity)
```

and to `onUpgrade`:

```dart
      if (from < 5) {
        await m.createTable(knownDeviceLists);
        await m.createTable(knownDeviceListMembers);
      }
```

Run: `dart run build_runner build --delete-conflicting-outputs && dart test test/storage`
Expected: PASS.

- [ ] **Step 3: API client**

Add to `api_client.dart` after `getKeyBundle`:

```dart
  // -- Multi-device ----------------------------------------------------------

  /// The signed device list [deviceId] belongs to (as primary or companion),
  /// or null when it is in none. The result is UNVERIFIED server data: pass
  /// it through DeviceDirectory.refresh, never use it directly.
  ///
  /// GET /devices/{deviceId}/device-list
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/devices/$deviceId/device-list',
      );
      return response.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Uploads a new version of this device's own list. 409 means the version
  /// did not grow or a listed device already belongs to another identity.
  ///
  /// PUT /devices/{primaryDeviceId}/device-list
  Future<void> putDeviceList(
    String primaryDeviceId, {
    required String payload,
    required String signature,
  }) => _dio.put<void>(
    '/devices/$primaryDeviceId/device-list',
    data: {'payload': payload, 'signature': signature},
  );
```

- [ ] **Step 4: Failing hub client tests**

Read the top of `test/network/signalr_client_test.dart` for its fake `HubTransport` (it records `invoke` calls and lets a test raise server events). Add, using that fake exactly as the neighbouring tests do:

```dart
  test('direct fan-out sends ids, declared recipients and payloads', () async {
    // arrange a connected client with the fake transport, as the tests above do
    await client.sendDirectFanout(
      'peer',
      {'peer': 'YQ==', 'peer-web': 'Yg=='},
      messageId: 'm1',
    );
    expect(transport.invocations.single.method, 'SendReliableDirectFanout');
    expect(transport.invocations.single.args, [
      'peer',
      'm1',
      ['peer', 'peer-web'],
      {'peer': 'YQ==', 'peer-web': 'Yg=='},
    ]);
  });

  test('an oversized fan-out is split per device but declares the full set', () async {
    final big = 'x' * (500 * 1024);
    await client.sendGroupFanout('g', {'a': big, 'b': big}, messageId: 'm2');
    expect(transport.invocations, hasLength(2));
    for (final call in transport.invocations) {
      expect(call.method, 'SendReliableGroupFanout');
      expect(call.args[2], ['a', 'b']);
      expect((call.args[3] as Map).length, 1);
    }
  });

  test('staleRequired extracts the device ids the server demands', () {
    expect(
      SignalRClient.staleRequired(
        Exception('HubException: device_list_stale:aa-1,bb-2'),
      ),
      {'aa-1', 'bb-2'},
    );
    expect(SignalRClient.staleRequired(Exception('device_list_stale:')), <String>{});
    expect(SignalRClient.staleRequired(Exception('auditor_unavailable')), isNull);
  });

  test('device list and link events are forwarded', () async {
    final changed = client.onDeviceListChanged.first;
    transport.raise('DeviceListChanged', [
      {'primaryDeviceId': 'p', 'version': 2},
    ]);
    expect((await changed)['version'], 2);
  });
```

Adapt the names `transport.invocations`, `.method`, `.args`, `transport.raise` to what the existing fake actually exposes; add a missing accessor to the fake rather than changing `SignalRClient` for the test.

Run: `dart test test/network/signalr_client_test.dart` - Expected: FAIL (methods missing).

- [ ] **Step 5: Hub client**

In `signalr_client.dart` add stream controllers next to `_onEmergencyDrill` (same `StreamController<Map<String, dynamic>>.broadcast()` pattern, and close them where the others are closed):

```dart
  final _onDeviceListChanged =
      StreamController<Map<String, dynamic>>.broadcast();
  final _onLinkOffer = StreamController<Map<String, dynamic>>.broadcast();
  final _onLinkConsent = StreamController<Map<String, dynamic>>.broadcast();

  /// Multi-device: an identity this device belongs to changed its device
  /// list. Payload: `primaryDeviceId`, `version`. A hint to refetch and
  /// VERIFY; the event itself proves nothing.
  Stream<Map<String, dynamic>> get onDeviceListChanged =>
      _onDeviceListChanged.stream;

  /// Multi-device linking: a primary offers to link this device
  /// (`primaryDeviceId`). Only meaningful while the link screen is open.
  Stream<Map<String, dynamic>> get onLinkOffer => _onLinkOffer.stream;

  /// Multi-device linking: the new device's signed consent (`deviceId`,
  /// `consentSig`), delivered to the primary.
  Stream<Map<String, dynamic>> get onLinkConsent => _onLinkConsent.stream;
```

Register the handlers after the `EmergencyDrill` one:

```dart
    _hubConnection!.on(
      'DeviceListChanged',
      (arguments) => _forward(arguments, _onDeviceListChanged),
    );
    _hubConnection!.on(
      'LinkOffer',
      (arguments) => _forward(arguments, _onLinkOffer),
    );
    _hubConnection!.on(
      'LinkConsent',
      (arguments) => _forward(arguments, _onLinkConsent),
    );
```

Add after `sendGroupMessage`:

```dart
  /// Multi-device direct send: one envelope per device of the peer identity
  /// and of our own identity. [recipientIdentityId] is the peer's PRIMARY id.
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) => _fanout(
    'SendReliableDirectFanout',
    recipientIdentityId,
    messageId,
    encryptedPayloads,
  );

  /// Multi-device group send (non-business groups only; the hub rejects it
  /// for business groups, which stay on [sendGroupMessage]).
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) => _fanout(
    'SendReliableGroupFanout',
    groupId,
    messageId,
    encryptedPayloads,
  );

  Future<void> _fanout(
    String method,
    String target,
    String messageId,
    Map<String, String> encryptedPayloads,
  ) async {
    final connection = _requireConnection();
    // Every call declares the FULL device set: the hub checks completeness
    // on it, so a send that has to be split (attachment copies do not fit
    // one 1 MiB frame) still cannot silently skip a device.
    final all = encryptedPayloads.keys.toList();
    final size = encryptedPayloads.values.fold(0, (n, v) => n + v.length);
    final calls = size <= _maxFanOutChars
        ? [encryptedPayloads]
        : [for (final e in encryptedPayloads.entries) {e.key: e.value}];
    for (final payloads in calls) {
      await connection.invoke(method, <Object>[target, messageId, all, payloads]);
    }
  }

  /// The device ids the hub demanded in a `device_list_stale:<ids>` error,
  /// or null when [error] is something else.
  static Set<String>? staleRequired(Object error) {
    final match = RegExp(
      r'device_list_stale:([0-9a-fA-F,\-]*)',
    ).firstMatch(error.toString());
    if (match == null) return null;
    return match.group(1)!.split(',').where((id) => id.isNotEmpty).toSet();
  }

  /// Linking, primary side: ask the scanned device to consent.
  Future<void> sendLinkOffer(String targetDeviceId) =>
      _requireConnection().invoke('LinkOffer', <Object>[targetDeviceId]);

  /// Linking, new-device side: answer with the signed consent.
  Future<void> sendLinkConsent(String primaryDeviceId, String consentSig) =>
      _requireConnection().invoke('LinkConsent', <Object>[
        primaryDeviceId,
        consentSig,
      ]);
```

- [ ] **Step 6: Run the tests**

Run: `dart test test/network test/storage`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/client/calltype_core
git commit -m "feat(core): schema v5, device list API and fan-out hub calls"
```

---

### Task 6: Core - DeviceDirectory

**Files:**
- Create: `src/client/calltype_core/lib/devices/device_directory.dart`
- Test: `src/client/calltype_core/test/devices/device_directory_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:drift/drift.dart';
import 'package:test/test.dart';

import '../helpers/test_device.dart';

const me = '10000000-0000-4000-8000-000000000001';
const bob = '20000000-0000-4000-8000-000000000002';
const bobWeb = '20000000-0000-4000-8000-000000000003';
const rogue = '90000000-0000-4000-8000-000000000009';

class ListApi extends ApiClient {
  ListApi() : super(baseUrl: 'http://unused');
  final served = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async =>
      served[deviceId];
}

void main() {
  late TestDevice self;
  late TestDevice bobPhone;
  late TestDevice bobCompanion;
  late ListApi api;
  late DeviceDirectory directory;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    self = await TestDevice.create(me);
    bobPhone = await TestDevice.create(bob);
    bobCompanion = await TestDevice.create(bobWeb);
    api = ListApi();
    directory = DeviceDirectory(
      database: self.db,
      apiClient: api,
      selfDeviceId: me,
      selfSigningKey: () async =>
          (await self.keys.getSignedIdentityBundle())['signingKey']!,
    );
    await directory.load();
  });

  tearDown(() async {
    await self.close();
    await bobPhone.close();
    await bobCompanion.close();
  });

  /// Bob's list as the server would serve it, signed by [signer].
  Future<Map<String, dynamic>> bobList(
    int version,
    List<TestDevice> companions, {
    TestDevice? signer,
  }) async {
    final signed = await signDeviceList(
      primarySigningKey: await (signer ?? bobPhone).keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: bob,
        version: version,
        devices: [
          for (final c in companions)
            DeviceListEntry(
              deviceId: c.id,
              identityKey: await c.keys.getPublicIdentityKey(),
              signingKey: (await c.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await c.keys.getSigningKeyPair(),
                primaryDeviceId: bob,
                companionDeviceId: c.id,
              ),
            ),
        ],
      ),
    );
    return {
      'primaryDeviceId': bob,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  /// What a real client does before it can verify Bob's list: start a session
  /// with Bob's primary, which pins his identity and signing key.
  Future<void> pinBob(String primary) async {
    if (!await self.sessions.hasSession(primary)) {
      await self.sessions.initiateSession(primary, await bobPhone.keyBundle());
    }
  }

  test('a verified list maps companions to the identity', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    final change = await directory.refresh(bob, ensurePinned: pinBob);
    expect(change!.added, {bobWeb});
    expect(await directory.identityOf(bobWeb), bob);
    expect(await directory.devicesOf(bob), [bob, bobWeb]);
    expect(await directory.fanoutTargets([bob]), unorderedEquals([bob, bobWeb]));
  });

  test('a device the server injects without a valid signature is ignored', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    // The "server" now serves a list signed by somebody else that adds a device.
    final attacker = await TestDevice.create(rogue);
    addTearDown(attacker.close);
    api.served[bob] = await bobList(2, [bobCompanion, attacker], signer: attacker);
    await expectLater(
      directory.refresh(bob, ensurePinned: pinBob),
      throwsA(isA<DeviceListException>()),
    );
    expect(await directory.devicesOf(bob), [bob, bobWeb]);
  });

  test('a replayed older list cannot bring a removed device back', () async {
    final v1 = await bobList(1, [bobCompanion]);
    api.served[bob] = v1;
    await directory.refresh(bob, ensurePinned: pinBob);
    api.served[bob] = await bobList(2, []);
    final change = await directory.refresh(bob, ensurePinned: pinBob);
    expect(change!.removed, {bobWeb});
    api.served[bob] = v1;
    await expectLater(
      directory.refresh(bob, ensurePinned: pinBob),
      throwsA(isA<DeviceListException>()),
    );
    expect(await directory.devicesOf(bob), [bob]);
  });

  test('no list, or the same list again, changes nothing', () async {
    expect(await directory.refresh(bob, ensurePinned: pinBob), isNull);
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    expect(await directory.refresh(bob, ensurePinned: pinBob), isNull);
    // "The list is gone" from the server must not erase what was verified.
    api.served.remove(bob);
    expect(await directory.refresh(bob, ensurePinned: pinBob), isNull);
    expect(await directory.devicesOf(bob), [bob, bobWeb]);
  });

  test('inbound routing: peer companion, own device, unrelated device', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);

    final fromBobWeb = await directory.routeInbound(senderDeviceId: bobWeb);
    expect(fromBobWeb.conversationId, bob);
    expect(fromBobWeb.senderIdentityId, bob);
    expect(fromBobWeb.own, isFalse);

    final stranger = await directory.routeInbound(senderDeviceId: rogue);
    expect(stranger.conversationId, rogue);

    final group = await directory.routeInbound(senderDeviceId: bobWeb, groupId: 'g1');
    expect(group.conversationId, 'g1');
    expect(group.senderIdentityId, bob);
  });

  test('a copy from our own device goes to the conversation named in `to`', () async {
    // This device becomes a companion of `bob`'s identity for the test:
    // simplest way to have a sibling without a third key set.
    await self.db.into(self.db.knownDeviceListMembers).insert(
      KnownDeviceListMembersCompanion.insert(deviceId: me, primaryDeviceId: bob),
    );
    await directory.load();
    expect(directory.selfIdentityId, bob);
    expect(directory.isCompanion, isTrue);

    final copy = await directory.routeInbound(senderDeviceId: bob, to: 'carol');
    expect(copy.own, isTrue);
    expect(copy.conversationId, 'carol');
    expect(
      directory.routeInbound(senderDeviceId: bob),
      throwsA(isA<DeviceListException>()),
    );
  });

  test('a companion whose pinned keys differ from the signed entry is refused', () async {
    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    // Nothing pinned: fail closed. Consent only proves the key written in the
    // entry agreed; the pinned keys are what tie the entry to the real device.
    await expectLater(
      directory.assertListedKeys(bobWeb),
      throwsA(isA<DeviceListException>()),
    );
    await self.db.into(self.db.backupState).insert(
      BackupStateCompanion.insert(key: 'peer_identity:$bobWeb', value: 'x|y'),
    );
    expect(
      directory.assertListedKeys(bobWeb),
      throwsA(isA<DeviceListException>()),
    );
  });
}
```

Run: `dart test test/devices` - Expected: FAIL, file missing.

- [ ] **Step 2: Implement `lib/devices/device_directory.dart`**

```dart
import 'package:drift/drift.dart';

import '../crypto/device_list.dart';
import '../network/api_client.dart';
import '../storage/database.dart';

/// What changed in an identity's device list (drives the "contact added a
/// device" notice).
class DeviceListChange {
  const DeviceListChange({
    required this.identityId,
    required this.added,
    required this.removed,
  });
  final String identityId;
  final Set<String> added;
  final Set<String> removed;
}

/// Where an incoming message belongs.
class InboundRoute {
  const InboundRoute({
    required this.conversationId,
    required this.senderIdentityId,
    required this.own,
  });
  final String conversationId;

  /// What to store in `messages.senderId`: the identity, never a companion's
  /// device id, so "mine vs theirs", delete-for-everyone and reply quotes
  /// keep working without knowing about devices.
  final String senderIdentityId;

  /// True for a copy of a message another of OUR devices sent.
  final bool own;
}

/// This device's view of who owns which device.
///
/// "Identity" is the primary device id: the id contacts, conversations and
/// `messages.senderId` use. Everything here is local and verified; the only
/// network call is [refresh], and what it fetches is checked against a key
/// this device pinned itself before it is stored.
class DeviceDirectory {
  DeviceDirectory({
    required AppDatabase database,
    required ApiClient apiClient,
    required this.selfDeviceId,
    required Future<String> Function() selfSigningKey,
  }) : _db = database,
       _api = apiClient,
       _selfSigningKey = selfSigningKey,
       _selfIdentityId = selfDeviceId;

  final AppDatabase _db;
  final ApiClient _api;
  final Future<String> Function() _selfSigningKey;

  /// The transport address of this device (hub connection, sessions).
  final String selfDeviceId;

  String _selfIdentityId;

  /// "Me" in conversations. Equals [selfDeviceId] unless this device is a
  /// companion. Call [load] once at startup before reading it.
  String get selfIdentityId => _selfIdentityId;

  bool get isCompanion => _selfIdentityId != selfDeviceId;

  Future<void> load() async {
    _selfIdentityId = await identityOf(selfDeviceId);
  }

  Future<String> identityOf(String deviceId) async {
    final row = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.deviceId.equals(deviceId))).getSingleOrNull();
    return row?.primaryDeviceId ?? deviceId;
  }

  /// The primary first, then its verified companions.
  Future<List<String>> devicesOf(String identityId) async {
    final rows = await (_db.select(
      _db.knownDeviceListMembers,
    )..where((m) => m.primaryDeviceId.equals(identityId))).get();
    return [identityId, ...rows.map((r) => r.deviceId)];
  }

  /// Every device a message to [identityIds] must be encrypted for: all
  /// their devices plus our own other devices (so they see what we sent).
  Future<List<String>> fanoutTargets(Iterable<String> identityIds) async {
    final targets = <String>{};
    for (final id in {...identityIds, _selfIdentityId}) {
      targets.addAll(await devicesOf(id));
    }
    targets.remove(selfDeviceId);
    return targets.toList();
  }

  /// Fetches the list [deviceId] is in and stores it if, and only if, it
  /// verifies. Returns what changed, or null when there is no list or it is
  /// the one already stored.
  ///
  /// [ensurePinned] must make sure the PRIMARY's identity is pinned (start a
  /// session with it). Only called when no pin exists yet: that is the same
  /// trust-on-first-use moment as a first message to a new contact.
  ///
  /// Throws [DeviceListException] when the server serves something that does
  /// not verify. What was stored before stays untouched in that case, and a
  /// missing list never deletes a stored one: otherwise the server could
  /// shrink or wipe a verified list by lying.
  Future<DeviceListChange?> refresh(
    String deviceId, {
    required Future<void> Function(String primaryDeviceId) ensurePinned,
  }) async {
    final raw = await _api.getDeviceList(deviceId);
    if (raw == null) return null;
    final primary = (raw['primaryDeviceId'] as String).toLowerCase();
    final signed = SignedDeviceList(
      raw['payload'] as String,
      raw['signature'] as String,
    );
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(primary))).getSingleOrNull();
    if (stored != null &&
        stored.payload == signed.payload &&
        stored.signature == signed.signature) {
      return null;
    }
    final list = await verifyDeviceList(
      signed: signed,
      primarySigningKey: await _signingKeyOf(primary, ensurePinned),
      expectedPrimaryDeviceId: primary,
      minVersion: (stored?.version ?? 0) + 1,
    );
    final before = (await devicesOf(primary)).toSet()..remove(primary);
    final after = list.devices.map((d) => d.deviceId).toSet();
    await _db.transaction(() async {
      await _db
          .into(_db.knownDeviceLists)
          .insertOnConflictUpdate(
            KnownDeviceListsCompanion.insert(
              primaryDeviceId: primary,
              version: list.version,
              payload: signed.payload,
              signature: signed.signature,
            ),
          );
      await (_db.delete(
        _db.knownDeviceListMembers,
      )..where((m) => m.primaryDeviceId.equals(primary))).go();
      for (final device in list.devices) {
        await _db
            .into(_db.knownDeviceListMembers)
            .insertOnConflictUpdate(
              KnownDeviceListMembersCompanion.insert(
                deviceId: device.deviceId,
                primaryDeviceId: primary,
              ),
            );
      }
    });
    // Our own membership may just have changed (linked or removed).
    if (before.contains(selfDeviceId) || after.contains(selfDeviceId)) {
      await load();
    }
    return DeviceListChange(
      identityId: primary,
      added: after.difference(before),
      removed: before.difference(after),
    );
  }

  /// Decides the conversation and the stored sender for an incoming message.
  /// [to] comes from INSIDE the decrypted payload and is honoured only for
  /// copies sent by our own devices; a peer cannot steer a message into
  /// another conversation with it.
  Future<InboundRoute> routeInbound({
    required String senderDeviceId,
    String? groupId,
    String? to,
  }) async {
    final sender = await identityOf(senderDeviceId);
    final own = sender == _selfIdentityId;
    if (own && groupId == null && to == null) {
      throw const DeviceListException('own_copy_without_to');
    }
    return InboundRoute(
      conversationId: groupId ?? (own ? to! : sender),
      senderIdentityId: sender,
      own: own,
    );
  }

  /// Throws when the keys this device pinned for a companion (at session
  /// start) are not the keys its primary signed into the list. Catches a
  /// server that swaps a companion's key bundle, and a signer who lists a
  /// stranger's device id with a key pair of her own (consent only proves
  /// that the key written in the entry agreed).
  ///
  /// Call it only after a session with [deviceId] exists: both session paths
  /// pin (initiateSession, and decryptMessage for a pre-key message). No pin
  /// means nothing ties the entry to the device, so it fails closed.
  Future<void> assertListedKeys(String deviceId) async {
    final identity = await identityOf(deviceId);
    if (identity == deviceId) return; // a primary: pinned directly, not listed
    final pinned = await _pinOf(deviceId);
    if (pinned == null) {
      throw const DeviceListException('listed_device_not_pinned');
    }
    final stored = await (_db.select(
      _db.knownDeviceLists,
    )..where((l) => l.primaryDeviceId.equals(identity))).getSingle();
    final entry = parseDeviceListPayload(
      stored.payload,
    ).devices.firstWhere((d) => d.deviceId == deviceId);
    if (pinned != '${entry.identityKey}|${entry.signingKey}') {
      throw const DeviceListException('listed_keys_mismatch');
    }
  }

  Future<String?> _pinOf(String deviceId) async => (await (_db.select(
    _db.backupState,
  )..where((r) => r.key.equals('peer_identity:$deviceId'))).getSingleOrNull())
      ?.value;

  Future<String> _signingKeyOf(
    String primary,
    Future<void> Function(String) ensurePinned,
  ) async {
    if (primary == selfDeviceId) return _selfSigningKey();
    var pinned = await _pinOf(primary);
    if (pinned == null) {
      await ensurePinned(primary);
      pinned = await _pinOf(primary);
    }
    if (pinned == null) throw const DeviceListException('primary_not_pinned');
    // Stored by SessionManager as "<identityKey>|<signingKey>".
    return pinned.split('|')[1];
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `dart test test/devices`
Expected: PASS. If `a verified list maps companions` fails with `primary_not_pinned`, `SessionManager.initiateSession` does not write `peer_identity:<peer>`; check where `_pinPeerIdentity` is called in `session_manager.dart` and report back instead of working around it in the directory.

- [ ] **Step 4: Commit**

```bash
git add src/client/calltype_core
git commit -m "feat(core): device directory with verified device lists"
```

---

### Task 7: Core - FanoutSender

**Files:**
- Create: `src/client/calltype_core/lib/devices/fanout_sender.dart`
- Test: `src/client/calltype_core/test/devices/fanout_sender_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
import 'dart:convert';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/network/api_client.dart';
import 'package:drift/drift.dart';
import 'package:test/test.dart';

import '../helpers/test_device.dart';

const me = '10000000-0000-4000-8000-000000000001';
const bob = '20000000-0000-4000-8000-000000000002';
const bobWeb = '20000000-0000-4000-8000-000000000003';
const rogue = '90000000-0000-4000-8000-000000000009';

class ListApi extends ApiClient {
  ListApi() : super(baseUrl: 'http://unused');
  final served = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async =>
      served[deviceId];
}

void main() {
  late TestDevice self;
  late Map<String, TestDevice> peers;
  late ListApi api;
  late DeviceDirectory directory;
  late FanoutSender sender;

  Future<void> ensureSession(String peer) async {
    if (!await self.sessions.hasSession(peer)) {
      await self.sessions.initiateSession(peer, await peers[peer]!.keyBundle());
    }
  }

  Future<void> serveBobList(int version, List<String> companions) async {
    final primary = peers[bob]!;
    final signed = await signDeviceList(
      primarySigningKey: await primary.keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: bob,
        version: version,
        devices: [
          for (final id in companions)
            DeviceListEntry(
              deviceId: id,
              identityKey: await peers[id]!.keys.getPublicIdentityKey(),
              signingKey:
                  (await peers[id]!.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await peers[id]!.keys.getSigningKeyPair(),
                primaryDeviceId: bob,
                companionDeviceId: id,
              ),
            ),
        ],
      ),
    );
    api.served[bob] = {
      'primaryDeviceId': bob,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    self = await TestDevice.create(me);
    peers = {
      for (final id in [bob, bobWeb, rogue]) id: await TestDevice.create(id),
    };
    api = ListApi();
    directory = DeviceDirectory(
      database: self.db,
      apiClient: api,
      selfDeviceId: me,
      selfSigningKey: () async =>
          (await self.keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: self.keys.getPublicIdentityKey,
    );
    await directory.load();
    sender = FanoutSender(
      directory: directory,
      sessions: self.sessions,
      ensureSession: ensureSession,
    );
  });

  tearDown(() async {
    await self.close();
    for (final peer in peers.values) {
      await peer.close();
    }
  });

  final payload = jsonEncode({'v': 1, 'id': 'm', 'body': 'hi', 'groupId': null});

  test('encrypts one envelope per verified device, each decryptable', () async {
    await serveBobList(1, [bobWeb]);
    final envelopes = await sender.encrypt([bob], payload);
    expect(envelopes.keys, unorderedEquals([bob, bobWeb]));
    for (final id in [bob, bobWeb]) {
      final plain = await peers[id]!.sessions.decryptMessage(
        me,
        utf8.decode(base64Decode(envelopes[id]!)),
      );
      expect(jsonDecode(plain)['body'], 'hi');
    }
  });

  test('stale: a device the server no longer has is dropped, others resent as is', () async {
    await serveBobList(1, [bobWeb]);
    final first = await sender.encrypt([bob], payload);
    final fixed = await sender.reconcile(
      envelopes: first,
      required: {bob},
      identityIds: [bob],
      payload: payload,
    );
    expect(fixed.keys, [bob]);
    // Byte-identical: re-encrypting would advance the ratchet a second time.
    expect(fixed[bob], first[bob]);
  });

  test('stale: a newly listed device gets an envelope after the list verifies', () async {
    await serveBobList(1, []);
    final first = await sender.encrypt([bob], payload);
    expect(first.keys, [bob]);
    await serveBobList(2, [bobWeb]);
    final fixed = await sender.reconcile(
      envelopes: first,
      required: {bob, bobWeb},
      identityIds: [bob],
      payload: payload,
    );
    expect(fixed.keys, unorderedEquals([bob, bobWeb]));
    expect(fixed[bob], first[bob]);
  });

  test('stale: a device the server demands but nobody signed is refused', () async {
    await serveBobList(1, []);
    final first = await sender.encrypt([bob], payload);
    expect(
      sender.reconcile(
        envelopes: first,
        required: {bob, rogue},
        identityIds: [bob],
        payload: payload,
      ),
      throwsA(isA<DeviceListException>()),
    );
  });
}
```

Run: `dart test test/devices/fanout_sender_test.dart` - Expected: FAIL, file missing.

- [ ] **Step 2: Implement `lib/devices/fanout_sender.dart`**

```dart
import 'dart:convert';

import '../crypto/device_list.dart';
import '../crypto/session_manager.dart';
import 'device_directory.dart';

/// Builds the per-device envelopes of one message and repairs them when the
/// hub answers `device_list_stale`.
///
/// The one rule that keeps the server from adding a reader: an envelope is
/// only ever created for a device from a VERIFIED list. The server may tell
/// us to drop a device (fewer readers is always safe) but if it demands one
/// we cannot verify, the send fails.
class FanoutSender {
  FanoutSender({
    required DeviceDirectory directory,
    required SessionManager sessions,
    required Future<void> Function(String deviceId) ensureSession,
  }) : _directory = directory,
       _sessions = sessions,
       _ensureSession = ensureSession;

  final DeviceDirectory _directory;
  final SessionManager _sessions;
  final Future<void> Function(String) _ensureSession;

  /// One base64 envelope per device of [identityIds] and of our own other
  /// devices. Refreshes the lists first so a contact's new device is picked
  /// up without waiting for a stale error.
  Future<Map<String, String>> encrypt(
    Iterable<String> identityIds,
    String payload,
  ) async {
    await _refresh(identityIds);
    return {
      for (final target in await _directory.fanoutTargets(identityIds))
        target: await _encryptFor(target, payload),
    };
  }

  /// After `device_list_stale`: [required] is the device set the hub wants.
  /// Existing envelopes are kept byte for byte (re-encrypting would advance
  /// the ratchet for a message the peer may already hold).
  Future<Map<String, String>> reconcile({
    required Map<String, String> envelopes,
    required Set<String> required,
    required Iterable<String> identityIds,
    required String payload,
  }) async {
    final kept = {
      for (final e in envelopes.entries)
        if (required.contains(e.key)) e.key: e.value,
    };
    final missing = required.difference(kept.keys.toSet());
    if (missing.isEmpty) return kept;
    await _refresh(identityIds);
    final verified = (await _directory.fanoutTargets(identityIds)).toSet();
    if (!verified.containsAll(missing)) {
      throw const DeviceListException('server_requires_unverified_device');
    }
    for (final target in missing) {
      kept[target] = await _encryptFor(target, payload);
    }
    return kept;
  }

  Future<void> _refresh(Iterable<String> identityIds) async {
    for (final id in {...identityIds, _directory.selfIdentityId}) {
      await _directory.refresh(id, ensurePinned: _ensureSession);
    }
  }

  Future<String> _encryptFor(String deviceId, String payload) async {
    await _ensureSession(deviceId);
    // After the session exists the device's keys are pinned: they must be
    // the ones its primary signed.
    await _directory.assertListedKeys(deviceId);
    return base64Encode(
      utf8.encode(await _sessions.encryptMessage(deviceId, payload)),
    );
  }
}
```

- [ ] **Step 3: Run the tests**

Run: `dart test test/devices`
Expected: PASS.

- [ ] **Step 4: Full core suite and commit**

Run: `dart analyze && dart test` in `src/client/calltype_core`. Expected: no issues, all PASS.

```bash
git add src/client/calltype_core
git commit -m "feat(core): fan-out sender with stale reconciliation"
```

---

### Task 8: Live E2E - three real devices

**Files:**
- Modify: `src/bots/jay_archiver/test/e2e/e2e_device.dart`
- Create: `src/bots/jay_archiver/test/e2e/multi_device_e2e_test.dart`

The scenario "a device inserted straight into the server database is rejected by clients" is covered at unit level (Task 6 "injected", Task 7 "nobody signed"): the E2E has no database access by design. Everything else in the spec's E2E list is below. Three registrations = three of the ten auth calls per minute.

- [ ] **Step 1: Extend `E2eDevice`**

Keep the `KeyManager` (the constructor currently drops it) and add multi-device helpers. Change the constructor and `register` so `keys` is stored:

```dart
  E2eDevice._(this.id, this.api, this.keys, this.sessions, this.signalR, this._db);

  final KeyManager keys;
```

(pass `keys` in the `E2eDevice._(...)` call inside `register`), make `_ensureSession` public by renaming it to `ensureSession` (update its two callers in this file), and add:

```dart
  late final DeviceDirectory directory = DeviceDirectory(
    database: _db,
    apiClient: api,
    selfDeviceId: id,
    selfSigningKey: () async =>
        (await keys.getSignedIdentityBundle())['signingKey']!,
    selfIdentityKey: keys.getPublicIdentityKey,
  );

  late final FanoutSender _fanout = FanoutSender(
    directory: directory,
    sessions: sessions,
    apiClient: api,
  );

  /// Linking without the QR step: each companion signs its consent and sends
  /// it through the hub (the server records it; PUT refuses a new companion
  /// without it), then the primary signs the next version and uploads it.
  /// Both sides must be connected to the hub.
  Future<void> setCompanions(List<E2eDevice> companions, {required int version}) async {
    for (final c in companions) {
      await c.signalR.sendLinkConsent(
        id,
        await signDeviceLinkConsent(
          companionSigningKey: await c.keys.getSigningKeyPair(),
          primaryDeviceId: id,
          companionDeviceId: c.id,
        ),
      );
    }
    final signed = await signDeviceList(
      primarySigningKey: await keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: id,
        version: version,
        devices: [
          for (final c in companions)
            DeviceListEntry(
              deviceId: c.id,
              identityKey: await c.keys.getPublicIdentityKey(),
              signingKey: (await c.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await c.keys.getSigningKeyPair(),
                primaryDeviceId: id,
                companionDeviceId: c.id,
              ),
            ),
        ],
      ),
    );
    await api.putDeviceList(id, payload: signed.payload, signature: signed.signature);
  }

  /// Sends a direct text to an identity the way the app does: fan-out,
  /// one retry after `device_list_stale`.
  Future<String> sendDirect(String peerIdentityId, String text) async {
    final messageId = uuid();
    final payload = jsonEncode({
      'v': 1,
      'id': messageId,
      'body': text,
      'type': 'text',
      'groupId': null,
      'to': peerIdentityId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    var envelopes = await _fanout.encrypt([peerIdentityId], payload);
    try {
      await signalR.sendDirectFanout(peerIdentityId, envelopes, messageId: messageId);
    } catch (e) {
      final required = SignalRClient.staleRequired(e);
      if (required == null) rethrow;
      envelopes = await _fanout.reconcile(
        envelopes: envelopes,
        required: required,
        identityIds: [peerIdentityId],
        payload: payload,
      );
      await signalR.sendDirectFanout(peerIdentityId, envelopes, messageId: messageId);
    }
    return messageId;
  }

  /// Waits for the next message, decrypts it, routes it and acknowledges it.
  /// Call BEFORE the send it should catch (onMessage is a broadcast stream).
  Future<({InboundRoute route, String body, String id})> nextMessage() async {
    final data = await signalR.onMessage.first.timeout(
      const Duration(seconds: 20),
    );
    final senderId = data['senderId'] as String;
    await directory.refresh(senderId, ensurePinned: ensureSession);
    final plaintext = await sessions.decryptMessage(
      senderId,
      utf8.decode(base64Decode(data['encryptedBody'] as String)),
    );
    await directory.assertListedKeys(senderId);
    final payload = jsonDecode(plaintext) as Map<String, dynamic>;
    final route = await directory.routeInbound(
      senderDeviceId: senderId,
      groupId: data['groupId'] as String?,
      to: payload['to'] as String?,
    );
    await signalR.acknowledgeMessage(senderId, data['messageId'] as String);
    return (route: route, body: payload['body'] as String, id: payload['id'] as String);
  }
```

with imports:

```dart
import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
```

Run: `cd src/bots/jay_archiver && dart analyze` - Expected: no issues.

- [ ] **Step 2: Write the E2E test**

`test/e2e/multi_device_e2e_test.dart`:

```dart
// Live proof of multi-device fan-out: real crypto, real hub, real API.
// Skipped without JAY_E2E_API. LOCAL compose only, never beta or production.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'e2e_device.dart';

void main() {
  final baseUrl = Platform.environment['JAY_E2E_API'];

  test(
    'messages reach every device of an identity, in the same conversation',
    skip: baseUrl == null ? 'set JAY_E2E_API to a LOCAL API' : null,
    () async {
      final aPhone = await E2eDevice.register(baseUrl!);
      final aWeb = await E2eDevice.register(baseUrl);
      final b = await E2eDevice.register(baseUrl);
      addTearDown(() => Future.wait([aPhone, aWeb, b].map((d) => d.close())));
      await Future.wait([aPhone, aWeb, b].map((d) => d.signalR.connect()));

      // A links the web device. The companion pins its primary by starting a
      // session with it, then verifies the list it is in.
      await aPhone.setCompanions([aWeb], version: 1);
      await aPhone.directory.refresh(aPhone.id, ensurePinned: aPhone.ensureSession);
      await aWeb.directory.refresh(aWeb.id, ensurePinned: aWeb.ensureSession);
      expect(aWeb.directory.isCompanion, isTrue);
      expect(aWeb.directory.selfIdentityId, aPhone.id);

      // 1. B -> A arrives on BOTH of A's devices.
      var onPhone = aPhone.nextMessage();
      var onWeb = aWeb.nextMessage();
      await b.sendDirect(aPhone.id, 'hello both');
      for (final received in [await onPhone, await onWeb]) {
        expect(received.body, 'hello both');
        expect(received.route.conversationId, b.id);
        expect(received.route.own, isFalse);
      }

      // 2. A's WEB device answers: B sees it in the conversation with A's
      //    identity, and A's phone gets a copy marked as its own.
      final atB = b.nextMessage();
      onPhone = aPhone.nextMessage();
      await aWeb.sendDirect(b.id, 'from the web');
      final seenByB = await atB;
      expect(seenByB.body, 'from the web');
      expect(seenByB.route.conversationId, aPhone.id);
      expect(seenByB.route.senderIdentityId, aPhone.id);
      final copy = await onPhone;
      expect(copy.body, 'from the web');
      expect(copy.route.own, isTrue);
      expect(copy.route.conversationId, b.id);

      // 3. A removes the web device. B still has version 1 stored and does
      //    not re-read it before sending; the hub answers device_list_stale
      //    with A's remaining devices and B's retry (reconcile) drops the
      //    removed one.
      await aPhone.setCompanions([], version: 2);
      onPhone = aPhone.nextMessage();
      var leaked = false;
      final webSub = aWeb.signalR.onMessage.listen((_) => leaked = true);
      addTearDown(webSub.cancel);
      await b.sendDirect(aPhone.id, 'phone only');
      expect((await onPhone).body, 'phone only');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(leaked, isFalse);
      // The stale answer made B re-read A's list: the removal now holds on
      // B's side too, not only on the (honest) server.
      expect(await b.directory.devicesOf(aPhone.id), [aPhone.id]);
    },
  );
}
```

- [ ] **Step 3: Run it against local compose**

```bash
docker compose up -d --build api
cd src/bots/jay_archiver && JAY_E2E_API=http://localhost:8080 dart test test/e2e/multi_device_e2e_test.dart
```

Expected: PASS. Wait a minute before re-running or before running the other E2E files (10 auth calls per minute per IP). Then run `dart test` (without the env var) in `src/bots/jay_archiver`, `src/bots/calltype_bot` and `src/bots/hermes_bridge`: all PASS, E2E skipped.

- [ ] **Step 4: Commit**

```bash
git add src/bots
git commit -m "test(e2e): live multi-device fan-out with three devices"
```

---

### Task 9: Documentation

**Files:**
- Modify: `docs/security/crypto-baseline.md`, `docs/security/data-subject-rights.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`

- [ ] **Step 1: `crypto-baseline.md`** (mandatory for any change under `calltype_core/lib/crypto`). Add a section in the document's existing language and table style covering exactly:
  - Primitive: Ed25519 over `"CallType-DeviceList-v1" || 0x00 || payload bytes`, key = the device signing key (`ct_signing_seed`), verified in `verifyDeviceList` (`device_list.dart`).
  - Consent: Ed25519 over `"CallType-DeviceLink-v1" || 0x00 || primary uuid (16 B) || companion uuid (16 B)`, key = the companion's signing key.
  - Trust anchor: the primary's signing key as pinned in `peer_identity:<deviceId>` (TOFU, unchanged).
  - Rollback protection: version must exceed the highest verified one stored in `known_device_lists`.
  - Limits: the server can withhold an update; peers and server learn the device count; a web companion keeps keys in browser storage; no cross-signing, a lost primary cannot change the list.

- [ ] **Step 2: `data-subject-rights.md`**: export now contains `deviceLists`; deleting a device removes it from routing (a deleted primary removes the list); the signed payload other devices cached locally is outside the server's reach.

- [ ] **Step 3: `CLAUDE.md`**: add to the entity table `DeviceList` ("signed list of an identity's companion devices; opaque to the server", key `PrimaryDeviceId`) and `DeviceListMember` ("device to identity routing row", key `DeviceId`); add to the endpoint table `PUT /devices/{primaryId}/device-list`, `GET /devices/{id}/device-list`, and extend the `SignalR /hub` row with `SendReliableDirectFanout`, `SendReliableGroupFanout`, `LinkOffer`, `LinkConsent`, events `DeviceListChanged`. Status "✅ Done". Add to "Known limitations" in Key design decision 2: multi-device trust is a list signed by the primary device, see the spec.

- [ ] **Step 4: Spec**: re-read Part A and Part B of the spec against what was built (method names, error strings, table names). Fix any drift in the spec, not in the code.

- [ ] **Step 5: Commit**

```bash
git add docs CLAUDE.md
git commit -m "docs: multi-device protocol in crypto baseline, GDPR and API tables"
```

---

## Done when

- `dart analyze && dart test` green in `src/client/calltype_core` and the three bot packages.
- `dotnet test src/server/CallType.Api.Tests` green (run once, sequentially).
- `multi_device_e2e_test.dart` green against local docker-compose.
- No client app change yet: the Flutter app still sends the old way and keeps working (the old hub methods are untouched). Plan 2 switches it over.

## Plan 2 scope (Flutter app + bot runtime), written after this plan lands

Not tasks yet: the code steps must be written against the core API as it really ends up. What plan 2 has to cover so that nothing from the spec is lost:

1. **Wiring and the identity split.** `DeviceDirectory` as a provider, `load()` at startup, refresh of the own list on `DeviceListChanged`. `ChatController.myDeviceId` becomes the identity id (rename to `myIdentityId`, including `chat_screen.dart` and `mentions.dart`); `WebRTCManager` and `SignalRClient` keep the transport device id.
2. **Receiving.** `MessageInboxService` routes through `DeviceDirectory.routeInbound`, stores the identity id in `senderId`, acknowledges with the transport sender id, refreshes the list of an unknown sender before decrypting, calls `assertListedKeys` after decrypting, does not bump unread for own copies.
3. **Sending.** `ChatController.retryMessage` uses `FanoutSender` + `sendDirectFanout` / `sendGroupFanout` for everything except business conversations; `to` in the payload; outbox keeps envelopes and is patched by `reconcile` on `device_list_stale`.
4. **Device change notice.** A `device-change` line in the conversation when a contact's list changes, plus the `backup_import.dart` whitelist fix (it must accept `call-event` and `device-change` and skip `delete` rows) because a new row type would otherwise break every restore.
5. **Linking UI.** New device: "Link to an existing device" with a QR code and the "Link to CT-XXXX-XXXX?" confirmation. Primary: Settings > Devices with scan, list and remove. Only an empty device may link.
6. **Removal and "cannot verify".** A companion wipes local data only after a verified higher version without itself.
7. **Companion restrictions in v1.** No business conversations, no calls from or to a companion.
8. **Bot runtime.** `calltype_bot` routes inbound through the directory and replies with fan-out, otherwise a user's companion never sees bot replies and a message sent from a companion opens a second conversation.
9. **Strings in all 19 ARB files**, widget tests, `docs/acceptance/` entry, manual check on phone + web.
