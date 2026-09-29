# Uzavření mezer — X0: základ a zmrazené kontrakty (vlna 0)

> **For agentic workers:** Tento soubor je **normativní**. Když se liší od plánu proudu (`2026-09-29-gap-<proud>.md`), platí tento soubor. Tam, kde odkazuje na oddíl plánu proudu („tvar viz M §4.1“), je tvarem ten oddíl, včetně úprav uvedených zde. Nic nepřejmenovávej bez úpravy tohoto souboru a bez upozornění vlastníka dotčeného proudu. Stávající řetězce `CallType-*` v kryptografii se nikdy nemění (CLAUDE.md). Nic nenasazuj.

**Cíl X0:** Za jednu krátkou sekvenční vlnu připravit všechny horké soubory, aby proudy P, N, C, M, M2, G, S, D a O běžely ve vlně 1 plně paralelně. Konkrétně X0 připraví:
- jednu serverovou EF migraci,
- jednu klientskou migraci drift schématu v4,
- všechny nové balíčky, oprávnění a identifikátory aplikace,
- stuby všech rozhraní mezi proudy,
- toleranci neznámých typů zpráv ve všech přijímačích.

**Zdroje:** požadavky na X0 v oddílu 4 každého plánu proudu. Tento soubor je sjednocuje a řeší rozpory mezi nimi (oddíl 0).

## 0. Rozhodnuté rozpory mezi proudy

