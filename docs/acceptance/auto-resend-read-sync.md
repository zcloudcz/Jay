# Automatické znovuodeslání a synchronizace přečtení mezi vlastními zařízeními - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-09-auto-resend-read-sync.md`. Větev `feat/retry-and-read-sync`.

Zařízení: P = telefon (primární), W = web propojený s P (`https://jay.zcloud.cz`), D = Windows desktop propojený s P, B = druhý uživatel (kontakt), S = vlastní zařízení se starší verzí aplikace (před touto změnou), F = firemní konverzace (Jay Business) na P.

## Automatické ověření

| Co | Stav |
| --- | --- |
| `calltype_protocol`: `dart test` (vč. `read_state_test`) | viz report větve |
| App: `flutter analyze` + `flutter test` (vč. `auto_resend_test`, `read_sync_flow_test`) | viz report větve |

## Ruční scénáře

### Část 1: automatické znovuodeslání

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| A1 | Na P zapnout režim letadlo, poslat B zprávu, po minutě režim letadlo vypnout | Bublina ukazuje "odesílá se" (ne červenou chybu); po připojení zpráva odejde sama bez klepnutí, B ji má jednou | NOT_RUN |
| A2 | Offline poslat zprávu, aplikaci na P úplně zavřít (kill), připojit síť a aplikaci znovu otevřít | Do pár sekund po startu zpráva odejde sama, B ji má jednou | NOT_RUN |
| A3 | Ve firemní konverzaci F poslat zprávu, kterou server trvale odmítne (např. `business_conversation_required` u 1:1 s členem organizace, nebo chybějící auditor v rozesílce) | Bublina hned ukazuje chybu s tlačítkem "Odeslat znovu", aplikace to sama nezkouší | NOT_RUN |
| A4 | Offline poslat fotku (bez zrušení nahrávání), pak připojit síť a počkat | Nahrání se samo obnoví a zpráva odejde | NOT_RUN |
| A5 | Offline poslat zprávu v chatu X, přejít do jiného chatu, připojit síť | Zpráva v X odejde, i když X není otevřený | NOT_RUN |
| A6 | Zpráva, která 24 h nešla odeslat (např. zařízení dlouho offline) | Po 24 h zůstane červená s "Odeslat znovu", ruční klepnutí funguje | NOT_RUN |

### Část 2: synchronizace přečtení mezi vlastními zařízeními

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| S1 | P a W online, W v pozadí (jiná karta nebo okno). B napíše A; na P i W je nepřečteno 1 a na W notifikace. Na P otevřít chat s B | Na W do pár sekund zmizí nepřečteno (seznam chatů) i notifikace prohlížeče | NOT_RUN |
| S2 | Totéž s D (Windows desktop) místo W | Na D zmizí nepřečteno i notifikace Windows | NOT_RUN |
| S3 | W zavřený (offline), B napíše A, server pošle Web Push a prohlížeč ho zobrazí; na P chat přečíst; pak W otevřít | Po otevření W je chat přečtený a Web Push notifikace s tagem chatu zmizí | NOT_RUN |
| S4 | Android P bez připojení k hubu (aplikace zavřená), B napíše, Android ukáže FCM push; chat přečíst na W; pak P otevřít | Na P zmizí nepřečteno i FCM notifikace (tag = id chatu) | NOT_RUN |
| S5 | iOS P: B napíše, iOS ukáže APNs push, chat přečíst na W | Nepřečteno na P zmizí; APNs notifikace v Oznamovacím centru ZŮSTANE (limit platformy, viz spec S5) | NOT_RUN |
| S6 | Přečíst chat na P, pak B napíše další zprávu | Na W je nepřečteno 1 a notifikace se ukáže (novější zpráva) | NOT_RUN |
| S7 | Chat otevřený na P, aplikace P v pozadí, B napíše | Na W zůstává nepřečteno 1; po návratu P do popředí s tímto chatem zmizí i na W | NOT_RUN |
| S8 | Starší aplikace na vlastním zařízení S (před touto změnou), na P číst chaty | S se chová jako dřív (nepřečteno a notifikace zůstávají), nic nespadne; po aktualizaci S se fronta vyprázdní | NOT_RUN |
| S9 | P bez propojených zařízení | Čtení chatů nic neposílá, chování beze změny | NOT_RUN |
