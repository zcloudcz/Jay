# Kontakty z odpovědí a přejmenování v 1:1 chatu - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-09-contacts-from-replies.md`. Větev `feat/auto-contact`.

Zařízení: P = telefon (primární), W = web propojený s P, A = cizí člověk (není v kontaktech P), R = bot, který není v kontaktech P.

## Automatické ověření

| Co | Stav |
| --- | --- |
| Server: `DeviceEndpointsTests` (`GET /devices/{id}/profile`: 200, 404, 401, bot, jméno, nespotřebuje pre-key) + celá sada | viz report větve |
| Core: `api_client_test` (`getDeviceProfile`) | viz report větve |
| App: `contacts_from_replies_test` (odpověď přidá kontakt, příchozí zpráva ne, skupina/business ne, selhání lookupu neblokuje odeslání, menu Přejmenovat/Přidat, titulek z profilu) | viz report větve |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| K1 | A napíše P, P jen přečte | A se do Kontaktů nepřidá; v seznamu chatů i v hlavičce chatu je jméno z profilu A (nebo handle), ne technické id | NOT_RUN |
| K2 | P odpoví A na telefonu | A je v Kontaktech P s handle a jménem z profilu, právě jednou | NOT_RUN |
| K3 | Po K2 otevřít Kontakty na W | A je i na W (synchronizace kontaktů) | NOT_RUN |
| K4 | Totéž jako K2, ale P odpoví z W | A je v Kontaktech na W i na P | NOT_RUN |
| K5 | Na W v chatu s A (ještě není kontakt): menu (tři tečky) > Přejmenovat | A se přidá, otevře se dialog přejmenování s handle; nové jméno je vidět v chatu, seznamu chatů a Kontaktech na W i P | NOT_RUN |
| K6 | Na telefonu v chatu s A (není kontakt): menu > Přidat kontakt | Hláška "Přidáno ..."; položka Přidat kontakt v menu zmizí, Přejmenovat zůstane | NOT_RUN |
| K7 | Titulek chatu s nekontaktem na W i P | Jméno z profilu A, bez jména jeho handle; nikdy dlouhé technické id (po načtení profilu) | NOT_RUN |
| K8 | P offline (režim letadlo), odpovědět A | Zpráva se zařadí a po připojení odejde; kontakt se nepřidá hned, ale při další odeslané zprávě online ano | NOT_RUN |
| K9 | P offline, menu > Přejmenovat u nekontaktu | Chybová hláška "Kontakt se nepodařilo přidat...", nic se nepřidá, dialog se neotevře | NOT_RUN |
| K10 | P odpoví botovi R | R je v Kontaktech s odznakem BOT | NOT_RUN |
| K11 | Odpověď ve skupině, kde je A | A se do Kontaktů nepřidá | NOT_RUN |
