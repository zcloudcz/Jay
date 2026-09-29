# Proud M — funkce zpráv (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů (oddíl 3) a kontrakty X0 (oddíl 4, finální znění v `2026-09-29-gap-contracts.md`). Nic nenasazuj, nic necommituj na `master` bez review. Nové typy zpráv se smějí začít **odesílat** až poté, co je na betě nasazená tolerance X0 (rozhodnutí R-10).

**Goal:** Dotáhnout chat na základní úroveň messengeru, aniž by server věděl něco nového o obsahu: potvrzení doručení a přečtení jako E2E zprávy (Signal styl), indikátor psaní v UI, odpověď/citace, přeposlání, úprava, smazání pro mě / pro všechny, reakce, koncepty, připnuté / archivované / ztlumené konverzace, jméno odesílatele ve skupině a (P2) vyhledávání a mizející zprávy. V business režimu má každý nový typ definované chování v `jay_archiver` a v append-only archivu.

**Architecture:** Všechny nové funkce jsou **řídicí zprávy uvnitř stávající Double Ratchet obálky** (`{v:1, id, type, body, groupId, …}`), posílané stejnou frontou (`QueuedMessage`, ACK po uložení) jako text. Server dostane jen dvě nové hub metody „bez push“ (X0), jinak se nemění. Klient se rozdělí na tři app-wide služby (vzor `MessageInboxService` a `CallEventSender`): **odesílání** (`MessageSender` + odchozí fronta řídicích zpráv s automatickým odesláním po reconnectu), **příjem** (registry handlerů podle `type`, kterou zavede X0) a **potvrzení** (`ReceiptScheduler` s dávkováním). UI (`chat_screen.dart`, `message_bubble.dart`, `message_input.dart`, `chat_list_*`) dostane extension pointy pro proud M2 (média). Drátový formát žije v `calltype_core/lib/messaging/`, aby ho sdílela aplikace, `calltype_bot` i `jay_archiver`.

**Tech Stack:** Flutter/Provider, drift (schema v4 od X0; FTS5 přes přibalený SQLite), pure Dart `calltype_core`, .NET 10 SignalR hub (jen X0), `CallType.Audit` archiv (jen whitelist `kind`, bez migrace audit DB).

**Zdroje:** `docs/gap-analysis-2026-09-29.md` §3, `docs/superpowers/plans/2026-09-29-gap-closure-paralelni.md`, `docs/superpowers/plans/2026-09-18-business-mode-contracts.md` (KB2, H1, E03-lite), `docs/superpowers/plans/2026-09-18-business-mode.md` (KB1–KB3).

**Značení balíčků:** balíčky tohoto proudu mají ID `M01`–`M12`. Dvojmístné číslo je tu schválně, aby se `M02` nepletl s proudem **M2** (média).

---

## 0. Stav kódu (ověřeno čtením, commit `4bd18ec`)

| Fakt | Důkaz |
| --- | --- |
| Přijímač přijme jen `text|file|call-event` a u čehokoli jiného hodí výjimku. Zpráva se pak nepotvrdí a server ji posílá znovu až do vypršení TTL (30 dní). | `src/client/calltype/lib/features/chat/message_inbox_service.dart:103-106`, `:163-166` |
| Validace obálky: `v==1`, `id==messageId`, `groupId==groupId` doručení, `body is String` | `message_inbox_service.dart:95-102` |
| Deduplikace probíhá jen přes řádek v `Messages` (`existing` → ack). Dešifrování běží v transakci. Když handler hodí výjimku, rollback vrátí i stav ratchetu. | `message_inbox_service.dart:71-81`, `:85-93` |
| ACK jde až po uložení | `message_inbox_service.dart:160-162` |
| Každá příchozí zpráva kromě `call-event` zvýší `unreadCount` | `message_inbox_service.dart:149-153` |
| Otevřený chat nuluje `unreadCount`. Lifecycle aplikace ani viditelnost se nekontrolují. | `features/chat/chat_controller.dart:38-41`, `:176-180` |
| Odesílání (outbox v `BackupState` `outbox:<id>`, šifrování, hub) je zabudované v `ChatController`, který má scope routy. Po chybě zůstane status `failed` a automatický retry chybí (ani po reconnectu). | `chat_controller.dart:182-329`, `:327` |
| Status odchozí zprávy v UI umí jen „Odesláno“ / „Selhalo, zkusit znovu“ / „Odesílá se“ | `features/chat/chat_screen.dart:385-408` |
| Skupina zobrazuje **UUID** odesílatele | `chat_screen.dart:350-359` |
| `MessageBubble(text, time, isMine)`: bez stavu, reakcí a citace. **Pozor:** soubor je v `lib/features/chat/`, ne v `lib/shared/widgets/`, jak uvádí tabulka proudů. | `features/chat/message_bubble.dart:10-25` |
| `MessageInput(onSend, onAttachment)`: tlačítko přílohy, bez konceptu, bez režimu odpovědi či úpravy | `features/chat/message_input.dart:15-20`, `:80-85` |
| Seznam konverzací: řazení jen podle `lastMessageAt`, podtitulek je „Šifrovaná konverzace“, bez náhledu zprávy | `features/chat_list/chat_list_controller.dart:31-36`, `chat_list_screen.dart:157-174` |
| Tabulka `Messages` má jen `id, conversationId, senderId, body, type, attachmentPath, status, createdAt, receivedAt`. `Conversations` nemá ztlumení, koncept, připnutí ani archiv. `schemaVersion => 3` | `calltype_core/lib/storage/tables.dart:45-117`, `database.dart:40` |
| Hub `TypingIndicator(conversationId)`: **plaintext**, jen online příjemcům, bez fronty. U 1:1 bez jakékoli kontroly (ani P1 policy, ani blokace). Ve skupině jde i auditorovi. | `src/server/CallType.Api/Hubs/MessengerHub.cs:203-227` |
| Klient: `SignalRClient.onTyping` (`{senderId, conversationId}`) a `sendTypingIndicator` existují, UI je nepoužívá | `calltype_core/lib/network/signalr_client.dart:92-94`, `:287-292` |
| Každá zpráva pro offline příjemce vyvolá push (data-only FCM), a to bez ohledu na typ | `MessengerHub.cs:175-189` (`:188`) |
| Unikátní klíč fronty je `(RecipientId, SenderId, MessageId)`. Každá řídicí zpráva proto potřebuje vlastní nové `id`. | `Services/MessageQueueService.cs:30-36` |
| KB2: každá zpráva do business skupiny musí mít obálku pro auditora, jinak `audit_recipient_missing`. Posílat podmnožině členů je povoleno. | `MessengerHub.cs:111-165` |
| Liveness auditora se počítá podle stáří nejstarší **nepotvrzené** skupinové zprávy auditorovi (výchozí limit 24 h). Když archiver nepotvrdí nový typ, firemní komunikace se za 24 h zablokuje (`auditor_unavailable`). | `business-mode-contracts.md:437-445`, `Services/AuditorLivenessService.cs` |
| `jay_archiver` hodí `Unsupported message type` u všeho kromě `text|file|call-event` a zprávu nepotvrdí | `src/bots/jay_archiver/lib/src/group_message_source.dart:149-156` |
| Archivní API: `AllowedKinds = ["text","attachment","call","call-metadata"]`. `details` je povolené jen pro `call-metadata` a je navázané na řetěz přes `ContentHash == SHA-256(details)`. `Kind` má max. 20 znaků. | `Endpoints/AuditArchiveEndpoints.cs:48`, `:79-104`, `CallType.Audit/Infrastructure/AuditDbContext.cs:96` |
| `calltype_bot` potvrdí a ignoruje vše, co není `text` (již tolerantní). Posílá typing každé 4 s, dokud handler běží. | `src/bots/calltype_bot/lib/calltype_bot.dart:321-325`, `:350-356` |
| Ratchet dovolí max. 256 přeskočených klíčů v jednom řetězci. **Zahozená** (nedoručená) E2E zpráva by se sem počítala. | `calltype_core/lib/crypto/session_manager.dart:62-70` |
| Reakce kanálů: 6 emoji (👍 ❤️ 😂 😮 😢 🙏) | `calltype_core/lib/network/channel_dtos.dart:15`, `Services/ChannelService.cs:56-64` |
| Web `sqlite3.wasm` obsahuje FTS5: `strings src/client/calltype/web/sqlite3.wasm \| grep -c fts5` → 37 výskytů (`fts5: parser stack overflow`, `no such fts5 table` …). Balíček `sqlite3` 3.3.2. | `web/sqlite3.wasm`, `pubspec.lock:1108-1115` |
| Import zálohy odmítne typ mimo `text|image|file|audio|video` | `features/backup/backup_import.dart:59-63` (proud D) |

---

## 1. Cíl a rozsah

| Priorita | Funkce | Balíček |
| --- | --- | --- |
| **P1** | Potvrzení doručení/přečtení (E2E `receipt`, dávkování, přepínač, skupiny, auditor, boti), fajfky v bublině | M01, M02, M03, M04, M09 |
| **P1** | Indikátor psaní v UI (hub zůstává plaintext, viz R-2) + přepínač | M05, M10 |
| **P1** | Odpověď / citace, úprava, smazání pro mě / pro všechny | M03, M06 |
| **P1** | Ztlumení konverzace (UI + `mutedUntil`; notifikaci podle něj zobrazuje proud N) | M07 |
| **P1** | Jméno odesílatele ve skupině místo UUID (fallback před profilem G) | M06 |
| **P1** | Koncepty (`Conversations.draft`), náhled poslední zprávy v seznamu | M06, M07 |
| **P1** | Automatické odeslání čekajících zpráv po reconnectu (dnes je nutné ručně klepnout na retry) | M02 |
| **P1** | Business: archivace `edit|delete|reaction`, `receipt` se jen potvrdí a zahodí | M09 (+ X0 server) |
| P2 | Reakce v chatu (analýza je řadí do P2; protokol je levný, proto M03/M06 ve vlně 1, pokud stačí kapacita) | M03, M06 |
| P2 | Přeposlání | M06 |
| P2 | Připnuté a archivované konverzace | M07 |
| P2 | Vyhledávání ve zprávách (FTS5) | M08 |
| P2 | Info o zprávě ve skupině („Přečetli 3/5“), historie úprav v UI | M04, M06 |
| P2 | Mizející zprávy: jen návrh (oddíl 6, M11), bez implementace | M11 |

