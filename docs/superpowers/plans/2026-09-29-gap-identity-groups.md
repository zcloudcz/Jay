# Proud G — Kontakty, skupiny, profil, ověření identity, pozvánky (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů (sekce 3) a kontrakty X0 (sekce 4, finální znění v `2026-09-29-gap-contracts.md`). Nic nenasazuj, audit DB nikdy nepouštěj proti betě.

**Goal:** Z Jay udělat messenger, ve kterém má člověk jméno a tvář (profil), spravuje si kontakty (přezdívka, smazání, blokování), umí si ověřit, že mluví se správným zařízením (bezpečnostní čísla, QR, řízená změna klíče), spravuje skupiny (členové, role, přejmenování, opuštění) a zve lidi odkazem, který otevře aplikaci na všech platformách. Anonymní model zůstává: nic z toho neposílá server v plaintextu a nic nevyžaduje telefonní číslo ani e-mail.

**Architecture:** Profil a změny skupin jsou nové **řídicí typy E2E zpráv** (`profile`, `group-update`), které jdou stejnou Double Ratchet cestou jako chat. Příjem řeší registr handlerů v inboxu (kontrakt X0), odesílání rozhraní `ControlMessageSender` (kontrakt X0, implementuje M). Pravdou o členství zůstává server (`GroupMembers`); E2E oznámení jen informuje a klient ho proti serveru ověřuje. Ověření identity staví nad TOFU pinem v `SessionManager` (vlastní S); G dodává UI, uložení stavu a politiku. Pozvánky jsou HTTPS odkazy na `https://jay.zcloud.cz` (App Links / Universal Links / webový klient).

**Tech Stack:** Flutter/Provider/drift (schema v4 z X0), `calltype_core` (pure Dart), ASP.NET Core minimal API + EF Core (bez nové migrace ve vlně 1), Testcontainers, `mobile_scanner`, `qr_flutter`, `share_plus`, `image_picker`, nový `image` (X0).

Stav kódu: `master` @ `91a80ee` (2026-09-29). Cesty aplikace jsou relativní k `src/client/calltype/`, pokud nezačínají `src/`.

---

## 0. Co dnes platí (ověřeno v kódu)

| Oblast | Stav | Důkaz |
| --- | --- | --- |
| Kontakty — data | `Contacts(deviceId, userHandle, displayName?, identityKey, verified, addedAt, isBot)`; `displayName` nikdo nezapisuje, `verified` nikdy není `true` | `src/client/calltype_core/lib/storage/tables.dart:10-37`; jediný zápis `verified` je `false` v `lib/features/backup/backup_import.dart:35` |
| Kontakty — přidání | Placeholder `identityKey = Uint8List(0)`, klíč se připne až při první session | `lib/features/contacts/contacts_controller.dart:118-128` |
| Kontakty — neznámý odesílatel | Komentář tvrdí „auto-create“, inbox ale vytvoří jen konverzaci, ne kontakt → titulek chatu je UUID | `contacts_controller.dart:14`, `lib/features/chat/message_inbox_service.dart:111-125`, `lib/features/chat/chat_screen.dart:206-210` |
| Jméno odesílatele ve skupině | Syrové UUID | `chat_screen.dart:355-356` |
| Avatar | Jen `LetterAvatar` (písmeno + barva) | `lib/shared/widgets/avatar.dart:8-60` |
| Profil | Neexistuje; handle `CT-XXXX-XXXX` je jediná identita | — |
| TOFU pin | `BackupState['peer_identity:<peer>'] = '<identityKey>|<signingKey>'`, při neshodě `StateError('Contact identity changed…')` | `src/client/calltype_core/lib/crypto/session_manager.dart:381-403`, `:405-427` |
| Kde změna vyskočí | odchozí `initiateSession` (`:98`) i příchozí pre-key zpráva (`:294`); inbox výjimku jen pošle do `errors` a zprávu **nepotvrdí** → zůstává ve frontě serveru a zkouší se při každém připojení | `message_inbox_service.dart:163-166` |
| Může se klíč legitimně změnit? | **Ne pro stejné `deviceId`.** Server přidělí nové `DeviceId` při každé registraci a žádný endpoint `IdentityKey` nemění | `src/server/CallType.Api/Endpoints/DeviceEndpoints.cs:111`, trasy `:31-39`, `Models/Device.cs:22-26` |
| Podepsaný bundle | `identityKey` (X25519) + `signingKey` (Ed25519) + `signedPreKey` + `signature` | `calltype_core/lib/crypto/key_manager.dart:34-56`, ověření `:67-93` |
| Lookup handle | `GET /devices/by-handle/{handle}` → `{deviceId, userHandle, isBot}`, bez klíčů | `DeviceEndpoints.cs:245-253` |
| Skupiny — server | `POST /groups`, `POST /groups/business`, `GET /groups/{id}`, `GET/PUT /groups/{id}/members`, `DELETE /groups/{id}/members/{deviceId}`; limit 100; add/remove jen admin; auditor 409 `auditor_immutable`; poslední admin 409 | `Endpoints/GroupEndpoints.cs:16-21`, `:34`, `:83-91`, `:136`, `:176-179` |
| Skupiny — člen nemůže odejít | `RemoveMember` vyžaduje admina i pro sebe | `GroupEndpoints.cs:170` |
| Skupiny — role | Endpoint na změnu role neexistuje | `GroupEndpoints.cs:16-21` |
| Skupiny — název | Klient posílá `name` do `POST /groups`, server ho ignoruje (`CreateGroupRequest` ho nemá); název cestuje jen v každé zprávě jako `groupName` a použije se jen při založení konverzace u příjemce | `calltype_core/lib/network/api_client.dart:96-100`, `GroupEndpoints.cs:186`, `lib/features/chat/chat_controller.dart:250`, `message_inbox_service.dart:114-125` |
| Skupiny — klient | Jen vytvořit | `lib/features/groups/group_controller.dart:15-16`, `:70-128` |
| Skupiny — jak se ostatní dozví o změně členství | **Nijak.** Odesílatel si před každým odesláním stáhne `GET /groups/{id}/members` (`chat_controller.dart:236-240`), takže nový člen dostává zprávy od další zprávy, odebraný přestane. Nikdo nedostane oznámení, přejmenování neexistuje | — |
| Hub — fan-out | Příjemci musí být **aktuální** členové, jinak `HubException("Sender and recipients must be group members")`; business skupina musí obsahovat auditora (KB2); payload ≤ 768 KiB na příjemce, celá zpráva ≤ 1 MiB | `Hubs/MessengerHub.cs:111-146`, `:192-193`, `Program.cs:313` |
| Nouzový kanál | Skupina `IsEmergencyChannel` s auditorem a členy `member`, **bez admina** | `Services/EmergencyGroupService.cs:21-67` |
| Business — odvolání z org | Odebere člena ze všech skupin org kromě auditora | `Services/BusinessGroupService.cs:98-102` |
| Archivátor | Whitelist typů `text|file|call-event`, jinak výjimka; server whitelist `kind` = `text, attachment, call, call-metadata` | `src/bots/jay_archiver/lib/src/group_message_source.dart:154`, `Endpoints/AuditArchiveEndpoints.cs:48` |
| Odkazy | Generuje se `ct://{deviceId}/{handle}` (onboarding, identita); parsuje se navíc `calltype://contact/{handle}` (nikdo ho negeneruje); v OS registrované jen `calltype://channel` | `lib/features/onboarding/onboarding_controller.dart:61-64`, `lib/features/settings/identity_screen.dart:31`, `lib/features/contacts/qr_scanner_screen.dart:107-131`, `android/app/src/main/AndroidManifest.xml:42-47`, `ios/Runner/Info.plist:104-111` |
| Web a doména | `https://jay.zcloud.cz` je **Flutter web** na SWA (`flutter build web` → `build/web`), ne `www/` (to je prezentační web, deploy ho nenasazuje). Web používá výchozí **hash** URL strategii (žádné `usePathUrlStrategy`) | `.github/workflows/deploy.yml:221-222`, `:383`; `www/README.md`; `web/staticwebapp.config.json` |
| Hlášení | Jen pro kanály (`ChannelReport`, 5/den/zařízení) | `Models/ChannelReport.cs`, `Services/ChannelService.cs:69` |

## 1. Cíl a rozsah

| # | Oblast | Priorita | Vlna | Balíček |
| --- | --- | --- | --- | --- |
| 1 | Server skupin: opuštění, role, detaily členů, příznak nouzového kanálu | P1 | 1 | G1 |
| 2 | Klientské API skupin + identity lookup (core) | P1 | 1 | G2 |
| 3 | Adresář lidí: jméno k zobrazení, avatar, blokace, stav identity (jedna služba pro M/C/N) | P1 | 1 | G3 |
| 4 | Profil: jméno, avatar, „o mně“, krok v onboardingu, E2E distribuce | P1 | 1 | G4 |
| 5 | Kontakty: detail, přezdívka, smazání, blokování, lišta „neznámý odesílatel“ | P1 | 1 | G5 |
| 6 | Ověření identity: bezpečnostní čísla, QR, `verifiedAt`, řízená změna klíče | P1 | 1 | G6 |
| 7 | Skupiny v UI: info, členové, přidat/odebrat, role, přejmenovat, opustit, systémové řádky | P1 | 1 | G7 |
| 8 | Pozvánky a deep linky: `https://jay.zcloud.cz/c/…`, App/Universal Links, sdílení | P1 (App/Universal Links na zařízení blokuje podpis — P) | 1 | G8 |
| 9 | Pozvánka do skupiny odkazem | P2 | 2 | G9 |
| 10 | Nahlášení spamu (serverový endpoint, metadata + přeposlání se souhlasem) | P2 | 2 | G10 |
| 11 | Share-to-app (příjem sdíleného obsahu) + deep linky na desktopu | P2 | 2 | G11 |
| 12 | Auditní událost (KB6) při změně členství business skupiny | P2 | 2 | G12 |

**Mimo rozsah:** synchronizace kontaktů mezi zařízeními účtu (D), záloha nových tabulek (D — jen požadavek, sekce 5), skupinové hovory (C2), Sender Keys/MLS, serverová blokace (viz R5), „online/naposledy viděn“, sloučení kontaktu po přeinstalaci (nové `deviceId` = nový kontakt, viz riziko 8.3).

## 2. Rozhodnutí k potvrzení vlastníkem

