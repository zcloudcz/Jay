# Boti + Kanály — přejímka (T05 / C04)

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář. Větev `feat/bots-channels`, **nenasazeno** — scénáře vyžadují deploy API (migrace `BotsAndChannels`) + webu a u botů běžící Hermes Agent.

Plány: `docs/superpowers/plans/2026-09-17-bots.md`, `2026-09-16-channels.md` (§7), exekuce `2026-09-17-bots-channels-paralelni.md`.

## Automatické ověření (stav k 2026-09-17, lokálně)

| Co | Stav |
| --- | --- |
| Server build, DB-free testy | PASS |
| Server integrační testy (Testcontainers: `ChannelEndpointsTests`, `ChannelPostCleanupServiceTests`, `ChannelSchemaTests`, IsBot v `DeviceEndpointsTests`) | NOT_RUN — Docker na vývojovém stroji neběží; první běh = hosted CI |
| Migrace `BotsAndChannels` proti PostgreSQL | NOT_RUN |
| `calltype_core`, `calltype_bot`, `hermes_bridge` — `dart analyze` + `dart test` | PASS |
| Flutter `analyze` + `test`, `flutter build web --release` | PASS |
| Android / iOS / Windows / macOS build po vytěžení `calltype_core` | NOT_RUN — ověří `deploy.yml` |
| Vlastní SignalR transport bota proti ASP.NET Core hubu | NOT_RUN — testován jen proti fake serveru |
| Code review + security review serveru (statické) | bez blokujících nálezů |

## Boti (T05)

| # | Scénář | Stav |
| --- | --- | --- |
| B-01 | Spustit `hermes_bridge` (README v `src/bots/hermes_bridge/`), první start vypíše handle + pozvánku | NOT_RUN |
| B-02 | Web: přidat bota přes handle — odznak BOT je vidět v náhledu **před** potvrzením | NOT_RUN |
| B-03 | První otevření chatu s botem ukáže upozornění o třetí straně; tlačítka hovoru skrytá | NOT_RUN |
| B-04 | 1:1 konverzace: odpověď dorazí, během generování „píše…“, druhá otázka navazuje na kontext první | NOT_RUN |
| B-05 | Bot vypnutý → poslat zprávu → zapnout: odpověď přijde právě jednou; restart bota podruhé další odpověď nevyvolá | NOT_RUN |
| B-06 | Restart bota: stejný handle, protějšek nevidí změnu safety number, konverzace pokračuje | NOT_RUN |
| B-07 | Handle mimo `ALLOWED_HANDLES`: žádná odpověď, v logu Hermes žádné volání | NOT_RUN |
| B-08 | Skupina: bot mlčí bez zmínky, odpoví na `@Hermes …` | NOT_RUN |
| B-09 | Android: B-02 až B-04 | NOT_RUN |
| B-10 | Server: v DB/logu není plaintext konverzace s botem | NOT_RUN |

Známé limity (nejsou chybou přejímky): bot nedoplňuje one-time pre-keys (server na to nemá endpoint — po vyčerpání 100 kusů běží X3DH bez OTK, stejně jako appka); „odpověď na zprávu bota“ ve skupině nelze rozpoznat (protokol nemá reply-to), funguje jen zmínka; drift DB bota je na disku v plaintextu jako v appce.

## Kanály (C04)

Zařízení A = registrovaný účet, B a C = libovolná (i anonymní).

| # | Scénář | Stav |
| --- | --- | --- |
| C-01 | Anonymní zařízení: založení kanálu nabídne registraci místo formuláře | NOT_RUN |
| C-02 | A založí kanál; B a C ho začnou sledovat přes odkaz `calltype://channel/<handle>` / QR | NOT_RUN |
| C-03 | Kanál se u B neobjeví, dokud B neklepne na Follow | NOT_RUN |
| C-04 | A postne text, obrázek (≤ 2 MiB) a anketu; B a C je vidí živě v záložce Updates, ne mezi chaty | NOT_RUN |
| C-05 | Obrázek > 2 MiB a ne-obrázek: srozumitelná chyba | NOT_RUN |
| C-06 | B offline → A postne 3× → B po startu vidí každý post jednou, badge nepřečtených sedí | NOT_RUN |
| C-07 | B reaguje, C hlasuje; A vidí jen součty. V žádné odpovědi API (DevTools → Network) není cizí DeviceId | NOT_RUN |
| C-08 | Sledující nemá vstupní pole; admin má compose bar; všude je vidět „veřejné, bez E2E“ | NOT_RUN |
| C-09 | A smaže post → u B/C zmizí a po restartu se nevrátí | NOT_RUN |
| C-10 | B přestane sledovat → další post nedostane | NOT_RUN |
| C-11 | C nahlásí kanál → řádek v `ChannelReports` + varování v logu API (e-mail se neposílá — repo nemá poštovní infrastrukturu); 6. nahlášení za den → limit | NOT_RUN |
| C-12 | C zablokuje kanál → zmizí z Updates, odkaz ho neotevře, dokud ho C v nastavení neodblokuje | NOT_RUN |
| C-13 | A se přihlásí na druhém zařízení téhož účtu → má vlastnická práva | NOT_RUN |
| C-14 | A smaže kanál → u B/C zmizí | NOT_RUN |
| C-15 | 6. kanál téhož účtu → odmítnuto (limit 5 na účet) | NOT_RUN |
| C-16 | Upgrade existující instalace (schema v1 → v2): kontakty a historie chatů zůstaly | NOT_RUN |
| C-17 | Push „nový příspěvek“ max 1× / kanál / 10 min, bez obsahu | BLOCKED — Firebase projekt neexistuje |

Ke každému řádku zapsat: datum UTC, zařízení + OS/prohlížeč, výsledek, odkaz na důkaz v `evidence/`.
