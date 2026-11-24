# Jay: store listing drafts (Google Play, App Store)

Drafts for the owner to paste into the consoles. Facts are derived from the
code on branch `feat/go-live` (spec `docs/superpowers/specs/2026-11-14-go-live.md`);
recheck them if the code changes. Nothing here is a legal declaration by
itself: the export compliance answer and the console forms are the owner's.

## 1. Texts

### English

- Name: Jay Messenger
- Subtitle (App Store, 30 chars): Private chat, no phone number
- Short description (Play, 80 chars): End-to-end encrypted messages and calls. No phone number, no e-mail needed.
- Keywords (App Store, 100 chars): messenger,encrypted,private,chat,secure,calls,anonymous,e2ee,group,signal protocol
- Full description:

  Jay is a messenger that knows as little about you as possible.

  - No phone number, no e-mail: your device gets a random handle. Add people by QR code or invite link; Jay never reads your address book.
  - End-to-end encrypted 1:1 chats, groups, voice and video calls, photos, videos and files (Signal protocol: X3DH and Double Ratchet).
  - The server only passes on encrypted envelopes and deletes them after delivery.
  - Use it on your phone, tablet, computer and in the browser; link devices to your identity.
  - Optional account for encrypted backup: the backup key comes from your passphrase, we cannot open it.
  - Public channels for one-way announcements, with clear rules and reporting.
  - Block and report anyone, export your data and delete your account right in the app.
  - No ads, no trackers.

  Privacy policy: https://jay.zcloud.cz/legal/privacy-en.html
- What's new (1.0): First public release: account deletion, data export, blocking and reporting people, legal pages.

### Česky

- Název: Jay Messenger
- Podtitul (30 znaků): Soukromý chat bez čísla
- Krátký popis (80 znaků): Koncově šifrované zprávy a hovory. Bez telefonního čísla a bez e-mailu.
- Klíčová slova (100 znaků): komunikátor,šifrovaný,soukromí,chat,zprávy,hovory,anonymní,skupiny,bezpečný,e2ee
- Plný popis:

  Jay je komunikátor, který o vás ví co nejméně.

  - Bez telefonního čísla a e-mailu: zařízení dostane náhodný identifikátor. Lidi přidáte QR kódem nebo pozvánkou; Jay nikdy nečte váš adresář.
  - Koncově šifrované chaty, skupiny, hlasové a video hovory, fotky, videa a soubory (protokol Signal: X3DH a Double Ratchet).
  - Server jen předává zašifrované obálky a po doručení je maže.
  - Na telefonu, tabletu, počítači i v prohlížeči; zařízení propojíte se svou identitou.
  - Nepovinný účet pro šifrovanou zálohu: klíč zálohy vzniká z vaší fráze, my ji otevřít nemůžeme.
  - Veřejné kanály pro jednosměrná oznámení, s jasnými pravidly a nahlašováním.
  - Blokování a nahlašování lidí, export dat a smazání účtu přímo v aplikaci.
  - Žádné reklamy ani sledování.

  Zásady ochrany osobních údajů: https://jay.zcloud.cz/legal/privacy-cs.html
- Co je nového (1.0): První veřejná verze: smazání účtu, export dat, blokování a nahlašování lidí, právní stránky.

### URLs

| Field | URL |
|-------|-----|
| Privacy policy (both stores) | https://jay.zcloud.cz/legal/privacy-en.html (cs: privacy-cs.html) |
| Account deletion (Play Data safety) | https://jay.zcloud.cz/legal/delete-account-en.html |
| Support URL (App Store) | https://jay.zcloud.cz/legal/support-en.html |
| Terms (EULA field, optional) | https://jay.zcloud.cz/legal/terms-en.html |

## 2. Google Play Data safety

