# Multi-device (spec 1: live sync) - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`. Plány:
`docs/superpowers/plans/2026-10-13-multi-device-sync-1-protocol.md`,
`docs/superpowers/plans/2026-10-14-multi-device-sync-2-app.md`.

Zařízení: P = telefon (primární, Android nebo iOS), W = web (`https://jay.zcloud.cz`, nová instalace = čistý prohlížečový profil), B = druhý uživatel (libovolné zařízení s aktuální verzí).

## Automatické ověření

| Co | Stav |
| --- | --- |
| Server: `GroupEndpointsTests`, `FanoutHubTests`, `DeviceListEndpointsTests` (Testcontainers) | PASS: celá sada 458 testů dříve; po změně nápovědy odesílatele znovu `FanoutHubTests` + `MessengerHubTests` 40 testů |
| `calltype_core`: `dart analyze` + `dart test` | PASS: 207 testů |
| App: `flutter analyze` + `flutter test` (vč. `multi_device_flow_test`, `message_inbox_multi_device_test`, l10n guardy) | PASS: analyze bez nálezů, 320 testů |
| Boti: `calltype_bot`, `hermes_bridge`, `jay_archiver` - `dart analyze` + `dart test` | PASS: `calltype_bot` 27, `hermes_bridge` 17, `jay_archiver` 27 + 3 přeskočené (živé E2E bez `JAY_E2E_API`) |
| Živé E2E `jay_archiver/test/e2e/multi_device_e2e_test.dart` proti lokálnímu compose (nikdy beta) | PASS: 6/6 dne 2026-10-14 |

## Chování zavedené při implementaci (oproti textu plánu)

- Zmizelý companion (server ho v zastaralé odpovědi vynechal) se odebere jen po potvrzení na primárním: obrazovka Propojená zařízení se zeptá "{zařízení} už na serveru neexistuje. Odebrat?" (Odebrat / Ponechat), nikdy automaticky.
- Primární během čekání na nové zařízení ukáže svůj handle ("Nové zařízení musí ukázat {handle}"). Propojení jde zrušit na obou stranách; nové zařízení vyprší po 4 min, primární po 3 min.
- Wipe nechává ověřené seznamy zařízení (spodní mez proti vrácení zpět) a dokončí se i po pádu (značka `companion_of`).
- Firemní skupiny: první odeslání se studenou cache spadne ve stejném pokusu na starou cestu. Server může na starou cestu vynutit i běžnou skupinu; companion pak tu zprávu nedostane (přijatý limit, popsaný ve specu).

## Ruční scénáře (telefon + web)

