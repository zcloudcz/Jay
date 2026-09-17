# Jay Business — firemní režim s auditním archivem (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů a kontrakty; nic automaticky nenasazuj.

**Goal:** Jeden produkt, dva režimy. **Anonymní režim** zůstává beze změny (E2E, server nevidí obsah, žádná organizace). **Business režim** přidává organizaci, role a **viditelného tichého auditního člena**, který firemní konverzace archivuje do odděleného, pouze přírůstkového archivu s řízeným přístupem („čtyři oči“) a doložitelnou integritou.

**Architecture:** Krok 1 staví nad dnešním per-recipient fan-outem (Signal-style, pure Dart): auditní člen je další příjemce, server jeho přítomnost **vynucuje**. Archivátor je headless klient nad `src/bots/calltype_bot` + `calltype_core`. Organization & Audit je samostatný bounded context s vlastní databází/credentials (DDD selektivně — jen zde). Souběžně běží **spike MLS** (OpenMLS přes Rust) jako příprava kroku 2, který uzavře známou mezeru kroku 1.

**Tech Stack:** .NET 10 minimal API, EF Core/Npgsql, SignalR, PostgreSQL (oddělené DB/role), Flutter/Provider/Drift, pure-Dart bot runtime; spike: Rust + OpenMLS + `flutter_rust_bridge`.

**Spec:** [TypeCall v0.2](../specs/2026-09-15-typecall-spec-v0.2.md) + rozhodnutí zadavatele z 2026-09-18 (níže). Plán byl 2026-09-18 zrevidován proti plnému textu specifikace; odchylky od ní jsou vyjmenované v sekci 0.1. Zbylé předpoklady jsou označeny **[PŘEDPOKLAD]**.

## 0. Rozhodnutí zadavatele (závazná)

1. Jay má **dva režimy**: anonymní E2E jako dnes + Business (audit, auditní člen, správa).
2. Auditní člen je **viditelný** a „tichý“ jen ve smyslu, že nepíše. Žádný skrytý záznam (§ 316 ZP, GDPR — transparentnost je požadavek návrhu, ne volba UI).
3. Postup: **krok 1 nad stávajícím krypto + souběžně MLS spike**; krok 2 (MLS pro business skupiny) až po vyhodnocení spiku.
4. Převzato z Typecall 6.2: .NET všude, Rust jen jako krypto knihovna; DDD jen pro Audit & Organization, Delivery zůstává tenký; oddělené DB/credentials pro Delivery a Audit; audit DB append-only (aplikační účet jen INSERT/SELECT); **bez message brokeru** (Postgres `FOR UPDATE SKIP LOCKED`, `Channel<T>`); žádná tvrdá závislost jádra na Azure (self-hosted cíl).

### 0.1 Vztah ke specifikaci TypeCall v0.2 (vědomé odchylky)

