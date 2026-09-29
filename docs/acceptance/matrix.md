# Q01 — přejímací matice (K06)

Statusy: PASS / FAIL / BLOCKED / NOT_RUN / UNSUPPORTED. PASS jen pro skutečně provedený scénář na dané platformě.
Commit klientů/artefaktů: `6f4802a` (run 35193671677; předchozí `9816709`, run 35129788149); web z domény `https://jay.zcloud.cz` (do 2026-09-17 `https://calltype.zcloud.cz`, zrušena — výsledky Q01-01/02 byly pořízeny tam). API: `https://calltype-beta-zahy.azurewebsites.net`.

| Scénář | Web (desktop) | Web iOS Safari⁷ | Android | Windows | macOS | iOS nativní |
| --- | --- | --- | --- | --- | --- | --- |
| Q01-01 start (onboarding → restart, stejná identita) | PASS¹ | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-02 chat A↔B, český text, restart | PASS (obousměrný chat)³ · restart + diakritika nepotvrzeny | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-03 offline 10 zpráv | NOT_RUN | PASS⁸ | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-04 reconnect při odesílání | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-05 skupina A/B/C, odebrání C | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-06 soubor 256 KiB / +1 B | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-07 záloha → druhé zařízení → obnova | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-08 chyby obnovy (heslo, poškozený soubor) | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-09 hovor 3 min přes vynucený relay | NOT_RUN⁴ | PASS (hovor + video)⁸ · relay/3 min nepotvrzeno | NOT_RUN⁴ | NOT_RUN⁴ | NOT_RUN | BLOCKED² |
| Q01-10 redial | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-11 zamítnutá oprávnění | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-12 push | BLOCKED⁵ | BLOCKED⁵ | BLOCKED⁵ | UNSUPPORTED (bez FCM) | BLOCKED⁵ | BLOCKED²⁵ |
| Q01-13 konfigurace (HTTPS API, žádný localhost) | PASS⁶ | PASS⁶ (stejný web build) | PASS⁶ (manifest) | PASS⁶ (manifest) | PASS⁶ (manifest) | PASS⁶ (manifest, unsigned) |

¹ 2026-09-17, vestavěný prohlížeč Claude (Chromium), `https://calltype.zcloud.cz`: onboarding vytvořil identitu `CT-X7JQ-MTJV`, přechod do seznamu konverzací OK. Po nasazení nového webu (`6f4802a`) a reloadu stránky aplikace přeskočila onboarding a *My identity* ukazuje stejný handle `CT-X7JQ-MTJV` → identita perzistuje. Ověřovatel: Claude (B00).
² Chybí Apple tým, podpisová identita a fyzický iPhone; k dispozici jen unsigned build.
³ Viz `evidence/Q01-02-add-contact.md`.
⁴ Připraveno: Settings → Diagnostics → *Force TURN relay* + tlačítko *Route* v hovoru (commit `c7048e9`). Vyžaduje dvě zařízení ve dvou sítích.
⁵ Firebase projekt neexistuje (`docs/acceptance/D03-push-handoff.md`).
⁶ `build-manifest.json` v artefaktech runu 35129788149: `apiBaseUrl=https://calltype-beta-zahy.azurewebsites.net`; deploy workflow odmítá prázdnou/HTTP/loopback URL. Od P9 (2026-09-29) staví `deploy.yml` jen web; nativní buildy a jejich manifesty (`buildName`, `buildNumber`, `distribution`, `signed`) dělá `release-native.yml` (`release-builds.md`).

⁷ Web build otevřený v Safari na iPhonu (případně přidaný na plochu). Není to nativní iOS aplikace — ta zůstává BLOCKED do prvního TestFlight buildu (`ios-testflight.md`).
⁸ 2026-09-17, ověřovatel Martin, `https://jay.zcloud.cz`, commit `e88620d`: hlasový hovor, videohovor a doručení offline zpráv fungují („vypadá to ok“). Model iPhonu/verze iOS, protistrana, síť, zda byl zapnut *Force TURN relay*, délka hovoru a počet offline zpráv: neuvedeno → dílčí podmínky scénářů (3 min přes vynucený relay; přesně 10 zpráv právě jednou) nejsou potvrzeny. Nálezy z tohoto testu: `evidence/Q01-09-call-ux.md`.

## Jak testovat (pro ověřovatele)

1. Dvě identity = dvě různá zařízení **nebo** dva různé prohlížeče/profily (identita je vázaná na origin + úložiště prohlížeče; anonymní okno = nová identita, která po zavření zmizí).
2. Přidání kontaktu: *New chat* → *Add contact* / *Enter handle or invite* → vložit handle `CT-XXXX-XXXX` druhé strany (najdeš ho pod ikonou QR „My identity“, tlačítko kopírovat).
3. Hovor přes relay: obě strany Settings → Diagnostics → zapnout *Force TURN relay*, zahájit hovor, během hovoru *Route* → očekáváno `relay / udp` (nebo `tcp`). Screenshot do `evidence/`.
4. Ke každému řádku zapsat: datum UTC, zařízení + OS/prohlížeč, partnerskou platformu, síť, výsledek, odkaz na důkaz.

## Nativní vydání (proud P, R-01 až R-08)

Plán: `docs/superpowers/plans/2026-09-29-gap-platform.md` §7. Buildy z `release-native.yml` (Android, iOS; macOS/Windows/Linux ve vlně 2), web z `deploy.yml`. Ke každému: datum UTC, zařízení/OS, build `buildName (buildNumber)` + SHA z manifestu, výsledek, důkaz.

| Scénář | Android | iOS | macOS | Windows | Linux | Web |
| --- | --- | --- | --- | --- | --- | --- |
| R-01 instalace z obchodu/stažení na čisté zařízení, první spuštění, identifikátor `cz.zcloud.jay` | NOT_RUN (Play interní test) | NOT_RUN (TestFlight) | NOT_RUN (P6) | NOT_RUN (P7) | NOT_RUN (P8) | — |
| R-02 hovor audio+video v **release** buildu (R8/hardened runtime nerozbily WebRTC, oprávnění kamera/mikrofon) | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | — |
| R-03 aktualizace buildu N → N+1 zachová identitu a historii | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| R-04 verze v Nastavení = `buildName (buildNumber)` z manifestu | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| R-05 Firebase: release build hlásí jiný stav než `notConfigured` | NOT_RUN | NOT_RUN | NOT_RUN | UNSUPPORTED | UNSUPPORTED | NOT_RUN |
| R-06 banner aktualizace z `latest.json` (jen direct) | — | — | NOT_RUN (P10) | NOT_RUN (P10) | NOT_RUN (P10) | — |
| R-07 identita po restartu OS (keychain / secure storage / libsecret) | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | — |
| R-08 Android: zapnutá Google záloha neobsahuje DB (`adb shell bmgr backupnow cz.zcloud.jay` → nic k záloze) | NOT_RUN | — | — | — | — | — |
