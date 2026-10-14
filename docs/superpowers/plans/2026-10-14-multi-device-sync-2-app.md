# Multi-device sync, plan 2 of 2: Flutter app + bot runtime

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user links a second device by QR code, and from then on both devices receive, send and see each other's messages in the same conversations; bots answer every device of a user.

**Architecture:** All protocol logic already lives in `calltype_core` (plan 1: `DeviceDirectory`, `FanoutSender`, signed device lists, fan-out hub methods). This plan wires it into the app: an app-wide `DeviceService` owns the directory and the device's own list (linking, removal, wipe, "cannot verify"); `MessageInboxService` routes every incoming envelope through the directory; `ChatController` sends with `FanoutSender` and repairs the outbox on `device_list_stale`; `myDeviceId` splits into the transport device id and the identity id. Business conversations and calls stay on the primary.

**Tech Stack:** Flutter/Dart (provider, go_router, drift, qr_flutter, mobile_scanner, crypto), pure Dart `calltype_core` and `calltype_bot`, ASP.NET Core 10 + xUnit/Testcontainers for one small server task.

**Spec:** `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md` (spec 1 of 4: live sync only). Plan 1: `docs/superpowers/plans/2026-10-13-multi-device-sync-1-protocol.md`; its "Deviations" 1-9 and "Constraints for plan 2" are binding and referenced below as "constraint N". The code in `src/client/calltype_core/lib/devices/*` is the contract; where plan 1's code blocks differ, the repo wins.

Not in scope: history transfer (spec 2), read state / delete-for-me / contact rename / calls on companions (spec 3), identity recovery (spec 4).

## Decisions (taken, not reopened)

1. **Companions may READ groups.** The server maps the caller to its identity for the read-only group endpoints (`GET /groups/{id}`, `GET /groups/{id}/members`, the only two the app needs to send to a group). Membership-changing endpoints stay primary-only. (Task 1)
2. **Companions in v1:** no business conversations (sending there is hidden on a companion; business groups stay on `SendReliableGroupMessage` from the primary), no calls from or to a companion (call buttons hidden on a companion; incoming calls ring the primary only, which is what peers already address). (Tasks 8, 9)
3. **Only an empty device (no contacts, no conversations) can become a companion**, enforced in the client. (Task 10)
4. **`ChatController.myDeviceId` becomes the identity id** (`myIdentityId`, incl. `chat_screen.dart`, `mentions.dart`, tests). `WebRTCManager` and `SignalRClient` keep the transport device id. (Task 6)
5. **A `device-change` system line** appears in the conversation when a contact's list adds or removes devices (never for our own identity), together with the `backup_import.dart` fix (accept `call-event` and `device-change`, skip `delete` control rows). (Tasks 3, 5, 9)
6. **Linking UI:** the new device ("Link to an existing device", from onboarding and from settings when the device is empty) shows a `jaylink://<deviceId>/<fingerprint>` QR code, waits for `LinkOffer`, shows "Link to CT-XXXX-XXXX?" and sends `LinkConsent`. The primary (Settings > Linked devices) lists companions, scans, fetches the key bundle, compares the fingerprint BEFORE `LinkOffer`, waits for `LinkConsent`, verifies it with `verifyDeviceLinkConsent`, signs version + 1, PUTs, refreshes its own list; "Remove" re-signs without the device. On 409 it reloads and retries with version + 1. (Tasks 5, 10)
7. **Companion removal:** local data is wiped only when a verified change lists `selfDeviceId` in `removed`; a missing list or a failed verification is "cannot verify" and deletes nothing. The primary re-signs without a companion the server dropped in a stale answer. (Tasks 5, 8)
8. **Bot runtime** routes inbound through `DeviceDirectory` and replies with fan-out. (Task 11)
9. **Strings in all 19 ARB files** (machine translation is acceptable per `CLAUDE.md`), l10n guards green, security wording keeps its meaning. (Task 4)

## Open questions (planned with the recommendation; veto before Task 1 if you disagree)

1. **The new device needs the primary's handle for "Link to CT-XXXX-XXXX?", but `LinkOffer` carries only `primaryDeviceId` and there is no endpoint "handle by device id".** Recommendation (planned in Task 1): the hub adds the CALLER's `userHandle`, looked up server-side, to the `LinkOffer` event. Server-side lookup also stops another user from putting somebody else's handle on an offer. Alternative: a new `GET /devices/{id}/profile` endpoint (more surface, same trust).
2. **`POST /groups` from a companion would make the companion a member on its own** (spec "Limits of v1"). Recommendation (planned in Task 1 + Task 9): the server answers 403 `companion_cannot_manage_groups` and the app hides "New group" on a companion.
3. **A companion's "My identity" screen would hand out the companion's own `ct://` invite**; a contact that adds it cannot send to it (`recipient_is_not_primary`). Recommendation (planned in Task 9): a companion shows the primary's invite (id + handle stored at link time) and hides the display-name field (it would rename the companion device, which nobody sees).
4. **Device-change lines only in direct conversations, one line per direction (not per device), and only for a change between two verified versions.** The first list ever stored for an identity produces no line (its existing companions are not news to the user). Recommendation: accept for v1 (one `ponytail:` comment marks the group gap).
5. **On a companion, conversations with people who are not contacts there show the raw id as title** (contacts are not synced until spec 3). Recommendation: accept for v1, document in the acceptance checklist.
6. **"Link a device" is hidden on Windows/Linux** (no camera; the contact scanner has the same gap). The web primary can scan with the browser camera. Recommendation: accept.
7. **Dropping a vanished companion trusts the server's stale answer** (constraint 5). The server can thereby unlink a companion of ours, which is the "may remove, never add" direction the spec accepts. Recommendation: accept, as the constraint says.

## Deviations from the spec and plan 1, decided while planning

1. **`DeviceDirectory.changes` (core).** Plan 1 returns a `DeviceListChange` only to the caller of `refresh`, and `FanoutSender.reconcile` refreshes internally without handing changes back. The app needs ONE place that sees every stored change (device-change lines, companion wipe), so the directory also publishes each change on a broadcast stream, with `firstList` set when nothing was stored for that identity before (the app shows no line for a first fetch). (Task 2)
2. **"Unknown sender" (constraint 1) = not attributed to another identity AND no session yet.** That is exactly the first message of a device we never talked to; a known sender costs no lookup.
3. **"Cannot verify" needs one extra GET on a companion.** `refresh` answers `null` both for "unchanged" and for "the server has no list"; only a direct `getDeviceList(selfDeviceId)` tells them apart. Done only on a companion, after a refresh that returned without a change.
4. **`DeviceListChanged` is honoured only for our own identity or the primary we just consented to.** Any other id would let the server make us pin and store arbitrary identities.
5. **Every list refresh runs inside `MessageProcessingQueue`** (inbox, outbox reconcile, `DeviceService.checkOwnList`, wipe), because refresh may start a session (ratchet state). Nothing that already runs in the queue may await another queue job: the chat controller's "drop vanished companion" hook is fire-and-forget for that reason.
6. **`FanoutSender.reconcile` runs OUTSIDE a database transaction.** The first encryption stays inside a transaction with the outbox insert (as today), but reconcile refreshes lists, `DeviceDirectory.refresh` serializes on its own tail, and a transaction held across that could wait for a refresh that waits for the database. A crash in between only loses envelopes nobody has received.
7. **`ChatController` builds its own `FanoutSender`** from the directory, sessions and API client it already gets. The class is stateless apart from those references; injecting it would only add a parameter to every test.
8. **Wipe scope on a verified removal:** messages, conversations, contacts, stored device lists, outbox and control markers, the stored primary handle. Keys, registration, sessions and pins stay: the device becomes an ordinary empty device again.
9. **Bots: `allowSender` receives the identity id** (resolved before the allowlist), so a companion of an allowed user is allowed. `hermes_bridge` resolves handles to primary ids already, so its behaviour is unchanged for single-device users.
10. **The scanner for "Link a device" is pushed as a `MaterialPageRoute`** like the contact scanner, not as a go_router route.
11. **Spec wording "Settings > Devices"** is "Settings > Linked devices" in the UI.

## Rules for every task

- Branch `feat/multi-device-sync`. Start with `git log --oneline -1`; the plan commit must be in the history.
- Comments explain WHY (project rule). Never rename `CallType-*` strings in `calltype_core/lib/crypto`.
- No U+2014 dash anywhere in new text (code, comments, ARB, docs).
- Minimal diff: change only what the task names. Anything else: mention, do not change.
- App commands run in `src/client/calltype`, core commands in `src/client/calltype_core`, bot commands in the bot's folder. Server tests need Docker and must run one `dotnet test` at a time.
- No drift schema change in this plan (schema v5 from plan 1 is enough) and no `mockito` change: the tracked `test/core/network/push_service_test.mocks.dart` stays untouched. If `database.g.dart` is missing locally, run `dart run build_runner build --delete-conflicting-outputs` in `src/client/calltype_core` first.
- UI text only through `context.l10n` (the l10n guard fails on `Text('...')` literals in `lib/features`, `lib/shared`, `lib/app`). Protocol strings, error codes and logs are not localized.
- Commit messages end with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File map

| File | Responsibility |
|---|---|
| `src/server/CallType.Api/Endpoints/GroupEndpoints.cs` | Read-only group endpoints as the identity; `POST /groups` refuses companions. |
| `src/server/CallType.Api/Hubs/MessengerHub.cs` | `LinkOffer` event carries the caller's `userHandle`. |
| `src/client/calltype_core/lib/devices/device_directory.dart` | `changes` broadcast stream. |
| `src/client/calltype/lib/features/backup/backup_import.dart` | Accept `call-event` / `device-change`, skip `delete` rows. |
| `src/client/calltype/lib/l10n/app_*.arb` (19) | 25 new strings. |
| `src/client/calltype/lib/features/devices/device_service.dart` (new) | App-wide owner of the directory: open, own-list checks, wipe, "cannot verify", device-change lines, publishing the own list. |
| `src/client/calltype/lib/features/devices/link_code.dart` (new) | `jaylink://` code + key fingerprint. |
| `src/client/calltype/lib/features/devices/link_controllers.dart` (new) | Primary-side and new-device-side linking state machines. |
| `src/client/calltype/lib/features/devices/devices_screen.dart` (new) | Settings > Linked devices. |
| `src/client/calltype/lib/features/devices/link_device_screen.dart` (new) | New device: QR code, confirmation, waiting. |
| `src/client/calltype/lib/features/chat/message_inbox_service.dart` | Inbound routing through the directory. |
| `src/client/calltype/lib/features/chat/chat_controller.dart` | `myIdentityId`, fan-out send, outbox repair. |
| `src/client/calltype/lib/features/chat/chat_screen.dart`, `mentions.dart` | Identity split, device-change line, companion restrictions. |
| `src/client/calltype/lib/features/chat_list/chat_list_screen.dart` | Companion status banner, no "New group" on a companion. |
| `src/client/calltype/lib/features/settings/{settings_screen,identity_screen}.dart` | Linked devices tile; a companion shows the primary's invite. |
| `src/client/calltype/lib/features/onboarding/onboarding_screen.dart` | "Link to an existing device" after registration. |
| `src/client/calltype/lib/features/contacts/qr_scanner_screen.dart` | `deviceLink` mode (accepts `jaylink://` only). |
| `src/client/calltype/lib/main.dart`, `lib/app/router.dart` | Wiring and routes. |
| `src/client/calltype/test/helpers/fake_multi_device_server.dart` (new) | In-memory API + hub with the server's fan-out completeness rule. |
| `src/bots/calltype_bot/lib/calltype_bot.dart` | Inbound routing, fan-out replies. |
| `docs/acceptance/multi-device.md` (new), `CLAUDE.md`, spec status line | Docs. |

## Tasks

1. Server: companions read groups, `LinkOffer` carries the handle
2. Core: `DeviceDirectory.changes`
3. App: backup import accepts every row type the app writes
4. App: strings in all 19 languages
5. App: `DeviceService` and wiring
6. App: identity split (`myIdentityId`)
7. App: inbox routes through the directory
8. App: fan-out send and outbox repair (+ app-level flow test with real crypto)
9. App: companion restrictions and the device-change line
10. App: linking UI
11. Bots: `calltype_bot` routes through the directory and replies with fan-out
12. Docs and final verification

---

### Task 1: Server - companions read groups, LinkOffer carries the handle

**Files:**
- Modify: `src/server/CallType.Api/Endpoints/GroupEndpoints.cs`
- Modify: `src/server/CallType.Api/Hubs/MessengerHub.cs` (method `LinkOffer`)
- Test: `src/server/CallType.Api.Tests/Endpoints/GroupEndpointsTests.cs`, `src/server/CallType.Api.Tests/Hubs/FanoutHubTests.cs`

- [ ] **Step 1: Write the failing group tests**

In `GroupEndpointsTests.cs` add to the usings:

```csharp
using Microsoft.Extensions.DependencyInjection;
using CallType.Api.Data;
using CallType.Api.Models;
```

Add inside the class (after `CreateGroupAsync`):

```csharp
    private HttpClient As(string token)
    {
        var client = Factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    /// <summary>
    /// Seeded straight into the database, like FanoutHubTests: signatures are
    /// the clients' business, the server only routes by membership.
    /// </summary>
    private async Task LinkAsync(Guid primary, Guid companion)
    {
        using var scope = Factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        db.DeviceLists.Add(new DeviceList
        {
            PrimaryDeviceId = primary, Version = 1, Payload = [1], Signature = new byte[64],
            UpdatedAt = DateTimeOffset.UtcNow,
            Members = [new DeviceListMember { DeviceId = companion, PrimaryDeviceId = primary }]
        });
        await db.SaveChangesAsync();
    }

    [Fact]
    public async Task A_companion_reads_the_groups_of_its_identity_but_cannot_change_them()
    {
        var phone = await RegisterAndAuthenticateAsync();
        var web = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        var stranger = await RegisterAndAuthenticateAsync();
        await LinkAsync(phone.DeviceId, web.DeviceId);
        var created = await As(phone.Token).PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { other.DeviceId } });
        created.StatusCode.Should().Be(HttpStatusCode.Created);
        var group = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("groupId").GetGuid();

        var companion = As(web.Token);
        (await companion.GetAsync($"/groups/{group}")).StatusCode.Should().Be(HttpStatusCode.OK);
        var members = await companion.GetFromJsonAsync<JsonElement>($"/groups/{group}/members");
        members.EnumerateArray().Select(m => m.GetProperty("deviceId").GetGuid())
            .Should().BeEquivalentTo(new[] { phone.DeviceId, other.DeviceId });

        // Membership changes stay with the member device itself (the primary).
        (await companion.PutAsJsonAsync($"/groups/{group}/members", new { deviceId = stranger.DeviceId }))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await companion.DeleteAsync($"/groups/{group}/members/{other.DeviceId}"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
        // A device outside the group still reads nothing.
        (await As(stranger.Token).GetAsync($"/groups/{group}/members"))
            .StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task A_companion_cannot_create_a_group()
    {
        var phone = await RegisterAndAuthenticateAsync();
        var web = await RegisterAndAuthenticateAsync();
        var other = await RegisterAndAuthenticateAsync();
        await LinkAsync(phone.DeviceId, web.DeviceId);

        var response = await As(web.Token).PostAsJsonAsync("/groups", new { memberDeviceIds = new[] { other.DeviceId } });

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("error").GetString()
            .Should().Be("companion_cannot_manage_groups");
    }
```

- [ ] **Step 2: Extend the link relay test**

In `FanoutHubTests.cs`, test `Link_offer_and_consent_are_relayed_and_an_offline_target_is_reported`, replace

```csharp
        (await offer.Task.WaitAsync(TimeSpan.FromSeconds(5)))
            .GetProperty("primaryDeviceId").GetGuid().Should().Be(phone.DeviceId);
```

with

```csharp
        var offered = await offer.Task.WaitAsync(TimeSpan.FromSeconds(5));
        offered.GetProperty("primaryDeviceId").GetGuid().Should().Be(phone.DeviceId);
        // Looked up by the server, so the new device can show whose phone asks.
        offered.GetProperty("userHandle").GetString().Should().Be(phone.UserHandle);
```

- [ ] **Step 3: Run the tests, verify they fail**

Run: `dotnet test src/server/CallType.Api.Tests --filter "FullyQualifiedName~GroupEndpointsTests|FullyQualifiedName~FanoutHubTests"`
Expected: FAIL. The companion gets 403 on `GET /groups/{id}`, `POST /groups` answers 201, and `userHandle` is missing.

- [ ] **Step 4: Implement in `GroupEndpoints.cs`**

Replace `CreateGroup`'s signature and its first three lines:

```csharp
    private static async Task<IResult> CreateGroup(CreateGroupRequest request, ClaimsPrincipal user,
        AppDbContext db, HttpContext http, DeviceListService deviceLists, CancellationToken ct)
    {
        var creator = Caller(user);
        if (creator == Guid.Empty) return Results.Unauthorized();
        // Multi-device: a companion would become a member on its own and the
        // rest of its identity would never see the group (spec "Limits of v1").
        // Groups are created and managed from the primary device.
        if (await deviceLists.PrimaryOfAsync(creator, ct) != creator)
            return Results.Json(new { error = "companion_cannot_manage_groups" }, statusCode: 403);
```

(the rest of `CreateGroup` is unchanged). Replace `Authorize`:

```csharp
    /// <summary>
    /// [caller] is the IDENTITY for the read-only endpoints (a companion reads
    /// the groups of its primary; it is not a member itself) and the raw
    /// device for membership changes, which stay with the member device.
    /// </summary>
    private static async Task<IResult?> Authorize(Guid groupId, Guid caller,
        AppDbContext db, bool admin, CancellationToken ct)
    {
        if (!await db.Groups.AnyAsync(g => g.GroupId == groupId, ct)) return Results.NotFound();
        var role = await db.GroupMembers.Where(m => m.GroupId == groupId && m.DeviceId == caller)
            .Select(m => m.Role).SingleOrDefaultAsync(ct);
        return role == null || (admin && role != "admin") ? Results.Forbid() : null;
    }
```

In `GetGroup` add the parameter `DeviceListService deviceLists` (after `BusinessModeOptions businessMode`) and replace its first line with:

```csharp
        var denial = await Authorize(groupId, await deviceLists.PrimaryOfAsync(Caller(user), ct), db, false, ct);
```

In `ListMembers` change the signature to

```csharp
    private static async Task<IResult> ListMembers(Guid groupId, ClaimsPrincipal user,
        AppDbContext db, DeviceListService deviceLists, CancellationToken ct)
```

and its first line to

```csharp
        var denial = await Authorize(groupId, await deviceLists.PrimaryOfAsync(Caller(user), ct), db, false, ct);
```

In `AddMember` and `RemoveMember` change `Authorize(groupId, user, db, true, ct)` to `Authorize(groupId, Caller(user), db, true, ct)`.

- [ ] **Step 5: Implement in `MessengerHub.cs`**

Replace the body of `LinkOffer` with:

```csharp
    public async Task LinkOffer(Guid targetDeviceId)
    {
        var caller = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
        if (!OnlineDevices.TryGetValue(targetDeviceId, out var connectionId))
            throw new HubException("link_target_offline");
        // The new device asks "Link to <handle>?" and the user compares it with
        // the phone in their hand. Looked up here instead of sent by the caller,
        // so another user cannot put somebody else's handle on an offer.
        var userHandle = await db.Devices.Where(d => d.DeviceId == caller)
            .Select(d => d.UserHandle).SingleOrDefaultAsync(Context.ConnectionAborted);
        await Clients.Client(connectionId).SendAsync("LinkOffer",
            new { primaryDeviceId = caller, userHandle }, Context.ConnectionAborted);
    }
```

- [ ] **Step 6: Run the tests, verify they pass**

Run: `dotnet test src/server/CallType.Api.Tests --filter "FullyQualifiedName~GroupEndpointsTests|FullyQualifiedName~FanoutHubTests|FullyQualifiedName~BusinessGroupEndpointsTests"`
Expected: PASS (business group tests included because they share `Authorize`).

- [ ] **Step 7: Commit**

```bash
git add src/server/CallType.Api/Endpoints/GroupEndpoints.cs src/server/CallType.Api/Hubs/MessengerHub.cs src/server/CallType.Api.Tests/Endpoints/GroupEndpointsTests.cs src/server/CallType.Api.Tests/Hubs/FanoutHubTests.cs
git commit -m "feat(api): companions read their identity's groups, link offer names the primary

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Core - DeviceDirectory.changes

**Files:**
- Modify: `src/client/calltype_core/lib/devices/device_directory.dart`
- Test: `src/client/calltype_core/test/devices/device_directory_test.dart`

- [ ] **Step 1: Write the failing test**

Append inside `main()` of `device_directory_test.dart` (it uses the file's existing `bobList`, `pinBob`, `bob`, `bobWeb`, `bobCompanion`):

```dart
  test('every stored change is also published on the changes stream', () async {
    final seen = <DeviceListChange>[];
    final subscription = directory.changes.listen(seen.add);
    addTearDown(subscription.cancel);

    api.served[bob] = await bobList(1, [bobCompanion]);
    await directory.refresh(bob, ensurePinned: pinBob);
    // The same list again stores nothing and publishes nothing.
    await directory.refresh(bob, ensurePinned: pinBob);
    api.served[bob] = await bobList(2, []);
    await directory.refresh(bob, ensurePinned: pinBob);
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(2));
    expect(seen[0].identityId, bob);
    expect(seen[0].added, {bobWeb});
    expect(seen[0].removed, isEmpty);
    // Nothing was stored for Bob before: a first fetch, not a change.
    expect(seen[0].firstList, isTrue);
    expect(seen[1].added, isEmpty);
    expect(seen[1].removed, {bobWeb});
    expect(seen[1].firstList, isFalse);
  });
```

- [ ] **Step 2: Run it, verify it fails**

Run (in `src/client/calltype_core`): `dart test test/devices/device_directory_test.dart`
Expected: compile error, `changes` and `firstList` are not defined.

- [ ] **Step 3: Implement**

In `device_directory.dart` replace the `DeviceListChange` constructor and fields with:

```dart
  const DeviceListChange({
    required this.identityId,
    required this.added,
    required this.removed,
    this.firstList = false,
  });
  final String identityId;
  final Set<String> added;
  final Set<String> removed;

  /// True when nothing was stored for this identity before: the first fetch
  /// of a list that may have existed for a long time. Its devices are not
  /// news to the user, so the app shows no "added a device" line for it.
  final bool firstList;
```

Add `import 'dart:async';` as the first import. Below the field `Future<void> _tail = Future.value();` add:

```dart
  final _changes = StreamController<DeviceListChange>.broadcast();

  /// Every change [refresh] stored, whoever asked for it (inbox, outbox
  /// reconcile, a DeviceListChanged hint). The app derives the "contact added
  /// a device" line and the companion wipe from this ONE stream: callers such
  /// as FanoutSender.reconcile refresh internally and do not hand their
  /// changes back.
  Stream<DeviceListChange> get changes => _changes.stream;
```

At the end of `_refresh`, replace

```dart
    return DeviceListChange(
      identityId: primary,
      added: after.difference(before),
      removed: before.difference(after),
    );
```

with

```dart
    final change = DeviceListChange(
      identityId: primary,
      added: after.difference(before),
      removed: before.difference(after),
      // `stored` is safe to use here: refreshes are serialized, and the
      // transaction above re-checked that nothing newer arrived meanwhile.
      firstList: stored == null,
    );
    _changes.add(change);
    return change;
```

- [ ] **Step 4: Run the core suite**

Run: `dart analyze && dart test`
Expected: no issues, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/client/calltype_core/lib/devices/device_directory.dart src/client/calltype_core/test/devices/device_directory_test.dart
git commit -m "feat(core): device directory publishes every stored change, marks first lists

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: App - backup import accepts every row type the app writes

Today one `call-event` row fails the whole restore (spec, "Known bug"); the `device-change` rows from Task 5 would do the same.

**Files:**
- Modify: `src/client/calltype/lib/features/backup/backup_import.dart`
- Test: `src/client/calltype/test/features/backup/backup_import_test.dart`

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `backup_import_test.dart`:

```dart
  test('call-event and device-change rows restore, delete control rows are skipped', () async {
    final data = fixture();
    final base = (data['messages'] as List).single as Map<String, dynamic>;
    data['messages'] = [
      base,
      {...base, 'id': 'call', 'type': 'call-event', 'body': '{}', 'status': 'sent'},
      {...base, 'id': 'device', 'type': 'device-change', 'body': 'added', 'status': 'delivered'},
      {...base, 'id': 'control', 'type': 'delete', 'body': 'message', 'status': 'sending'},
    ];
    await importBackup(db, data);
    final ids = (await db.select(db.messages).get()).map((m) => m.id);
    expect(ids, unorderedEquals(['message', 'call', 'device']));
  });

  test('an unknown message type still rejects the whole backup', () async {
    final data = fixture();
    (data['messages'] as List).single['type'] = 'sticker';
    await expectLater(importBackup(db, data), throwsFormatException);
    expect(await db.select(db.contacts).get(), isEmpty);
  });
