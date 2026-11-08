# Synchronizace kontaktů a přenos historie mezi vlastními zařízeními - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-08-contact-sync.md`. Větev `feat/contact-sync` (obsahuje i `feat/chat-extras`).

Zařízení: P = telefon (primární), W = web propojený s P (`https://jay.zcloud.cz`), W2 = druhý web nebo prohlížeč propojený s P, D = Windows desktop bez kamery propojený s P, B = druhý uživatel (kontakt), S = vlastní zařízení se starší verzí aplikace (před touto změnou), F = firemní konverzace (Jay Business) na P.

## Automatické ověření

| Co | Stav |
| --- | --- |
| `calltype_core`: `dart analyze` + `dart test` (vč. `contact_sync_test`, `history_transfer_test`, migrace v9 -> v10) | viz report větve |
| App: `flutter analyze` + `flutter test` (vč. `contact_sync_flow_test`, `history_transfer_screen_test`, `backup_contact_sync_test`, `poll_wire_test`) | viz report větve |
| Server: `FanoutHubTests` (4 nové testy fan-outu adresovaného vlastní identitě) | viz report větve |

## Ruční scénáře

### Kontakty po propojení

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| K1 | P má kontakty s přezdívkami a skupiny; propojit nový W (Nastavení > Propojená zařízení) | Na W se do pár sekund objeví všechny kontakty s přezdívkami z P a všechny chaty se správnými názvy (bez zpráv) | NOT_RUN |
| K2 | Po propojení přijde na W zpráva od B | Chat na W má jméno B z P, ne surové ID | NOT_RUN |
| K3 | Na W: Propojená zařízení > Synchronizovat kontakty | Hláška "Kontakty odeslány"; na P ani W se nic nezdvojí | NOT_RUN |
| K4 | P bez propojených zařízení | Položky synchronizace a přenosu se nezobrazí | NOT_RUN |
| K5 | Firemní konverzace F na P, propojit W | Na W je hlavička F i s firemním odznakem, zprávy F na W nejsou (firemní jen na primárním) | NOT_RUN |

### Přejmenování

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| R1 | Na W přejmenovat kontakt B | Nové jméno do pár sekund na P i W2, i v seznamu chatů | NOT_RUN |
| R2 | Na P smazat přezdívku B (prázdné jméno) | Na W a W2 se zobrazí handle B | NOT_RUN |
| R3 | P offline, na W přejmenovat B, pak P online | Po připojení má P nové jméno | NOT_RUN |
| R4 | Na P a W přejmenovat B téměř současně na různá jména | Po chvíli mají P, W i W2 stejné jméno (vyhrává novější změna) | NOT_RUN |
| R5 | Přidat nový kontakt na W | Kontakt se objeví na P a W2 | NOT_RUN |
| R6 | B přejmenovat na P; jméno B na B se nezmění | Přezdívka je jen pro vlastní zařízení, B ani server ji nevidí | NOT_RUN |

### Přenos historie

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| H1 | Na W: Propojená zařízení > Přenést zprávy z jiného zařízení | QR kód, pod ním textový kód a tlačítko Kopírovat kód | NOT_RUN |
| H2 | Na P: Poslat moje zprávy do jiného zařízení > Naskenovat kód z W | Dotaz "Chaty: N, přibližně X MB. Přenést je do zařízení ...?" s rozumnými čísly | NOT_RUN |
| H3 | Potvrdit Přenést | P ukazuje průběh odesílání, pak čekání; W ukazuje příjem a import; na konci W "Hotovo. Přeneseno zpráv: N" a P "Vaše zprávy byly přeneseny" | NOT_RUN |
| H4 | Po H3 projít na W staré chaty | Staré zprávy jsou na W, žádné zdvojené, nepřečtené 0; fotky z posledních 72 h se dají stáhnout, starší ne (jako po obnově zálohy) | NOT_RUN |
| H5 | D (Windows bez kamery) jako cíl: zkopírovat textový kód, poslat si ho, na P vložit do pole Textový kód > Pokračovat | Přenos proběhne jako H3 | NOT_RUN |
| H6 | W jako zdroj, P jako cíl (P zobrazí kód, W vloží text) | Přenos proběhne; na P se nic nezdvojí | NOT_RUN |
| H7 | Firemní konverzace F, přenos z P na W | Zprávy F na W nejsou, ostatní ano | NOT_RUN |
| H8 | Kód z jiného účtu (cizí telefon zobrazí kód, P ho naskenuje) | P odmítne: "Tento kód patří zařízení, které není propojené s vaším účtem." | NOT_RUN |
| H9 | Během odesílání na P stisknout Zrušit | P se vrátí na začátek; W dál čeká; nový pokus jde jen s novým kódem | NOT_RUN |
| H10 | Na W zavřít obrazovku s kódem a pak na P naskenovat starý kód | W nic nepřijme; P čeká, po Zrušit se upload smaže | NOT_RUN |
| H11 | Kód nechat zobrazený přes 15 minut | W ukáže "Platnost kódu vypršela", Zkusit znovu ukáže nový kód | NOT_RUN |
| H12 | iOS (TestFlight) jako zdroj i cíl | Skenování kódu funguje, přenos jako H3 | NOT_RUN |

### Kompatibilita

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| C1 | S (stará verze) propojené s P, na P Synchronizovat kontakty | P ukáže "Pokud je některé zařízení nezobrazí, aktualizujte Jay na všech svých zařízeních"; S nespadne | NOT_RUN |
| C2 | Obnova starší zálohy (před touto verzí) | Obnoví se, přezdívky zůstanou | NOT_RUN |
| C3 | Záloha z nové verze obnovená na nové verzi | Přezdívky, odznak bota a firemní odznak zůstanou | NOT_RUN |
| C4 | B (kontakt) nedostane žádnou synchronizační zprávu | U B se nic nezobrazí, žádné nové notifikace | NOT_RUN |

## Limity (ze spec)

- Ověření (verified) kontaktů, koncepty a stav přečtení se nesynchronizují.
- Přenos je jeden archiv bez pokračování; po neúspěchu nový kód.
- Média se přenáší jen jako odkazy; po 72 h na serveru nejsou dostupná.
- Vlastní zařízení se starou aplikací synchronizaci nedostane, dokud se neaktualizuje.