| Spec | Tento plán | Proč |
| --- | --- | --- |
| Tři profily: denní provoz, **nouzový režim**, consumer (2.6) | Consumer = dnešní anonymní Jay (hotovo). Denní provoz + nouzový kanál = Business režim; nouzový kanál je **první prodejní vstup** (2.3) a má vlastní balíček E07 | Zadavatel mluví o „dvou režimech“; nouzový kanál je profil uvnitř Business, ne třetí aplikace |
| Pořadí fází: business jádro → pilot → mobil → enterprise → consumer (kap. 10) | Consumer klient na 5 platformách už existuje a běží | Realita repozitáře; výhoda — mobil (největší riziko dle 8.1) je z velké části hotový |
| MLS od začátku (kap. 4) | Krok 1 nad stávajícím fan-outem, MLS jako souběžný spike M0 a krok 2 | Rozhodnutí zadavatele; mez KB2 je přiznaná |
| Výchozí archivace **metadata-only** (5.4) | Převzato: krok 1 dodává metadata-only; full content je samostatná, později zapínaná úroveň (E03b) | Stačí pro ZoKB/NIS2, řádově menší storage i právní riziko |
| Klient odmítne odeslat bez auditora (5.2) | Převzato **a navíc** vynucení na serveru (KB2) | Obrana do hloubky |
| Denní Merkle kořen + kvalifikované časové razítko eIDAS, ne blockchain (5.6) | Převzato (KB4), TSA za rozhraním `ITimestampAuthority` | Self-hosted zásada 6.1 |
| `OrgAuditKey` privátní část v HSM, 4 oči (5.1) | Převzato jako cíl; v kroku 1 za `IArchiveKeyStore` (dev: konfigurační tajemství) — relevantní až pro full content | Metadata-only archivní klíč nepotřebuje |
| Admin konzole Blazor Server (kap. 6) | **[PŘEDPOKLAD]** správa uvnitř Flutter app, přehodnotit po pilotu | Jeden frontend stack pro solo vývoj |
| SSO/SCIM, správa klíčů a certifikátů (2.7), crypto baseline NÚKIB (2.8), plné exporty doložitelnosti (2.9) | Mimo krok 1 (spec fáze 2b/4); E06/E07 dodávají jen první exporty | Rozsah |
| **Validační milník kap. 12: „nekódovat, dokud 3 organizace nepotvrdí potřebu a ochotu platit“** | **Nesplněn / nedoložen.** Plán lze realizovat, ale je to vědomé porušení vlastního pravidla zadavatele — viz otevřená otázka 0 | Poctivost |

## 1. Model režimů

- Režim je vlastnost **konverzace**, ne zařízení. Jedno zařízení může mít anonymní chaty i být zapsané (enrolled) v organizaci.
- **Business konverzace** = skupina vlastněná organizací (`Group.OrganizationId != null`). Firemní 1:1 je technicky tříčlenná skupina (A, B, auditní člen) — v UI se tváří jako 1:1 s archivním bannerem.
- Anonymní konverzace se **nikdy** nearchivují a kód pro ně se nemění. Převod anonymní konverzace na business neexistuje (zakládá se nová).
- Odebrání člena z organizace = odebrání ze všech jejích skupin + zneplatnění enrollmentu. Zařízení zůstává platným anonymním uživatelem Jay; historie v zařízení se nemaže (web to už takto komunikuje).

## 2. Kontrakty

### KB1 — viditelnost auditu (právní invariant)
Každá business konverzace má právě jednoho auditního člena (`GroupMember.Role = "auditor"`). Klient ho **vždy** zobrazuje v seznamu členů jako „Archiv organizace <název>“ a konverzace nese trvalý banner „Tato konverzace je archivována organizací <název>“. Auditního člena nelze odebrat ani skrýt; business skupinu bez něj server odmítne vytvořit. Porušení KB1 je blokující vada.

### KB2 — vynucení na serveru
`SendReliableGroupMessage` pro skupinu s `OrganizationId`: mapa `encryptedPayloads` **musí** obsahovat klíč auditního zařízení, jinak `HubException("audit_recipient_missing")` a nic se neuloží. Metody a tvar `ReceiveMessage` (K01) se nemění.
**Známá mez kroku 1 (dokumentovat všude, kde se mluví o úplnosti archivu):** server ověří přítomnost ciphertextu pro auditora, ne jeho obsahovou shodu s ostatními příjemci. Upravený klient může auditorovi poslat jiný obsah. Mez uzavírá krok 2 (MLS — všichni členové dešifrují tentýž ciphertext).