- **[ROZHODNUTÍ] R1 — komu se posílá profil.** Doporučeno: jméno a avatar dostane (a) každý, komu **já** pošlu 1:1 zprávu (tím je pokryt první kontakt i odpověď cizímu), (b) všechny skupiny, kde jsem členem. Cizí člověk, který mi jen napíše, moje jméno nevidí, dokud mu neodpovím. Přepínač „Sdílet jméno a fotku“ (výchozí zapnuto, pokud je jméno vyplněné). *Jiná volba:* jen uloženým kontaktům. Pak členové skupin, kteří nejsou v kontaktech, uvidí dál jen handle. To je přesně dnešní problém s UUID ve skupině.
- **[ROZHODNUTÍ] R2 — pořadí jména.** Doporučeno: moje přezdívka (`Contacts.displayName`) → profilové jméno (`PeerProfiles.displayName`, u neuloženého kontaktu s prefixem `~`, jako WhatsApp) → handle → zkrácené `deviceId`. Handle je v detailu a v náhledu přidání **vždy** vidět (obrana proti vydávání se za někoho jiného). *Jiná volba:* profilové jméno přednostně. Pak by si kdokoli mohl „přejmenovat“ můj kontakt.
- **[ROZHODNUTÍ] R3 — politika změny klíče.** Doporučeno: **nikdy nepřijímat automaticky.** V Jay se klíč pro stejné `deviceId` legitimně změnit nemůže (sekce 0), takže změna znamená chybu serveru nebo útok. Neověřený kontakt: banner v chatu, přijetí na jedno ťuknutí s potvrzovacím dialogem. Ověřený kontakt: přijetí jen přes obrazovku bezpečnostního čísla a ověření se ztratí. Zprávy čekají nepotvrzené ve frontě serveru (max. 30 dní) a po přijetí se doručí. *Jiná volba (Signal):* u neověřených přijmout automaticky s oznámením. Je pohodlnější, ale v Jay by tiše spolkla jediný reálný signál MITM.
- **[ROZHODNUTÍ] R4 — skupina, kde má člen nepřijatou změnu klíče.** Doporučeno: pokud byl člen před změnou ověřený → odesílání do skupiny blokovat, dokud se změna nevyřeší. Neověřený člen → vynechat ho z fan-outu a do chatu vložit řádek „Zpráva nebyla doručena: X (změna bezpečnostního kódu)“. Auditor s nepřijatou změnou → blokovat vždy (KB2). *Jiná volba:* vždy blokovat celou skupinu. Je to bezpečnější, ale jeden člen by zastavil skupinu o 100 lidech. Dnes celou skupinu zastaví výjimka v `GroupCipher.encryptForGroup` (`calltype_core/lib/crypto/group_cipher.dart:27-31`).
- **[ROZHODNUTÍ] R5 — blokování jen na klientovi.** Doporučeno: ano, ve vlně 1 bez serverové blokace. Server by se tím dozvěděl nový vztah „A blokuje B“, což je metadata, která dnes nemá. Blokovaný dál posílá a zprávy se u mě dešifrují a zahodí (kvůli synchronizaci ratchetu), bez notifikace a bez vyzvánění. Blokovaný nic nepozná. 1:1 zprávy se zahodí, ve skupinách se zobrazí normálně (jako WhatsApp). Sbalení se nechává na P2. *Jiná volba:* `POST /devices/me/blocks`, který server použije k zahození fronty a pushů (šetří baterii při spamu). Přehodnotit s G10, pokud se objeví spam.
- **[ROZHODNUTÍ] R6 — poslední admin opouští skupinu.** Doporučeno: server vrátí 409 `last_admin`, jen pokud ve skupině zůstávají jiní lidé (mimo auditora). Klient pak nabídne výběr nového admina (`PATCH` role) a potom odejde. Jediný člověk ve skupině odejít může. *Jiná volba:* automaticky povýšit nejstaršího člena. Je to méně kroků, ale uživatel neurčí, kdo skupinu převezme. Obě varianty mění očekávání existujícího testu `Admin_can_add_and_remove_members_but_not_last_admin` (`src/server/CallType.Api.Tests/Endpoints/GroupEndpointsTests.cs:65-74`), kde osamělý admin dnes dostane 409.
- **[ROZHODNUTÍ] R7 — kdo přejmenuje skupinu.** Doporučeno: jen admin, protože server role zná a příjemce to ověří. *Jiná volba:* kdokoli (výchozí u WhatsApp). V business skupinách nevhodné.
- **[ROZHODNUTÍ] R8 — tvar odkazů.** Doporučeno:
  - kanonický odkaz `https://jay.zcloud.cz/c/{handle}?d={deviceId}&f={fingerprint}`, parametry v **query**, ne ve fragmentu (spolehlivě projdou App Links, Universal Links i webovým routerem; nejsou tajné);
  - kanály `https://jay.zcloud.cz/ch/{handle}`, skupiny (P2) `https://jay.zcloud.cz/g/{token}`;
  - staré `ct://` a `calltype://…` se dál **parsují** (už vytištěné QR kódy), ale nové se negenerují;
  - schéma `ct://` se v OS **neregistruje**, protože je krátké a kolizní;
  - web přejde na `usePathUrlStrategy()`: URL `/#/chats` → `/chats`, a bez toho by webový klient cestu `/c/…` ignoroval. Staré záložky `/#/…` skončí na `/chats`.

  *Jiná volba:* ponechat hash strategii a převádět `Uri.base` na počáteční routu ručně v `main.dart`. Je to křehčí.
- **[ROZHODNUTÍ] R9 — nahlášení spamu.** Doporučeno: P2, entita `DeviceReport` ve **vlně 2** (migrace vlny 2), žádná změna X0 migrace. *Jiná volba:* přidat entitu už do X0. Je to levné, ale bez provozního procesu, kdo hlášení čte, nemá smysl.
- **[ROZHODNUTÍ] R10 — nouzový kanál a business skupiny.** Doporučeno: z nouzového kanálu nelze odejít (409 `emergency_membership_managed`, členství řídí organizace přes enrollment). Z běžné business skupiny odejít lze a auditor zůstává. *Jiná volba:* zakázat odchod i z business skupin. Členství ale už dnes mění odvolání z organizace, takže zákaz by nic nechránil.
- **[ROZHODNUTÍ] R11 — jméno v onboardingu.** Doporučeno: volitelné pole na obrazovce po registraci s nápisem „Uvidí ho jen lidé, kterým napíšete“. Tlačítko „Přeskočit“ je rovnocenné. Nic se neposílá na server. *Jiná volba:* bez onboardingového kroku, jen v Nastavení.
- **[ROZHODNUTÍ] R12 — audit změn členství business skupin (KB6).** Dnes `PUT/DELETE /groups/{id}/members` u business skupin nezapisuje `AdminAuditEvent`. Doporučeno: P2 (G12). Zápis běží až po commitu Delivery DB. Při selhání se zaloguje Error s `groupId`, protože mezi dvěma databázemi není distribuovaná transakce. *Jiná volba:* zapsat do audit DB **před** změnou členství. Pak při selhání druhého kroku zůstane v append-only archivu nepravdivý záznam.

## 3. Vlastnictví souborů

**Výhradně G (vlna 1):**
- `lib/features/contacts/**` (včetně `qr_scanner_screen.dart`), `lib/features/groups/**`, `lib/features/profile/**` (nový), `lib/features/onboarding/**`
- `lib/features/settings/identity_screen.dart` (**požadavek na koordinátora** — v tabulce proudů nikomu nepatří, G ho přestaví na „Moje pozvánka“)
- `lib/shared/widgets/avatar.dart`, `lib/shared/identity/**` (nový; implementace `PeerDirectory`, rozhraní vytvoří X0)
- `src/client/calltype_core/lib/network/group_api.dart`, `group_dtos.dart`, `device_identity_api.dart` (nové)
- `src/client/calltype_core/lib/links/invite_link.dart` (nový, čistá funkce, sdílená s boty)
- `src/client/calltype/web/.well-known/**` (nový). **Oprava tabulky proudů:** `www/.well-known/**` je špatně, `www/` se nenasazuje (sekce 0). G nesahá do `www/`.
- `src/server/CallType.Api/Endpoints/GroupEndpoints.cs`, `src/server/CallType.Api.Tests/Endpoints/GroupEndpointsTests.cs`, nový `src/server/CallType.Api.Tests/Endpoints/GroupMembershipManagementTests.cs`
- testy: `test/features/{contacts,groups,profile,onboarding}/**`, `test/shared/identity/**`, `test/web/well_known_test.dart`, `calltype_core/test/network/group_api_test.dart`, `calltype_core/test/links/invite_link_test.dart`

**Jen připisuje (horké soubory):**
- `lib/app/router.dart` — nové routy (sekce G8) a jeden blok v `redirect` (odložený deep link)
- `lib/main.dart` — provider `PeerDirectoryService`, registrace handlerů `profile` a `group-update`, `usePathUrlStrategy()`
- `lib/features/settings/settings_screen.dart` — položky „Profil“ a „Blokované kontakty“
- `lib/l10n/app_*.arb` — jen klíče s prefixy G (níže), vždy všech 19 jazyků
- `src/client/calltype/web/staticwebapp.config.json` — `routes` pro `/.well-known/*` a rozšíření `exclude` (jen připisovat; N zde může přidat service worker)
- `src/client/calltype_core/lib/network/channel_dtos.dart` — **jen** rozšíření `parseChannelLink` o `https://jay.zcloud.cz/ch/{handle}` (kanály ve vlně 1 nikdo nevlastní; koordinátor potvrdí)
- `lib/features/channels/channel_profile_screen.dart:107` — jediný řádek: sdílet HTTPS odkaz místo `calltype://channel/` (stejná podmínka)
- `src/client/calltype_core/lib/network/api_client.dart` — **nic**; G přidává metody přes `extension` v nových souborech jako `organization_api.dart:9`

**Prefixy ARB klíčů G (výhradní):** `profile*`, `onboardingName*`, `contactDetail*`, `contactBlock*`, `contactUnknown*`, `safetyNumber*`, `identityChange*`, `groupInfo*`, `groupMember*`, `groupEvent*`, `invite*`, `report*` (P2). Existující klíče `contacts*`/`group*`/`identity*` G nemění. Nahrazený text, například hint `contactsHandleOrInviteLabel` „CT-XXXX-XXXX or ct://…“, dostane nový klíč `inviteHandleOrLinkHint` a starý přestane být používán. Smazání nepoužívaných klíčů udělá koordinátor při merge.

**Jen čte:** `session_manager.dart`, `key_manager.dart`, `group_cipher.dart` (S), `message_inbox_service.dart`, `chat_controller.dart`, `chat_screen.dart`, `chat_list/**` (M), `webrtc_manager.dart` (C), `features/organization/**`, `features/backup/**` (D), `MessengerHub.cs`, `DeviceEndpoints.cs`.

## 4. Požadavky na X0 (kontrakty)

### 4.1 Klientská schema v4 (`calltype_core/lib/storage/tables.dart`, `database.dart`)

G navrhuje **změnu** předběžného kontraktu (b). Sloupce `blocked`, `profileName`, `avatarPath` a `profileVersion` **ne**patří do `Contacts`. Důvody:
- profil přichází i od lidí, které nemám v kontaktech (členové skupin);
- blokovat jde i cizího odesílatele;
- smazání kontaktu nesmí zrušit blokaci.

Stejný vzor už používá `BlockedChannels` (`tables.dart:213-225`).