| # | Rozpor | Rozhodnutí koordinátora | Dopad |
| --- | --- | --- | --- |
| K1 | **Neznámý typ zprávy.** M chce potvrdit a zahodit, M2 uložit (jinak se média přijatá mezi X0 a M2-10 ztratí). | Obálka dostane pole **`ctl`**. Řídicí typy posílají `"ctl": true`.<br>• Neznámý typ s `ctl: true` → zápis do `InboundLog`, ack, ignorovat.<br>• Neznámý typ bez `ctl` → **uložit** do `Messages` s původním `type` a `body` a zobrazit zástupný text „Tato zpráva vyžaduje novější verzi Jay“. Po aktualizaci aplikace ji handler znovu vykreslí z uloženého `body`. Zvyšuje `unreadCount`. | M, M2, G, D, boti |
| K2 | **Archivátor a neznámý typ obsahu.** Potvrzení bez záznamu by udělalo díru v řetězu KB3. Nepotvrzení by po 24 h zablokovalo organizaci (`auditor_unavailable`). | Nový archivní kind **`other`** s `details = {"type":"<type>"}` (max. 64 znaků). Archivátor tak zapíše metadata každé zprávy obsahu, které nerozumí. Řídicí typy (`ctl: true`) bez vlastního kindu jen potvrdí bez záznamu. | X0 server + archivátor |
| K3 | **Registr příchozích handlerů.** M (`registerHandler` + `InboundResult`), D (`InboundDispatcher`, `fromOwnDevice`) a G (`registerControlHandler`) navrhly tři různá rozhraní. | Jedno rozhraní podle **M §4.4**, rozšířené o D: `InboundContext.fromOwnDevice` + `copyWith`, re-entrantní `dispatch` pro `sync`, `addPayloadObserver`. Platí pravidlo G: handler běží v transakci inboxu a nesmí volat síť. G registruje přes stejné `registerHandler` a vrací `Applied`/`Ignored`. Umístění: `src/client/calltype/lib/features/chat/inbound/`. | M, G, D, M2 |
| K4 | **Odchozí zprávy.** Kolidovaly M (`OutgoingMessages`), N (`outgoing_message_service`) a G (`ControlMessageSender`). | Jediné rozhraní **`OutgoingMessages`** podle M §4.5 s úpravami:<br>• `sendControl(String conversationId, String type, {String body = '', Map<String, Object?> fields = const {}, List<String>? recipients, bool durable = true})` samo doplní `ctl: true`. Pole `fields` jde na nejvyšší úroveň obálky (M, `receipt`), `body` je JSON řetězec (G `profile`/`group-update`, D `device-list`).<br>• Přibude `Future<void> markConversationRead(String conversationId)` (N).<br>• Soubory N `outgoing_message_service.dart` a G `ControlMessageSender` **nevznikají**. | M implementuje; N, G, M2, D volají |
| K5 | **Hovorový push.** N navrhlo `IPushNotificationService.SendCallPushAsync(callee, caller, …, businessGroupId?)`, C navrhlo `ICallPushSender`. | Rozhraní **`ICallPushSender`** podle C §5.2 (KC4). `record CallPush` dostane navíc `Guid CallerId`, který smí jít do pushe **jen** zašifrovaný v hintu `h` podle N R2. Do Applu ani Googlu nesmí odejít v čitelné podobě. `SendCallCancelPushAsync(Guid callee, Guid callId, CallCancelReason reason, CancellationToken ct)` s enumem od N. `IPushNotificationService` (N §4.3) zůstane jen pro zprávy a kanály. | N implementuje, C volá |
| K6 | **Klientský handler hovorového pushe.** N navrhlo třídu `CallPushHandler`, C top-level funkci. | Platí návrh C: `@pragma('vm:entry-point') Future<void> handleCallPush(Map<String, dynamic> data)` v `lib/features/calls/call_push_handler.dart`. Musí jít zavolat z background isolate. | N volá, C implementuje |
| K7 | **Notifikace zmeškaných a příchozích hovorů.** N navrhlo `MissedCallNotifier`, C `CallNotifications`. | Platí rozhraní C `CallNotifications` v `lib/core/notifications/call_notifications.dart` (+ `NoopCallNotifications`). **Implementuje N** (web, desktop, zmeškané hovory), volá C. Na mobilu zobrazuje příchozí hovor `flutter_callkit_incoming` (C). `MissedCallNotifier` nevzniká. | N, C |
| K8 | **Blokace a profil.** Koordinátor je chtěl jako sloupce `Contacts`, G jako samostatné tabulky. | Platí G §4.1: tabulky `PeerProfiles` a `BlockedDevices`. Profil přichází i od ne-kontaktů a blokace musí přežít smazání kontaktu. Čtení jen přes `PeerDirectory`, v izolátu přes `isDeviceBlocked(db, id)`. **N a C nečtou `Contacts.blocked` ani `profileName`** (ty sloupce neexistují). | G, N, C, M, D |
| K9 | **Bezpečnostní čísla a API identity.** Signatury G a S se liší. | Platí **signatury S** (S §4.6, S5/S6: `SafetyNumber`, `PartyIdentity`, `SafetyNumberScanResult`, `IdentityChangedException extends StateError`, `PendingIdentityChange`, metody `SessionManager`). G si UI přizpůsobí. Formát QR odkazu s otiskem: `…?fp=<base64url 32 B>`. | S implementuje, G konzumuje |
| K10 | **`session_overlay.dart`** si nárokují S (PIN) i C (hovor přes zámek). | Vlastník **S**. C smí měnit jen `_callChanged` a větev hovoru v `build`, S jen `_unlock` a formulář PINu. Obrazovku hovoru nad zámkem dodá C jako widget `LockedCallView` (stub X0). Konflikty merguje koordinátor. | S, C |
| K11 | **`audioplayers`.** M2 chce `^6.8.1`, C `>=6.7.1 <6.8.0` (kvůli Flutter 3.41 v CI). | Platí **rozsah od C**. M2 nesmí použít API, které přibylo až v 6.8. X0 to ověří na všech šesti platformách (`flutter pub get` + build). | M2, C |
| K12 | **Klíče `AppSettings`.** | Formát `<obor>.<klíč>`. Záloha (D) obsahuje všechno **kromě prefixu `local.`**.<br>• Obory: `privacy.*` (M), `notif.*` (N), `profile.*` (G), `media.*` (M2), `sec.*` (S), `calls.*` (C).<br>• Hodnoty specifické pro zařízení mají prefix `local.`, např. `local.notif.permissionAsked` a `local.notif.desktop.*`.<br>• Klíč `settings.*` z plánu D se nepoužívá. | všichni |
| K13 | **`.well-known`.** | Umístění `src/client/calltype/web/.well-known/**`, ne `www/` (G). Web přejde na `usePathUrlStrategy()` (G R8). **N musí navigovat jen přes `go_router` cesty (`/chats/:id`), nikdy přes URL s `#`.** Service worker otevírá `/<cesta>`. | G, N, P |
| K14 | **Nasazení tolerance.** | Mezi vlnou 0 a vlnou 1 je **brána W0.5**. Build X0 (API, web, archivátor, boti) musí být na betě dřív, než se k uživatelům dostane jakýkoli build, který posílá nové typy (M R-10, G riziko 1). | O, vlastník |

## 1. Rozdělení X0 na tři souběžné části

X0 je sekvenční vůči vlně 1. Uvnitř ho ale tvoří tři části s disjunktními soubory, které mohou běžet paralelně. X0-A začíná, až má X0-K zmrazené typy v core (první den).

| Část | Soubory | Obsah |
| --- | --- | --- |
| **X0-S** server | `src/server/**` | oddíl 2 |
| **X0-K** jádro a přijímače | `src/client/calltype_core/**`, `src/client/calltype/lib/features/chat/{message_inbox_service.dart,inbound/**}`, `src/bots/**` | oddíly 3 a 4 |
| **X0-A** aplikace a platformy | `src/client/calltype/{pubspec.yaml,android,ios,macos,windows,web,assets}/**`, stuby v `lib/**` (oddíl 5), `lib/main.dart` | oddíly 5 a 6 |

## 2. X0-S: server

### 2.1 Jedna EF migrace `GapClosureWave1` (`CallType.Api`, **ne** `CallType.Audit`)