```

- [ ] **Step 2: Run them, verify the first fails**

Run (in `src/client/calltype`): `flutter test test/features/backup/backup_import_test.dart`
Expected: the first new test FAILS with `FormatException: Invalid message type or status`; the second passes already.

- [ ] **Step 3: Implement**

In `backup_import.dart` replace

```dart
  final messages = rows('messages').map((m) {
```

with

```dart
  // 'delete' rows are transient outbox control messages (deleteForEveryone).
  // A backup taken while one was pending must not resurrect it: it has no
  // bubble and would be resent. Skipped, not rejected, so one such row cannot
  // fail a whole restore.
  final messages = rows('messages').where((m) => m['type'] != 'delete').map((m) {
```

and replace

```dart
    if (!['text', 'image', 'file', 'audio', 'video'].contains(type) ||
```

with

```dart
    // Every type the app itself writes into `messages` must restore:
    // 'call-event' (business call log) and 'device-change' (multi-device
    // notice) are rows like any other.
    if (!['text', 'image', 'file', 'audio', 'video', 'call-event', 'device-change']
            .contains(type) ||
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `flutter test test/features/backup`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/client/calltype/lib/features/backup/backup_import.dart src/client/calltype/test/features/backup/backup_import_test.dart
git commit -m "fix(app): restore call-event and device-change rows, skip delete control rows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: App - strings in all 19 languages

**Files:**
- Modify: `src/client/calltype/lib/l10n/app_en.arb` and the 18 other `app_<lang>.arb`

Every ARB file currently ends with the `chatReplyCancel` entry (in `app_en.arb` followed by its `@chatReplyCancel` block). For each file: add a comma after that last entry and paste the block for the language before the closing `}`. Keep the security meaning of `linkDeviceConfirmBody`, `devicesFingerprintMismatch` and `devicesCannotVerify` when touching any wording later.

- [ ] **Step 1: `app_en.arb`**

```json
  "settingsDevices": "Linked devices",
  "@settingsDevices": {
    "description": "Settings row and screen title: the user's devices that share one identity (multi-device)."
  },
  "settingsDevicesSubtitle": "Use your chats on another device",
  "@settingsDevicesSubtitle": {
    "description": "Subtitle of the Linked devices settings row."
  },
  "devicesEmpty": "No other devices are linked to this one.",
  "@devicesEmpty": {
    "description": "Linked devices screen on the main device when it has no linked devices."
  },
  "devicesDeviceLabel": "Device {id}",
  "@devicesDeviceLabel": {
    "description": "One linked device in the list; id is the first characters of its technical id.",
    "placeholders": {
      "id": {
        "type": "String"
      }
    }
  },
  "devicesAdd": "Link a device",
  "@devicesAdd": {
    "description": "Action on the main device: scan the code of a new device to link it."
  },
  "devicesRemove": "Remove",
  "@devicesRemove": {
    "description": "Button that unlinks a device (also the confirm button of the dialog)."
  },
  "devicesRemoveConfirm": "Remove this device? It stops receiving your messages and deletes your chats the next time it connects.",
  "@devicesRemoveConfirm": {
    "description": "Confirmation before unlinking a device."
  },
  "devicesRemoveFailed": "The device could not be removed. Try again.",
  "@devicesRemoveFailed": {
    "description": "Snackbar when unlinking failed."
  },
  "devicesScanHint": "Scan the code shown on the new device",
  "@devicesScanHint": {
    "description": "Hint on the camera screen when linking a new device."
  },
  "devicesFingerprintMismatch": "This code does not match the keys of the device. Do not link it.",
  "@devicesFingerprintMismatch": {
    "description": "Security warning: the scanned code and the keys the server returned differ. Must stay a clear 'do not link'."
  },
  "devicesWaitingConsent": "Confirm the link on the new device.",
  "@devicesWaitingConsent": {
    "description": "Main device waits until the user confirms on the new device."
  },
  "devicesLinkFailed": "Linking failed. Try again.",
  "@devicesLinkFailed": {
    "description": "Generic linking failure."
  },
  "devicesLinkedTo": "This device is linked to {handle}. Linked devices are managed there.",
  "@devicesLinkedTo": {
    "description": "Linked devices screen on a linked (secondary) device; handle is the main device's CT-XXXX-XXXX.",
    "placeholders": {
      "handle": {
        "type": "String"
      }
    }
  },
  "devicesCannotVerify": "The link of this device cannot be verified. Nothing was deleted.",
  "@devicesCannotVerify": {
    "description": "Banner on a linked device whose device list is missing or invalid. Must say that nothing was deleted."
  },
  "devicesRemovedNotice": "This device was unlinked and its chats were deleted.",
  "@devicesRemovedNotice": {
    "description": "Banner after the main device unlinked this device and its local chats were wiped."
  },
  "linkDeviceAction": "Link to an existing device",
  "@linkDeviceAction": {
    "description": "Action on a new, empty device: become a linked device of an existing phone."
  },
  "linkDeviceInstructions": "On your main phone open Settings, Linked devices, Link a device, and scan this code.",
  "@linkDeviceInstructions": {
    "description": "Shown under the QR code on the new device."
  },
  "linkDeviceConfirmTitle": "Link to {handle}?",
  "@linkDeviceConfirmTitle": {
    "description": "Question on the new device when a phone offers to link it.",
    "placeholders": {
      "handle": {
        "type": "String"
      }
    }
  },
  "linkDeviceConfirmBody": "Confirm only if {handle} is the phone in your hand. This device will then receive and send the messages of that phone.",
  "@linkDeviceConfirmBody": {
    "description": "Security text under the link question: the user must compare the handle with the phone in their hand.",
    "placeholders": {
      "handle": {
        "type": "String"
      }
    }
  },
  "linkDeviceConfirm": "Link",
  "@linkDeviceConfirm": {
    "description": "Button that confirms linking on the new device."
  },
  "linkDeviceNotEmpty": "Only a device without contacts and chats can be linked.",
  "@linkDeviceNotEmpty": {
    "description": "Shown when the device already has contacts or chats."
  },
  "linkDeviceWaiting": "Waiting for your phone to finish linking…",
  "@linkDeviceWaiting": {
    "description": "New device after it confirmed, until the main device has signed the link."
  },
  "chatDeviceAdded": "This contact added a device",
  "@chatDeviceAdded": {
    "description": "System line in a chat: the contact linked another device that now also receives this chat."
  },
  "chatDeviceRemoved": "This contact removed a device",
  "@chatDeviceRemoved": {
    "description": "System line in a chat: the contact unlinked one of their devices."
  },
  "chatCompanionBusinessReadOnly": "Business chats can only be used on your main device.",
  "@chatCompanionBusinessReadOnly": {
    "description": "Shown instead of the message input in a business chat on a linked device."
  }
```

- [ ] **Step 2: `app_cs.arb`**

```json
  "settingsDevices": "Propojená zařízení",
  "settingsDevicesSubtitle": "Používejte své chaty na dalším zařízení",
  "devicesEmpty": "K tomuto zařízení nejsou propojená žádná další zařízení.",
  "devicesDeviceLabel": "Zařízení {id}",
  "devicesAdd": "Propojit zařízení",
  "devicesRemove": "Odebrat",
  "devicesRemoveConfirm": "Odebrat toto zařízení? Přestane dostávat vaše zprávy a při příštím připojení smaže vaše chaty.",
  "devicesRemoveFailed": "Zařízení se nepodařilo odebrat. Zkuste to znovu.",
  "devicesScanHint": "Naskenujte kód zobrazený na novém zařízení",
  "devicesFingerprintMismatch": "Tento kód neodpovídá klíčům zařízení. Zařízení nepropojujte.",
  "devicesWaitingConsent": "Potvrďte propojení na novém zařízení.",
  "devicesLinkFailed": "Propojení se nezdařilo. Zkuste to znovu.",
  "devicesLinkedTo": "Toto zařízení je propojené s {handle}. Propojená zařízení se spravují tam.",
  "devicesCannotVerify": "Propojení tohoto zařízení nelze ověřit. Nic nebylo smazáno.",
  "devicesRemovedNotice": "Toto zařízení bylo odpojeno a jeho chaty byly smazány.",
  "linkDeviceAction": "Propojit s existujícím zařízením",
  "linkDeviceInstructions": "Na hlavním telefonu otevřete Nastavení, Propojená zařízení, Propojit zařízení a naskenujte tento kód.",
  "linkDeviceConfirmTitle": "Propojit s {handle}?",
  "linkDeviceConfirmBody": "Potvrďte jen tehdy, pokud {handle} je telefon, který držíte v ruce. Toto zařízení pak bude přijímat a odesílat zprávy tohoto telefonu.",
  "linkDeviceConfirm": "Propojit",
  "linkDeviceNotEmpty": "Propojit lze jen zařízení bez kontaktů a chatů.",
  "linkDeviceWaiting": "Čekání, až telefon dokončí propojení…",
  "chatDeviceAdded": "Tento kontakt přidal zařízení",
  "chatDeviceRemoved": "Tento kontakt odebral zařízení",
  "chatCompanionBusinessReadOnly": "Firemní chaty lze používat jen na hlavním zařízení."
```

- [ ] **Step 3: `app_sk.arb`**

```json
  "settingsDevices": "Prepojené zariadenia",
  "settingsDevicesSubtitle": "Používajte svoje chaty na ďalšom zariadení",
  "devicesEmpty": "K tomuto zariadeniu nie sú prepojené žiadne ďalšie zariadenia.",
  "devicesDeviceLabel": "Zariadenie {id}",
  "devicesAdd": "Prepojiť zariadenie",
  "devicesRemove": "Odstrániť",
  "devicesRemoveConfirm": "Odstrániť toto zariadenie? Prestane prijímať vaše správy a pri ďalšom pripojení vymaže vaše chaty.",
  "devicesRemoveFailed": "Zariadenie sa nepodarilo odstrániť. Skúste to znova.",
  "devicesScanHint": "Naskenujte kód zobrazený na novom zariadení",
  "devicesFingerprintMismatch": "Tento kód nezodpovedá kľúčom zariadenia. Zariadenie neprepájajte.",
  "devicesWaitingConsent": "Potvrďte prepojenie na novom zariadení.",
  "devicesLinkFailed": "Prepojenie zlyhalo. Skúste to znova.",
  "devicesLinkedTo": "Toto zariadenie je prepojené s {handle}. Prepojené zariadenia sa spravujú tam.",
  "devicesCannotVerify": "Prepojenie tohto zariadenia nemožno overiť. Nič nebolo vymazané.",
  "devicesRemovedNotice": "Toto zariadenie bolo odpojené a jeho chaty boli vymazané.",
  "linkDeviceAction": "Prepojiť s existujúcim zariadením",
  "linkDeviceInstructions": "Na hlavnom telefóne otvorte Nastavenia, Prepojené zariadenia, Prepojiť zariadenie a naskenujte tento kód.",
  "linkDeviceConfirmTitle": "Prepojiť s {handle}?",
  "linkDeviceConfirmBody": "Potvrďte len vtedy, ak {handle} je telefón, ktorý držíte v ruke. Toto zariadenie potom bude prijímať a odosielať správy tohto telefónu.",
  "linkDeviceConfirm": "Prepojiť",
  "linkDeviceNotEmpty": "Prepojiť možno len zariadenie bez kontaktov a chatov.",
  "linkDeviceWaiting": "Čaká sa, kým telefón dokončí prepojenie…",
  "chatDeviceAdded": "Tento kontakt pridal zariadenie",
  "chatDeviceRemoved": "Tento kontakt odstránil zariadenie",
  "chatCompanionBusinessReadOnly": "Firemné chaty možno používať len na hlavnom zariadení."
```

- [ ] **Step 4: `app_de.arb`**

```json
  "settingsDevices": "Verknüpfte Geräte",
  "settingsDevicesSubtitle": "Deine Chats auf einem weiteren Gerät nutzen",
  "devicesEmpty": "Mit diesem Gerät sind keine weiteren Geräte verknüpft.",
  "devicesDeviceLabel": "Gerät {id}",
  "devicesAdd": "Gerät verknüpfen",
  "devicesRemove": "Entfernen",
  "devicesRemoveConfirm": "Dieses Gerät entfernen? Es erhält deine Nachrichten nicht mehr und löscht deine Chats, sobald es sich das nächste Mal verbindet.",
  "devicesRemoveFailed": "Das Gerät konnte nicht entfernt werden. Versuche es erneut.",
  "devicesScanHint": "Scanne den Code, der auf dem neuen Gerät angezeigt wird",
  "devicesFingerprintMismatch": "Dieser Code passt nicht zu den Schlüsseln des Geräts. Nicht verknüpfen.",
  "devicesWaitingConsent": "Bestätige die Verknüpfung auf dem neuen Gerät.",
  "devicesLinkFailed": "Verknüpfen fehlgeschlagen. Versuche es erneut.",
  "devicesLinkedTo": "Dieses Gerät ist mit {handle} verknüpft. Verknüpfte Geräte werden dort verwaltet.",
  "devicesCannotVerify": "Die Verknüpfung dieses Geräts kann nicht überprüft werden. Es wurde nichts gelöscht.",
  "devicesRemovedNotice": "Dieses Gerät wurde entkoppelt und seine Chats wurden gelöscht.",
  "linkDeviceAction": "Mit einem vorhandenen Gerät verknüpfen",
  "linkDeviceInstructions": "Öffne auf deinem Haupttelefon Einstellungen, Verknüpfte Geräte, Gerät verknüpfen und scanne diesen Code.",
  "linkDeviceConfirmTitle": "Mit {handle} verknüpfen?",
  "linkDeviceConfirmBody": "Bestätige nur, wenn {handle} das Telefon in deiner Hand ist. Dieses Gerät empfängt und sendet dann die Nachrichten dieses Telefons.",
  "linkDeviceConfirm": "Verknüpfen",
  "linkDeviceNotEmpty": "Nur ein Gerät ohne Kontakte und Chats kann verknüpft werden.",
  "linkDeviceWaiting": "Warte, bis dein Telefon die Verknüpfung abschließt…",
  "chatDeviceAdded": "Dieser Kontakt hat ein Gerät hinzugefügt",
  "chatDeviceRemoved": "Dieser Kontakt hat ein Gerät entfernt",
  "chatCompanionBusinessReadOnly": "Business-Chats können nur auf deinem Hauptgerät verwendet werden."
```

- [ ] **Step 5: `app_fr.arb`**

```json
  "settingsDevices": "Appareils associés",
  "settingsDevicesSubtitle": "Utilisez vos discussions sur un autre appareil",
  "devicesEmpty": "Aucun autre appareil n'est associé à celui-ci.",
  "devicesDeviceLabel": "Appareil {id}",
  "devicesAdd": "Associer un appareil",
  "devicesRemove": "Retirer",
  "devicesRemoveConfirm": "Retirer cet appareil ? Il ne recevra plus vos messages et supprimera vos discussions à sa prochaine connexion.",
  "devicesRemoveFailed": "Impossible de retirer l'appareil. Réessayez.",
  "devicesScanHint": "Scannez le code affiché sur le nouvel appareil",
  "devicesFingerprintMismatch": "Ce code ne correspond pas aux clés de l'appareil. Ne l'associez pas.",
  "devicesWaitingConsent": "Confirmez l'association sur le nouvel appareil.",
  "devicesLinkFailed": "L'association a échoué. Réessayez.",
  "devicesLinkedTo": "Cet appareil est associé à {handle}. Les appareils associés se gèrent là-bas.",
  "devicesCannotVerify": "L'association de cet appareil ne peut pas être vérifiée. Rien n'a été supprimé.",
  "devicesRemovedNotice": "Cet appareil a été dissocié et ses discussions ont été supprimées.",
  "linkDeviceAction": "Associer à un appareil existant",
  "linkDeviceInstructions": "Sur votre téléphone principal, ouvrez Paramètres, Appareils associés, Associer un appareil, puis scannez ce code.",
  "linkDeviceConfirmTitle": "Associer à {handle} ?",
  "linkDeviceConfirmBody": "Ne confirmez que si {handle} est le téléphone que vous tenez en main. Cet appareil recevra et enverra alors les messages de ce téléphone.",
  "linkDeviceConfirm": "Associer",
  "linkDeviceNotEmpty": "Seul un appareil sans contacts ni discussions peut être associé.",
  "linkDeviceWaiting": "En attente de la fin de l'association sur votre téléphone…",
  "chatDeviceAdded": "Ce contact a ajouté un appareil",
  "chatDeviceRemoved": "Ce contact a retiré un appareil",
  "chatCompanionBusinessReadOnly": "Les discussions professionnelles ne sont disponibles que sur votre appareil principal."
```

- [ ] **Step 6: `app_es.arb`**

```json
  "settingsDevices": "Dispositivos vinculados",
  "settingsDevicesSubtitle": "Usa tus chats en otro dispositivo",
  "devicesEmpty": "No hay otros dispositivos vinculados a este.",
  "devicesDeviceLabel": "Dispositivo {id}",
  "devicesAdd": "Vincular un dispositivo",
  "devicesRemove": "Quitar",
  "devicesRemoveConfirm": "¿Quitar este dispositivo? Dejará de recibir tus mensajes y borrará tus chats la próxima vez que se conecte.",
  "devicesRemoveFailed": "No se pudo quitar el dispositivo. Inténtalo de nuevo.",
  "devicesScanHint": "Escanea el código que aparece en el nuevo dispositivo",
  "devicesFingerprintMismatch": "Este código no coincide con las claves del dispositivo. No lo vincules.",
  "devicesWaitingConsent": "Confirma la vinculación en el nuevo dispositivo.",
  "devicesLinkFailed": "La vinculación falló. Inténtalo de nuevo.",
  "devicesLinkedTo": "Este dispositivo está vinculado a {handle}. Los dispositivos vinculados se gestionan allí.",
  "devicesCannotVerify": "No se puede verificar la vinculación de este dispositivo. No se ha borrado nada.",
  "devicesRemovedNotice": "Este dispositivo se desvinculó y sus chats se borraron.",
  "linkDeviceAction": "Vincular a un dispositivo existente",
  "linkDeviceInstructions": "En tu teléfono principal abre Ajustes, Dispositivos vinculados, Vincular un dispositivo y escanea este código.",
  "linkDeviceConfirmTitle": "¿Vincular a {handle}?",
  "linkDeviceConfirmBody": "Confirma solo si {handle} es el teléfono que tienes en la mano. Este dispositivo recibirá y enviará entonces los mensajes de ese teléfono.",
  "linkDeviceConfirm": "Vincular",
  "linkDeviceNotEmpty": "Solo se puede vincular un dispositivo sin contactos ni chats.",
  "linkDeviceWaiting": "Esperando a que tu teléfono termine la vinculación…",
  "chatDeviceAdded": "Este contacto añadió un dispositivo",
  "chatDeviceRemoved": "Este contacto quitó un dispositivo",
  "chatCompanionBusinessReadOnly": "Los chats de empresa solo se pueden usar en tu dispositivo principal."
```

- [ ] **Step 7: `app_it.arb`**

```json
  "settingsDevices": "Dispositivi collegati",
  "settingsDevicesSubtitle": "Usa le tue chat su un altro dispositivo",
  "devicesEmpty": "Nessun altro dispositivo è collegato a questo.",
  "devicesDeviceLabel": "Dispositivo {id}",
  "devicesAdd": "Collega un dispositivo",
  "devicesRemove": "Rimuovi",
  "devicesRemoveConfirm": "Rimuovere questo dispositivo? Non riceverà più i tuoi messaggi ed eliminerà le tue chat alla prossima connessione.",
  "devicesRemoveFailed": "Impossibile rimuovere il dispositivo. Riprova.",
  "devicesScanHint": "Scansiona il codice mostrato sul nuovo dispositivo",
  "devicesFingerprintMismatch": "Questo codice non corrisponde alle chiavi del dispositivo. Non collegarlo.",
  "devicesWaitingConsent": "Conferma il collegamento sul nuovo dispositivo.",
  "devicesLinkFailed": "Collegamento non riuscito. Riprova.",
  "devicesLinkedTo": "Questo dispositivo è collegato a {handle}. I dispositivi collegati si gestiscono lì.",
  "devicesCannotVerify": "Impossibile verificare il collegamento di questo dispositivo. Non è stato eliminato nulla.",
  "devicesRemovedNotice": "Questo dispositivo è stato scollegato e le sue chat sono state eliminate.",
  "linkDeviceAction": "Collega a un dispositivo esistente",
  "linkDeviceInstructions": "Sul tuo telefono principale apri Impostazioni, Dispositivi collegati, Collega un dispositivo e scansiona questo codice.",
  "linkDeviceConfirmTitle": "Collegare a {handle}?",
  "linkDeviceConfirmBody": "Conferma solo se {handle} è il telefono che hai in mano. Questo dispositivo riceverà e invierà poi i messaggi di quel telefono.",
  "linkDeviceConfirm": "Collega",
  "linkDeviceNotEmpty": "Si può collegare solo un dispositivo senza contatti né chat.",
  "linkDeviceWaiting": "In attesa che il telefono completi il collegamento…",
  "chatDeviceAdded": "Questo contatto ha aggiunto un dispositivo",
  "chatDeviceRemoved": "Questo contatto ha rimosso un dispositivo",
  "chatCompanionBusinessReadOnly": "Le chat aziendali si possono usare solo sul dispositivo principale."
```

- [ ] **Step 8: `app_pt.arb`**

```json
  "settingsDevices": "Dispositivos vinculados",
  "settingsDevicesSubtitle": "Use suas conversas em outro dispositivo",
  "devicesEmpty": "Nenhum outro dispositivo está vinculado a este.",
  "devicesDeviceLabel": "Dispositivo {id}",
  "devicesAdd": "Vincular um dispositivo",
  "devicesRemove": "Remover",
  "devicesRemoveConfirm": "Remover este dispositivo? Ele deixará de receber suas mensagens e apagará suas conversas na próxima vez que se conectar.",
  "devicesRemoveFailed": "Não foi possível remover o dispositivo. Tente novamente.",
  "devicesScanHint": "Escaneie o código exibido no novo dispositivo",
  "devicesFingerprintMismatch": "Este código não corresponde às chaves do dispositivo. Não o vincule.",
  "devicesWaitingConsent": "Confirme a vinculação no novo dispositivo.",
  "devicesLinkFailed": "A vinculação falhou. Tente novamente.",
  "devicesLinkedTo": "Este dispositivo está vinculado a {handle}. Os dispositivos vinculados são gerenciados lá.",
  "devicesCannotVerify": "Não é possível verificar a vinculação deste dispositivo. Nada foi apagado.",
  "devicesRemovedNotice": "Este dispositivo foi desvinculado e suas conversas foram apagadas.",
  "linkDeviceAction": "Vincular a um dispositivo existente",
  "linkDeviceInstructions": "No seu telefone principal abra Configurações, Dispositivos vinculados, Vincular um dispositivo e escaneie este código.",
  "linkDeviceConfirmTitle": "Vincular a {handle}?",
  "linkDeviceConfirmBody": "Confirme apenas se {handle} for o telefone que está na sua mão. Este dispositivo passará a receber e enviar as mensagens desse telefone.",
  "linkDeviceConfirm": "Vincular",
  "linkDeviceNotEmpty": "Só é possível vincular um dispositivo sem contatos e sem conversas.",
  "linkDeviceWaiting": "Aguardando o telefone concluir a vinculação…",
  "chatDeviceAdded": "Este contato adicionou um dispositivo",
  "chatDeviceRemoved": "Este contato removeu um dispositivo",
  "chatCompanionBusinessReadOnly": "As conversas empresariais só podem ser usadas no seu dispositivo principal."
```

- [ ] **Step 9: `app_pl.arb`**

```json
  "settingsDevices": "Połączone urządzenia",
  "settingsDevicesSubtitle": "Korzystaj z czatów na innym urządzeniu",
  "devicesEmpty": "Z tym urządzeniem nie są połączone żadne inne urządzenia.",
  "devicesDeviceLabel": "Urządzenie {id}",
  "devicesAdd": "Połącz urządzenie",
  "devicesRemove": "Usuń",
  "devicesRemoveConfirm": "Usunąć to urządzenie? Przestanie odbierać Twoje wiadomości i usunie Twoje czaty przy następnym połączeniu.",
  "devicesRemoveFailed": "Nie udało się usunąć urządzenia. Spróbuj ponownie.",
  "devicesScanHint": "Zeskanuj kod wyświetlony na nowym urządzeniu",
  "devicesFingerprintMismatch": "Ten kod nie pasuje do kluczy urządzenia. Nie łącz go.",
  "devicesWaitingConsent": "Potwierdź połączenie na nowym urządzeniu.",
  "devicesLinkFailed": "Nie udało się połączyć. Spróbuj ponownie.",
  "devicesLinkedTo": "To urządzenie jest połączone z {handle}. Połączonymi urządzeniami zarządza się tam.",
  "devicesCannotVerify": "Nie można zweryfikować połączenia tego urządzenia. Nic nie zostało usunięte.",
  "devicesRemovedNotice": "To urządzenie zostało odłączone, a jego czaty usunięte.",
  "linkDeviceAction": "Połącz z istniejącym urządzeniem",
  "linkDeviceInstructions": "Na głównym telefonie otwórz Ustawienia, Połączone urządzenia, Połącz urządzenie i zeskanuj ten kod.",
  "linkDeviceConfirmTitle": "Połączyć z {handle}?",
  "linkDeviceConfirmBody": "Potwierdź tylko wtedy, gdy {handle} to telefon, który trzymasz w ręce. To urządzenie będzie wtedy odbierać i wysyłać wiadomości tego telefonu.",
  "linkDeviceConfirm": "Połącz",
  "linkDeviceNotEmpty": "Połączyć można tylko urządzenie bez kontaktów i czatów.",
  "linkDeviceWaiting": "Czekam, aż telefon zakończy łączenie…",
  "chatDeviceAdded": "Ten kontakt dodał urządzenie",
  "chatDeviceRemoved": "Ten kontakt usunął urządzenie",
  "chatCompanionBusinessReadOnly": "Czaty firmowe działają tylko na Twoim głównym urządzeniu."
```

- [ ] **Step 10: `app_nl.arb`**

```json
  "settingsDevices": "Gekoppelde apparaten",
  "settingsDevicesSubtitle": "Gebruik je chats op een ander apparaat",
  "devicesEmpty": "Er zijn geen andere apparaten aan dit apparaat gekoppeld.",
  "devicesDeviceLabel": "Apparaat {id}",
  "devicesAdd": "Een apparaat koppelen",
  "devicesRemove": "Verwijderen",
  "devicesRemoveConfirm": "Dit apparaat verwijderen? Het ontvangt je berichten niet meer en wist je chats zodra het weer verbinding maakt.",
  "devicesRemoveFailed": "Het apparaat kon niet worden verwijderd. Probeer het opnieuw.",
  "devicesScanHint": "Scan de code die op het nieuwe apparaat staat",
  "devicesFingerprintMismatch": "Deze code past niet bij de sleutels van het apparaat. Koppel het niet.",
  "devicesWaitingConsent": "Bevestig de koppeling op het nieuwe apparaat.",
  "devicesLinkFailed": "Koppelen mislukt. Probeer het opnieuw.",
  "devicesLinkedTo": "Dit apparaat is gekoppeld aan {handle}. Gekoppelde apparaten beheer je daar.",
  "devicesCannotVerify": "De koppeling van dit apparaat kan niet worden geverifieerd. Er is niets gewist.",
  "devicesRemovedNotice": "Dit apparaat is ontkoppeld en de chats erop zijn gewist.",
  "linkDeviceAction": "Koppelen aan een bestaand apparaat",
  "linkDeviceInstructions": "Open op je hoofdtelefoon Instellingen, Gekoppelde apparaten, Een apparaat koppelen en scan deze code.",
  "linkDeviceConfirmTitle": "Koppelen aan {handle}?",
  "linkDeviceConfirmBody": "Bevestig alleen als {handle} de telefoon in je hand is. Dit apparaat ontvangt en verstuurt dan de berichten van die telefoon.",
  "linkDeviceConfirm": "Koppelen",
  "linkDeviceNotEmpty": "Alleen een apparaat zonder contacten en chats kan worden gekoppeld.",
  "linkDeviceWaiting": "Wachten tot je telefoon het koppelen afrondt…",
  "chatDeviceAdded": "Dit contact heeft een apparaat toegevoegd",
  "chatDeviceRemoved": "Dit contact heeft een apparaat verwijderd",
  "chatCompanionBusinessReadOnly": "Zakelijke chats kun je alleen op je hoofdapparaat gebruiken."
```

- [ ] **Step 11: `app_uk.arb`**

```json
  "settingsDevices": "Прив'язані пристрої",
  "settingsDevicesSubtitle": "Користуйтеся чатами на іншому пристрої",
  "devicesEmpty": "До цього пристрою не прив'язано інших пристроїв.",
  "devicesDeviceLabel": "Пристрій {id}",
  "devicesAdd": "Прив'язати пристрій",
  "devicesRemove": "Видалити",
  "devicesRemoveConfirm": "Видалити цей пристрій? Він перестане отримувати ваші повідомлення й видалить ваші чати під час наступного підключення.",
  "devicesRemoveFailed": "Не вдалося видалити пристрій. Спробуйте ще раз.",
  "devicesScanHint": "Відскануйте код, показаний на новому пристрої",
  "devicesFingerprintMismatch": "Цей код не відповідає ключам пристрою. Не прив'язуйте його.",
  "devicesWaitingConsent": "Підтвердьте прив'язку на новому пристрої.",
  "devicesLinkFailed": "Не вдалося прив'язати. Спробуйте ще раз.",
  "devicesLinkedTo": "Цей пристрій прив'язано до {handle}. Прив'язаними пристроями керують там.",
  "devicesCannotVerify": "Не вдається перевірити прив'язку цього пристрою. Нічого не видалено.",
  "devicesRemovedNotice": "Цей пристрій відв'язано, а його чати видалено.",
  "linkDeviceAction": "Прив'язати до наявного пристрою",
  "linkDeviceInstructions": "На основному телефоні відкрийте Налаштування, Прив'язані пристрої, Прив'язати пристрій і відскануйте цей код.",
  "linkDeviceConfirmTitle": "Прив'язати до {handle}?",
  "linkDeviceConfirmBody": "Підтверджуйте, лише якщо {handle} є телефоном у вашій руці. Тоді цей пристрій отримуватиме й надсилатиме повідомлення цього телефона.",
  "linkDeviceConfirm": "Прив'язати",
  "linkDeviceNotEmpty": "Прив'язати можна лише пристрій без контактів і чатів.",
  "linkDeviceWaiting": "Очікування, доки телефон завершить прив'язку…",
  "chatDeviceAdded": "Цей контакт додав пристрій",
  "chatDeviceRemoved": "Цей контакт видалив пристрій",
  "chatCompanionBusinessReadOnly": "Бізнес-чати можна використовувати лише на основному пристрої."
```

- [ ] **Step 12: `app_ro.arb`**

```json
  "settingsDevices": "Dispozitive asociate",
  "settingsDevicesSubtitle": "Folosește-ți conversațiile pe alt dispozitiv",
  "devicesEmpty": "Niciun alt dispozitiv nu este asociat cu acesta.",
  "devicesDeviceLabel": "Dispozitiv {id}",
  "devicesAdd": "Asociază un dispozitiv",
  "devicesRemove": "Elimină",
  "devicesRemoveConfirm": "Elimini acest dispozitiv? Nu îți va mai primi mesajele și îți va șterge conversațiile la următoarea conectare.",
  "devicesRemoveFailed": "Dispozitivul nu a putut fi eliminat. Încearcă din nou.",
  "devicesScanHint": "Scanează codul afișat pe noul dispozitiv",
  "devicesFingerprintMismatch": "Acest cod nu se potrivește cu cheile dispozitivului. Nu îl asocia.",
  "devicesWaitingConsent": "Confirmă asocierea pe noul dispozitiv.",
  "devicesLinkFailed": "Asocierea a eșuat. Încearcă din nou.",
  "devicesLinkedTo": "Acest dispozitiv este asociat cu {handle}. Dispozitivele asociate se gestionează acolo.",
  "devicesCannotVerify": "Asocierea acestui dispozitiv nu poate fi verificată. Nu s-a șters nimic.",
  "devicesRemovedNotice": "Acest dispozitiv a fost disociat și conversațiile lui au fost șterse.",
  "linkDeviceAction": "Asociază cu un dispozitiv existent",
  "linkDeviceInstructions": "Pe telefonul principal deschide Setări, Dispozitive asociate, Asociază un dispozitiv și scanează acest cod.",
  "linkDeviceConfirmTitle": "Asociezi cu {handle}?",
  "linkDeviceConfirmBody": "Confirmă doar dacă {handle} este telefonul din mâna ta. Acest dispozitiv va primi și va trimite apoi mesajele acelui telefon.",
  "linkDeviceConfirm": "Asociază",
  "linkDeviceNotEmpty": "Doar un dispozitiv fără contacte și conversații poate fi asociat.",
  "linkDeviceWaiting": "Se așteaptă ca telefonul să termine asocierea…",
  "chatDeviceAdded": "Acest contact a adăugat un dispozitiv",
  "chatDeviceRemoved": "Acest contact a eliminat un dispozitiv",
  "chatCompanionBusinessReadOnly": "Conversațiile de business pot fi folosite doar pe dispozitivul principal."
```

- [ ] **Step 13: `app_hu.arb`**

```json
  "settingsDevices": "Összekapcsolt eszközök",
  "settingsDevicesSubtitle": "Használd a csevegéseidet egy másik eszközön",
  "devicesEmpty": "Ehhez az eszközhöz nincs más eszköz kapcsolva.",
  "devicesDeviceLabel": "Eszköz: {id}",
  "devicesAdd": "Eszköz összekapcsolása",
  "devicesRemove": "Eltávolítás",
  "devicesRemoveConfirm": "Eltávolítod ezt az eszközt? Nem kapja tovább az üzeneteidet, és a következő csatlakozáskor törli a csevegéseidet.",
  "devicesRemoveFailed": "Az eszközt nem sikerült eltávolítani. Próbáld újra.",
  "devicesScanHint": "Olvasd be az új eszközön látható kódot",
  "devicesFingerprintMismatch": "Ez a kód nem egyezik az eszköz kulcsaival. Ne kapcsold össze.",
  "devicesWaitingConsent": "Erősítsd meg az összekapcsolást az új eszközön.",
  "devicesLinkFailed": "Az összekapcsolás nem sikerült. Próbáld újra.",
  "devicesLinkedTo": "Ez az eszköz ehhez van kapcsolva: {handle}. Az összekapcsolt eszközöket ott kezelheted.",
  "devicesCannotVerify": "Az eszköz összekapcsolása nem ellenőrizhető. Semmi sem lett törölve.",
  "devicesRemovedNotice": "Ezt az eszközt leválasztották, a csevegései törölve lettek.",
  "linkDeviceAction": "Összekapcsolás meglévő eszközzel",
  "linkDeviceInstructions": "A fő telefonodon nyisd meg a Beállítások, Összekapcsolt eszközök, Eszköz összekapcsolása menüt, és olvasd be ezt a kódot.",
  "linkDeviceConfirmTitle": "Összekapcsolod ezzel: {handle}?",
  "linkDeviceConfirmBody": "Csak akkor erősítsd meg, ha a(z) {handle} a kezedben lévő telefon. Ez az eszköz ezután fogadja és küldi annak a telefonnak az üzeneteit.",
  "linkDeviceConfirm": "Összekapcsolás",
  "linkDeviceNotEmpty": "Csak névjegyek és csevegések nélküli eszköz kapcsolható össze.",
  "linkDeviceWaiting": "Várakozás, amíg a telefon befejezi az összekapcsolást…",
  "chatDeviceAdded": "Ez a névjegy hozzáadott egy eszközt",
  "chatDeviceRemoved": "Ez a névjegy eltávolított egy eszközt",
  "chatCompanionBusinessReadOnly": "Az üzleti csevegések csak a fő eszközödön használhatók."
```

- [ ] **Step 14: `app_zh.arb`**

```json
  "settingsDevices": "已关联的设备",
  "settingsDevicesSubtitle": "在另一台设备上使用您的聊天",
  "devicesEmpty": "没有其他设备与此设备关联。",
  "devicesDeviceLabel": "设备 {id}",
  "devicesAdd": "关联设备",
  "devicesRemove": "移除",
  "devicesRemoveConfirm": "移除此设备？它将不再接收您的消息，并会在下次连接时删除您的聊天。",
  "devicesRemoveFailed": "无法移除该设备。请重试。",
  "devicesScanHint": "扫描新设备上显示的二维码",
  "devicesFingerprintMismatch": "此二维码与该设备的密钥不匹配。请勿关联。",
  "devicesWaitingConsent": "请在新设备上确认关联。",
  "devicesLinkFailed": "关联失败。请重试。",
  "devicesLinkedTo": "此设备已关联到 {handle}。已关联的设备在那里管理。",
  "devicesCannotVerify": "无法验证此设备的关联。未删除任何内容。",
  "devicesRemovedNotice": "此设备已解除关联，其聊天已被删除。",
  "linkDeviceAction": "关联到现有设备",
  "linkDeviceInstructions": "在您的主手机上依次打开 设置、已关联的设备、关联设备，然后扫描此二维码。",
  "linkDeviceConfirmTitle": "关联到 {handle}？",
  "linkDeviceConfirmBody": "仅当 {handle} 是您手中的手机时才确认。之后此设备将接收和发送该手机的消息。",
  "linkDeviceConfirm": "关联",
  "linkDeviceNotEmpty": "只有没有联系人和聊天的设备才能被关联。",
  "linkDeviceWaiting": "正在等待手机完成关联…",
  "chatDeviceAdded": "此联系人添加了一台设备",
  "chatDeviceRemoved": "此联系人移除了一台设备",
  "chatCompanionBusinessReadOnly": "企业聊天只能在您的主设备上使用。"
```

- [ ] **Step 15: `app_hi.arb`**

```json
  "settingsDevices": "लिंक किए गए डिवाइस",
  "settingsDevicesSubtitle": "अपनी चैट दूसरे डिवाइस पर इस्तेमाल करें",
  "devicesEmpty": "इस डिवाइस से कोई और डिवाइस लिंक नहीं है।",
  "devicesDeviceLabel": "डिवाइस {id}",
  "devicesAdd": "डिवाइस लिंक करें",
  "devicesRemove": "हटाएँ",
  "devicesRemoveConfirm": "यह डिवाइस हटाएँ? इसे आपके संदेश मिलने बंद हो जाएँगे और अगली बार कनेक्ट होने पर यह आपकी चैट मिटा देगा।",
  "devicesRemoveFailed": "डिवाइस हटाया नहीं जा सका। फिर कोशिश करें।",
  "devicesScanHint": "नए डिवाइस पर दिखाया गया कोड स्कैन करें",
  "devicesFingerprintMismatch": "यह कोड डिवाइस की कुंजियों से मेल नहीं खाता। इसे लिंक न करें।",
  "devicesWaitingConsent": "नए डिवाइस पर लिंक की पुष्टि करें।",
  "devicesLinkFailed": "लिंक नहीं हो सका। फिर कोशिश करें।",
  "devicesLinkedTo": "यह डिवाइस {handle} से लिंक है। लिंक किए गए डिवाइस वहीं से प्रबंधित होते हैं।",
  "devicesCannotVerify": "इस डिवाइस के लिंक की पुष्टि नहीं हो सकती। कुछ भी नहीं मिटाया गया।",
  "devicesRemovedNotice": "यह डिवाइस अनलिंक कर दिया गया और इसकी चैट मिटा दी गईं।",
  "linkDeviceAction": "किसी मौजूदा डिवाइस से लिंक करें",
  "linkDeviceInstructions": "अपने मुख्य फ़ोन पर सेटिंग्स, लिंक किए गए डिवाइस, डिवाइस लिंक करें खोलें और यह कोड स्कैन करें।",
  "linkDeviceConfirmTitle": "{handle} से लिंक करें?",
  "linkDeviceConfirmBody": "पुष्टि तभी करें जब {handle} आपके हाथ में मौजूद फ़ोन हो। इसके बाद यह डिवाइस उस फ़ोन के संदेश पाएगा और भेजेगा।",
  "linkDeviceConfirm": "लिंक करें",
  "linkDeviceNotEmpty": "सिर्फ़ बिना संपर्कों और चैट वाला डिवाइस ही लिंक किया जा सकता है।",
  "linkDeviceWaiting": "फ़ोन के लिंक पूरा करने का इंतज़ार है…",
  "chatDeviceAdded": "इस संपर्क ने एक डिवाइस जोड़ा",
  "chatDeviceRemoved": "इस संपर्क ने एक डिवाइस हटाया",
  "chatCompanionBusinessReadOnly": "बिज़नेस चैट सिर्फ़ आपके मुख्य डिवाइस पर इस्तेमाल हो सकती हैं।"
```

- [ ] **Step 16: `app_ar.arb`**

```json
  "settingsDevices": "الأجهزة المرتبطة",
  "settingsDevicesSubtitle": "استخدم محادثاتك على جهاز آخر",
  "devicesEmpty": "لا توجد أجهزة أخرى مرتبطة بهذا الجهاز.",
  "devicesDeviceLabel": "الجهاز {id}",
  "devicesAdd": "ربط جهاز",
  "devicesRemove": "إزالة",
  "devicesRemoveConfirm": "إزالة هذا الجهاز؟ سيتوقف عن تلقي رسائلك وسيحذف محادثاتك عند اتصاله التالي.",
  "devicesRemoveFailed": "تعذّرت إزالة الجهاز. حاول مرة أخرى.",
  "devicesScanHint": "امسح الرمز الظاهر على الجهاز الجديد",
  "devicesFingerprintMismatch": "هذا الرمز لا يطابق مفاتيح الجهاز. لا تربطه.",
  "devicesWaitingConsent": "أكّد الربط على الجهاز الجديد.",
  "devicesLinkFailed": "فشل الربط. حاول مرة أخرى.",
  "devicesLinkedTo": "هذا الجهاز مرتبط بـ {handle}. تتم إدارة الأجهزة المرتبطة من هناك.",
  "devicesCannotVerify": "لا يمكن التحقق من ربط هذا الجهاز. لم يُحذف أي شيء.",
  "devicesRemovedNotice": "تم فك ربط هذا الجهاز وحُذفت محادثاته.",
  "linkDeviceAction": "الربط بجهاز موجود",
  "linkDeviceInstructions": "على هاتفك الرئيسي افتح الإعدادات، ثم الأجهزة المرتبطة، ثم ربط جهاز، وامسح هذا الرمز.",
  "linkDeviceConfirmTitle": "الربط بـ {handle}؟",
  "linkDeviceConfirmBody": "لا تؤكد إلا إذا كان {handle} هو الهاتف الذي في يدك. سيستقبل هذا الجهاز بعد ذلك رسائل ذلك الهاتف ويرسلها.",
  "linkDeviceConfirm": "ربط",
  "linkDeviceNotEmpty": "لا يمكن ربط إلا جهاز بلا جهات اتصال ولا محادثات.",
  "linkDeviceWaiting": "في انتظار أن يُكمل هاتفك الربط…",
  "chatDeviceAdded": "أضافت جهة الاتصال هذه جهازًا",
  "chatDeviceRemoved": "أزالت جهة الاتصال هذه جهازًا",
  "chatCompanionBusinessReadOnly": "لا يمكن استخدام محادثات الأعمال إلا على جهازك الرئيسي."
```

- [ ] **Step 17: `app_ru.arb`**

```json
  "settingsDevices": "Связанные устройства",
  "settingsDevicesSubtitle": "Используйте чаты на другом устройстве",
  "devicesEmpty": "К этому устройству не привязаны другие устройства.",
  "devicesDeviceLabel": "Устройство {id}",
  "devicesAdd": "Привязать устройство",
  "devicesRemove": "Удалить",
  "devicesRemoveConfirm": "Удалить это устройство? Оно перестанет получать ваши сообщения и удалит ваши чаты при следующем подключении.",
  "devicesRemoveFailed": "Не удалось удалить устройство. Попробуйте снова.",
  "devicesScanHint": "Отсканируйте код, показанный на новом устройстве",
  "devicesFingerprintMismatch": "Этот код не соответствует ключам устройства. Не привязывайте его.",
  "devicesWaitingConsent": "Подтвердите привязку на новом устройстве.",
  "devicesLinkFailed": "Не удалось привязать. Попробуйте снова.",
  "devicesLinkedTo": "Это устройство привязано к {handle}. Связанными устройствами управляют там.",
  "devicesCannotVerify": "Не удаётся проверить привязку этого устройства. Ничего не удалено.",
  "devicesRemovedNotice": "Это устройство отвязано, его чаты удалены.",
  "linkDeviceAction": "Привязать к существующему устройству",
  "linkDeviceInstructions": "На основном телефоне откройте Настройки, Связанные устройства, Привязать устройство и отсканируйте этот код.",
  "linkDeviceConfirmTitle": "Привязать к {handle}?",
  "linkDeviceConfirmBody": "Подтверждайте, только если {handle} является телефоном у вас в руке. Тогда это устройство будет получать и отправлять сообщения этого телефона.",
  "linkDeviceConfirm": "Привязать",
  "linkDeviceNotEmpty": "Привязать можно только устройство без контактов и чатов.",
  "linkDeviceWaiting": "Ожидание, пока телефон завершит привязку…",
  "chatDeviceAdded": "Этот контакт добавил устройство",
  "chatDeviceRemoved": "Этот контакт удалил устройство",
  "chatCompanionBusinessReadOnly": "Бизнес-чаты доступны только на основном устройстве."
```

- [ ] **Step 18: `app_ja.arb`**

```json
  "settingsDevices": "リンク済みデバイス",
  "settingsDevicesSubtitle": "別のデバイスでチャットを使う",
  "devicesEmpty": "このデバイスにリンクされている他のデバイスはありません。",
  "devicesDeviceLabel": "デバイス {id}",
  "devicesAdd": "デバイスをリンク",
  "devicesRemove": "削除",
  "devicesRemoveConfirm": "このデバイスを削除しますか？メッセージを受信しなくなり、次回接続時にチャットが削除されます。",
  "devicesRemoveFailed": "デバイスを削除できませんでした。もう一度お試しください。",
  "devicesScanHint": "新しいデバイスに表示されたコードをスキャンしてください",
  "devicesFingerprintMismatch": "このコードはデバイスの鍵と一致しません。リンクしないでください。",
  "devicesWaitingConsent": "新しいデバイスでリンクを確認してください。",
  "devicesLinkFailed": "リンクに失敗しました。もう一度お試しください。",
  "devicesLinkedTo": "このデバイスは {handle} にリンクされています。リンク済みデバイスはそちらで管理します。",
  "devicesCannotVerify": "このデバイスのリンクを確認できません。何も削除されていません。",
  "devicesRemovedNotice": "このデバイスはリンク解除され、チャットは削除されました。",
  "linkDeviceAction": "既存のデバイスにリンク",
  "linkDeviceInstructions": "メインの電話で 設定、リンク済みデバイス、デバイスをリンク を開き、このコードをスキャンしてください。",
  "linkDeviceConfirmTitle": "{handle} にリンクしますか？",
  "linkDeviceConfirmBody": "{handle} が手元の電話である場合にのみ確認してください。このデバイスはその電話のメッセージを送受信するようになります。",
  "linkDeviceConfirm": "リンク",
  "linkDeviceNotEmpty": "連絡先とチャットのないデバイスのみリンクできます。",
  "linkDeviceWaiting": "電話がリンクを完了するのを待っています…",
  "chatDeviceAdded": "この連絡先がデバイスを追加しました",
  "chatDeviceRemoved": "この連絡先がデバイスを削除しました",
  "chatCompanionBusinessReadOnly": "ビジネスチャットはメインのデバイスでのみ使用できます。"
```

- [ ] **Step 19: `app_tr.arb`**

```json
  "settingsDevices": "Bağlı cihazlar",
  "settingsDevicesSubtitle": "Sohbetlerinizi başka bir cihazda kullanın",
  "devicesEmpty": "Bu cihaza bağlı başka cihaz yok.",
  "devicesDeviceLabel": "Cihaz {id}",
  "devicesAdd": "Cihaz bağla",
  "devicesRemove": "Kaldır",
  "devicesRemoveConfirm": "Bu cihaz kaldırılsın mı? Mesajlarınızı artık almaz ve bir sonraki bağlantıda sohbetlerinizi siler.",
  "devicesRemoveFailed": "Cihaz kaldırılamadı. Tekrar deneyin.",
  "devicesScanHint": "Yeni cihazda gösterilen kodu tarayın",
  "devicesFingerprintMismatch": "Bu kod cihazın anahtarlarıyla eşleşmiyor. Bağlamayın.",
  "devicesWaitingConsent": "Bağlantıyı yeni cihazda onaylayın.",
  "devicesLinkFailed": "Bağlama başarısız oldu. Tekrar deneyin.",
  "devicesLinkedTo": "Bu cihaz {handle} ile bağlı. Bağlı cihazlar orada yönetilir.",
  "devicesCannotVerify": "Bu cihazın bağlantısı doğrulanamıyor. Hiçbir şey silinmedi.",
  "devicesRemovedNotice": "Bu cihazın bağlantısı kaldırıldı ve sohbetleri silindi.",
  "linkDeviceAction": "Mevcut bir cihaza bağla",
  "linkDeviceInstructions": "Ana telefonunuzda Ayarlar, Bağlı cihazlar, Cihaz bağla bölümünü açın ve bu kodu tarayın.",
  "linkDeviceConfirmTitle": "{handle} ile bağlansın mı?",
  "linkDeviceConfirmBody": "Yalnızca {handle} elinizdeki telefonsa onaylayın. Bu cihaz bundan sonra o telefonun mesajlarını alıp gönderecek.",
  "linkDeviceConfirm": "Bağla",
  "linkDeviceNotEmpty": "Yalnızca kişi ve sohbet içermeyen bir cihaz bağlanabilir.",
  "linkDeviceWaiting": "Telefonunuzun bağlamayı tamamlaması bekleniyor…",
  "chatDeviceAdded": "Bu kişi bir cihaz ekledi",
  "chatDeviceRemoved": "Bu kişi bir cihazı kaldırdı",
  "chatCompanionBusinessReadOnly": "İş sohbetleri yalnızca ana cihazınızda kullanılabilir."
```

- [ ] **Step 20: Generate and run the l10n guards**

Run (in `src/client/calltype`): `flutter gen-l10n && flutter test test/l10n`
Expected: PASS; `build/l10n_untranslated.json` is `{}`. Then `grep -c "settingsDevices" lib/l10n/app_*.arb` prints 1 for every file except `app_en.arb` (2, with the `@` block).

- [ ] **Step 21: Commit**

```bash
git add src/client/calltype/lib/l10n/*.arb
git commit -m "feat(app): multi-device strings in all 19 languages

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: App - DeviceService and wiring

`DeviceService` is the app-wide owner of the directory. It exists before onboarding (the inbox is built at startup) and is opened once the device has an id. It refreshes the device's OWN list (on `DeviceListChanged`, on every hub connect, after its own PUT), wipes a verified-removed companion, shows "cannot verify" otherwise, writes the device-change lines for contacts, and signs the primary's list. The app still sends and receives the old way after this task.

**Files:**
- Create: `src/client/calltype/lib/features/devices/device_service.dart`
- Create: `src/client/calltype/test/helpers/fake_multi_device_server.dart`
- Modify: `src/client/calltype/lib/main.dart`, `src/client/calltype/lib/app/router.dart`
- Test: `src/client/calltype/test/features/devices/device_service_test.dart`

- [ ] **Step 1: Write the test helper**

Create `test/helpers/fake_multi_device_server.dart`:

```dart
import 'dart:async';

import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:dio/dio.dart';

import 'test_device.dart';

/// In-memory stand-in for the parts of the API and hub that multi-device
/// needs. Like the real server it stores device lists as opaque signed bytes
/// and never verifies them, and its fan-out completeness check mirrors
/// MessengerHub.FanoutAsync, so clients are tested against the real rules.
class FakeMultiDeviceServer {
  final devices = <String, TestDevice>{};

  /// primary id -> the GET /devices/{id}/device-list body.
  final lists = <String, Map<String, dynamic>>{};

  /// companion id -> primary id (the server's DeviceListMembers).
  final members = <String, String>{};
  final groups = <String, List<String>>{};
  final inboxes = <String, StreamController<Map<String, dynamic>>>{};

  /// Every device id a client asked the list for, in order.
  final deviceListRequests = <String>[];
  final hubs = <String, FakeHubClient>{};
  final _services = <DeviceService>[];

  void add(TestDevice device) {
    devices[device.id] = device;
    inboxes[device.id] = StreamController<Map<String, dynamic>>();
  }

  String primaryOf(String deviceId) => members[deviceId] ?? deviceId;

  Set<String> devicesOf(String identityId) => {
    identityId,
    for (final e in members.entries)
      if (e.value == identityId) e.key,
  };

  /// The GET body of [primaryId]'s list, signed by [signer], naming
  /// [entries] as (device id, device whose keys and consent go into the entry).
  Future<Map<String, dynamic>> signedList(
    TestDevice signer,
    String primaryId,
    int version,
    List<(String, TestDevice)> entries,
  ) async {
    final signed = await signDeviceList(
      primarySigningKey: await signer.keys.getSigningKeyPair(),
      list: DeviceList(
        primaryDeviceId: primaryId,
        version: version,
        devices: [
          for (final (id, owner) in entries)
            DeviceListEntry(
              deviceId: id,
              identityKey: await owner.keys.getPublicIdentityKey(),
              signingKey:
                  (await owner.keys.getSignedIdentityBundle())['signingKey']!,
              consentSig: await signDeviceLinkConsent(
                companionSigningKey: await owner.keys.getSigningKeyPair(),
                primaryDeviceId: primaryId,
                companionDeviceId: id,
              ),
            ),
        ],
      ),
    );
    return {
      'primaryDeviceId': primaryId,
      'version': version,
      'payload': signed.payload,
      'signature': signed.signature,
    };
  }

  /// [primary] signs a list of [companions], as a successful PUT would store it.
  Future<void> link(
    TestDevice primary,
    List<TestDevice> companions, {
    required int version,
  }) async => store(
    await signedList(primary, primary.id, version, [
      for (final c in companions) (c.id, c),
    ]),
  );

  void store(Map<String, dynamic> body) {
    final primary = body['primaryDeviceId'] as String;
    lists[primary] = body;
    members.removeWhere((_, p) => p == primary);
    for (final d in parseDeviceListPayload(body['payload'] as String).devices) {
      members[d.deviceId] = primary;
    }
  }

  /// MessengerHub.FanoutAsync: the declared devices must be exactly every
  /// device of the target identities and of the sender's own identity, minus
  /// the sending device; otherwise `device_list_stale:<required>`.
  void fanout({
    required String sender,
    required Set<String> identities,
    required String messageId,
    required Map<String, String> payloads,
    String? groupId,
  }) {
    final required = <String>{
      for (final identity in {...identities, primaryOf(sender)})
        ...devicesOf(identity),
    }..remove(sender);
    final declared = payloads.keys.toSet();
    if (declared.length != required.length || !declared.containsAll(required)) {
      throw Exception('HubException: device_list_stale:${required.join(',')}');
    }
    for (final entry in payloads.entries) {
      inboxes[entry.key]?.add({
        'senderId': sender,
        'messageId': messageId,
        'encryptedBody': entry.value,
        'groupId': groupId,
      });
    }
  }

  /// [device]'s view of device lists, against this server.
  DeviceDirectory directoryFor(TestDevice device) => DeviceDirectory(
    database: device.db,
    apiClient: FakeDeviceApi(this),
    selfDeviceId: device.id,
    selfSigningKey: () async =>
        (await device.keys.getSignedIdentityBundle())['signingKey']!,
    selfIdentityKey: device.keys.getPublicIdentityKey,
  );

  /// What a first message does before a list can be verified: a session with
  /// the primary, which pins its keys.
  Future<void> Function(String) pinFor(TestDevice device) => (id) async {
    if (!await device.sessions.hasSession(id)) {
      await device.sessions.initiateSession(id, await devices[id]!.keyBundle());
    }
  };

  /// An opened DeviceService for [device]; its hub is [hubs][device.id].
  Future<DeviceService> deviceServiceFor(TestDevice device) async {
    final hub = hubs[device.id] = FakeHubClient(this, device.id);
    final service = DeviceService(
      database: device.db,
      apiClient: FakeDeviceApi(this),
      keyManager: device.keys,
      sessionManager: device.sessions,
      signalRClient: hub,
    );
    await service.open(device.id);
    _services.add(service);
    return service;
  }

  Future<void> close() async {
    for (final service in _services) {
      service.dispose();
    }
    for (final hub in hubs.values) {
      hub.dispose();
    }
    // Not awaited: close() of a single-subscription controller that never
    // had a listener completes only when somebody listens, i.e. never.
    for (final inbox in inboxes.values) {
      unawaited(inbox.close());
    }
  }
}

class FakeDeviceApi extends ApiClient {
  FakeDeviceApi(this.server) : super(baseUrl: 'http://unused');
  final FakeMultiDeviceServer server;

  @override
  Future<Map<String, dynamic>> getKeyBundle(String deviceId) =>
      server.devices[deviceId]!.keyBundle();

  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async {
    server.deviceListRequests.add(deviceId);
    return server.lists[server.primaryOf(deviceId)];
  }

  /// Only the rule the client must handle (version must grow); the consent
  /// and membership rules are covered by the server's own tests.
  @override
  Future<void> putDeviceList(
    String primaryDeviceId, {
    required String payload,
    required String signature,
  }) async {
    final version = parseDeviceListPayload(payload).version;
    final current = server.lists[primaryDeviceId]?['version'] as int?;
    if (current != null && version <= current) {
      final request = RequestOptions(path: '/devices/$primaryDeviceId/device-list');
      throw DioException(
        requestOptions: request,
        response: Response(
          requestOptions: request,
          statusCode: 409,
          data: {'error': 'device_list_version_conflict'},
        ),
      );
    }
    server.store({
      'primaryDeviceId': primaryDeviceId,
      'version': version,
      'payload': payload,
      'signature': signature,
    });
  }

  @override
  Future<List<String>> getGroupMembers(String groupId) async =>
      server.groups[groupId]!;
}

/// The app's SignalRClient with the hub replaced by [FakeMultiDeviceServer]
/// and the link / list events injectable by the test.
class FakeHubClient extends SignalRClient {
  FakeHubClient(this.server, String deviceId)
    : super(baseUrl: 'http://unused', deviceId: deviceId);
  final FakeMultiDeviceServer server;
  final offers = StreamController<Map<String, dynamic>>.broadcast();
  final consents = StreamController<Map<String, dynamic>>.broadcast();
  final listChanged = StreamController<Map<String, dynamic>>.broadcast();
  final sentOffers = <String>[];
  final sentConsents = <(String, String)>[];
  final acks = <String>[];

  @override
  Stream<Map<String, dynamic>> get onLinkOffer => offers.stream;
  @override
  Stream<Map<String, dynamic>> get onLinkConsent => consents.stream;
  @override
  Stream<Map<String, dynamic>> get onDeviceListChanged => listChanged.stream;

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => server.fanout(
    sender: deviceId,
    identities: {recipientIdentityId},
    messageId: messageId,
    payloads: encryptedPayloads,
  );

  @override
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async => server.fanout(
    sender: deviceId,
    identities: server.groups[groupId]!.toSet(),
    messageId: messageId,
    payloads: encryptedPayloads,
    groupId: groupId,
  );

  @override
  Future<void> acknowledgeMessage(String senderId, String messageId) async =>
      acks.add(messageId);

  @override
  Future<void> sendLinkOffer(String targetDeviceId) async =>
      sentOffers.add(targetDeviceId);

  @override
  Future<void> sendLinkConsent(String primaryDeviceId, String consentSig) async =>
      sentConsents.add((primaryDeviceId, consentSig));

  @override
  void dispose() {
    offers.close();
    consents.close();
    listChanged.close();
    super.dispose();
  }
}

/// Polls [condition]. DeviceService reacts to list changes on a stream, so
/// tests wait for the effect instead of guessing how many event-loop turns
/// it takes. Plain `test()` only (real time).
Future<void> until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition never held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
```

- [ ] **Step 2: Write the failing DeviceService tests**

Create `test/features/devices/device_service_test.dart`:

```dart
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const bobWebId = 'b0000000-0000-4000-8000-000000000002';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;
  late TestDevice bob;
  late TestDevice bobWeb;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    phone = await TestDevice.create(phoneId);
    web = await TestDevice.create(webId);
    bob = await TestDevice.create(bobId);
    bobWeb = await TestDevice.create(bobWebId);
    for (final d in [phone, web, bob, bobWeb]) {
      server.add(d);
    }
  });

  tearDown(() async {
    await server.close();
    for (final d in [phone, web, bob, bobWeb]) {
      await d.close();
    }
  });

  /// The web device after the phone linked it and the hint arrived.
  Future<DeviceService> linkedWeb() async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(web);
    service.expectLink(phoneId);
    await service.checkOwnList(phoneId);
    return service;
  }

  Future<void> addChat(TestDevice device, String peer) async {
    await device.db
        .into(device.db.conversations)
        .insert(ConversationsCompanion.insert(id: peer, type: 'direct'));
    await device.db
        .into(device.db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'hello-$peer',
            conversationId: peer,
            senderId: peer,
            body: const Value('hello'),
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<List<Message>> deviceLines(TestDevice device) =>
      (device.db.select(device.db.messages)
            ..where((m) => m.type.equals('device-change')))
          .get();

  test('a verified list makes this device a companion of the primary', () async {
    final service = await linkedWeb();
    expect(service.isCompanion, isTrue);
    expect(service.directory.selfIdentityId, phoneId);
    expect(service.status, CompanionStatus.ok);
  });

  test('a verified removal wipes the companion, which is a plain device again', () async {
    final service = await linkedWeb();
    await addChat(web, bobId);
    await server.link(phone, [], version: 2);
    await service.checkOwnList();
    await until(() => service.status == CompanionStatus.removed);
    expect(await web.db.select(web.db.messages).get(), isEmpty);
    expect(await web.db.select(web.db.conversations).get(), isEmpty);
    expect(service.isCompanion, isFalse);
    expect(service.directory.selfIdentityId, webId);
  });

  test('a list that does not verify, or no list at all, deletes nothing', () async {
    final service = await linkedWeb();
    await addChat(web, bobId);
    // The server serves a "removal" that the phone did not sign.
    server.lists[phoneId] = await server.signedList(bob, phoneId, 2, []);
    await service.checkOwnList();
    expect(service.status, CompanionStatus.cannotVerify);
    // The server pretends the list is gone.
    server.lists.remove(phoneId);
    server.members.remove(webId);
    await service.checkOwnList();
    expect(service.status, CompanionStatus.cannotVerify);
    expect(await web.db.select(web.db.messages).get(), hasLength(1));
    expect(service.isCompanion, isTrue);
  });

  test('a contact who links a device gets one line in the chat; a first fetch and our own list do not', () async {
    final service = await server.deviceServiceFor(phone);
    await addChat(phone, bobId);
    // First list ever stored for Bob, already with a companion: no line.
    await server.link(bob, [bobWeb], version: 1);
    await service.directory.refresh(bobId, ensurePinned: server.pinFor(phone));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await deviceLines(phone), isEmpty);
    // Bob removes and re-adds the device: two verified versions apart, so
    // each change is a line.
    await server.link(bob, [], version: 2);
    await service.directory.refresh(bobId, ensurePinned: server.pinFor(phone));
    await until(() async => (await deviceLines(phone)).length == 1);
    expect((await deviceLines(phone)).single.body, 'removed');
    await server.link(bob, [bobWeb], version: 3);
    await service.directory.refresh(bobWebId, ensurePinned: server.pinFor(phone));
    await until(() async => (await deviceLines(phone)).length == 2);
    final line = (await deviceLines(phone)).firstWhere((m) => m.body == 'added');
    expect(line.conversationId, bobId);
    expect(line.senderId, bobId);

    await server.link(phone, [web], version: 1);
    await service.checkOwnList(phoneId);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await deviceLines(phone), hasLength(2));
  });

  test('removing a companion signs the next version and stores it', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(phone);
    await service.checkOwnList(phoneId);
    expect((await service.companions()).map((d) => d.deviceId), [webId]);

    await service.removeCompanions({webId});

    expect(server.lists[phoneId]!['version'], 2);
    expect(await service.companions(), isEmpty);
    expect(await service.directory.devicesOf(phoneId), [phoneId]);
  });

  test('a version conflict reloads the newer list and signs on top of it', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(phone);
    await service.checkOwnList(phoneId);
    // An edit whose result this device never stored is already at version 3.
    await server.link(phone, [web], version: 3);

    await service.removeCompanions({webId});

    expect(server.lists[phoneId]!['version'], 4);
    expect(await service.companions(), isEmpty);
  });

  test('a stale answer without one of our companions re-signs without it', () async {
    await server.link(phone, [web], version: 1);
    final service = await server.deviceServiceFor(phone);
    await service.checkOwnList(phoneId);

    await service.dropVanishedCompanions({bobId});
    expect(await service.companions(), isEmpty);
    // Nothing vanished any more: no further version.
    await service.dropVanishedCompanions({bobId});
    expect(server.lists[phoneId]!['version'], 2);
  });

  test('a list-changed hint for a foreign identity is ignored', () async {
    await server.deviceServiceFor(phone);
    await server.link(bob, [bobWeb], version: 1);
    server.hubs[phoneId]!.listChanged.add({'primaryDeviceId': bobId, 'version': 1});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.deviceListRequests, isEmpty);
  });
}
```

- [ ] **Step 3: Run them, verify they fail**

Run (in `src/client/calltype`): `flutter test test/features/devices/device_service_test.dart`
Expected: compile error, `device_service.dart` does not exist.

- [ ] **Step 4: Implement `DeviceService`**

Create `lib/features/devices/device_service.dart`:

```dart
import 'dart:async';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/crypto/key_manager.dart';
import '../../core/crypto/session_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import '../chat/message_inbox_service.dart' show MessageProcessingQueue;

