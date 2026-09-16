# CallType — podrobné zadání dokončení bety

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Pracuj jen na přiděleném balíčku a dodrž vlastnictví souborů.

**Goal:** Dokončit, provozně zabezpečit a doložit funkčnost současné bety CallType pro Android, iOS, web, Windows a macOS.

**Architecture:** Zachovat Flutter klienta, ASP.NET Core API se SignalR, PostgreSQL a privátní Blob. API běží v jedné instanci Linux App Service B1; web v Static Web Apps Free; PostgreSQL a coturn na existujícím serveru.

**Tech Stack:** Flutter 3.41.x/Dart, Provider, Drift/SQLite, .NET 10, EF Core/Npgsql, WebRTC, Azure, GitHub Actions.

**Spec:** Výchozí stav popisují `README.md`, `docs/beta-status.md`, `docs/azure-beta-plan.md`. Tento dokument a tři připojené dokumenty jsou nové zadání k 16. 9. 2026.

## 1. Jak zadání používat

Toto je zadání další práce, nikoli potvrzení, že zde popsané změny již existují. Rozsah odvozuji z aktuálního repozitáře: dokončení existující bety. Nový produkt, přepis kryptografie ani vydání do obchodů nejsou součástí tohoto kola.

Čti v tomto pořadí:

1. Tento dokument — rozsah, pořadí, rozdělení práce a release brány.
2. [Společné kontrakty](2026-09-16-beta-kontrakty.md) — závazná rozhraní a význam stavů.
3. [Vývojové balíčky](2026-09-16-beta-vyvoj.md) — backend, klient, push, hovory, CI a přejímka.
4. [Infrastrukturní balíčky](2026-09-16-beta-infrastruktura.md) — Azure, PostgreSQL, TURN, provoz a náklady.

Každému pracovníkovi dej tyto první dva dokumenty a právě jeho balíček. Názvy souborů uvedené jako „nové“ jsou návrh, ostatní odkazují na existující strukturu. Cesty jsou relativní ke kořeni repozitáře. Zdroje kódu mají přednost před zastaralými komentáři.

## 2. Výchozí stav a zjištěné mezery

Zdrojové soubory a dokumentace byly při přípravě přečteny. V této úloze se znovu nespouštěly testy, cloudové kontroly ani reálné hovory. Čísla 108 backendových a 120 Flutter testů jsou historický výsledek z 13. 9., nikoli výsledek této práce.

| Oblast | Existuje | Další práce |
| --- | --- | --- |
| Identita a chat | Anonymní zařízení, JWT, kontakty, párové šifrování, skupiny | Regrese reconnectu, skupin a deduplikace na cílových platformách |
| Spolehlivost | Uložení před odesláním, potvrzení po lokálním zápisu, replay | Ověřit pády mezi jednotlivými kroky a retry bez změny ciphertextu |
| Přílohy | Limit 256 KiB, šifrovaný přenos | Hraniční velikosti, export, platformní oprávnění |
| Zálohy | Šifrování v klientovi, Blob, autorizace, obnova historie | Omezení spotřeby, konzistence DB/Blob, skutečná obnova v klientovi |
| Hovory | WebRTC, přijmout/odmítnout, callId, cleanup | Skutečný zvuk/video, oddělené sítě, vynucený TURN |
| Push | FCM HTTP v1 a registrace tokenu | Příjem/zobrazení, konfigurace providerů, zařízení a lifecycle |
| Nasazení | Dle záznamu App Service B1 + SWA Free | Reprodukovatelnost a odstranění nesouladu deploy workflow |
| Databáze | TLS spojení dle záznamu | Ověřování certifikátu a doložená obnova |
| Distribuce | Lokální web/Android/Windows buildy | Hosted CI, Apple buildy, podpis a akceptace |

Konkrétní nesoulad: `.github/workflows/deploy.yml` stále nasazuje Container Apps přes ACR, zatímco provozní dokumentace popisuje App Service. `infra/main.bicep`, `infra/beta-vm.bicep` a `infra/beta-compose.yml` nejsou šablony současné bety. Nespouštět je jako zkratku.

Pracovní strom obsahuje velké množství již existujících změn. Nikdo nesmí provést reset, clean, hromadný checkout nebo zahrnout cizí změny do svého commitu.

## 3. Globální omezení

