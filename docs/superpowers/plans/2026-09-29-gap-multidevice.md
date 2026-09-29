# Proud D — Více zařízení, zálohy, GDPR UI (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů (sekce 3) a kontrakty X0 (sekce 4, finální znění v `2026-09-29-gap-contracts.md`). Nic nenasazuj, nic nepřepínej na public bez souhlasu vlastníka.

**Goal:** (1) Uživatel smí smazat účet i zařízení a stáhnout export svých dat přímo z aplikace (GDPR UI nad existujícími N09 endpointy). (2) Záloha je úplná (kanály, blokace, piny identit, nastavení, profil, historie hovorů), běží automaticky a jde obnovit na novém zařízení, včetně ověřeného testu obnovy. (3) Registrovaný účet může mít až 5 propojených zařízení. Zprávy chodí na všechna, odeslané zprávy se synchronizují a nové zařízení se propojí QR kódem. To všechno bez nového serverového lookupu, který by komukoli prozradil vazbu zařízení↔účet.

**Architecture:** Vlna 1 (GDPR UI a zálohy) je nezávislá na hubu i na změnách ostatních proudů. Vlna 2 (multi-device) zachovává **nezávislou X3DH identitu pro každé zařízení**. `SessionManager`, `peer_identity:<deviceId>` i `GroupMember = zařízení` proto zůstávají beze změny. Nahoru se přidává **podepsaný seznam zařízení**, který podepisuje primární zařízení existujícím Ed25519 klíčem `ct_signing_seed`. Seznam se kontaktům rozesílá **E2E** jako nový typ zprávy `device-list`. Server se tak o vazbách nedozví nic nového (vazbu už dnes zná z `AccountDevices`) a třetí strany nedostanou žádný endpoint, kde by si ji mohly vyhledat. Fan-out dělá klient. Hub dostane jedinou novou metodu: atomické odeslání jedné zprávy na N zařízení. Proudy M, C a G pracují už ve vlně 1 proti rozhraní `DeviceDirectory` / `DirectPayloadPlanner`, které X0 připraví v jednozařízeňové výchozí implementaci. Vlna 2 pak jen vymění implementaci.

**Tech Stack:** .NET 10 minimal API, EF Core/Npgsql, SignalR, Testcontainers (Postgres + Azurite), Flutter/Provider/drift, `calltype_core` (pure Dart), `cryptography` (Ed25519, AES-GCM), `package:archive` (gzip, [OVĚŘIT]).

---

## 0. Stav dnes (ověřeno v kódu)

| Oblast | Stav | Důkaz |
| --- | --- | --- |
| Kontakt = jedno zařízení | PK `Contacts.deviceId`. Přímá konverzace má `id` = deviceId protějšku. | `calltype_core/lib/storage/tables.dart:10-37`, `message_inbox_service.dart:70` |
| Odeslání 1:1 jde na jedno zařízení | `recipients = [conversationId]` a `sendMessage(envelopes.keys.single, …)` | `chat_controller.dart:236-237,300-304` |
| „Moje zpráva“ | `message.senderId == controller.myDeviceId` | `chat_screen.dart:334` |
| Hub | `OnlineDevices` mapuje DeviceId → **jedno** ConnectionId. Přímé zprávy chodí na jeden cíl, skupinové fan-outem s kontrolou členství a KB2. | `MessengerHub.cs:44,94-106,111-169` |
| Unikátnost fronty | `(RecipientId, SenderId, MessageId)`, takže stejné `messageId` pro víc příjemců nevadí | `AppDbContext.cs:151`, `MessageQueueService.cs:32-36` |
| Propojení zařízení s účtem | Jen `authKey` (heslo účtu) a jen zařízení samo za sebe. Endpoint pro odpojení **neexistuje**. Zařízení jde propojit i s více účty současně (PK je kompozitní). | `AccountEndpoints.cs:51,160-194`, `Models/AccountDevice.cs` |
| Seznam zařízení účtu | `GET /accounts/{id}/devices` smí volat jen zařízení propojené s účtem. Vrací `{deviceId, linkedAt}`. Klient ho nevolá. | `AccountEndpoints.cs:199-212,288` |
| Skupinový člen | Zařízení. `AddMember` smí volat jen admin. U business skupiny musí být cílové zařízení zapsané (enrollment) v organizaci. | `GroupEndpoints.cs:83-91,125-164` |
| Business enrollment | Je vázaný na zařízení (`OrgEnrollment(OrganizationId, DeviceId)`). | `OrganizationEndpoints.cs:247-265` |
| Obsah zálohy | Kontakty, konverzace a zprávy (JSON v1). Bez identity, sessions, kanálů, blokací a nastavení. | `backup_controller.dart:178-230` |
| Formát zálohy | `salt(16) ‖ nonce(12) ‖ ct ‖ tag(16)`, PBKDF2 600k, AES-256-GCM | `backup_controller.dart:237-256`, `backup_crypto.dart:33-40,96-130` |
| Obnova | Import validuje celý soubor a pak ho zapíše jednou transakcí s `insertOrIgnore`. Bere vždy nejnovější zálohu. | `backup_import.dart:5-87`, `backup_controller.dart:346-353` |
| Kvóty | 8 MiB na soubor, 3 zálohy na účet, **256 MiB na celou instalaci** (ne na účet). Klient má limity natvrdo v kódu. | `BackupLimitsOptions.cs:17-23`, `BackupStorageService.cs:~100-108`, `backup_controller.dart:17-18` |
| GDPR endpointy | Smazání zařízení (409 `device_is_auditor`), smazání účtu s `authKey` (409 `account_owns_organization`), export. **Klient nic z toho nevolá.** | `PrivacyEndpoints.cs:43-45,70-76,137-155,220-316`, `docs/security/data-subject-rights.md:3` |
| Odvození `authKey` | `sha256(utf8(passphrase))` jako hex řetězec. Server ho dekóduje jako base64. | `account_screen.dart:267`, `AccountEndpoints.cs:172` |
| Služby v `main.dart` | Vytvoří se jednou s `deviceId` načteným při startu. | `main.dart:41,63-80,87-94` |

### 0.1 Nálezy (chyby v současném kódu, opravuje tento proud)

1. **Obnova selže u každého, kdo má v historii `call-event`.** Import povoluje jen typy `text|image|file|audio|video` (`backup_import.dart:61-63`), ale aplikace ukládá i `call-event` (`call_event_sender.dart:81`, `message_inbox_service.dart:104`). Celá obnova pak spadne s `FormatException` a uživatel vidí jen „špatné heslo nebo soubor“. Opravuje D3.
2. **Po obnově na novém zařízení vypadají moje zprávy jako přijaté.** `senderId` obnovených zpráv je staré deviceId a porovnání `senderId == myDeviceId` (`chat_screen.dart:334`) je vyhodnotí jako cizí. Opravuje D3 (přepis odesílatele).
3. **Import zahodí `organizationId/organizationName` konverzace** (`backup_import.dart:45-51`). Business banner (KB1) se po obnově zobrazí až po backfillu. Opravuje D3.
4. **Plné úložiště instalace se hlásí jako „limit účtu“.** Obě situace vracejí stejné 409 `backup_quota_exceeded` (`BackupStorageService.cs:~102-108`, `BackupEndpoints.cs:87-88`). Klient radí „smažte starou zálohu“ (`backup_controller.dart:316-317`), i když problém není v účtu. Opravuje D5.
5. **Smazání účtu nevyžaduje MFA ani tam, kde ho má účet zapnuté** (`PrivacyEndpoints.cs:124-141`). Export navíc neobsahuje stav MFA. Opravuje D2 (podle rozhodnutí D-12).
6. **Zastaralý komentář:** `PrivacyEndpoints.cs:65-69` tvrdí, že neexistuje způsob, jak auditora přeřadit. `PUT /orgs/{id}/auditor` ale existuje (`OrganizationEndpoints.cs:48,291-307`). Opravuje D2.
7. (Pro proud S, jen poznámka) `authKey` je nesolený SHA-256 hesla účtu. Server tak drží hash, který lze lámat offline slovníkem. Kódování nesmí D měnit (rozbilo by přihlášení existujících účtů). Nová funkce `deriveAuthKey` (D1) ho přebírá **beze změny**.

---

## 1. Cíl a rozsah

| Priorita | In scope | Vlna |
| --- | --- | --- |
| **P1** | GDPR UI: export, smazání účtu, smazání zařízení a obsluha 409 stavů (D1, D2) | 1 |
| **P1** | Záloha v2: úplnější obsah, oprava nálezů 1–3, kompatibilita s v1 (D3). Kvóty per účet a limity ze serveru (D5). Obnova na novém zařízení a test obnovy (D6). | 1 |
| **P1** | Automatická záloha (D4) | 1 |
| **P2** | Multi-device pro registrované účty: server (D7), hub (D8), core (D9), propojení QR (D10), obrazovka zařízení (D11), integrace (D12) | 2 |
| **P2** | Dokumentace a přejímka (D13) | 1+2 |

**Out of scope:** multi-device pro anonymní zařízení (návrh je na něj připravený, viz D-1); přenos identity nebo ratchet stavu v záloze; plná média v záloze (jen náhledy, viz D-10); systémové úlohy na pozadí (workmanager/BGTask, viz D-8); synchronizace business konverzací na nezapsaná zařízení; skupinové hovory; bezpečnostní čísla (proud G/S). D jim jen dodá kořenový klíč seznamu.

---

## 2. Rozhodnutí k potvrzení vlastníkem

