# Jay Business — přejímka kroku 1 (E06), stav 2026-09-18

Integrační větev `business/base` (lokální, nepushnutá). Základ: `feat/bots-channels` @ `158b8d9`. Statusy dle K06.

## Balíčky

| Balíček | Commit | Stav | Poznámka |
| --- | --- | --- | --- |
| E00 základ (CallType.Audit, 2. DB, HashChain, kontrakty) | `1eb15fe` + review `a35143e` | DONE | review: migrace pod ops rolí (`ConnectionStrings:AuditMigrations`), default privileges, HashChain hardening |
| M0 MLS spike | `d402274` | DONE — GO s výjimkami | `spikes/mls/REPORT.md`; web runtime v prohlížeči NOT_RUN, iOS/macOS NOT_RUN |
| E01 organizace, role, pozvánky, enrollment, admin audit (KB6) | `6914144` | DONE | review: `FOR UPDATE` → advisory lock (app role nemá UPDATE) |
| E02 firemní skupiny, KB1 immutabilita, KB2 v hubu, revokace | `5221495` | DONE | |
| E03-lite archivátor (metadata, hash řetěz, ACK po zápisu) | `50cc75b` | DONE | bez Merkle/TSA/verify tool (E03b/E04) |
| E05 Flutter: enrollment, správa org, banner + auditor (KB1) | `02fdd4a` | DONE | review: `/groups/business`, `GET /groups/{id}`, normalizace rolí |
| E07 nouzový kanál: sady kódů, offline enrollment, cvičení, doklad | `90e7896` + `12a4bcd` | DONE | |

## Ověření na sloučeném stromu (`business/base`)

