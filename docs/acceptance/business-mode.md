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
| End-to-end (klient ↔ reálný server, archivátor běžící, nouzový enrollment) | NOT_RUN |
| Nasazení na betu | **PASS** — 2026-09-18, `25b5844`, [run 35337715526](https://github.com/zcloudcz/Jay/actions/runs/35337715526): testy, API, 5 klientských buildů, deploy API + web, smoke. Po deployi `/health/ready` 200, web 200. Business režim **vypnutý** (`ConnectionStrings__Audit` nenastaven) — ověřeno jen, že anonymní Jay běží beze změny; business endpointy na betě NOT_RUN |

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
