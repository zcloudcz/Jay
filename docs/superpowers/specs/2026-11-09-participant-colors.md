# Participant colors in group chats

Status: approved (owner request 2026-11-09, Discord: "ve skupinovém chatu bych uvítal barevné rozlišení účastníků ... možnost u každého si zvolit jeho barvu, pak bych měl barvu účastníka napříč chaty stejnou").

## Problem

In a group chat my own messages sit on the right, but every other member's bubble has the same background (`surfaceContainerHighest`) and the same small grey name label (`labelSmall`) above it (`chat_screen.dart`, `_buildMessage`, `if (group && !mine)`). With three or more people the messages run together.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Every other participant gets a color: the name label above the bubble is drawn in that color (semibold) and the bubble gets a 1.5 px outline in the same color. My own bubbles do not change. | The owner asked for "bubble outline, or at least the name label in a different color"; both together are the clearest, and the background stays neutral so text contrast does not depend on the color. |
| D2 | Only in group chats. A 1:1 chat has one other person, so color adds nothing. | Scope. |
| D3 | The color belongs to a PERSON, not to a chat or a device: key = the user handle (`CT-XXXX-XXXX`, upper case) when known from the group member list or the local contact, else the sender id (device id, lower case). | Same color for the same person in every chat; a person with several devices (multi-device) stays one color. |
| D4 | Default (no choice made) = deterministic: FNV-1a 32-bit hash of the person key (UTF-8) modulo the palette size. | Stable across restarts, devices and app versions without storing anything; no network. |
| D5 | Palette: 10 named colors (red, orange, amber, green, teal, cyan, blue, indigo, purple, pink), each with one tone for light theme and one for dark theme, chosen so the name label has a contrast ratio of at least 4.5:1 against the bubble background (`surfaceContainerHighest`) and the page background, in both themes (WCAG 2.2 1.4.3; the outline needs 3:1, 1.4.11). A unit test computes the contrast ratios. Palette ORDER is part of this contract: index i always means the same color, because D4 and D6 store/compute indexes. Append only. | Readable labels; stable stored values. |
| D6 | The user can pick a color per person, or "Automatic" (back to D4). Stored locally in `backup_state` under key `participant_color:<person key>` = palette index as decimal text; "Automatic" deletes the key. No schema change. | `backup_state` is the existing local key-value table (also used for `bot_notice_seen:`, `contact-removed:` ...). |
| D7 | Where to pick: (a) tap on the colored name label above a group bubble; (b) "Participant color" in the message menu (long-press) of another member's message in a group; (c) "Color" in the contact's menu on the Contacts screen (next to rename). All three open the same bottom sheet: title "Color for <name>", 10 round swatches with the color name as tooltip/semantics label, the current one marked with a check, plus an "Automatic" option. The change applies immediately in every open chat. | Discoverable without a new group-info screen (none exists). |
| D8 | Quote (reply) block: when the quoted author is another participant in a group, the accent bar and author name use that participant's color instead of `colorScheme.primary`. My own quoted messages keep `primary`. | Consistency: the same person is the same color everywhere in the chat. |
| D9 | Bots are participants like anyone else (same rules). | Simple. |
| D10 | Backup and history transfer: `buildBackupData` adds an additive key `participantColors`: list of `{key, color}` (color = palette index). Import restores them (unknown or out-of-range index skipped, not an error); older backups without the key restore as today. Because history transfer between own devices reuses `buildBackupData`, a newly linked device gets the choices too. Ongoing sync of later changes between own devices is NOT part of this spec (follow-up: a `contact-sync`-style own-device message). | Choices survive restore and the move to a new phone; no wire change. |
| D11 | Nothing goes over the wire to other people and the server is not involved. Other people never learn which color I picked. | Privacy; no compatibility issues with old clients. |
| D12 | Accessibility: color is never the only cue (the name label text stays); swatches have semantic labels with the color name; the sheet works with keyboard and screen reader. | WCAG 1.4.1. |

## Strings (all 19 ARB files)

`participantColorTitle` "Color for {name}", `participantColorAction` "Participant color" (message menu), `participantColorContactAction` "Color" (contacts menu), `participantColorAutomatic` "Automatic", and one string per palette color name (`participantColorRed` ... `participantColorPink`). Czech: "Barva pro {name}", "Barva účastníka", "Barva", "Automaticky", "Červená, Oranžová, Jantarová, Zelená, Modrozelená, Azurová, Modrá, Indigová, Fialová, Růžová".

## Tests

- Unit: hash is stable (fixed expected index for a few keys), key normalization (handle upper case wins over device id; device id fallback), palette contrast >= 4.5:1 (label) and >= 3:1 (outline) in light and dark, store/read/delete in `backup_state`, backup export/import round trip incl. old backup without the key and bad index.
- Widget: group chat shows colored label + outlined bubble for another member and none for me; 1:1 chat unchanged; picking a swatch in the sheet recolors the label; "Automatic" restores the default.

## Limits

- Changes made later on one own device do not propagate to the others until a sync follow-up (only the snapshot at linking / restore carries them).
- 10 colors: in a group with more than 10 people two people can share a default color; the user can change one of them.
