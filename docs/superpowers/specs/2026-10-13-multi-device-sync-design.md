# Multi-device sync - Design Specification (spec 1 of 4: live sync)

Status: approved direction (owner, 2026-10-13). Not implemented.

## Problem

Signing in to an account on the web does not show the conversations the same
user sees on the phone. Today that is by construction:

- Every install is its own device with its own ID and keys. Logging in only
  adds an `AccountDevices` row (`AccountEndpoints.LinkDevice`), used for backups.
- History lives only in the device's local SQLite. The server deletes a message
  once it is delivered.
- The hub relays to exactly one `deviceId`. Nothing fans out to the other
  devices of the same user.

## Roadmap

Four specs, each with its own plan and implementation cycle:

1. **Live sync** (this document): messages for me reach all my devices,
   messages I send are mirrored to my other devices.
2. **History transfer** to a newly linked device, sent encrypted over the
   device-to-device session (no backup passphrase involved).
3. **State sync**: read state, delete-for-me, contact rename, calls ringing on
   every device.
4. **Identity recovery**: optional identity keys in the encrypted backup
   (backup v2), email / TOTP as a second factor. Decisions already taken are
   recorded in "Decisions for spec 4" below.

## Goals and non-goals

Goals:
- A user links a second device and from then on both devices receive and can
  send in the same conversations.
- The server can never add a reader. It may only cause an outage.
- Works without an email account (anonymous-first is kept).
- No migration of existing contacts, conversations or messages.

Non-goals for this spec:
- History from before linking (spec 2).
- Merging two devices that both already have conversations.
- Companions in business groups (see "Limits of v1").
- Calls on companion devices, cross-device read / delete-for-me state (spec 3).

## Why a signed device list

The question that decides the security of multi-device is: who is allowed to
say "this is also my device"?

| Option | Who authorizes a device | Server can inject a reader | Verdict |
|---|---|---|---|
| A. Server returns the account's devices | server | yes | breaks the E2EE promise |
| B. My devices forward to each other | me | no | web only works while the phone is online; a backgrounded phone has no connection |
| C. Identity = email account | account | no | multi-device only with email, rewrite of contacts and conversations |
| **D. Device list signed by the primary device** | me (QR + signature) | **no** | chosen |

Consequence the owner accepted: **signing in to the account alone must not
give access to conversations.** A new device is approved by scanning a QR code
with an already trusted device. `AccountDevices` stays what it is today:
backup ownership only.

## Terms

- **Primary device**: the device whose ID contacts already know. Its Ed25519
  signing key (`ct_signing_seed`, already pinned by peers as part of
  `peer_identity:<deviceId>`) signs the device list.
- **Companion device**: an additional device listed by the primary. It has its
  own device ID, identity key, signing key, pre-keys and Signal sessions.
- **Identity ID**: the primary device ID. It is what a contact row, a direct
  conversation ID and `messages.senderId` hold.

## Part A - device list and linking

### Signed device list

```
payload (UTF-8 JSON, stored and transmitted as the exact signed bytes):
{
  "primaryDeviceId": "<guid>",
  "version": 3,
  "devices": [
    { "deviceId": "<guid>", "identityKey": "<b64 X25519>",
      "signingKey": "<b64 Ed25519>", "consentSig": "<b64>" }
  ]
}

signature = Ed25519(primary signing key,
                    "CallType-DeviceList-v1" || 0x00 || payload bytes)
consentSig = Ed25519(companion signing key,
                    "CallType-DeviceLink-v1" || 0x00 ||
                    primaryDeviceId (16 bytes) || companionDeviceId (16 bytes))
```

- The signature covers the exact bytes that are stored and served, so there is
  no JSON canonicalization to get wrong. Clients verify first, parse second.
- `devices` lists companions only. The primary is implicit.
- `identityKey` + `signingKey` in the list stop the server from swapping a
  companion's key bundle.
- `consentSig` proves that the key written in the entry agreed. It becomes
  proof that the DEVICE agreed only together with the pinned-key comparison
  (receiving rule 4): a signer could otherwise list a stranger's device id
  with a key pair of her own. Clients therefore never attribute a companion
  whose pinned keys they cannot compare with the entry.