```dart
// Contacts — PŘIDAT (ponechat `verified`; zapisovat oba, dokud D nepřevede zálohu)
DateTimeColumn get verifiedAt => dateTime().nullable()();          // kdy jsem ověřil (null = neověřeno)
DateTimeColumn get identityKeyChangedAt => dateTime().nullable()(); // nepřijatá změna klíče (null = žádná)

// Conversations — PŘIDAT
DateTimeColumn get leftAt => dateTime().nullable()();         // už nejsem člen skupiny (odešel/odebrán) → skrýt composer
DateTimeColumn get titleUpdatedAt => dateTime().nullable()(); // LWW pro přejmenování skupiny (čas odesílatele)

// NOVÁ tabulka — profily deklarované protějškem (a můj vlastní pod mým deviceId)
class PeerProfiles extends Table {
  TextColumn get deviceId => text()();
  TextColumn get displayName => text().nullable()();   // ≤ 40 znaků, bez řídicích a bidi-override znaků
  TextColumn get about => text().nullable()();         // ≤ 140 znaků
  BlobColumn get avatarThumb => blob().nullable()();   // JPEG 48×48, ≤ 2 KiB (přijde inline)
  BlobColumn get avatarImage => blob().nullable()();   // JPEG 256×256, ≤ 64 KiB (stažený blob; blob i na webu — žádný souborový systém)
  TextColumn get avatarRef => text().nullable()();     // JSON MediaRef (kontrakt M2); u mého řádku poslední nahraný
  DateTimeColumn get avatarUploadedAt => dateTime().nullable()(); // jen můj řádek — re-upload po TTL/2
  IntColumn get version => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();        // deklarovaný odesílatelem
  DateTimeColumn get receivedAt => dateTime().nullable()();
  @override Set<Column> get primaryKey => {deviceId};
}

// NOVÁ tabulka — blokovaná zařízení (nezávislá na Contacts)
class BlockedDevices extends Table {
  TextColumn get deviceId => text()();
  TextColumn get userHandle => text().nullable()();
  DateTimeColumn get blockedAt => dateTime()();
  @override Set<Column> get primaryKey => {deviceId};
}
```

Migrace `from < 4`:
- `addColumn` ×4 (výše);
- `createTable(peerProfiles)`, `createTable(blockedDevices)`;
- `UPDATE contacts SET verified_at = added_at WHERE verified = 1` (dnes nulový počet řádků, jen pro korektnost).

Test migrace 3→4 do `calltype_core/test/storage/` (vlastní X0).

`Messages.type` získá hodnotu `'system'` (bez změny schématu, jen komentář v `tables.dart:98-99`). `body` = JSON:

```json
{"event":"member-added|member-removed|member-left|renamed|role-changed|removed-me|identity-changed|identity-accepted|delivery-skipped",
 "actor":"<deviceId>","targets":["<deviceId>"],"name":"<nový název>|null","role":"admin|member|null"}
```

Systémový řádek nezvyšuje `unreadCount` a nespouští notifikaci.

Klíče `BackupState`, které G používá (bez změny schématu, stejný vzor jako `peer_identity:` a `outbox:`):
- `profile:settings` = `{"share":true}`;
- `profile_sent:<deviceId>` a `profile_sent:group:<groupId>` = verze jako text;
- `pending_identity:<deviceId>` = `{"bundle":{…},"detectedAt":"…","source":"incoming|outgoing|add"}`;
- `pending_control:<messageId>` = serializovaná řídicí zpráva čekající na ověření proti serveru.

### 4.2 Nové typy zpráv (plaintext uvnitř obálky, kontrakt a)

Obě zprávy mají `body` jako **JSON řetězec**, protože inbox dnes vyžaduje `body is String` (`message_inbox_service.dart:95-98`).

```jsonc
// profile — 1:1 (groupId chybí) nebo fan-out do skupiny
{"v":1,"id":"<uuid>","type":"profile","createdAt":"…Z",
 "body":"{\"displayName\":\"Martin\"|null,\"about\":\"…\"|null,
          \"avatar\":{MediaRef}|null,\"avatarThumb\":\"<base64 JPEG ≤2 KiB>\"|null,
          \"version\":3,\"updatedAt\":\"…Z\"}"}

// group-update — vždy s groupId (fan-out), výjimka: oznámení odebranému (1:1, groupId v body)
{"v":1,"id":"<uuid>","type":"group-update","groupId":"<gid>","createdAt":"…Z",
 "body":"{\"op\":\"add|remove|leave|role|rename\",\"groupId\":\"<gid>\",
          \"members\":[\"<deviceId>\"],\"role\":\"admin|member\"|null,
          \"name\":\"…\"|null,\"nameUpdatedAt\":\"…Z\"|null}"}
```

Pravidla, která musí X0 zapsat do kontraktu:
- **Řídicí typy nevytvářejí konverzaci ani řádek `Messages`**. Inbox je předá handleru **před** automatickým založením konverzace (`message_inbox_service.dart:111-125`).
- Business skupina: `profile` i `group-update` jdou fan-outem **včetně auditora** (KB2). `jay_archiver`:
  - `group-update` → archivovat jako nový `kind = "group-event"` (jen metadata; `details = null`);
  - `profile` → potvrdit a ignorovat (není obsahem konverzace).

  X0 přidá `"group-event"` do `AllowedKinds` (`AuditArchiveEndpoints.cs:48`) a upraví text chyby (`:80`).
- `calltype_bot`: oba typy potvrdit a ignorovat (výchozí chování „neznámý typ“).

### 4.3 Rozhraní, která X0 vytvoří (stuby), aby G/M/C/N běželi paralelně

1. **Registr řídicích handlerů v inboxu** (implementuje X0 při přepisu tolerance neznámých typů):
   ```dart
   // calltype_core/lib/messaging/control_message.dart
   class IncomingControlMessage {
     final String messageId, senderId, type, body; final String? groupId;
     final DateTime createdAt; final Map<String, dynamic> payload; }
   typedef ControlMessageHandler = Future<void> Function(IncomingControlMessage m);
   // MessageInboxService:
   void registerControlHandler(String type, ControlMessageHandler handler);
   ```
   Handler běží **uvnitř** transakce inboxu po dešifrování. Když selže, transakce se vrátí, zpráva zůstane nepotvrzená a přijde znovu. Handler nesmí volat síť. G proto síťové ověření odkládá přes `pending_control:`.
2. **Odesílání řídicích zpráv** (rozhraní X0, implementace M nad stejnou outbox logikou jako chat, `chat_controller.dart:217-326`):
   ```dart
   // calltype_core/lib/messaging/control_message.dart
   abstract interface class ControlMessageSender {
     /// Direct: groupId == null && recipientDeviceId != null.
     /// Group: groupId != null → příjemci = aktuální členové ze serveru minus já (auditor vždy — KB2),
     ///        volitelně omezeno na [onlyRecipients] (musí být podmnožinou členů).
     /// durable: true → uloží se do outboxu (`outbox:<id>`) a opakuje se; false → jeden pokus, chyba se vyhodí.
     Future<String> sendControl({required String type, required String body,
       String? groupId, String? recipientDeviceId, List<String>? onlyRecipients,
       bool durable = true});
   }
   ```
3. **`PeerDirectory`** (rozhraní X0 v `lib/shared/identity/peer_directory.dart`, implementace G v G3; X0 dodá i `FallbackPeerDirectory`):
   ```dart
   enum IdentityState { unverified, verified, changedUnverified, changedVerified }
   abstract class PeerDirectory implements Listenable {
     String displayName(String deviceId);      // pořadí dle R2
     String? handle(String deviceId);
     Uint8List? avatarThumb(String deviceId);
     Uint8List? avatarImage(String deviceId);
     bool isContact(String deviceId);
     bool isBlocked(String deviceId);
     IdentityState identityState(String deviceId);
   }
   ```
   Pro izolát notifikací (N) navíc čistá funkce v core: `Future<bool> isDeviceBlocked(AppDatabase db, String deviceId)` (`calltype_core/lib/storage/block_list.dart`, X0).
4. **Stub `safety_number.dart`** (signatury níže, těla `UnimplementedError`, implementuje S):
   ```dart
   // calltype_core/lib/crypto/safety_number.dart
   class PeerIdentityKeys { const PeerIdentityKeys({required this.deviceId, required this.identityKey, required this.signingKey}); // base64
     final String deviceId, identityKey, signingKey; }
   class IdentityFingerprint {
     /// base64url(SHA-256('CallType-IdentityFingerprint-v1' || ik || sk)), 43 znaků bez '='.
     static Future<String> of(String identityKey, String signingKey); }
   class SafetyNumber {
     static Future<SafetyNumber> compute({required PeerIdentityKeys local, required PeerIdentityKeys remote});
     String get digits;          // přesně 60 číslic, stejné na obou stranách
     List<String> get groups;    // 12 × 5
     String get qrPayload;       // 'JAYSN1:' + base64url(...) — formát určí S
     bool matchesScanned(String payload); // true = protějšek ukazuje totéž číslo; FormatException pro cizí QR
   }
   ```
   Doporučení pro S: algoritmus jako Signal. Pro každou stranu `SHA-512` iterovaně 5200× nad `version || 'CallType-SafetyNumber-v1' || ik || sk || utf8(deviceId)`. Z prvních 30 B vznikne 6 × (uint40 mod 100000). Obě 30místné poloviny se seřadí lexikograficky. Nový doménový řetězec `CallType-*` nic existujícího nerozbije. Aktualizaci `docs/security/crypto-baseline.md` dělá S.
5. **Stub API identity v `SessionManager`** (signatury X0, implementuje S). Požadavky G na S:
   ```dart
   class IdentityChangedException extends StateError {   // dědí StateError → stávající catch/contains dál fungují
     IdentityChangedException({required this.peerDeviceId, required this.pinnedFingerprint,
       required this.offeredFingerprint, required this.offeredBundle, required this.source})
       : super('Contact identity changed. Verify the contact before starting a new session.');
     final String peerDeviceId, pinnedFingerprint, offeredFingerprint;
     final Map<String, dynamic> offeredBundle;           // podepsaný bundle protějšku
     final IdentityChangeSource source; }                // incoming | outgoing | expectedMismatch
   enum IdentityChangeSource { incoming, outgoing, expectedMismatch }
   // SessionManager:
   Stream<IdentityChangedException> get identityChanges; // broadcast; emit PŘED vyhozením výjimky
   Future<PinnedIdentity?> pinnedIdentity(String peerDeviceId); // {identityKey, signingKey, fingerprint}
   Future<void> pinIdentity(String peerDeviceId, Map<String, dynamic> signedBundle); // ověří podpis; stejný pin = no-op; jiný = IdentityChangedException
   Future<void> expectIdentity(String peerDeviceId, String fingerprint); // BackupState 'expected_identity:<peer>'; při prvním pinu neshoda → IdentityChangedException(source: expectedMismatch)
   Future<void> acceptIdentityChange(String peerDeviceId, Map<String, dynamic> signedBundle,
       {required String expectedFingerprint}); // v 1 transakci: ověř podpis a fingerprint, přepiš pin + Contacts.identityKey,
                                               // smaž všechny SignalSessions s address = peer i LIKE 'peer:%',
                                               // Contacts.verifiedAt = null, identityKeyChangedAt = null
   ```
   Pozor: `_verifyPeerIdentity` dnes běží uvnitř transakce inboxu (`message_inbox_service.dart:85-93`) a její zápisy se při výjimce vrátí. Proto S jen emituje událost. Zápis `pending_identity:` a `identityKeyChangedAt` dělá posluchač G **mimo** transakci.
6. **Stub `AttachmentService`** (kontrakt M2, G potřebuje jen): `Future<MediaRef> uploadEncrypted(Uint8List bytes, {required String mime, String? name, int? width, int? height})`, `Future<Uint8List> download(MediaRef ref)` (ověří `sha256`), `MediaRef.toJson/fromJson`, konstanta `e2eAttachmentTtl` (**[OVĚŘIT]** hodnotu s M2; G podle ní plánuje re-upload avataru).

### 4.4 Server a HTTP

