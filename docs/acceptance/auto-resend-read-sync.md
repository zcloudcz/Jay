# Automatické znovuodeslání a synchronizace přečtení mezi vlastními zařízeními - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-09-auto-resend-read-sync.md`. Větev `feat/retry-and-read-sync`.

Zařízení: P = telefon (primární), W = web propojený s P (`https://jay.zcloud.cz`), D = Windows desktop propojený s P, B = druhý uživatel (kontakt), S = vlastní zařízení se starší verzí aplikace (před touto změnou), F = firemní konverzace (Jay Business) na P.

## Automatické ověření

| Co | Stav |
| --- | --- |
| App: `flutter analyze` + `flutter test` (vč. `auto_resend_test`) | viz report větve |

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
