# Devices, device lists and fan-out

Sources of truth: `src/client/calltype_protocol/lib/crypto/device_list.dart`
(signing and verification), `calltype_core/lib/devices/device_directory.dart`
(which lists are trusted) and `calltype_core/lib/devices/fanout_sender.dart`
(per-device envelopes). Design: `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`.

Every device is a full protocol endpoint with its own keys (crypto.md) and
its own sessions. An identity (a person or a bot) is a PRIMARY device plus up
to 5 COMPANION devices. The identity id is the primary's device id.

## Device-link consent (signed by the companion)

```
consentSig = Sign(companion SK_sig,
                  UTF-8("CallType-DeviceLink-v1") || 0x00
                  || uuid_bytes(primaryDeviceId) || uuid_bytes(companionDeviceId))
```

`uuid_bytes` = the 16 bytes of the canonical lowercase UUID
(`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, hex digits only, no other
spelling accepted).

## Device list (signed by the primary)

Payload: the UTF-8 bytes of exactly this compact JSON, keys in this order:

```json
{"primaryDeviceId":"<uuid>","version":3,"devices":[
  {"deviceId":"<uuid>","identityKey":"<b64 X25519>","signingKey":"<b64 Ed25519>","consentSig":"<b64>"}]}
```

`devices` lists companions only (the primary is implicit), at most 5, no
duplicates, never the primary itself. On the wire and in storage:

```
{ "payload": base64(payload bytes),
  "signature": base64( Sign(primary SK_sig, UTF-8("CallType-DeviceList-v1") || 0x00 || payload bytes) ) }
```

Served by `GET /devices/{deviceId}/device-list` for the primary and for each
listed companion; published with `PUT /devices/{primaryDeviceId}/device-list`.

### Verification (`verifyDeviceList`)

1. `payload` (base64 text) at most 16 KiB; signature 64 bytes, key 32 bytes.
2. Ed25519 signature over domain || payload bytes with the primary's PINNED
   signing key (`peer_identity:<primary>`), never a key from the list itself.
3. `primaryDeviceId` equals the expected primary (lower case).
4. Re-encoding the parsed list with the canonical encoder gives exactly the
   payload bytes (no extra fields, whitespace or duplicate keys: the server
   parses the same bytes with another JSON parser and must see the same set).
5. `version >= minVersion` (highest version accepted so far + 1, or 1):
   an older list is a rollback, e.g. re-adding a removed device.
6. At most 5 companions, unique, not the primary.
7. Every `consentSig` verifies with that entry's `signingKey`.

Caller contract: a valid consent only proves that the LISTED key agreed.
Before a device is attributed to the identity, its own authenticated keys
(the `identityKey|signingKey` pinned from its sessions) must equal the
listed ones (`DeviceDirectory.assertListedKeys`). A received message from a
device whose keys differ from the list is dropped (but acknowledged).

## Fan-out (sending)

A message is ONE payload (payloads.md) encrypted separately for every
target device:

- 1:1: every device of the recipient identity (primary + verified
  companions) and every OTHER device of the sender's own identity, which
  get the copy with `to` = the conversation id.
- Group: the same for every member identity of the group. There are no
  Sender Keys; each envelope uses the pairwise session with that device.
  The payload carries `groupId`, and receivers reject a payload whose
  `groupId` differs from the delivery's.
- Business groups (organization conversations): one envelope per member
  identity's PRIMARY device (`GroupCipher`, `SendReliableGroupMessage`),
  sent from the primary only; companions are not part of them in v1. The
  hub refuses fan-out there, and the auditor device is a member, so it
  always gets a copy.

Targets come only from VERIFIED, stored device lists, never from the server.
The hub checks completeness: if the envelope set does not match its own view
it answers `device_list_stale` with the device set it expects. The sender
then refreshes and verifies the affected lists and

- keeps every existing envelope byte for byte (re-encrypting would advance
  the ratchet for a message the peer may already hold),
- drops envelopes for devices the refreshed lists no longer contain,
- adds envelopes for required devices it could verify, and
- fails the send if the hub requires a device it cannot verify (the server
  must not be able to add a reader).

Hub methods (SignalR): `SendReliableDirectFanout(recipientPrimaryId,
messageId, allDeviceIds, envelopes)` and `SendReliableGroupFanout(groupId,
messageId, allDeviceIds, envelopes)` (each also as `...Silent` with the same
arguments: no push to offline devices, spec 2026-11-11-bot-ack-reactions N1),
`envelopes` = map deviceId -> base64
envelope. `allDeviceIds` always names the FULL device set, so a send split
over several calls (1 MiB frame limit) cannot silently skip a device. The
per-member calls `SendReliableMessage` / `SendReliableGroupMessage` remain
for business groups. Exact signatures: `src/server/CallType.Api/Hubs/` and
`calltype_core/lib/network/signalr_client.dart`.

## Receiving

The relay attributes the message to the SENDER DEVICE. The receiver maps the
device to an identity only through a verified device list; the server's
`senderPrimaryId` is a hint that at most triggers a re-read of the list.
`to` (own copies) is honoured only when the sender device is a verified
device of the receiver's own identity.