### KB3 — archiv (úrovně dle spec 5.4)
Úroveň je politika organizace (`ArchiveLevel`), verzovaná s datem účinnosti a zapsaná v `AdminAuditEvent`:
- **`metadata` (výchozí, rozsah kroku 1):** kdo, komu (skupina), kdy, `ContentHash`, velikost, typ (text/příloha/hovor-metadata). Archivátor je řádný člen: zprávu dešifruje jen v paměti, spočítá `ContentHash = SHA-256(plaintext)`, zapíše metadata a plaintext zahodí. Hash z plaintextu (ne z ciphertextu) je nutný, aby šel později porovnat s kopií, kterou předloží kterýkoli účastník.
- **`full` (balíček E03b, až po kroku 1):** navíc obsah **znovu zašifrovaný veřejným `OrgAuditKey`**, nezávisle na session/epoch klíčích (spec 5.3) — archiv zůstává čitelný i po rotaci klíčů. Privátní část za `IArchiveKeyStore` (cíl: HSM).
- **`full+attachments`:** mimo tento plán.

Plaintext se nikdy neukládá ani neloguje. Záznam: `OrganizationId, GroupId, MessageId, SenderDeviceId, SentAt, ArchivedAt, Kind, SizeBytes, ContentHash, CiphertextForArchive (null pro metadata), PrevHash, Hash` kde `Hash = SHA-256(PrevHash ‖ kanonická serializace záznamu)` — řetěz per organizace. ACK zprávy serveru až po potvrzeném zápisu do audit DB (stejná disciplína jako K01). Audit DB: role aplikace má jen `INSERT, SELECT`; žádné `UPDATE/DELETE`; retence se řeší `DROP PARTITION` samostatnou provozní rolí podle retenční politiky organizace.

### KB4 — denní Merkle kořen a kvalifikované časové razítko (spec 5.6)
Hash řetěz sám nestačí — kdo ovládá DB, přepíše celý řetěz. Jednou denně (scheduled job, ne fronta) se z hashů záznamů dne sestaví **Merkle strom přes všechny organizace** (multi-tenant: jeden společný kořen, každá organizace dostane Merkle proof své větve) a kořen se orazítkuje přes `ITimestampAuthority` (RFC 3161; produkce: kvalifikované razítko eIDAS — PostSignum/I.CA; dev/test: deterministický fake). Ukládá se `DailyRoot(Day, RootHash, TimestampToken, TsaName, ExpiresAt)` + `OrgDailyProof`. Blockchain zamítnut specifikací. Bez nakonfigurované TSA jde jen o interní integritu a UI/export to musí říkat. Přerazítkování před expirací (5 let) a alert 6 měsíců předem: job navrhnout hned, implementace může počkat — zapsat jako TODO s datem.
WORM úložiště (immutable Blob) pro export denních kořenů je volitelný adaptér `IImmutableStore`; jádro na něm nesmí záviset (spec 6.1).

### KB5 — přístup k archivu („čtyři oči“)
Žádost `AuditAccessRequest` (kdo, rozsah: skupina/osoba/období, důvod) → schválení **druhou** osobou s rolí `auditor-approver` (žadatel ≠ schvalovatel) → časově omezené okno → každé čtení zapisuje `AuditAccessLog` (kdo, co, kdy; append-only). Členové dotčené konverzace jsou o otevření archivu **informováni** (systémová zpráva) — **[PŘEDPOKLAD]**, potvrdit s právníkem.
**Mez kroku 1:** čtyři oči vynucuje Audit Service politikou; soukromý archivní klíč drží služba (konfigurační tajemství / později Key Vault/HSM). Kryptografické rozdělení klíče mezi schvalovatele (threshold) je samostatné zadání.

### KB6 — auditní log správy
Všechny změny v Organization contextu (členství, role, enrollment, skupiny, politiky, žádosti o přístup) se zapisují jako doménové události do `AdminAuditEvent` (append-only, stejná DB jako archiv, vlastní hash řetěz). Export CSV/JSON pro roli `org-admin`. Nikdy neobsahuje obsah zpráv.

## 3. Datový model

**Delivery DB (stávající, jen doplnění):** `Group.OrganizationId` (nullable Guid, index); `GroupMember.Role` rozšířit o `auditor`. Nic dalšího — Delivery o organizacích ví jen ID.