| ID | [ROZHODNUTÍ] | Doporučeno | Důsledek jiné volby |
| --- | --- | --- | --- |
| D-1 | Kdo smí mít víc zařízení | **Jen registrované účty** (spec :216 „Registered Only“). Formát seznamu zařízení na serveru nezávisí, takže se později dá rozšířit i na anonymní zařízení. | Anonymní multi-device: seznam by žil jen v E2E zprávách. Server by nic nevěděl (lepší soukromí), ale chyběl by arbitr pro odpojení a pro limit zařízení. Obnova je složitější, přibude +1 L balíček. |
| D-2 | Model identity | **Každé zařízení má nezávislou X3DH identitu a nad nimi stojí podepsaný seznam zařízení.** Krypto jádro, TOFU piny i skupiny zůstanou beze změny. | Přenos identity (sdílený identity key, Signal-like): nutný přepis `SessionManager` (adresa = účet.zařízení), přenos privátních klíčů mezi zařízeními a migrace všech pinů. Změny v `core/crypto/**` (proud S) plus riziko pro běžící sessions. |
| D-3 | Kořen důvěry seznamu | **Podpisový klíč primárního zařízení** (`ct_signing_seed`, `key_manager.dart:34-57`). Nevzniká nový klíč a odpojení zařízení nevyžaduje rotaci. | Sdílený účetní klíč přenesený na všechna zařízení: ztráta primárního zařízení nevadí, ale každé odpojení vynutí rotaci klíče, a tím varování o změně identity u všech kontaktů. |
| D-4 | Jak odesílatel zjistí zařízení příjemce | **Jen E2E:** zpráva `device-list` jde kontaktům, do anonymních skupin a vlastním zařízením. Každá odchozí zpráva nese `dlv` (verzi seznamu) a příjemce se zastaralou verzí si řekne o nový (`device-list-request`). **Žádný serverový lookup.** | Serverový endpoint „zařízení účtu k deviceId“ nebo Signal-like 409 „mismatched devices“ by vazbu zařízení↔účet prozradil každému, kdo má JWT a zná deviceId. Zamítnuto kvůli soukromí. |
| D-5 | Přenos historie při propojení | **Kontakty, konverzace, kanály, blokace, piny, nastavení a profil vždy. Zprávy volitelně** (žádné / posledních 90 dní) přes šifrovaný blob proudu M2. Bez M2 se historie nepřenese a uživatel ji může obnovit ze zálohy. | Bez historie: jednodušší, ale horší UX. Celá historie: narazí na limit velikosti blobu M2. |
| D-6 | Business konverzace a propojená zařízení | **Nesynchronizovat, nepřenášet při propojení a nepřidávat propojené zařízení do business skupin.** Enrollment zůstává per zařízení (KB1/KB2 beze změny). Do záloh business konverzace dál patří jako dnes. | Synchronizace business obsahu na nezapsané zařízení obchází politiku organizace (P1 `RequireBusinessConversations`, `GroupEndpoints.cs:143-159`). Vyloučení business konverzací ze zálohy je otevřená otázka pro právníka (sekce 8). |
| D-7 | Kde je heslo pro automatickou zálohu | **Heslo se neukládá nikdy.** Do OS secure storage (Keychain/Keystore/DPAPI) se uloží **odvozený** klíč (PBKDF2 výstup, 32 B) a salt. **Na webu je automatická záloha vypnutá**, protože secure storage na webu je fakticky localStorage. | Heslo zadávat při každé záloze: automatická záloha nejde. Uložit na webu: klíč by byl v prohlížeči prakticky v plaintextu. |
| D-8 | Kdy běží automatická záloha | **Oportunisticky v popředí:** při startu, při návratu do aplikace a každou hodinu, pokud uplynul interval (výchozí 24 h, volitelně 7 dní). Nepřidávají se nativní balíčky. | Plánovač na pozadí (`workmanager` + iOS BGTaskScheduler): nový balíček a nativní konfigurace (X0/P), přitom iOS běh stejně negarantuje. Návrh na P2. |
| D-9 | Identita v záloze | **Ne.** Obnova vytvoří novou identitu. Záloha nese piny kontaktů (`peer_identity:*`), aby obnovené zařízení poznalo změnu klíče kontaktu. | Identita v záloze: dvě aktivní instance téhož deviceId a staré ratchet stavy (replay, desync). Zamítnuto. |
| D-10 | Média v záloze | **Jen náhledy** (jsou v `body` zprávy `media`, ≤16 KiB, kontrakt a). Plná média se vejdou, jen dokud neexpiruje blob M2. | Plná média: vícedílné zálohy a kvóty ve stovkách MiB na účet. Rozhoduje O/vlastník podle ceny Blob. |
| D-11 | Kvóty záloh | **Nový limit per účet `MaxAccountBytes` (výchozí 24 MiB)**, samostatný kód `backup_storage_full` pro plnou instalaci a `GET /backups/limits`. Kapacitu instalace (`MaxTotalBytes`) nastaví vlastník. | Beze změny: 11 uživatelů na maximu zablokuje zálohy všem ostatním (nález 4). |
| D-12 | GDPR tvrdší kontroly | **Smazání účtu vyžaduje step-up MFA, pokud má účet MFA zapnuté. Export obsahuje stav MFA. Nový `GET /devices/{id}/export` pro anonymní zařízení.** | Bez step-upu stačí k nevratnému smazání heslo účtu a ukradený JWT, i když má uživatel MFA. Bez exportu zařízení nemá anonymní uživatel jak uplatnit právo na přístup. |
| D-13 | Co po smazání zařízení | **Nejdřív server (204/404), potom lokální wipe DB a secure storage a restart aplikace.** Web se znovu načte, Android a desktop aplikaci ukončí, iOS zobrazí blokující obrazovku. | Ponechat lokální data: zbyla by osiřelá historie bez identity. Wipe před voláním serveru: při chybě sítě by uživatel přišel o data a server by identitu dál držel. |
| D-14 | Limit zařízení a primární role | **Max. 5 zařízení na účet** (konfigurovatelné `Accounts:MaxLinkedDevices`). Nová zařízení přidává jen primární zařízení. Primární zařízení nejde odpojit, dokud jsou propojená jiná. Kterékoli propojené zařízení se může povýšit na primární s heslem účtu. | Přidávat smí kterékoli zařízení: vyžadovalo by sdílený klíč (D-3 varianta b). |

---

## 3. Vlastnictví souborů

### Výhradně vlastní (D)

**Vlna 1**
- Klient: `src/client/calltype/lib/features/backup/**` (existující i nové soubory), `lib/features/privacy/**` (nový), `lib/features/settings/account_screen.dart`, `lib/features/settings/account_*.dart` (nové).
- Core: `src/client/calltype_core/lib/network/backup_api.dart` (existující extension), `calltype_core/lib/network/privacy_api.dart` (nový).
- Server: `Endpoints/PrivacyEndpoints.cs`, `Endpoints/BackupEndpoints.cs`, `Services/BackupStorageService.cs`, `Configuration/BackupLimitsOptions.cs`, sekce `BackupLimits` v `appsettings.json` (jen tato sekce).
- Testy: `CallType.Api.Tests/Endpoints/{PrivacyEndpointsTests,BackupEndpointsTests}.cs`, `Services/BackupStorageServiceTests.cs`, `calltype/test/features/{backup,privacy,settings}/**`.
- Dokumentace: `docs/acceptance/multidevice-backup-gdpr.md` (nový).

**Vlna 2** (navíc)
- Server: `Hubs/MessengerHub.cs` (podle `paralelni.md`, ve vlně 2 patří D), `Endpoints/AccountEndpoints.cs`, `Services/AccountLinkService.cs` (nový), `Configuration/AccountOptions.cs` (nový), migrace vlny 2 v rozsahu entit ze sekce 4.2 (pokud ji nepíše koordinátor).
- Testy: `CallType.Api.Tests/Endpoints/LinkedDeviceEndpointsTests.cs`, `Hubs/MultiDeviceHubTests.cs` (nové).
- Core: `calltype_core/lib/devices/**` kromě `device_directory.dart` (ten vytvoří X0, D ve vlně 2 jen **přidává** implementace do nových souborů), `calltype_core/lib/network/linked_devices_api.dart` (nový), `calltype_core/test/devices/**`.
- Klient: `lib/features/devices/**` (nový).
- **Převzetí těla metody** `SignalRClient.sendDirectFanout` (signaturu zmrazí X0, tělo ve vlně 2 přepíše D).

### Jen připisuje (horké soubory)
- `lib/app/router.dart`: routy `/settings/privacy` (v1), `/settings/devices`, `/settings/devices/link`, `/link-device` (v2). Úprava redirectu `/settings/backup` jen přidáním větve `?next=restore`.
- `lib/main.dart`: vytvoření a `start()` `AutoBackupService` (v1). Ve v2 výměna `SingleDeviceDirectory` → `AccountDeviceDirectory` (jeden řádek, koordinátor merguje) a registrace inbound handlerů.
- `lib/features/settings/settings_screen.dart`: dlaždice „Soukromí a data“ (v1) a „Propojená zařízení“ (v2).
- `lib/l10n/app_*.arb`: nové klíče s prefixem **`md`** ve všech 19 jazycích. Existující klíče `backup*` a `account*` smí D jen přeformulovat.
- `calltype_core/lib/network/{api_client,signalr_client}.dart`: jen nové metody.
- `lib/core/storage/secure_storage.dart`: jen nové metody (sekce 4.1 bod 7).
- `lib/features/onboarding/onboarding_screen.dart`: jedno tlačítko „Mám účet / obnovit ze zálohy“ (D6). Soubor v `paralelni.md` nikomu nepatří, **potvrdí koordinátor**.
- `docs/acceptance/matrix.md`: nové řádky `Q01-D*`.
- `Endpoints/GroupEndpoints.cs` (vlna 2): jedna nová routa a handler `JoinLinkedDevice` na konci souboru. Stávající kód se nemění.

### Jen čte
`message_inbox_service.dart`, `chat_controller.dart`, `chat_screen.dart` (M); `calltype_core/lib/crypto/**` (S); `webrtc_manager.dart` (C); `calltype_core/lib/storage/{tables,database}.dart` (X0); `features/organization/mfa_flow.dart` (`runMfaStepUpFlow`, použije se pro step-up); `OrganizationEndpoints.cs`, `GroupEndpoints.cs` (kromě připsání), `docs/security/**` (S; texty pro ně D dodá jako požadavek, viz sekce 5).

---

## 4. Požadavky na X0 (kontrakty)

### 4.1 Vlna 0 (pro vlnu 1, a aby M/C/G psali proti rozhraní už ve vlně 1)

1. **Drift schema v4** (`tables.dart`, `database.dart`, `schemaVersion 3→4`). D potřebuje:
   - Nová tabulka **`ContactDevices`**. Použije se až ve vlně 2, ale patří do v4, aby nevznikala v5:
     ```dart
     class ContactDevices extends Table {
       TextColumn get deviceId => text()();            // PK
       /// Contacts.deviceId (kotva přímé konverzace) NEBO rezervované 'self'
       /// pro vlastní zařízení. U členů skupin, kteří nejsou kontakty, je to
       /// primaryDeviceId jejich seznamu.
       TextColumn get contactId => text()();
       BlobColumn get identityKey => blob().nullable()();
       TextColumn get signingKey => text().nullable()();   // base64 Ed25519 pub
       TextColumn get name => text().nullable()();         // ze seznamu, max 64
       BoolColumn get isPrimary => boolean().withDefault(const Constant(false))();
       DateTimeColumn get addedAt => dateTime()();
       DateTimeColumn get removedAt => dateTime().nullable()(); // historické řádky se nemažou
       @override Set<Column> get primaryKey => {deviceId};
     }
     ```
     Index `contactId` (drift `@TableIndex(name: 'contact_devices_contact', columns: {#contactId})`).
   - `Contacts` + `deviceListVersion` (`IntColumn`, nullable) a `deviceListRoot` (`TextColumn`, nullable; pinnutý Ed25519 podpisový klíč primárního zařízení kontaktu).
   - Z koordinátorova návrhu b) D konzumuje (a zálohuje) `Contacts.{blocked, verifiedAt, identityKeyChangedAt, profileName, avatarPath, profileVersion}`, `Conversations.{mutedUntil, draft, pinnedAt, archivedAt}`, `Messages.{replyToId, editedAt, deletedAt, readAt, expiresAt}`, `Reactions`, `CallLog` a `AppSettings(key, value)`. **D si vyžaduje `AppSettings`** a konvenci klíčů: `profile.displayName`, `profile.avatarPath`, `profile.version` (G), `settings.*` (smí do zálohy), `local.*` (nikdy do zálohy).
   - `BackupState`: beze změny schématu. Rezervované prefixy klíčů pro D: `backup:*` (stav auto-zálohy) a `devices:*` (vlastní seznam, čekající propojení).