/// What a companion knows about its own link (shown on the chat list).
enum CompanionStatus {
  /// Not a companion, or a companion whose list verified.
  ok,

  /// The list this companion is in is missing or does not verify. Nothing is
  /// deleted: otherwise the server could force a wipe by lying (spec Part A,
  /// "Removing a device").
  cannotVerify,

  /// A verified, newer list no longer contains this device; its chats were
  /// deleted.
  removed,
}

/// BackupState key: the handle of the primary this device is linked to.
/// The hub's LinkOffer carries it; it is shown on the companion and used for
/// its "My identity" invite.
const linkedPrimaryHandleKey = 'linked_primary_handle';

/// App-wide owner of this device's multi-device state (spec Part A).
///
/// Built before onboarding (the inbox needs a reference at startup) and
/// [open]ed once the device has an id. Every list refresh it starts runs in
/// [MessageProcessingQueue]: a refresh may create a session (ratchet state),
/// and the inbox and the outbox refresh through the same queue.
class DeviceService extends ChangeNotifier {
  DeviceService({
    required AppDatabase database,
    required ApiClient apiClient,
    required KeyManager keyManager,
    required SessionManager sessionManager,
    required SignalRClient signalRClient,
  }) : _db = database,
       _api = apiClient,
       _keys = keyManager,
       _sessions = sessionManager,
       _signalR = signalRClient;