**Mimo rozsah:** média a hlasovky (proud M2, sem jen extension pointy), notifikace, jejich zvuky a odpověď z notifikace (N; M dodá rozhraní), profil a blokace (G; M dodá háčky), synchronizace přečtení mezi zařízeními jednoho účtu (D, vlna 2), zmínky @, náhledy odkazů, GIFy a samolepky, online / naposledy viděn (R-12), mazání adminem skupiny.

---

## 2. Rozhodnutí k potvrzení vlastníkem

| ID | [ROZHODNUTÍ] | Doporučení | Důsledek jiné volby |
| --- | --- | --- | --- |
| R-1 | Potvrzení o přečtení: výchozí stav a reciprocita | **Zapnuto** ve výchozím stavu. Vypnutí platí i ve skupinách a je reciproční jako u Signalu (kdo nepotvrzuje, nevidí přečtení u druhých). Potvrzení o **doručení** se posílá vždy. | Výchozí „vypnuto“ znamená, že fajfky „přečteno“ skoro nikdo neuvidí. Bez reciprocity může uživatel sledovat ostatní a sám se neukázat. |
| R-2 | Indikátor psaní: ponechat plaintext hub, nebo převést do E2E | **Ponechat hub** (`TypingIndicator`) + přepínač „Posílat a zobrazovat indikátor psaní“ (výchozí zapnuto). Únik: server v reálném čase vidí, *kdo komu / do které skupiny píše*, i když zprávu nakonec neodešle. Vztah a časování odesílání server zná už z fronty (`QueuedMessage.SenderId/RecipientId/CreatedAt`), nový je tedy jen signál „píše, ale ještě neposlal“. | E2E typing potřebuje novou hub metodu „jen online, bez fronty“. Každý zahozený (nedoručený) typing ale spálí klíč v ratchetu. Při limitu 256 přeskočených klíčů (`session_manager.dart:65`) by aktivní psaní na offline protějšek po čase **znemožnilo dešifrovat další skutečnou zprávu**. Typing přes frontu zase plní DB a budí push. Obojí je dražší než zisk. |
| R-3 | Business: archivovat potvrzení o přečtení? | **Ne.** Archiver `receipt` potvrdí a zahodí. Záznam „kdy zaměstnanec četl“ je sledování chování, ne komunikace (§ 316 ZP, GDPR minimalizace) a řádově zvětšuje archiv. | Když ano: nový `kind: receipt` v archivu, nutná právní revize a text transparentnosti v banneru KB1. |
| R-4 | Úprava zprávy | Jen `text`, **do 24 h**, **max. 10 úprav**, štítek „upraveno“. Lokálně se drží historie verzí (`MessageRevisions`), UI „Historie úprav“ je P2. | 15 min (WhatsApp): méně zneužití, ale uživatelé chtějí opravovat i později. Bez historie: příjemce nemá doklad o původním znění. |
| R-5 | Smazání pro všechny | **Do 24 h** od odeslání. Tombstone „Zpráva byla smazána“. Dialog výslovně říká, že příjemci ji už mohli vidět a starší verze aplikace ji nemusí smazat. V business konverzaci navíc: „Zpráva zůstane v archivu organizace.“ | Bez limitu: mazání dávno přečtené historie mate protistranu. Bez upozornění na archiv: porušení ducha KB1 (transparentnost). |
| R-6 | Sada reakcí | **Stejných 6 jako kanály** (`channelReactionEmojis`). Přijímač je ale tolerantní (libovolný krátký emoji řetězec), takže pozdější plný picker nepotřebuje změnu protokolu. | Plný picker hned znamená nový balíček (X0) a větší plochu pro zneužití (dlouhé řetězce). |
| R-7 | „Tiché“ hub metody bez push pro řídicí zprávy | **Ano** (`SendQuietMessage` / `SendQuietGroupMessage`, X0). Server se tím dozví *třídu* zprávy (tichá = potvrzení / reakce / úprava / smazání), ne obsah. | Bez nich každé potvrzení o doručení probudí telefon push notifikací: baterie, a na iOS i throttling. Proud N by musel tiché zprávy filtrovat až po probuzení. |
| R-8 | Archivovaná konverzace a nová zpráva | Nová **obsahová** zpráva archivaci zruší, **pokud konverzace není ztlumená** (Signal). | „Archiv drží navždy“ (WhatsApp volba): uživatel přehlédne zprávy. |
| R-9 | Mizející zprávy | P2, **nikdy v business konverzacích** (organizace archivuje; mizení by bylo klamavé). Návrh je v M11. | Implementovat hned: rozsah +L a kolize s archivací. |
| R-10 | Rollout nových typů | **Dvoufázově.** Nejdřív na betu nasadit X0 (tolerance neznámých typů v app, `calltype_bot` i `jay_archiver`), teprve pak build, který nové typy posílá. | Obojí najednou: otevřené webové taby se starým JS a běžící archiver starší verze zprávy nepotvrdí. Archiver pak po 24 h spadne do `auditor_unavailable` a zablokuje firemní komunikaci. |
| R-11 | Vyhledávání | Lokální FTS5 index (plaintext na disku, stejná ochrana jako tabulka `Messages`, dokud nepřijde SQLCipher S2), tokenizer `unicode61 remove_diacritics 2` (hledání „prilis“ najde „příliš“). | Bez indexu: `LIKE` na tisících zpráv, pomalé a bez diakritické tolerance. |
| R-12 | Online / naposledy viděn | **Neimplementovat** (server by musel stav rozesílat, což je únik metadat). | Implementace = nový hub event + přepínač soukromí + review S. |

---

## 3. Vlastnictví souborů

Cesty aplikace jsou relativní k `src/client/calltype/`.

**Výhradně vlastní (vlna 1):**
- `lib/features/chat/**`. Stávající: `chat_controller.dart`, `chat_screen.dart`, `message_bubble.dart`, `message_input.dart`, `message_inbox_service.dart` (po refaktoru X0 přidává M jen handlery), `attachment.dart`. Nové: `message_sender.dart`, `control_outbox.dart`, `receipt_scheduler.dart`, `typing_controller.dart`, `handlers/*.dart`, `widgets/*.dart`, `search/*.dart`, `message_privacy_screen.dart`, `sender_label.dart`, `message_preview.dart`, `forward_sheet.dart`, `message_actions.dart`.
- `lib/features/chat_list/**`
- `test/features/chat/**`, `test/features/chat_list/**` (nový)
- `src/client/calltype_core/lib/messaging/control_messages.dart` (nový) + `calltype_core/test/messaging/**`
- `src/bots/jay_archiver/lib/src/group_message_source.dart`, `lib/src/archiver.dart` (jen mapování nových typů na `kind` + `details`, po X0), `test/signal_group_message_source_test.dart`, `test/archiver_test.dart`, `test/e2e/business_mode_e2e_test.dart` (jen rozšíření)
- `src/bots/calltype_bot/lib/calltype_bot.dart` (jen odesílání `receipt`), `test/**`

**Jen připisuje (horké soubory):**
- `lib/main.dart`: vytvoření `MessageSender`, `ControlOutbox`, `ReceiptScheduler`, `TypingController`, `ActiveConversation`, `SearchIndex` + providery.
- `lib/app/router.dart`: předání nových služeb do `ChatController` (stávající routa `/chats/:id`) a nová routa `/search`.
- `lib/features/settings/settings_screen.dart`: jedna `ListTile` „Soukromí zpráv“ → `MessagePrivacyScreen`.
- `lib/l10n/app_*.arb` (19 souborů): jen klíče s prefixem **`msg`**.
- `calltype_core/lib/network/api_client.dart`: nová metoda `getGroupMemberDetails` (oddíl 4.6).
- `calltype_core/lib/network/signalr_client.dart`: nic, tiché metody přidá X0.

**Jen čte:** `calltype_core/lib/storage/{tables,database}.dart` (X0), `Hubs/MessengerHub.cs` (X0 / C), `Endpoints/AuditArchiveEndpoints.cs` (X0), `features/contacts/**`, `features/groups/**`, `features/profile/**` (G), `features/organization/business_banner.dart`, `features/calls/call_event_sender.dart` (C), `features/backup/**` (D), `calltype_core/lib/crypto/**` (S).

**Kolize, které je třeba hlídat:** `ChatController` konstruuje router (`app/router.dart:118-135`). M tam jen **přidá** parametry konstruktoru. `CallEventSender` (C) má vlastní kopii outbox logiky. M ji nemění, ale automatické odeslání po reconnectu v M02 obslouží i jeho řádky `outbox:<id>` se statusem `sending` (vedlejší zlepšení, žádná změna souboru C).

---

## 4. Požadavky na X0 (kontrakty)

### 4.1 Vnitřní payload (drátový formát, zmrazit v `2026-09-29-gap-contracts.md`)