2. **Rozhraní multi-device v core**, soubor `calltype_core/lib/devices/device_directory.dart` (vytvoří X0 i s výchozí implementací):
   ```dart
   /// Kdo je "ta osoba" za deviceId a na která zařízení se má poslat přímá zpráva.
   /// Vlna 1: SingleDeviceDirectory (kontakt = jedno zařízení). Vlna 2: AccountDeviceDirectory (D).
   abstract interface class DeviceDirectory {
     /// Zařízení protějšku přímé konverzace [conversationId] (vč. kotvy). Nikdy prázdné.
     Future<List<String>> peerDevices(String conversationId);
     /// Všechna zařízení osoby, které patří [deviceId] (vč. něj). Pro receipts a hovory.
     Future<List<String>> devicesOfPeer(String deviceId);
     /// Moje OSTATNÍ aktivní zařízení (bez tohoto). Vlna 1: [].
     Future<List<String>> ownOtherDevices();
     /// Lokální id přímé konverzace pro příchozí zprávu od [senderDeviceId]. Vlna 1: senderDeviceId.
     Future<String> directConversationFor(String senderDeviceId);
     /// true = zpráva od [deviceId] je "moje" (toto zařízení, aktivní i historické vlastní zařízení).
     Future<bool> isOwnDevice(String deviceId);
     /// true jen pro AKTIVNÍ vlastní zařízení (jen od nich se přijímá `sync`).
     Future<bool> isActiveOwnDevice(String deviceId);
     Stream<void> get changes;
   }

   /// Rozloží jeden odchozí plaintext přímé zprávy na plaintext pro každé zařízení.
   abstract interface class DirectPayloadPlanner {
     /// Výsledek: deviceId -> plaintext JSON k zašifrování pro dané zařízení.
     /// Vlna 1: {conversationId: payloadJson} (při ownDevicesOnly == true prázdná mapa).
     Future<Map<String, String>> plan(String conversationId, String payloadJson, {bool ownDevicesOnly = false});
   }
   class SingleDeviceDirectory implements DeviceDirectory, DirectPayloadPlanner { /* myDeviceId + dotaz na ContactDevices(contactId='self') pro isOwnDevice */ }
   ```
   Poskytne se v `main.dart` jako `Provider<DeviceDirectory>` i `Provider<DirectPayloadPlanner>` (stejná instance).
3. **Povinné použití rozhraní v kódu M/C/G už ve vlně 1** (X0 upraví stávající místa, M/C/G je dodrží u nového kódu):
   - `chat_controller.dart:236-237,258-270,300-304`: přímé odeslání `planner.plan(...)` → zašifrovat každou položku (`_ensureSession` + `encryptMessage`) → uložit do outboxu `envelopes` (tvar `outbox:` už mapu zná) → `signalR.sendDirectFanout(envelopes, messageId: id)`.
   - `chat_screen.dart:334`: `isMine` = `senderId == myDeviceId || await directory.isOwnDevice(senderId)`. Výsledek cachovat v controlleru.
   - `message_inbox_service.dart:70`: `conversationId = groupId ?? await directory.directConversationFor(senderId)`. Dedup kontrola `:74-78` porovnává takto odvozené `conversationId`.
   - Receipts, reakce, úpravy a mazání (M) jdou přes `planner.plan` (sync na vlastní zařízení pak přijde zadarmo). Při vypnutých potvrzeních o přečtení M volá `plan(..., ownDevicesOnly: true)` s `receipt kind: read` (read-sync jen pro vlastní zařízení).
   - Hovory (C): offer jde na `directory.peerDevices(conversationId)` (vlna 1 = jedno zařízení), viz sekce 5.
4. **`SignalRClient.sendDirectFanout`**, nová metoda v `calltype_core/lib/network/signalr_client.dart`:
   ```dart
   /// Vlna 1: pro každou položku SendReliableMessage (stejné messageId).
   /// Vlna 2 (D): jedno volání SendReliableMultiDeviceMessage (atomicky), při
   /// "Method does not exist" fallback na smyčku (klient napřed před serverem).
   Future<void> sendDirectFanout(Map<String, String> envelopes, {required String messageId});
   ```
5. **Registr typů příchozích zpráv v inboxu** (X0 to zavádí kvůli pravidlu „neznámý typ → ack a ignorovat“). D potřebuje, aby šly registrovat handlery bez editace inboxu:
   ```dart
   class InboundContext {
     final String senderId, messageId, conversationId; final String? groupId;
     final DateTime createdAt; final bool fromOwnDevice; // true pro obsah rozbalený ze `sync`
     InboundContext copyWith({String? conversationId, bool? fromOwnDevice});
   }
   abstract interface class InboundTypeHandler {
     String get type;
     /// Běží UVNITŘ inbox transakce před ack. Vyhození výjimky = zpráva zůstane ve frontě.
     Future<Message?> handle(InboundContext ctx, Map<String, dynamic> payload);
   }
   class InboundDispatcher {
     void register(InboundTypeHandler h);
     Future<Message?> dispatch(InboundContext ctx, Map<String, dynamic> payload); // re-entrantní (sync)
     /// Hook pro metadata každé platné zprávy (D: pole `dlv`).
     void addPayloadObserver(Future<void> Function(InboundContext, Map<String, dynamic>) o);
   }
   ```
   Kontrakt pro M: handlery `text|file|media|...` při `ctx.fromOwnDevice == true` uloží zprávu se `senderId = ctx.senderId`, `status: 'sent'` a **nezvyšují `unreadCount`**. Handler `receipt kind: read` s `fromOwnDevice` nastaví `readAt` a `unreadCount = 0` pro zprávy ≤ `ref`.
6. **Rezervované typy zpráv proudu D** (JSON uvnitř Double Ratchet, obálka `{v:1, id, type, body, createdAt, groupId?}`, `body` vždy **string**):
   | `type` | `body` (JSON string) | Kam | Poznámka |
   | --- | --- | --- | --- |
   | `device-list` | `{"listJson":"<string>","sig":"<b64 Ed25519 64 B>"}` | přímé kontakty (ne boti), vlastní zařízení, **anonymní** skupiny | Nikdy do business skupin (D-6), takže archivátor ho nedostane a `AuditArchiveEndpoints.cs:48` se nemění |
   | `device-list-request` | `""` | přímo zařízení, které poslalo vyšší `dlv` | Odpověď max. 1× za hodinu na odesílatele |
   | `sync` | vnořený payload původní zprávy (celý JSON string) + pole obálky `syncKind:"sent"`, `to:{"deviceIds":[…],"handle":"CT-…"}` | jen vlastní zařízení | `id` obálky = `id` vnořené zprávy. Přijímá se jen od `isActiveOwnDevice` |
   | `provision` | viz D10 | jen nové zařízení při propojení | Přijímá se jen v režimu „čekám na propojení“ se shodným `secret` |
   Volitelné pole **`dlv`** (int, verze mého seznamu zařízení) smí nést každá přímá zpráva od multi-device uživatele. Starší klienti ho ignorují. Boti (`calltype_bot`, `jay_archiver`) všechny čtyři typy potvrdí a ignorují (obecné pravidlo X0). Žádná další úprava botů není potřeba.
7. **`SecureStorage`** (`lib/core/storage/secure_storage.dart`), jen nové metody (X0, nebo je D připíše ve vlně 1):
   `getBackupKey()/setBackupKey(String b64)/deleteBackupKey()` (klíč `ct_backup_key_v1`), `getBackupSalt()/setBackupSalt()` (`ct_backup_salt_v1`), `getAccountEmail()/setAccountEmail()` (`ct_account_email`, jen pro zobrazení), `clearAccount()` (smaže `ct_account_id`, `ct_account_email`, `ct_backup_key_v1`, `ct_backup_salt_v1`), `deleteAll()` (`FlutterSecureStorage.deleteAll()`).
8. **`KeyManager`** (`calltype_core/lib/crypto/key_manager.dart`, vlastník S), jen nové metody. Pokud je S nestihne do X0, dodá je X0:
   ```dart
   /// Podpis ct_signing_seed nad `domain ‖ 0x00 ‖ message`. Vrací base64 (64 B).
   Future<String> signDetached(String domain, List<int> message);
   Future<String> getSigningPublicKey(); // base64 32 B
   static Future<bool> verifyDetached(String domain, String signingKeyB64, List<int> message, String signatureB64);
   ```
   Doménové separátory D (nové, stávající `CallType-*` se nemění): `CallType-DeviceList-v1`, `CallType-LinkFingerprint-v1`.
9. **pubspec** (`src/client/calltype/pubspec.yaml`): `archive: ^4.0.0` **[OVĚŘIT verzi a API `GZipEncoder`/`GZipDecoder`]**. Je to čistý Dart, takže by měl fungovat na android/ios/web/windows/macos/linux **[OVĚŘIT]**. Nic dalšího: QR sken a zobrazení používají existující `mobile_scanner`/`qr_flutter` a ukládání souboru `file_picker` (už se tak používá v `chat_screen.dart:183-196`). `workmanager` **ne** (D-8).
10. **AndroidManifest / Info.plist / entitlements:** nic nového. Kamera už je (`AndroidManifest.xml:4`, `Info.plist:91`). Text `NSCameraUsageDescription` („Scan contact QR codes…“) by měl zmínit i propojení zařízení. Změnu textu udělá X0/P při sjednocení.
11. **Server X0 migrace (vlna 1):** **žádná entita pro D.** Změny kvót jsou jen konfigurace (D5).
12. **HTTP kontrakty vlny 1** (implementuje D, X0 je jen zapíše do `contracts.md`):
    - `GET /backups/limits` → 200 `{"maxFileBytes":8388608,"maxPerAccount":3,"maxAccountBytes":25165824}`. Vyžaduje JWT, limiter `api`, účet nepotřebuje.
    - `POST /backups/{accountId}` 409 rozlišuje `{"code":"backup_quota_exceeded"}` (účet: počet nebo bajty) a `{"code":"backup_storage_full"}` (instalace).
    - `DELETE /accounts/{accountId}` navíc 403 `{"code":"mfa_required"}`, pokud má účet `AccountMfa.Enabled` a token nenese platný step-up (`MfaAuthHelper.RequireStepUp`).
    - `GET /accounts/{accountId}/export` navíc `"mfa":{"enabled":bool,"confirmedAt":iso|null,"backupCodesRemaining":int}`.
    - `GET /devices/{deviceId}/export` (jen samo zařízení, jinak 403; 404) → viz D2.
13. **Prefix ARB klíčů:** `md` (např. `mdPrivacyTitle`, `mdAutoBackupSwitch`, `mdDevicesTitle`).

### 4.2 Migrace vlny 2 (jedna společná; D dodá entity, koordinátor/X0-W2 je sloučí)

- `AccountDevice.IsPrimary` (`bool`, NOT NULL, default `false`). Backfill: nejstarší `LinkedAt` v rámci účtu, při shodě menší `DeviceId`:
  ```sql
  UPDATE "AccountDevices" ad SET "IsPrimary" = TRUE
  FROM (SELECT DISTINCT ON ("AccountId") "AccountId", "DeviceId" FROM "AccountDevices"
        ORDER BY "AccountId", "LinkedAt", "DeviceId") f
  WHERE ad."AccountId" = f."AccountId" AND ad."DeviceId" = f."DeviceId";
  ```
  Částečný unikátní index `IX_AccountDevices_AccountId_Primary` na `AccountId` s filtrem `"IsPrimary"` (max. jedno primární zařízení na účet).