  final AppDatabase _db;
  final ApiClient _api;
  final KeyManager _keys;
  final SessionManager _sessions;
  final SignalRClient _signalR;
  static const _uuid = Uuid();

  DeviceDirectory? _directory;
  StreamSubscription<DeviceListChange>? _changes;
  StreamSubscription<Map<String, dynamic>>? _hints;
  CompanionStatus _status = CompanionStatus.ok;
  String? _pendingPrimary;
  bool _disposed = false;

  bool get isOpen => _directory != null;

  DeviceDirectory get directory =>
      _directory ?? (throw StateError('This device is not registered yet.'));

  bool get isCompanion => _directory?.isCompanion ?? false;

  CompanionStatus get status => _status;

  /// Loads the verified lists for [deviceId]. Routing reads
  /// `selfIdentityId`, so this must finish before the hub delivers the first
  /// message (constraint 8).
  Future<void> open(String deviceId) async {
    if (_directory != null) return;
    final directory = DeviceDirectory(
      database: _db,
      apiClient: _api,
      selfDeviceId: deviceId,
      selfSigningKey: () async =>
          (await _keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: _keys.getPublicIdentityKey,
    );
    await directory.load();
    _directory = directory;
    _changes = directory.changes.listen(
      (change) => unawaited(_onChange(change).catchError((Object _) {})),
    );
    _hints = _signalR.onDeviceListChanged.listen((event) {
      final primary = (event['primaryDeviceId'] as String?)?.toLowerCase();
      // The event is only a hint to refetch and verify. Only our own
      // identity, or the primary we just consented to join, is worth a fetch:
      // anything else would let the server make us pin and store arbitrary
      // identities.
      if (primary == null ||
          (primary != directory.selfIdentityId && primary != _pendingPrimary)) {
        return;
      }
      unawaited(checkOwnList(primary));
    });
    _notify();
  }

  /// The new device consented to join [primaryDeviceId]; its next list hint
  /// is the one that makes this device a companion.
  void expectLink(String primaryDeviceId) =>
      _pendingPrimary = primaryDeviceId.toLowerCase();

  Future<String?> linkedPrimaryHandle() async =>
      (await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals(linkedPrimaryHandleKey))).getSingleOrNull())
          ?.value;

  /// Re-reads and verifies the list this device belongs to: on a
  /// DeviceListChanged hint, on every hub connect (a hint sent while we were
  /// offline is lost) and after our own PUT (fan-out targets come from the
  /// STORED list, constraint 5).
  Future<void> checkOwnList([String? primaryDeviceId]) =>
      MessageProcessingQueue.forDatabase(_db).run(() async {
        final directory = _directory;
        if (directory == null) return;
        // Most devices never link anything: no own list and not a companion
        // means there is nothing to re-check, and a reconnect costs nothing.
        if (primaryDeviceId == null &&
            !directory.isCompanion &&
            await _ownList() == null) {
          return;
        }
        try {
          await directory.refresh(
            primaryDeviceId ?? directory.selfIdentityId,
            ensurePinned: _ensureSession,
          );
          // refresh() answers null both for "unchanged" and for "the server
          // has no list". Only the second matters for a companion, and only a
          // direct look tells them apart.
          if (directory.isCompanion &&
              await _api.getDeviceList(directory.selfDeviceId) == null) {
            _setStatus(CompanionStatus.cannotVerify);
            return;
          }
        } on DeviceListException {
          if (directory.isCompanion) _setStatus(CompanionStatus.cannotVerify);
          return;
        } catch (_) {
          // Offline, 429 or 5xx: no verdict about the list either way.
          return;
        }
        if (_status == CompanionStatus.cannotVerify) {
          _setStatus(CompanionStatus.ok);
        }
      });

  Future<void> _onChange(DeviceListChange change) async {
    final directory = _directory!;
    if (change.removed.contains(directory.selfDeviceId)) {
      await _wipe();
      return;
    }
    if (change.added.contains(directory.selfDeviceId)) {
      _pendingPrimary = null;
      _setStatus(CompanionStatus.ok);
      return;
    }
    // Our own identity (as primary or as companion): screens re-read, but no
    // line; the user linked that device themselves.
    if (change.identityId == directory.selfIdentityId) {
      _notify();
      return;
    }
    // Only a change between two verified versions is news. The first list
    // we ever store for somebody may be years old; showing it as "added a
    // device" would be noise.
    if (change.firstList) return;
    await _noteDeviceChange(change);
  }

  /// Spec Part A, "What a peer sees": nothing happens silently, same
  /// principle as the visible auditor. One line per direction, not per
  /// device: the fact matters, not the count.
  Future<void> _noteDeviceChange(DeviceListChange change) async {
    final conversation = await (_db.select(
      _db.conversations,
    )..where((c) => c.id.equals(change.identityId))).getSingleOrNull();
    // ponytail: direct conversations only. A group would need the line in
    // every group shared with that person; add it when users ask for it.
    if (conversation == null || conversation.type != 'direct') return;
    final now = DateTime.now();
    for (final (kind, devices) in [
      ('added', change.added),
      ('removed', change.removed),
    ]) {
      if (devices.isEmpty) continue;
      await _db
          .into(_db.messages)
          .insert(
            MessagesCompanion.insert(
              id: _uuid.v4(),
              conversationId: change.identityId,
              senderId: change.identityId,
              body: Value(kind),
              type: const Value('device-change'),
              status: const Value('delivered'),
              createdAt: now,
              receivedAt: Value(now),
            ),
          );
    }
  }

  /// A verified, newer list without this device: delete what it holds of the
  /// identity's conversations. Keys and registration stay, so the device is
  /// simply an empty, standalone device again.
  Future<void> _wipe() => MessageProcessingQueue.forDatabase(_db).run(() async {
    await _db.transaction(() async {
      await _db.delete(_db.messages).go();
      await _db.delete(_db.conversations).go();
      await _db.delete(_db.contacts).go();
      await _db.delete(_db.knownDeviceListMembers).go();
      await _db.delete(_db.knownDeviceLists).go();
      await (_db.delete(_db.backupState)..where(
            (s) =>
                s.key.like('outbox:%') |
                s.key.like('control:%') |
                s.key.equals(linkedPrimaryHandleKey),
          ))
          .go();
    });
    await _directory!.load();
    _setStatus(CompanionStatus.removed);
  });

  Future<KnownDeviceList?> _ownList() => (_db.select(
    _db.knownDeviceLists,
  )..where((l) => l.primaryDeviceId.equals(directory.selfDeviceId))).getSingleOrNull();

  /// The companions in this primary's own verified list.
  Future<List<DeviceListEntry>> companions() async {
    final own = await _ownList();
    return own == null ? const [] : parseDeviceListPayload(own.payload).devices;
  }

  Future<void> addCompanion(DeviceListEntry entry) => _publish(
    (current) => [
      for (final d in current)
        if (d.deviceId != entry.deviceId) d,
      entry,
    ],
  );

  Future<void> removeCompanions(Set<String> deviceIds) => _publish(
    (current) => [
      for (final d in current)
        if (!deviceIds.contains(d.deviceId)) d,
    ],
  );

  /// Constraint 5: a stale answer that leaves out one of OUR companions means
  /// the server no longer knows that device (it deleted itself). Re-sign
  /// without it; otherwise every peer pays a stale round trip per message and
  /// the next PUT fails with device_list_unknown_device.
  Future<void> dropVanishedCompanions(Set<String> required) async {
    final directory = _directory;
    if (directory == null || directory.isCompanion) return;
    final own = (await directory.devicesOf(directory.selfDeviceId)).skip(1);
    final vanished = own.toSet().difference(required);
    if (vanished.isEmpty) return;
    try {
      await removeCompanions(vanished);
    } catch (_) {
      // Retried by the next stale answer.
    }
  }

  /// Signs version + 1 of this primary's list with [edit] applied and
  /// uploads it (spec Part A, steps 5 and "Removing a device").
  Future<void> _publish(
    List<DeviceListEntry> Function(List<DeviceListEntry> current) edit,
  ) async {
    final directory = this.directory;
    if (directory.isCompanion) {
      throw StateError('Only the primary device signs its device list.');
    }
    for (var attempt = 1; ; attempt++) {
      final own = await _ownList();
      final signed = await signDeviceList(
        primarySigningKey: await _keys.getSigningKeyPair(),
        list: DeviceList(
          primaryDeviceId: directory.selfDeviceId,
          version: (own?.version ?? 0) + 1,
          devices: edit(
            own == null ? const [] : parseDeviceListPayload(own.payload).devices,
          ),
        ),
      );
      try {
        await _api.putDeviceList(
          directory.selfDeviceId,
          payload: signed.payload,
          signature: signed.signature,
        );
        break;
      } on DioException catch (e) {
        final data = e.response?.data;
        final conflict =
            data is Map && data['error'] == 'device_list_version_conflict';
        // Two edits at once (spec Part C): load the newer list and sign
        // version + 1 of it. Bounded, so a server that keeps answering 409
        // produces an error instead of a loop.
        if (!conflict || attempt == 3) rethrow;
        await checkOwnList(directory.selfDeviceId);
      }
    }
    await checkOwnList(directory.selfDeviceId);
    _notify();
  }

  Future<void> _ensureSession(String deviceId) async {
    if (!await _sessions.hasSession(deviceId)) {
      await _sessions.initiateSession(deviceId, await _api.getKeyBundle(deviceId));
    }
  }

  void _setStatus(CompanionStatus status) {
    _status = status;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.cancel();
    _hints?.cancel();
    super.dispose();
  }
}
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `flutter test test/features/devices/device_service_test.dart`
Expected: PASS (8 tests).

- [ ] **Step 6: Wire it into the app**

`lib/main.dart`: add `import 'features/devices/device_service.dart';`. Directly after `final sessionManager = SessionManager(database: db, keyManager: keyManager);` insert:

```dart

  // Multi-device: owns the verified device lists, the companion state and the
  // device's own list. Opened before the inbox can see a message: routing
  // needs selfIdentityId (constraint 8). A fresh install opens it in the
  // onboarding route instead.
  final devices = DeviceService(
    database: db,
    apiClient: apiClient,
    keyManager: keyManager,
    sessionManager: sessionManager,
    signalRClient: signalRClient,
  );
  if (deviceId.isNotEmpty) await devices.open(deviceId);
```

In the `signalRClient.addListener` callback replace

```dart
    if (connected && !wasConnected) {
      unawaited(channels.sync().catchError((Object _) {}));
    }
```

with

```dart
    if (connected && !wasConnected) {
      unawaited(channels.sync().catchError((Object _) {}));
      // A DeviceListChanged hint sent while this device was offline is lost,
      // so a (re)connect re-checks the own list (cheap no-op when unlinked).
      if (devices.isOpen) unawaited(devices.checkOwnList());
    }
```

In the providers list add after `ChangeNotifierProvider.value(value: webrtcManager),`:

```dart
        ChangeNotifierProvider.value(value: devices),
```

`lib/app/router.dart`: add `import '../features/devices/device_service.dart';`. In the onboarding route replace

```dart
            onRegistered: (id) async {
              final connection = ctx.read<SignalRClient>();
```

with

```dart
            onRegistered: (id) async {
              // Before connecting: the inbox routes through the directory from
              // the first queued message on.
              await ctx.read<DeviceService>().open(id);
              final connection = ctx.read<SignalRClient>();
```

- [ ] **Step 7: Analyze and run the whole app suite**

Run: `flutter analyze && flutter test`
Expected: no issues, all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add src/client/calltype/lib/features/devices/device_service.dart src/client/calltype/lib/main.dart src/client/calltype/lib/app/router.dart src/client/calltype/test/helpers/fake_multi_device_server.dart src/client/calltype/test/features/devices/device_service_test.dart
git commit -m "feat(app): device service owns device lists, companion wipe and own-list signing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: App - identity split (`myIdentityId`)

`myDeviceId` meant both "transport address" and "me". From here on `ChatController.myIdentityId` (read from the directory) is "me" in conversations; `SignalRClient.deviceId` and `WebRTCManager` keep the transport id (decision 4).

**Files:**
- Modify: `src/client/calltype/lib/features/chat/chat_controller.dart`, `chat_screen.dart`, `mentions.dart`, `lib/app/router.dart`
- Modify: `src/client/calltype/test/helpers/test_device.dart`
- Test: `test/features/chat/chat_controller_test.dart`, `message_actions_flow_test.dart`, `mentions_test.dart`, `test/features/contacts/bot_badge_test.dart`

- [ ] **Step 1: Give TestDevice a directory**

In `test/helpers/test_device.dart` add the imports

```dart
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype_core/devices/device_directory.dart';
```

add inside `TestDevice` (after `final SessionManager sessions;`):