| Sada | Výsledek |
| --- | --- |
| `dotnet build CallType.sln -c Release` | 0 chyb |
| Backend unit testy bez DB (audit doména, HashChain, validator, emergency codes/proof, CSV escaping, TURN, FCM) | 77/77 PASS |
| Backend integrační testy (Testcontainers: business groups, hub KB2, org endpoints, archive API, emergency endpoints, audit role INSERT/SELECT only) | **PASS** — 2026-09-18 lokálně (Docker/Testcontainers), `dotnet test src/server/CallType.Api.Tests -c Release`: 325/325. První běh odhalil start API bez Business režimu (`af32ce9`) a 14 chyb v testech/fixture (auditor bez řádku v `Devices`, pořadí autentizace, REVOKE na neexistující `__EFMigrationsHistory`); produktový kód beze změny. Běh v CI zatím ne |
| `calltype_core` analyze + test | 114/114 PASS |
| `calltype` analyze + gen-l10n + test (vč. ARB parity 19 jazyků) | 188/188 PASS |
| `jay_archiver` analyze + test | 10/10 PASS |
| End-to-end (klient ↔ reálný server, archivátor běžící) | **PASS lokálně** — 2026-09-18, `src/bots/jay_archiver/test/e2e/business_mode_e2e_test.dart` proti docker-compose (`JAY_E2E_API=http://localhost:8080 dart test test/e2e`): 3 zařízení s reálným `calltype_core` kryptem, organizace → pozvánky → firemní skupina; KB1 auditor člen + odebrání 409, KB2 `audit_recipient_missing`, člen dešifruje, archivátor zapíše 1 záznam. **Nikdy nepouštět proti betě** (append-only audit). První běh našel 3 chyby klientského API (viz níže) a nefunkční Docker build API |
| End-to-end nouzový enrollment (E07) | **PASS lokálně** — 2026-09-18, `src/bots/jay_archiver/test/e2e/emergency_enrollment_e2e_test.dart` proti docker-compose: sada 2 kódů, zařízení bez účtu a bez pozvánky se zapíše kódem, znovupoužití kódu 410 `emergency_code_used`, cvičení dorazí přes hub a potvrzení se započte, odvolání sady → 410 `kit_revoked`, doklad neobsahuje žádný kód. Pozor: limit „auth“ 10/min na IP — oba E2E soubory dohromady spotřebují přesně 10, opakovaný běh do minuty končí 429. Vstup do nouzové konverzace a zpráva v ní NOT_RUN (klient po enrollmentu nezná `groupId`) |
| UI průchod na zařízení (banner KB1, auditor bez akce odebrání, obrazovka organizace) | NOT_RUN — ruční |
| Nasazení na betu | **PASS** — 2026-09-18, `25b5844`, [run 35337715526](https://github.com/zcloudcz/Jay/actions/runs/35337715526): testy, API, 5 klientských buildů, deploy API + web, smoke. Po deployi `/health/ready` 200, web 200. Business režim při deployi vypnutý; anonymní Jay beze změny |
| Zapnutí Business režimu na betě | **PASS (čtení)** — 2026-09-18: DB `calltype_audit` + role dle `audit-roles.sql`, `ConnectionStrings__Audit` (app role), migrace ručně jako ops (`AuditMigrations` v App Service záměrně nenastaven). Autentizovaný `GET /orgs/mine` → 200 `[]`. Zápis do auditu na betě NOT_RUN. Klient s chybami níže byl na betě jen mezi deployi `25b5844` a `9e0f7ae` |
| Nasazení oprav klienta | **PASS** — 2026-09-18, `9e0f7ae`, [run 35347457939](https://github.com/zcloudcz/Jay/actions/runs/35347457939) (testy, buildy, deploy, smoke); `/health/ready` 200, web 200. Obrazovka organizace na betě po opravě ručně NOT_RUN |

## Kontrakty — stav

- **KB1** viditelný auditor: server vytváří auditora atomicky, odebrání → 409; klient: trvalý banner, auditor v seznamu členů bez akce odebrání — implementováno, integrační/widget testy (widget PASS, integrační PASS).
- **KB2** vynucení na serveru: `audit_recipient_missing` v hubu — implementováno; test PASS. Známá mez (obsahová shoda) trvá do MLS.
- **KB3** archiv metadata-only, app role INSERT/SELECT, řetěz — implementováno; test role PASS.
- **KB4** Merkle + razítko — NOT IMPLEMENTED (mimo krok 1).
- **KB5** čtyři oči — NOT IMPLEMENTED (E04, čeká na validační milník).
- **KB6** admin audit log + export — implementováno; řetěz test PASS.

## Známé limity kroku 1

- Pozvánky jen jednorázové; převod vlastnictví organizace neexistuje; limit 1 vlastněná organizace na účet.
- Souběžný úplně první admin zápis v organizaci → unikátní konflikt (500), bez retry.
- Nouzový enrollment zapisuje do dvou DB bez společné transakce: kód se spálí, když selže zápis členství — náprava = vydat nový kód.
- Výběr členů firemní skupiny v klientu nefiltruje podle organizace (server vynucuje 403).
- Po nouzovém enrollmentu klient jde na seznam chatů, ne přímo do nouzové konverzace.
- Překlady ARB pro 17 jazyků mimo en/cs jsou strojové.
- Texty na webu (`www/`) firemní režim zatím nepopisují; README/CLAUDE.md „server nevidí obsah“ platí jen pro anonymní režim — doplnit před zveřejněním.

## Blokace přejímky

1. Docker/CI: integrační testy neproběhly. Hosted CI vyžaduje Actions minuty (private repo) nebo dočasně public repo — **pozor: repo teď obsahuje `docs/superpowers/specs/2026-09-15-typecall-spec-v0.2.md` s obchodní strategií** (zatím nepushnuto).
2. Validační milník spec kap. 12 nesplněn — E03b/E04/MLS krok 2 čekají.

## Nálezy z prvního E2E běhu (2026-09-18)

Klient `calltype_core/lib/network/organization_api.dart` byl psán proti domnělému tvaru odpovědí a testován jen proti mockům téhož omylu; server odpovídá kontraktu (`…-business-mode-contracts.md`).

- `POST /orgs` vrací `{organizationId, name}` bez `role` → klient spadl při parsování (organizace přitom vznikla). Oprava: tvůrce = owner.
- `GET /orgs/{id}/members` neexistuje (členové jsou v `GET /orgs/{id}`); `GET /orgs/{id}` nemá `role`; `PATCH` vrací 204 → seznam členů, enroll i nastavení auditora v UI padaly. Oprava: role z `/orgs/mine`, členové z `/orgs/{id}`.
- `POST /orgs/{id}/invites` bez těla → 400. Oprava: klient posílá `{}`.
- `src/server/CallType.Api/Dockerfile` měl build context bez `CallType.Audit` → image nešel sestavit (beta se nasazuje zipem, proto bez povšimnutí). Oprava: context `src/server`.
- Skupinový fan-out po jednom příjemci na volání hubu — nejen bot (`CallTypeBot._send`), ale i **aplikace** (`chat_controller.dart`): v business skupině každé volání bez obálky auditora končí `audit_recipient_missing`, tedy z aplikace nešla do firemní skupiny odeslat žádná zpráva. Opraveno na jednom místě: `SignalRClient.sendGroupMessage` posílá celý fan-out jedním voláním (= jedna serverová transakce). **Známá mez:** fan-out nad ~900 kB (příloha 256 kB pro 3+ členy; limit hubu 1 MiB) padá zpět na volání po příjemcích → v anonymní skupině funguje jako dřív, ve firemní skupině selže s `audit_recipient_missing`. Náprava: přílohy jako šifrované bloby. Nasazeno 2026-09-18, `a2fbb5b`, [run 35351480413](https://github.com/zcloudcz/Jay/actions/runs/35351480413) PASS; odeslání do firemní skupiny z aplikace na betě ručně NOT_RUN.
- `POST /orgs/{id}/emergency/kits` bez nastaveného auditora vracel 409 `auditor_not_configured` až PO zápisu sady → osiřelá sada (kódy nikdo neviděl) natrvalo v append-only auditu a v dokladu (`kitsIssued`). Opraveno: kontrola auditora v `EmergencyAppService.IssueKitAsync` před jakýmkoli zápisem; integrační test `Issuing_a_kit_without_an_auditor_is_rejected_and_stores_nothing`. Backend 326/326. Nasazení: NOT_RUN.