Obálka zůstává `{v:1, id, type, body, groupId, groupName, createdAt, …}`. **`body` je vždy `String`**, u řídicích typů `""` (kvůli stávající validaci `body is String`, `message_inbox_service.dart:98`). `id` je **vždy nové UUID** (unikátní klíč fronty). Cíl nese pole `ref`. `groupId` = skupina, do které patří cílová zpráva (null u 1:1). `groupName` je u řídicích typů vždy `null`: řídicí zpráva **nikdy nezakládá konverzaci**. `createdAt` = čas odesílatele, ISO-8601 UTC.

```jsonc
// receipt — jen původnímu odesílateli (+ auditorovi v business skupině, KB2)
{"v":1,"id":"<uuid>","type":"receipt","body":"","groupId":null,"groupName":null,
 "createdAt":"2026-10-01T10:00:00.000Z",
 "kind":"delivered",            // "delivered" | "read"  (read implikuje delivered)
 "ref":["<uuid>", "..."]}       // 1..100 id zpráv, všechny od příjemce tohoto receiptu, ze stejné konverzace

// reaction — všem členům konverzace; emoji "" = odebrat
{"v":1,"id":"<uuid>","type":"reaction","body":"","groupId":"<uuid>|null","groupName":null,
 "createdAt":"…","ref":"<uuid>","emoji":"👍"}

// edit — všem členům; body = nový text (jen cíl typu text)
{"v":1,"id":"<uuid>","type":"edit","body":"opravený text","groupId":…,"groupName":null,
 "createdAt":"…","ref":"<uuid>"}

// delete — "pro všechny"; všem členům
{"v":1,"id":"<uuid>","type":"delete","body":"","groupId":…,"groupName":null,
 "createdAt":"…","ref":"<uuid>"}

// volitelná pole obsahových typů text|file|media
{"type":"text","body":"…",
 "replyTo":{"id":"<uuid>","senderId":"<uuid>","preview":"≤100 znaků textu citované zprávy"},
 "forwarded":true,
 "expiresInSec":null}            // REZERVA (M11), dnes neposílat
```

**Pravidla přijímače** (implementuje M03, X0 je zapíše do kontraktu):
- `receipt`: `kind ∈ {delivered, read}`, `ref` je neprázdné pole UUID řetězců (max. 100). Aplikuje se jen na zprávy, kde `senderId == já` a `conversationId == groupId ?? senderId(receiptu)`. Neznámá id se tiše ignorují.
- `reaction`: `ref` je UUID, `emoji` má 0–64 UTF-8 bajtů a max. 16 runes, bez whitespace a řídicích znaků. Last-write-wins podle `createdAt` na `(ref, senderId)`. Cíl nemusí existovat (reakce se uloží, řádek bez cíle se ignoruje a smaže při úklidu).
- `edit`: cíl existuje, `target.senderId == senderId(editu)`, `target.conversationId == conversationId`, `target.type == 'text'`, `target.deletedAt == null`, `edit.createdAt - target.createdAt ≤ 24 h + 10 min` (časy odesílatele, jde o UX pravidlo, ne o bezpečnost), počet revizí < 10, `edit.createdAt > target.editedAt` (starší edit doručený pozdě se jen uloží do historie).
- `delete`: cíl existuje, stejný odesílatel i konverzace, `≤ 24 h + 10 min`. Idempotentní.
- **Chybně formovaná řídicí zpráva se potvrdí (ack) a zahodí** (zaloguje se jen id). Po úspěšném dešifrování ji opakování neopraví a bez ACK by se točila 30 dní. Obsahové typy si ponechávají dnešní „neack“ disciplínu jen pro selhání dešifrování.
- Řídicí typy **nezvyšují `unreadCount` ani `lastMessageAt`** a **neemitují** do `persistedMessages`.

### 4.2 Server (součást jedné EF migrace X0: **žádná** změna entit, jen hub a endpoint)

**X0-M-1: tiché odeslání (hub `MessengerHub.cs`, vlna 0, pak vlastník C):**
```csharp
// Identické s SendReliableMessage / SendReliableGroupMessage (stejná P1 policy,
// KB2, W2-F auditor_unavailable, stejné HubException kódy, stejná idempotence
// (Recipient, Sender, MessageId)), jen DeliverAsync(message, push: false).
public Task SendQuietMessage(Guid recipientDeviceId, Guid messageId, string encryptedBodyBase64);
public Task SendQuietGroupMessage(Guid groupId, Guid messageId, Dictionary<Guid, string> encryptedPayloads);
```
Implementace: stávající těla přesunout do `private Task SendDirectCoreAsync(..., bool push)` a `SendGroupCoreAsync(..., bool push)`. `DeliverAsync(QueuedMessage message, bool push = true)` při offline příjemci a `push == false` push nevolá. Doručení při připojení (`SendPendingAsync`) se nemění.
Klient (`signalr_client.dart`, jen přidání):
```dart
Future<void> sendQuietMessage(String recipientDeviceId, String encryptedBodyBase64, {required String messageId});
Future<void> sendQuietGroupMessage(String groupId, Map<String, String> encryptedPayloads, {required String messageId});
// Bez fallbacku rozdělení na volání po příjemcích: řídicí zprávy jsou malé (< 4 KiB na příjemce).
```
Testy (Testcontainers, `CallType.Api.Tests`): tichá zpráva offline příjemci je ve frontě a push se nevolá (`PushNotificationService` nahrazený test doublem v DI, **DB se nemockuje**). Business skupina bez auditorovy obálky → `audit_recipient_missing`. Stejné `messageId` podruhé = jeden řádek.

**X0-M-2: archivní kindy (`Endpoints/AuditArchiveEndpoints.cs`):**
- `AllowedKinds` += `"edit"`, `"delete"`, `"reaction"`.
- Pro tyto tři je `details` **povinné** a má přesně klíče `{"ref","bodyHash"}`: `ref` = UUID řetězec, `bodyHash` = 64 hex znaků (SHA-256 UTF-8 nového textu / emoji) pro `edit|reaction`, `null` pro `delete`, max. 256 znaků. Kontrola `ContentHash == SHA-256(UTF8(details))` (stejné vázání do řetězu jako `call-metadata`, `ComputeHash` se **nemění**). Chyby: `422 invalid_ref_details`, `422 details_hash_mismatch`. Pro `text|attachment|call` dál `details_not_allowed`.
- Opravit text chyby na `:80` (vyjmenuje všechny kindy).
- **Žádná migrace audit DB:** `Kind` má `HasMaxLength(20)` (`AuditDbContext.cs:96`) a `DetailsJson` už existuje.
- Testy (Testcontainers): každý kind přijat, špatný tvar `details` → 422, `delete` s ne-null `bodyHash` → 422, idempotence podle `MessageId`, řetěz ověřitelný.
- Doplnit sekci do `business-mode-contracts.md` (za H1).

**X0-M-3 (volitelné, vlna 2, vlastník hubu D):** zpevnit `TypingIndicator`: u 1:1 volat `communicationPolicy.IsAllowedAsync` (dnes P1 obchází), rate limit ≤ 1 událost / 2 s na (odesílatel, konverzace), auditorovi neposílat (`Role == "auditor"`). Nic z toho M nepotřebuje k práci.

**X0-M-4 (volitelné, patří G nebo X0):** `GET /groups/{id}/members` rozšířit `GroupMemberDto` o `userHandle` a `isBot` (aditivně). Jmenovka nečlena kontaktů pak může ukázat `CT-XXXX-XXXX` místo zkráceného UUID (oddíl 6, M06).

### 4.3 Klientská schema v4 (`calltype_core/lib/storage/tables.dart`, `database.dart`, `schemaVersion 3→4`)

**`Messages` (nové sloupce):**

| Sloupec (Dart / SQL) | Typ | Účel |
| --- | --- | --- |
| `replyToId` / `reply_to_id` | text null | id citované zprávy |
| `replyToSenderId` / `reply_to_sender_id` | text null | autor citované zprávy (pro jmenovku, i když originál chybí) |
| `replyPreview` / `reply_preview` | text null | snímek textu citace ≤ 100 znaků |
| `forwarded` | bool default false | štítek „přeposláno“ |
| `editedAt` / `edited_at` | datetime null | poslední aplikovaná úprava |
| `deletedAt` / `deleted_at` | datetime null | tombstone „smazáno pro všechny“ |
| `readAt` / `read_at` | datetime null | příchozí: kdy jsem ji přečetl já |
| `receiptSent` / `receipt_sent` | text null | příchozí: nejvyšší odeslané potvrzení `delivered|read` |
| `expiresAt` / `expires_at` | datetime null | **rezerva** M11, nepoužívat |

Status odchozí: `sending|sent|delivered|read|failed`, beze změny výchozí hodnoty. Index `CREATE INDEX idx_messages_conversation_created ON messages(conversation_id, created_at)`.
**Datová migrace (povinná):** `UPDATE messages SET receipt_sent = 'read'` pro všechny existující řádky a `UPDATE messages SET read_at = received_at WHERE received_at IS NOT NULL`. Jinak by první spuštění v4 rozeslalo potvrzení za celou historii.