```dart
  /// This device's view of device lists. Its API answers "no list" for
  /// everybody, which is the single-device world most tests live in (and
  /// avoids a DNS lookup of the dummy base URL); tests that need lists build
  /// a directory against FakeMultiDeviceServer instead.
  late final DeviceDirectory directory = DeviceDirectory(
    database: db,
    apiClient: NoDeviceListsApi(),
    selfDeviceId: id,
    selfSigningKey: () async =>
        (await keys.getSignedIdentityBundle())['signingKey']!,
    selfIdentityKey: keys.getPublicIdentityKey,
  );
```

and at the end of the file:

```dart
/// An API with no device lists at all.
class NoDeviceListsApi extends ApiClient {
  NoDeviceListsApi() : super(baseUrl: 'http://unused');
  @override
  Future<Map<String, dynamic>?> getDeviceList(String deviceId) async => null;
}
```

- [ ] **Step 2: Update the tests to the new constructor (they become the failing tests)**

- `test/features/chat/chat_controller_test.dart` and `test/features/chat/message_actions_flow_test.dart`: replace every `myDeviceId: alice.id,` with `directory: alice.directory,`.
- `test/features/chat/mentions_test.dart`: replace every `myDeviceId:` with `myIdentityId:`.
- `test/features/contacts/bot_badge_test.dart`: add `import 'package:calltype_core/devices/device_directory.dart';`; in `pumpChat` replace

```dart
    final sessions = SessionManager(
      database: db,
      keyManager: KeyManager(secureStorage: InMemorySecureStorage()),
    );
```

with

```dart
    final keys = KeyManager(secureStorage: InMemorySecureStorage());
    final sessions = SessionManager(database: db, keyManager: keys);
    final directory = DeviceDirectory(
      database: db,
      apiClient: NoDeviceListsApi(),
      selfDeviceId: 'me',
      selfSigningKey: () async =>
          (await keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: keys.getPublicIdentityKey,
    );
```

and `myDeviceId: 'me',` with `directory: directory,`.

Add one test to `chat_controller_test.dart` (inside `main()`):

```dart
  test('on a companion, own messages are stored under the identity id', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final web = await TestDevice.create('web');
    final bob = await TestDevice.create('bob');
    // What a verified list leaves behind: 'web' belongs to identity 'phone'.
    await web.db
        .into(web.db.knownDeviceListMembers)
        .insert(
          KnownDeviceListMembersCompanion.insert(
            deviceId: 'web',
            primaryDeviceId: 'phone',
          ),
        );
    await web.directory.load();
    await web.db
        .into(web.db.conversations)
        .insert(ConversationsCompanion.insert(id: bob.id, type: 'direct'));
    final transport = Transport()..fail = true;
    final inbox = MessageInboxService(
      database: web.db,
      sessionManager: web.sessions,
      incomingMessages: const Stream.empty(),
    );
    final controller = ChatController(
      database: web.db,
      signalRClient: transport,
      sessionManager: web.sessions,
      inbox: inbox,
      apiClient: ChatApi([bob]),
      conversationId: bob.id,
      directory: web.directory,
    );

    expect(controller.myIdentityId, 'phone');
    expect(controller.isCompanion, isTrue);
    await controller.sendMessage('hi');
    expect((await web.db.select(web.db.messages).getSingle()).senderId, 'phone');

    controller.dispose();
    await inbox.dispose();
    transport.dispose();
    await web.close();
    await bob.close();
  });
```

- [ ] **Step 3: Run them, verify they fail**

Run: `flutter test test/features/chat test/features/contacts/bot_badge_test.dart`
Expected: compile errors (`directory` / `myIdentityId` are not defined).

- [ ] **Step 4: Implement**

`lib/features/chat/chat_controller.dart`:
- Add `import 'package:calltype_core/devices/device_directory.dart';`.
- In the constructor replace `required this.myDeviceId,` with `required DeviceDirectory directory,` and replace the initializer list

```dart
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient {
```

with

```dart
  }) : _db = database,
       _signalR = signalRClient,
       _sessions = sessionManager,
       _api = apiClient,
       _directory = directory {
```

- Replace the field line `  final String myDeviceId;` with:

```dart
  final DeviceDirectory _directory;

  /// "Me" in this conversation: the IDENTITY id (the primary device id),
  /// which `messages.senderId` stores for every device of this user. Equals
  /// the device id unless this device is a companion; the transport id is
  /// SignalRClient.deviceId.
  String get myIdentityId => _directory.selfIdentityId;

  /// v1: a companion has no calls and no business conversations.
  bool get isCompanion => _directory.isCompanion;
```

- Replace every remaining `myDeviceId` in the file with `myIdentityId` (in `businessCallTarget`, `deleteForEveryone` twice, `_send`, `retryMessage` twice).

`lib/features/chat/chat_screen.dart`: replace every `myDeviceId` with `myIdentityId` (three places: `_authorLabel`, the `mine` flag in the list, `buildMentionCandidates`).

`lib/features/chat/mentions.dart`: replace both `myDeviceId` with `myIdentityId` (the `buildMentionCandidates` parameter and its use).

`lib/app/router.dart`: in the `/chats/:id` route replace `myDeviceId: ctx.read<SignalRClient>().deviceId,` with `directory: ctx.read<DeviceService>().directory,`.

- [ ] **Step 5: Run the tests, verify they pass**

Run: `flutter analyze && flutter test`
Expected: no issues, all tests PASS. `grep -rn "myDeviceId" lib test` lists only `WebRTCManager` and its tests (`webrtc_manager.dart`, `main.dart`, `webrtc_manager_test.dart`, `call_screen_test.dart`, `session_overlay_call_test.dart`, `widget_test.dart`).

- [ ] **Step 6: Commit**

```bash
git add src/client/calltype/lib/features/chat src/client/calltype/lib/app/router.dart src/client/calltype/test
git commit -m "refactor(app): chat uses the identity id, transport keeps the device id

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: App - inbox routes through the directory

Constraints 1, 2 and 8: refresh an unknown sender once before decrypting (never a contact row before that), `assertListedKeys` after every decrypt (drop on mismatch), the identity in `senderId`, the transport id in the ack, own copies filed under `to` without touching unread.

**Files:**
- Modify: `src/client/calltype/lib/features/chat/message_inbox_service.dart`, `lib/main.dart`
- Modify (constructor calls): `test/features/chat/message_inbox_service_test.dart`, `chat_controller_test.dart`, `message_actions_flow_test.dart`, `test/features/calls/call_event_sender_test.dart`, `test/features/contacts/bot_badge_test.dart`
- Test: `src/client/calltype/test/features/chat/message_inbox_multi_device_test.dart` (new)

- [ ] **Step 1: Write the failing tests**

Create `test/features/chat/message_inbox_multi_device_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';
const malloryId = 'c0000000-0000-4000-8000-000000000001';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice aPhone;
  late TestDevice aWeb;
  late TestDevice bob;
  late TestDevice mallory;
  late StreamController<Map<String, dynamic>> wire;
  late List<(String, String)> acks;
  var next = 0;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    aPhone = await TestDevice.create(aPhoneId);
    aWeb = await TestDevice.create(aWebId);
    bob = await TestDevice.create(bobId);
    mallory = await TestDevice.create(malloryId);
    for (final d in [aPhone, aWeb, bob, mallory]) {
      server.add(d);
    }
    wire = StreamController<Map<String, dynamic>>();
    acks = [];
  });

  tearDown(() async {
    unawaited(wire.close());
    await server.close();
    for (final d in [aPhone, aWeb, bob, mallory]) {
      await d.close();
    }
  });

  /// Starts [receiver]'s inbox on [wire], with a directory backed by the
  /// fake server.
  Future<DeviceDirectory> inboxOf(TestDevice receiver) async {
    final directory = server.directoryFor(receiver);
    await directory.load();
    final inbox = MessageInboxService(
      database: receiver.db,
      sessionManager: receiver.sessions,
      incomingMessages: wire.stream,
      apiClient: FakeDeviceApi(server),
      directory: () => directory,
      acknowledge: (sender, id) async => acks.add((sender, id)),
    )..start();
    addTearDown(inbox.dispose);
    return directory;
  }

  /// [from] encrypts a direct text for [to] and the hub delivers it.
  Future<String> deliver(
    TestDevice from,
    TestDevice to,
    String body, {
    String? toConversation,
  }) async {
    if (!await from.sessions.hasSession(to.id)) {
      await from.sessions.initiateSession(to.id, await to.keyBundle());
    }
    final id = 'm-${next++}';
    final cipher = await from.sessions.encryptMessage(
      to.id,
      jsonEncode({
        'v': 1,
        'id': id,
        'body': body,
        'type': 'text',
        'groupId': null,
        'to': ?toConversation,
      }),
    );
    wire.add({
      'senderId': from.id,
      'messageId': id,
      'encryptedBody': base64Encode(utf8.encode(cipher)),
      'groupId': null,
    });
    await Future<void>.delayed(Duration.zero);
    await MessageProcessingQueue.forDatabase(to.db).run(() async {});
    return id;
  }

  test('a contact\'s companion lands in the contact\'s chat, under the contact\'s id', () async {
    await server.link(aPhone, [aWeb], version: 1);
    await inboxOf(bob);
    final id = await deliver(aWeb, bob, 'from the web');
    final row = await bob.db.select(bob.db.messages).getSingle();
    expect(row.conversationId, aPhoneId);
    expect(row.senderId, aPhoneId);
    expect(row.status, 'delivered');
    // Acknowledged with the TRANSPORT sender: the server queues per device.
    expect(acks, [(aWebId, id)]);
  });

  test('a copy from our own other device goes to `to`, as sent and not unread', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final directory = await inboxOf(aPhone);
    await directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await deliver(aWeb, aPhone, 'sent from the web', toConversation: bobId);
    final row = await aPhone.db.select(aPhone.db.messages).getSingle();
    expect(row.conversationId, bobId);
    expect(row.senderId, aPhoneId);
    expect(row.status, 'sent');
    expect(
      (await aPhone.db.select(aPhone.db.conversations).getSingle()).unreadCount,
      0,
    );
  });

  test('an own copy without `to` is refused and stays queued', () async {
    await server.link(aPhone, [aWeb], version: 1);
    final directory = await inboxOf(aPhone);
    await directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await deliver(aWeb, aPhone, 'nowhere');
    expect(await aPhone.db.select(aPhone.db.messages).get(), isEmpty);
    expect(acks, isEmpty);
  });

  test('a device whose keys differ from its signed entry is dropped but acknowledged', () async {
    // A's list names A's web device with Mallory's keys (her consent included).
    server.store(await server.signedList(aPhone, aPhoneId, 1, [(aWebId, mallory)]));
    await inboxOf(bob);
    final id = await deliver(aWeb, bob, 'who am I');
    expect(await bob.db.select(bob.db.messages).get(), isEmpty);
    expect(acks, [(aWebId, id)]);
  });

  test('an unknown sender is looked up once, not once per message', () async {
    await inboxOf(bob);
    await deliver(mallory, bob, 'one');
    await deliver(mallory, bob, 'two');
    expect(server.deviceListRequests, [malloryId]);
    expect(await bob.db.select(bob.db.messages).get(), hasLength(2));
  });
}
```

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/features/chat/message_inbox_multi_device_test.dart`
Expected: compile error, `MessageInboxService` has no parameter `directory`.

- [ ] **Step 3: Implement**

In `lib/features/chat/message_inbox_service.dart` add the imports

```dart
import 'package:calltype_core/crypto/device_list.dart' show DeviceListException;
import 'package:calltype_core/devices/device_directory.dart';
```

Replace the class doc, the constructor and the fields of `MessageInboxService` (from `/// Persists incoming messages before acknowledging their server queue entries.` down to and including `final Future<void> Function(String, String)? _acknowledge;`) with:

```dart
/// Persists incoming messages before acknowledging their server queue entries.
///
/// Multi-device: the hub's `senderId` is the sending DEVICE. [directory]
/// turns it into the identity that `messages.senderId` stores and decides
/// the conversation: a contact's companion lands in the contact's
/// conversation, a copy from one of our own devices in the one named by `to`.
class MessageInboxService {
  MessageInboxService({
    required AppDatabase database,
    required SessionManager sessionManager,
    required Stream<Map<String, dynamic>> incomingMessages,
    required DeviceDirectory Function() directory,
    ApiClient? apiClient,
    Future<void> Function(String senderId, String messageId)? acknowledge,
  }) : _db = database,
       _sessionManager = sessionManager,
       _incoming = incomingMessages,
       _directory = directory,
       _api = apiClient,
       _acknowledge = acknowledge;

  final AppDatabase _db;
  final SessionManager _sessionManager;
  final Stream<Map<String, dynamic>> _incoming;

  /// A getter, not the directory itself: the app builds the inbox at startup,
  /// before onboarding has given a fresh install its id (DeviceService.open).
  final DeviceDirectory Function() _directory;

  /// Fetches the key bundle of a sender's PRIMARY when its list must be
  /// verified (the primary's pin is the trust anchor).
  final ApiClient? _api;

  final Future<void> Function(String, String)? _acknowledge;
```

Replace `_handleIncoming` entirely with:

```dart
  Future<void> _handleIncoming(Map<String, dynamic> data) async {
    try {
      final senderId = data['senderId'] as String?;
      final messageId = data['messageId'] as String?;
      final groupId = data['groupId'] as String?;
      if (senderId == null ||
          senderId.isEmpty ||
          messageId == null ||
          messageId.isEmpty) {
        throw const FormatException('Missing message identity');
      }
      final directory = _directory();
      // A `delete` control message never gets a messages row, so redelivery
      // (ack lost) is recognised by this marker instead of the row below.
      // Replaying it would otherwise fail in the ratchet and stay queued.
      final handled = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('control:$messageId'))).getSingleOrNull();
      if (handled != null) {
        await _acknowledge?.call(senderId, messageId);
        return;
      }
      final existing = await (_db.select(
        _db.messages,
      )..where((m) => m.id.equals(messageId))).getSingleOrNull();
      if (existing != null) {
        // Rows store the sender's IDENTITY (a companion's message is filed
        // under its primary), so a redelivery is compared with that.
        if (existing.senderId != await directory.identityOf(senderId) ||
            (groupId != null && existing.conversationId != groupId)) {
          throw const FormatException('Conflicting message identity');
        }
        await _acknowledge?.call(senderId, messageId);
        return;
      }
      // Constraint 1: a device we never talked to may be a companion of
      // somebody we know. Look it up once, before decrypting, and only then:
      // a known sender has a session, so this costs nothing per message. No
      // contact row is created here (that would mark the device as claimed).
      if (await directory.identityOf(senderId) == senderId.toLowerCase() &&
          !await _sessionManager.hasSession(senderId)) {
        try {
          await directory.refresh(senderId, ensurePinned: _ensureSession);
        } catch (_) {
          // No verified list: the sender stays a standalone device, exactly
          // as before multi-device. Attribution is never forced.
        }
      }
      // Membership was authorized by the relay when it accepted the message.
      // Current membership can differ after an offline recipient reconnects.
      Message? inserted;
      await _db.transaction(() async {
        final envelope = utf8.decode(
          base64Decode(data['encryptedBody'] as String),
        );
        final plaintext = await _sessionManager.decryptMessage(
          senderId,
          envelope,
          deferPreKeyCleanup: true,
        );
        // Constraint 2: the keys this device used (pinned by the decrypt
        // above) must be the keys its primary signed into the list. On a
        // mismatch the message is DROPPED: the ratchet step commits with this
        // transaction, so it is not decrypted again, and the caller
        // acknowledges it, but it is never stored or shown.
        try {
          await directory.assertListedKeys(senderId);
        } on DeviceListException {
          return;
        }
        final payload = jsonDecode(plaintext) as Map<String, dynamic>;
        if (payload['v'] != 1 ||
            payload['id'] != messageId ||
            payload['groupId'] != groupId ||
            payload['body'] is! String) {
          throw const FormatException(
            'Encrypted message context does not match delivery',
          );
        }
        final type = payload['type'] as String? ?? 'text';
        // 'delete' is a control message added after the first release. An OLD
        // client throws here, so the message stays queued on the server for
        // it (accepted: that client keeps showing the original message).
        if (type != 'text' &&
            type != 'file' &&
            type != 'call-event' &&
            type != 'delete') {
          throw const FormatException('Unsupported message type');
        }
        // Who sent it and where it belongs. `to` is honoured only for copies
        // from our own devices (DeviceDirectory.routeInbound): a peer cannot
        // steer a message into another conversation with it.
        final to = payload['to'];
        final route = await directory.routeInbound(
          senderDeviceId: senderId,
          groupId: groupId,
          to: to is String ? to : null,
        );
        final conversationId = route.conversationId;
        if (type == 'delete') {
          await _applyDelete(
            targetId: payload['body'] as String,
            senderId: route.senderIdentityId,
            conversationId: conversationId,
          );
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'control:$messageId',
                  value: '1',
                ),
              );
          return;
        }
        if (type == 'file') Attachment.decode(payload['body'] as String);
        final now = DateTime.now();
        final createdAt =
            DateTime.tryParse(payload['createdAt'] as String? ?? '') ?? now;
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingleOrNull();
        if (conversation == null) {
          await _db
              .into(_db.conversations)
              .insert(
                ConversationsCompanion.insert(
                  id: conversationId,
                  type: groupId == null ? 'direct' : 'group',
                  title: Value(
                    groupId == null ? null : payload['groupName'] as String?,
                  ),
                ),
              );
        } else if (conversation.type !=
            (groupId == null ? 'direct' : 'group')) {
          throw const FormatException('Conflicting conversation type');
        }
        // WHY defensive: replyTo is attacker-controlled JSON; a malformed one
        // must drop the quote, never the message. The preview is the SENDER's
        // claim about what was quoted (same limit as WhatsApp): we cannot
        // verify it against the original, which we may not even have.
        final replyTo = payload['replyTo'];
        String? replyToId, replySenderId, replyPreview;
        if (replyTo is Map &&
            replyTo['id'] is String &&
            replyTo['senderId'] is String &&
            replyTo['preview'] is String) {
          replyToId = replyTo['id'] as String;
          replySenderId = replyTo['senderId'] as String;
          final preview = replyTo['preview'] as String;
          replyPreview = preview.length > maxReplyPreview
              ? preview.substring(0, maxReplyPreview)
              : preview;
        }
        await _db
            .into(_db.messages)
            .insert(
              MessagesCompanion.insert(
                id: messageId,
                conversationId: conversationId,
                senderId: route.senderIdentityId,
                body: Value(payload['body'] as String),
                type: Value(type),
                // A copy of what our other device sent is OUR message: shown
                // as sent, like on the device that wrote it.
                status: Value(route.own ? 'sent' : 'delivered'),
                createdAt: createdAt,
                receivedAt: Value(route.own ? null : now),
                replyToId: Value(replyToId),
                replySenderId: Value(replySenderId),
                replyPreview: Value(replyPreview),
                forwarded: Value(payload['forwarded'] == true),
              ),
            );
        await (_db.update(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).write(
          ConversationsCompanion(
            lastMessageAt: Value(now),
            // A call-event is a log line and an own copy was written by us:
            // neither is something to "read" (H2).
            unreadCount: Value(
              (conversation?.unreadCount ?? 0) +
                  (route.own || type == 'call-event' ? 0 : 1),
            ),
          ),
        );
        inserted = await (_db.select(
          _db.messages,
        )..where((m) => m.id.equals(messageId))).getSingle();
      });
      await _sessionManager.finalizePreKeyCleanup();
      if (inserted != null) _persisted.add(inserted!);
      await _acknowledge?.call(senderId, messageId);
    } catch (error) {
      // Leave failures queued on the server; never report corrupt ciphertext as delivered.
      _errors.add(error);
    }
  }

  Future<void> _ensureSession(String deviceId) async {
    final api = _api;
    if (api == null) throw StateError('No API client to fetch a key bundle.');
    if (!await _sessionManager.hasSession(deviceId)) {
      await _sessionManager.initiateSession(
        deviceId,
        await api.getKeyBundle(deviceId),
      );
    }
  }
```

`lib/main.dart`: in `MessageInboxService(` add after `incomingMessages: signalRClient.onMessage,`:

```dart
    directory: () => devices.directory,
```

Existing tests: add a `directory:` argument right after the `sessionManager:` argument of every `MessageInboxService(` call:
- `test/features/chat/message_inbox_service_test.dart` (receiver bob): `directory: () => bob.directory,`
- `test/features/chat/chat_controller_test.dart` (all 4 calls, plus the one added in Task 6, which uses `web`): `directory: () => alice.directory,` / `directory: () => web.directory,`
- `test/features/chat/message_actions_flow_test.dart`: the inbox group (receiver bob) `directory: () => bob.directory,`; the controller group (alice) `directory: () => alice.directory,`
- `test/features/calls/call_event_sender_test.dart` (alice): `directory: () => alice.directory,`
- `test/features/contacts/bot_badge_test.dart`: `directory: () => directory,`

- [ ] **Step 4: Run the tests, verify they pass**

Run: `flutter analyze && flutter test`
Expected: no issues, all tests PASS (the 5 new ones included).

- [ ] **Step 5: Commit**

```bash
git add src/client/calltype/lib/features/chat/message_inbox_service.dart src/client/calltype/lib/main.dart src/client/calltype/test
git commit -m "feat(app): inbox routes through the device directory

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: App - fan-out send and outbox repair

Constraint 4: every non-business send goes through `FanoutSender` + `sendDirectFanout` / `sendGroupFanout`, `to` is always in direct payloads, envelopes are persisted per message and resent byte for byte, `device_list_stale` is repaired by `reconcile` in a bounded loop, and an unresolved stale answer is a visible failure. Business conversations keep the per-member `sendGroupMessage` path and a companion refuses them (decision 2). A business group whose `organizationId` is not cached yet (the hub answers `fanout_unsupported_in_business_group`) is finished on the business path within the SAME send attempt (same messageId, envelopes for the server's member list incl. the auditor) and the cache is filled, so a first send never ends as `failed`. The primary drops a vanished companion (constraint 5).

**Files:**
- Modify: `src/client/calltype/lib/features/chat/chat_controller.dart`, `lib/app/router.dart`
- Modify: `test/features/chat/chat_controller_test.dart`, `test/features/chat/message_actions_flow_test.dart` (fake transports)
- Test: `src/client/calltype/test/features/devices/multi_device_flow_test.dart` (new, real crypto end to end)

- [ ] **Step 1: Teach the fake transports the fan-out methods**

`test/features/chat/chat_controller_test.dart`, class `Transport`, add:

```dart
  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async {
    envelopes.add(Map.of(encryptedPayloads));
    ids.add(messageId);
    if (fail) throw StateError(failMessage);
  }

  @override
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async {
    envelopes.add(Map.of(encryptedPayloads));
    ids.add(messageId);
    if (fail) throw StateError(failMessage);
  }
```

`test/features/chat/message_actions_flow_test.dart`, class `_Transport`, add:

```dart
  /// Plays a hub that knows the group is a business group (the client's
  /// cache does not yet): group fan-out is refused, nothing is queued.
  bool refuseGroupFanout = false;
  var refusedGroupFanouts = 0;
  final sentIds = <String?>[];

  @override
  Future<void> sendDirectFanout(
    String recipientIdentityId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async {
    sent.add(Map.of(encryptedPayloads));
    sentIds.add(messageId);
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> sendGroupFanout(
    String groupId,
    Map<String, String> encryptedPayloads, {
    required String messageId,
  }) async {
    if (refuseGroupFanout) {
      refusedGroupFanouts++;
      throw StateError('HubException: fanout_unsupported_in_business_group');
    }
    sent.add(Map.of(encryptedPayloads));
    sentIds.add(messageId);
    if (fail) throw StateError('offline');
  }
```

In the same class, make the existing `sendGroupMessage` record the id too: add `sentIds.add(messageId);` right after its `sent.add(Map.of(encryptedPayloads));`.

Add to the `controller` group of `message_actions_flow_test.dart`:

```dart
    test(
      'a business group the cache does not know yet still sends, in the same attempt',
      () async {
        // The chat opens while the server still answers "anonymous", so the
        // cached organizationId stays empty: the cold-cache case.
        await setUpChat(id: 'biz', type: 'group');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        _infoMode = 'business';
        transport.refuseGroupFanout = true;

        await controller.sendMessage('terms');

        final message = await alice.db.select(alice.db.messages).getSingle();
        expect(message.status, 'sent');
        expect(transport.refusedGroupFanouts, 1);
        // One business call with the SAME message id, one envelope per member
        // the server lists (here: bob).
        expect(transport.sent.single.keys, ['bob']);
        expect(transport.sentIds.single, message.id);
        final conversation = await (alice.db.select(
          alice.db.conversations,
        )..where((c) => c.id.equals('biz'))).getSingle();
        expect(conversation.organizationId, 'org');

        // The warm cache sends the next message straight to the business path.
        await controller.sendMessage('more terms');
        expect(transport.refusedGroupFanouts, 1);
        expect(transport.sent, hasLength(2));
      },
    );
```

Add to `chat_controller_test.dart` (inside `main()`):

```dart
  test('a companion never sends into a business conversation', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final web = await TestDevice.create('web');
    final auditor = await TestDevice.create('auditor-device');
    await web.db
        .into(web.db.knownDeviceListMembers)
        .insert(
          KnownDeviceListMembersCompanion.insert(
            deviceId: 'web',
            primaryDeviceId: 'alice',
          ),
        );
    await web.directory.load();
    await web.db
        .into(web.db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'biz-group',
            type: 'group',
            organizationId: const Value('org1'),
            organizationName: const Value('Acme'),
          ),
        );
    final transport = Transport()..fail = false;
    final inbox = MessageInboxService(
      database: web.db,
      sessionManager: web.sessions,
      directory: () => web.directory,
      incomingMessages: const Stream.empty(),
    );
    final controller = ChatController(
      database: web.db,
      signalRClient: transport,
      sessionManager: web.sessions,
      inbox: inbox,
      apiClient: ChatApi([auditor]),
      conversationId: 'biz-group',
      directory: web.directory,
    );

    await controller.sendMessage('terms');

    expect(transport.envelopes, isEmpty);
    expect((await web.db.select(web.db.messages).getSingle()).status, 'failed');
    controller.dispose();
    await inbox.dispose();
    transport.dispose();
    await web.close();
    await auditor.close();
  });
```

- [ ] **Step 2: Write the failing end-to-end flow test**

Create `test/features/devices/multi_device_flow_test.dart`:

```dart
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/chat/chat_controller.dart';
import 'package:calltype/features/chat/message_inbox_service.dart';
import 'package:calltype_core/devices/device_directory.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const aPhoneId = 'a0000000-0000-4000-8000-000000000001';
const aWebId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