| Entita | Změna | Proud |
| --- | --- | --- |
| `Device` | `VoipPushToken` string? (200) | C, N |
| `Device` | `VoipPushEnvironment` string? (10, `production\|sandbox`) | N |
| `Device` | `PushKey` byte[]? (přesně 32 B), klíč pro šifrovaný hint | N |
| `Device` | `PushTokenUpdatedAt` DateTimeOffset? | N |
| `Device` | `SignedPreKeyId` int NOT NULL DEFAULT 1 | S |
| `Device` | `SignedPreKeyUpdatedAt` DateTimeOffset? | S |
| `Device` | oprava komentáře `Models/Device.cs:29` | S |
| **nová** `E2eAttachment` | tvar podle **M2 §4.1**: `BlobId` PK (CSPRNG, `ValueGeneratedNever`), `UploaderDeviceId` bez FK, `SizeBytes`, `ChunkSizeBytes`, `ChunkCount`, `Status` (`Uploading\|Committed\|Deleting\|Deleted`), `CreatedAt`, `CommittedAt?`, `ExpiresAt`<br>Indexy: `(UploaderDeviceId, CreatedAt)`, `(Status, ExpiresAt)`, `(CreatedAt)` | M2 |

**Audit DB (`CallType.Audit`) se v X0 nemigruje.** Nové kindy jsou jen whitelist (`Kind` má max. 20 znaků, `DetailsJson` existuje). Každá migrace Audit DB znamená ruční krok vlastníka (O2).

### 2.2 Endpointy a oprava autorizace

- **Oprava IDOR (S1 vytažená do X0, S R1).** `PUT /devices/{id}/push-token` odmítne `{id}` ≠ `sub` z JWT kódem 403 `device_mismatch`. Totéž platí pro nový `DELETE /devices/{id}/push-token`. Plný audit „id v cestě proti JWT“ zůstává na S1 (tabulka v S §0).
- **`PUT /devices/{id}/push-token`**
  - Tělo: `{token, platform: fcm|apns|apns-voip, environment?, pushKey?(b64 32 B)}`.
  - `apns-voip` → `VoipPushToken` a `VoipPushEnvironment`. `PushPlatform` zůstává `fcm|apns`.
  - Odpovědi: 204, nebo 400 `invalid_platform|invalid_token|invalid_push_key|invalid_environment` (N §4.2).
- **`DELETE /devices/{id}/push-token?platform=fcm|apns|apns-voip`** → 204.
- **GDPR:** `DELETE /devices/{id}` (`PrivacyEndpoints.cs`) maže i `VoipPushToken`, `PushKey` a bloby zařízení. Mazání blobů je stub, implementuje M2-4. Export přidá `hasVoipPushToken`.
- **Archiv (`AuditArchiveEndpoints.cs:48`)**
  - Nové kindy v `AllowedKinds`: `edit`, `delete`, `reaction`, `group-event`, `other`.
  - Validace `details`:
    - `edit|delete|reaction` přesně podle M §4.2 (X0-M-2). Chyby 422 `invalid_ref_details` / `details_hash_mismatch`.
    - `group-event` bez `details`.
    - `other`: `{"type": string ≤ 32}`, `ContentHash == SHA-256(UTF8(details))`.
  - Opravit text chyby na `:80`.
  - Doplnit oddíl do `2026-09-18-business-mode-contracts.md`.
- **Zmrazené HTTP kontrakty.** Implementují je proudy ve vlně 1; X0 zakládá jen stuby, které vracejí 501, pokud je proud potřebuje k překladu.

| Endpoint | Tvar | Implementuje |
| --- | --- | --- |
| `GET /devices/{id}/prekeys`, `POST /devices/{id}/prekeys`, `PUT /devices/{id}/signed-prekey`, `key-bundle` + `signedPreKeyId` | S §4.2 | S2 |
| `GET /devices/{id}/identity` (bez spotřeby OPK) | G §4.4 | S2 (vlastník `DeviceEndpoints.cs`) |
| `POST /attachments…`, `GET /attachments/{blobId}…` (upload po blocích, commit, download) | M2 §4.2 a M2-3 | M2-3 |
| `POST /calls/{callId}/decline`, `GET /turn/credentials` (deviceId z JWT, 503 + `stunUrls`) | C §3 KC5 | C01, C02 |
| `GET /groups/{id}` (+ `isEmergencyChannel`, `myRole`, `memberCount`), `GET /groups/{id}/members` (+ `userHandle`, `isBot`), `DELETE …/members/{self}` (409 `last_admin`, `emergency_membership_managed`), `PATCH /groups/{id}/members/{deviceId} {role}` | G §4.4 | G1 |
| `GET /backups/limits`, 409 `backup_quota_exceeded\|backup_storage_full`, `DELETE /accounts/{id}` 403 `mfa_required`, export + `mfa`, `GET /devices/{id}/export` | D §4.1 bod 12 | D2, D5 |
| `POST /push/test` | N3 | N3 |