| # | Scénář | Stav |
| --- | --- | --- |
| M-01 | W čerstvě zaregistrovaný: "Propojit s existujícím zařízením" ukáže QR kód | NOT_RUN |
| M-02 | P: Nastavení > Propojená zařízení > Propojit zařízení, naskenovat QR z W; P ukáže vlastní handle ke srovnání, W ukáže "Propojit s CT-…?" se stejným handlem P; po potvrzení W skončí v seznamu chatů a P ukáže zařízení v seznamu | NOT_RUN |
| M-03 | W s kontaktem nebo chatem: propojení odmítnuto textem "jen zařízení bez kontaktů a chatů" | NOT_RUN |
| M-04 | QR z jiného zařízení než toho, jehož klíče server vrátí (podvržený kód): P ukáže varování "Kód neodpovídá klíčům zařízení", W nedostane nabídku | NOT_RUN |
| M-05 | B pošle zprávu P: dorazí na P i W do konverzace s B | NOT_RUN |
| M-06 | W odpoví B: B ji vidí v existující konverzaci s P (ne v nové); P ji vidí jako vlastní odeslanou, bez nepřečteného odznaku | NOT_RUN |
| M-07 | W smaže svou zprávu "pro všechny": zmizí u B i na P | NOT_RUN |
| M-08 | Skupina (ne firemní), ve které je P: W ji po první zprávě vidí, může do ní psát, ostatní členové vidí odesílatele jako P | NOT_RUN |
| M-09 | U B se v konverzaci s P objeví řádek "Tento kontakt přidal zařízení"; po odebrání W "…odebral zařízení" | NOT_RUN |
| M-10 | P odebere W, když je W online: W ukáže "Toto zařízení bylo odpojeno…" a nemá žádné chaty; další zpráva od B na W nedorazí | NOT_RUN |
| M-11 | P odebere W, když je W offline; W se po spuštění připojí a smaže data (hint se při offline ztratí, kontrola při připojení) | NOT_RUN |
| M-12 | Na W: žádná tlačítka hovoru, žádné "Nová skupina", ve firemní konverzaci místo pole pro psaní text "Firemní chaty jen na hlavním zařízení". Firemní část: W nikdy nedostane firemní konverzace, zkontrolovat, že se na W žádná neobjeví (ani po zprávě z firemní skupiny na P); zamítnutí `business_conversation_required` na W ukáže jen vysvětlující text, bez akce "Otevřít firemní konverzaci" | NOT_RUN |
| M-13 | Hovor od B na P zvoní jen na P | NOT_RUN |
| M-14 | Na W "Moje identita" ukazuje pozvánku P (handle P), ne W | NOT_RUN |
| M-15 | Bot (hermes_bridge): zpráva z W dostane odpověď na W i na P | NOT_RUN |
| M-16 | Záloha z P obnovená na jiném zařízení: obnova projde i s řádky hovorů a změn zařízení | NOT_RUN |
| M-17 | Zrušení propojení na P během čekání: W se vrátí do výchozího stavu a QR jde zobrazit znovu. Zrušení na novém zařízení: P o tom nedostane zprávu, čekání skončí až vypršením po 3 minutách | NOT_RUN |
| M-18 | Zrušení na W po odeslání souhlasu, zatímco P ještě čeká: známý limit, P může propojení dokončit (uživatel to na W potvrdil) | NOT_RUN |
| M-19a | Zmizelý companion hned po propojení: W smazat na serveru (GDPR smazání zařízení) dřív, než kdokoli napsal; P pak pošle zprávu: odeslání projde (W se přeskočí) a v Propojených zařízeních se nabídne "{zařízení} už na serveru neexistuje. Odebrat?"; "Ponechat" u jednoho řádku zruší jen ten řádek a nic nemění v seznamu, "Odebrat" ho odebere ze seznamu | NOT_RUN |
| M-19b | Zmizelý companion po výměně zpráv: stejné jako M-19a, ale W smazat až po zprávách mezi P, W a B; další odeslání z P projde a nabídka se objeví | NOT_RUN |
| M-20 | Srovnání handlu: P ukáže svůj handle, W ukáže stejný; při neshodě se propojení nepotvrzuje | NOT_RUN |
| M-21 | Skupina s companionem: P a B ve skupině, W propojený; zpráva od B dorazí na P i W, odpověď z W vidí B i P jako od P | NOT_RUN |
| M-22 | Odebrání + wipe + restart: P odebere W, W smaže data; po restartu aplikace na W zůstane prázdné zařízení bez chatů (wipe se dokončí i po pádu uprostřed) a nic se nevrátí | NOT_RUN |
| M-23 | Notifikace na P: P je na pozadí, uživatel píše z W. Vlastní zprávy z W na P nezabzučí ani nezobrazí notifikaci; zpráva od B stále ano | NOT_RUN |

Známé limity v1 (nejsou chybou přejímky): historie před propojením se nepřenáší (spec 2); stav přečtení, mazání "pro mě" a přejmenování kontaktu se mezi zařízeními nesynchronizují (spec 3); konverzace na W s lidmi, kteří tam nejsou v kontaktech, mají jako název technické id; protějšek se starou verzí posílá jen na P; propojení z Windows/Linux není (chybí kamera); ztráta P = seznam už nejde měnit (spec 4); server může vynutit starou cestu i pro běžnou skupinu, companion pak tu zprávu nedostane; zrušení na novém zařízení po odeslaném souhlasu nemusí propojení zastavit; odebraný companion, který se nesmazal (např. odcizený prohlížeč), se protějšku ukáže jako samostatné zařízení od své další zprávy (nápověda serveru), už ne jako vlastník.