**Nové tabulky:**
```dart
class Reactions extends Table {            // jedna reakce na osobu a zprávu
  TextColumn get messageId => text()();
  TextColumn get reactorId => text()();    // deviceId (i můj)
  TextColumn get emoji => text()();
  DateTimeColumn get updatedAt => dateTime()();   // createdAt z payloadu (LWW)
  @override Set<Column> get primaryKey => {messageId, reactorId};
}
class MessageReceipts extends Table {      // odchozí zpráva × příjemce (bez auditora)
  TextColumn get messageId => text()();
  TextColumn get recipientId => text()();
  DateTimeColumn get deliveredAt => dateTime().nullable()();
  DateTimeColumn get readAt => dateTime().nullable()();
  @override Set<Column> get primaryKey => {messageId, recipientId};
}
class MessageRevisions extends Table {     // historie úprav; revize 0 = původní text
  TextColumn get messageId => text()();
  IntColumn get revision => integer()();
  TextColumn get body => text()();
  DateTimeColumn get editedAt => dateTime()();
  @override Set<Column> get primaryKey => {messageId, revision};
}
class InboundLog extends Table {           // KAŽDÉ zpracované příchozí id (obsah, řídicí i neznámé)
  TextColumn get senderId => text()();
  TextColumn get messageId => text()();
  DateTimeColumn get processedAt => dateTime()();
  @override Set<Column> get primaryKey => {senderId, messageId};
}
class AppSettings extends Table {          // sdílené s N/S; M používá dva klíče
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override Set<Column> get primaryKey => {key};
}
```
Proč `InboundLog`: dnes se deduplikuje jen přes `Messages` (`message_inbox_service.dart:71-81`). Řídicí a neznámé zprávy řádek v `Messages` nemají. Když se ztratí ACK, server zprávu doručí znovu, dešifrování selže (klíč je spotřebovaný) a zpráva se 30 dní točí jako chyba. Úklid: řádky starší 35 dní (TTL fronty 30 dní + rezerva) maže M02 při startu.

**`Conversations` (nové sloupce):** `mutedUntil` datetime null (ztlumeno „navždy“ = `9999-12-31T00:00:00Z`), `draft` text null, `pinnedAt` datetime null, `archivedAt` datetime null.
**`Contacts`:** `profileName` (vyžaduje G) M jen čte. `blocked` (G) M čte přes háček v 4.5.

**Klíče `AppSettings`, které M používá:** `privacy.readReceipts` (`"true"|"false"`, výchozí `true`), `privacy.typingIndicators` (výchozí `true`).

### 4.4 Refaktor přijímače a boti (X0, vlna 0)

`message_inbox_service.dart` X0 přestaví na registr handlerů. **Rozhraní se zmrazí takto** (M a G, M2 do něj jen registrují):
```dart
// lib/features/chat/inbound/inbound_handler.dart (vytvoří X0)
class InboundContext {
  final AppDatabase db;
  final String messageId, senderId, conversationId, myDeviceId;
  final String? groupId;
  final Map<String, dynamic> payload;   // už validovaná obálka
  final DateTime serverCreatedAt;       // data['createdAt'] z hubu
  final DateTime now;
}
sealed class InboundResult {}
class StoredContent extends InboundResult { StoredContent(this.message); final Message message; } // → persistedMessages
class Applied extends InboundResult { Applied(this.event); final ControlEvent event; }        // → controlEvents
class Ignored extends InboundResult {}                                                         // ack + nic
abstract class InboundTypeHandler {
  /// Běží UVNITŘ transakce přijímače. FormatException = chybně formovaná
  /// zpráva → přijímač ji potvrdí a zahodí (4.1). Jiná výjimka = rollback, bez ACK.
  Future<InboundResult> handle(InboundContext ctx);
}
class ControlEvent { final String type, conversationId, senderId; final List<String> refs; }
// MessageInboxService:
void registerHandler(String type, InboundTypeHandler handler); // před start()
Stream<Message> get persistedMessages;   // JEN obsahové typy (pro N)
Stream<ControlEvent> get controlEvents;  // receipt/reaction/edit/delete (pro UI, N P2)
bool Function(String senderId)? isBlocked; // háček pro G; true → ack + zahodit
```
X0 zaregistruje `text|file|call-event` (dnešní chování), přidá `InboundLog` deduplikaci (před dešifrováním: řádek existuje → ack) a pravidlo „neznámý typ → zápis do `InboundLog` + ack + ignore“.
**`jay_archiver` (X0):** neznámý typ → ack bez záznamu. **Výslovně i `receipt` → ack bez záznamu** (R-3). **`calltype_bot`:** už tolerantní (`calltype_bot.dart:321-325`), X0 jen přidá test.

### 4.5 Stuby, které X0 vytvoří (M je pak naplní)

```dart
// lib/features/chat/outgoing_messages.dart: pro N (odpověď z notifikace), M2 (média), G (profile)
class ReplyRef { final String id, senderId, preview; }
abstract class OutgoingMessages {
  /// Uloží řádek 'sending', zašifruje, odešle; vrátí id. Offline → zůstane 'sending'
  /// a odešle se po reconnectu (M02).
  Future<String> sendContent(String conversationId, {required String type, required String body,
      ReplyRef? replyTo, bool forwarded = false});
  Future<String> sendText(String conversationId, String text, {ReplyRef? replyTo});
  /// Řídicí zpráva (tichá, bez řádku v Messages). recipients null = všichni členové
  /// (+ auditor), jinak jen tito (auditor se v business skupině přidá VŽDY sám).
  Future<void> sendControl(String conversationId, String type, Map<String, Object?> fields,
      {List<String>? recipients});
  Future<void> retry(String messageId);
}
// lib/features/chat/active_conversation.dart: pro N (nezobrazovat notifikaci otevřeného chatu) a M04
class ActiveConversation extends ValueNotifier<String?> { ActiveConversation() : super(null);
  bool get appInForeground; }
// lib/features/chat/chat_extensions.dart: extension pointy pro M2 (vlna 2 je zapojí v main.dart)
typedef MessageBodyBuilder = Widget Function(BuildContext context, Message message, {required bool isMine});
class ComposerAction {
  const ComposerAction({required this.icon, required this.label, required this.onInvoke});
  final IconData icon;
  final String Function(BuildContext) label;       // lokalizovaný text
  final Future<void> Function(BuildContext context, String conversationId, ReplyRef? replyTo) onInvoke;
}
class MessageTypeHooks {
  const MessageTypeHooks({this.bodyBuilder, this.previewText, this.searchableText,
      this.prepareForwardBody, this.onDeleted});
  final MessageBodyBuilder? bodyBuilder;                              // obsah bubliny
  final String Function(BuildContext, Message)? previewText;          // seznam, citace, notifikace
  final String? Function(Message)? searchableText;                    // FTS (popisek fotky…)
  final Future<String> Function(Message)? prepareForwardBody;         // přeposlání (reuse blobu)
  final Future<void> Function(Message)? onDeleted;                    // smazat lokální soubory
}
class ChatExtensions {
  const ChatExtensions({this.types = const {}, this.attachmentActions = const [],
      this.trailingWhenEmpty});
  final Map<String, MessageTypeHooks> types;        // klíč = Message.type, např. 'media'
  final List<ComposerAction> attachmentActions;     // položky menu „+“ (foto, video, soubor)
  final Widget Function(BuildContext, String conversationId)? trailingWhenEmpty; // hlasovka místo „odeslat“
  static const none = ChatExtensions();
}
```
Poskytuje se jako `Provider<ChatExtensions>.value(ChatExtensions.none)` v `main.dart` (X0). Vlna 2 (M2) jen vymění hodnotu.

### 4.6 Ostatní
- **Balíčky (pubspec): žádné nové.** FTS5 je v přibaleném SQLite (web ověřen řetězci ve `web/sqlite3.wasm`, nativní [OVĚŘIT] testem v M08). Emoji picker se nepřidává (R-6).
- **Manifest / Info.plist / entitlements:** nic.
- **Prefix ARB klíčů:** `msg` (např. `msgStatusRead`, `msgActionReply`, `msgTypingOne`).
- **`api_client.dart` (M si přidá sám, jen nová metoda):** `Future<List<GroupMemberInfo>> getGroupMemberDetails(String groupId)`, kde `GroupMemberInfo{deviceId, role, joinedAt}` z již vraceného `GroupMemberDto` (`GroupEndpoints.cs:122-123`). Slouží k vyloučení auditora (`role == "auditor"`) z `MessageReceipts`.

---

## 5. Závislosti na jiných proudech

| Proud | M konzumuje | Kontrakt / stub | Bez čekání? |
| --- | --- | --- | --- |
| X0 | schema v4, registr handlerů, `InboundLog`, tiché hub metody, archivní kindy, stuby 4.5 | oddíl 4 | ano: M začíná po X0 |
| G | `Contacts.profileName` (jmenovka), `blocked` (háček `isBlocked`), typ `profile` (G si zaregistruje handler a posílá přes `OutgoingMessages.sendControl`) | 4.3, 4.4, 4.5 | ano: fallback jmenovky nepotřebuje profil |
| M2 | `ChatExtensions` (bublina `media`, akce přílohy, hlasovka, náhled, přeposlání, mazání souborů) | 4.5 | ano: vlna 1 s `ChatExtensions.none`, zapojení ve vlně 2 |
| N | M dodává: `persistedMessages` (jen obsah), `controlEvents`, `ActiveConversation`, `Conversations.mutedUntil`, `OutgoingMessages.sendText` (odpověď z notifikace), `MessagePreview.textFor` | 4.4, 4.5 | ano |
| C | nic nového. `call-event` beze změny, `CallLog` je C. Hub mění ve vlně 1 jen C, tiché metody proto musí udělat X0. | 4.2 | ano |
| S | nic. Ratchet a `session_manager.dart` beze změny. | — | — |
| D (vlna 2) | záloha a obnova nových sloupců a tabulek (`Reactions`, `editedAt`, `deletedAt`, `replyTo*`) a rozšíření whitelistu typů v `backup_import.dart:59-63`. Synchronizace „přečteno“ mezi zařízeními účtu. | tento plán, 4.3 | D, vlna 2 |

---