### 2.3 Rozhraní a stuby (překládají se, nic nedělají)

- `Services/IPushNotificationService.cs` podle N §4.3 bez hovorových metod (K5). `PushNotificationService` ho implementuje dnešním chováním. `MessengerHub` a `ChannelService` přejdou na rozhraní.
- `Services/ICallPushSender.cs` podle C §5.2 + `CallerId` (K5). Implementace v `PushNotificationService` vrací `NotConfigured`.
- Stuby hovorů podle C §5.2: `PendingCallOptions` (sekce `Calls` v `appsettings.json` s hodnotami z C), `PendingCallStore`, `PendingCallSweeper`, `Endpoints/CallEndpoints.cs`.
- Stuby příloh podle M2 §4.2:
  - `Configuration/AttachmentsOptions.cs`,
  - `Services/E2eAttachmentService.cs` (`ContainerName = "e2e-attachments"`),
  - `Services/E2eAttachmentCleanupService.cs`,
  - `Endpoints/AttachmentEndpoints.cs`,
  - rate-limit politiky `attachments` a `attachment-chunks`.
- `Program.cs`: registrace všech výše uvedených služeb.
- `ProductionConfigurationValidator`: když je nastavený kterýkoli klíč `Push:Apns:*`, musí být nastavené všechny (`TeamId`, `KeyId`, `PrivateKeyP8`, `BundleId`). Nevyplněné APNs = push vypnutý, ne chyba (stejně jako FCM).

### 2.4 Hub (`MessengerHub.cs`) před předáním proudu C

1. Tiché metody `SendQuietMessage` a `SendQuietGroupMessage` podle M §4.2 (X0-M-1): společné jádro s `push: false`.
2. `DeliverAsync`:
   - offline větev volá `IPushNotificationService.SendMessagePushAsync`,
   - online větev volá `ScheduleUnackedPushCheck` (N §4.3),
   - sekvenční čekání na FCM uvnitř volání odesílatele odstraní dispatcher od N (N1). X0 jen vytvoří rozhraní.
3. Od tohoto commitu vlastní hub **C** (vlna 1). Ve vlně 2 ho vlastní D (K14 v paralelni.md).

### 2.5 Testy X0-S

Testcontainers s reálným Postgres:
- migrace se aplikuje,
- IDOR vrací 403,
- `apns-voip` se uloží do `VoipPushToken`,
- tichá zpráva offline příjemci neposílá push (test double `IPushNotificationService` v DI, DB se nemockuje),
- nové archivní kindy fungují, včetně `other`,
- existujících 326 testů zůstává zelených.

## 3. X0-K: drátový formát (plaintext uvnitř obálky Double Ratchet)

Obálka `{v:1, id, type, body, groupId, groupName, createdAt, …}`, kde `body` je **vždy řetězec**.

- **Nové pole `ctl: true`** u všech řídicích typů (K1). Řídicí zprávy:
  - nezakládají konverzaci,
  - nezvyšují `unreadCount` ani `lastMessageAt`,
  - neemitují do `persistedMessages`.

| `type` | `ctl` | Tvar | Kam | Archivátor | Proud |
| --- | --- | --- | --- | --- | --- |
| `text`, `file`, `call-event` | — | beze změny | — | beze změny | — |
| volitelná pole obsahu: `replyTo{id, senderId, preview≤100}`, `forwarded`, `expiresInSec` (rezerva) | — | M §4.1 | — | ignoruje | M |
| `media` | — | `body` = JSON `MediaRef` podle **M2 §4.6**. Zvyšuje `unreadCount`, smí mít `replyTo`. | členové + auditor | `attachment` (velikost, hash těla, blob nestahuje) | M2 |
| `receipt` | ✔ | M §4.1 (`kind`, `ref[≤100]`) | původní odesílatel (+ auditor v business skupině, KB2) | ack bez záznamu | M |
| `reaction`, `edit`, `delete` | ✔ | M §4.1 | všichni členové + auditor | kind podle typu, `details` podle M | M |
| `profile` | ✔ | G §4.2 + rezervované `caps: [string]` (C2-1 `call-sig-v2`) | kontakty, moje skupiny (G R1) | ack bez záznamu | G |
| `group-update` | ✔ | G §4.2 | členové + auditor | `group-event` | G |
| `device-list`, `device-list-request`, `sync`, `provision` | ✔ | D §4.1 bod 6. Volitelné pole `dlv` na přímé zprávě. | nikdy do business skupin | nikdy je nedostane | D (vlna 2) |
| neznámý typ s `ctl` | ✔ | — | — | ack bez záznamu | — |
| neznámý typ bez `ctl` | — | uložit a zobrazit zástupný text (K1) | — | `other` (K2) | — |