- **Žádná změna entit ani EF migrace X0 pro G.** Role je `string` (`Models/GroupMember.cs`) a nové endpointy skupin žádné nové sloupce nepotřebují. `GroupInvite` a `DeviceReport` patří do migrace vlny 2 (G9, G10).
- **Požadavek na S (vlastník `DeviceEndpoints.cs`), zmrazit v X0:** nový endpoint `GET /devices/{id:guid}/identity` (auth, limiter `api`, **nespotřebuje OPK**):
  - `200 {"deviceId":"…","userHandle":"CT-…","isBot":false,"identityKey":"b64","signingKey":"b64"|null,"signedPreKey":"b64","signature":"b64"|null}`;
  - `404` pro neznámé zařízení.

  Použití: připnutí identity při přidání kontaktu, bezpečnostní číslo ještě před první zprávou a jméno a handle neznámého odesílatele. Integrační test píše S. Klientský parser (`device_identity_api.dart`) píše G proti tomuto kontraktu.
- **Kontrakty endpointů skupin (implementuje G1, X0 je jen zapíše do contracts):**

| Metoda a cesta | Kdo | Request | Odpověď |
| --- | --- | --- | --- |
| `GET /groups/{id}` | člen | — | `200 {groupId, organizationId?, organizationName?, auditorDeviceId?, isEmergencyChannel:bool, myRole:"admin|member|auditor", memberCount:int}` (**nová pole jsou aditivní**) |
| `GET /groups/{id}/members` | člen | — | `200 [{deviceId, role, joinedAt, userHandle, isBot}]` (`userHandle`, `isBot` aditivní) |
| `PUT /groups/{id}/members` | admin | `{deviceId}` | beze změny 200. Chyby dostanou navíc `code`: `device_not_found` 400, `already_member` 409, `group_full` 400, `not_enrolled` 403 (bez těla, jako dnes), `business_conversation_required` 409 |
| `DELETE /groups/{id}/members/{deviceId}` | admin, **nebo sám sebe** | — | `200 {message}`; `409 {error,code:"auditor_immutable"}`; `409 {error,code:"last_admin"}` (jen když zůstávají jiní lidé, R6); `409 {error,code:"emergency_membership_managed"}` (sám sebe v nouzovém kanálu, R10); `403` ne-admin maže cizího |
| `PATCH /groups/{id}/members/{deviceId}` **(nový)** | admin | `{role:"admin"|"member"}` | `200 {deviceId, role, joinedAt, userHandle, isBot}`; `400 {code:"invalid_role"}`; `404`; `409 {code:"auditor_immutable"}`; `409 {code:"last_admin"}` (degradace posledního admina) |

- Hub: **beze změny** (žádná nová metoda ani událost). Změny členství se šíří E2E zprávou `group-update` a pravdou zůstává REST.

### 4.5 Balíčky, manifesty, entitlements (X0 najednou)

| Položka | Proč | Platformy |
| --- | --- | --- |
| `image: ^4.5.0` **[OVĚŘIT]** aktuální verzi na pub.dev | čtvercový ořez, zmenšení 256/48 px, JPEG enkód avataru (pure Dart) | android, ios, web, windows, macos, linux |
| `flutter_web_plugins: {sdk: flutter}` | `usePathUrlStrategy()` (R8) | web (import podmíněný `kIsWeb` není třeba — no-op mimo web) |
| (existuje) `image_picker ^1.2.2`, `mobile_scanner`, `qr_flutter`, `share_plus`, `file_picker` | výběr fotky, skenování, QR, sdílení | image_picker na desktopu **[OVĚŘIT]** endorsed implementace; fallback `file_picker` |
| AndroidManifest: nový `<intent-filter android:autoVerify="true">` s `VIEW`, `DEFAULT`, `BROWSABLE`, `<data android:scheme="https" android:host="jay.zcloud.cz" android:pathPrefix="/c/"/>` + `pathPrefix="/ch/"` + `pathPrefix="/g/"` | App Links | android |
| iOS `ios/Runner/Runner.entitlements`: `com.apple.developer.associated-domains = [applinks:jay.zcloud.cz]` + `CODE_SIGN_ENTITLEMENTS` v projektu (P vlastní xcodeproj) + capability *Associated Domains* u App ID `cz.zcloud.jay` (vlastník v Apple portálu) | Universal Links | ios |
| Info.plist: nic nového. `NSPhotoLibraryUsageDescription` a `NSCameraUsageDescription` už jsou (`ios/Runner/Info.plist:91-92`), jen text doplnit o „profilovou fotku“ (volitelné). `FlutterDeepLinkingEnabled` je od Flutter 3.27 výchozí **[OVĚŘIT]** na 3.41 (`.github/workflows/ci.yml:59`) | — | ios |
| macOS: bez změny ve vlně 1 (deep linky desktop = G11) | — | macos |

## 5. Závislosti na jiných proudech

| Proud | Co G konzumuje / co od něj potřebuje | Kontrakt | Jak G kóduje bez čekání |
| --- | --- | --- | --- |
| X0 | schema v4 (4.1), registr handlerů, `ControlMessageSender` (rozhraní), `PeerDirectory` (rozhraní), stuby S a M2, balíčky, manifest, `group-event` v archivátoru | 4.1–4.5 | fake implementace v testech |
| S | `SafetyNumber`, `IdentityFingerprint`, API identity v `SessionManager`, `GET /devices/{id}/identity` | 4.3 bod 4–5, 4.4 | obrazovky berou kalkulačku jako parametr (`SafetyNumberCalculator`), testy s fake `SessionManager` |
| M | implementace `ControlMessageSender`; v inboxu: registr + blokace (blokovaný → dešifrovat, zahodit, **ack** i při chybě dešifrování, bez notifikace); ignorovat typing od blokovaných; v chatu: `PeerDirectory.displayName` pro titulek a jméno odesílatele (`chat_screen.dart:206-210`, `:355-356`) a totéž v `chat_list_screen.dart:146-152`; vložit `IdentityChangedBanner`, `UnknownSenderBar`, `GroupLeftBar` (widgety G) nad seznam zpráv; vykreslit `type == 'system'` přes `SystemEventLine` (widget G); klepnutí na titulek → `/contacts/:id` resp. `/groups/:id/info`; brána odeslání podle R3/R4 (`PeerDirectory.identityState`), u skupiny vynechání členů přes `onlyRecipients`; volat `ProfileDistributor.beforeOutgoing(conversationId)` před prvním šifrováním zprávy | 4.3 | widgety a `ProfileDistributor` jsou v G, M jen vkládá volání. G testuje widgety samostatně |
| M2 | `AttachmentService.uploadEncrypted/download`, `MediaRef`, TTL | 4.3 bod 6 | fake služba v testech. Bez M2 se profil pošle jen s `avatarThumb` (degradace, ne blokace) |
| C | příchozí nabídka hovoru od `PeerDirectory.isBlocked` → tiše ignorovat (nevyzvánět, neodpovídat → volající vidí timeout); jméno a avatar na obrazovce hovoru přes `PeerDirectory` | 4.3 bod 3 | — |
| N | notifikace: nezobrazit pro blokované odesílatele (`isDeviceBlocked`) ani pro řídicí typy (`profile`, `group-update`) a `system`; jméno odesílatele v notifikaci přes `PeerDirectory`/DB | 4.3 bod 3 | — |
| D (vlna 2) | záloha v2 přenese `Contacts.displayName`, `verifiedAt` (jen spolu s `identityKey`, jinak `null`), `BlockedDevices`, `PeerProfiles` (bez `avatarImage`), můj profil, `profile:settings`. Oprava whitelistu typů v `backup_import.dart:62` (chybí `call-event`, přibude `system`) | — | — |
| P | release keystore SHA-256 + Play App Signing SHA-256 do `assetlinks.json`; Apple Team ID do AASA; `applicationId`/bundle `cz.zcloud.jay`; `CODE_SIGN_ENTITLEMENTS`; krok v `deploy.yml`, který selže, když `.well-known` obsahuje placeholder, a zkopíruje `web/.well-known` do `build/web/.well-known`, pokud to `flutter build web` neudělá (**[OVĚŘIT]** kopírování tečkových adresářů) | — | G vytvoří soubory s placeholdery `__ANDROID_SHA256_RELEASE__`, `__ANDROID_SHA256_PLAY__`, `__APPLE_TEAM_ID__` |
| O | nic (doména `jay.zcloud.cz` na SWA už existuje) | — | — |

## 6. Balíčky práce

Pořadí uvnitř proudu: **G1, G2, G3 hned a paralelně** (základy) → **G4, G5, G6, G7, G8 paralelně** (každý má své soubory; sdílí jen `router.dart` a `main.dart` připisováním a ARB s různými prefixy).

### G1 — Server: správa členství skupin (M, vlna 1)

**Cíl:** Člen může odejít, admin mění role, klient dostane handle a příznaky pro UI. KB1, KB2 ani nouzový kanál neregresují.

**Soubory:**
- `src/server/CallType.Api/Endpoints/GroupEndpoints.cs`
- `src/server/CallType.Api.Tests/Endpoints/GroupEndpointsTests.cs`
- nový `src/server/CallType.Api.Tests/Endpoints/GroupMembershipManagementTests.cs`

**Kroky:**
1. `RemoveMember`:
   - `var self = Caller(user) == deviceId;`
   - `Authorize(groupId, user, db, admin: !self, ct)`.
   - Kontrola auditora zůstane první (`:176-177`).
   - Pro `self` načíst `IsEmergencyChannel`. Když je `true` → `409 {error:"emergency_membership_managed", code:"emergency_membership_managed"}`. Komentář PROČ: členství v nouzovém kanálu řídí enrollment organizace (E07).
   - Pro `self && Role == "admin"`: `otherHumans = count(GroupId == g && DeviceId != caller && Role != "auditor")`, `otherAdmins = count(Role == "admin" && DeviceId != caller)`. Když `otherAdmins == 0 && otherHumans > 0` → `409 {error:"The last administrator must promote someone first.", code:"last_admin"}`.
   - Stávající kontrolu `:178-179` ponechat jen pro `!self` (pojistka) a doplnit ji o `code:"last_admin"`.
2. Nový `PATCH /groups/{groupId:guid}/members/{deviceId:guid}` → `SetMemberRole(Guid groupId, Guid deviceId, SetGroupMemberRoleRequest request, …)`:
   - `RequireAuthorization().RequireRateLimiting("api")`, `Authorize(admin: true)`;
   - role ∉ {`admin`, `member`} → 400 `invalid_role`;
   - cíl neexistuje → 404;
   - cíl je `auditor` → 409 `auditor_immutable`;
   - degradace posledního admina → 409 `last_admin`;
   - stejná role → 200 beze změny;
   - jinak uložit a vrátit 200 `GroupMemberDto`.
   - `public record SetGroupMemberRoleRequest(string? Role);`
3. `GroupMemberDto(Guid DeviceId, string Role, DateTimeOffset JoinedAt, string UserHandle, bool IsBot)`. `ListMembers` se projektuje přes `m.Device.UserHandle`, `m.Device.IsBot` (navigační vlastnost existuje, `Models/GroupMember.cs`). Handle není tajný (lookup `by-handle` ho vydá každému přihlášenému).
4. `GroupInfoDto(…, bool IsEmergencyChannel, string MyRole, int MemberCount)`. Vyplnit i pro anonymní skupiny a při vypnutém business režimu (`:106-107`).
5. `AddMember`: ke stávajícím chybám přidat `code` (`device_not_found`, `already_member`, `group_full`). Text `error` ponechat, testy ho čtou.
6. Komentáře PROČ u každého nového pravidla (hlavně proč auditor nesmí odejít ani sám a proč se u nouzového kanálu zakazuje odchod).

