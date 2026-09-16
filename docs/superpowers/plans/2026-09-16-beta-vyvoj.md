# CallType — vývojové balíčky Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Checkboxy označují jednotlivé kroky; každý balíček má samostatnou přejímku.

**Goal:** Dokončit chybějící provozní a platformní chování bety bez přepisu již funkčních modulů.

**Architecture:** Rozšiřovat existující endpointy a feature-first Flutter moduly. Sdílené změny integruje B00.

**Tech Stack:** .NET 10, Flutter 3.41.x, Provider, PostgreSQL/Testcontainers, Azurite, GitHub Actions.

**Spec:** [Hlavní zadání](2026-09-16-beta-zadani.md), [kontrakty K01–K06](2026-09-16-beta-kontrakty.md).

## Společné ověření a hranice

Každý balíček přebírá všechna globální omezení hlavního zadání. Kroky jsou pracovní postup, nikoli povolení měnit cizí soubory. Backendový balíček končí plnou backendovou sadou; klientský analyzérem a Flutter sadou. Q01 je znovu provede na integrovaném commitu.

Z kořene:

```powershell
dotnet test src/server/CallType.Api.Tests --configuration Release --logger trx --results-directory TestResults
```

Z `src/client/calltype`:

```powershell
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

Očekávání: exit code 0; žádné nově přeskočené testy. Build runner nespouštět současně s jiným pracovníkem nad stejnou pracovní kopií. Žádná změna generovaných souborů bez odpovídajícího zdroje. Produkční data nejsou testovací fixture.

## B00 — koordinátor, baseline a společné zapojení

**Výsledek:** všichni vycházejí ze stejné skutečné verze; společné soubory mají jediného vlastníka.

**Soubory:** `src/server/CallType.Api/Program.cs`, `appsettings*.json`, `Data/AppDbContext.cs`, `Migrations/`; `src/client/calltype/lib/main.dart`, `lib/app/`, `lib/core/network/api_client.dart`, `lib/core/network/signalr_client.dart`, `lib/core/storage/`, `pubspec.yaml`, `pubspec.lock`. Nový záznam `docs/acceptance/baseline.md`.

**Rozhraní:** přijímá od D01–D05 požadavky na registraci, konfiguraci, DB migraci nebo lifecycle; vrací přesný commit se společnou integrací. `signalr_client.dart` je výslovně B00; D01/D04 ho pouze čtou a předávají návrh změny.

- [ ] Zapsat `git status --short`, `git rev-parse HEAD`, `dotnet --info`, `flutter --version`, `docker version`; nevypisovat prostředí s tajemstvími.
- [ ] Rozlišit stávající uživatelské změny a projektové změny. Připravit pojmenovaný baseline commit pouze z odsouhlasených souborů; necommitovat automaticky celý pracovní strom.
- [ ] Spustit výše uvedené sady a uložit skutečný baseline; při chybě nástroje uvést blokaci, při regresi samostatný problém.
- [ ] Potvrdit kontrakty K01–K06 a přidělit balíčky/izolované worktrees. B00 nepotřebuje vyřešit všechny provozní vstupy před zahájením lokálního vývoje.
- [ ] Pro každou změnu schématu nejprve převzít model/test očekávání, poté vytvořit jedinou konzistentní EF migraci. Ověřit upgrade kopie předchozího schématu s frontou a zálohami.
- [ ] Zapojovat malé dokončené balíčky; po změně společných souborů spustit dotčené sady.

**Přejímka B00-A:** všechny větve sdílejí stejnou základnu; seznam vlastnictví nemá překryvy. **B00-B:** migrační test zachová dosavadní zprávy, účty a zálohy. **B00-C:** žádný secret v commitu.

**Rollback:** vrátit konkrétní integrační commit; databázi nevracet destruktivní Down migrací nad živými daty. Pro nekompatibilní schéma použít předem ověřenou obnovu I02.

## D01 — doručení, skupiny a přílohy

**Výsledek:** existující mechanismus K01 prokazatelně neztrácí zprávy při přerušení a nevytváří duplicity v UI.

**Vlastní soubory:** `src/server/CallType.Api/Hubs/MessengerHub.cs`, `Services/MessageQueueService.cs`, `Services/MessageCleanupService.cs`; odpovídající `CallType.Api.Tests/Hubs/MessengerHubTests.cs` a `Services/MessageQueueServiceTests.cs`, `MessageCleanupServiceTests.cs`; klientské `lib/features/chat/`, `lib/features/groups/`, `lib/features/chat_list/` a testy těchto adresářů. `Endpoints/GroupEndpoints.cs` a jeho testy pouze pokud přejímka prokáže chybu autorizace členství.

**Čte:** `session_manager.dart`, `group_cipher.dart`, `signalr_client.dart`, `database.dart`. Kryptografii ani společnou DB nepřepisuje. Potřebné změny předá B00; samostatná změna kryptografie vyžaduje konkrétní reprodukční test.

**Vstupy/výstupy:** K01, K02. Zachovat metody hubu, payload ReceiveMessage a per-recipient fan-out.

- [ ] Prohlédnout současné queue/inbox testy a označit, které scénáře níže již pokrývají.
- [ ] Přidat chybějící test pro pád po serverovém zápisu, ale před odpovědí. Zopakovat stejné UUID a ciphertext; očekávat jeden serverový záznam a jednu klientskou zprávu.
- [ ] Přidat test pro ztracený ACK: uložit zprávu v klientovi, zahodit ACK, přehrát ji. Očekávat jeden řádek a nový ACK bez opětovného posunu kryptografické session.
- [ ] Přidat test selhání lokální transakce: neodeslat ACK a při novém replay úspěšně uložit zprávu.
- [ ] Přidat test cizího ACK a přepsání stejného ID jiným payloadem/groupId. Očekávat zamítnutí bez změny původního záznamu.
- [ ] Přidat skupinový scénář A/B/C: A odešle B i C, B je offline; po reconnectu dostane B jednu zprávu ve správné skupině. Po odebrání C nesmí nový fan-out obsahovat C; pokus C o nové odeslání se zamítne. Dříve zařazené zprávy posuzovat podle existující politiky, nezavádět zpětné mazání historie.
- [ ] U příloh pokrýt 262144 bajtů, 262145 bajtů, poškozená metadata a jméno obsahující `../`. Export nesmí zapisovat mimo uživatelem zvolené místo.
- [ ] Ověřit celkový limit skupinové SignalR invokace. Nadlimitní fan-out musí skončit viditelnou chybou bez falešného „odesláno“; nevydávat limit souboru za záruku přenosu do libovolně velké skupiny.
- [ ] Opravit pouze reprodukované chyby a spustit obě celé sady.

**Cílené příkazy:** `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~MessengerHubTests`; z klienta `flutter test test/features/chat test/features/groups`.

**Přejímka D01-A až G:** všech sedm scénářů výše doloženo testem nebo existujícím přesným testem; retry zachovává ciphertext; žádný serverový plaintext. Test průběhu retry musí kontrolovat i počet zápisů, nestačí pouze porovnat zobrazený text.

**Rollback:** vrátit vlastní diff; ponechat původní protokol a data. Nový stav schématu koordinovat přes B00.

## D02 — omezené zálohy a atomická obnova

**Výsledek:** záloha má předvídatelnou maximální spotřebu; chyby nezničí historii a nevytvoří trvalé neúčtované Blob objekty.

**Soubory:** `Endpoints/BackupEndpoints.cs`, `Models/Backup.cs`, nové `Services/BackupStorageService.cs`, `Services/BackupCleanupService.cs`, `Configuration/BackupLimitsOptions.cs`; `Endpoints/BackupEndpointsTests.cs`, nové `Services/BackupStorageServiceTests.cs`; klient `lib/core/network/backup_api.dart`, `lib/features/backup/`, `test/features/backup/`. DB registrace/migrace B00.

**Rozhraní:** K03 je závazné HTTP rozhraní. Vnitřní služba musí zpřístupnit upload/list/download/delete potřebné endpointům; přesné C# signatury pracovník nejprve zapíše do svého návrhu a nechá sjednotit B00 před zásahem do sdíleného DI. Ostatní balíčky nevolají tuto vnitřní službu.

- [ ] Nejprve zapsat stavový diagram rezervace → upload → dokončeno → mazání → odstraněno, včetně pádu mezi každými dvěma kroky; určit transakční hranice.
- [ ] Napsat integrační testy K03: prázdný/velký soubor, čtvrtý upload, globální bajty, vlastnictví, idempotentní delete.
- [ ] Přidat souběžný test: zbývá místo na jeden upload, spustí se dva. Právě jeden uspěje; součet rezervací i hotových souborů nepřekročí limit. Testovat přes reálný PostgreSQL, ne in-memory kolekci.
- [ ] Přidat fault injection testy pro Blob úspěch/DB výpadek a restart po rezervaci. Cleanup smí odstranit jen prokazatelně osiřelý objekt, nikdy aktivní upload.
- [ ] Implementovat rezervace a kompenzace; po delete uvolnit kapacitu až po potvrzení smazání Blob. Zdokumentovat co se děje při překročené kapacitě již existujících dat: zachovat je, blokovat nové uploady, umožnit download/delete.
- [ ] V UI přidat limit a srozumitelné chyby 413/409; mazání vyžaduje vědomou uživatelskou akci a obnoví seznam po 204.
- [ ] Roundtrip test historie s diakritikou a přílohou: export → šifrovat → upload → download → decrypt → import do druhé lokální DB. Porovnat obsah a nepřevzít původní deviceId/klíče/session.
- [ ] Špatné heslo, poškozený blob a přerušení importu ponechají původní DB beze změny. Zajistit transakci celé obnovy, nikoli po jednotlivých řádcích.

**Ověření:** `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~Backup`; z klienta `flutter test test/features/backup`. Poté celé sady.

**Přejímka:** všechny HTTP kódy K03, souběžnost a fault injection projdou; cleanup má omezenou dávku a lze jej opakovat. Do reportu uvést velikost před/po a prokazatelně odstraněné osiřelé objekty.

**Rollback:** vypnout nové uploady, zachovat download existujících záloh; vrátit aplikaci jen na verzi kompatibilní s novým schématem. Žádné plošné mazání kontejneru.

## D03 — push zpráv

**Výsledek:** podporované platformy zobrazí obecné upozornění a po otevření dočtou frontu. Nezaručuje příchozí VoIP hovory při ukončené aplikaci.

**Soubory:** server `Services/PushNotificationService.cs`, `Services/FcmTokenProvider.cs`, jejich existující testy; klient `lib/core/network/push_service.dart`, nový `test/core/network/push_service_test.dart`. Platformní konfiguraci vlastní R01, startup B00.

**Rozhraní:** zachovat `SendPushAsync(Guid recipientDeviceId)` a registraci tokenu v ApiClient. K04 určuje obsah i chování. Případnou veřejnou změnu PushService předat B00 ještě před integrací.

- [ ] Ověřit aktuální implementaci; FCM HTTP v1 je již přítomné, nemigrovat znovu z legacy API.
- [ ] Testovat odpověď s UNREGISTERED, obecnou 404 bez tohoto kódu, 401, 429, 500 a timeout. Jen první případ odstraní použitý token; rotace během requestu nesmí odstranit nový token.
- [ ] Opravit vyhodnocování odpovědi a redakci logů. Nezapisovat celé tělo provider chyby, pokud může obsahovat token/payload.
- [ ] Implementovat foreground/background obsluhu podle podporovaných Firebase platforem. V popředí zabránit duplicitní notifikaci stejné události. V pozadí použít mechanismus, který lze reálně ověřit na dané platformě; samotný data-only handler není důkaz viditelné notifikace.
- [ ] Předat R01 přesný seznam konfigurace Firebase, web workeru/VAPID a Apple capabilities; veřejnou konfiguraci odlišit od serverového service-account tajemství.
- [ ] Testovat permission denied, chybějící konfiguraci, změnu tokenu, opakované initialize/dispose a obnovení registrace po síťové chybě. Nesmí narůstat počet listenerů ani blokovat chat.
- [ ] Na fyzickém Android/iOS a podporovaném webu/macOS zapsat foreground/background/OS-terminated/force-stop jednotlivě. Nedostupný scénář označit podle K06; nepřevádět chování jedné platformy na všechny.

**Ověření:** `dotnet test src/server/CallType.Api.Tests --filter FullyQualifiedName~PushNotificationServiceTests`; `flutter test test/core/network/push_service_test.dart` a celé sady.

**Přejímka:** žádný plaintext v provider requestu, žádná ztracená queued message při výpadku FCM, žádné mazání nového tokenu. Poklep na notifikaci nezaloží druhé zařízení a zpráva se zobrazí jednou.

**Rollback:** vypnout push konfiguraci a vrátit službu; zachovat frontu i běžné doručení při otevření aplikace.

## D04 — hovory a lifecycle médií

**Soubory:** `lib/core/network/webrtc_manager.dart`, `lib/features/calls/call_screen.dart`, `test/core/network/webrtc_manager_test.dart`. Změny transportu přes B00. Vstup K02 a TURN výstup I03.

- [ ] Zachovat existující testy rychlé answer/ICE, cancellation a stale hangup. Přidat zamítnutý mikrofon, zamítnutou kameru a výpadek spojení během hovoru.
- [ ] Každý terminální stav musí zavřít peer connection, zastavit media tracks a zrušit timery/listenery. Assertovat tyto účinky, nestačí stav `idle`.
- [ ] Přidat opakovaný hovor A→B, ukončit, ihned zahájit nový; pozdní ICE/hangup prvního hovoru nesmí druhý ukončit.
- [ ] Připravit testovací možnost vynucení ICE relay, standardně vypnutou. Uložit jen redigovaný typ vybraného kandidáta/protokol a callId, nikoli SDP s osobními síťovými údaji.
- [ ] S I03 provést zvuk/video mezi dvěma odlišnými sítěmi; spojení musí mít vybraný relay kandidát. Samostatně vyzkoušet variantu bez UDP a doložit skutečný fallback nebo konkrétní selhání.
- [ ] Ověřit ztlumení, kamera on/off, odmítnutí hovoru, timeout bez odpovědi, přesun aplikace do pozadí a návrat. Popisovat skutečné platformní chování.

**Ověření:** `flutter test test/core/network/webrtc_manager_test.dart`, celý Flutter test/analyze. Reálný hovor alespoň 3 minuty, obě strany slyší a vidí druhou stranu, poté nesvítí indikátor aktivního mikrofonu/kamery.

**Přejímka:** důkaz typu relay a obousměrných médií; protokolový coturn test sám nestačí. Pro každou platformu Q01 páruje testované zařízení s druhou stranou a zapisuje síť i výsledek.

**Rollback:** vrátit vlastní změny, vypnout testovací forced-relay režim. Neměnit formát call envelope.

## D05 — validace konfigurace a health

**Soubory:** nové `Configuration/ProductionConfigurationValidator.cs`, `Services/ReadinessService.cs`, `Endpoints/HealthEndpoints.cs`, nové `CallType.Api.Tests/Configuration/ProductionConfigurationValidatorTests.cs`; rozšířit `HealthCheckTests.cs`, `Endpoints/RateLimitTests.cs`. Program.cs mění B00 na základě předaného zapojení.

- [ ] Implementovat testy produkčního startu bez JWT secretu, s krátkým secretem, se známou dev hodnotou a bez explicitního CORS. Očekávat odmítnutí startu s názvem klíče bez jeho hodnoty.
- [ ] Zachovat lokální Development režim z Compose; test ho odliší od Production.
- [ ] Přidat readiness podle K05: zdravé služby 200, vypnutý PostgreSQL 503, nedostupný Blob 503, timeout nejvýše 5 s. Liveness při těchto výpadcích zůstává 200.
- [ ] S I01 zapsat skutečnou proxy topologii; ověřit rate limit ze dvou klientů a podvržené X-Forwarded-For. Nehardcodovat aktuálně náhodně pozorovanou proxy IP bez provozního postupu aktualizace.
- [ ] Zkontrolovat logování `/hub?access_token=...`, výjimky a provider odpovědi. Přidat test log sinku, který odmítne výskyt syntetického secretu/token markeru.
- [ ] Předat B00 přesné DI registrace, mapování health a pořadí middleware; poté ověřit na integrovaném commitu.

**Přejímka:** testy výše, zachované auth/CORS preflight, žádné secret hodnoty v logu. D05 nezavádí placený monitoring.

**Rollback:** návrat konkrétního diffu/config; neobcházet validační chybu přepnutím produkce na Development.

## R01 — CI/CD, Firebase konfigurace a artefakty

**Soubory:** `.github/workflows/ci.yml`, `.github/workflows/deploy.yml`; platformní adresáře `src/client/calltype/android/`, `ios/`, `macos/`, `windows/`, `web/`; nový `docs/acceptance/release-builds.md`. `pubspec.*` mění B00. Infrastrukturní šablony vlastní I01.

**Vstupy:** B00 baseline, I01 skutečné identifikátory prostředků a deployment metoda, D03 platformní požadavky. **Výstupy:** testované artefakty konkrétního SHA a ručně spustitelné nasazení do existující bety.

- [ ] Zrušit automatickou cestu do starých Container Apps/ACR. Nový deploy musí cílit výhradně na existující App Service/SWA a selhat při chybějícím cíli, ne vytvořit náhradní infrastrukturu.
- [ ] Zachovat test gates před buildy; zahrnout cesty infra a workflow do odpovídajících validačních triggerů. Nedůvěryhodný PR nesmí získat produkční secrets.
- [ ] Oddělit lokální development build od distribučního buildu. Release job musí odmítnout prázdné API URL, HTTP a localhost/loopback. Žádný fallback na localhost pro distribuovaný artefakt.
- [ ] Přidat build manifest: commit SHA, Flutter/.NET verze, cílová platforma, API URL a SHA256 artefaktu. API URL není tajemství.
- [ ] Sestavit všech pět cílů; Windows zabalit celý runtime adresář, Apple archivovat se zachováním executable permissions; web musí obsahovat sqlite3.wasm a drift_worker.js a správné MIME/routing.
- [ ] Začlenit D03 konfiguraci a platformní oprávnění; serverový Firebase service-account JSON nikdy nepatří do klientského artefaktu. Apple signing secrets zpřístupnit jen chráněnému prostředí; unsigned build jasně označit.
- [ ] Připravit deploy přes ruční workflow se zvoleným commit SHA; testy i publikované artefakty musí odpovídat právě tomuto SHA. Serializovat souběžné deploye stejného prostředí.
- [ ] Preferovat workload identity/OIDC, kde je v prostředí dostupné; nepřenášet staré ACR admin credentials do nové cesty. Ověřit minimální práva k existujícím prostředkům.
- [ ] Před deploy provést zálohu podle I02 a explicitní migration krok. Automatické migrace na produkčním startu vypnout až po ověření náhrady. B1 sloty nepředpokládat; počítat s krátkým výpadkem a reconnectem.
- [ ] Po nasazení provést `/health`, `/health/ready`, načtení webu a autentizovaný SignalR smoke test; při selhání zastavit další publikaci. Udržet předchozí artefakt pro návrat.

**Přejímka:** neplatná release API URL skutečně shodí job před publikací; pět buildů má dostupný artefakt; chybějící signing ≠ podepsaný release; neprojde deploy jiného SHA než ověřeného. Hosted workflow musí skutečně běžet, lokální parsování YAML nestačí.

**Rollback:** znovu nasadit předchozí známý artefakt a odpovídající web. DB rollback pouze kompatibilní schéma nebo ověřená obnova; deployment workflow musí tento rozdíl popsat.

## Q01 — společná přejímka na zařízení a release protokol

**Soubory:** nové `docs/acceptance/matrix.md`, `docs/acceptance/release-report.md` a redigované důkazy v `docs/acceptance/evidence/`. Po dokončení aktualizovat `README.md`, `docs/beta-status.md`, `docs/azure-beta-plan.md`, zastaralé tvrzení v `CLAUDE.md`; FABLE historicky označit, nepřepisovat historii na zdánlivě nový audit.

**Předpoklady:** integrovaný commit, testovací A/B/C zařízení, přístup k buildům, dvě různé sítě a provider konfigurace pro ověřované push platformy.

Každý řádek následující matice vyplnit pro Android, iOS, web, Windows a macOS. Výjimka musí uvést UNSUPPORTED/BLOCKED a konkrétní důvod.

| Scénář | Postup | Očekávaný výsledek |
| --- | --- | --- |
| Q01-01 start | Čistá instalace → onboarding → restart | Stejná identita po restartu, žádná registrace navíc |
| Q01-02 chat | A→B a B→A český text → restart obou | Správný text, žádné duplicity, historie zachována |
| Q01-03 offline | Zavřít B, odeslat 10 zpráv, znovu otevřít | Každá právě jednou v UI, žádná ztráta |
| Q01-04 reconnect | Odpojit síť při odesílání, obnovit síť | Retry bez duplikace, konečný stav v UI odpovídá realitě |
| Q01-05 skupina | A založí A/B/C, B offline, odebrat C | Správný routing a nové zprávy jen aktuálním příjemcům |
| Q01-06 soubor | Přesně 256 KiB a o 1 bajt více | První lze přijmout/exportovat, druhý jasně odmítnut |
| Q01-07 záloha | Záloha → druhé zařízení → obnova | Stejná historie, odlišná identita, zachovaná původní data při chybě |
| Q01-08 chyby obnovy | Špatné heslo a poškozený soubor | Žádný částečný import |
| Q01-09 hovor | 3 min zvuk/video přes vynucený relay | Média oběma směry a cleanup po ukončení |
| Q01-10 redial | Ukončit a okamžitě volat znovu | Staré události neovlivní nový hovor |
| Q01-11 oprávnění | Zamítnout kameru/mikrofon/notifikace | Žádný pád, vysvětlení v UI, chat funkční |
| Q01-12 push | Foreground, background a otevření notifikace | Výsledek dle doložené platformní podpory, zpráva jednou |
| Q01-13 konfigurace | Prohlédnout manifest a skutečné připojení | Správné produkční HTTPS API, žádný localhost |

- [ ] Spustit plné automatické sady na stejném commitu jako artefakty.
- [ ] Vyplnit matici podle K06, přiložit verzi OS/prohlížeče, zařízení, datum, partnerskou platformu a důkaz.
- [ ] Selhání převést na malý reprodukovatelný úkol pro původního vlastníka: kroky, očekávání, realita, log, závažnost.
- [ ] Po opravě zopakovat postižený scénář a nezbytnou regresi; nepřepsat neprovedený test na PASS.
- [ ] Zhodnotit G1–G5 hlavního zadání. Ztráta dat, obejití auth, únik tajemství, nespustitelný distribuovaný artefakt nebo nefunkční základní chat blokují vydání.
- [ ] Zapsat omezení: TOFU, vlastní neauditovaná kryptografie, nešifrovaná lokální DB, dostupnost push a VoIP v pozadí. Uživatel musí odlišit fungující funkci od budoucího plánu.

**Hotovo:** release-report obsahuje jediné konkrétní SHA, odkazy na důkazy všech balíčků a rozhodnutí po platformách. Pokud chybí Apple zařízení, napsat „Apple přejímka BLOCKED“, nikoli „pětiplatformní beta hotova“.