- Zachovat .NET 10, Flutter 3.41.x, Provider a existující architekturu. Verze nástrojů pro reprodukování zapíše B00; neaktualizovat závislosti plošně.
- Server nesmí dešifrovat zprávy ani zálohy. Do logů nesmí obsah, klíče, hesla, JWT, push tokeny ani query `access_token`.
- Příloha maximálně 262144 bajtů před kódováním. TTL serverové fronty 30 dní. Časy serveru `DateTimeOffset` v UTC.
- SQLite není SQLCipher. Vlastní kryptografie není oficiální libsignal ani auditované řešení. Neslibovat opak.
- Jedna API instance kvůli paměťovému směrování. Horizontální škálování vyžaduje samostatné zadání.
- Zachovat nynější protokoly. Historické zprávy nebo klíče se nesmí tiše přepisovat ani smazat.
- Integrační DB testy používají skutečný PostgreSQL přes Testcontainers; testy Blob používají Azurite. Chybějící Docker znamená BLOCKED, nikoli PASS.
- Rozpočtový cíl je maximálně 20 USD/měsíc. Historický odhad 14–16 USD není aktuální cenová nabídka ani záruka stropu.
- Návrh neautorizuje nové placené prostředky, zásah do produkčních dat ani publikaci do obchodů. Lokální kód, testy, návrhy a dry-run lze připravit nezávisle.

## 4. Organizace paralelní práce

B00 nejprve připraví společný výchozí commit obsahující odsouhlasený aktuální stav. Každý pracovník dostane samostatnou větev `codex/beta-<ID>` a izolovaný worktree z tohoto commitu. Nepoužívat čistý HEAD, který neobsahuje nynější necommitnuté funkce. Pracovník nevytváří další větev z náhodné rozpracované větve.

| ID | Výstup | Závislosti před implementací | Výhradní vlastnictví |
| --- | --- | --- | --- |
| B00 | Baseline, rozhraní a integrační změny | Žádné | Program.cs, appsettings*, AppDbContext.cs, Migrations/, app/, main.dart, api_client.dart, pubspec.*, sdílená DB |
| D01 | Spolehlivé doručení a skupiny | B00 | Hub, queue, chat/inbox/group moduly a jejich testy |
| D02 | Omezené a konzistentní zálohy | B00; limity z kontraktů | BackupEndpoints, nové backup služby, features/backup, backup_api a testy |
| D03 | Push zpráv | B00 | Push služby server/klient, FcmTokenProvider a nové push testy |
| D04 | Hovory a média | B00 | webrtc_manager, call_screen a jejich testy |
| D05 | Konfigurace a ochrana API | B00 | nové validační/health služby a nové testy; zapojení přes B00 |
| R01 | CI/CD a platformní balení | B00, I01 pro deploy; D03 pro Firebase integraci | .github/workflows/, platformní projekty android/ios/macos/windows/web |
| I01 | Současná infrastruktura jako kód | B00 | nové beta App Service šablony a inventura |
| I02 | PostgreSQL TLS a obnova | I01 inventura | nové DB provozní skripty a runbook |
| I03 | TURN provoz | I01 inventura | nové coturn konfigurace a runbook |
| I04 | Náklady, limity a dohled | I01 inventura; D02/D05 pro propojení | rozpočtové a provozní dokumenty/skripty |
| Q01 | Přejímací protokol a release rozhodnutí | všechny dokončené relevantní balíčky | docs/acceptance/, závěrečné status dokumenty |

Předpis konkrétního balíčku dále zužuje tabulku. Kolize řeší B00 před editací. D03 například předá R01 požadavky na Firebase soubory/oprávnění a sám nemění platformní adresáře. D01/D02 předají B00 změnu schématu; migraci generuje pouze B00 z integrovaného modelu.

**Vlny:**

1. B00: snapshot, baseline a zafixování kontraktů. I01 může souběžně pouze číst inventuru.
2. Paralelně D01, D02, D03, D04, D05 a I01; R01 může připravovat testovací/build část.
3. I02, I03 a I04 po inventuře; R01 dokončí deploy podle I01. B00 postupně zapojuje registrace a migrace.
4. Q01 a skutečné zařízení/provoz. Závady se vrací vlastníkovi, nevytváří se druhý konkurenční patch.

Při třech pracovnících obsazuj například D01 + D02 + I01; po dokončení D03 + D04 + I02; poté D05 + R01 + I03; nakonec I04 + Q01. To je rozvrh kapacity, nikoli náhrada závislostí.