**Testy** (Testcontainers, `IntegrationTestBase`):
- `Member_can_leave_and_then_loses_read_access` (DELETE self 200 → GET members 403)
- `Last_admin_cannot_leave_while_others_remain` (409 `last_admin`) → `PATCH` povýšit → odchod 200
- `Sole_human_admin_can_leave`
- `Admin_can_promote_and_demote`; `Member_cannot_change_roles` (403); `Invalid_role_is_rejected` (400); `Demoting_last_admin_is_rejected` (409)
- `Auditor_role_cannot_be_changed_or_leave` (PATCH 409, DELETE self jako auditor 409)
- `Emergency_member_cannot_leave` (skupina přes `EmergencyGroupService.EnsureGroupAsync` + `AddMemberAsync`)
- `Business_member_can_leave_and_auditor_stays_required` (po odchodu `SendReliableGroupMessage` bez auditora dál `audit_recipient_missing`, vzor v `Hubs/MessengerHubTests.cs`)
- `Members_list_includes_handle_and_bot_flag`; `Get_group_reports_emergency_flag_role_and_count`
- Upravit `Admin_can_add_and_remove_members_but_not_last_admin` (`GroupEndpointsTests.cs:65-74`) podle R6. Komentář v testu vysvětlí změnu chování.

**Kritéria přijetí:** všechny testy zelené v `dotnet test src/server/CallType.Api.Tests` (Docker; když lokálně neběží, pak hosted CI v public okně se souhlasem vlastníka). Existující `BusinessGroupEndpointsTests` a emergency testy beze změny zelené. Koordinátor doplní řádky do tabulky API v `CLAUDE.md`.

**Paralelně s:** G2, G3.

### G2 — Core: klientské API skupin, identita zařízení, parser odkazů (S, vlna 1)

**Soubory:**
- `calltype_core/lib/network/group_api.dart`, `group_dtos.dart`, `device_identity_api.dart`
- `calltype_core/lib/links/invite_link.dart`
- testy `calltype_core/test/network/group_api_test.dart`, `device_identity_api_test.dart`, `calltype_core/test/links/invite_link_test.dart`

**Kroky:**
1. `extension GroupApi on ApiClient` (vzor `organization_api.dart:9`):
   - `getGroupDetails(groupId) → GroupDetails`;
   - `getGroupMemberDetails(groupId) → List<GroupMemberInfo>`;
   - `addGroupMember(groupId, deviceId)`, `removeGroupMember(groupId, deviceId)`, `leaveGroup(groupId, myDeviceId)`;
   - `setGroupMemberRole(groupId, deviceId, GroupRole role) → GroupMemberInfo`;
   - `GroupApiError? groupApiErrorOf(Object error)` mapuje `code` na enum `GroupApiError { lastAdmin, auditorImmutable, emergencyMembershipManaged, businessConversationRequired, notEnrolled, groupFull, alreadyMember, deviceNotFound, invalidRole, forbidden, notFound }`. U 403 bez těla se pro PUT v business skupině mapuje na `notEnrolled`, jinak na `forbidden`.
2. `GroupDetails` a `GroupMemberInfo` (`deviceId`, `role`, `joinedAt`, `userHandle`, `isBot`, getter `isAuditor`) s `fromJson` tolerantním k chybějícím novým polím. Starý server vrátí `isEmergencyChannel` jako `false` a `myRole` jako `null`.
3. `extension DeviceIdentityApi on ApiClient { Future<DeviceIdentity?> getDeviceIdentity(String deviceId); }`. Při 404 vrací `null`. `DeviceIdentity.toSignedBundle()` vrátí mapu ve tvaru, který bere `KeyManager.verifyIdentityBundle`.
4. `invite_link.dart`:
   - `class InviteLink { final String handle; final String? deviceId; final String? fingerprint; }`;
   - `InviteLink? parseInviteLink(String raw)` přijme:
     - `https://jay.zcloud.cz/c/{handle}?d=&f=` (i jiný host předaný `allowedHosts`);
     - `ct://{deviceId}/{handle}`;
     - `calltype://contact/{handle}`;
     - holý `CT-XXXX-XXXX` (normalizovat na velká písmena, regex `^CT-[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$` podle abecedy `HandleChars` v `src/server/CallType.Api/Services/HandleGenerator.cs:21`);
   - `String buildInviteLink({required String baseUrl, required String handle, required String deviceId, required String fingerprint})`;
   - `deviceId` validovat UUID regexem (stejným jako `contacts_controller.dart:99-103`).
5. Testy: kontrakt JSON zkopírovaný z tabulky 4.4 (ne vymyšlený, CLAUDE.md), mapování chyb přes `DioException` s `Response`, všechny formáty odkazů včetně neplatných.

**Kritéria:** `cd src/client/calltype_core && flutter test` zelené; nic se nepřejmenovává v `api_client.dart`.

### G3 — Adresář lidí (`PeerDirectoryService`), avatar widgety (M, vlna 1)

**Soubory:**
- `lib/shared/identity/peer_directory_service.dart`
- `lib/shared/widgets/avatar.dart`
- `lib/main.dart` (připsat provider)
- testy `test/shared/identity/peer_directory_service_test.dart`, `test/shared/widgets/avatar_test.dart`

**Kroky:**
1. `class PeerDirectoryService extends ChangeNotifier implements PeerDirectory`. Drží cache ze tří drift `watch()` streamů (`contacts`, `peerProfiles`, `blockedDevices`) a set `identityKeyChangedAt != null`. Při každé změně volá `notifyListeners()`. Synchronní gettery jsou kvůli `build()` v M a C.
2. `displayName` podle R2: `contact.displayName?.trim()` → `profile.displayName` (u neuloženého kontaktu `'~ $name'`) → `contact.userHandle ?? profile-handle cache` → `deviceId.substring(0, 8)`.
3. `identityState`: `identityKeyChangedAt == null` → `verifiedAt != null ? verified : unverified`. Jinak `verifiedAt != null ? changedVerified : changedUnverified`. `verifiedAt` se při detekci změny **nemaže**, aby politika R3/R4 věděla, že kontakt byl ověřený. Smaže ho až přijetí nového klíče.
4. `avatar.dart`:
   - `LetterAvatar` rozšířit o volitelné `Uint8List? image` (`CircleAvatar(backgroundImage: MemoryImage(image))`) a stabilní barvu z `deviceId`, ne z `String.hashCode` jména. Barva se tak nezmění s přezdívkou.
   - Nový `PeerAvatar({required String deviceId, double radius = 24})` čte `PeerDirectory` přes `context.watch`. Použije `avatarImage ?? avatarThumb`, jinak písmeno.
   - Komentář PROČ: thumb přijde inline hned, plný obrázek až po stažení blobu.
5. `main.dart`: `ChangeNotifierProvider<PeerDirectory>(create: (_) => PeerDirectoryService(database: db)..start())`, připsat za `ContactsController`.

**Testy:**
- unit s `NativeDatabase.memory()`: pořadí jmen, `~` prefix, blokace, všechny 4 stavy identity, reakce na změnu tabulek;
- widget: `PeerAvatar` s obrázkem a bez, RTL (`localizedApp(locale: Locale('ar'))`).

**Paralelně s:** G1, G2.

### G4 — Profil: jméno, avatar, „o mně“, onboarding, distribuce (L, vlna 1)

**Soubory:**
- `lib/features/profile/{my_profile_screen.dart, profile_controller.dart, avatar_pipeline.dart, profile_distributor.dart, profile_handler.dart, profile_codec.dart}`
- `lib/features/onboarding/onboarding_screen.dart`, `onboarding_controller.dart`
- `router.dart` (routa `/settings/profile`), `settings_screen.dart` (položka), `main.dart` (registrace handleru a distributora)
- ARB `profile*`, `onboardingName*`
- testy `test/features/profile/**`, `test/features/onboarding/onboarding_name_test.dart`

**Kroky:**
1. `profile_codec.dart`:
   - `ProfilePayload {displayName, about, avatar (MediaRef?), avatarThumb (Uint8List?), version, updatedAt}`;
   - `encode()` → JSON řetězec pro `body`;
   - `decode(String)` s validací: jméno max. 40 grafémů (`characters`), about max. 140; odstranit řídicí znaky a `U+202A–U+202E`, `U+2066–U+2069` (bidi override, obrana proti podvržení jména); `avatarThumb` max. 2048 B po dekódování; `version >= 1`. Jinak `FormatException`.
2. `avatar_pipeline.dart` (balík `image`, výpočet přes `compute()` mimo UI vlákno, na webu inline):
   - `Future<AvatarImages> prepareAvatar(Uint8List source)`: dekódovat, oříznout na střed čtverce, 256×256 JPEG q80 (max. 64 KiB, jinak snižovat kvalitu po 10 až na q40) a 48×48 JPEG q60 (max. 2 KiB, jinak q30, jinak `null`).
   - Metadata EXIF se zahodí, protože re-enkódování je nepřenáší. Komentář PROČ: GPS v EXIF.
3. `profile_controller.dart`:
   - načte a uloží můj řádek `PeerProfiles` (`deviceId = můj`);
   - `setName`, `setAbout`, `setAvatar(bytes)`, `removeAvatar()`;
   - každá změna: `version++`, `updatedAt = now`;
   - avatar: `AttachmentService.uploadEncrypted(jpeg256, mime: 'image/jpeg', width: 256, height: 256)` → `avatarRef`, `avatarUploadedAt`. Když M2 selže nebo chybí, uloží se jen thumb a v UI se ukáže info.
   - `profile:settings.share` přepínač.
4. `my_profile_screen.dart`:
   - avatar s akcí „Vybrat fotku“ (`ImagePicker().pickImage(source: gallery, maxWidth: 1024)`, na Windows a Linuxu `FilePicker` s filtrem obrázků) a „Odebrat“;
   - pole jméno a „o mně“ s počítadlem;
   - přepínač sdílení;
   - pod tím handle a karta „Moje pozvánka“ (odkaz na `/settings/identity`);
   - vysvětlení v textu: „Jméno a fotka se posílají jen šifrovaně lidem, kterým píšete. Server je nevidí.“
5. `profile_distributor.dart`:
   - `class ProfileDistributor { Future<void> beforeOutgoing(String conversationId); Future<void> onProfileChanged(); Future<void> onGroupMembersAdded(String groupId, List<String> newMembers); }`.
   - `beforeOutgoing` (volá M): když `share == false` nebo nemám jméno ani avatar → nic. Direct: pokud `profile_sent:<peer>` < aktuální verze → `sendControl(type:'profile', recipientDeviceId: peer, durable: true)` a uložit verzi. Group: totéž s klíčem `profile_sent:group:<gid>` a `groupId`.
   - Avatar blob starší než `e2eAttachmentTtl / 2` → před odesláním znovu nahrát (nový `avatarRef`).
   - `onProfileChanged` (debounce 5 s): rozeslat všem cílům, které mají záznam `profile_sent:*`, nikomu novému (R1).
   - `onGroupMembersAdded` (volá G7 po ověřeném `add`): anonymní skupina → direct zpráva každému novému členovi. Business skupina → fan-out do skupiny, protože direct zprávu může zakázat `RequireBusinessConversations` (`MessengerHub.cs:99-101`).
   - Blokovaným se profil neposílá.
