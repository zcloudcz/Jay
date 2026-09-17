# Q01 — přejímací matice (K06)

Statusy: PASS / FAIL / BLOCKED / NOT_RUN / UNSUPPORTED. PASS jen pro skutečně provedený scénář na dané platformě.
Commit klientů/artefaktů: `6f4802a` (run 35193671677; předchozí `9816709`, run 35129788149); web z domény `https://calltype.zcloud.cz`. API: `https://calltype-beta-zahy.azurewebsites.net`.

| Scénář | Web | Android | Windows | macOS | iOS |
| --- | --- | --- | --- | --- | --- |
| Q01-01 start (onboarding → restart, stejná identita) | PASS¹ | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-02 chat A↔B, český text, restart | **FAIL → opraveno a nasazeno, čeká na retest dvěma identitami**³ | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-03 offline 10 zpráv | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-04 reconnect při odesílání | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-05 skupina A/B/C, odebrání C | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-06 soubor 256 KiB / +1 B | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-07 záloha → druhé zařízení → obnova | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-08 chyby obnovy (heslo, poškozený soubor) | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-09 hovor 3 min přes vynucený relay | NOT_RUN⁴ | NOT_RUN⁴ | NOT_RUN⁴ | NOT_RUN | BLOCKED² |
| Q01-10 redial | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-11 zamítnutá oprávnění | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | BLOCKED² |
| Q01-12 push | BLOCKED⁵ | BLOCKED⁵ | UNSUPPORTED (bez FCM) | BLOCKED⁵ | BLOCKED²⁵ |
| Q01-13 konfigurace (HTTPS API, žádný localhost) | PASS⁶ | PASS⁶ (manifest) | PASS⁶ (manifest) | PASS⁶ (manifest) | PASS⁶ (manifest, unsigned) |

¹ 2026-09-17, vestavěný prohlížeč Claude (Chromium), `https://calltype.zcloud.cz`: onboarding vytvořil identitu `CT-X7JQ-MTJV`, přechod do seznamu konverzací OK. Po nasazení nového webu (`6f4802a`) a reloadu stránky aplikace přeskočila onboarding a *My identity* ukazuje stejný handle `CT-X7JQ-MTJV` → identita perzistuje. Ověřovatel: Claude (B00).
² Chybí Apple tým, podpisová identita a fyzický iPhone; k dispozici jen unsigned build.
³ Viz `evidence/Q01-02-add-contact.md`.
⁴ Připraveno: Settings → Diagnostics → *Force TURN relay* + tlačítko *Route* v hovoru (commit `c7048e9`). Vyžaduje dvě zařízení ve dvou sítích.
⁵ Firebase projekt neexistuje (`docs/acceptance/D03-push-handoff.md`).
⁶ `build-manifest.json` v artefaktech runu 35129788149: `apiBaseUrl=https://calltype-beta-zahy.azurewebsites.net`; deploy workflow odmítá prázdnou/HTTP/loopback URL.

## Jak testovat (pro ověřovatele)

1. Dvě identity = dvě různá zařízení **nebo** dva různé prohlížeče/profily (identita je vázaná na origin + úložiště prohlížeče; anonymní okno = nová identita, která po zavření zmizí).
2. Přidání kontaktu: *New chat* → *Add contact* / *Enter handle or invite* → vložit handle `CT-XXXX-XXXX` druhé strany (najdeš ho pod ikonou QR „My identity“, tlačítko kopírovat).
3. Hovor přes relay: obě strany Settings → Diagnostics → zapnout *Force TURN relay*, zahájit hovor, během hovoru *Route* → očekáváno `relay / udp` (nebo `tcp`). Screenshot do `evidence/`.
4. Ke každému řádku zapsat: datum UTC, zařízení + OS/prohlížeč, partnerskou platformu, síť, výsledek, odkaz na důkaz.