**Org & Audit DB (nová databáze `calltype_audit` [PŘEDPOKLAD název], vlastní connection string `ConnectionStrings__Audit`, vlastní DB role):**

| Agregát / tabulka | Obsah |
| --- | --- |
| `Organization` | `OrganizationId`, `Name`, `CreatedAt`, `ArchivePublicKey`, `RetentionDays`, `AuditorDeviceId` |
| `OrgMember` | (`OrganizationId`,`AccountId`), `Role` ∈ `owner/org-admin/auditor-approver/member`, `AddedAt`, `RemovedAt` |
| `OrgEnrollment` | (`OrganizationId`,`DeviceId`), `AccountId`, `EnrolledAt`, `RevokedAt` — zařízení zapsané pozvánkou |
| `OrgInvite` | jednorázový kód, expirace, vydal kdo |
| `AuditRecord` | viz KB3, partitioning po měsících |
| `DailyRoot` / `OrgDailyProof` | viz KB4 |
| `EmergencyKit` / `EmergencyDrill` | viz E07 |
| `AuditAccessRequest` / `AuditAccessLog` | viz KB5 |
| `AdminAuditEvent` | viz KB6 |

Invarianty v doméně (ne v endpointech): právě jeden aktivní `owner`; žadatel ≠ schvalovatel; nelze odebrat posledního `org-admin`; enrollment jen platnou pozvánkou; business skupina vždy s auditorem.
**[PŘEDPOKLAD]** Správci organizace (`owner`, `org-admin`, `auditor-approver`) vyžadují registrovaný `Account` (e-mail) — anonymní zařízení by při ztrátě telefonu ztratilo firmu. Řadový člen se zapisuje zařízením přes pozvánku a Account mít nemusí.

## 4. API (nové endpointy, vše `RequireAuthorization` + rate limit)

`POST /orgs` · `GET /orgs/mine` · `POST /orgs/{id}/invites` · `POST /orgs/enroll` (kód) · `GET/PUT/DELETE /orgs/{id}/members/{accountId}` · `DELETE /orgs/{id}/enrollments/{deviceId}` (revokace) · `POST /orgs/{id}/groups` (založí business skupinu včetně auditora; 1:1 varianta) · `GET /orgs/{id}/admin-audit?from&to&format=json|csv` · `POST /orgs/{id}/audit-access` · `POST /orgs/{id}/audit-access/{reqId}/approve|reject` · `GET /orgs/{id}/audit-access/{reqId}/records?cursor` (jen ve schváleném okně, loguje se).
Chyby: 403 role, 404, 409 invariant (`last_admin`, `self_approval`), 410 expirované okno/pozvánka.

## 5. Komponenty a vlastnictví