- `version` only grows. A client remembers the highest verified version per
  identity and rejects anything lower.
- At most 5 companions.
- The two domain separators follow the `CallType-*` convention and, like the
  existing ones, must never be renamed.

### Server

The server stores and serves. It does not verify signatures and decides
nothing about trust.

- Table `DeviceLists`: `PrimaryDeviceId` (PK), `Version`, `Payload` (bytes),
  `Signature` (bytes), `UpdatedAt`.
- Table `DeviceListMembers`: `DeviceId` (PK), `PrimaryDeviceId`. Derived from
  the payload on every PUT. The PK enforces "a device is in at most one list".
  Used only for routing validation.
- `PUT /devices/{primaryId}/device-list` - caller must be `primaryId`; version
  must be greater than the stored one (409 `device_list_version_conflict`
  otherwise); every listed device must exist, must not be a primary of another
  list and must not be in another list (409); more than 5 companions is 422.
- Consent gate: a device that is NEW in the list is accepted only after it
  sent `LinkConsent` for this primary itself, authenticated (409
  `device_list_consent_missing`). The server cannot verify signatures, and
  without this anybody could name a victim's device in a list: clients would
  reject the list, but the server would route the victim as the uploader's
  device and the victim could no longer send.
- `GET /devices/{id}/device-list` - any authenticated device; `id` may be the
  primary or a companion, the same list comes back. 404 when there is none.
- Hub event `DeviceListChanged(primaryId, version)` to the primary and all
  companions (old and new) after a successful PUT.
- `DELETE /devices/{id}` (existing GDPR endpoint): deleting a companion removes
  its `DeviceListMembers` row; deleting a primary removes the list.
- `GET /accounts/{id}/export` includes the device list of the caller's identity.

### Linking a device

1. The new device is a fresh install with its own keys, registered as usual.
   It shows a QR code: its `deviceId` and a fingerprint of
   `identityKey|signingKey`.
2. The primary scans, fetches the key bundle, compares it with the fingerprint
   from the QR code and asks the user to confirm. The QR code is the
   out-of-band channel: the server never gets to choose which keys are linked.
3. The primary sends `LinkOffer(primaryDeviceId)` to the new device through the
   hub (new relay-only hub method, target must be online, nothing is stored).
4. The new device shows "Link to CT-XXXX-XXXX?", and on confirmation answers
   `LinkConsent(consentSig)`. The new device cannot sign its consent earlier,
   because `consentSig` names the primary and it only learns the primary here.
5. The primary verifies `consentSig`, signs version + 1 and PUTs it.
6. The new device receives `DeviceListChanged`, fetches the list, pins the
   primary's keys from the primary's key bundle (it needs a session with the
   primary anyway) and verifies the signature, checks that
   its own entry is exactly what it consented to, and switches to companion
   mode.

A forged `LinkOffer` (server or another user naming a different primary) is
caught by the user in step 4: the handle shown on the new device must be the
handle of the phone in their hand. The confirmation text says so. The empty
device holds no data at that point, so a wrongly confirmed link exposes
nothing that already exists.

v1 restriction: only an empty device (no contacts, no conversations) can
become a companion.

### Removing a device

- The primary signs version + 1 without the device. Settings > Devices lists
  the companions and offers removal, on the primary only.
- A companion wipes its local data only after it has verified a higher-version
  list that no longer contains it. A missing list or a failed verification
  shows "cannot verify", and deletes nothing. Otherwise the server could force
  a history wipe by pretending the list is gone.

### What a peer sees

- The peer keeps the last verified list next to the contact (local schema v5).
- A change of the list adds a system line to the conversation: "Contact added
  a device" / "Contact removed a device". Same principle as the visible
  auditor: nothing happens silently.
- A bad signature or a lower version is ignored and the last verified list
  stays in force.

## Part B - sending and receiving

### Hub