## 6. Balíčky práce

Pořadí uvnitř proudu: **M01 → (M02 ∥ M03 ∥ M05 ∥ M07 ∥ M09 ∥ M08) → (M04 ∥ M06) → M10 → M12**. M11 je jen návrh.
Ověření: `flutter test` (app + core), `dart test` (boti). Serverová část patří X0, Testcontainers potřebuje Docker. Když lokálně neběží, poslední slovo má hostované CI v public okně GitHubu (`/gh-actions-public`, každé okno schvaluje vlastník). Živé E2E jen proti lokálnímu `docker compose`, **nikdy proti betě**.

### M01: Drátový formát řídicích zpráv (sdílená knihovna) · S · vlna 1
**Cíl:** Jeden zdroj pravdy pro stavbu a validaci `receipt|reaction|edit|delete` + `replyTo/forwarded` pro app, `calltype_bot` i `jay_archiver`.
**Soubory:** `calltype_core/lib/messaging/control_messages.dart` (nový), `calltype_core/test/messaging/control_messages_test.dart`.
**Kroky:**
1. `sealed class ControlMessage { String get type; Map<String, Object?> fields(); }` a podtřídy `ReceiptMessage(kind, refs)`, `ReactionMessage(ref, emoji)`, `EditMessage(ref, body)`, `DeleteMessage(ref)`.
2. `static ControlMessage parse(Map<String, dynamic> payload)`: pravidla z 4.1, chyby jako `FormatException('<důvod>')`. `ReplyRef.tryParse(payload['replyTo'])`: preview se ořízne na 100 znaků, neplatný tvar → null (obsahová zpráva se kvůli citaci nezahodí).
3. `Map<String, Object?> buildPayload({required String id, required ControlMessage msg, String? groupId, required DateTime createdAt})`: vždy `v:1`, `body` (u `edit` text, jinak `""`), `groupName: null`.
4. Konstanty: `kMaxReceiptRefs = 100`, `kEditWindow = Duration(hours: 24)`, `kDeleteWindow = Duration(hours: 24)`, `kClockSkew = Duration(minutes: 10)`, `kMaxEdits = 10`, `kReplyPreviewMax = 100`, `chatReactionEmojis = channelReactionEmojis` (re-export z `channel_dtos.dart:15`, sjednocení s kanály, R-6).
5. `bool isValidReactionEmoji(String)`: 0–64 bajtů, ≤ 16 runes, bez `\s` a `\p{Cc}`.
6. Komentáře PROČ: proč `body:""`, proč nové `id`, proč LWW podle času odesílatele.

**Testy:** round-trip každého typu. Hranice (100/101 refs, prázdné refs, ne-UUID, emoji 65 B, „a b“). `edit` s `body` ne-String. `groupName` je vždy null.
**Přijetí:** `dart test` v `calltype_core` zelený. Bez závislosti na Flutteru (musí jít importovat z botů).

### M02: `MessageSender`, tichá odchozí fronta a automatický retry · M · vlna 1
**Cíl:** Vytáhnout odesílání z route-scoped `ChatController` do app-wide služby, implementovat `OutgoingMessages` (4.5) a odesílat čekající zprávy po reconnectu.
**Soubory:** `lib/features/chat/message_sender.dart` (nový, `class MessageSender implements OutgoingMessages`), `lib/features/chat/control_outbox.dart` (nový), `chat_controller.dart` (deleguje), `lib/main.dart` (připsat), `app/router.dart` (připsat parametr), testy `test/features/chat/message_sender_test.dart`, `control_outbox_test.dart`.
**Kroky:**
1. Přesunout `_send` / `retryMessage` / `_ensureSession` z `chat_controller.dart:182-343` do `MessageSender`. `ChatController.sendMessage/sendAttachment/retryMessage` zůstanou jako tenké delegáty (stávající `chat_controller_test.dart` musí projít beze změny asercí). Business příznaky (`auditRecipientMissing`, `auditorUnavailable`, `businessConversationRequired`) vrací `MessageSender` jako `SendFailure` enum ve výsledku / streamu `failures` (`Stream<SendFailure>` s `conversationId`) a `ChatController` je dál vystavuje jednorázovými `consume*()`.
2. Payload obsahové zprávy doplnit o `replyTo` a `forwarded` (jen když jsou nastavené, starší klient je ignoruje). Při odeslání do skupiny vložit `MessageReceipts` řádky pro příjemce **kromě auditora** (`api.getGroupMemberDetails`, `role != 'auditor'`) a kromě mě. U 1:1 jeden řádek (peer).
3. **Rozlišení chyb:** `StateError` z `_requireConnection` (`signalr_client.dart:278`) nebo přerušené spojení → status zůstane `sending`. `HubException` → `failed` (dnes vše `failed`, `chat_controller.dart:327`).
4. `ControlOutbox`: `sendControl(conversationId, type, fields, {recipients})` staví payload přes M01. V `MessageProcessingQueue.forDatabase(db)` (stejná serializace ratchetu jako dnes) šifruje pro příjemce: 1:1 = peer. Skupina = `recipients` nebo všichni členové; v business skupině (`Conversations.organizationId != null`) se vždy přidá auditor (KB2). Uloží `BackupState` klíč `ctl-outbox:<id>` = `{"conversationId","groupId","envelopes":{deviceId:b64},"createdAt"}` a odešle `sendQuietMessage` / `sendQuietGroupMessage`. Po úspěchu smaže klíč. Trvalé chyby (`Sender and recipients must be group members`, `business_conversation_required`, `audit_recipient_missing`) → smazat klíč + zalogovat id (opakování nepomůže). `auditor_unavailable` a offline → nechat.
5. `flushPending()`: po každém přechodu `connected` false→true (stejný vzor jako `main.dart` s `channels.sync()`) a při startu projde `ctl-outbox:*` (nejstarší první) a zprávy `Messages.status == 'sending'` se záznamem `outbox:<id>` (obslouží i `call-event` od C). Záznamy starší 30 dní smaže (server by je stejně zahodil).
6. Úklid `InboundLog` starších 35 dní a osiřelých `Reactions` (bez zprávy, starší 7 dní) při startu.
7. `main.dart`: `final sender = MessageSender(...)`, `Provider<OutgoingMessages>.value(sender)`, `Provider.value(sender)`, napojit flush na `signalRClient.addListener`.

**Testy:** Dvě `TestDevice` (reálná krypto) + falešný `SignalRClient` (podtřída, zaznamenává volání). Offline odeslání → `sending` → reconnect → odesláno jednou. Hub chyba → `failed`. Business skupina: auditor v obálkách řídicí zprávy i při `recipients=[origSender]`. `MessageReceipts` bez auditora. Trvalá chyba smaže `ctl-outbox`. Existující `chat_controller_test.dart` zelený.
**Přijetí:** Zpráva napsaná offline se po připojení odešle bez klepnutí. Řídicí zprávy jdou výhradně tichými metodami.

### M03: Příchozí handlery `receipt|reaction|edit|delete` + citace · M · vlna 1
**Cíl:** Aplikovat řídicí zprávy podle 4.1 a ukládat `replyTo/forwarded` u obsahu.
**Soubory:** `lib/features/chat/handlers/receipt_handler.dart`, `reaction_handler.dart`, `edit_handler.dart`, `delete_handler.dart`, `content_extras.dart` (ukládání `replyTo*`/`forwarded` do obsahového řádku, volá ho `text|file` handler od X0), registrace v `main.dart`. Testy `test/features/chat/handlers/*_test.dart`.
**Kroky:**
1. `ReceiptHandler`: pro každé `ref` ověřené dle 4.1 upsert `MessageReceipts(ref, senderId)`: `deliveredAt ??= serverCreatedAt`, u `read` i `readAt ??= serverCreatedAt`. Chybí-li řádek (zpráva z v3 nebo nový člen), vloží ho, jen pokud je odesílatel receiptu v 1:1 peer, nebo receipt přišel se stejným `groupId`. Pak přepočítá `Messages.status` cíle: všechny řádky `readAt != null` → `read`, všechny `deliveredAt != null` → `delivered`, jinak beze změny. **Status nikdy neklesá** (`sent < delivered < read`), `failed` a `sending` se nepřepisují. Výsledek `Applied(ControlEvent)`.
2. `ReactionHandler`: validace, LWW (`updatedAt` = `payload.createdAt`), `emoji == ""` smaže řádek. Cíl smazaný (`deletedAt != null`) → `Ignored`.
3. `EditHandler`: validace dle 4.1. Při první úpravě vloží revizi 0 (původní `body`) a pak revizi n. Pokud `createdAt > editedAt`, přepíše `body` a `editedAt`. Aktualizuje FTS (volá `SearchIndex.onEdited`, pokud M08 existuje; jinak no-op rozhraní).
4. `DeleteHandler`: `body = null`, `deletedAt = serverCreatedAt`, `replyPreview = null`, smazat `Reactions`, `MessageRevisions`, FTS řádek. Hook `ChatExtensions.types[type]?.onDeleted` (M2 smaže soubor) **mimo transakci** (po commitu přes `controlEvents`).
5. Obsah: `replyTo` přes `ReplyRef.tryParse`, `forwarded == true`.
6. Žádný handler nemění `unreadCount` ani `lastMessageAt`.