| ID | Výstup | Závislosti | Vlastnictví |
| --- | --- | --- | --- |
| **E00** | Kontrakty KB1–KB6 zafixovat; nový projekt `CallType.Audit` (doména + EF `AuditDbContext` + migrace), druhá DB v docker-compose/Testcontainers, DB role skript, DI/konfigurace, `Group.OrganizationId` migrace v Delivery | — | `Program.cs`, `appsettings*`, oba DbContexty, Migrations, `infra/postgres/` |
| **E01** | Organization context: agregáty, invarianty, endpointy org/invite/enroll/members, `AdminAuditEvent` + export | E00 | `CallType.Audit/Organization/**`, `Endpoints/OrganizationEndpoints.cs`, testy |
| **E02** | Business skupiny v Delivery: založení s auditorem, vynucení KB2 v hubu, zákaz odebrání auditora, revokace enrollmentu → odebrání ze skupin | E00 | `Hubs/MessengerHub.cs` (jen doplnění), `Endpoints/GroupEndpoints.cs`, testy |
| **E03** | Archivátor úrovně `metadata`: `src/bots/jay_archiver/` nad `calltype_bot` — přihlášení jako auditní zařízení, dešifrování v paměti, `ContentHash`, zápis přes interní audit API, ACK až po zápisu; hash řetěz; denní Merkle kořen + `ITimestampAuthority` (fake + RFC 3161 klient); offline ověřovací nástroj (řetěz + Merkle proof + razítko) | E00, E02 | `src/bots/jay_archiver/**`, `CallType.Audit/Archive/**`, `tools/audit-verify/`, testy |
| **E03b** | (po kroku 1) úroveň `full`: `OrgAuditKey`, re-encrypt, `IArchiveKeyStore`, čtení obsahu v E04 | E03, E04 | tamtéž |
| **E04** | Přístup k archivu: žádost/schválení/okno/čtení/log, notifikace členům | E01, E03 | `CallType.Audit/Access/**`, `Endpoints/AuditAccessEndpoints.cs`, testy |
| **E05** | Klient: enrollment kódem, přepínač/označení režimu, banner + auditor v seznamu členů (KB1), založení business skupiny/1:1, správa organizace a schvalování pro adminy (ve Flutter app — **[PŘEDPOKLAD]** místo samostatné Blazor konzole, aby nevznikl druhý frontend stack; přehodnotit po pilotu) | E01, E02 kontrakty | `lib/features/organization/**`, úpravy `features/groups`, `features/chat`, `calltype_core` DTO/API, testy |
| **E07** | **Nouzový kanál** (spec 2.3, fáze 1): `EmergencyKit` = předem vydaný offline enrollment balíček (jednorázové kódy + recovery kód, tisknutelný/QR) nezávislý na infrastruktuře zákazníka — žádné SSO, žádný firemní e-mail; nouzová skupina organizace s auditorem; **cvičení (drill)**: admin spustí test, členové potvrdí dosažitelnost, vznikne `EmergencyDrill` záznam; **export „doklad o existenci a funkčnosti nouzového kanálu“** (PDF/JSON: složení týmu, datum posledního úspěšného cvičení, doba odezvy, konfigurace archivace, otisk denního kořene) | E01, E02, E05 | `CallType.Audit/Emergency/**`, `Endpoints/EmergencyEndpoints.cs`, `lib/features/organization/emergency/**`, testy |
| **E06** | Přejímka + dokumenty: scénáře níže, texty transparentnosti v UI a na webu (`www/`), aktualizace README/CLAUDE.md („server nevidí obsah“ platí pro anonymní režim; v business režimu obsah vidí archiv organizace) | vše | `docs/acceptance/business-mode.md`, `www/**` |
| **M0** | **MLS spike** (souběžně, izolovaně): `spikes/mls/` — OpenMLS přes `flutter_rust_bridge`; dva klienti + třetí člen (auditor) v jedné skupině, zpráva tam a zpět, přidání/odebrání člena; cíle **web (WASM), Android, iOS, Windows** | — | `spikes/mls/**` (nic v produkčním kódu) |

Vlny: E00 → (E01 ∥ E02 ∥ M0) → (E03 ∥ E05) → (E04 ∥ E07) → E06. E03b až po vyhodnocení pilotu/M0.

## 6. MLS spike — výstupní kritéria (M0)

Report `spikes/mls/REPORT.md` s K06 statusy: build a běh na každé cílové platformě; velikost WASM/binárek; doba `create group / add / encrypt / decrypt`; perzistence stavu skupiny (kam a jak — Drift/secure storage); chování při souběžných commit zprávách; co je potřeba na serveru (Delivery Service: pořadí handshake zpráv, KeyPackage úložiště). Rozhodnutí: **GO** (krok 2 = MLS pro business skupiny), **GO s výjimkou** (např. web přes jinou cestu), nebo **NO-GO** + alternativa (gRPC krypto služba nedává smysl pro klienta — alternativou je setrvat u fan-outu a mez KB2 řešit jinak). Spike nic nemerguje do `src/`.

## 7. Přejímací kritéria (E06)