/// One app instance: real database, real ratchets, the real inbox and chat
/// controller. Only the network is the in-memory fake server.
class _Node {
  _Node(this.device, this.server) : hub = FakeHubClient(server, device.id) {
    directory = server.directoryFor(device);
    inbox = MessageInboxService(
      database: device.db,
      sessionManager: device.sessions,
      incomingMessages: server.inboxes[device.id]!.stream,
      directory: () => directory,
      apiClient: FakeDeviceApi(server),
      acknowledge: hub.acknowledgeMessage,
    )..start();
  }

  final TestDevice device;
  final FakeMultiDeviceServer server;
  final FakeHubClient hub;
  late final DeviceDirectory directory;
  late final MessageInboxService inbox;

  ChatController chat(String conversationId) => ChatController(
    database: device.db,
    signalRClient: hub,
    sessionManager: device.sessions,
    inbox: inbox,
    apiClient: FakeDeviceApi(server),
    conversationId: conversationId,
    directory: directory,
  );

  Future<List<Message>> messages() => device.db.select(device.db.messages).get();

  Future<Conversation?> conversation(String id) => (device.db.select(
    device.db.conversations,
  )..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<void> settle() =>
      MessageProcessingQueue.forDatabase(device.db).run(() async {});

  Future<void> close() async {
    await inbox.dispose();
    hub.dispose();
  }
}

void main() {
  late FakeMultiDeviceServer server;
  late _Node aPhone;
  late _Node aWeb;
  late _Node bob;

  /// Lets every delivered envelope reach its inbox and be processed.
  Future<void> settle() async {
    for (var round = 0; round < 3; round++) {
      await Future<void>.delayed(Duration.zero);
      for (final node in [aPhone, aWeb, bob]) {
        await node.settle();
      }
    }
  }

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    final devices = [
      for (final id in [aPhoneId, aWebId, bobId]) await TestDevice.create(id),
    ];
    devices.forEach(server.add);
    aPhone = _Node(devices[0], server);
    aWeb = _Node(devices[1], server);
    bob = _Node(devices[2], server);
    // A links its web device (what Settings > Linked devices does) and both
    // of A's devices verify the list.
    await server.link(aPhone.device, [aWeb.device], version: 1);
    await aPhone.directory.refresh(aPhoneId, ensurePinned: (_) async {});
    await aWeb.directory.refresh(aPhoneId, ensurePinned: server.pinFor(aWeb.device));
    await bob.device.db
        .into(bob.device.db.conversations)
        .insert(ConversationsCompanion.insert(id: aPhoneId, type: 'direct'));
  });

  tearDown(() async {
    for (final node in [aPhone, aWeb, bob]) {
      await node.close();
    }
    await server.close();
    for (final node in [aPhone, aWeb, bob]) {
      await node.device.close();
    }
  });

  test('a message to A reaches both of A\'s devices, in the chat with B', () async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);

    await toA.sendMessage('hello both');
    await settle();

    expect((await bob.messages()).single.status, 'sent');
    for (final node in [aPhone, aWeb]) {
      final message = (await node.messages()).single;
      expect(message.body, 'hello both');
      expect(message.conversationId, bobId);
      expect(message.senderId, bobId);
      expect(message.status, 'delivered');
      expect((await node.conversation(bobId))!.unreadCount, 1);
    }
    // B learned A's list from the stale answer and keeps it.
    expect(await bob.directory.devicesOf(aPhoneId), [aPhoneId, aWebId]);
  });

  test('the web device replies and retracts; B and A\'s phone follow', () async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);
    await toA.sendMessage('hello both');
    await settle();

    final fromWeb = aWeb.chat(bobId);
    addTearDown(fromWeb.dispose);
    expect(fromWeb.myIdentityId, aPhoneId);
    await fromWeb.sendMessage('from the web');
    await settle();

    final atBob = (await bob.messages()).firstWhere((m) => m.body == 'from the web');
    expect(atBob.conversationId, aPhoneId);
    expect(atBob.senderId, aPhoneId);
    final copy = (await aPhone.messages()).firstWhere((m) => m.body == 'from the web');
    expect(copy.conversationId, bobId);
    expect(copy.senderId, aPhoneId);
    expect(copy.status, 'sent');
    // Only B's message is unread on the phone; its own copy is not.
    expect((await aPhone.conversation(bobId))!.unreadCount, 1);

    final sent = (await aWeb.messages()).firstWhere((m) => m.body == 'from the web');
    expect(await fromWeb.deleteForEveryone(sent.id), isTrue);
    await settle();
    for (final node in [bob, aPhone]) {
      expect(
        (await node.messages()).firstWhere((m) => m.id == sent.id).deleted,
        isTrue,
      );
    }
  });

  test('after A removes the web device, B\'s next message leaves it out', () async {
    final toA = bob.chat(aPhoneId);
    addTearDown(toA.dispose);
    await toA.sendMessage('hello both');
    await settle();
    await server.link(aPhone.device, [], version: 2);
    final webBefore = (await aWeb.messages()).length;

    await toA.sendMessage('phone only');
    await settle();

    expect((await bob.messages()).map((m) => m.status), everyElement('sent'));
    expect((await aPhone.messages()).map((m) => m.body), contains('phone only'));
    expect(await aWeb.messages(), hasLength(webBefore));
    expect(await bob.directory.devicesOf(aPhoneId), [aPhoneId]);
  });
}
```

- [ ] **Step 3: Run the tests, verify they fail**

Run: `flutter test test/features/devices/multi_device_flow_test.dart test/features/chat/chat_controller_test.dart test/features/chat/message_actions_flow_test.dart`
Expected: the flow tests FAIL (the controller still calls `sendMessage`, which the fake hub does not route, so A never receives anything); the companion business test FAILS (the message is sent); the cold-cache business test FAILS (`refusedGroupFanouts` is 0, the controller never tries fan-out yet).

- [ ] **Step 4: Implement in `chat_controller.dart`**

Add the imports

```dart
import 'package:calltype_core/devices/fanout_sender.dart';
import 'package:calltype_core/network/signalr_client.dart' as core show SignalRClient;
```

Extend the constructor parameters after `required DeviceDirectory directory,` with

```dart
    void Function(Set<String> required)? onStale,
```

and the initializer list after `_directory = directory` with

```dart
       // Stateless apart from these references, so each chat builds its own
       // instead of sharing one through the provider tree.
       _fanout = FanoutSender(
         directory: directory,
         sessions: sessionManager,
         apiClient: apiClient,
       ),
       _onStale = onStale
```

Below the `isCompanion` getter add the fields:

```dart
  final FanoutSender _fanout;

  /// Told about every `device_list_stale` answer (the primary drops a
  /// companion the server no longer knows, constraint 5). Must not await
  /// anything that runs in MessageProcessingQueue: it is called from inside it.
  final void Function(Set<String> required)? _onStale;

  /// Rounds of "send; on device_list_stale repair the envelopes and resend".
  /// Bounded: a server that keeps answering stale produces a visible failure,
  /// not a loop.
  static const _maxFanoutRounds = 3;
```

Replace `retryMessage` entirely with:

```dart
  Future<void> retryMessage(
    String messageId,
  ) => MessageProcessingQueue.forDatabase(_db).run(() async {
    final message = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingle();
    if (message.senderId != myIdentityId ||
        message.conversationId != conversationId ||
        (message.status != 'failed' && message.status != 'sending')) {
      return;
    }
    await _status(messageId, 'sending');
    _auditRecipientMissing = false;
    _auditorUnavailable = false;
    _businessConversationRequired = false;
    try {
      var stored = await (_db.select(
        _db.backupState,
      )..where((s) => s.key.equals('outbox:$messageId'))).getSingleOrNull();
      if (stored == null) {
        final conversation = await (_db.select(
          _db.conversations,
        )..where((c) => c.id.equals(conversationId))).getSingle();
        final groupId = conversation.type == 'group' ? conversationId : null;
        // Business conversations stay on the per-member group call from the
        // primary: KB2 auditor rules are defined over member devices and the
        // hub refuses fan-out there. v1 keeps companions out of them.
        final business = conversation.organizationId != null;
        if (business && isCompanion) {
          throw StateError('Business conversations are primary-only in v1.');
        }
        final recipients = groupId == null
            ? [conversationId]
            : (await _api.getGroupMembers(
                groupId,
              )).where((id) => id != myIdentityId).toList();
        if (recipients.isEmpty) {
          throw StateError('No recipients in this conversation');
        }
        final payload = jsonEncode({
          'v': 1,
          'id': messageId,
          'body': message.body,
          'type': message.type,
          'groupId': groupId,
          'groupName': groupId == null ? null : conversation.title,
          'createdAt': message.createdAt.toUtc().toIso8601String(),
          // Multi-device: our OTHER devices get a copy too, and only this
          // says which direct conversation it belongs to (constraint 4).
          if (groupId == null) 'to': conversationId,
          // Additive keys: old clients ignore them and show a normal message.
          if (message.replyToId != null)
            'replyTo': {
              'id': message.replyToId,
              'senderId': message.replySenderId,
              'preview': message.replyPreview ?? '',
            },
          if (message.forwarded) 'forwarded': true,
        });
        await _db.transaction(() async {
          final Map<String, String> envelopes;
          if (business) {
            final encrypted = await GroupCipher(
              sessionManager: _sessions,
              ensureSession: _ensureSession,
            ).encryptForGroup(groupId!, recipients, payload);
            envelopes = encrypted.map(
              (id, bytes) => MapEntry(id, base64Encode(bytes)),
            );
          } else {
            // One envelope per VERIFIED device of the recipients and of our
            // own identity, from stored lists only (no fetch per message).
            envelopes = await _fanout.encrypt(recipients, payload);
          }
          await _db
              .into(_db.backupState)
              .insert(
                BackupStateCompanion.insert(
                  key: 'outbox:$messageId',
                  // Recipients and the exact payload are kept for a stale
                  // answer: a missing device gets a new envelope while every
                  // existing one is resent byte for byte.
                  value: jsonEncode({
                    'groupId': groupId,
                    'envelopes': envelopes,
                    if (!business)
                      'fanout': {'identityIds': recipients, 'payload': payload},
                  }),
                ),
              );
        });
        stored = await (_db.select(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).getSingle();
      }
      final outbox = jsonDecode(stored.value) as Map<String, dynamic>;
      final envelopes = (outbox['envelopes'] as Map<String, dynamic>)
          .cast<String, String>();
      final groupId = outbox['groupId'] as String?;
      if (outbox['fanout'] != null) {
        await _sendFanout(messageId, outbox, envelopes);
      } else if (groupId != null) {
        // The whole fan-out in one call (see sendGroupMessage): a business
        // group rejects any call without the auditor's envelope (KB2).
        await _signalR.sendGroupMessage(
          groupId,
          envelopes,
          messageId: messageId,
        );
      } else {
        // An outbox written before multi-device (one envelope for the peer):
        // finish it the old way rather than encrypting again.
        await _signalR.sendMessage(
          envelopes.keys.single,
          envelopes.values.single,
          messageId: messageId,
        );
      }
      await _db.transaction(() async {
        await _status(messageId, 'sent');
        await (_db.delete(
          _db.backupState,
        )..where((s) => s.key.equals('outbox:$messageId'))).go();
      });
    } catch (e) {
      // The hub reports the audit failure as a plain-text HubException
      // message; surfacing it distinctly (rather than a generic "failed")
      // is required by KB1 - this must never look like an ordinary
      // delivery hiccup the user can ignore.
      if (e.toString().contains('audit_recipient_missing')) {
        _auditRecipientMissing = true;
        notifyListeners();
      } else if (e.toString().contains('auditor_unavailable')) {
        _auditorUnavailable = true;
        notifyListeners();
      } else if (e.toString().contains('business_conversation_required')) {
        _businessConversationRequired = true;
        notifyListeners();
      }
      await _status(messageId, 'failed');
    }
  });

  /// Sends a fan-out outbox; on `device_list_stale` lets FanoutSender repair
  /// the envelopes (new devices get one, removed devices lose theirs, the
  /// rest stays byte for byte) and persists them before the next round.
  Future<void> _sendFanout(
    String messageId,
    Map<String, dynamic> outbox,
    Map<String, String> envelopes,
  ) async {
    final groupId = outbox['groupId'] as String?;
    final fanout = outbox['fanout'] as Map<String, dynamic>;
    final identityIds = (fanout['identityIds'] as List).cast<String>();
    final payload = fanout['payload'] as String;
    var current = envelopes;
    for (var round = 1; ; round++) {
      try {
        if (groupId == null) {
          await _signalR.sendDirectFanout(
            identityIds.single,
            current,
            messageId: messageId,
          );
        } else {
          await _signalR.sendGroupFanout(
            groupId,
            current,
            messageId: messageId,
          );
        }
        return;
      } catch (e) {
        if (groupId != null &&
            e.toString().contains('fanout_unsupported_in_business_group')) {
          await _sendBusinessFallback(messageId, groupId, payload);
          return;
        }
        final required = core.SignalRClient.staleRequired(e);
        if (required == null || round == _maxFanoutRounds) rethrow;
        _onStale?.call(required);
        // Deliberately NOT inside a database transaction: reconcile refreshes
        // device lists, DeviceDirectory serializes its refreshes, and a
        // transaction held across that could wait for a refresh that waits
        // for the database. A crash in between only loses envelopes nobody
        // has received; encrypting those again is harmless.
        current = await _fanout.reconcile(
          envelopes: current,
          required: required,
          identityIds: identityIds,
          payload: payload,
        );
        await (_db.update(_db.backupState)
              ..where((s) => s.key.equals('outbox:$messageId')))
            .write(
              BackupStateCompanion(
                value: Value(jsonEncode({...outbox, 'envelopes': current})),
              ),
            );
      }
    }
  }

  /// The hub says this group is a business group, but the local cache did
  /// not know yet (it is filled asynchronously when the chat opens). Finish
  /// the SAME send attempt on the business path instead of failing: same
  /// messageId, one envelope per member from the server's member list (the
  /// auditor included, KB2), one sendGroupMessage call. The refused fan-out
  /// call queued nothing, so encrypting again only skips a ratchet step.
  Future<void> _sendBusinessFallback(
    String messageId,
    String groupId,
    String payload,
  ) async {
    // v1: business conversations are primary-only (decision 2).
    if (isCompanion) {
      throw StateError('Business conversations are primary-only in v1.');
    }
    // Fills the cached organizationId, so the next send goes straight to the
    // business path (and the banner appears).
    await _syncBusinessInfo();
    final recipients = (await _api.getGroupMembers(
      groupId,
    )).where((id) => id != myIdentityId).toList();
    final envelopes = <String, String>{};
    await _db.transaction(() async {
      final encrypted = await GroupCipher(
        sessionManager: _sessions,
        ensureSession: _ensureSession,
      ).encryptForGroup(groupId, recipients, payload);
      envelopes.addAll(
        encrypted.map((id, bytes) => MapEntry(id, base64Encode(bytes))),
      );
      // The outbox becomes a business outbox: a retry after a failed call
      // below resends these exact envelopes through the business branch.
      await (_db.update(_db.backupState)
            ..where((s) => s.key.equals('outbox:$messageId')))
          .write(
            BackupStateCompanion(
              value: Value(
                jsonEncode({'groupId': groupId, 'envelopes': envelopes}),
              ),
            ),
          );
    });
    await _signalR.sendGroupMessage(groupId, envelopes, messageId: messageId);
  }
```

(`staleRequired` is static on the core class; static members are not inherited by the app's `SignalRClient` subclass, hence the `core` import.)

`lib/app/router.dart`: add `import 'dart:async';` and in the `/chats/:id` route replace `directory: ctx.read<DeviceService>().directory,` with:

```dart
                  directory: ctx.read<DeviceService>().directory,
                  // Not awaited: the hook runs inside the processing queue and
                  // re-signing our list goes through that queue too.
                  onStale: (required) => unawaited(
                    ctx.read<DeviceService>().dropVanishedCompanions(required),
                  ),
```

- [ ] **Step 5: Run the tests, verify they pass**

Run: `flutter analyze && flutter test`
Expected: no issues, all tests PASS (flow tests included).

- [ ] **Step 6: Commit**

```bash
git add src/client/calltype/lib/features/chat/chat_controller.dart src/client/calltype/lib/app/router.dart src/client/calltype/test
git commit -m "feat(app): send with fan-out and repair the outbox on stale device lists

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: App - companion restrictions and the device-change line

Decision 2 in the UI (no calls, no business input, no group creation on a companion), the device-change line from decision 5, the companion banner from decision 7, and open question 3 (a companion hands out the primary's invite).

**Files:**
- Modify: `src/client/calltype/lib/features/chat/chat_screen.dart`
- Modify: `src/client/calltype/lib/features/chat_list/chat_list_screen.dart`
- Modify: `src/client/calltype/lib/features/settings/identity_screen.dart`
- Test: `src/client/calltype/test/features/contacts/bot_badge_test.dart`

- [ ] **Step 1: Write the failing widget tests**

In `bot_badge_test.dart` add below `const _botId = ...`:

```dart
const _primaryId = '99999999-0000-4000-8000-000000000001';
```

Change the `pumpChat` signature to

```dart
  Future<Future<void> Function()> pumpChat(
    WidgetTester tester, {
    required bool isBot,
    bool companion = false,
    bool deviceChange = false,
  }) async {
```

and inside its `tester.runAsync(() async {`, directly before `chat = ChatController(`, insert:

```dart
      if (companion) {
        // What a verified list leaves on a linked device: 'me' belongs to
        // the identity _primaryId.
        await db
            .into(db.knownDeviceListMembers)
            .insert(
              KnownDeviceListMembersCompanion.insert(
                deviceId: 'me',
                primaryDeviceId: _primaryId,
              ),
            );
        await directory.load();
      }
      if (deviceChange) {
        await db
            .into(db.messages)
            .insert(
              MessagesCompanion.insert(
                id: 'device-change',
                conversationId: _botId,
                senderId: _botId,
                body: const Value('added'),
                type: const Value('device-change'),
                status: const Value('delivered'),
                createdAt: DateTime.now(),
              ),
            );
      }
```

Append the tests:

```dart
  testWidgets('on a companion the call buttons are hidden', (tester) async {
    final cleanUp = await pumpChat(tester, isBot: false, companion: true);
    expect(find.byTooltip('Voice call'), findsNothing);
    expect(find.byTooltip('Video call'), findsNothing);
    await cleanUp();
  });

  testWidgets('a device change is a system line, not a bubble', (tester) async {
    final cleanUp = await pumpChat(tester, isBot: false, deviceChange: true);
    expect(find.text(l10nEn.chatDeviceAdded), findsOneWidget);
    expect(find.text('added'), findsNothing);
    await cleanUp();
  });
```

- [ ] **Step 2: Run them, verify they fail**

Run: `flutter test test/features/contacts/bot_badge_test.dart`
Expected: the companion test FAILS (call buttons shown), the device-change test FAILS (`added` rendered as a bubble).

- [ ] **Step 3: Implement `chat_screen.dart`**

Add below `_CallEventLine`:

```dart
/// "This contact added a device" (spec Part A, "What a peer sees"). Written
/// locally by DeviceService when a contact's verified list changes; never
/// sent over the wire.
class _DeviceChangeLine extends StatelessWidget {
  const _DeviceChangeLine({required this.body});
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Center(
      child: Text(
        body == 'removed'
            ? context.l10n.chatDeviceRemoved
            : context.l10n.chatDeviceAdded,
        style: Theme.of(context).textTheme.labelSmall,
        textAlign: TextAlign.center,
      ),
    ),
  );
}
```

In the message list, after

```dart
                      if (message.type == 'call-event') {
                        return _CallEventLine(body: message.body ?? '');
                      }
```

add

```dart
                      if (message.type == 'device-change') {
                        return _DeviceChangeLine(body: message.body ?? '');
                      }
```

Replace `if (!group && !isBot) ...[` with

```dart
          // v1: calls ring the primary only, so a companion offers none
          // (spec "Limits of v1").
          if (!group && !isBot && !controller.isCompanion) ...[
```

and `if (group && organizationName != null)` (the business call `FutureBuilder`) with `if (group && organizationName != null && !controller.isCompanion)`.

Replace the `MessageInput(` widget at the end of the `Column` (from `MessageInput(` to its closing `),`) with:

```dart
          // v1: business conversations stay on the primary (KB2 auditor rules
          // are defined over member devices). A companion says why it cannot
          // write here instead of failing on send.
          if (organizationName != null && controller.isCompanion)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.chatCompanionBusinessReadOnly,
                textAlign: TextAlign.center,
              ),
            )
          else
            MessageInput(
              onSend: controller.sendMessage,
              onAttachment: () => _attach(context),
              replyAuthor: controller.replyingTo == null
                  ? null
                  : _authorLabel(
                      context,
                      controller,
                      controller.replyingTo!.senderId,
                      allContacts,
                    ),
              replyText: controller.replyingTo == null
                  ? null
                  : ChatController.replyPreviewOf(controller.replyingTo!),
              onCancelReply: controller.cancelReply,
              mentionCandidates: group
                  ? buildMentionCandidates(
                      members: controller.groupMembers,
                      contacts: allContacts,
                      myIdentityId: controller.myIdentityId,
                    )
                  : const [],
            ),
```

- [ ] **Step 4: Implement `chat_list_screen.dart`**

Add `import '../devices/device_service.dart';`. In `build`, after `final network = context.watch<SignalRClient>();` add `final devices = context.watch<DeviceService>();`. Replace the "New group" `IconButton(` (tooltip `l10n.chatListNewGroup`) with:

```dart
          // A companion would become a group member on its own; groups are
          // created from the primary (the server refuses it too).
          if (!devices.isCompanion)
            IconButton(
              icon: const Icon(Icons.group_add_outlined),
              tooltip: l10n.chatListNewGroup,
              onPressed: () => context.push('/groups/create'),
            ),
```

In the body `Column`, after the offline `MaterialBanner(...)` entry, add:

```dart
          // Decision 7: "cannot verify" deletes nothing and says so; a
          // verified removal says that the chats were deleted.
          if (devices.status != CompanionStatus.ok)
            ListTile(
              leading: const Icon(Icons.warning_amber_rounded),
              title: Text(
                devices.status == CompanionStatus.removed
                    ? l10n.devicesRemovedNotice
                    : l10n.devicesCannotVerify,
              ),
            ),
```

- [ ] **Step 5: Implement `identity_screen.dart`**

Add `import '../devices/device_service.dart';`. Add the field `bool _companion = false;` next to `_deviceId`. Replace `_load()` with:

```dart
  Future<void> _load() async {
    final storage = context.read<SecureStorage>();
    final devices = context.read<DeviceService>();
    var id = await storage.getDeviceId();
    var handle = await storage.read('ct_user_handle');
    final displayName = await storage.read(_keyDisplayName);
    // A companion is not an identity of its own: contacts must add the
    // primary. An invite to this device would address a device the hub
    // refuses as a recipient (recipient_is_not_primary).
    final companion = devices.isCompanion;
    if (companion) {
      id = devices.directory.selfIdentityId;
      handle = await devices.linkedPrimaryHandle();
    }
    if (mounted) {
      setState(() {
        _companion = companion;
        _deviceId = id;
        _handle = handle ?? id;
        _identity = 'ct://$id/${handle ?? id}';
        _nameController.text = displayName ?? '';
      });
    }
  }
```

and wrap the display-name block (`const SizedBox(height: 24),` followed by the `Padding(` with the `TextField`) in `if (!_companion) ...[` ... `],` with the comment:

```dart
              // The display name belongs to the primary; on a companion it
              // would rename a device nobody sees.
```

- [ ] **Step 6: Run the tests, verify they pass**

Run: `flutter analyze && flutter test`
Expected: no issues, all tests PASS (the l10n guard included: no new literals).

- [ ] **Step 7: Commit**

```bash
git add src/client/calltype/lib/features/chat/chat_screen.dart src/client/calltype/lib/features/chat_list/chat_list_screen.dart src/client/calltype/lib/features/settings/identity_screen.dart src/client/calltype/test/features/contacts/bot_badge_test.dart
git commit -m "feat(app): companion limits in the UI and the device-change line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: App - linking UI

Spec Part A "Linking a device" with decisions 3 and 6 and constraint 7: the QR code is the out-of-band channel, the fingerprint is compared BEFORE `LinkOffer`, the consent is verified before signing, the PUT follows right after the consent (the hub keeps it for 10 minutes), and `link_target_offline` after `LinkConsent` does not undo the consent.

**Files:**
- Create: `src/client/calltype/lib/features/devices/link_code.dart`
- Create: `src/client/calltype/lib/features/devices/link_controllers.dart`
- Create: `src/client/calltype/lib/features/devices/devices_screen.dart`
- Create: `src/client/calltype/lib/features/devices/link_device_screen.dart`
- Modify: `src/client/calltype/lib/features/contacts/qr_scanner_screen.dart`, `lib/app/router.dart`, `lib/features/settings/settings_screen.dart`, `lib/features/onboarding/onboarding_screen.dart`
- Test: `test/features/devices/link_code_test.dart`, `test/features/devices/link_controllers_test.dart`, `test/features/devices/devices_screen_test.dart`

- [ ] **Step 1: Write the failing link code test**

Create `test/features/devices/link_code_test.dart`:

```dart
import 'package:calltype/features/devices/link_code.dart';
import 'package:flutter_test/flutter_test.dart';

const id = 'a0000000-0000-4000-8000-000000000002';

void main() {
  final fingerprint = linkFingerprint('aWs=', 'c2s=');

  test('a code survives the QR round trip', () {
    final parsed = LinkCode.parse(LinkCode(id, fingerprint).toString())!;
    expect(parsed.deviceId, id);
    expect(parsed.fingerprint, fingerprint);
  });

  test('contact invites and malformed codes are not link codes', () {
    expect(LinkCode.parse('ct://$id/CT-AAAA-BBBB'), isNull);
    expect(LinkCode.parse('calltype://contact/CT-AAAA-BBBB'), isNull);
    expect(LinkCode.parse('jaylink://not-a-device/$fingerprint'), isNull);
    expect(LinkCode.parse('jaylink://$id/abc'), isNull);
    expect(LinkCode.parse('jaylink://$id/$fingerprint/extra'), isNull);
  });

  test('the fingerprint covers both keys', () {
    expect(fingerprint, hasLength(64));
    expect(linkFingerprint('aWs=', 'c2s='), fingerprint);
    expect(linkFingerprint('aWs=', 'b3RoZXI='), isNot(fingerprint));
    expect(linkFingerprint('b3RoZXI=', 'c2s='), isNot(fingerprint));
  });
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `flutter test test/features/devices/link_code_test.dart`
Expected: compile error, `link_code.dart` does not exist.

- [ ] **Step 3: Implement `link_code.dart`**

```dart
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What a new device shows as a QR code while it waits to be linked:
/// `jaylink://<deviceId>/<fingerprint>`.
///
/// WHY its own scheme: the contact scanner accepts `ct://` and `calltype://`.
/// A link code read as a contact invite would add the new device as a
/// contact, which marks it as somebody's identity and locks it out of
/// linking (DeviceDirectory refuses to attribute a device that is a contact).
class LinkCode {
  const LinkCode(this.deviceId, this.fingerprint);

  final String deviceId;
  final String fingerprint;

  static const scheme = 'jaylink';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

  @override
  String toString() => '$scheme://$deviceId/$fingerprint';

  static LinkCode? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != scheme || uri.pathSegments.length != 1) {
      return null;
    }
    final deviceId = uri.host.toLowerCase();
    final fingerprint = uri.pathSegments.single.toLowerCase();
    if (!_uuid.hasMatch(deviceId) || !_sha256Hex.hasMatch(fingerprint)) {
      return null;
    }
    return LinkCode(deviceId, fingerprint);
  }
}

/// SHA-256 over `<identityKey>|<signingKey>` (base64, as the key bundle
/// serves them). The primary compares it with the bundle the SERVER returns
/// before anything is sent, so the server never chooses which keys get
/// linked (spec Part A, step 2).
String linkFingerprint(String identityKey, String signingKey) =>
    sha256.convert(utf8.encode('$identityKey|$signingKey')).toString();
```

Run: `flutter test test/features/devices/link_code_test.dart` - Expected: PASS.

- [ ] **Step 4: Write the failing controller tests**

Create `test/features/devices/link_controllers_test.dart`:

```dart
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/link_code.dart';
import 'package:calltype/features/devices/link_controllers.dart';
import 'package:calltype_core/crypto/device_list.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';
const bobId = 'b0000000-0000-4000-8000-000000000001';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;
  late TestDevice bob;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    server = FakeMultiDeviceServer();
    phone = await TestDevice.create(phoneId);
    web = await TestDevice.create(webId);
    bob = await TestDevice.create(bobId);
    for (final d in [phone, web, bob]) {
      server.add(d);
    }
  });

  tearDown(() async {
    await server.close();
    for (final d in [phone, web, bob]) {
      await d.close();
    }
  });

  Future<String> codeOf(TestDevice device, {TestDevice? keysOf}) async {
    final bundle = await (keysOf ?? device).keys.getSignedIdentityBundle();
    return LinkCode(
      device.id,
      linkFingerprint(bundle['identityKey']!, bundle['signingKey']!),
    ).toString();
  }

  Future<String> consentOf(TestDevice device, String primary) async =>
      signDeviceLinkConsent(
        companionSigningKey: await device.keys.getSigningKeyPair(),
        primaryDeviceId: primary,
        companionDeviceId: device.id,
      );

  group('primary', () {
    test('offers only after the fingerprint matched, then signs the consented device in', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      final linking = controller.link(await codeOf(web));
      await until(() => hub.sentOffers.isNotEmpty);
      expect(hub.sentOffers, [webId]);
      expect(controller.state, PrimaryLinkState.waitingForConsent);
      hub.consents.add({'deviceId': webId, 'consentSig': await consentOf(web, phoneId)});
      await linking;

      expect(controller.state, PrimaryLinkState.linked);
      expect((await devices.companions()).single.deviceId, webId);
      expect(await devices.directory.devicesOf(phoneId), [phoneId, webId]);
    });

    test('a code whose keys differ from the served bundle is refused before any offer', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      await controller.link(await codeOf(web, keysOf: bob));

      expect(controller.state, PrimaryLinkState.mismatch);
      expect(hub.sentOffers, isEmpty);
      expect(server.lists, isEmpty);
    });

    test('a consent signed for another primary is refused', () async {
      final devices = await server.deviceServiceFor(phone);
      final hub = server.hubs[phoneId]!;
      final controller = PrimaryLinkController(
        devices: devices,
        apiClient: FakeDeviceApi(server),
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      final linking = controller.link(await codeOf(web));
      await until(() => hub.sentOffers.isNotEmpty);
      hub.consents.add({'deviceId': webId, 'consentSig': await consentOf(web, bobId)});
      await linking;

      expect(controller.state, PrimaryLinkState.failed);
      expect(server.lists, isEmpty);
    });
  });

  group('new device', () {
    test('shows its code, confirms the offered handle, consents and ends linked', () async {
      final devices = await server.deviceServiceFor(web);
      final hub = server.hubs[webId]!;
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: hub,
      );
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.state, CompanionLinkState.showingCode);
      expect(controller.code, await codeOf(web));

      hub.offers.add({'primaryDeviceId': phoneId, 'userHandle': 'CT-PHON-E001'});
      await until(() => controller.state == CompanionLinkState.offered);
      expect(controller.offeredHandle, 'CT-PHON-E001');

      await controller.accept();
      final (primary, consentSig) = hub.sentConsents.single;
      expect(primary, phoneId);
      final bundle = await web.keys.getSignedIdentityBundle();
      expect(
        await verifyDeviceLinkConsent(
          consentSig: consentSig,
          companionSigningKey: bundle['signingKey']!,
          primaryDeviceId: phoneId,
          companionDeviceId: webId,
        ),
        isTrue,
      );

      // The primary signs and uploads; the hub sends the hint.
      await server.link(phone, [web], version: 1);
      hub.listChanged.add({'primaryDeviceId': phoneId, 'version': 1});
      await until(() => controller.state == CompanionLinkState.linked);
      expect(devices.directory.selfIdentityId, phoneId);
      expect(await devices.linkedPrimaryHandle(), 'CT-PHON-E001');
    });

    test('a device with chats cannot be linked', () async {
      await web.db
          .into(web.db.conversations)
          .insert(ConversationsCompanion.insert(id: bobId, type: 'direct'));
      final devices = await server.deviceServiceFor(web);
      final controller = CompanionLinkController(
        database: web.db,
        devices: devices,
        keyManager: web.keys,
        signalRClient: server.hubs[webId]!,
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state, CompanionLinkState.notEmpty);
      expect(controller.code, isNull);
    });
  });
}
```

- [ ] **Step 5: Run them, verify they fail**

Run: `flutter test test/features/devices/link_controllers_test.dart`
Expected: compile error, `link_controllers.dart` does not exist.

- [ ] **Step 6: Implement `link_controllers.dart`**

```dart
import 'dart:async';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:flutter/foundation.dart';