## 5. Povinný postup každého pracovníka

- [ ] Přečíst svůj balíček, kontrakty a uvedené zdroje; uvést baseline commit.
- [ ] Ověřit, zda požadované chování již existuje. Fungující část pouze pokrýt chybějícím scénářem, nepsat ji znovu.
- [ ] Pro změnu chování nejprve přidat test s konkrétním očekáváním a prokázat, že selže ze správného důvodu.
- [ ] Implementovat nejmenší změnu v povolených souborech. Složitější důvody vysvětlit komentářem.
- [ ] Spustit cílené testy, pak příslušnou celou sadu. Uvést příkaz, návratový kód a počty PASS/FAIL/SKIP.
- [ ] Předat integrátorovi diff, nové konfigurační klíče, migrace a omezení. Nic automaticky nenasazovat.
- [ ] Přiložit důkazy podle šablony níže. Nedostupný provider nebo zařízení je konkrétní blokace.

```text
Balíček: D01
Baseline commit: <skutečné SHA>
Výsledný commit: <skutečné SHA>
Změněné soubory: <úplný seznam>
Splněná přejímací kritéria: <ID scénářů>
Ověření: <příkaz, exit code, datum, prostředí, cesta k logu>
Změny kontraktů: žádné / <přesný návrh pro B00>
Blokace: žádná / <chybějící vstup a co kvůli němu nešlo ověřit>
Rollback: <konkrétní postup pro tento diff>
```

Úhlové závorky v této šabloně jsou pole pro výsledek pracovníka, nikoli hodnoty k vložení do zdrojového kódu.

## 6. Brány dokončení

**G1 — technická integrace:** backend a Flutter testy zelené na sloučeném commitu, analyzer bez chyb, negativní autorizace a retry scénáře ověřené. Starý počet testů není pevná metrika úspěchu; úbytky musí mít vysvětlení.

**G2 — infrastruktura:** žádný deploy do staré architektury; ověřený DB certifikát, izolovaná obnova dat, autentizovaný TURN, nákladový model s limity. Otevřené fakturační vstupy nesmí být označené jako vyřešené.

**G3 — platformy:** každá z pěti platforem má build, instalaci/spuštění a přejímací protokol. Unsigned iOS build není instalace na fyzickém zařízení. Platforma bez důkazu zůstává neověřená.

**G4 — funkce:** obousměrný chat, offline doručení, skupiny, přílohy, záloha/obnova a hovory přes TURN prošly Q01; notifikace mají zaznamenané podporované platformy a omezení.

**G5 — vydání:** artefakty odpovídají stejnému commitu, mají správnou API URL, kontrolní součty a dokumentovanou cestu návratu. Uživatel dostane přesný seznam neověřených funkcí. „Pětiplatformní beta dokončena“ lze napsat jen po splnění všech pěti platforem; dílčí vydání označit konkrétně.

## 7. Vstupy, které se musí získat před příslušným krokem

Přípravu kódu neblokují; blokují pouze konkrétní provozní akci.

| Vstup | Potřebuje | Bez něj |
| --- | --- | --- |
| Azure subscription, oprávnění a skutečná inventura | I01, R01 | Pouze lokální validace, žádný deploy |
| DNS jméno DB odpovídající certifikátu a CA | I02 | Nelze potvrdit VerifyFull |
| Přístup k existujícímu serveru a provozní okno | I02/I03 | Pouze runbook, žádná změna firewallu/restart |
| Firebase projekt, Apple tým, push konfigurace | D03/R01 | Mock testy ano, reálný push BLOCKED |
| Mac/Apple runner, fyzický iPhone a podpisové identity | R01/Q01 | Apple device acceptance BLOCKED |
| Zda 20 USD zahrnuje DPH a stávající server; limity přenosu serveru | I04 | Nelze slíbit rozpočtový strop |

## 8. Záměrně mimo rozsah

SQLCipher migrace, přechod na libsignal/Sender Keys, multi-instance SignalR, vlastní doména, velké přílohy, synchronizace živé identity mezi zařízeními a automatické vydání do obchodů mají samostatné zadání, až vznikne konkrétní požadavek. Příchozí VoIP hovor v ukončené mobilní aplikaci také vyžaduje samostatné platformní zadání; obyčejný FCM push není jeho náhradou.