6. `profile_handler.dart`: `registerControlHandler('profile', …)`:
   - odesílatel blokovaný → ignorovat;
   - `decode`: když `version <= uložená` → ignorovat;
   - jinak upsert `PeerProfiles` (bez sítě, jsme v transakci).
   - Pokud se `avatar.sha256` liší od uloženého, naplánuje se po commitu `AvatarFetcher.fetch(deviceId, ref)` (fronta v paměti + `pending_control:` pro přežití restartu). `download` → ověřit sha256 → uložit `avatarImage`. Chyba se tiše zopakuje při dalším startu, maximálně 3×.
7. Onboarding (R11):
   - na obrazovce po úspěšné registraci (`onboarding_screen.dart:121-166`) přidat volitelné pole „Vaše jméno (nepovinné)“ s vysvětlujícím textem;
   - „Začít“ uloží jméno přes `ProfileController.setName` jen tehdy, když je neprázdné;
   - nic se neposílá hned, profil jde až s první zprávou (R1).
8. Router `/settings/profile`, položka v Nastavení. `main.dart`: `ProfileDistributor` a registrace handleru.

**Testy:**
- codec: hranice, bidi, příliš velký thumb, verze;
- pipeline: PNG 2000×1000 → 256×256 JPEG max. 64 KiB, thumb max. 2 KiB, EXIF pryč;
- distributor s fake `ControlMessageSender`: první zpráva pošle profil jednou, druhá už ne, změna → rozeslání jen dřívějším cílům, blokovaný nic nedostane, business skupina → fan-out;
- handler: starší verze se ignoruje, blokovaný se ignoruje, špatný sha256 avataru se neuloží;
- widget `MyProfileScreen` (en, cs, ar) a onboarding s přeskočením;
- `test/l10n/locale_screens_test.dart` doplnit o `MyProfileScreen` (koordinátor merge).

**Kritéria:** protějšek po první zprávě uvidí jméno v chatu, v seznamu chatů i ve skupině (po integraci M). Bez nastaveného jména se nic neposílá. Žádný plaintext profilu nejde na server (ověřit testem, že `sendControl` dostává `body` a nic jiného se nevolá přes `ApiClient`).

### G5 — Kontakty: detail, přezdívka, smazání, blokování, neznámý odesílatel (M, vlna 1)

**Soubory:**
- `lib/features/contacts/{contacts_controller.dart, contacts_screen.dart, contact_detail_screen.dart, blocked_contacts_screen.dart, block_list_controller.dart, contact_add_flow.dart, widgets/unknown_sender_bar.dart}`
- router, settings (připsat), ARB `contactDetail*`, `contactBlock*`, `contactUnknown*`
- testy `test/features/contacts/**`

**Kroky:**
1. `ContactsController`:
   - `rename(deviceId, String? nickname)` (prázdné → `null`, trim, max. 40);
   - `deleteContact(deviceId)` smaže jen řádek `Contacts`. Konverzace, zprávy, pin `peer_identity:` i blokace zůstanou. Komentář PROČ: pin musí přežít, jinak by znovupřidání otevřelo TOFU znovu;
   - `saveUnknown(deviceId)`: pro neznámého odesílatele stáhne `getDeviceIdentity` a založí kontakt s handle;
   - řazení v Dartu podle `PeerDirectory.displayName` (SQL `ORDER BY displayName` dnes řadí `NULL` první, `contacts_controller.dart:37-42`).
2. `contact_add_flow.dart`: vytáhnout `_previewAndAdd` a `_showAddDialog` z `contacts_screen.dart:198-308` do znovupoužitelné třídy `ContactAddFlow`. Používají ji obrazovka kontaktů, QR sken a deep link (G8). Náhled ukáže handle, BOT odznak a u odkazu s `f` i stav „ověřeno z QR“ / „otisk sedí“ / „otisk NESEDÍ“ (G6).
3. `block_list_controller.dart`:
   - `block(deviceId, {String? handle})` → insert `BlockedDevices`;
   - `unblock(deviceId)`;
   - `blocked` stream.
   
   Blokace neruší kontakt ani konverzaci.
4. `contact_detail_screen.dart` (`/contacts/:deviceId`):
   - hlavička: velký `PeerAvatar`, `displayName`, pod ním handle (vždy), profilové „o mně“, BOT odznak;
   - akce: Napsat (`ChatListController.createDirectConversation`, `chat_list_controller.dart:65`), Přejmenovat (dialog), Bezpečnostní číslo (`/contacts/:id/safety`, G6), Blokovat/Odblokovat (potvrzovací dialog s vysvětlením R5), Smazat kontakt (potvrzení), u neuloženého „Uložit do kontaktů“.
5. `blocked_contacts_screen.dart` (`/contacts/blocked`, položka v Nastavení vedle „Blokované kanály“, `settings_screen.dart:74-76`).
6. `widgets/unknown_sender_bar.dart`: `UnknownSenderBar(deviceId)` se zobrazí v 1:1 chatu, když `!isContact && !isBlocked`. Text „Tento člověk není ve vašich kontaktech.“ a tlačítka [Uložit] [Blokovat]. Vkládá ho M.
7. `contacts_screen.dart`: dlaždice přes `PeerAvatar` a `displayName`, trailing ikona ověření podle `verifiedAt` (dnes `contact.verified`, `:333`), dlouhý stisk nebo ikona `info` → detail. Zbavit se `dynamic` u `_ContactTile` (`:315`).

**Testy:**
- controller: rename/delete zachová pin i konverzaci;
- block/unblock;
- widget: detail (uložený, neuložený, bot, blokovaný), prázdný seznam blokovaných, `UnknownSenderBar` akce;
- `no_hardcoded_strings_test` projde.

**Kritéria:** přezdívka se projeví všude, kde M a C používají `PeerDirectory`. Smazaný a znovu přidaný kontakt nedostane nový TOFU. Blokovaný je ve všech třech vrstvách (inbox M, hovory C, notifikace N) podle kontraktu `isBlocked`.

### G6 — Ověření identity a změna klíče (L, vlna 1)

**Soubory:**
- `lib/features/contacts/{safety_number_screen.dart, identity_service.dart, identity_change_recorder.dart, widgets/identity_changed_banner.dart}`
- `qr_scanner_screen.dart` (režim raw)
- `contacts_controller.dart` (pin při přidání)
- router, `main.dart` (start recorderu), ARB `safetyNumber*`, `identityChange*`
- testy

**Kroky:**
1. **Pin při přidání** (`ContactsController.addContact`):
   - po uložení kontaktu zkusit `api.getDeviceIdentity(deviceId)` → `sessionManager.pinIdentity(deviceId, bundle)` a zapsat `Contacts.identityKey`;
   - když odkaz nesl `f`: `IdentityFingerprint.of(ik, sk) != f` → kontakt **nepřidat** a vyhodit `InviteFingerprintMismatch`. UI ukáže varování „Klíč na serveru neodpovídá pozvánce. Nepřidávejte kontakt a ověřte pozvánku jinou cestou.“;
   - shoda a zdroj je kamera (`ContactAddSource.cameraScan`) → `verifiedAt = now`, `verified = true`;
   - shoda z vloženého nebo otevřeného odkazu → jen pin, neověřeno. Komentář PROČ: odkaz poslaný přes cizí kanál neprokazuje, s kým mluvím; QR naskenovaný z displeje druhé osoby ano.
   - Offline, tedy lookup selže: kontakt přidat, pokud je `f`, zavolat `expectIdentity(deviceId, f)`, pin proběhne při první session.
2. **`identity_change_recorder.dart`** (start v `main.dart`) poslouchá `sessionManager.identityChanges` a **mimo** transakci:
   - uloží `pending_identity:<peer>`;
   - nastaví `Contacts.identityKeyChangedAt = now`, pokud kontakt existuje. Pokud neexistuje, stav nese jen `pending_identity:`, `PeerDirectoryService` ho čte také;
   - do přímé konverzace (existuje-li) vloží `system` řádek `identity-changed`, idempotentně: jen jednou na `offeredFingerprint`.
   
   U zdroje `expectedMismatch` je text ostřejší („neodpovídá pozvánce“).
3. **`identity_service.dart`**:
   - `Future<void> acceptChange(String deviceId)`: načte `pending_identity:` → `sessionManager.acceptIdentityChange(peer, bundle, expectedFingerprint: …)` → smaže `pending_identity:` → vloží `system` řádek `identity-accepted` → `signalR.requestPendingMessages()` (`signalr_client.dart:264-266`), aby server znovu doručil zprávy, které čekaly nepotvrzené.
   - `Future<void> markVerified(String deviceId)` a `unmarkVerified` (zapisuje `verifiedAt` i `verified`). Označit lze jen při existujícím pinu a bez čekající změny.
4. **`safety_number_screen.dart`** (`/contacts/:deviceId/safety`):
   - Vstup: moje klíče (`keyManager.getSignedIdentityBundle()`) a klíče protějšku v pořadí `pending_identity` (pokud existuje) → `pinnedIdentity` → `getDeviceIdentity` (bez OPK).
   - Zobrazení: 12 skupin po 5 číslicích v mřížce 3×4, `SelectableText` s monospace písmem, QR s `qrPayload`.
   - „Naskenovat kód protějšku“ (jen na platformách s kamerou, stejná podmínka jako `contacts_screen.dart:43-47`) → `QrScannerScreen(rawMode: true)` → `matchesScanned`. Shoda → zelený stav a `markVerified`. Neshoda → červené varování.
   - Ruční „Označit jako ověřené“ s potvrzovacím dialogem „Porovnali jste všech 60 číslic osobně nebo v hovoru?“.
   - Při čekající změně: nahoře vysvětlení a tlačítka „Kódy se shodují — přijmout a ověřit“, „Přijmout bez ověření“ a „Blokovat“.
   - Kalkulačka je parametr konstruktoru `SafetyNumberCalculator calculator = SafetyNumber.compute` kvůli testům bez S.
5. **`widgets/identity_changed_banner.dart`**: `IdentityChangedBanner(deviceId)` (vkládá M) pro stavy `changed*`.
   - Neověřený: text + [Zobrazit kód] [Přijmout nový klíč] (s potvrzením).
   - Ověřený: text + jen [Ověřit znovu] (vede na safety obrazovku).
   - Ve skupině `GroupIdentityWarning(groupId)` vypíše členy se změnou (čte `PeerDirectory` nad seznamem členů z G7).
6. `qr_scanner_screen.dart`: parametr `rawMode`. V něm vrací `{'raw': value}` bez parsování kontaktu. Parser kontaktů přesunout na `parseInviteLink` (G2). QR s `f` z kamery předá `source: cameraScan`.
7. Texty (bezpečnostní wording, CLAUDE.md): nepsat „zpráva je kompromitovaná“. Pravdivé znění je například: „Server nabídl pro tento kontakt jiný klíč. Může jít o chybu serveru nebo o pokus o odposlech. Zprávy od kontaktu čekají, dokud nerozhodnete.“ Ve všech 19 jazycích musí zůstat význam.

**Testy:**
- recorder s fake streamem: zapíše pending + `identityKeyChangedAt` + právě jeden system řádek i při opakované výjimce;
- `acceptChange` volá S se správným fingerprintem a pak `requestPendingMessages`;
- pin při přidání: shoda z kamery → verified; shoda z odkazu → neověřeno; neshoda → výjimka a kontakt neuložen;
- widget safety screen: zobrazí 60 číslic ve 12 skupinách (fake kalkulačka), stav čekající změny, neshoda skenu;
- banner ve 2 stavech (en, cs, ar);
- **integrační test přes skutečné S** (`calltype_core`): po implementaci S dvě `TestDevice` (`test/helpers/test_device.dart`) spočítají stejné číslo (napíše S, G ho vyžaduje v přejímce).