- **Anonymní režim beze změny:** celá stávající sada testů zelená; anonymní skupina nikdy neobsahuje auditora a nic se nearchivuje (test hledá zápisy v audit DB → 0).
- **KB1:** business skupinu bez auditora nelze vytvořit; auditora nelze odebrat; klient ho zobrazuje a banner je trvalý (widget test).
- **KB2:** zpráva bez payloadu pro auditora → odmítnuta, žádný zápis ve frontě; s payloadem → doručena všem + archivována právě jednou (idempotence přes `MessageId`).
- **KB3:** audit DB role nemůže `UPDATE/DELETE` (test se pokusí a očekává chybu oprávnění); v audit DB ani v logách není plaintext (syntetický marker); řetěz hashů ověřitelný offline nástrojem; ruční změna řádku superuživatelem je ověřením odhalena.
- **KB4:** pro každý den existuje kořen s razítkem (v testu fake TSA); `audit-verify` ověří libovolný záznam proti orazítkovanému kořeni bez přístupu k DB; záznam změněný superuživatelem ověřením neprojde.
- **E07:** zapsání zařízení nouzovým balíčkem funguje bez e-mailu/SSO; opakované použití kódu → odmítnuto; cvičení vytvoří záznam; export dokladu obsahuje datum posledního úspěšného cvičení a je reprodukovatelný.
- **KB5:** žadatel si nemůže schválit sám; čtení mimo okno → 410; každé čtení má záznam v `AuditAccessLog`; členové dostanou oznámení.
- **KB6:** každá změna členství/role má událost; export CSV/JSON; žádný obsah zpráv.
- **Revokace:** zrušený enrollment → zařízení zmizí z business skupin, nové zprávy nedostane, anonymní chaty mu fungují dál.
- **Oddělení:** kompromitace Delivery credentials nedává přístup k audit DB (různé role; test připojení).
- **Poctivost textů:** UI i web uvádějí mez KB2 a fakt, že vlastní kryptografie není auditovaná.

## 8. Otevřené otázky pro zadavatele

0. **Validační milník (spec kap. 12) není doložen.** Specifikace říká „nekódovat, dokud 3 organizace pod ZoKB nepotvrdí (a) chybějící nouzový kanál, (b) vědomí povinnosti, (c) ochotu platit“. Doporučení: E00–E02 + E07 jsou levné a slouží zároveň jako demo pro validační rozhovory; E03b, E04 a krok 2 (MLS) spustit až po splnění milníku. Rozhodnutí je na zadavateli.
1. ~~Plný text specifikace~~ — doplněn 2026-09-18.
2. Account povinný pro správce, volitelný pro členy — potvrdit **[PŘEDPOKLAD]**.
3. Oznamovat členům otevření archivu — potvrdit s právníkem; totéž texty banneru a poučení (§ 316 ZP, GDPR, DPIA). Právní balíček je mimo tento plán.
4. ~~Přílohy~~ — dle spec 5.4 v kroku 1 jen metadata (hash, velikost, typ); `full+attachments` mimo plán.
5. Hovory: jen metadata (kdo, kdy, délka), nikdy média — potvrdit.
6. Admin konzole ve Flutter app vs. Blazor Server (spec kap. 6) — rozhodnout po pilotu.
6b. Poskytovatel časových razítek (PostSignum / I.CA) a účet — potřebné až pro produkční KB4; do té doby fake TSA a poctivý text „interní integrita“.
7. Kde poběží archivátor v betě (App Service WebJob / druhý proces / externí server) — jedna B1 instance má omezenou paměť.

## 9. Mimo rozsah

Skrytý/neviditelný audit; SSO a napojení firemní identity; vynucované bezpečnostní politiky zařízení (MDM); fakturace a tarify; threshold kryptografie pro archivní klíč; federace mezi organizacemi; message broker; přepis anonymního režimu na MLS; právní posudek a vzorové dokumenty.