```
SendReliableDirectFanout(Guid recipientPrimaryId, Guid messageId,
                         List<Guid> allRecipients, Dictionary<Guid,string> payloads)
SendReliableGroupFanout(Guid groupId, Guid messageId,
                        List<Guid> allRecipients, Dictionary<Guid,string> payloads)
```

Two methods because the Dart hub transport cannot send `null` arguments.

- The required device set: devices of the recipient identity (direct) or of
  every group member (group), plus the devices of the sender's own identity,
  minus the sending device.
- Completeness is checked on `allRecipients`, which must equal the required
  set. Otherwise the call fails with `device_list_stale:<required ids>`. The
  client then sends to the required devices it has verified, and refuses if
  the server requires a device it cannot verify. This is how a peer learns
  about a list change without the server knowing who the user's contacts are.
- `payloads` may carry only a part of `allRecipients`: copies of an attachment
  for several devices do not fit one 1 MiB hub frame, so a large send is split
  per device, as group attachments are today. One call is one transaction.
- The server can only lie towards an outage here. A sender encrypts only for
  devices from a list it verified. It cannot add a reader.
- Business groups reject `SendReliableGroupFanout`
  (`fanout_unsupported_in_business_group`) and stay on
  `SendReliableGroupMessage`.
- A device that no longer exists (deleted itself) is skipped by the
  completeness check.
- Queueing, acknowledgement and push are unchanged; they are already per
  device.
- `communicationPolicy.IsAllowedAsync` is evaluated on primary IDs, otherwise
  an enrolled employee could bypass `RequireBusinessConversations` through a
  companion.
- `SendReliableMessage` and `SendReliableGroupMessage` stay for old clients.

### Client - sending

- Recipients = verified devices of the peer identity (or of all group members)
  + my other devices.
- The encrypted payload gets one additive key, `to`: the peer's identity ID
  for a direct message. A copy that goes to one of my own devices would
  otherwise not know which conversation it belongs to. Old clients ignore it.
- On `device_list_stale` the outbox only adds envelopes for new devices and
  drops envelopes for removed ones. Envelopes that already exist are resent
  byte for byte, so no ratchet is advanced twice.

### Client - receiving

For an incoming envelope from `senderDeviceId`:

1. Sender is in a contact's verified list (or is the contact's primary):
   conversation = that contact's identity ID.
2. Sender is one of my own devices: conversation = `to` (or `groupId`),
   status `sent`, unread count not touched.
3. Sender unknown: fetch its device list and verify it against the pinned keys
   of the primary (trust on first use for a brand new contact, as today). If
   it does not verify, the sender is treated as an unrelated standalone
   device, as today. Attribution to somebody else's identity cannot be forced.
4. The identity key used in X3DH must equal the key in the signed list.

`messages.senderId` stores the **identity ID**, never the companion's device
ID. That keeps "mine vs theirs", delete-for-everyone sent from another device
of the same user, group sender names and reply quotes working unchanged.

### The main client change

`myDeviceId` today means both the transport address and "me". On a companion
these differ: transport = own device ID, "me" = identity ID. The split is
mechanical but touches chat, groups and the chat list, and is where most bugs
are expected. Transport-only uses (hub connection, key upload, sessions) keep
the device ID; everything that compares a stored `senderId` or builds a
conversation uses the identity ID.

## Limits of v1 (stated honestly, also in user-facing text where relevant)

- A peer on an old client still sends only to the primary. The companion does
  not see that message until the peer updates.
- Business groups: primary device only. The server validates recipients
  against membership and archives metadata there; companions need their own
  analysis together with the auditor rules.
- Calls ring on the primary only. Typing indicators are unchanged.
- Group membership is not normalized to identities: adding a companion's
  device id to a group directly makes it a member on its own (the fan-out
  then ignores the rest of that identity). Clients add primaries only; the
  server does not enforce it yet. Business policy is not affected, it is
  evaluated over identities for every send path.
- `LinkOffer` / `LinkConsent` have no rate limit: anyone who knows an online
  device id can pop a link offer on it (the user confirms the handle, so it
  is a nuisance, not a takeover).
- Peers and the server learn how many devices an identity has. Client-side
  fan-out cannot avoid that.