**Testy (reálná krypto přes `TestDevice`, vzor `message_inbox_service_test.dart`):** receipt od cizího zařízení nezmění cizí zprávu. Receipt na zprávu v jiné konverzaci se ignoruje. Pořadí `read` před `delivered` → `read`. Edit od jiného odesílatele se ignoruje. Edit po 25 h se ignoruje. Jedenáctý edit se ignoruje. Edity mimo pořadí → poslední vyhrává a historie má obě. Delete je idempotentní. Chybně formovaný receipt → ack + nic (ACK zaznamenán). Redelivery téže řídicí zprávy → `InboundLog` → jen ack, bez chyby dešifrování. Reakce → `Reactions`, `""` → smazáno. `unreadCount` beze změny.
**Přijetí:** Všechny testy zelené. `persistedMessages` neemituje řídicí typy.

### M04: Potvrzení doručení a přečtení (`ReceiptScheduler`) + fajfky · L · vlna 1 (po M02, M03)
**Cíl:** Posílat `receipt` dávkově a úsporně, respektovat přepínač a zobrazovat stav.
**Soubory:** `lib/features/chat/receipt_scheduler.dart`, `active_conversation.dart` (naplnění stubu: `WidgetsBindingObserver`), `chat_controller.dart` (`_markRead` → nastaví `readAt`), `widgets/message_status_icon.dart`, `widgets/message_info_sheet.dart` (P2), `main.dart` (připsat). Testy `receipt_scheduler_test.dart`, `message_status_icon_test.dart`.
**Kroky:**
1. **Delivered:** po každém `persistedMessages` (obsah, kromě `call-event` a zpráv od auditora) naplánuje doručenku. **Read:** `ChatController` při otevření, při příchodu zprávy do otevřeného chatu a při `AppLifecycleState.resumed` s aktivní konverzací (`ActiveConversation.value == conversationId && appInForeground`, zamčená aplikace = není v popředí) nastaví `readAt = now` všem příchozím v konverzaci s `readAt == null` a vynuluje `unreadCount`.
2. Dávkování: debounce **1,5 s**, klíč `(conversationId, originalSenderId)`. Jedna zpráva nese max. 100 id. Když čeká `read`, samostatný `delivered` pro stejná id se nepošle. Po úspěšném předání do `ControlOutbox` nastaví `receiptSent`.
3. Výběr při startu a reconnectu: příchozí obsah za posledních 30 dní s `receiptSent == null` (→ delivered) nebo `readAt != null && receiptSent != 'read' && privacy.readReceipts` (→ read).
4. Přepínač `privacy.readReceipts == false`: `read` se neposílá (`receiptSent` zůstane `delivered`). UI ukáže max. „doručeno“ (reciprocita R-1): příchozí `readAt` v `MessageReceipts` se ukládá, jen se nezobrazí.
5. Skupiny: receipt jde přes `sendControl(..., recipients: [originalSender])`. Auditora přidá `ControlOutbox` sám (KB2). Auditorovi se nikdy nic nepotvrzuje (auditor nepíše). Zprávy od botů se potvrzují normálně.
6. Blokovaným kontaktům (háček G `isBlocked`) se nic neposílá.
7. `MessageStatusIcon(status)`: `sending` hodiny, `sent` ✓, `delivered` ✓✓, `read` ✓✓ v `colorScheme.primary`, `failed` ikona chyby. `Semantics` label z ARB (`msgStatusSending|Sent|Delivered|Read|Failed`). Nahradí text `chatStatusSent` v `chat_screen.dart:385-408`, retry tlačítko u `failed` zůstává.
8. P2 `MessageInfoSheet` (dlouhý stisk → Info, jen ve skupině): seznam příjemců z `MessageReceipts` s časy. Jmenovky přes `SenderLabel` (M06).

**Testy:** Fake clock (`clock` z `package:clock` již tranzitivně, [OVĚŘIT], jinak injektovaný `DateTime Function() now`). 5 zpráv za 1 s → jeden receipt s 5 refs. 150 zpráv → 2 receipty (100 + 50). Přepínač off → žádný `read`. Po restartu se nepotvrzené dohledají. Migrace v4 (`receipt_sent='read'`) → nic se nepošle. Widget test ikon v `localizedApp` (en + ar RTL).
**Přijetí:** A pošle B zprávu, B je offline → ✓. B se připojí → ✓✓. B otevře chat → modré ✓✓ do ~2 s. Ve skupině 3 lidí je ✓✓ až po obou příjemcích. Auditor se do počtu nepočítá.

### M05: Indikátor psaní v UI · S · vlna 1
**Cíl:** Zobrazit „píše…“ a posílat typing úsporně, bez změny hubu (R-2).
**Soubory:** `lib/features/chat/typing_controller.dart`, `widgets/typing_indicator.dart`, `message_input.dart` (callback `onTextChanged`), `chat_screen.dart` (AppBar subtitle), `main.dart`. Testy `typing_controller_test.dart`.
**Kroky:**
1. Odesílání: při změně neprázdného textu nejvýš 1× za **3 s** `signalR.sendTypingIndicator(conversationId)`. Chyby se polykají (offline). Neposílá se, když `privacy.typingIndicators == false`, konverzace je s botem nebo je kontakt blokovaný.
2. Příjem: `onTyping` `{senderId, conversationId}` se mapuje na konverzaci: `conversationId == myDeviceId` → `senderId` (1:1), jinak `conversationId` (skupina). Ignoruje se auditor, já, blokovaní a vše při vypnutém přepínači (reciprocita). Stav `Map<conversationId, Map<senderId, DateTime expires>>`, expirace **5 s** (bot posílá á 4 s, `calltype_bot.dart:355`). Příchozí obsahová zpráva od odesílatele jeho typing hned zruší.
3. UI: pod názvem v AppBar `msgTypingOne(name)` / `msgTypingMany(count)` (ICU plural), jména přes `SenderLabel`.
4. Komentář PROČ u sendTypingIndicator: únik metadat a proč se nepřevádí do E2E (odkaz na R-2 a `session_manager.dart:65`).

**Testy:** Throttle (10 změn za 2 s → 1 volání). Expirace. Mapování 1:1 a skupiny. Přepínač off → nic neodejde ani se nezobrazí. Widget test textu (cs, plural).
**Přijetí:** Web ↔ web: „píše…“ se objeví do 1 s a zmizí do 5 s po přestání.

### M06: Chat UI: akce, odpověď, úprava, smazání, reakce, přeposlání, jmenovky, koncept, extension pointy · L · vlna 1 (po M02; lze začít proti stubu)
**Cíl:** Uživatelská vrstva všech funkcí nad M02/M03.
**Soubory:** `chat_screen.dart` (rozdělit: seznam do `widgets/message_list.dart`, položku do `widgets/message_tile.dart`), `message_bubble.dart`, `message_input.dart`, nové `message_actions.dart`, `sender_label.dart`, `message_preview.dart`, `forward_sheet.dart`, `widgets/reply_quote.dart`, `widgets/reaction_bar.dart`, `widgets/composer_banner.dart`, `chat_controller.dart`. Testy `test/features/chat/widgets/*_test.dart`, `chat_screen_test.dart`.
**Kroky:**
1. **`MessageBubble`** rozšířit o volitelné parametry: `status` (→ `MessageStatusIcon`, jen `isMine`), `edited` (štítek `msgEdited`), `forwarded` (`msgForwarded`), `deleted` (kurzíva `msgDeletedPlaceholder`, bez akcí kromě „Smazat pro mě“), `quote` (`ReplyQuote(senderName, preview)`), `reactions` (`List<(String emoji, int count, bool mine)>` → `ReactionBar` pod bublinou), `child` (**extension point:** když je nastavený, nahradí `Text(text)`; M2 sem dá obsah média přes `ChatExtensions.types['media'].bodyBuilder`). Stávající tři povinné parametry se nemění (kompatibilita testů).
2. **Akce** (`message_actions.dart`): dlouhý stisk (mobil) a pravé tlačítko / hover menu (web, desktop) → bottom sheet / `MenuAnchor`: řádek 6 reakcí (`chatReactionEmojis`), Odpovědět, Kopírovat (jen text), Přeposlat, Upravit (moje, `text`, ≤ 24 h, < 10 úprav, nesmazané), Smazat pro mě, Smazat pro všechny (moje, ≤ 24 h, nesmazané), Info (skupina, P2). Na `call-event` jen „Smazat pro mě“.
3. **Odpověď:** `ChatController.replyTo` (ValueNotifier<ReplyRef?>), banner nad vstupem (`ComposerBanner`, zrušit ×). `ReplyRef.preview` = `MessagePreview.textFor` ořezaný na 100 znaků. Klepnutí na citaci v bublině posune seznam na originál, pokud je načtený (P2: `GlobalKey` podle id), jinak nic.
4. **Úprava:** `ChatController.editing` (Message?). Vstup se předvyplní, banner „Úprava zprávy“. Odeslání lokálně aplikuje (revize 0/n, `body`, `editedAt`) v transakci a pak `sendControl('edit', …)` všem. Chyba odeslání → snackbar `msgEditNotSent` (lokální změna zůstane, `ControlOutbox` to zkusí znovu).
5. **Smazání:** „pro mě“ = hard delete řádku + `Reactions` + `MessageRevisions` + FTS + hook `onDeleted` (redelivery chrání `InboundLog`). „Pro všechny“ = dialog (`msgDeleteForEveryoneBody`, v business konverzaci navíc `msgDeleteBusinessArchiveNote`), lokální tombstone a `sendControl('delete')` všem.
6. **Reakce:** klepnutí na emoji v `ReactionBar` přepíná mou reakci. Lokálně upsert `Reactions(reactorId = já)` + `sendControl('reaction')` všem. Stejné emoji znovu → `emoji: ""`.
7. **Přeposlání** (P2): `ForwardSheet` = modal se seznamem konverzací (z `ChatListController`, bez archivovaných), výběr až 5. Pro každou `sendContent(type, body, forwarded: true)`. U typu s `prepareForwardBody` (M2) se použije ten. Přeposlání z business konverzace do anonymní se v UI nijak neomezuje ([otázka O-3]).
8. **`SenderLabel`** (nahradí `chat_screen.dart:350-359`): fallback `contact.displayName` (lokální přezdívka) → `contact.profileName` (G) → `contact.userHandle` → `GroupMemberInfo.userHandle` (pokud X0-M-4) → `msgUnknownMember(shortId)`, kde `shortId` = prvních 4 hex znaků UUID velkými písmeny. Auditor → stávající `context.l10n.businessAuditorTile(organizationName)` (`business_banner.dart:57`). Barva jmenovky: deterministická z hash(deviceId) do 8 odstínů z `ColorScheme` (kontrast ověřit v obou tématech). Po sobě jdoucí zprávy téhož odesílatele jmenovku neopakují.
9. **Koncept:** `MessageInput` dostane `initialText` a `onChanged`. `ChatController` ukládá `Conversations.draft` s debounce 800 ms a při `dispose`, po odeslání ho maže. Při otevření chatu koncept obnoví.
10. **Extension pointy (M2):** `ChatScreen` čte `context.read<ChatExtensions>()`: `types[message.type]?.bodyBuilder` → `MessageBubble.child`. Tlačítko přílohy v `MessageInput`: když `attachmentActions` není prázdné → menu „+“ s položkami M2 + dnešní „Soubor“ (256 KiB inline zůstává, dokud ho M2 nenahradí). Jinak dnešní chování (`message_input.dart:80-85`). `trailingWhenEmpty` se ukáže místo „odeslat“, když je vstup prázdný (hlasovka).
11. `MessagePreview.textFor(BuildContext, Message)`: `text` → body. `file` → `msgPreviewFile(name)`. `call-event` → stávající řádek. Smazaná → `msgDeletedPlaceholder`. Jiný typ → `ChatExtensions.types[t]?.previewText` nebo `msgPreviewUnsupported`. Používá seznam, citace i proud N.