- Nová entita `AccountLinkToken`: `Id` (long, identity), `AccountId` (Guid, FK → Accounts, cascade), `TokenHash` (byte[32], unique), `IssuedByDeviceId` (Guid), `CreatedAt`, `ExpiresAt`, `UsedAt?`, `UsedByDeviceId?` (DateTimeOffset/Guid), index `AccountId`.
- `GroupMember.LinkedFromDeviceId` (Guid?, bez FK). Nastaví se jen při vstupu přes `POST /groups/{id}/members/linked`. Při odpojení zařízení se smažou právě tyto řádky.
- Konfigurace `Accounts` (`AccountOptions`): `MaxLinkedDevices = 5`, `LinkTokenTtlMinutes = 10`.

### 4.3 Hub vlny 2 (vlastník D)
`public async Task SendReliableMultiDeviceMessage(Guid messageId, Dictionary<Guid, string> encryptedPayloads)`. Událost `ReceiveMessage` se **nemění** (`{messageId, senderId, encryptedBody, createdAt, groupId:null}`). Chyby (`HubException` message): `invalid_recipient_count` (0 nebo >32), `sender_is_recipient`, `business_conversation_required`, stávající `Invalid encrypted payload size|encoding`.

---

## 5. Závislosti na jiných proudech

| Proud | Co D konzumuje / co od něj chce | Kontrakt |
| --- | --- | --- |
| X0 | Sekce 4.1 celá | `2026-09-29-gap-contracts.md` |
| M | Ve vlně 1 psát odesílání, receipts, reakce, úpravy a mazání přes `DirectPayloadPlanner` + `sendDirectFanout`, příchozí přes `InboundDispatcher` a `isMine` přes `DeviceDirectory`. Handlery respektují `ctx.fromOwnDevice` (4.1 bod 5). | 4.1 body 2–6 |
| M2 | Pro přenos historie (D10) a náhledy v záloze: `E2eAttachmentApi.upload(Uint8List ciphertext) → {blobId}`, `download(blobId) → Uint8List`, max. velikost a TTL. D šifruje sám (`BackupCrypto.encrypt` s náhodným 32 B klíčem). **Bez M2 D10 přenese jen snapshot bez zpráv.** | kontrakt c) + M2 plán |
| C / C2 | Offer jde na **všechna** `directory.peerDevices(conv)` se stejným `callId`. První `answer` vyhrává a ostatním zařízením jde `hangup` s `payload.reason = "answered_elsewhere"`. `reject` z libovolného zařízení ukončí hovor a ostatním jde `hangup` s `reason = "declined_elsewhere"`. Volající hlásí „nedostupný“ až když **všechna** cílová zařízení vrátí `unavailable` (resp. `pushed` podle kontraktu d). Business hovory (`BusinessCallSignal`) jdou jen na zapsané zařízení (beze změny). Ve vlně 1 C napíše smyčku přes `peerDevices` (1 prvek), ve vlně 2 to začne platit automaticky. | 4.1 bod 3, C plán |
| G | Profil v `AppSettings` (`profile.*`) kvůli záloze a provisioningu. Seskupení členů skupiny podle `ContactDevices.contactId` v info o skupině. Bezpečnostní čísla a UI změny klíče používají `Contacts.deviceListRoot` a `identityKeyChangedAt` (D je nastavuje při změně kořene seznamu). | 4.1 bod 1 |
| S | `KeyManager.signDetached/verifyDetached/getSigningPublicKey` (4.1 bod 8). Doplnění `docs/security/crypto-baseline.md` (podpis seznamu zařízení, otisk propojení; text dodá D v PR popisu) a `docs/security/data-subject-rights.md` (UI existuje, step-up, export zařízení; text dodá D). Po obnově na novou identitu uvidí kontakty změnu klíče. To řeší UI změny klíče u S/G. D jen zobrazí upozornění. | 4.1 bod 8 |
| N | Každé propojené zařízení registruje vlastní push token (beze změny). D nic dalšího nepotřebuje. | — |
| O | Kapacita Blob pro zálohy (`BackupLimits__MaxTotalBytes`, `__MaxAccountBytes`) a nastavení na betě. | D-11 |

Všechno jde naprogramovat proti stubům. D9 až D12 testují s falešným `E2eAttachmentApi` a s `SingleDeviceDirectory` ↔ `AccountDeviceDirectory` přes stejné rozhraní.

---

## 6. Balíčky práce

Paralelismus uvnitř proudu. **Vlna 1:** D1 ∥ D2 ∥ D3 ∥ D5, po D3 pak D4 ∥ D6. **Vlna 2:** D7 ∥ D8 ∥ D9, potom D10 ∥ D11, potom D12. D13 průběžně.

Ověření: klientské testy (`flutter test`, `dart test`) běží lokálně bez Dockeru. Serverové integrační testy potřebují Docker (Testcontainers Postgres + Azurite). Když lokálně Docker neběží, spustí se v hosted CI v public okně (`/gh-actions-public`, vždy se souhlasem vlastníka). V PR se uvede odkaz na run. „Zelené bez spuštění“ se nevykazuje.

---

### D1 — Obrazovka „Soukromí a data“ (GDPR UI) · M · vlna 1

**Cíl:** export, smazání účtu, smazání zařízení a srozumitelné 409/403 stavy.

**Soubory:**
- `lib/features/privacy/privacy_screen.dart`, `privacy_controller.dart`, `local_data_wiper.dart`, `app_restart.dart` (conditional import `app_restart_io.dart` / `app_restart_web.dart`).
- `lib/features/settings/account_credentials.dart`: `String deriveAuthKey(String passphrase) => sha256.convert(utf8.encode(passphrase)).toString();`. Přesun z `account_screen.dart:267` **bez změny kódování** (komentář PROČ: tak je zaregistrovaný každý existující účet).
- `calltype_core/lib/network/privacy_api.dart`:
  ```dart
  extension PrivacyApi on ApiClient {
    Future<Uint8List> exportAccount(String accountId);          // GET, ResponseType.bytes (uložit 1:1)
    Future<Uint8List> exportDevice(String deviceId);            // GET /devices/{id}/export (D2)
    Future<void> deleteAccount(String accountId, String authKey); // DELETE s tělem {"authKey":…}
    Future<void> deleteDevice(String deviceId);                 // DELETE /devices/{id}
  }
  ```
- `router.dart` (připsat `GoRoute(path: 'privacy', …)` pod `/settings`), `settings_screen.dart` (dlaždice), `account_screen.dart` (po přihlášení uložit `setAccountEmail`).

**Kroky:**
1. `PrivacyController extends ChangeNotifier` se stavy `idle|working|done|error` a `enum PrivacyError { wrongPassphrase, mfaRequired, ownsOrganization, deviceIsAuditor, sessionExpired, network, requestFailed }`. Mapování: 403 s `code == mfa_required` → mfaRequired, jinak 403 → wrongPassphrase (u mazání účtu). 409 `account_owns_organization` → ownsOrganization. 409 `device_is_auditor` → deviceIsAuditor. 401 → sessionExpired. `null` status → network. Lokalizované texty mapuje funkce `privacyErrorMessage(l10n, c)` (vzor `backupErrorMessage`, `backup_controller.dart:82-102`).
2. **Export:** tlačítko „Stáhnout data“ je aktivní pro účet (`getAccountId() != null`) i pro zařízení (vždy). Uložení přes `FilePicker.saveFile(fileName: 'jay-export-<yyyyMMdd>.json', bytes: …)`. Na webu [OVĚŘIT], že `file_picker 12` spustí stažení, jinak fallback `share_plus`. Pod tlačítkem je vysvětlení: server nezná obsah zpráv a zprávy na zařízení nejsou součástí exportu.
3. **Smazání účtu:** dialog s vysvětlením (nevratné; smažou se zálohy a vlastněné kanály; zařízení zůstanou anonymní; chaty na zařízení zůstanou), pole pro heslo účtu a checkbox „Rozumím“. Volání `withMfa(() => api.deleteAccount(id, deriveAuthKey(p)), () => runMfaStepUpFlow(context, api, id))` (`mfa_api.dart:117`, `features/organization/mfa_flow.dart`). Po 204: `secureStorage.clearAccount()` a smazání `backup:*` klíčů v `BackupState`. Na 409 `ownsOrganization` se zobrazí text „Nejdřív předejte nebo zrušte organizaci“ (převod vlastnictví zatím neexistuje, text to musí poctivě říct).
4. **Smazání zařízení:** dialog (nevratné; kontakty vás přestanou zastihnout; ztratíte členství ve skupinách a čekající zprávy; data v tomto zařízení se vymažou). Pokud je zařízení propojené s účtem, nabídne se nejdřív „Smazat i účet?“ (volitelný krok 3). Pořadí je **server první**: `deleteDevice(me)`. Na 204 nebo 404 následuje `LocalDataWiper.wipe()` a pak `AppRestart.restart()`. Na 409 `device_is_auditor` se zobrazí text „Toto zařízení je archivní (auditní) zařízení organizace. Správce musí nejdřív určit jiné“ (endpoint `PUT /orgs/{id}/auditor` existuje).
5. `LocalDataWiper.wipe()`: `signalRClient.disconnect()`. Pak v jedné transakci `for (final t in db.allTables) await db.delete(t).go();` a nakonec `secureStorage.deleteAll()`. Komentář PROČ: řádky se mažou v transakci, protože na webu soubor DB nejde jednoduše smazat a služby v `main.dart` drží otevřené spojení.
6. `AppRestart.restart()`: web `window.location.reload()` přes `package:web` **[OVĚŘIT dostupnost, jinak `dart:html` v conditional importu]**, Android `SystemNavigator.pop()`, Windows/macOS/Linux `exit(0)`, iOS blokující obrazovka „Data smazána, zavřete aplikaci“ (Apple zakazuje programové ukončení). Komentář PROČ: služby v `main.dart:63-94` drží `deviceId` ze startu.

**Testy:**
- Unit: `LocalDataWiper` vyprázdní všechny tabulky in-memory DB a `InMemorySecureStorage` (`test/helpers/test_device.dart:70`).
- Widget (`localizedApp`, Dio interceptor jako v `backup_controller_test.dart:43-60`): export 200 volá uložení; smazání účtu 204, 403, 403 `mfa_required` (prompt se zavolá jednou), 409 org; smazání zařízení 204 (wipe zavolán), 404 (wipe zavolán), 409 auditor (wipe **nezavolán**), síťová chyba (wipe nezavolán).
- l10n guard (`test/l10n/**`) zelený, `build/l10n_untranslated.json == {}`.

**Přijetí:** všechny tři akce jsou dosažitelné z Nastavení. Žádný lokální wipe neproběhne bez 204/404 ze serveru. Texty jsou v 19 jazycích. Bezpečnostní význam („nevratné“) zůstává v každém jazyce.

---

### D2 — Serverové zpřísnění GDPR · S · vlna 1 (podle D-12)

**Soubory:** `Endpoints/PrivacyEndpoints.cs`, `CallType.Api.Tests/Endpoints/PrivacyEndpointsTests.cs`.

