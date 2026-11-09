# Contacts from replies, and rename in any 1:1 chat

Status: approved (owner feedback 2026-11-09, Discord): "Když mi někdo napíše a já mu odepíšu, měl by se mi přidat do Kontaktů a měl bych mít možnost Kontakt přejmenovat. Minimálně na webu to teď nejde."

## Today
- A message from someone who is not a contact creates only a conversation (`message_inbox_service.dart`, conversation insert); no contact row. The chat title falls back to the raw device id (known limit in `docs/acceptance/multi-device.md`).
- The rename action in the chat app bar exists only `if (!group && contact != null)` (`chat_screen.dart`), so such a chat cannot be renamed, on any platform. The comment in `contacts_controller.dart` ("3. A message arrives from an unknown sender (auto-create)") describes behaviour that does not exist.
- The client cannot learn the peer's handle from its device id: the only lookup is `GET /devices/by-handle/{handle}`; `GET /devices/{id}/key-bundle` must not be used for this (it consumes a one-time pre-key).

## Decisions

| # | Decision | Why |
|---|---|---|
| C1 | Server: new `GET /devices/{id:guid}/profile` (authorized, rate limit `api`) returning exactly what `by-handle` already returns: `{deviceId, userHandle, isBot, displayName}`; 404 when unknown. No new data is exposed: anyone who knows the handle gets the same; device ids are random GUIDs. Document in AGENTS.md endpoint table. Integration tests in the existing device endpoint test class (200, 404, 401 without auth, bot flag, display name). | The client needs the handle to create a contact row (`contacts.user_handle` is NOT NULL). |
| C2 | When I SEND a message (any non-control type) in a direct (1:1) conversation whose peer is not a contact, the app adds the peer as a contact (`ContactsController.addContact` with the profile from C1: handle, isBot, displayName suggestion). Through the existing path, so contact sync (`onLocalChange`) carries it to my other devices. Incoming messages alone do not add a contact (owner: "a já mu odepíšu"). | Owner request; avoids spam senders becoming contacts. |
| C3 | Rename is offered in every direct chat's app bar menu. For a peer that is not a contact yet, "Rename" first adds the contact (C1/C2 path), then opens the same rename dialog. Also add "Add to contacts" in that menu for a non-contact (no rename needed). | Owner: rename must be possible, also on the web. |
| C4 | Chat title for a non-contact: use the profile displayName, else the handle from C1 (cached in memory/`backup_state` key `peer-profile:<id>` with a 24 h refresh), instead of the raw id. | Fixes the technical-id title in the chat list and app bar. |
| C5 | Failure handling: profile lookup failure (offline, 404 on an old server) never blocks sending; the add is retried on the next send or when the user taps Rename / Add (show the existing error snackbar style). | Sending is more important than the contact row. |
| C6 | Groups and bots: C2 does not apply to group conversations. A bot 1:1 behaves like a person (it gets added on reply, BOT badge from isBot). Business conversations: follow the existing rules for contacts in business chats; if unclear, do not auto-add there. | Scope. |
| C7 | New strings only if needed (e.g. "Add to contacts"); all 19 ARB files. | l10n rule. |

## Tests
Server: C1 integration tests. App: unit/widget tests: reply in a non-contact chat adds exactly one contact with handle/displayName/isBot from the profile; incoming message alone adds none; rename from the chat menu for a non-contact adds then renames; title uses profile name; lookup failure still sends; group chat unaffected; contact-sync hook called once.

## Compatibility
Old app versions are unaffected. A new app against an old server (no C1) keeps today's behaviour (404 -> no auto-add, Rename/Add show an error).