**Testy (widget, `localizedApp`, cs/de/ar):** bublina se všemi kombinacemi příznaků (a žádný hard-coded `Text('…')`, hlídá `no_hardcoded_strings_test.dart`). Menu akcí nabízí upravit/smazat jen u vlastních zpráv v limitu (injektovaný čas). Odpověď → payload obsahuje `replyTo`. Úprava → `sendControl('edit')` a lokální `editedAt`. Smazat pro všechny v business konverzaci ukáže poznámku o archivu. `SenderLabel` fallbacky. Obnova konceptu po znovuotevření. `ChatExtensions` s testovacím `bodyBuilder` pro typ `media` se vykreslí.
**Přijetí:** Všechny akce fungují web ↔ web. Ve skupině už není vidět UUID.

### M07: Seznam konverzací: ztlumení, připnutí, archiv, koncept, náhled · M · vlna 1
**Soubory:** `lib/features/chat_list/chat_list_controller.dart`, `chat_list_screen.dart`, nové `chat_list/mute_dialog.dart`, `chat_list/archived_screen.dart` (otevírá se `Navigator.push` bez nové routy), ztlumení i v menu AppBar `chat_screen.dart`. Testy `test/features/chat_list/*`.
**Kroky:**
1. `ChatListController` → `customSelect` s `readsFrom: {conversations, messages}` (watch): konverzace + poslední obsahová zpráva (`SELECT … FROM messages WHERE conversation_id = c.id ORDER BY created_at DESC LIMIT 1` jako korelovaný poddotaz; index z 4.3). Řádek `ConversationRow{conversation, lastMessage?}`.
2. Řazení: připnuté (`pinnedAt DESC`) nahoře, pak `lastMessageAt DESC`. Archivované (`archivedAt != null`) se v hlavním seznamu nezobrazí, nahoře je řádek „Archivováno (n)“.
3. Podtitulek: koncept → `msgDraftPrefix(draft)` akcentní barvou. Jinak `MessagePreview.textFor(lastMessage)`, u skupiny s `SenderLabel` prefixem. Bez zpráv zůstane dnešní text.
4. Dlouhý stisk / menu řádku: Připnout / Odepnout (max. 3, pak snackbar `msgPinLimit`), Archivovat / Obnovit, Ztlumit / Zrušit ztlumení, Označit jako přečtené (nastaví `readAt`, `unreadCount = 0`, naplánuje `read` receipt přes M04).
5. `MuteDialog`: 8 h, 1 týden, Navždy → `mutedUntil`. Ikona ztlumení u řádku, badge nepřečtených šedě. Business nouzová skupina: ztlumení se nenabízí, pokud jde poznat (`Conversations` nemá příznak → [otázka O-2]).
6. R-8: `MessageInboxService.persistedMessages` listener v `ChatListController` → pokud `archivedAt != null` a není ztlumeno (`mutedUntil == null || mutedUntil < now`), `archivedAt = null`.

**Testy:** Řazení s připnutými. Archiv se skryje a nová zpráva ho vrátí (když není ztlumeno). Koncept v podtitulku. Ztlumení zapíše `mutedUntil`. Widget testy v cs/ar.
**Přijetí:** Proud N může číst `mutedUntil` bez další práce M.

### M08: Vyhledávání (FTS5) · M · vlna 1, pokud zbude kapacita, jinak 2 (P2)
**Cíl:** Globální hledání a hledání v chatu, s diakritickou tolerancí, na webu i nativně.
**Soubory:** `lib/features/chat/search/search_index.dart`, `search/search_screen.dart` (routa `/search`, připsat do `router.dart`), `search/in_chat_search_bar.dart`, ikona v AppBar seznamu a chatu. Testy `search_index_test.dart` (VM, `NativeDatabase.memory()`), `search_web_test.dart` (`flutter test --platform chrome`, [OVĚŘIT] že drift web worker v testu běží, jinak ruční přejímka).
**Kroky:**
1. **Runtime** (ne v migraci X0, protože boti sdílejí schéma a FTS nepotřebují a jejich SQLite build je [OVĚŘIT]): `CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(body, message_id UNINDEXED, conversation_id UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')`.
2. Plnění kódem, ne triggery (drift `TableMigration` by triggery při budoucí migraci tiše zahodil): `onInserted/onEdited/onDeleted` volané z M02 (odeslání), handlerů M03 a obsahového handleru (listener `persistedMessages`). Text = `body` u `text`, `name` u `file`, `searchableText` hook u ostatních.
3. Při startu: když `SELECT count(*) FROM message_fts` < počet textových zpráv → přestavba po 500 řádcích v `Future.microtask` smyčce (web nesmí zamrznout).
4. Když `CREATE VIRTUAL TABLE` selže (SQLite bez FTS5), `SearchIndex.available = false` a použije se fallback `LIKE '%' || ? || '%'` na `messages.body` (s komentářem, proč).
5. Dotaz: uživatelský vstup → tokeny v uvozovkách + `*` (prefix), escapovat `"`. `ORDER BY rank LIMIT 50`. Výsledek: konverzace, jmenovka, zvýraznění `snippet()`.

**Testy:** „prilis“ najde „příliš“. Upravená zpráva se najde podle nového textu, podle starého ne. Smazaná se nenajde. Uvozovky ve vstupu nezpůsobí SQL chybu. Fallback bez FTS.
**Přijetí:** Hledání na webu (Chrome) i Androidu vrátí výsledky do 200 ms na 10 000 zprávách ([OVĚŘIT] měřením).

### M09: Boti a archiver · M · vlna 1 (po X0)
**Soubory:** `src/bots/jay_archiver/lib/src/group_message_source.dart`, `lib/src/archiver.dart` (beze změny API, `detailsJson` se použije pro nové kindy), `test/signal_group_message_source_test.dart`, `test/archiver_test.dart`, `test/e2e/business_mode_e2e_test.dart`. Dále `src/bots/calltype_bot/lib/calltype_bot.dart`, `test/bot_runtime_test.dart`.
**Kroky (archiver):**
1. Parsovat přes M01 (`ControlMessage.parse`). `reaction` / `edit` / `delete` → `IncomingGroupMessage(kind: 'reaction'|'edit'|'delete', sizeBytes: utf8 délka emoji/nového textu (delete 0), detailsJson: jsonEncode({'ref': ref, 'bodyHash': hex|null}), contentHashHex: sha256(detailsJson))`. Pořadí klíčů je pevné (`ref`, `bodyHash`). Server hashuje přesně poslaný řetězec.
2. `receipt` → ack bez záznamu (X0 už zavedl, M jen hlídá testem, R-3).
3. Chybně formovaná řídicí zpráva → ack bez záznamu + log id (stejné pravidlo jako app, 4.1). **Pozor:** nepotvrzená zpráva stárne a za 24 h shodí organizaci do `auditor_unavailable`.
4. `text` s `replyTo` / `forwarded` → dál `kind: text`, `contentHash = sha256(body)` beze změny (reply vztah se v metadata úrovni nearchivuje, [otázka O-4]).
5. Komentáře PROČ: append-only. Úprava a smazání jsou **nové záznamy**, originál zůstává.

**Kroky (calltype_bot):**
6. Po úspěšném zpracování zprávy (1:1, nebo skupina s oslovením botu) poslat `receipt kind: read` odesílateli, dávkově á 2 s, tiše (`sendQuietMessage` / `sendQuietGroupMessage`). Zprávy ve skupině bez oslovení → `delivered`. Šifrovat ve stávající frontě `_crypto`. Neúspěch se jen zaloguje (boti nemají outbox pro řídicí zprávy, [PŘEDPOKLAD] ztráta receiptu nevadí).