**Kroky:**
1. `DeleteAccount` (`:124`): přidat parametr `TimeProvider clock`. Po úspěšné kontrole `authKey` (`:137-141`) a **před** kontrolou organizace: `if (await db.AccountMfas.AnyAsync(m => m.AccountId == accountId && m.Enabled, ct) && MfaAuthHelper.RequireStepUp(user, accountId, clock) is { } denied) return denied;`. Komentář PROČ: nevratná akce, a MFA uživatel zapnul právě proto, aby heslo samo nestačilo.
2. `ExportAccount` (`:220`): přidat `mfa = new { enabled, confirmedAt, backupCodesRemaining = count(AccountMfaBackupCodes where UsedAt == null) }`. Pro účet bez MFA řádku `enabled = false`.
3. Nový `GET /devices/{deviceId:guid}/export` (`RequireAuthorization`, limiter `api`). Volat ho smí jen samo zařízení (`AccountEndpoints.CallerDeviceId(user) != deviceId` → 403), jinak 404. Tělo:
   ```json
   { "device": {"deviceId":"…","userHandle":"CT-…","createdAt":"…","lastSeenAt":"…","isBot":false,"hasPushToken":true,"pushPlatform":"fcm"},
     "oneTimePreKeysRemaining": 87,
     "linkedAccountIds": ["…"],
     "groups": [{"groupId":"…","role":"member","joinedAt":"…","organizationId":null}],
     "channelsFollowed": [{"channelId":"…"}], "channelsAdministered": [{"channelId":"…","addedAt":"…"}],
     "channelReportsFiled": [{"channelId":"…","postId":null,"reason":"…","createdAt":"…"}],
     "queuedMessages": {"note":"Counts only — …","count": 3},
     "organizations": null | {"enrollments":[{"organizationId":"…","enrolledAt":"…","revokedAt":null}]} }
   ```
4. Opravit zastaralý komentář `:65-69` (auditora lze přeřadit přes `PUT /orgs/{id}/auditor`). Do 409 `device_is_auditor` přidat `hint = "reassign_auditor"`.

**Testy (Testcontainers):** step-up je potřeba s MFA (enroll přes `IntegrationTestBase.EnrollAndVerifyMfaAsync`, bez step-up tokenu → 403 `mfa_required`, se step-upem → 204). Bez MFA stačí `authKey`. Export obsahuje `mfa`. Export zařízení: cizí zařízení 403, vlastní 200 s očekávanými klíči. Business mode on/off (sekce `organizations` null/objekt).

**Přijetí:** stávající testy N09 zůstanou zelené a nové projdou v CI.

---

### D3 — Formát zálohy v2 a úplný obsah · M · vlna 1

**Cíl:** záloha obsahuje všechno kromě identity, sessions a čistě lokálních věcí. Opravuje nálezy 1–3 a obnoví zálohy v1.

**Soubory (nové v `lib/features/backup/`):**
- `backup_format.dart`: kontejner.
  ```
  v2:  "JAYB" (4 B) ‖ 0x02 (verze) ‖ flags (1 B; bit0 = gzip) ‖ salt (16 B) ‖ BackupCrypto.encrypt(...) = nonce(12) ‖ ct ‖ tag(16)
  v1:  salt (16 B) ‖ nonce(12) ‖ ct ‖ tag(16)            (bez hlavičky, dnešní stav)
  ```
  API: `Uint8List seal({required Uint8List key, required Uint8List salt, required Uint8List plaintextJson})` a `Future<({int version, Uint8List json})> open(Uint8List blob, Future<Uint8List> Function(Uint8List salt) keyFor)`. Detekce: prefix `JAYB` + verze 2 → v2. Jinak nebo při selhání dešifrování v2 se zkusí v1 (šance 2⁻³², že v1 salt začíná `JAYB`; komentář PROČ). Hlavička není v AAD, proto plaintext v2 nese `"format":2` a po dešifrování se kontroluje. Gzip přes `package:archive` **[OVĚŘIT API]**.
- `backup_snapshot.dart`: `class BackupSnapshotWriter { Future<Map<String, Object?>> build(AppDatabase db, {required String sourceDeviceId, String? sourceHandle, bool includeMessages = true, bool excludeBusiness = false}); }` a `class BackupSnapshotReader { BackupImportPlan parse(Map<String, dynamic> json, {required String currentDeviceId}); Future<BackupImportResult> apply(AppDatabase db, BackupImportPlan plan); }`. Parse validuje všechno předem, apply zapisuje jednou transakcí `insertOrIgnore` (stávající disciplína, `backup_import.dart:76-86`).
- `backup_schema_v2.dart`: explicitní mapování sloupců pro každou tabulku a množiny `excludedColumns` (např. `messages.attachmentPath`, protože lokální cesta na jiném zařízení neplatí).
- `backup_import.dart`: zůstane jako tenká fasáda `importBackup(db, json, {currentDeviceId})`, která volá reader. Přidá se v1 cesta s opravami.

**JSON v2 (plaintext před gzipem):**
```json
{
  "format": 2, "createdAt": "2026-10-01T08:00:00Z", "schemaVersion": 4,
  "source": {"deviceId": "…", "userHandle": "CT-…"},
  "contacts":      [{"deviceId","userHandle","displayName","identityKey(b64)","verified","addedAt","isBot","blocked","verifiedAt","profileName","profileVersion"}],
  "contactDevices":[{"deviceId","contactId","identityKey","signingKey","name","isPrimary","addedAt","removedAt"}],
  "conversations": [{"id","type","title","lastMessageAt","unreadCount","organizationId","organizationName","mutedUntil","draft","pinnedAt","archivedAt"}],
  "messages":      [{"id","conversationId","senderId","body","type","status","createdAt","receivedAt","replyToId","editedAt","deletedAt","readAt"}],
  "reactions":     [{"messageId","reactorId","emoji","updatedAt"}],
  "callLog":       [{"callId","peerId","conversationId","direction","video","outcome","startedAt","connectedAt","endedAt"}],
  "channels":      [{"channelId","handle","name","description","role","isFollowing"}],
  "blockedChannels":[{"channelId","handle","name","blockedAt"}],
  "identityPins":  [{"peer":"<deviceId>","value":"<identityKey>|<signingKey>"}],
  "settings":      {"settings.<key>": "<value>"},
  "profile":       {"displayName": "…", "version": 3}
}
```
Přesné názvy sloupců v4 převezme D z finální schema X0. Tvar řádku = název sloupce v camelCase, DateTime jako ISO-8601 UTC a bloby jako base64. **Nezálohuje se:** `SignalSessions`, `BackupState` kromě `peer_identity:*` (vynechá se `outbox:*`, `consumed_prekey:*`, `backup:*`, `devices:*`), `ChannelPosts` (veřejné, stáhnou se znovu), `AppSettings` s prefixy `local.*` a `profile.avatarPath` (lokální cesta), secure storage.

**Pravidla importu:**
1. Typy zpráv: import přijme **každý** string typ. Neznámý typ se uloží tak, jak je (UI ho vykreslí jako „nepodporovaná zpráva“ podle pravidla X0). Tím mizí nález 1. Status mimo `sending|sent|delivered|read|failed` → `failed` a `sending` → `failed` (jako dnes).
2. **Přepis odesílatele (nález 2):** v2: `senderId == source.deviceId` → `currentDeviceId`. v1 heuristika: v přímé konverzaci je zpráva se `senderId != conversationId` moje, takže `currentDeviceId`. Ve skupinách v1 nejde poznat, zůstane beze změny (komentář PROČ).
3. `organizationId/Name` se obnoví (nález 3). `unreadCount` se obnoví jen u v2.
4. `identityPins` → `BackupState` `insertOrIgnore`. **Lokální pin má přednost** (TOFU: obnova nesmí přepsat klíč, kterému už zařízení věří).
5. Kontakty `insertOrIgnore`. Lokální záznam vyhrává.
6. Kanály: po commitu best-effort `apiClient.followChannel(id)` pro `isFollowing == true` (`api_client.dart:303`). Nové zařízení totiž na serveru není follower. Chyby se jen spočítají do výsledku.
7. Výsledek `BackupImportResult {contacts, conversations, messages, skipped, channelFollowFailures}` se zobrazí v UI (D6).

**Úprava `BackupController`:** vytvoření zálohy jde přes `BackupSnapshotWriter` a `seal`. `jsonEncode` + gzip běží v `compute` (na webu je to no-op, komentář PROČ). Před uploadem se porovná velikost s `limits.maxFileBytes` → `BackupError.fileTooLarge` (bez síťového volání). Třídní dokumentace (`:37-58`) se vrátí nad `BackupController` (dnes visí nad enumem).

**Testy:**
- Round-trip: naplnit všechny zálohované tabulky v4, udělat `build → seal → open → parse → apply` do čisté DB a porovnat mapované sloupce.
- **Guard test:** pro každou zálohovanou tabulku platí, že `table.$columns` = namapované ∪ `excludedColumns`. Nový sloupec bez rozhodnutí test shodí.
- v1 fixture: doslovný JSON dnešního formátu **včetně `call-event`** (regrese nálezu 1) se obnoví a vlastní zprávy mají `senderId == currentDeviceId`.
- Tamper testy: špatné heslo → `restoreFailed`, zkrácený soubor → `invalidFile`, hlavička verze 3 → `invalidFile`, přepnutý bit flags → dešifrování projde, ale kontrola `format` selže → `invalidFile`.
- Pin se nepřepíše. Business konverzace si ponechá `organizationId`.

**Přijetí:** zálohy v1 z bety jdou obnovit. v2 obsahuje všechno ze seznamu. Guard test hlídá budoucí sloupce.

---

### D4 — Automatická záloha · M · vlna 1 (po D3)

**Soubory:** `lib/features/backup/backup_service.dart` (logika bez UI vyjmutá z controlleru), `backup_key_store.dart`, `auto_backup_service.dart`, úpravy `backup_controller.dart` a `backup_settings_screen.dart`. `main.dart` jen připisuje.

**Kroky:**
1. `BackupService` obsahuje `Future<void> createAndUpload({required Uint8List key, required Uint8List salt})` a `Future<void> rotateIfFull(BackupLimits limits)`. Rotace: `listBackups`, a když `count >= maxPerAccount` nebo `sum + odhad > maxAccountBytes`, smaže nejstarší (podle `createdAt`). **Vždy ale nechá aspoň jednu zálohu.** Komentář PROČ: když upload potom selže, pořád zbývá poslední dobrá záloha.
2. `BackupKeyStore`: `Future<({Uint8List key, Uint8List salt})?> load()`, `Future<void> saveFromPassphrase(String p)` (nový salt, PBKDF2 přes `compute`, uloží `ct_backup_key_v1` + `ct_backup_salt_v1`) a `Future<void> forget()`. **Heslo se nikdy neukládá.** Komentář PROČ (D-7): odvozený klíč v Keychain/Keystore neoslabuje nic, co by útočník s odemčeným zařízením neměl stejně, protože lokální DB je bez SQLCipher.
3. `AutoBackupService({required AppDatabase db, required ApiClient api, required SecureStorage storage, required bool Function() isBusy, DateTime Function() now = DateTime.now, bool isWeb = kIsWeb})`:
   - `start()`: spustí `maybeRun()` při startu a při `AppLifecycleListener.onResume`, plus `Timer.periodic(1 h)`. `dispose()` je všechno zruší.
   - `maybeRun()` se ukončí bez akce, když platí: `isWeb` / chybí `accountId` / `backup:auto:enabled != '1'` / chybí klíč / `isBusy()` (probíhá hovor nebo ruční záloha) / `now - lastSuccessAt < interval` / po chybě `now - lastAttemptAt < min(interval, 6 h)`.
   - Stav v `BackupState`: `backup:auto:enabled` (`'1'|'0'`), `backup:auto:intervalHours` (`'24'|'168'`), `backup:lastSuccessAt`, `backup:lastAttemptAt` (ISO UTC), `backup:lastError` (`BackupError.name`), `backup:consecutiveFailures`.
   - Chyby `sessionExpired|forbidden` (účet odpojen nebo smazán) → vypnout auto-zálohu a zapsat chybu. `storageFull` se nikdy nerotuje.