- **Tvar `media` implementuje X0 celý:** `calltype_core/lib/attachments/media_ref.dart` s přísnou validací a testy (M2 §4.6).
- **Knihovna drátového formátu** `calltype_core/lib/messaging/control_messages.dart`: X0 založí prázdnou kostru s konstantou `ctl`, tvary a parsery doplní M01. Boti ji importují.
- **Přijímače (X0-K):**
  - aplikace: registr podle K3, deduplikace přes `InboundLog` ještě před dešifrováním, pravidla K1, háček `isBlocked`,
  - `jay_archiver`: pravidla z tabulky výše, včetně větve `media` podle M2 a kindu `other`,
  - `calltype_bot`: test tolerance.
- Každý přijímač má testy na všechny řádky tabulky.

## 4. X0-K: drift schéma v4 (`schemaVersion` 3 → 4)

| Tabulka | Změna | Proud |
| --- | --- | --- |
| `Messages` | + `replyToId`, `replyToSenderId`, `replyPreview`, `forwarded`, `editedAt`, `deletedAt`, `readAt`, `receiptSent`, `expiresAt` (rezerva)<br>+ index `(conversation_id, created_at)` | M §4.3 |
| `Messages` | + `mediaBlobId`, `mediaState`; `attachmentPath` = relativní cesta (web `idb:<klíč>`) | M2 §4.5 |
| `Messages.type` | nové hodnoty `media`, `system` (lokální, G), neznámé typy (K1). Status odchozí zprávy: `sending\|sent\|delivered\|read\|failed`. | M, M2, G |
| `Conversations` | + `mutedUntil` (navždy = `9999-12-31T00:00:00Z`), `draft`, `pinnedAt`, `archivedAt` | M |
| `Conversations` | + `leftAt`, `titleUpdatedAt` | G |
| `Contacts` | + `verifiedAt`, `identityKeyChangedAt` (`verified` zůstává a zapisují se obě hodnoty) | S, G |
| `Contacts` | + `deviceListVersion`, `deviceListRoot` | D |
| nová `Reactions`, `MessageReceipts`, `MessageRevisions`, `InboundLog`, `AppSettings` | M §4.3 | M |
| nová `AttachmentTransfers` | M2 §4.5 | M2 |
| nová `PeerProfiles`, `BlockedDevices` | G §4.1 | G |
| nová `ContactDevices` + index `contactId` | D §4.1 | D |
| nová `CallLog(callId PK, peerId?, conversationId?, direction, video, outcome, startedAt, connectedAt?, endedAt?, seenAt?)` + 2 indexy | C §5.5 | C |

**Datová migrace (povinná):**
- `receipt_sent = 'read'` a `read_at = received_at` na existujících řádcích (jinak by aplikace rozeslala potvrzení za celou historii),
- `verified_at = added_at`, kde `verified = 1`.

**Test migrace:** databáze v3 s daty → v4 beze ztráty, na nativní platformě i na webu (WASM).

## 5. X0-A: klientské stuby (překládají se a mají no-op nebo `UnimplementedError`)

| Soubor | Rozhraní | Implementuje |
| --- | --- | --- |
| `lib/features/chat/outgoing_messages.dart` | `OutgoingMessages`, `ReplyRef` (K4) | M02 |
| `lib/features/chat/active_conversation.dart` | `ActiveConversation` | M |
| `lib/features/chat/chat_extensions.dart` | `ChatExtensions`, `MessageTypeHooks`, `ComposerAction` (M §4.5); `ChatExtensions.none` v `main.dart` | M2-10 |
| `lib/features/chat/inbound/**` | registr podle K3 (X0-K ho **implementuje**, nejde jen o stub) | X0-K |
| `calltype_core/lib/devices/device_directory.dart` | `DeviceDirectory`, `DirectPayloadPlanner`, **implementace** `SingleDeviceDirectory` (D §4.1 bod 2); X0 upraví místa podle D §4.1 bodu 3 | D (vlna 2) |
| `lib/shared/identity/peer_directory.dart` + `calltype_core/lib/storage/block_list.dart` | `PeerDirectory`, `IdentityState`, `FallbackPeerDirectory`, `isDeviceBlocked(db, id)` (G §4.3 bod 3) | G3 |
| `calltype_core/lib/crypto/safety_number.dart` + API identity v `SessionManager` | signatury S (K9) | S5, S6 |
| `calltype_core/lib/attachments/media_ref.dart` | `MediaRef` (plná implementace) | X0-K |
| `lib/core/attachments/attachment_service.dart` | `AttachmentService`, `AttachmentSource`, `MediaMetadata`, `TransferProgress`, `LocalMedia`, `AttachmentException` (M2 §4.7); `UnavailableAttachmentService` v `main.dart` | M2-5 |
| `lib/features/calls/call_push_handler.dart` | `handleCallPush` (K6) | C06 |
| `lib/core/notifications/call_notifications.dart` | `CallNotifications` + `NoopCallNotifications` (K7) | N |
| `lib/features/calls/locked_call_view.dart` | `LockedCallView` (K10) | C08 |
| `lib/core/config/firebase_config.dart` + `web/firebase-config.js` | P §4 X0-P6 (dart-define klíče `FIREBASE_*`) | P3 |
| `calltype_core/lib/network/signalr_client.dart` (jen nové metody) | `sendQuietMessage`, `sendQuietGroupMessage` (M), `sendDirectFanout` (D, vlna 1 = smyčka), `claimPendingCall` (C) | X0-K |
| `calltype_core/lib/network/api_client.dart` (jen nové metody) + `prekey_dtos.dart` | `getPreKeyStatus`, `uploadOneTimePreKeys`, `updateSignedPreKey`, `deleteDevice`, `registerPushToken(platform, environment?, pushKey?)`, `deletePushToken` | X0-K; těla S, N |
| `lib/core/storage/secure_storage.dart` (jen nové metody) | backup key a salt, account email, `clearAccount`, `deleteAll` (D §4.1 bod 7) | X0-A |
| `lib/core/storage/secure_storage.dart` (iOS dostupnost klíčenky) | `first_unlock_this_device` pro `deviceId`, device secret a JWT, s migrací existujících položek (C §5.4); bez toho hovor na zamčeném iPhonu po zabití aplikace nefunguje | X0-A |
| `assets/sounds/.gitkeep` + `flutter.assets` | — | C05 |