**Kritéria:**
- změna klíče nikdy neskončí tichým selháním;
- chat ukáže banner a zprávy po přijetí dorazí;
- ověřený kontakt nejde odblokovat jedním ťuknutím;
- `verified` se poprvé v historii projektu může stát `true`.

### G7 — Skupiny v UI a protokol `group-update` (L, vlna 1)

**Soubory:**
- `lib/features/groups/{group_controller.dart, group_info_screen.dart, group_info_controller.dart, group_member_picker_screen.dart, group_update_handler.dart, group_update_processor.dart, widgets/system_event_line.dart, widgets/group_left_bar.dart}`
- `group_create_screen.dart`
- router, `main.dart`, ARB `groupInfo*`, `groupMember*`, `groupEvent*`
- testy

**Kroky:**
1. `group_info_controller.dart`:
   - `load()` = `getGroupDetails` + `getGroupMemberDetails`;
   - `addMembers(List<String>)`: jednotlivě `PUT`, zastaví se na první chybě a vrátí seznam úspěšných;
   - pak `sendControl(type:'group-update', groupId, body:{op:'add', members, name, nameUpdatedAt}, durable:true)`, takže noví členové dostanou název;
   - pak `ProfileDistributor.onGroupMembersAdded`.
   - `removeMember(id)`: **nejdřív `DELETE`**, potom oznámení zbylým (`op:'remove'`) fan-outem a odebranému direct zprávou `group-update` s `groupId` jen v `body` (`durable:true`, `recipientDeviceId`). Komentář PROČ: obálky v outboxu jsou šifrované pro pevný seznam příjemců a hub odmítne příjemce, který už není členem (`MessengerHub.cs:124-125`). Oznámení před smazáním by v outboxu uvízlo.
   - `leave()`: `sendControl(op:'leave', durable:false)` s timeoutem 10 s (chyba se ignoruje) → `leaveGroup` → `Conversations.leftAt = now` + system řádek. Při 409 `last_admin` UI nabídne výběr nového admina (`setRole`) a zopakuje odchod.
   - `setRole(id, role)` → `PATCH` → `op:'role'`.
   - `rename(name)`: jen admin (R7) → lokálně `title` a `titleUpdatedAt = now` → `op:'rename'`.
   - Limit: `memberCount` (včetně auditora) + nově vybraní ≤ 100, jinak UI tlačítko zakáže (server by vrátil `group_full`).
2. `group_info_screen.dart` (`/groups/:id/info`):
   - název (editace jen pro admina) a počet členů;
   - business: `BusinessBanner` a `AuditorMemberTile` z `features/organization/business_banner.dart` (jen použití) → **KB1: auditor vždy v seznamu, bez akcí**;
   - nouzový kanál (`isEmergencyChannel`): štítek, žádné přidat/odebrat/opustit, jen seznam;
   - seznam členů s `PeerAvatar`, `displayName`, handle, odznaky Admin, Bot a ikonou změny klíče;
   - akce admina na člena (ne auditora): Odebrat, Udělit/odebrat admina;
   - tap na člena → `/contacts/:deviceId`;
   - tlačítka „Přidat členy“ (admin), „Opustit skupinu“ (ne v nouzovém kanálu), `GroupIdentityWarning`.
3. `group_member_picker_screen.dart` (`/groups/:id/add`): kontakty kromě stávajících členů a blokovaných. Business skupina: průnik s `getOrganizationEnrollments`, stejně jako `group_create_screen.dart:70-80`. Filtr převzít, ne duplikovat: vytáhnout do `lib/features/groups/enrolled_filter.dart` a použít na obou místech. Počítadlo zbývající kapacity.
4. `group_update_handler.dart` (`registerControlHandler('group-update')`): v transakci jen uloží `pending_control:<messageId>` (bez sítě). Po commitu spustí `GroupUpdateProcessor.drain()`.
5. `group_update_processor.dart` pro každý záznam:
   - stáhne `getGroupMemberDetails` a **ověří proti serveru**:
     - `add` → cíle jsou členy;
     - `remove`/`leave` → cíl už není členem;
     - `role` → role sedí;
     - `rename` → odesílatel je admin;
   - 403 na `getGroupMemberDetails` znamená, že já už nejsem člen: `leftAt = now` a system řádek `removed-me`;
   - ověřeno → system řádek. Při `rename` platí LWW: aplikovat jen když `nameUpdatedAt > titleUpdatedAt`, při shodě rozhoduje vyšší `senderId`;
   - neověřeno (podvrh nebo závod) → zahodit a zalogovat;
   - konverzace neexistuje (nový člen) → založit `type:'group'`, `title: name`, `titleUpdatedAt`;
   - síťová chyba → nechat v `pending_control:`, zopakovat při dalším `connected` (SignalR) nebo startu;
   - `add` obsahující mě → `leftAt = null` (znovupřidání).
6. `widgets/system_event_line.dart`: `SystemEventLine(Message)` vykreslí `system` řádky (jména přes `PeerDirectory`, ICU texty `groupEvent*`, např. „{actor} přidal(a) {count, plural, …}“). Vkládá M do `chat_screen.dart` jako větev vedle `call-event` (`:333-335`).
7. `widgets/group_left_bar.dart`: `GroupLeftBar(conversationId)` nahradí composer, když `leftAt != null` („Nejste členem této skupiny“). M vloží podmínku.
8. `group_controller.dart`: odstranit komentář „MVP only creation“ (`:15-16`), `createGroup` beze změny chování. Po vytvoření pošle `group-update {op:'add', members: všichni, name}`, aby členové znali název dřív než s první zprávou.

**Testy:**
- processor s fake API: každá operace ověřená i podvržená, LWW, 403 → `removed-me`, offline → zůstane pending, idempotence při redelivery stejného `messageId`;
- controller: pořadí volání u remove (DELETE před sendControl) a leave (sendControl non-durable před DELETE), `last_admin` flow;
- widget `GroupInfoScreen`: anonymní admin, anonymní člen, business (auditor bez akcí, KB1), **nouzový** (žádné akce), `ar` RTL;
- picker: business filtr enrollmentů, kapacita 100.

**Kritéria:**
- tři zařízení: přidání, odebrání, opuštění, přejmenování a změna role se ukáže všem jako systémový řádek;
- odebraný nemůže psát a vidí proč;
- auditor nikdy nemá akci;
- nouzový kanál nenabízí opuštění;
- stávající testy `test/features/groups/**` a organizace zelené.

### G8 — Pozvánky a deep linky (M, vlna 1; ověření na zařízení blokuje P)

**Soubory:**
- `lib/features/contacts/{invite_landing_screen.dart, pending_deep_link.dart, invite_share.dart}`
- `lib/features/settings/identity_screen.dart`
- `onboarding_controller.dart` a `onboarding_screen.dart` (QR a odložený odkaz)
- `web/.well-known/{assetlinks.json, apple-app-site-association}`
- `web/staticwebapp.config.json` (připsat)
- router, `main.dart` (připsat)
- `channel_dtos.dart` a `channel_profile_screen.dart:107` (jen podle sekce 3)
- ARB `invite*`
- testy `test/features/contacts/invite_*`, `test/web/well_known_test.dart`

**Kroky:**
1. `inviteBaseUrl`: `const String.fromEnvironment('INVITE_BASE_URL', defaultValue: 'https://jay.zcloud.cz')`, stejný vzor jako API base URL v `main.dart:46`.
2. Generování: onboarding QR (`onboarding_controller.dart:61-64`) a `identity_screen.dart:31` → `buildInviteLink(...)` s `f = IdentityFingerprint.of(...)`. `identity_screen` přejmenovat v UI na „Moje pozvánka“ a přidat tlačítko Sdílet (`SharePlus.instance.share(ShareParams(text: l10n.inviteShareText(link)))`, vzor `channel_profile_screen.dart:186`) vedle Kopírovat.
3. Routy (připsat do `router.dart`):
   - `/c/:handle` → `InviteLandingScreen(handle, deviceId: q['d'], fingerprint: q['f'])` (náhled přes `ContactAddFlow`, zdroj `link`);
   - `/ch/:handle` → `redirect: '/channels/profile/:handle'`;
   - `/contacts/blocked`, `/contacts/:deviceId`, `/contacts/:deviceId/safety` (statické `scan` a `blocked` **před** `:deviceId`);
   - `/groups/:id/info`, `/groups/:id/add`, `/settings/profile`.
4. `redirect` (připsat):
   - `calltype://contact/<h>` → `/c/<h>`;
   - `parseChannelLink` beze změny volání (funkce nově zná i HTTPS);
   - neonboardované zařízení a cesta začíná `/c/` (později `/g/`) → `PendingDeepLink.store(state.uri)` a `/onboarding`.
   
   Onboarding „Začít“ → `context.go(PendingDeepLink.take() ?? '/chats')`. Úložiště je v paměti a navíc `SecureStorage` `ct_pending_link`, aby přežilo restart během onboardingu.
5. `main.dart`: `usePathUrlStrategy()` před `runApp` (R8). `web/index.html` má `<base href="$FLUTTER_BASE_HREF">` → `/` **[OVĚŘIT]** v buildu. SWA `navigationFallback` už přepisuje neznámé cesty na `/index.html`.
6. `web/.well-known/assetlinks.json`:
   ```json
   [{"relation":["delegate_permission/common.handle_all_urls"],
     "target":{"namespace":"android_app","package_name":"cz.zcloud.jay",
       "sha256_cert_fingerprints":["__ANDROID_SHA256_RELEASE__","__ANDROID_SHA256_PLAY__"]}}]
   ```
   `web/.well-known/apple-app-site-association` (bez přípony):
   ```json
   {"applinks":{"details":[{"appIDs":["__APPLE_TEAM_ID__.cz.zcloud.jay"],
     "components":[{"/":"/c/*"},{"/":"/ch/*"},{"/":"/g/*"}]}]}}
   ```
7. `staticwebapp.config.json` (připsat):
   - `"routes":[{"route":"/.well-known/apple-app-site-association","headers":{"content-type":"application/json"}}]`;
   - do `navigationFallback.exclude` přidat `"/.well-known/*"`.
   
   **[OVĚŘIT]** SWA servíruje soubor bez přípony a hlavičku z `routes` aplikuje (test po nasazení: `curl -sI https://jay.zcloud.cz/.well-known/apple-app-site-association` → 200 a `application/json`, bez redirectu).
8. `parseChannelLink` přijme i `https://<host>/ch/<handle>`. Sdílení kanálu (`channel_profile_screen.dart:107`) generuje HTTPS. `channelLinkPrefix` zůstane kvůli zpětné kompatibilitě.
9. `test/web/well_known_test.dart` (čistý Dart test ve `flutter test`): oba soubory jsou validní JSON, package `cz.zcloud.jay`, cesty `/c/*`, `/ch/*`, `/g/*`, a `staticwebapp.config.json` obsahuje route a exclude. Kontrolu placeholderů dělá deploy (P), ne tento test.

**Testy:**
- widget `InviteLandingScreen` (bot, neshoda otisku, offline);
- router test (`localizedApp(router: …)`): `/c/CT-…?d=…&f=…` otevře landing a neonboardované zařízení projde onboardingem a vrátí se na landing;
- `/ch/X` → profil kanálu;
- starý `ct://` a `calltype://contact/` přes paste i QR dál fungují.