4. UI `BackupSettingsScreen`: přepínač „Automatická záloha“ (na webu skrytý a nahrazený vysvětlením), interval (denně/týdně), „Poslední úspěšná záloha: …“, poslední chyba, „Zálohovat teď“ (s uloženým klíčem bez hesla), „Změnit heslo zálohy“ (varování: staré zálohy půjdou otevřít jen starým heslem) a „Zapomenout heslo“ (vypne auto-zálohu). Při zapnutí se heslo zadává dvakrát a hned proběhne první záloha.
5. `main.dart`: vytvořit `AutoBackupService(..., isBusy: () => webrtcManager.<aktivní hovor> || …)` **[OVĚŘIT název getteru stavu hovoru ve `WebRTCManager`, vlastník C]** a zavolat `start()`.

**Testy:** falešné `now` a `isWeb`. Záloha běží, když je splatná, a neběží, když není. Neběží bez klíče ani na webu. Rotace smaže nejstarší a nechá ≥1. `storageFull` nemaže. Backoff po chybě. `forget()` smaže klíč i salt. Widget test přepínače a na webu skrytí.

**Přijetí:** po zapnutí vznikne záloha při startu, pokud je splatná, a jinak ne. Heslo se nikde neukládá (test prohledá `InMemorySecureStorage` a `BackupState`, zda neobsahují heslo).

---

### D5 — Kvóty záloh a limity ze serveru · S · vlna 1

**Soubory:** `Configuration/BackupLimitsOptions.cs`, `Services/BackupStorageService.cs`, `Endpoints/BackupEndpoints.cs`, `appsettings.json` (sekce `BackupLimits`), testy, `calltype_core/lib/network/backup_api.dart`, `backup_controller.dart`.

**Kroky:**
1. `BackupLimitsOptions.MaxAccountBytes` (`long`, výchozí `24 * 1024 * 1024`) + `appsettings.json` `"MaxAccountBytes": 25165824`. Komentář PROČ: `MaxTotalBytes` je strop celé instalace, ne účtu.
2. `ReservationResult` doplnit o `StorageFull`. V `ReserveAsync` pod stávajícím advisory lockem: když `accountBytes + requested > MaxAccountBytes`, vrátit `QuotaExceeded`. Když se překročí instalační strop, vrátit `StorageFull` a zalogovat `LogWarning` (signál pro provoz, O).
3. `BackupEndpoints`: `StorageFull` → 409 `{error, code:"backup_storage_full"}`. Nová routa `GET /backups/limits` (`RequireAuthorization`, `api`) vrací `BackupLimitsDto(long MaxFileBytes, int MaxPerAccount, long MaxAccountBytes)`. Kolize s `/backups/{accountId:guid}` nevzniká díky constraintu `guid` (komentář).
4. Klient: `BackupApi.getBackupLimits() → BackupLimits`. Controller limity načte při vstupu, při chybě použije konstanty (`:17-18` zůstanou jako fallback a komentář „ponytail“ se aktualizuje). `BackupError.storageFull` a mapování 409 podle `code`.

**Testy:** `BackupStorageServiceTests` (limit bajtů účtu, `StorageFull` odlišené od `QuotaExceeded`, souběh dvou rezervací přes hranici bajtů → jedna vyhraje), `BackupEndpointsTests` (`/backups/limits` 200 i pro zařízení bez účtu, kódy 409), klientský unit test mapování.

---

### D6 — Obnova na novém zařízení a test obnovy · S–M · vlna 1 (po D3)

**Soubory:** `restore_screen.dart`, `backup_controller.dart`, `account_screen.dart`, `router.dart` (připsat), `onboarding_screen.dart` (jedno tlačítko, se souhlasem koordinátora).

**Kroky:**
1. `RestoreScreen`: seznam záloh (datum v lokále, velikost), výchozí je nejnovější, a `restore(passphrase, backupId)`. Po úspěchu souhrn `BackupImportResult` (D3). Když je zdrojové zařízení jiné než toto (`source.deviceId != me`), zobrazí se upozornění: „Vaše kontakty uvidí nový bezpečnostní klíč. Ve skupinách vás musí správce znovu přidat.“ (skupiny: nová identita není členem).
2. Onboarding: po dokončení registrace tlačítko „Mám účet: obnovit ze zálohy“ vede na `/settings/account?next=restore`. `AccountScreen` po úspěšném propojení s `next=restore` provede `context.go('/settings/backup/restore')`.
3. `docs/acceptance/multidevice-backup-gdpr.md`: postup ručního testu obnovy a řádky matice (sekce 7).

**Testy:** widget testy výběru zálohy a upozornění. Integrační klientský test: `TestDevice` A vytvoří zálohu (Dio mock drží blob), `TestDevice` B (jiné deviceId) ji obnoví a zkontroluje přepis odesílatele, piny a kanály (mock `followChannel` volán). Na serveru stávající `BackupEndpointsTests` upload/download zůstává zelený.

**Přijetí:** Q01-07/Q01-08 jsou připravené k ručnímu běhu. Automatický round-trip je zelený.

---

### D7 — Server: propojení, odpojení, primární role · M · vlna 2

**Soubory:** `Endpoints/AccountEndpoints.cs`, `Services/AccountLinkService.cs` (nový), `Configuration/AccountOptions.cs` (nový, registrace v `Program.cs` přes X0-W2/koordinátora), `Endpoints/GroupEndpoints.cs` (připsat), `Endpoints/PrivacyEndpoints.cs` (malá úprava), migrace podle 4.2, `LinkedDeviceEndpointsTests.cs`.

**Endpointy** (všechny `RequireAuthorization`; limiter `auth` pro mutace, `api` pro čtení; čas přes `TimeProvider`):

| Metoda a cesta | Request | Odpověď | Pravidla |
| --- | --- | --- | --- |
| `POST /accounts/{accountId}/link-tokens` | — | 201 `{"token":"<base64url 32 B>","expiresAt":"…"}` | Volající musí být propojený a **primární**, jinak 403. Počet propojených zařízení ≥ `MaxLinkedDevices` → 409 `device_limit_reached`. Ukládá se jen SHA-256 tokenu. Expirované tokeny účtu se při vydání smažou. |
| `POST /accounts/{accountId}/devices/{deviceId}` | `{"authKey"?: string, "linkToken"?: string}` (právě jedno) | 200 `{"message":…,"isPrimary":bool}` | Cesta `authKey` jako dnes (`:160-194`) + limit zařízení. Cesta `linkToken`: `UPDATE "AccountLinkTokens" SET "UsedAt"=@now,"UsedByDeviceId"=@d WHERE "TokenHash"=@h AND "AccountId"=@a AND "UsedAt" IS NULL AND "ExpiresAt">@now` musí vrátit 1 řádek, jinak 403 (nerozlišovat důvod). Zařízení propojené s **jiným** účtem → 409 `device_linked_elsewhere` (jen na token cestě; u `authKey` beze změny kvůli zpětné kompatibilitě, komentář PROČ). `IsPrimary = true`, pokud účet žádné jiné zařízení nemá. |
| `DELETE /accounts/{accountId}/devices/{deviceId}` | volitelně `{"authKey"?: string}` | 204 | Volající musí být propojený a zároveň platí jedno z: `caller == deviceId`, caller je primární, nebo platný `authKey`. Jinak 403. Cíl je primární a jsou propojená jiná zařízení → 409 `primary_has_linked_devices`. Cíl není propojený → 404. V transakci: smazat `AccountDevice` a smazat `GroupMembers WHERE DeviceId = @d AND LinkedFromDeviceId IS NOT NULL`. |
| `POST /accounts/{accountId}/primary` | `{"authKey"?: string, "deviceId"?: guid}` | 204 | a) Volající se povýší sám s platným `authKey` (obnova po ztrátě primárního zařízení). b) Současné primární zařízení předá roli `deviceId` (musí být propojené) bez `authKey`. Změna v transakci (unikátní index 4.2). |
| `GET /accounts/{accountId}/devices` | — | 200 `[{"deviceId","linkedAt","isPrimary","userHandle","lastSeenAt","isCurrent"}]` | Rozšíření `LinkedDeviceDto` (`:288`). Nová pole jsou aditivní. Přístup má jen propojené zařízení (`:205`), takže třetím stranám se vazba neprozradí. |
| `POST /groups/{groupId}/members/linked` (GroupEndpoints, připsat) | `{"deviceId":"…"}` | 200 | Volající musí být členem (libovolná role). Business skupina (`OrganizationId != null`) → 403 `{"code":"business_group"}` (D-6). Cíl není propojený se **stejným účtem** jako volající → 403. Už je člen → 409. ≥100 členů → 400. Řádek `Role="member"`, `LinkedFromDeviceId = caller`. Komentář PROČ: `AddMember` je jen pro adminy (`:90,130`), ale vlastní zařízení nesmí záviset na adminovi. |

`PrivacyEndpoints.DeleteDevice`: komentář, že smazání primárního zařízení nechá účet bez primárního zařízení. Klient to detekuje (D11) a nabídne povýšení s `authKey`. Server nepovyšuje automaticky, protože nový seznam musí podepsat klient.

**Testy (Testcontainers):** vydání tokenu jen primárním zařízením. Limit 5 → 409. Expirace (`FakeTimeProvider`). Token je jednorázový: dva souběžné `POST …/devices/{d}` se stejným tokenem → přesně jeden 200. Cizí účet → 403. Odpojení: sám sebe, primární jiného, neprimární jiného bez `authKey` 403 a s `authKey` 204, primární s ostatními 409. Povýšení (a) i (b). Seznam obsahuje nová pole. Linked join: anonymní skupina 200, business 403, zařízení cizího účtu 403. Odpojení smaže jen `LinkedFromDeviceId` řádky. Migrace: backfill `IsPrimary` a unikátní částečný index (vzor `DatabaseSchemaTests.cs`).

---

### D8 — Hub: `SendReliableMultiDeviceMessage` · S · vlna 2

**Soubory:** `Hubs/MessengerHub.cs` (nová metoda za `SendReliableGroupMessage`, `:169`), `Hubs/MultiDeviceHubTests.cs`, `calltype_core/lib/network/signalr_client.dart` (tělo `sendDirectFanout`).