Stuby jsou registrované v `main.dart` jako `Provider`. Vlna 1 vymění jen hodnotu.

## 6. X0-A: balíčky, identifikátory, platformy

### 6.1 Identifikátory (P1 ve vlně 0, podle R-P1/R-O1, čeká na potvrzení vlastníka)

- **Všude `cz.zcloud.jay`.**
- Android: `namespace` a `applicationId` (`build.gradle.kts:9,24`), `MainActivity.kt` se přesune do `kotlin/cz/zcloud/jay/`. Soubor pak vlastní C.
- macOS: `AppInfo.xcconfig` (bundle id, `PRODUCT_NAME = Jay`, copyright).
- Windows: `Runner.rc:92,96` (`CompanyName` a copyright ZCloud).
- iOS: `CFBundleName = Jay`, deployment target **15.0** (Podfile a 3× pbxproj; požadavek `flutter_callkit_incoming`, R-C1). `CODE_SIGN_ENTITLEMENTS`.
- `.gitignore` pro konfigurační soubory Firebase.

### 6.2 `pubspec.yaml` (verze ověřené agenty na pub.dev 2026-09-29; X0 ověří `flutter pub get` a build všech platforem na Flutteru z CI)

| Balíček | Constraint | Proud | Poznámka |
| --- | --- | --- | --- |
| `package_info_plus` | ^10.2.1 | P | |
| `msix` (dev) | ^3.18.0 | P | |
| `flutter_local_notifications` | ^22.3.1 | N | [OVĚŘIT] minimální verzi Flutteru |
| `app_badge_plus` | ^1.3.5 | N | |
| `web` | ^1.1.1 | N, M2 | |
| `flutter_callkit_incoming` | ^3.1.6 | C | android, ios; iOS 15 |
| `audioplayers` | >=6.7.1 <6.8.0 | C, M2 | K11 |
| `wakelock_plus` | >=1.7.0 <1.8.0 | C | |
| `proximity_sensor` | >=1.4.0 <2.0.0 | C | android, ios |
| `connectivity_plus` | ^7.3.1 | C | |
| `window_manager` | ^0.5.2 | C, N | desktop |
| `record` | ^7.1.1 | M2 | |
| `video_player` / `video_player_win` | ^2.14.0 / ^3.3.0 | M2 | |
| `get_thumbnail_video` | ^0.7.3 | M2 | [OVĚŘIT] build |
| `gal` | ^2.3.3 | M2 | [OVĚŘIT] C++20 na Windows |
| `image`, `cross_file`, `mime` | ^4.10.1, ^0.3.5 (ne 0.4), ^2.0.0 | M2, G | dnes jen tranzitivní |
| `screen_protector` | ^1.5.3 | S | [OVĚŘIT] build na Flutteru z CI |
| `archive` | ^4.0.0 | D | [OVĚŘIT] API gzipu na webu |
| `flutter_web_plugins` (sdk) | — | G | `usePathUrlStrategy` |
| **odebrat** `sqlite3_flutter_libs` (EOL) | — | S | [OVĚŘIT] build všech platforem; když něco selže, ponechat a zapsat |

**Vlna 2 (nepřidávat v X0):**
- `tray_manager`, `launch_at_startup` (N12),
- `hooks: user_defines: sqlite3: source: sqlite3mc` (S10),
- `url_launcher`, pokud ho P10 potřebuje.

### 6.3 Platformní soubory (jen X0; ve vlně 1 je mění jen P, a jen podpis)

