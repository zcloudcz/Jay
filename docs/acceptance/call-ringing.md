# Vyzvánění hovorů při zavřené aplikaci - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-06-call-ringing.md` (ruční přejímka = sekce 3). Větve `feat/call-ringing-server`,
`feat/call-ringing-app`, sloučené v `release/2026-11-09`.

Zařízení: I = iPhone s TestFlight buildem, D = Android telefon (release/internal build), C = volající (web nebo jiný
telefon s Jay). Aplikace na I/D je zavřená (odstraněná z přepínače aplikací), pokud scénář neříká jinak.

## Automatické ověření

| Co | Stav |
| --- | --- |
| Server: `RequestPendingCalls` / `DeclinePendingCall`, signály `ringing` / `cancelled`, `ringCalls`, `voip-token` endpointy, ring pushe (integrační testy) + celá sada | viz `verify_release.sh` na release SHA |
| Core: `push_token_api_test` (`ringCalls`, voip-token), `signalr_client_test` (hub metody) | viz `verify_release.sh` |
| App: `call_ring_coordinator_test`, `webrtc_ringing_test`, `push_service_test`, `call_screen_test`, `notification_service_test`, `notifications_screen_test`, `session_overlay_ring_lock_test`, l10n guardy | viz `verify_release.sh` |
| iOS nativní kód (`AppDelegate.swift`, PushKit, CallKit audio) | NOT_RUN: na Linuxu nejde přeložit, ověří až TestFlight build |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| R1 | I zamčený, aplikace zavřená; C volá I | I zvoní přes CallKit (systémová obrazovka hovoru); C vidí "Zvoní u příjemce..." místo "Vyzvánění..." | NOT_RUN |
| R2 | R1, I přijme hovor na zamčené obrazovce | Hovor se spojí, zvuk oběma směry (i se zamčeným telefonem); po odemčení je otevřená obrazovka hovoru, zámek aplikace se zeptá nejvýš jednou | NOT_RUN |
| R3 | R1, I hovor odmítne v CallKit | C vidí "Hovor byl odmítnut." a hovor u C skončí; I už nezvoní | NOT_RUN |
| R4 | R1, C zavěsí, dokud I zvoní | CallKit na I přestane zvonit; I dostane oznámení "Zmeškaný hovor" | NOT_RUN |
| R5 | D zamčený, aplikace zavřená; C volá D | Celoobrazovkové příchozí volání na zamykací obrazovce; přijetí spojí hovor se zvukem oběma směry | NOT_RUN |
| R6 | R5, D odmítne | C vidí "Hovor byl odmítnut." | NOT_RUN |
| R7 | R5, C zavěsí během vyzvánění | Vyzvánění na D skončí, oznámení "Zmeškaný hovor" | NOT_RUN |
| R8 | D Android 14+ bez povolení celoobrazovkových oznámení | V Nastavení > Oznámení je řádek "Příchozí hovory přes celou obrazovku" s vysvětlením; klepnutí otevře systémové nastavení; bez povolení hovor zazvoní jako oznámení | NOT_RUN |
| R9 | Aplikace na I/D otevřená v popředí; C volá | Zvoní dosavadní obrazovka v aplikaci (bez CallKit / celoobrazovkového oznámení), hovor jde přijmout | NOT_RUN |
| R10 | Web nebo desktop volaný | Beze změny proti předchozí verzi (vyzvánění jen v aplikaci) | NOT_RUN |