- Does the app collect or share user data? Yes (collects); shares: No (processors acting for us are not "sharing" under Play's definition).
- Encrypted in transit: Yes (TLS; content also end-to-end).
- Users can request deletion: Yes (in app, web app, e-mail; URL above).
- Independent security review: No.

| Play data type | Collected | Optional | Purpose | Notes |
|---|---|---|---|---|
| Personal info > Email address | Yes | Yes (only registered accounts) | Account management | Also optional contact e-mail in reports |
| Personal info > User IDs | Yes | No | App functionality, Account management | Random device id and handle |
| Personal info > Name | Yes | Yes | App functionality | Display name only if the user publishes one (bots, channels) |
| Messages > Other in-app messages | Yes | No | App functionality | Only as end-to-end encrypted envelopes until delivery, max 30 days; report evidence the user chooses to attach (Optional, Fraud prevention, security, and compliance) |
| Photos and videos / Files and docs | Yes | Yes | App functionality | End-to-end encrypted, deleted 72 h after upload |
| Audio > Voice or sound recordings | Yes | Yes | App functionality | Voice messages, end-to-end encrypted, 72 h |
| App activity > Other user-generated content | Yes | Yes | App functionality | Public channel posts (90 days) |
| Device or other IDs | Yes | No | App functionality | Push tokens (FCM) |
| App info and performance | No | | | No crash or analytics SDK |
| Location, contacts, calendar, health, financial, web history | No | | | |

Data that is end-to-end encrypted and only passes through the server could
arguably be declared "not collected" (Play: "processed ephemerally"); the
table takes the conservative choice. Calls go through Cloudflare TURN only as
encrypted media.

## 3. Apple App Privacy

- Data used to track you: None.
- Data linked to you:
  - Contact Info > Email Address (App Functionality; only registered accounts)
  - Identifiers > User ID (App Functionality)
  - User Content > Other User Content (App Functionality: public channel posts; report evidence the user attaches)
  - Identifiers > Device ID: push token (App Functionality)
- Data not collected: Location, Contacts, Browsing/Search History, Usage Data, Diagnostics, Financial, Health, Purchases, Sensitive Info.
- Messages, photos, videos and audio: Apple's definition excludes data that is end-to-end encrypted so that the developer cannot read it; Jay's message content qualifies, so "Emails or Text Messages", "Photos or Videos" and "Audio Data" are NOT declared.

## 4. Content rating (IARC questionnaire, Play; App Store age rating)

- Category: Communication / social.
- Violence, sexuality, language, controlled substances, gambling: none in app content supplied by us.
- Users can interact / exchange content: Yes (chat, calls, groups, public channels).
- Shares user location: No. Digital purchases: No.
- Users can block and report others: Yes (in app; channels and people).
- Expected result: Play "Users interact"; Apple age rating 17+ is NOT required by default, but the App Store asks about "Unrestricted web access" (No) and user-generated content: answer with the moderation tools above. The owner may still choose 12+/16+.

## 5. Export compliance facts (for the owner's answer)

Cryptography in the app (all standard, published algorithms; no proprietary algorithm):

- Messaging E2EE: Signal protocol design (X3DH + Double Ratchet) implemented in Dart with the `cryptography` package: X25519 (key agreement), Ed25519 (signatures), HKDF-SHA256 and HMAC-SHA256 (key derivation, chains), AES-256-GCM (message and media encryption).
- Local database: SQLCipher (AES-256) via drift; app PIN and backup key: Argon2id.
- Transport: TLS from the operating system (HTTPS, WSS); calls: WebRTC DTLS-SRTP.
- Server side (not shipped in the app): Argon2id password hashing, TLS, ES256 (APNs JWT), RFC 8291 aes128gcm for Web Push, HMAC-SHA1 TURN credentials.

App Store Connect answer prepared in the skill: "Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system"; mass-market item (EAR 740.17(b)(1)); a French ANSSI declaration is needed only if the app is offered in France. `ITSAppUsesNonExemptEncryption` is deliberately NOT set in `Info.plist` (owner's declaration pending). CallKit apps are rejected in the China storefront: exclude China.

## 6. Reviewer notes (App Store review / Play pre-launch)

```
Jay needs no sign-in: on first launch the app creates an anonymous identity
(handle CT-XXXX-XXXX). To test chatting, open Settings > Account to see your
handle and scan or open the invite of our demo account <DEMO HANDLE, owner>
(a person replies during the review window) or install the app on a second
device and add it by QR code.

Account deletion: Settings > Account > Delete account (type your handle).
Blocking/reporting a user: open a chat > menu > Block / Report, or
long-press a received message > Report. Group members: Group info > member
menu. Data export: Settings > Privacy > Export my data.
Calls use CallKit (iOS) and VoIP push to ring. Message content is end-to-end
encrypted; the server cannot read it, so reports may attach message text the
reporter chooses.
```