**Kritéria:**
- web: odkaz otevřený v prohlížeči přidá kontakt (i po čerstvém onboardingu);
- Android a iOS: po doplnění placeholderů (P) otevře odkaz aplikaci;
- nikde se negeneruje `ct://`.

### G9 — Pozvánka do skupiny odkazem (P2, M, vlna 2)

- Entita (migrace vlny 2) `GroupInvite`:
  - `InviteId Guid PK`, `GroupId Guid FK`, `TokenHash byte[32]` (SHA-256 tokenu; token 32 B náhodný, base64url, v DB nikdy v čisté podobě), `CreatedBy Guid`, `CreatedAt`, `ExpiresAt` (max. 30 dní), `MaxUses int?`, `UseCount int`, `RevokedAt?`;
  - index `(TokenHash)` unique.
- Endpointy:
  - `POST /groups/{id}/invites` (admin) `{expiresInHours?, maxUses?}` → `201 {inviteId, token, expiresAt}`;
  - `GET /groups/{id}/invites` (admin);
  - `DELETE /groups/{id}/invites/{inviteId}` (admin) → 204;
  - `POST /groups/join {token}` → `200 {groupId}`, chyby `404 invite_invalid`, `410 invite_expired`, `409 group_full`, `409 already_member`.
- Business skupina a nouzový kanál → `409 invite_not_allowed_for_business` (členství řídí enrollment). Anonymní skupina: `OrgCommunicationPolicy.IsAllowedAsync(creator, joiner)` jako v `AddMember` (`GroupEndpoints.cs:156-158`).
- Odkaz `https://jay.zcloud.cz/g/{token}#n={base64url(název)}`. Název jen ve fragmentu, server ho nevidí.
- Po připojení nový člen pošle `group-update {op:'add', members:[já]}`. Ostatní ho ověří proti serveru stejným procesorem (G7).
- GDPR: `DELETE /devices/{id}` a export (`PrivacyEndpoints`) musí pokrýt `GroupInvite.CreatedBy` (smazat pozvánky zařízení).
- Testy Testcontainers: expirace, maxUses, revokace, business zákaz, rate-limit `api`.

### G10 — Nahlášení spamu (P2, M, vlna 2)

- Entita (migrace vlny 2) `DeviceReport`: `Id long`, `ReportedDeviceId Guid`, `ReporterDeviceId Guid`, `Reason string(512)`, `Kind` (`spam|abuse|other`), `ForwardedMessages jsonb?`, `CreatedAt`.
- Endpoint `POST /devices/{id}/report` `{kind, reason?, forwardedMessages?:[{messageId, createdAt, body}]}` → 204 a 429 `report_limit_reached`, sdílený denní limit 5 jako `ChannelService.MaxReportsPerDay`.
- Obsah je **jen** to, co nahlašující sám přijal a výslovně zaškrtl („Přiložit posledních N zpráv“, výchozí vypnuto). UI to říká pravdivě: přiložené zprávy uvidí provozovatel v čitelné podobě.
- Nahlášení v UI automaticky nabídne i blokaci.
- Provozní postup: `docs/ops/` (proud O). GDPR: export a smazání zahrnou `ReporterDeviceId`.

### G11 — Share-to-app a deep linky na desktopu (P2, M, vlna 2)

- Android: intent-filter `SEND`/`SEND_MULTIPLE` (`text/*`, `image/*`, `*/*`).
- iOS: Share Extension (nový target + App Group; P vlastní xcodeproj).
- Balík `receive_sharing_intent` nebo `share_handler` **[OVĚŘIT]** údržbu a podporu platforem (android/ios; web a desktop ne).
- Tok: sdílený obsah → výběr konverzace (`lib/features/share_target/**`, G) → text do konceptu (M) nebo média přes M2.
- Desktop: schéma `calltype` na macOS (Info.plist `CFBundleURLTypes`) a Windows (registrace protokolu v MSIX, P) + balík `app_links` **[OVĚŘIT]** pro předání URI.

### G12 — KB6 událost při změně členství business skupiny (P2, S, vlna 2)

`AddMember`, `RemoveMember` (včetně odchodu) a `SetMemberRole` u skupiny s `OrganizationId` po úspěšném `SaveChangesAsync` zapíšou přes `AdminAuditWriter.AppendAsync` (`src/server/CallType.Audit/Organization/AdminAuditWriter.cs:30`) událost:
- typ `group.member_added|member_removed|member_left|role_changed`;
- `details {groupId, deviceId, role}`;
- `actorAccountId` z `OrgEnrollments` volajícího zařízení.

Chyba zápisu → `LogError` s `groupId` a HTTP odpověď se nemění (R12). Testy proti audit DB v Testcontaineru (vzor `Audit/AuditRoleMutationTests.cs`).

## 7. Přejímka na zařízení (řádky pro `docs/acceptance/matrix.md`)

Sloupce jako v matici: Web (desktop) | Web iOS Safari | Android | Windows | macOS | iOS nativní.

| Scénář | Poznámka |
| --- | --- |
| G-01 profil: jméno + fotka, protějšek je uvidí po první zprávě (1:1) | výběr fotky na každé platformě zvlášť (image_picker/file_picker) |
| G-02 změna profilu se propíše kontaktu i do skupiny; ve skupině ne-kontakt jako `~Jméno` | 3 zařízení |
| G-03 onboarding: jméno vyplněné i přeskočené | čerstvá instalace |
| G-04 přezdívka kontaktu v seznamu kontaktů, chatů, chatu a hovoru; smazání a znovupřidání kontaktu bez varování o klíči | |
| G-05 blokace: blokovaný píše (nic se nezobrazí, žádná notifikace) a volá (nic nezvoní); odblokování a nová zpráva dorazí | push závisí na N |
| G-06 bezpečnostní číslo: 60 číslic shodných na obou zařízeních; vzájemný sken QR → ověřeno | sken jen na kamerových platformách; Windows UNSUPPORTED |
| G-07 QR pozvánka naskenovaná osobně → kontakt rovnou ověřený; vložený odkaz → neověřený | |
| G-08 změna klíče: **jen lokální compose** — ruční `UPDATE "Devices" SET "IdentityKey"=…` (nikdy beta), banner, přijetí a doručení čekajících zpráv; u ověřeného kontaktu jen přes safety obrazovku | simulace útoku |
| G-09 skupina A/B/C: přidat D, odebrat C (C vidí „byl jste odebrán“, nemůže psát), D odejde, přejmenování, povýšení na admina, poslední admin musí předat roli | rozšiřuje Q01-05 |
| G-10 business skupina: auditor v seznamu bez akcí, člen odejde, archivátor dál zapisuje (lokální compose s `jay_archiver`) | KB1/KB2 |
| G-11 nouzový kanál: žádné přidat/odebrat/opustit | E07 |
| G-12 `https://jay.zcloud.cz/c/…` otevře aplikaci (Android App Links ověřené přes `adb shell pm get-app-links cz.zcloud.jay`; iOS Universal Link z Poznámek) | BLOCKED do keystore a Apple týmu (P) |
| G-13 tentýž odkaz bez nainstalované aplikace → webový klient → onboarding → náhled kontaktu | |
| G-14 sdílení pozvánky přes systémový share sheet | Windows/macOS share_plus |
| G-15 `curl` na `/.well-known/assetlinks.json` a `apple-app-site-association`: 200, `application/json`, bez redirectu | po deployi webu |

## 8. Rizika a otevřené otázky

1. **Starší klienti a boty.** Než X0 zavede toleranci neznámých typů, klient `profile` a `group-update` nepotvrdí a zprávy mu leží ve frontě až 30 dní. Web se aktualizuje sám a nativní buildy nejsou publikované. `jay_archiver` a `calltype_bot` ale musí být aktualizované **před** prvním nasazením G. Bez toho by auditorova fronta rostla a W2-F liveness nic nepozná.
2. **Hub limit 1 MiB.** Profil ve skupině se 100 členy: thumb ≤ 2 KiB → cca 6 KiB na příjemce po dvojím base64 → cca 600 KiB. Proto je thumb omezený a plný avatar jde přes blob M2. Větší thumb by rozbil fan-out (stejný problém jako soubory nad cca 900 kB, analýza §3).
3. **Nové zařízení kamaráda = nový kontakt.** Přeinstalace dá nové `deviceId` a handle (`DeviceEndpoints.cs:111`). Profilové jméno se může shodovat se starým kontaktem, takže hrozí záměna nebo podvržení. Zmírnění: `~` prefix, handle vždy vidět, neověřený stav. „Převod kontaktu“ je otevřená otázka pro D (více zařízení).
4. **R3 platí jen pokud se klíč nemění legitimně.** Kdyby D nebo S zavedli obnovu identity pod stejným `deviceId`, změny začnou být běžné a politiku je třeba přehodnotit (Signal-style). Rotace SPK (S) pin nemění, protože pin je `identityKey|signingKey`.
5. **Odmítnutý nový klíč.** Když uživatel změnu nepřijme ani neblokuje, zprávy se při každém připojení znovu doručí a znovu selžou (šum v `inbox.errors`). Blokace je ukončí (M potvrdí i nedešifrovatelné zprávy blokovaného).
6. **Podvržené `group-update`.** Členství, role a admina u přejmenování ověřuje klient proti serveru. Obsah přejmenování ověřit nejde, ale jen admin ho smí poslat. Závod mezi oznámením a čtením serveru řeší opakování z `pending_control:`.
7. **Outbox a změna členství (existující, M).** Chatová zpráva zašifrovaná před změnou členství selže na hubu („must be group members“) a zůstane `failed`. G7 to u svých oznámení obchází pořadím DELETE → oznámení. Obecné řešení (přešifrovat pro aktuální členy) patří M.
8. **Web: `usePathUrlStrategy`.** Mění tvar URL (`/#/chats` → `/chats`). **[OVĚŘIT]**, že `flutter build web` zkopíruje `web/.well-known` a SWA pošle AASA s `application/json`. Jinak krok v `deploy.yml` (P).
9. **Blokováno vlastníkem.** Apple Team ID, capability *Associated Domains*, release keystore a Play App Signing (P/O). Do té doby G-12 BLOCKED a soubory `.well-known` s placeholdery **nesmí** jít do deploye (hlídá P).
10. **Avatar blob TTL (M2).** Když blob vyprší dřív, než si ho nový protějšek stáhne, zůstane mu thumb. Distributor proto nahrává znovu po TTL/2. Hodnotu TTL potvrdí M2.
11. **Osobní údaje ostatních v lokální DB (`PeerProfiles`).** Mizí s odinstalací. Záloha (D) je volitelná a šifrovaná. Server je neukládá.
12. **Ověření bez Dockeru a Flutteru.** V tomto prostředí nemusí běžet Docker ani `flutter`. Serverové testy (G1, G9, G10, G12) i `flutter test` se pak ověří v hosted CI během public okna (`/gh-actions-public`, každé okno se souhlasem vlastníka).
13. **Otevřené:**
    - Mají boty (`hermes_bridge`) posílat `profile` se jménem? Doporučeno ano (P2, M).
    - Má se profil posílat i do business skupin, kde ho auditor dostane a zahodí? Doporučeno ano, jinak kolegové uvidí jen handle.
    - Sbalit zprávy blokovaného ve skupinách (P2)?