**AndroidManifest:**
- Oprávnění: `USE_FULL_SCREEN_INTENT`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_PHONE_CALL`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA`, `MANAGE_OWN_CALLS`, `WAKE_LOCK`, `VIBRATE`, `BLUETOOTH_CONNECT` (C, N) a `WRITE_EXTERNAL_STORAGE maxSdkVersion=29` (M2).
- Komponenty: receiver `ActionBroadcastReceiver`, meta-data s výchozím kanálem `jay_messages` a ikonou `@drawable/ic_stat_jay` (N).
- App Links: intent-filter `autoVerify` pro `https://jay.zcloud.cz` s cestami `/c/`, `/ch/`, `/g/` (G).
- **Bezpečnost:** `allowBackup="false"`, `fullBackupContent="false"` a `dataExtractionRules` bez databáze a sharedprefs (P, S). Dnes auto-backup vynáší nešifrovanou SQLite do Google Drive.
- `MainActivity` bez statického `showWhenLocked` (C).
- Gradle: core library desugaring (N).

**iOS `Info.plist`:**
- `UIBackgroundModes` = `remote-notification`, `voip`, `audio`.
- `NSPhotoLibraryAddUsageDescription`.
- Upravené texty mikrofonu (hlasovky), kamery (fotky, QR, propojení zařízení) a Face ID.
- `ITSAppUsesNonExemptEncryption` **nepřidávat** (R-P4).

**iOS `Runner.entitlements` (nový):** `aps-environment` a `com.apple.developer.associated-domains = applinks:jay.zcloud.cz`.

**macOS:**
- `Release.entitlements` a `DebugProfile.entitlements`: `com.apple.developer.aps-environment`, případně `com.apple.security.personal-information.photos-library` [OVĚŘIT].
- Info.plist: texty ke knihovně fotek.

**iOS a macOS `Localizable.strings` pro 19 jazyků** (N9 generuje obsah, X0 přidá soubory do Xcode projektu).

**`AppDelegate.swift`:** vlastník C. X0 přidá jen delegáta `UNUserNotificationCenter` a `setPluginRegistrantCallback` pro `flutter_local_notifications` (N).

### 6.4 Prefixy ARB klíčů (každý nový klíč ve všech 19 ARB, koordinátor slučuje)

| Proud | Prefixy |
| --- | --- |
| M | `msg` |
| M2 | `media` |
| N | `notif` |
| C | `call`, `calls` |
| S | `sec` |
| D | `md` |
| P | `plat` |
| G | `profile`, `onboardingName`, `contactDetail`, `contactBlock`, `contactUnknown`, `safetyNumber`, `identityChange`, `groupInfo`, `groupMember`, `groupEvent`, `invite`, `report` |

X0 přidá jen `msgUnsupportedType` (zástupný text K1).

## 7. Kritéria přijetí X0 (brána do vlny 1)

1. Backend: všech 326 testů a nové testy X0-S jsou zelené v hosted CI (public okno se souhlasem vlastníka).
2. Testy `calltype_core`, `calltype`, `calltype_bot`, `hermes_bridge` a `jay_archiver` jsou zelené, včetně testu migrace v3 → v4 a tolerančních testů přijímačů.
3. `flutter build` projde pro web, apk, ios `--no-codesign`, macos a windows. Platí nové identifikátory a nové balíčky.
4. `test/l10n/` je zelený (ARB parita).
5. Živé E2E Business režimu (`jay_archiver/test/e2e`) proti docker compose je 2/2 a přibyl test, že zprávy typů `media` a `other` vytvoří archivní záznam.
6. **W0.5:** build X0 je nasazený na betě (API, web, archivátor, boti). Až potom se smí na betu dostat build vlny 1, který posílá nové typy (K14). Nasazení schvaluje vlastník.

## 8. Stav X0 a upřesnění z implementace (2026-09-29, závazné pro vlnu 1)

X0-S, X0-K a X0-A jsou zmergované ve větvi `claude/funny-volta-w7yl11`. Kde se implementace liší od oddílů 0–6, platí tento oddíl.

### Server (X0-S)
- **Migrace** `20260929184035_GapClosureWave1`. DB CHECK `CK_Devices_PushKey_Length`: `PushKey` je null, nebo má přesně 32 B.
- **`record CallPush(Guid CallId, Guid CallerId, bool Video, string DeclineToken, DateTimeOffset ExpiresAt)`**
  - `CallCancelReason` leží v `ICallPushSender.cs`.
  - Výsledek je `CallPushResult` (od C). `CallPushOutcome` od N nevznikl.
  - Obě rozhraní implementuje jeden singleton `PushNotificationService`.
- **Validátor APNs:** kontrolu zapíná jen `TeamId`, `KeyId` nebo `PrivateKeyP8`. Samotné `BundleId` ne, protože ho N nastaví jako výchozí hodnotu. Pak musí být vyplněné všechny čtyři klíče.
- **`push-token`**
  - Token má max. 512 znaků. `apns-voip` token nad 200 znaků vrací 400 `invalid_token`.
  - Když se `pushKey` neuvede, zůstane uložený původní klíč.
  - `DELETE` s `fcm|apns` smaže jen odpovídající slot (když sedí `PushPlatform`, nebo je null).