**Implementace:**
```csharp
/// Jedna zpráva na víc zařízení (zařízení protějšku + moje ostatní zařízení) v JEDNÉ
/// transakci. Server nekontroluje úplnost seznamu příjemců: seznam zná jen klient
/// (E2E device-list), a kdyby ho server vynucoval, prozradil by vazbu zařízení↔účet
/// každému odesílateli (rozhodnutí D-4).
public async Task SendReliableMultiDeviceMessage(Guid messageId, Dictionary<Guid, string> encryptedPayloads)
{
    if (encryptedPayloads.Count is 0 or > 32) throw new HubException("invalid_recipient_count");
    var sender = GetCallerDeviceId() ?? throw new HubException("Invalid device identity");
    if (encryptedPayloads.ContainsKey(sender)) throw new HubException("sender_is_recipient");
    var ownDevices = await db.AccountDevices
        .Where(ad => db.AccountDevices.Any(s => s.DeviceId == sender && s.AccountId == ad.AccountId))
        .Select(ad => ad.DeviceId).ToListAsync(Context.ConnectionAborted);
    foreach (var r in encryptedPayloads.Keys.Where(r => !ownDevices.Contains(r)))
        if (!await communicationPolicy.IsAllowedAsync(sender, r, Context.ConnectionAborted))
            throw new HubException("business_conversation_required");
    var decoded = encryptedPayloads.ToDictionary(p => p.Key, p => DecodePayload(p.Value));
    // … transakce + EnqueueReliableAsync(groupId: null) + DeliverAsync, stejně jako :159-168
}
```
Vlastní zařízení jsou z P1 politiky vyjmutá (komentář PROČ: sync mezi vlastními zařízeními není komunikace dvou osob).

**Klient:** tělo `sendDirectFanout`: rozdělit mapu do dávek ≤ `_maxFanOutChars` (stejná logika jako `sendGroupMessage`, `signalr_client.dart:238-252`). Každá dávka je jedno `SendReliableMultiDeviceMessage`. Když server metodu nezná (chyba obsahuje `Method does not exist` **[OVĚŘIT přesný text SignalR]**), fallback na smyčku `SendReliableMessage`.

**Testy:** 3 příjemci se zařadí atomicky (chyba dekódování u třetího payloadu → žádný zápis). Opakování se stejným `messageId` nevytvoří duplikáty. Offline příjemce dostane zprávu po připojení. Org s `RequireBusinessConversations`: vlastní zařízení projde, cizí zapsané → `business_conversation_required`. 33 příjemců → chyba. Existující `MessengerHubTests` zůstanou zelené (včetně 3-argumentového `CallSignal`).

---

### D9 — Core: seznam zařízení, directory, distribuce, sync handlery · L · vlna 2

**Soubory (nové, `calltype_core/lib/devices/`):** `device_list.dart`, `account_device_directory.dart`, `device_list_service.dart`, `system_message_sender.dart`, `inbound_device_handlers.dart`. Testy v `calltype_core/test/devices/**` (helper `test/helpers/test_device.dart`).

**Model a podpis:**
```dart
class DeviceListEntry { final String deviceId, identityKey, signingKey; final String? name; final DateTime addedAt; }
class DeviceList {
  final int version;                 // monotónní, začíná 1
  final DateTime issuedAt;
  final String primaryDeviceId, primarySigningKey;
  final List<DeviceListEntry> devices; // obsahuje i primární zařízení, max AccountOptions.MaxLinkedDevices
  String toJson();                   // pevné pořadí klíčů; podepisuje se PŘESNĚ tento string
}
class SignedDeviceList { final String listJson, sig; }
Future<SignedDeviceList> signDeviceList(DeviceList l, KeyManager km);     // km.signDetached('CallType-DeviceList-v1', utf8(listJson))
Future<DeviceList> verifyDeviceList(SignedDeviceList s, {String? pinnedRoot, int? minVersionExclusive});
// Výjimky: DeviceListInvalid (podpis/formát), DeviceListRootChanged, DeviceListReplay
```
Kontroly: podpis `primarySigningKey`; primární zařízení je v `devices`; klíče jsou 32 B; `name` má ≤ 64 znaků; počet ≤ 5 (konstanta synchronizovaná s configem, komentář); `version > minVersionExclusive`.

**`AccountDeviceDirectory implements DeviceDirectory, DirectPayloadPlanner`** nad `ContactDevices`:
- `peerDevices(conv)`: aktivní řádky `contactId == conv`. Když žádné nejsou, `[conv]`.
- `ownOtherDevices()`: aktivní řádky `'self'` bez `myDeviceId`.
- `directConversationFor(sender)`: řádek `deviceId == sender` → jeho `contactId` (pro `'self'` vyhodí `StateError`, protože vlastní zařízení posílá přímo jen `sync`/`device-list`/`provision`, které konverzaci nepotřebují). Jinak `sender`.
- `isOwnDevice`: `myDeviceId` nebo jakýkoli řádek `'self'` (i odebraný, kvůli zobrazení historie). `isActiveOwnDevice`: jen `removedAt == null`.
- `plan(conv, payloadJson, {ownDevicesOnly})`: každé zařízení protějšku dostane `payloadJson` s přidaným `dlv` (když mám ≥2 zařízení). Každé moje ostatní zařízení dostane `{"v":1,"id":<id>,"type":"sync","syncKind":"sent","to":{"deviceIds":[…peers],"handle":<Contacts.userHandle>},"body":payloadJson,"createdAt":…}`. Konverzace s `organizationId != null` → **žádný sync** (D-6).

**`DeviceListService`** (vlastní seznam; podepisuje jen primární zařízení): uložený v `BackupState` `devices:own_list` = `{"listJson","sig"}`. Operace `addDevice(entry)`, `removeDevice(id)`, `rename(id, name)` → `version+1` → podpis → uložení → přepis řádků `ContactDevices('self')` (odebrané dostanou `removedAt`, nemažou se) → `distribute()`.
`distribute()` přes `SystemMessageSender` (vzor `CallEventSender`: `SessionManager` + `ensureSession` přes `getKeyBundle` + `sendDirectFanout` / `GroupCipher` + `sendGroupMessage`): přímé konverzace s ne-botem a `organizationId == null`, vlastní ostatní zařízení (i právě odebrané, aby se dozvědělo, že bylo odpojeno) a anonymní skupiny. Chyby u jednotlivých příjemců se logují a zbytek pokračuje. Opakování přes outbox: klíč `BackupState` `devices:pending_distribution:<recipient>` do úspěchu, zkouší se znovu po reconnectu.

**Inbound handlery** (registrují se do `InboundDispatcher`):
- `device-list`:
  - Přímo od kontaktu: odesílatel musí být v seznamu. `pinnedRoot = Contacts.deviceListRoot`. `DeviceListRootChanged` → `Contacts.identityKeyChangedAt = now`, seznam se neaplikuje a uloží se jako čekající do `devices:pending_list:<contact>` (UI S/G). Jinak přepsat `ContactDevices(contactId = kotva)` a nastavit `Contacts.deviceListVersion/Root`.
  - Od vlastního zařízení: kořen se musí shodovat s mým kořenem (nebo jsem teprve při propojení, viz D10). Přepsat `'self'`. **Pokud v seznamu nejsem** → stav „toto zařízení bylo odpojeno“ (`devices:unlinked = '1'`, UI D11).
  - Ve skupině: řádky s `contactId = list.primaryDeviceId`, pokud odesílatel není kontakt.
  - Handler nic nezobrazuje, vrací `null` (není to zpráva v chatu).
- `device-list-request`: když od stejného odesílatele nepřišla žádost poslední hodinu (`devices:dlr:<sender>` = ISO), poslat `device-list` jen jemu.
- Payload observer `dlv`: `dlv > Contacts.deviceListVersion` → poslat `device-list-request`.
- `sync`: `isActiveOwnDevice(senderId)`, jinak `FormatException` (zpráva zůstane nepotvrzená a do logu jde „sync od cizího zařízení“; komentář PROČ: jinak by kdokoli mohl podstrčit „moje“ zprávy). Pak rozbalit `body` (jeho `id` musí být stejné jako `id` obálky) a konverzaci určit podle prvního `to.deviceIds`, které má řádek v `ContactDevices`/`Contacts`. Pokud žádné takové není, založit kontakt: `getKeyBundle(to.deviceIds.first)` → `KeyManager.verifyIdentityBundle` → `Contacts(deviceId, userHandle: to.handle, identityKey)`. Nakonec `dispatch(ctx.copyWith(conversationId: …, fromOwnDevice: true), inner)`.

**Testy (pure Dart):** podpis a ověření, replay, změna kořene, limit a formát. Directory mapování. Planner: 2 zařízení protějšku a 1 vlastní → 3 plaintexty, sync obálka a business bez sync. Handlery se dvěma reálnými `SessionManager`y v paměti: sync od cizího zařízení se odmítne, sync od vlastního se uloží se `senderId` vlastního zařízení a `status 'sent'`, `device-list` bez odesílatele v seznamu se odmítne, odpojení nastaví `devices:unlinked`.

---

### D10 — Propojení nového zařízení (QR provisioning) · L · vlna 2 (po D7 + D9)

**Soubory:** `lib/features/devices/link_this_device_screen.dart` (nové zařízení B), `scan_link_screen.dart` (primární A), `link_controller.dart`, `calltype_core/lib/devices/provisioning.dart`, `calltype_core/lib/network/linked_devices_api.dart`:
```dart
extension LinkedDevicesApi on ApiClient {
  Future<({String token, DateTime expiresAt})> createLinkToken(String accountId);
  Future<bool> linkDeviceWithToken(String accountId, String deviceId, String linkToken); // → isPrimary
  Future<void> unlinkDevice(String accountId, String deviceId, {String? authKey});
  Future<void> makePrimary(String accountId, {String? authKey, String? deviceId});
  Future<List<LinkedDeviceDto>> listLinkedDevices(String accountId);
  Future<void> joinGroupAsLinkedDevice(String groupId, String deviceId);
}
```

**QR (a text ke zkopírování, pro Windows bez skeneru, `router.dart:152-156`):**
`ct-link:1:<deviceId>:<fp>:<secret>`. `fp` = prvních 16 B z `SHA-256("CallType-LinkFingerprint-v1\0" ‖ identityKey ‖ signingKey)`, `secret` = 16 náhodných B. Oboje v base64url bez paddingu. Schéma `ct-link:` se **neregistruje v OS**, parsuje ho jen vestavěný skener. Komentář PROČ: odkaz se nesmí dát otevřít z webu.

**Tok:**
1. **B** (zaregistrované anonymní zařízení, nepropojené s jiným účtem): „Propojit s existujícím účtem“ vygeneruje `secret`, uloží `devices:link_pending = {"secretSha256":…,"createdAt":…}` (platí 15 min i přes restart) a zobrazí QR a kód.
2. **A** (propojené a primární; neprimární zařízení dostane vysvětlení, D-14): naskenuje nebo vloží kód → `getKeyBundle(B)` → `verifyIdentityBundle` → spočítá `fp` a porovná v konstantním čase. **Nesoulad = konec** („bezpečnostní kontrola selhala“), protože server mohl podvrhnout klíč. Dialog: handle B, název zařízení (výchozí „Nové zařízení“, max 64) a historie (žádná / 90 dní, D-5).
3. A: `createLinkToken`. Snapshot se staví přes `BackupSnapshotWriter` (D3) s `includeMessages: false, excludeBusiness: true`. Historie (volitelná): `BackupSnapshotWriter(includeMessages: true, excludeBusiness: true)` omezená na 90 dní → gzip → `BackupCrypto.encrypt(randomKey)` → `E2eAttachmentApi.upload` (M2). Payload `provision`:
   ```json
   {"secret":"<b64url>","accountId":"…","linkToken":"<b64url>","email":"…",
    "deviceList":{"listJson":"…","sig":"…"},
    "snapshot":{ … v2 bez messages … } | null,
    "history": null | {"blobId":"…","key":"<b64 32 B>","sha256":"<hex>","size":123456,"format":2},
    "snapshotBlob": null | {"blobId":"…","key":"…","sha256":"…","size":…}}
   ```
   Snapshot jde inline, pokud je base64 obálka ≤ 600 KiB (limit hubu 768 KiB, `MessengerHub.cs:193`). Jinak jde do `snapshotBlob`. Bez M2 se použije inline bez historie, a když se nevejde, chyba „příliš mnoho kontaktů pro přímý přenos“.