import '../../core/crypto/key_manager.dart';
import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import 'device_service.dart';
import 'link_code.dart';

/// v1 links only an empty device (decision 3): no contacts, no
/// conversations. Merging two histories is out of scope, and an empty device
/// that confirms the wrong primary exposes nothing that already exists.
Future<bool> isEmptyDevice(AppDatabase db) async =>
    (await (db.select(db.contacts)..limit(1)).get()).isEmpty &&
    (await (db.select(db.conversations)..limit(1)).get()).isEmpty;

enum PrimaryLinkState { idle, working, waitingForConsent, linked, mismatch, failed }

/// Primary side of spec Part A "Linking a device", steps 2, 3 and 5.
class PrimaryLinkController extends ChangeNotifier {
  PrimaryLinkController({
    required DeviceService devices,
    required ApiClient apiClient,
    required SignalRClient signalRClient,
    this.consentTimeout = const Duration(minutes: 2),
  }) : _devices = devices,
       _api = apiClient,
       _signalR = signalRClient;

  final DeviceService _devices;
  final ApiClient _api;
  final SignalRClient _signalR;

  /// How long the primary waits for the user to confirm on the new device.
  /// Shorter than the hub's 10 minute consent record, so the PUT that
  /// follows always finds it.
  final Duration consentTimeout;

  PrimaryLinkState _state = PrimaryLinkState.idle;
  PrimaryLinkState get state => _state;
  bool _disposed = false;

  Future<void> link(String scanned) async {
    if (_state == PrimaryLinkState.working ||
        _state == PrimaryLinkState.waitingForConsent) {
      return;
    }
    final code = LinkCode.parse(scanned);
    if (code == null) {
      _set(PrimaryLinkState.failed);
      return;
    }
    _set(PrimaryLinkState.working);
    StreamSubscription<Map<String, dynamic>>? subscription;
    try {
      final bundle = await _api.getKeyBundle(code.deviceId);
      final identityKey = bundle['identityKey'] as String;
      final signingKey = bundle['signingKey'] as String;
      // Step 2, BEFORE anything is sent: the keys the server hands out must
      // be the keys the QR code (the out-of-band channel) named.
      if (linkFingerprint(identityKey, signingKey) != code.fingerprint) {
        _set(PrimaryLinkState.mismatch);
        return;
      }
      final consent = Completer<String>();
      // Listen before the offer goes out, or a fast answer is missed.
      subscription = _signalR.onLinkConsent.listen((event) {
        final sig = event['consentSig'];
        if ((event['deviceId'] as String?)?.toLowerCase() == code.deviceId &&
            sig is String &&
            !consent.isCompleted) {
          consent.complete(sig);
        }
      });
      await _signalR.sendLinkOffer(code.deviceId);
      _set(PrimaryLinkState.waitingForConsent);
      final consentSig = await consent.future.timeout(consentTimeout);
      final self = _devices.directory.selfDeviceId;
      // The consent must be signed by the key the QR code named, for THIS
      // primary; the hub relays it but cannot forge it.
      if (!await verifyDeviceLinkConsent(
        consentSig: consentSig,
        companionSigningKey: signingKey,
        primaryDeviceId: self,
        companionDeviceId: code.deviceId,
      )) {
        _set(PrimaryLinkState.failed);
        return;
      }
      await _devices.addCompanion(
        DeviceListEntry(
          deviceId: code.deviceId,
          identityKey: identityKey,
          signingKey: signingKey,
          consentSig: consentSig,
        ),
      );
      _set(PrimaryLinkState.linked);
    } catch (_) {
      _set(PrimaryLinkState.failed);
    } finally {
      await subscription?.cancel();
    }
  }

  void _set(PrimaryLinkState state) {
    _state = state;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

enum CompanionLinkState {
  loading,
  notEmpty,
  showingCode,
  offered,
  waiting,
  linked,
  failed,
}

/// New-device side of spec Part A "Linking a device", steps 1, 4 and 6.
class CompanionLinkController extends ChangeNotifier {
  CompanionLinkController({
    required AppDatabase database,
    required DeviceService devices,
    required KeyManager keyManager,
    required SignalRClient signalRClient,
  }) : _db = database,
       _devices = devices,
       _keys = keyManager,
       _signalR = signalRClient {
    _devices.addListener(_onDevices);
  }

  final AppDatabase _db;
  final DeviceService _devices;
  final KeyManager _keys;
  final SignalRClient _signalR;
  StreamSubscription<Map<String, dynamic>>? _offers;
  bool _disposed = false;

  CompanionLinkState _state = CompanionLinkState.loading;
  CompanionLinkState get state => _state;

  /// The QR code content, set once the device is known to be empty.
  String? code;
  String? offeredPrimary;

  /// The primary's handle as the hub reported it (the user compares it with
  /// the phone in their hand); falls back to the id on an old server.
  String? offeredHandle;

  Future<void> start() async {
    if (!await isEmptyDevice(_db)) {
      _set(CompanionLinkState.notEmpty);
      return;
    }
    final bundle = await _keys.getSignedIdentityBundle();
    code = LinkCode(
      _devices.directory.selfDeviceId,
      linkFingerprint(bundle['identityKey']!, bundle['signingKey']!),
    ).toString();
    _offers = _signalR.onLinkOffer.listen((event) {
      final primary = (event['primaryDeviceId'] as String?)?.toLowerCase();
      // Offers count only while the code is on screen and nothing was
      // accepted yet: a later offer must not replace the one being confirmed.
      if (primary == null || _state != CompanionLinkState.showingCode) return;
      offeredPrimary = primary;
      offeredHandle = event['userHandle'] as String? ?? primary;
      _set(CompanionLinkState.offered);
    });
    _set(CompanionLinkState.showingCode);
  }

  void reject() {
    offeredPrimary = null;
    offeredHandle = null;
    _set(CompanionLinkState.showingCode);
  }

  Future<void> accept() async {
    final primary = offeredPrimary;
    if (primary == null || _state != CompanionLinkState.offered) return;
    // Re-checked: a message may have arrived while the question was open.
    if (!await isEmptyDevice(_db)) {
      _set(CompanionLinkState.notEmpty);
      return;
    }
    _set(CompanionLinkState.waiting);
    _devices.expectLink(primary);
    await _db
        .into(_db.backupState)
        .insertOnConflictUpdate(
          BackupStateCompanion.insert(
            key: linkedPrimaryHandleKey,
            value: offeredHandle ?? primary,
          ),
        );
    try {
      // The consent names the primary, so it can only be signed now that the
      // offer told us which primary it is (spec Part A, step 4).
      await _signalR.sendLinkConsent(
        primary,
        await signDeviceLinkConsent(
          companionSigningKey: await _keys.getSigningKeyPair(),
          primaryDeviceId: primary,
          companionDeviceId: _devices.directory.selfDeviceId,
        ),
      );
    } catch (e) {
      // The hub records the consent BEFORE it relays it (constraint 7):
      // link_target_offline does not undo it, so keep waiting for the list.
      if (!e.toString().contains('link_target_offline')) {
        _set(CompanionLinkState.failed);
      }
    }
  }

  void _onDevices() {
    if (_state == CompanionLinkState.waiting &&
        _devices.isCompanion &&
        _devices.directory.selfIdentityId == offeredPrimary) {
      _set(CompanionLinkState.linked);
    }
  }

  void _set(CompanionLinkState state) {
    _state = state;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _offers?.cancel();
    _devices.removeListener(_onDevices);
    super.dispose();
  }
}
```

Run: `flutter test test/features/devices/link_controllers_test.dart` - Expected: PASS.

- [ ] **Step 7: Write the failing screen test**

Create `test/features/devices/devices_screen_test.dart`:

```dart
import 'package:calltype/core/network/api_client.dart';
import 'package:calltype/core/network/signalr_client.dart';
import 'package:calltype/core/storage/database.dart';
import 'package:calltype/features/devices/device_service.dart';
import 'package:calltype/features/devices/devices_screen.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../helpers/fake_multi_device_server.dart';
import '../../helpers/localized_app.dart';
import '../../helpers/test_device.dart';

const phoneId = 'a0000000-0000-4000-8000-000000000001';
const webId = 'a0000000-0000-4000-8000-000000000002';

void main() {
  late FakeMultiDeviceServer server;
  late TestDevice phone;
  late TestDevice web;

  Future<void> pump(WidgetTester tester, TestDevice device, DeviceService devices) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: device.db),
          Provider<ApiClient>.value(value: FakeDeviceApi(server)),
          ChangeNotifierProvider<SignalRClient>.value(value: server.hubs[device.id]!),
          ChangeNotifierProvider<DeviceService>.value(value: devices),
        ],
        child: localizedApp(home: const DevicesScreen()),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  Future<void> setUpDevices(WidgetTester tester) async {
    await tester.runAsync(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      server = FakeMultiDeviceServer();
      phone = await TestDevice.create(phoneId);
      web = await TestDevice.create(webId);
      server
        ..add(phone)
        ..add(web);
      await server.link(phone, [web], version: 1);
    });
  }

  Future<void> tearDownDevices(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await server.close();
      await phone.close();
      await web.close();
    });
  }

  testWidgets('the primary lists its companion and can link another', (tester) async {
    await setUpDevices(tester);
    final devices = (await tester.runAsync(() async {
      final service = await server.deviceServiceFor(phone);
      await service.checkOwnList(phoneId);
      return service;
    }))!;
    await pump(tester, phone, devices);

    expect(find.text(l10nEn.devicesDeviceLabel(webId.substring(0, 8))), findsOneWidget);
    expect(find.text(l10nEn.devicesRemove), findsOneWidget);
    expect(find.text(l10nEn.devicesAdd), findsOneWidget);
    // A primary with a companion is not an empty device.
    expect(find.text(l10nEn.linkDeviceAction), findsNothing);
    await tearDownDevices(tester);
  });

  testWidgets('a companion only says whose device it is', (tester) async {
    await setUpDevices(tester);
    final devices = (await tester.runAsync(() async {
      await web.db
          .into(web.db.backupState)
          .insert(
            BackupStateCompanion.insert(
              key: linkedPrimaryHandleKey,
              value: 'CT-PHON-E001',
            ),
          );
      final service = await server.deviceServiceFor(web);
      service.expectLink(phoneId);
      await service.checkOwnList(phoneId);
      return service;
    }))!;
    await pump(tester, web, devices);

    expect(find.text(l10nEn.devicesLinkedTo('CT-PHON-E001')), findsOneWidget);
    expect(find.text(l10nEn.devicesAdd), findsNothing);
    await tearDownDevices(tester);
  });
}
```

Run: `flutter test test/features/devices/devices_screen_test.dart` - Expected: compile error, `devices_screen.dart` does not exist.

- [ ] **Step 8: Implement the screens**

Create `lib/features/devices/devices_screen.dart`:

```dart
import 'dart:async';

import 'package:calltype_core/crypto/device_list.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/network/api_client.dart';
import '../../core/network/signalr_client.dart';
import '../../core/storage/database.dart';
import '../../l10n/l10n.dart';
import '../contacts/qr_scanner_screen.dart';
import 'device_service.dart';
import 'link_controllers.dart';

/// Settings > Linked devices. On the primary: its companions, removal and
/// "Link a device". On a companion: whose device it is; the list is managed
/// on the primary, the only device that can sign it.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  // The contact scanner has the same gap: no camera plugin on these.
  static bool get _hasCamera =>
      kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.windows &&
          defaultTargetPlatform != TargetPlatform.linux);

  Future<(List<DeviceListEntry>, bool)> _load(
    AppDatabase db,
    DeviceService devices,
  ) async => (await devices.companions(), await isEmptyDevice(db));

  @override
  Widget build(BuildContext context) {
    final devices = context.watch<DeviceService>();
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsDevices)),
      body: devices.isCompanion
          ? FutureBuilder<String?>(
              future: devices.linkedPrimaryHandle(),
              builder: (context, snapshot) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.devicesLinkedTo(
                    snapshot.data ?? devices.directory.selfIdentityId,
                  ),
                ),
              ),
            )
          : FutureBuilder<(List<DeviceListEntry>, bool)>(
              future: _load(context.read<AppDatabase>(), devices),
              builder: (context, snapshot) {
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final (companions, empty) = data;
                return ListView(
                  children: [
                    if (companions.isEmpty) ListTile(title: Text(l10n.devicesEmpty)),
                    for (final device in companions)
                      ListTile(
                        leading: const Icon(Icons.devices_other_rounded),
                        title: Text(
                          l10n.devicesDeviceLabel(device.deviceId.substring(0, 8)),
                        ),
                        trailing: TextButton(
                          onPressed: () => _remove(context, device.deviceId),
                          child: Text(l10n.devicesRemove),
                        ),
                      ),
                    if (_hasCamera && companions.length < maxCompanionDevices)
                      ListTile(
                        leading: const Icon(Icons.qr_code_scanner_rounded),
                        title: Text(l10n.devicesAdd),
                        onTap: () => _add(context),
                      ),
                    // Decision 3: only an empty device may become a companion,
                    // and a device that already has companions is a primary.
                    if (empty && companions.isEmpty)
                      ListTile(
                        leading: const Icon(Icons.link_rounded),
                        title: Text(l10n.linkDeviceAction),
                        onTap: () => context.push('/settings/devices/link'),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Future<void> _remove(BuildContext context, String deviceId) async {
    final l10n = context.l10n;
    final devices = context.read<DeviceService>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.devicesRemoveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.devicesRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await devices.removeCompanions({deviceId});
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.devicesRemoveFailed)));
    }
  }

  Future<void> _add(BuildContext context) async {
    final devices = context.read<DeviceService>();
    final api = context.read<ApiClient>();
    final signalR = context.read<SignalRClient>();
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen(deviceLink: true)),
    );
    final scanned = result?['link'];
    if (scanned == null || !context.mounted) return;
    final controller = PrimaryLinkController(
      devices: devices,
      apiClient: api,
      signalRClient: signalR,
    );
    unawaited(controller.link(scanned));
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChangeNotifierProvider.value(
        value: controller,
        child: const _PrimaryLinkDialog(),
      ),
    );
    controller.dispose();
  }
}

class _PrimaryLinkDialog extends StatelessWidget {
  const _PrimaryLinkDialog();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PrimaryLinkController>().state;
    final l10n = context.l10n;
    final message = switch (state) {
      PrimaryLinkState.waitingForConsent => l10n.devicesWaitingConsent,
      PrimaryLinkState.mismatch => l10n.devicesFingerprintMismatch,
      PrimaryLinkState.failed => l10n.devicesLinkFailed,
      _ => null,
    };
    final busy =
        state == PrimaryLinkState.idle ||
        state == PrimaryLinkState.working ||
        state == PrimaryLinkState.waitingForConsent;
    return AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const CircularProgressIndicator()
          else
            Icon(
              state == PrimaryLinkState.linked
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              size: 48,
            ),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          // Built-in and localized in every Flutter language.
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
```

Create `lib/features/devices/link_device_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/l10n.dart';
import 'link_controllers.dart';

/// The new device's side of linking: QR code, the "Link to CT-XXXX-XXXX?"
/// question, then waiting until the primary has signed the list.
class LinkDeviceScreen extends StatelessWidget {
  const LinkDeviceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CompanionLinkController>();
    final l10n = context.l10n;
    if (controller.state == CompanionLinkState.linked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/chats');
      });
    }
    final handle = controller.offeredHandle ?? '';
    final Widget body = switch (controller.state) {
      CompanionLinkState.notEmpty => Text(
        l10n.linkDeviceNotEmpty,
        textAlign: TextAlign.center,
      ),
      CompanionLinkState.showingCode => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: QrImageView(data: controller.code!, size: 240),
          ),
          const SizedBox(height: 24),
          Text(l10n.linkDeviceInstructions, textAlign: TextAlign.center),
        ],
      ),
      // The handle comes from the server's LinkOffer; the user's comparison
      // with the phone in their hand is what catches a forged offer.
      CompanionLinkState.offered => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.linkDeviceConfirmTitle(handle),
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(l10n.linkDeviceConfirmBody(handle), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: controller.reject,
                child: Text(l10n.commonCancel),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: controller.accept,
                child: Text(l10n.linkDeviceConfirm),
              ),
            ],
          ),
        ],
      ),
      CompanionLinkState.waiting => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(l10n.linkDeviceWaiting, textAlign: TextAlign.center),
        ],
      ),
      CompanionLinkState.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.devicesLinkFailed, textAlign: TextAlign.center),
          TextButton(onPressed: controller.reject, child: Text(l10n.commonRetry)),
        ],
      ),
      CompanionLinkState.loading ||
      CompanionLinkState.linked => const CircularProgressIndicator(),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.linkDeviceAction)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: body,
        ),
      ),
    );
  }
}
```

`lib/features/contacts/qr_scanner_screen.dart`:
- Add `import '../devices/link_code.dart';`.
- Replace the widget constructor `const QrScannerScreen({super.key});` with

```dart
  const QrScannerScreen({super.key, this.deviceLink = false});

  /// Multi-device "Link a device": accept ONLY `jaylink://` codes, returned
  /// as {'link': raw}. The contact mode never accepts them (and this mode
  /// accepts no contact invites), so neither scan can be mistaken for the
  /// other.
  final bool deviceLink;
```

- In `_onDetect` replace `final result = _parseContactUri(raw);` with

```dart
      final result = widget.deviceLink
          ? (LinkCode.parse(raw) == null ? null : {'link': raw})
          : _parseContactUri(raw);
```

- In `build` replace `context.l10n.qrScanHint,` with

```dart
                  widget.deviceLink
                      ? context.l10n.devicesScanHint
                      : context.l10n.qrScanHint,
```

`lib/app/router.dart`: add the imports

```dart
import '../features/devices/devices_screen.dart';
import '../features/devices/link_controllers.dart';
import '../features/devices/link_device_screen.dart';
```

and add under the `/settings` routes (after the `identity` route):

```dart
        GoRoute(
          path: 'devices',
          builder: (context, state) => const DevicesScreen(),
          routes: [
            GoRoute(
              path: 'link',
              builder: (context, state) => ChangeNotifierProvider(
                create: (ctx) {
                  final controller = CompanionLinkController(
                    database: ctx.read<AppDatabase>(),
                    devices: ctx.read<DeviceService>(),
                    keyManager: ctx.read<KeyManager>(),
                    signalRClient: ctx.read<SignalRClient>(),
                  );
                  unawaited(controller.start());
                  return controller;
                },
                child: const LinkDeviceScreen(),
              ),
            ),
          ],
        ),
```

`lib/features/settings/settings_screen.dart`: after the identity `_SettingsTile` add:

```dart
          _SettingsTile(
            icon: Icons.phonelink_rounded,
            iconColor: colorScheme.primary,
            title: l10n.settingsDevices,
            subtitle: l10n.settingsDevicesSubtitle,
            onTap: () => context.push('/settings/devices'),
          ),
```

`lib/features/onboarding/onboarding_screen.dart`, in `_SuccessContent` after the "Start messaging" `FilledButton.icon(...)`, add:

```dart
        const SizedBox(height: 12),
        // Right after registration the device is still empty, the only kind
        // of device v1 links as a companion (decision 3).
        OutlinedButton.icon(
          onPressed: () => context.go('/settings/devices/link'),
          icon: const Icon(Icons.link_rounded),
          label: Text(context.l10n.linkDeviceAction),
        ),
```

- [ ] **Step 9: Run everything, verify it passes**

Run: `flutter analyze && flutter test`
Expected: no issues, all tests PASS (link code, controllers, screens, l10n guards).

- [ ] **Step 10: Commit**

```bash
git add src/client/calltype/lib src/client/calltype/test
git commit -m "feat(app): link a device by QR code and manage linked devices

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Bots - calltype_bot routes through the directory and replies with fan-out