- **Archiv**
  - Nový chybový kód 422 `invalid_other_details`.
  - U `edit|delete|reaction` musí být `ref` UUID v kanonickém tvaru „D“ malými písmeny.
  - `details` se serializují deterministicky: klíče v pořadí z kontraktu, bez mezer.
- **Endpointy:** stub endpointy 501 nevznikly, ke kompilaci je nic nepotřebuje. `MapCallEndpoints` a `MapAttachmentEndpoints` zatím jen vracejí `app`.
- **Přílohy:** `E2eAttachmentService` má skutečné tělo jen u `MarkDeviceAttachmentsForDeletionAsync`. Zbytek (upload, commit, download, delete) doplní M2-3.
- **Opcí `PendingCallOptions`** se váží přes `AddOptions().Configure<IConfiguration>`.

### Jádro a přijímače (X0-K)
- **`HubTransport.invoke`** vrací `Future<Object?>` kvůli návratové hodnotě `ClaimPendingCall`.
- **Datové třídy drift:** `CallLogEntry`, `InboundLogEntry`. Konstanta `mutedForever` je v `database.dart`.
- **Přijímač**
  - `isBlocked` má typ `FutureOr<bool> Function(String)`. Výchozí implementace čte tabulku `BlockedDevices`: zprávu dešifruje, potvrdí a zahodí.
  - `FormatException` v handleru vrátí jen změny toho handleru (savepoint). Zpráva se zapíše do `InboundLog` a potvrdí.
  - **Přijatá zpráva typu `system` se zahodí**: potvrdí se, ale neuloží. `system` vzniká jen lokálně, jinak by šlo podvrhnout skupinové nebo identitní události.
- **Stuby**
  - `OutgoingMessages` existuje jen jako `UnimplementedOutgoingMessages`. Odesílací cestu z `ChatController` vytáhne M02.
  - Tělo API identity v `SessionManager` hází `UnimplementedError`. Samotné `IdentityChangedException` (podtřída `StateError`) se už vyhazuje.
  - `KeyManager.ownPartyIdentity` a testovací vektory dodá S.
- **Archivátor:** chybně formovaný `media` se neemituje ani nepotvrdí (M2 R4). Jeden člen tím může vyvolat `auditor_unavailable`. Stejné riziko už existuje u `call-event` a je zapsané jako riziko pro M09/M2.
- **Nenahráno:** test migrace v3 → v4 na webu (WASM) nedoběhl, v prostředí chybí Chrome. SQL je na obou platformách stejné.

### Aplikace a platformy (X0-A)
- **`record: ^6.2.1`** a **`video_player: ">=2.11.1 <2.12.0"`** místo verzí z §6.2. Novější verze vyžadují Flutter 3.44 / Dart 3.12, CI běží na 3.41. M2 píše proti API `record` 6.x.
- **`sqlite3_flutter_libs`** už není přímá závislost. Tranzitivně zůstává jako prázdný balíček, nativní knihovnu dodávají hooks balíčku `sqlite3` 3.x. Komentář v `lib/core/storage/database.dart` je zastaralý a opraví ho S10.
- **macOS minimum je 11.0** (dřív 10.15), kvůli `gal`. `macos/Podfile` je commitnutý.
- **macOS `aps-environment` se nepřidal.** Bez provisioning profilu by ad-hoc CI build selhal. Přesouvá se do P6 k podpisu Developer ID.
- **Klíčenka iOS:** `first_unlock_this_device` platí pro **všechny** položky. Migrace běží v `main()` a je odolná proti pádu uprostřed. Na zamčeném telefonu `read` vyhodí výjimku místo null, aby se znovu nespustil onboarding. Klíče nepřejdou zálohou iCloud na nový iPhone (`_this_device`).
- **Firebase:** `FirebaseConfig.initializeIfConfigured()` inicializuje Firebase jen při nastavených `FIREBASE_*` dart-define. Dnešní buildy se chovají beze změny.
- **Nativní stuby:** `CallWindowChannel.kt` (stub) a jeho registrace v `MainActivity`.
- **Manifest:** `app_badge_plus` a `flutter_callkit_incoming` si přes manifest merger přinesou další oprávnění (odznaky launcherů, `DISABLE_KEYGUARD`, `TURN_SCREEN_ON`, `ACCESS_NOTIFICATION_POLICY`). Zkontrolovat v P4 spolu s R8 keep pravidly.
- **`Localizable.strings`:** do obou pbxproj přidá N9 spolu s P.

### Koordinátor
- Stuby z X0-K jsou zapojené v `main.dart` a `router.dart`.
- `PeerDirectory` jde přes `ListenableProvider`.
- `ComposerAction.onInvoke` má typ `ReplyRef?`.