**Testy:** archiver: každý kind → správné `details` + hash (porovnat s ručně spočteným SHA-256). Receipt → ack, žádný POST. Poškozený edit → ack, žádný POST. Bot: po odpovědi odejde jeden receipt `read`. Receipt, reakce a úprava od uživatele → bot jen ack. **Živé E2E** (`JAY_E2E_API=http://localhost:8080`, jen lokální compose): **rozšířit stávající** `business_mode_e2e_test.dart` se stávajícími zařízeními (limit 10 auth volání/min je v obou E2E souborech vyčerpán, nový soubor ani nové registrace nepřidávat). Kroky: edit, delete, reakce → 3 nové `AuditRecord` s `kind` a `details`. Receipt → počet záznamů se nezmění.
**Přijetí:** `dart test` v obou balíčcích zelený. E2E zelené lokálně (Docker) nebo v CI public okně.

### M10: Nastavení soukromí zpráv · S · vlna 1
**Soubory:** `lib/features/chat/message_privacy_screen.dart`, `lib/features/chat/chat_settings.dart` (čtení a zápis `AppSettings`, `ValueNotifier`y), připsat `ListTile` do `settings/settings_screen.dart`. Test `message_privacy_screen_test.dart`.
**Kroky:** dva `SwitchListTile`: `msgSettingsReadReceipts` + popis reciprocity (`msgSettingsReadReceiptsHint`), `msgSettingsTypingIndicators` + popis úniku („server vidí, že píšete“ – `msgSettingsTypingHint`, poctivě dle R-2). Změna se projeví okamžitě (M04, M05 poslouchají `ChatSettings`).
**Přijetí:** widget test cs/ar, přepínač přežije restart.

### M11: Mizející zprávy (P2): jen návrh, neimplementovat bez rozhodnutí R-9
- Nastavení per konverzace řídicí zprávou `type: "timer"`, `{"expiresInSec": 0|3600|86400|604800}` (vždy všem, zobrazí se jako systémový řádek). Obsahové zprávy pak nesou `expiresInSec`.
- Odpočet: odesílatel od odeslání, příjemce od `readAt` (Signal). `Messages.expiresAt` (rezerva v4) + periodický úklid (1 min, při startu) = stejná cesta jako „smazat pro mě“ (včetně FTS a hooku M2).
- V business konverzaci se volba nenabízí a příchozí `timer` se ignoruje (R-9). Archiver ho potvrdí bez záznamu.
- Starý klient: zprávy nezmizí. UI to musí říct („funguje jen v aktuálních verzích aplikace“).
- Velikost při schválení: M. Vlna 2+.

### M12: Dokumentace a přejímka · S · vlna 1 (na konci)
- `docs/superpowers/plans/2026-09-29-gap-contracts.md`: M jen dodá text oddílu 4.1 (sloučí koordinátor).
- `docs/acceptance/matrix.md`: řádky z oddílu 7 (připíše koordinátor, M dodá text).
- `CLAUDE.md` tabulka Hub: `SendQuietMessage` / `SendQuietGroupMessage` (X0) a poznámka „potvrzení jsou E2E, server je nevidí“.
- `docs/acceptance/business-mode.md`: nové kindy a „receipt se nearchivuje“.

### Co uvidí starší klient (bez X0 tolerance / bez M)

| Nový typ / pole | Starý klient (před X0) | Klient s X0, bez M |
| --- | --- | --- |
| `receipt` | výjimka, bez ACK, redelivery až 30 dní (šum, ratchet OK díky rollbacku) | ack + ignore; odesílatel vidí ✓✓ u ostatních, ale ne od něj |
| `reaction` | totéž | reakce se nezobrazí |
| `edit` | totéž; zůstane původní text | zůstane původní text |
| `delete` | totéž; **zpráva zůstane vidět** (proto varování R-5) | zpráva zůstane vidět |
| `replyTo` / `forwarded` u `text` | zobrazí jen text bez citace (pole se ignorují, `message_inbox_service.dart:95-102` je nekontroluje) | totéž |
| typing | beze změny (hub) | beze změny |
| `jay_archiver` starý | nový typ nepotvrdí → po 24 h `auditor_unavailable` pro celou organizaci | **proto R-10** |

---

## 7. Přejímka na zařízení (řádky pro `docs/acceptance/matrix.md`)

Sloupce jako v matici: Web (desktop), Web iOS Safari, Android, Windows, macOS, iOS nativní. Stav na začátku je všude NOT_RUN.

| Scénář | Poznámka k provedení |
| --- | --- |
| Q-M-01 fajfky 1:1: A pošle offline B → ✓. B online → ✓✓. B otevře chat → ✓✓ modré | dvě zařízení / dva prohlížeče |
| Q-M-02 potvrzení ve skupině A/B/C: ✓✓ až po B i C, info „Přečetli 2/2“ | + business varianta: auditor se nepočítá, archiv receipt neobsahuje |
| Q-M-03 přepínač potvrzení off na B: A nevidí modré, B nevidí modré u A | reciprocita R-1 |
| Q-M-04 indikátor psaní 1:1 a ve skupině, zmizí do 5 s; přepínač off | web ↔ mobil |
| Q-M-05 odpověď s citací, klepnutí na citaci | + starší build na druhé straně zobrazí jen text |
| Q-M-06 úprava do 24 h, štítek „upraveno“, druhá strana vidí nový text | + restart obou stran |
| Q-M-07 smazat pro všechny / pro mě, tombstone, business poznámka o archivu | business: v archivu originál + `delete` záznam |
| Q-M-08 reakce 6 emoji, přepnutí a odebrání, skupina se 3 reagujícími | RTL (ar) rozložení |
| Q-M-09 koncept přežije přepnutí chatu i restart aplikace | web: reload stránky |
| Q-M-10 ztlumení 8 h / navždy: žádná notifikace (s proudem N), badge šedý | závisí na N |
| Q-M-11 připnutí (max. 3), archiv a návrat archivu po nové zprávě | |
| Q-M-12 jméno odesílatele ve skupině: kontakt / profil / neznámý člen | závisí na G pro profil |
| Q-M-13 offline odeslání 5 zpráv → reconnect → odejdou samy, jednou | letadlový režim |
| Q-M-14 hledání „prilis“ → „příliš“, web i nativně | FTS5 na webu (sqlite3.wasm) |
| Q-M-15 přeposlání textu do 2 konverzací | |

---

## 8. Rizika a otevřené otázky

**Rizika**
1. **Archiver bez tolerance = výpadek firemní komunikace za 24 h** (liveness podle nepotvrzené skupinové zprávy). Mitigace: R-10 a test v M09. `jay_archiver` na betě dnes neběží (analýza §8), riziko se tedy projeví až při jeho spuštění. Musí běžet verze ≥ X0.
2. **Metadatový únik tichých metod** (R-7): server rozliší „tichou“ zprávu. Přijatelné, zdokumentovat v `docs/security/` (proud S) a v CLAUDE.md.
3. **Objem zpráv:** každé přečtení = zpráva (dávkování ≤ 1 na konverzaci a odesílatele za 1,5 s). Ve skupině 100 členů jedna zpráva vyvolá až 99 receiptů k odesílateli (+ 99 auditorovi v business skupině). Signal to má stejně, ale sledovat `QueuedMessages` na betě. Případná optimalizace: potvrzovat „read“ ve skupinách > 20 členů jen agregovaně (Otázka O-1).
4. **Pořadí doručení:** reakce nebo úprava může přijít dřív než cílová zpráva (živé doručení, různí odesílatelé). Reakce se uloží „naslepo“, ale úprava a smazání se zahodí. Vzácné, protože fronta řadí podle `CreatedAt`. Zdokumentovat a případně řešit krátkou odkladnou frontou (P2).
5. **Refaktor `ChatController` → `MessageSender`** zasahuje do nejkritičtější cesty (odesílání, KB2 chyby). Mitigace: stávající testy `chat_controller_test.dart` a `call_event_sender_test.dart` beze změny asercí.
6. **FTS5 na nativních platformách:** `sqlite3` 3.x přibaluje SQLite přes build hooks. Zda má FTS5 zapnuté, je [OVĚŘIT] (test M08 + fallback LIKE).
7. **Časy odesílatele** (limity úprav a smazání) lze podvrhnout upraveným klientem. Jde jen o UX, bezpečnostní invariant „jen autor“ drží autentizovaná session.
8. **Chat screen je sdílený s M2:** ve vlně 1 M2 nesmí sahat do `chat_screen.dart`, `message_bubble.dart` ani `message_input.dart`. Vše jde přes `ChatExtensions` (4.5). Když M2 potřebuje nový slot, je to požadavek na M, ne úprava souboru.

**Otevřené otázky**
- O-1: Velké skupiny (> 20): posílat `read` receipty, nebo jen `delivered`? Doporučení pro vlnu 1: posílat, změřit.
- O-2: Pozná klient nouzovou skupinu (`IsEmergencyChannel`)? `GroupBusinessInfo` pole nemá (`calltype_core/lib/network/organization_dtos.dart:90-115`). Bez něj nejde zakázat ztlumení nouzového kanálu. Návrh: X0 / G přidá `isEmergencyChannel` do `GET /groups/{id}` a `Conversations.isEmergency`.
- O-3: Přeposílání z business konverzace do anonymní: organizace může chtít zakázat (únik firemních dat). Mimo rozsah M, otázka pro business roadmapu.
- O-4: Archivovat vztah odpovědi (`replyTo.id`) v metadata úrovni? Dnes `details` pro `text` zakázané. Doporučení: ne v kroku 1.
- O-5: Má „smazat pro všechny“ fungovat i pro admina skupiny (moderace)? Doporučení: ne teď.