- The server can withhold a list update (delay a removal). It cannot add.
- The web companion is the weakest device: keys sit in browser storage, the
  local database is not SQLCipher. Every companion widens the attack surface,
  hence the device list in settings and removal from the primary.
- Losing the primary: companions keep working, but the list can no longer be
  changed. Recovery is spec 4.

## Part C - errors, tests, rollout

### Error handling

| Situation | Behaviour |
|---|---|
| Lower version or bad signature from the server | ignore, keep the last verified list |
| Server says there is no list | companion shows "cannot verify", deletes nothing |
| Two list changes at once | 409 on version, client reloads and retries |
| Companion deleted itself | skipped by the completeness check; dropped at the primary's next signature |
| Primary deleted | list is gone; companions stay in "cannot verify" |
| Decryption fails on one device | message stays queued for that device only (as today) |
| Fan-out | one transaction per call; a split attachment send is not atomic (as groups today) |

### Tests

- **Core (unit):** exact-bytes signing and verification, version monotonicity,
  `consentSig`, every tampering variant (swapped key, removed consent, foreign
  device, replayed lower version, wrong domain separator).
- **Server (Testcontainers):** PUT / GET rules, fan-out validation,
  `device_list_stale`, policy over primary IDs, device deletion.
- **Client:** routing of an incoming message (peer companion, own device,
  unknown sender), identity ID in `senderId`, outbox patching on stale.
- **Live E2E** via `calltype_bot` against docker-compose with three devices
  (A primary, A companion, B):
  - B to A arrives on both of A's devices
  - A companion to B lands in B's existing conversation with A
  - A primary sees the message A's companion sent
  - after the companion is removed, B's next send leaves it out
  - a device inserted straight into the server database is rejected by clients
- The API allows 10 auth calls per minute per IP; split the E2E files
  accordingly.

### Rollout

- One migration of the main database (applied at startup). The Audit database
  is not touched, so there is no manual ops step.
- Server first: the new hub method is additive.
- Client: local drift schema v5 (contact devices, own list state).
- Docs to update with the change: `docs/security/crypto-baseline.md`
  (mandatory for anything under `calltype_core/lib/crypto`), the endpoint table
  in `CLAUDE.md`, `docs/security/data-subject-rights.md`, new strings in all
  19 ARB files.

### Implementation phases

1. Core: device list, signatures. Server: tables and endpoints.
2. Linking and removing a device (QR, settings).
3. Fan-out send and receive, the `myDeviceId` split.
4. Live E2E, documentation.

## Decisions for spec 4 (identity recovery), recorded so they are not lost

Today a lost phone means a lost identity even with a registered account: the
backup holds contacts, conversations and messages, not keys.

- **Identity in the encrypted backup, opt-in.** Backup v2 additionally carries
  the identity private key, the signing seed, the device ID and the device
  secret. Restoring on a new phone yields the same identity, which can then
  sign device lists again. A stronger passphrase is enforced when this is on.
- **Email is a second factor and an alarm, never a root of trust.** Email
  verification is performed by the server, so "verified by email" must never
  be enough to add a device or restore an identity. What email is used for:
  - second factor for downloading a backup that contains an identity (TOTP
    step-up token when MFA is enabled, otherwise a code by email),
  - a notification on every identity restore,
  - an emergency brake in that email ("this was not me"): the server stops
    delivering to the identity and drops its pre-keys. The server may remove,
    never add; abuse is an outage, not a wiretap,
  - verification of the address at registration (not done today).
- Email goes out through the owner's MailNotify service
  (`C:\GIT\ZCLOUD\MailNotify`), not through SMTP of our own.
- What nothing solves: the lost phone still holds the key. Whoever unlocks it
  is also "you". The only defence is a new identity, which peers see as a
  key-change warning. This is true today as well.
- Known bug to fix in that spec: `backup_import.dart` accepts only
  `text/image/file/audio/video`, but the backup exports every `messages` row,
  including `call-event` (and `delete` control rows if present). One such row
  fails the whole restore with `restoreFailed`.