4. A pošle payload přes normální X3DH session na B (`sendDirectFanout({B: env})`). Pak se každé 2 s po dobu 2 min dotazuje na `listLinkedDevices`, dokud se B neobjeví. Potom `DeviceListService.addDevice(B)` (distribuuje) a pro každou anonymní skupinu, kde je A členem, `joinGroupAsLinkedDevice(g, B)`. Obrazovka Hotovo.
5. **B** přijme `provision` jen s `devices:link_pending` a shodným `secret` (porovnání SHA-256 v konstantním čase) do 15 min. Jinak se zpráva potvrdí a zahodí (komentář PROČ: potvrdit, aby nevisela ve frontě). Ověří `deviceList` a jako kořen si pinne `primarySigningKey`. Aplikuje snapshot (D3 reader) a historii (stažení, kontrola SHA-256, dešifrování, gunzip, import). Pak `linkDeviceWithToken` → `setAccountId`/`setAccountEmail` → smaže `link_pending` → čeká na `device-list`, který obsahuje B → Hotovo.

**Testy:** parse a serializace QR, `fp` (známý vektor), odmítnutí špatného `secret`, expirovaného pendingu a podvrženého bundle. Core „loopback“ test dvou zařízení s falešným transportem a falešným `E2eAttachmentApi`: celý tok až po B s kontakty, konverzacemi a historií, bez business konverzací. Widget testy obou obrazovek (mock API): neprimární zařízení dostane vysvětlení, nesoulad `fp` zobrazí chybu.

---

### D11 — Obrazovka propojených zařízení · M · vlna 2 (po D7 + D9)

**Soubory:** `lib/features/devices/linked_devices_screen.dart`, `linked_devices_controller.dart`, `router.dart` (`/settings/devices`, `/settings/devices/link`, `/link-device`), `settings_screen.dart` (dlaždice), `account_screen.dart` (odkaz „Propojit toto zařízení QR kódem“).

**Obsah:** sloučení `GET /accounts/{id}/devices` a vlastního seznamu (názvy). Každý řádek ukazuje název, handle, štítky „primární“ a „toto zařízení“, „naposledy aktivní“ (relativně z `lastSeenAt`) a `linkedAt`. Akce:
- přejmenovat (jen primární zařízení, `DeviceListService.rename`),
- odpojit jiné zařízení (primární zařízení; neprimární s heslem účtu),
- odhlásit toto zařízení z účtu (`unlinkDevice(me)` → `clearAccount()` a smazání řádků `'self'`; chaty zůstanou),
- udělat primárním (heslo účtu),
- propojit nové zařízení (jen primární → `scan_link_screen`).

**Stavy:**
- Toto zařízení v serverovém seznamu není nebo platí `devices:unlinked == '1'` → banner „Toto zařízení bylo odpojeno od účtu“ + `clearAccount()`.
- Serverový seznam nemá primární zařízení → výzva „Nastavit toto zařízení jako primární“.
- Poznámka: „Firemní konverzace zůstávají jen na zařízeních zapsaných v organizaci“ (D-6).

Po odpojení jiného zařízení se volá `DeviceListService.removeDevice` (distribuce).

**Testy:** widget testy všech stavů a akcí (mock API a in-memory DB), včetně chybových 409 (`primary_has_linked_devices`, `device_limit_reached`).

---

### D12 — Integrace multi-device · M · vlna 2 (po D8–D11)

**Kroky:**
1. `main.dart`: `AccountDeviceDirectory` místo `SingleDeviceDirectory` (tatáž instance jako `DeviceDirectory` i `DirectPayloadPlanner`) a registrace handlerů D9 a D10.
2. Scénářové testy v `calltype_core/test/devices/multi_device_flow_test.dart` (falešný hub = in-memory router obálek podle `deviceId`, reální `SessionManager`y): osoby A (A1, A2) a B (B1, B2).
   - A1 pošle text → B1 a B2 ho mají, A2 ho má jako moji zprávu se `status 'sent'`.
   - B2 přečte → A1 a A2 mají `read` a B1 má `unreadCount 0`.
   - A1 odpojí A2 → B1 a B2 dostanou nový seznam a další zpráva na A2 nejde.
   - Business konverzace A1↔B1 → žádný sync na A2.
3. C2: předat fixture `DeviceDirectory` se 2 zařízeními pro testy „ring all / answered elsewhere“ (implementuje C2, D reviewuje).
4. G: info o skupině seskupí členy podle `ContactDevices.contactId` (implementuje G/D podle dohody. Pokud G nemá kapacitu, D připíše helper `groupMembersByPerson(db, members)` do `calltype_core/lib/devices/` a G ho zavolá).

**Přijetí:** celá sada testů app i core je zelená a stávající testy M/C/G prochází s `AccountDeviceDirectory` i `SingleDeviceDirectory`.

---

### D13 — Dokumentace a přejímka · S · vlna 1 + 2

- `docs/acceptance/multidevice-backup-gdpr.md` (nový): scénáře ze sekce 7, známé meze (D-4 zastaralý seznam až do `dlv`, boti vidí jen jedno zařízení, business jen na zapsaných zařízeních, obnova = nová identita).
- Řádky do `docs/acceptance/matrix.md`.
- Texty pro S: `crypto-baseline.md` (podpis seznamu `CallType-DeviceList-v1`, Ed25519 `ct_signing_seed`; otisk `CallType-LinkFingerprint-v1` SHA-256/16 B; `provision` přes X3DH session; záloha v2 kontejner `JAYB`, gzip, stejné PBKDF2/AES-GCM; uložený odvozený klíč auto-zálohy) a `data-subject-rights.md` (UI existuje, step-up, export zařízení).
- Pro koordinátora do `CLAUDE.md`: nové endpointy v tabulce API a poznámka „Multi-device: podepsaný seznam zařízení, žádný serverový lookup“.

---

## 7. Přejímka na zařízeních (řádky pro `docs/acceptance/matrix.md`)

Sloupce jako v matici (Web desktop / Web iOS Safari / Android / Windows / macOS / iOS nativní). Výchozí stav NOT_RUN (iOS BLOCKED², dokud neexistuje TestFlight).

| Scénář | Poznámka |
| --- | --- |
| Q01-D1 export dat účtu i zařízení: soubor se uloží a otevře | Web: stažení. Mobil: systémový dialog. |
| Q01-D2 smazání účtu: špatné heslo 403, s MFA prompt kódu, vlastník organizace 409, úspěch → zálohy zmizí a zařízení zůstane anonymní | Business jen na betě se zapnutým režimem |
| Q01-D3 smazání zařízení: auditor 409, úspěch → lokální data vymazána, restart, onboarding | iOS: blokující obrazovka |
| Q01-D4 automatická záloha: zapnout, zavřít, otevřít po intervalu → nová záloha. Na webu přepínač chybí | Posun času jen ručně (interval 24 h), nebo diagnostický build |
| Q01-D5 záloha v2 → jiné zařízení → obnova (kanály, blokace, piny, business banner, vlastní zprávy vpravo) | Rozšiřuje Q01-07 |
| Q01-D6 obnova zálohy v1 z bety (včetně `call-event`) | Regrese nálezu 1 |
| Q01-D7 propojení QR: telefon skenuje web/desktop, a obráceně s kódem ke zkopírování | Windows bez skeneru |
| Q01-D8 zpráva od kontaktu dorazí na všechna zařízení, odeslaná z A1 se objeví na A2 | Obě sítě online i offline |
| Q01-D9 odpojení zařízení: A2 ukáže „odpojeno“ a nové zprávy na něj nechodí | |
| Q01-D10 hovor vyzvání na všech zařízeních, přijetí na jednom ukončí vyzvánění jinde | Spolu s C2 |
| Q01-D11 business skupina: propojené nezapsané zařízení business zprávy nevidí | Beta s business režimem |

---

## 8. Rizika a otevřené otázky

1. **Zastaralý seznam zařízení u kontaktu** (D-4): dokud kontakt nedostane `device-list`, na nové zařízení zprávy nechodí. Mitigace je `dlv` + `device-list-request` a distribuce hned po propojení. Zbývá mez „kontakt offline déle než 30 dní“ (TTL fronty). Dokumentuje se.
2. **Boti** zpracují jen zařízení, které znají. Odpovědi bota přijdou jen na jedno zařízení (to, které botovi psalo). Přijatelné pro P2, zapsat do `bots-channels.md`.
3. **Obnova = nová identita** (D-9): kontakty uvidí změnu klíče. Záleží na UI proudu S/G („identity changed“, dnes `StateError`, `session_manager.dart:390-393`). Bez něj po obnově tiše selže odesílání od kontaktů k obnovenému uživateli. **Blokující pro užitečnost D6** a musí se sladit s S.
4. **Ztráta primárního zařízení** (D-3): povýšení jiného zařízení změní kořen seznamu, takže všichni kontakty uvidí „změnu identity“. To je poctivé, ale hlučné. Alternativa D-3b je v rozhodnutích.
5. **Business zálohy:** má zaměstnanec smět mít business konverzace v osobní cloudové záloze? Dnes je tam má. Otázka pro právníka a vlastníka. Technicky je připravené `excludeBusiness` (D3).
6. **Kapacita Blob** (D-11): plná média v zálohách jsou mimo rozsah. Bez nich po expiraci M2 blobu zůstanou po obnově jen náhledy. Uživatel to musí vědět (text `backupExplanation`).
7. **Web a secure storage:** auto-záloha je na webu vypnutá (D-7). Web může být propojené zařízení, ale jeho klíče jsou chráněné slaběji (plain SQLite a localStorage) a projeví se to v seznamu zařízení. Zvážit štítek „webové zařízení“ v D11.
8. **Frame limit hubu 1 MiB:** fan-out na 10 zařízení s velkou zprávou se rozdělí na dávky, které už nejsou atomické. Po M2 jsou těla malá, takže riziko je nízké.
9. **Souběh `authKey` a QR propojení:** zařízení propojené jen heslem (dnešní cesta) je na serveru propojené, ale není v podepsaném seznamu, takže zprávy na něj nechodí. UI (D11) ho musí označit „jen záloha – propojte QR kódem“. Otázka pro vlastníka: má cesta `authKey` na druhém zařízení zůstat?
10. **Docker:** serverové testy D2, D5, D7 a D8 vyžadují Testcontainers. Když lokálně neběží, ověří se v hosted CI v public okně se souhlasem vlastníka.
11. **[OVĚŘIT]** `package:archive` (verze, API, web), `file_picker.saveFile` na webu, `package:web` pro reload, text chyby SignalR pro neznámou metodu, getter aktivního hovoru ve `WebRTCManager`, přesná jména sloupců schema v4 od X0.