Without this a user's companion never sees bot replies, and a message from a companion opens a second conversation (plan 1, "Plan 2 scope" item 8). Same constraints as the app inbox and outbox. `jay_archiver` is not touched (the auditor is a primary-only business device).

**Files:**
- Modify: `src/bots/calltype_bot/lib/calltype_bot.dart`
- Modify: `src/bots/calltype_bot/test/helpers.dart`, `src/bots/calltype_bot/test/bot_runtime_test.dart`, `src/bots/hermes_bridge/test/hermes_bridge_test.dart`

- [ ] **Step 1: Teach the fake API device lists**

In `src/bots/calltype_bot/test/helpers.dart` add `import 'package:calltype_core/crypto/device_list.dart';`. In `FakeApi` add the field

```dart
  /// GET /devices/{id}/device-list bodies, keyed by EVERY device id of the
  /// list (the real server answers for the primary and its companions).
  final deviceLists = <String, Map<String, dynamic>>{};
```

and in `_serve`, before the `segments[0] == 'groups'` branch, add

```dart
    } else if (segments.length == 3 && segments[2] == 'device-list') {
      body = deviceLists[segments[1]];
```

Add at the end of the file:

```dart
/// [primary]'s signed device list naming [companions], as the server serves it.
Future<Map<String, dynamic>> signedDeviceList(
  FakeUser primary,
  List<FakeUser> companions, {
  required int version,
}) async {
  final signed = await signDeviceList(
    primarySigningKey: await primary.keys.getSigningKeyPair(),
    list: DeviceList(
      primaryDeviceId: primary.id,
      version: version,
      devices: [
        for (final c in companions)
          DeviceListEntry(
            deviceId: c.id,
            identityKey: await c.keys.getPublicIdentityKey(),
            signingKey: (await c.keys.getSignedIdentityBundle())['signingKey']!,
            consentSig: await signDeviceLinkConsent(
              companionSigningKey: await c.keys.getSigningKeyPair(),
              primaryDeviceId: primary.id,
              companionDeviceId: c.id,
            ),
          ),
      ],
    ),
  );
  return {
    'primaryDeviceId': primary.id,
    'version': version,
    'payload': signed.payload,
    'signature': signed.signature,
  };
}
```

- [ ] **Step 2: Update the existing expectations and write the failing test**

In `src/bots/calltype_bot/test/bot_runtime_test.dart` replace all occurrences:
- `'SendReliableMessage'` with `'SendReliableDirectFanout'`
- `'SendReliableGroupMessage'` with `'SendReliableGroupFanout'`
- `sent[2] as String` with `(sent[3] as Map<String, String>)[alice.id]!`
- `s[2] as Map<String, String>` with `s[3] as Map<String, String>`

(The fan-out methods take `[target, messageId, allRecipients, payloads]`, so the payload map moved from index 2 to 3.)

In `src/bots/hermes_bridge/test/hermes_bridge_test.dart` replace all occurrences:
- `'SendReliableMessage'` with `'SendReliableDirectFanout'`
- `'SendReliableGroupMessage'` with `'SendReliableGroupFanout'`
- `sent[2] as String` with `(sent[3] as Map<String, String>)[alice.id]!`
- `notice[2] as Map<String, String>` with `notice[3] as Map<String, String>`

Check: `grep -n "\[2\]" src/bots/calltype_bot/test/bot_runtime_test.dart src/bots/hermes_bridge/test/hermes_bridge_test.dart` prints nothing.

Append to `bot_runtime_test.dart` inside `main()`:

```dart
  test('a user\'s companion lands in the user\'s conversation; the reply reaches both devices', () async {
    final aliceWeb = await FakeUser.create('00000000-0000-4000-8000-0000000000aa');
    addTearDown(aliceWeb.close);
    api.keyBundles[aliceWeb.id] = await aliceWeb.keyBundle();
    final list = await signedDeviceList(alice, [aliceWeb], version: 1);
    api.deviceLists[alice.id] = list;
    api.deviceLists[aliceWeb.id] = list;
    final bot = await startBot();
    final seen = <BotMessage>[];
    await bot.onMessage((msg) async {
      seen.add(msg);
      await msg.reply('hi both');
    });

    hub.deliver(await aliceWeb.messageTo(bot.deviceId, api.botBundle, 'from the web'));
    await until(() => hub.calls('AcknowledgeMessage').isNotEmpty);

    expect(seen.single.senderId, alice.id);
    expect(seen.single.conversationId, alice.id);
    // Acknowledged with the TRANSPORT sender: the server queues per device.
    expect(hub.calls('AcknowledgeMessage').single, [aliceWeb.id, seen.single.id]);
    final sent = hub.calls('SendReliableDirectFanout').single;
    expect(sent[0], alice.id);
    final payloads = sent[3] as Map<String, String>;
    expect(payloads.keys.toSet(), {alice.id, aliceWeb.id});
    expect(await aliceWeb.read(bot.deviceId, payloads[aliceWeb.id]!), 'hi both');
    expect(await alice.read(bot.deviceId, payloads[alice.id]!), 'hi both');
  });
```

- [ ] **Step 3: Run the tests, verify they fail**

Run (in `src/bots/calltype_bot`): `dart test`
Expected: FAIL. The bot still calls `SendReliableMessage` / `SendReliableGroupMessage`, and the companion's message is handled as `aliceWeb`.

- [ ] **Step 4: Implement in `calltype_bot.dart`**

Add the imports:

```dart
import 'package:calltype_core/crypto/device_list.dart' show DeviceListException;
import 'package:calltype_core/devices/device_directory.dart';
import 'package:calltype_core/devices/fanout_sender.dart';
```

`BotMessage`: replace the constructor and the `senderId` / `conversationId` fields with:

```dart
  BotMessage._(
    this._bot, {
    required this.id,
    required this.text,
    required this.senderId,
    required this.conversationId,
    required this.isGroup,
    required this.mentionsBot,
    required String ackSenderId,
    String? groupName,
  }) : _groupName = groupName,
       _ackSenderId = ackSenderId;

  final CallTypeBot _bot;
  final String? _groupName;

  /// The device that actually sent it. The server queues per device, so the
  /// acknowledgement must name this one, not the identity in [senderId].
  final String _ackSenderId;

  /// Server-unique message UUID - the idempotence key.
  final String id;
  final String text;

  /// The sender's IDENTITY (a user's primary device id): the same for every
  /// device of that user, so allowlists and per-user memory keep working.
  final String senderId;

  /// Stable per conversation: the peer's identity id (1:1) or the group id.
  /// Backends use it to keep separate memory per conversation.
  final String conversationId;
```

(keep `isGroup`, `mentionsBot` and `reply` as they are).

`CallTypeBot`: change the private constructor to

```dart
  CallTypeBot._(
    this._db,
    this._api,
    this._sessions,
    this._signalR,
    this._directory,
    this._fanout,
    this.deviceId,
    this.handle,
    this.displayName,
    this._log,
    this._sendRetryDelay,
  );
```

and add after `final SignalRClient _signalR;`:

```dart
  /// Multi-device: who owns which device (a user's companion belongs to the
  /// user's conversation) and the per-device envelopes of a reply.
  final DeviceDirectory _directory;
  final FanoutSender _fanout;
```

In `start`, replace the final `return CallTypeBot._(...);` with:

```dart
    final sessions = SessionManager(database: db, keyManager: keys);
    final directory = DeviceDirectory(
      database: db,
      apiClient: api,
      selfDeviceId: deviceId,
      selfSigningKey: () async =>
          (await keys.getSignedIdentityBundle())['signingKey']!,
      selfIdentityKey: keys.getPublicIdentityKey,
    );
    await directory.load();
    return CallTypeBot._(
      db,
      api,
      sessions,
      SignalRClient(
        baseUrl: apiBaseUrl,
        deviceId: deviceId,
        authService: auth,
        transportFactory: transportFactory ?? WebSocketHubTransport.new,
      ),
      directory,
      FanoutSender(directory: directory, sessions: sessions, apiClient: api),
      deviceId,
      handle,
      displayName,
      log,
      sendRetryDelay,
    );
```

Replace `_receive` with:

```dart
  Future<void> _receive(Map<String, dynamic> data) async {
    final senderId = data['senderId'] as String?;
    final messageId = data['messageId'] as String?;
    final groupId = data['groupId'] as String?;
    if (senderId == null || messageId == null) return;

    // Multi-device: a device the bot never talked to may be a companion of a
    // user it knows. Learn that BEFORE the allowlist, which names users
    // (identities). Only for a sender without a session: one lookup per new
    // device, never one per message.
    if (await _directory.identityOf(senderId) == senderId.toLowerCase() &&
        !await _sessions.hasSession(senderId)) {
      try {
        await _directory.refresh(senderId, ensurePinned: _ensureSession);
      } catch (_) {
        // No verified list: the sender stays its own identity, as before.
      }
    }
    final identity = await _directory.identityOf(senderId);
    if (!(_allowSender?.call(identity) ?? true)) {
      await _ack(senderId, messageId);
      return;
    }

    // Idempotence across replays AND restarts: the id row is committed in
    // the same transaction as the ratchet advance below. Known id = a
    // re-delivery (our ack was lost, or we crashed mid-handler) - ack only.
    // This makes handling AT-MOST-ONCE on purpose: a backend with tools
    // must never run the same instruction twice; after a crash mid-handler
    // the user simply asks again.
    final seen = await (_db.select(
      _db.messages,
    )..where((m) => m.id.equals(messageId))).getSingleOrNull();
    if (seen != null) {
      await _ack(senderId, messageId);
      return;
    }

    final ({Map<String, dynamic> payload, InboundRoute route})? result;
    try {
      result = await _db
          .transaction<({Map<String, dynamic> payload, InboundRoute route})?>(
            () async {
              final plaintext = await _sessions.decryptMessage(
                senderId,
                utf8.decode(base64Decode(data['encryptedBody'] as String)),
                deferPreKeyCleanup: true,
              );
              Map<String, dynamic>? decoded;
              InboundRoute? route;
              try {
                // The keys the device used must be the keys its primary
                // signed. A mismatch is dropped, but only after the ratchet
                // step and the seen-row commit, so a replay is acked instead
                // of decrypted again.
                await _directory.assertListedKeys(senderId);
                decoded = jsonDecode(plaintext) as Map<String, dynamic>;
                // The inner (encrypted, authenticated) payload must agree with
                // the outer (server-controlled) routing data - otherwise the
                // server could replay a 1:1 message into a group or under
                // another id.
                if (decoded['v'] != 1 ||
                    decoded['id'] != messageId ||
                    decoded['groupId'] != groupId ||
                    decoded['body'] is! String) {
                  throw const FormatException('Message context mismatch');
                }
                final to = decoded['to'];
                route = await _directory.routeInbound(
                  senderDeviceId: senderId,
                  groupId: groupId,
                  to: to is String ? to : null,
                );
              } on DeviceListException {
                route = null;
              }
              await _db
                  .into(_db.messages)
                  .insert(
                    MessagesCompanion.insert(
                      id: messageId,
                      conversationId: route?.conversationId ?? groupId ?? identity,
                      senderId: route?.senderIdentityId ?? identity,
                      // Body deliberately NOT stored: only the id is needed for
                      // idempotence, and less plaintext on disk is better.
                      status: const Value('seen'),
                      createdAt: DateTime.now(),
                    ),
                  );
              return route == null ? null : (payload: decoded!, route: route);
            },
          );
      await _sessions.finalizePreKeyCleanup();
    } catch (error) {
      // Not acked, like the app: a message we could not authenticate is
      // never reported as delivered. It expires with the server's TTL.
      if (_reportedFailures.add(messageId)) {
        _log('Cannot decrypt message $messageId from $senderId: $error');
      }
      return;
    }

    // Dropped (keys differ from the signed list), or a copy from one of the
    // bot's own devices (a bot has none; never answer itself).
    if (result == null || result.route.own) {
      await _ack(senderId, messageId);
      return;
    }
    final payload = result.payload;
    final route = result.route;
    final body = payload['body'] as String;
    final mentioned = mentionsBot(
      body,
      handle: handle,
      displayName: displayName,
    );
    // v1 is text only; in groups the bot speaks only when addressed
    // (decision §7.1) - everything else is acknowledged and ignored.
    if ((payload['type'] ?? 'text') != 'text' ||
        (groupId != null && !mentioned)) {
      await _ack(senderId, messageId);
      return;
    }

    final message = BotMessage._(
      this,
      id: messageId,
      text: body,
      senderId: route.senderIdentityId,
      conversationId: route.conversationId,
      isGroup: groupId != null,
      mentionsBot: mentioned,
      ackSenderId: senderId,
      groupName: payload['groupName'] as String?,
    );
    final tail = _conversations[message.conversationId] ?? Future.value();
    late final Future<void> next;
    next = tail.then((_) => _handle(message)).whenComplete(() {
      // Drop finished chains so the map does not grow with every peer ever.
      if (_conversations[message.conversationId] == next) {
        _conversations.remove(message.conversationId);
      }
    });
    _conversations[message.conversationId] = next;
  }
```

In `_handle` replace `await _ack(message.senderId, message.id);` with `await _ack(message._ackSenderId, message.id);`.

Replace `_send` with:

```dart
  Future<void> _send(
    String conversationId,
    String text, {
    String? groupId,
    String? groupName,
  }) async {
    final messageId = _uuidV4();
    final payload = jsonEncode({
      'v': 1,
      'id': messageId,
      'body': text,
      'type': 'text',
      'groupId': groupId,
      'groupName': groupName,
      // Multi-device: names the direct conversation for a sender's own other
      // devices; required in every direct payload (constraint 4).
      if (groupId == null) 'to': conversationId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    });
    final identityIds = groupId == null
        ? [conversationId]
        : [
            for (final id in await _api.getGroupMembers(groupId))
              if (id.toLowerCase() != deviceId.toLowerCase()) id,
          ];

    // Encrypt once (inside the crypto queue), then retry only the network
    // send: re-encrypting would advance the ratchet for a message the peer
    // may already have received. One envelope per device of every recipient
    // identity (a user's companions included), from verified lists only.
    var envelopes = await _inCrypto(
      () => _db.transaction(() => _fanout.encrypt(identityIds, payload)),
    );
    var businessGroup = false;
    // ponytail: 3 attempts, then the reply is lost (logged by the caller's
    // error path). Add a persistent outbox like the app's if this bites.
    for (var attempt = 1; ; attempt++) {
      try {
        if (businessGroup) {
          // Whole fan-out in one call: the hub rejects a business group call
          // without the auditor's envelope (KB2).
          await _signalR.sendGroupMessage(
            groupId!,
            envelopes,
            messageId: messageId,
          );
        } else if (groupId == null) {
          await _signalR.sendDirectFanout(
            conversationId,
            envelopes,
            messageId: messageId,
          );
        } else {
          await _signalR.sendGroupFanout(
            groupId,
            envelopes,
            messageId: messageId,
          );
        }
        return;
      } catch (e) {
        if (attempt == 3) rethrow;
        final required = SignalRClient.staleRequired(e);
        if (!businessGroup &&
            groupId != null &&
            e.toString().contains('fanout_unsupported_in_business_group')) {
          // The bot cannot tell a business group beforehand. Business groups
          // stay on the per-member call (primary devices only). The refused
          // call queued nothing, so encrypting again only skips a ratchet
          // step for the members.
          businessGroup = true;
          envelopes = await _inCrypto(
            () => _db.transaction(() async {
              final encrypted = await GroupCipher(
                sessionManager: _sessions,
                ensureSession: _ensureSession,
              ).encryptForGroup(groupId, identityIds, payload);
              return encrypted.map(
                (id, bytes) => MapEntry(id, base64Encode(bytes)),
              );
            }),
          );
        } else if (!businessGroup && required != null) {
          // The hub knows a different device set: re-read the lists, keep
          // existing envelopes byte for byte, add or drop the difference.
          final current = envelopes;
          envelopes = await _inCrypto(
            () => _fanout.reconcile(
              envelopes: current,
              required: required,
              identityIds: identityIds,
              payload: payload,
            ),
          );
        } else {
          await Future<void>.delayed(_sendRetryDelay);
        }
      }
    }
  }

  /// Runs [action] in the crypto queue (see [_crypto]) and returns its result.
  Future<T> _inCrypto<T>(Future<T> Function() action) {
    final result = _crypto.then((_) => action());
    _crypto = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
```

- [ ] **Step 5: Run the bot suites**

Run, one after the other: `cd src/bots/calltype_bot && dart analyze && dart test`, then `cd src/bots/hermes_bridge && dart analyze && dart test`, then `cd src/bots/jay_archiver && dart analyze && dart test`.
Expected: no issues, all PASS (the archiver's live E2E files stay skipped without `JAY_E2E_API`).

- [ ] **Step 6: Commit**

```bash
git add src/bots/calltype_bot src/bots/hermes_bridge/test
git commit -m "feat(bots): route by identity and reply to every device of a user

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Docs and final verification

**Files:**
- Create: `docs/acceptance/multi-device.md`
- Modify: `CLAUDE.md`, `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md` (status line)

- [ ] **Step 1: Acceptance checklist**

Create `docs/acceptance/multi-device.md` (Czech, like the other acceptance files):

```markdown
# Multi-device (spec 1: live sync) - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`. Plány:
`docs/superpowers/plans/2026-10-13-multi-device-sync-1-protocol.md`,
`docs/superpowers/plans/2026-10-14-multi-device-sync-2-app.md`.

Zařízení: P = telefon (primární, Android nebo iOS), W = web (`https://jay.zcloud.cz`, nová instalace = čistý prohlížečový profil), B = druhý uživatel (libovolné zařízení s aktuální verzí).

## Automatické ověření

| Co | Stav |
| --- | --- |
| Server: `GroupEndpointsTests`, `FanoutHubTests`, `DeviceListEndpointsTests` (Testcontainers) | NOT_RUN |
| `calltype_core`: `dart analyze` + `dart test` | NOT_RUN |
| App: `flutter analyze` + `flutter test` (vč. `multi_device_flow_test`, `message_inbox_multi_device_test`, l10n guardy) | NOT_RUN |
| Boti: `calltype_bot`, `hermes_bridge`, `jay_archiver` - `dart analyze` + `dart test` | NOT_RUN |
| Živé E2E `jay_archiver/test/e2e/multi_device_e2e_test.dart` proti lokálnímu compose (nikdy beta) | NOT_RUN |

## Ruční scénáře (telefon + web)

| # | Scénář | Stav |
| --- | --- | --- |
| M-01 | W čerstvě zaregistrovaný: "Propojit s existujícím zařízením" ukáže QR kód | NOT_RUN |
| M-02 | P: Nastavení > Propojená zařízení > Propojit zařízení, naskenovat QR z W; W ukáže "Propojit s CT-…?" s handlem P; po potvrzení W skončí v seznamu chatů a P ukáže zařízení v seznamu | NOT_RUN |
| M-03 | W s kontaktem nebo chatem: propojení odmítnuto textem "jen zařízení bez kontaktů a chatů" | NOT_RUN |
| M-04 | QR z jiného zařízení než toho, jehož klíče server vrátí (podvržený kód): P ukáže varování "Kód neodpovídá klíčům zařízení", W nedostane nabídku | NOT_RUN |
| M-05 | B pošle zprávu P: dorazí na P i W do konverzace s B | NOT_RUN |
| M-06 | W odpoví B: B ji vidí v existující konverzaci s P (ne v nové); P ji vidí jako vlastní odeslanou, bez nepřečteného odznaku | NOT_RUN |
| M-07 | W smaže svou zprávu "pro všechny": zmizí u B i na P | NOT_RUN |
| M-08 | Skupina (ne firemní), ve které je P: W ji po první zprávě vidí, může do ní psát, ostatní členové vidí odesílatele jako P | NOT_RUN |
| M-09 | U B se v konverzaci s P objeví řádek "Tento kontakt přidal zařízení"; po odebrání W "…odebral zařízení" | NOT_RUN |
| M-10 | P odebere W, když je W online: W ukáže "Toto zařízení bylo odpojeno…" a nemá žádné chaty; další zpráva od B na W nedorazí | NOT_RUN |
| M-11 | P odebere W, když je W offline; W se po spuštění připojí a smaže data (hint se při offline ztratí, kontrola při připojení) | NOT_RUN |
| M-12 | Na W: žádná tlačítka hovoru, žádné "Nová skupina", ve firemní konverzaci místo pole pro psaní text "Firemní chaty jen na hlavním zařízení" | NOT_RUN |
| M-13 | Hovor od B na P zvoní jen na P | NOT_RUN |
| M-14 | Na W "Moje identita" ukazuje pozvánku P (handle P), ne W | NOT_RUN |
| M-15 | Bot (hermes_bridge): zpráva z W dostane odpověď na W i na P | NOT_RUN |
| M-16 | Záloha z P obnovená na jiném zařízení: obnova projde i s řádky hovorů a změn zařízení | NOT_RUN |

Známé limity v1 (nejsou chybou přejímky): historie před propojením se nepřenáší (spec 2); stav přečtení, mazání "pro mě" a přejmenování kontaktu se mezi zařízeními nesynchronizují (spec 3); konverzace na W s lidmi, kteří tam nejsou v kontaktech, mají jako název technické id; protějšek se starou verzí posílá jen na P; propojení z Windows/Linux není (chybí kamera); ztráta P = seznam už nejde měnit (spec 4).
```

- [ ] **Step 2: `CLAUDE.md`**

- In "What this is", replace the bullet

```markdown
- **Optional registration** (email + passphrase) enables cloud backup and
  multi-device sync.
```

with

```markdown
- **Optional registration** (email + passphrase) enables cloud backup.
- **Multi-device** without an account: a new device is linked by QR code from
  the primary, which signs the device list (spec
  `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`).
```

- In the endpoint table replace

```markdown
| `POST /groups` | Create group | ✅ Done |
| `GET /groups/{id}/members` | List members (+ public profile: handle, display name, isBot) | ✅ Done |
```

with

```markdown
| `POST /groups` | Create group (403 `companion_cannot_manage_groups` from a companion device) | ✅ Done |
| `GET /groups/{id}/members` | List members (+ public profile: handle, display name, isBot); a companion reads the groups of its identity | ✅ Done |
```

- In the `SignalR /hub` row replace `` `LinkOffer`, `LinkConsent`, event `DeviceListChanged` `` with `` `LinkOffer` (event carries the primary's `userHandle`), `LinkConsent`, event `DeviceListChanged` ``.
- In "Spec & plan" add the bullet:

```markdown
- **Multi-device (spec 1 of 4, live sync):** `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`, plans `docs/superpowers/plans/2026-10-13-multi-device-sync-1-protocol.md` (core + server) and `2026-10-14-multi-device-sync-2-app.md` (app + bots); manual acceptance in `docs/acceptance/multi-device.md` is NOT_RUN. Companions: no calls, no business conversations, only an empty device can be linked.
```

- [ ] **Step 3: Spec status line**

In `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md` replace the status paragraph (lines 3-5) with:

```markdown
Status: approved direction (owner, 2026-10-13). Protocol layer (core, server,
live E2E) and app + bot runtime implemented on `feat/multi-device-sync`
(plans 1 and 2); manual acceptance in `docs/acceptance/multi-device.md`.
```

- [ ] **Step 4: Final verification, everything once**

Run, sequentially:
1. `cd src/client/calltype_core && dart analyze && dart test`
2. `cd src/client/calltype && flutter analyze && flutter test`
3. `cd src/bots/calltype_bot && dart test`, `cd src/bots/hermes_bridge && dart test`, `cd src/bots/jay_archiver && dart test`
4. `dotnet test src/server/CallType.Api.Tests` (Docker; once, alone)
5. Optional, local compose only: `docker compose up -d --build api` then `cd src/bots/jay_archiver && JAY_E2E_API=http://localhost:8080 dart test test/e2e` (10 auth calls per minute per IP: do not re-run within the same minute).

Expected: everything green; `build/l10n_untranslated.json` is `{}`; `git grep -nP '\x{2014}' -- docs/superpowers/plans/2026-10-14-multi-device-sync-2-app.md docs/acceptance/multi-device.md src/client/calltype/lib/features/devices` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add docs/acceptance/multi-device.md CLAUDE.md docs/superpowers/specs/2026-10-13-multi-device-sync-design.md
git commit -m "docs: multi-device app status and acceptance checklist

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Done when

- All suites in Task 12 Step 4 are green.
- Two app instances with real crypto (the flow test) show: B to A reaches both of A's devices; A's companion answers into B's existing conversation; A's primary sees that answer as its own; after removal B leaves the companion out.
- A companion never gets a call button, a business input or "New group"; a primary can link and remove devices; a verified removal wipes the companion and nothing else does.
- Manual checklist `docs/acceptance/multi-device.md` exists (NOT_RUN until the owner runs it on a phone and the web).

## Self-review (done while writing)

- Spec coverage: Part A linking (Task 10), removal and "cannot verify" (Task 5), peer notice (Tasks 5, 9); Part B sending (Task 8) and receiving rules 1-4 (Task 7); the identity split (Task 6); Limits of v1 in UI (Task 9) and docs (Task 12); Part C client tests (Tasks 5, 7, 8, 10); bots (Task 11); backup bug (Task 3). The server-side items of Part A/B were plan 1.
- Constraints: 1 and 2 (Task 7), 3 (Task 5), 4 (Task 8), 5 (Tasks 5, 8), 6 (Tasks 1, 8, 9), 7 (Task 10), 8 (Tasks 5, 6), 9 (carried over unchanged; not touched here).
- Names used across tasks: `DeviceListChange.firstList`, `ChatController._sendBusinessFallback`, `DeviceService.{open, directory, isOpen, isCompanion, status, checkOwnList, expectLink, linkedPrimaryHandle, companions, addCompanion, removeCompanions, dropVanishedCompanions}`, `CompanionStatus.{ok, cannotVerify, removed}`, `linkedPrimaryHandleKey`, `ChatController.{myIdentityId, isCompanion}`, `MessageInboxService(directory:)`, `LinkCode`, `linkFingerprint`, `isEmptyDevice`, `PrimaryLinkController`/`PrimaryLinkState`, `CompanionLinkController`/`CompanionLinkState`, `FakeMultiDeviceServer.{add, link, store, signedList, directoryFor, pinFor, deviceServiceFor, hubs, lists, members, deviceListRequests, close}`, `FakeDeviceApi`, `FakeHubClient`, `until`, `TestDevice.directory`, `NoDeviceListsApi`.
