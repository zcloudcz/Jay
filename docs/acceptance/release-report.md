# CallType beta — release report (průběžný)

**Stav k 2026-09-17:** dílčí vydání **web + API**; NENÍ „pětiplatformní beta dokončena“.

| | |
| --- | --- |
| Nasazený commit (API + web) | `e88620d` (run https://github.com/zcloudcz/Jay/actions/runs/35207819763) |
| Web | https://jay.zcloud.cz (také https://orange-bush-07e1b5803.6.azurestaticapps.net) |
| API | https://calltype-beta-zahy.azurewebsites.net |
| Artefakty stejného SHA | api, web, android (APK), windows (zip), macos (tar.gz), ios-unsigned (tar.gz) + `build-manifest.json` se SHA256 |
| Rollback | `deploy.yml` s `commit_sha` předchozího dobrého commitu (artefakty 90 dní); DB migrace jsou aditivní, downgrade DB se neprovádí |

## Brány

| Brána | Stav | Důkaz / co chybí |
| --- | --- | --- |
| G1 technická integrace | PASS | hosted CI: backend 154/154 (Testcontainers), Flutter analyze + testy; `baseline.md` |
| G2 infrastruktura | FAIL (neuzavřeno) | TURN autentizovaný přes Cloudflare PASS; DB `VerifyFull` NOT_RUN; obnova DB NOT_RUN (skripty připraveny, `ops/evidence/I02.md`); nákladový model bez ověřených cen |
| G3 platformy | částečně | 5 buildů PASS; spuštění doloženo jen web; iOS BLOCKED (unsigned) |
| G4 funkce | FAIL (neuzavřeno) | `matrix.md` — Q01-02 první nález opraven, retest čeká; hovory přes relay a push neověřeny |
| G5 vydání | částečně | artefakty + manifesty + SHA PASS; tento report je průběžný |

## Neověřené funkce (uživatel musí vědět)

- Hovory přes TURN relay mezi dvěma sítěmi, chování hovoru na pozadí.
- Push notifikace na všech platformách (Firebase není nastaven); příchozí hovor při ukončené aplikaci není podporován.
- Záloha/obnova na reálných zařízeních; provozní záloha a obnova PostgreSQL.
- Android, Windows, macOS: instalace a běh artefaktů z tohoto SHA; iOS: bez podpisu nelze instalovat.

## Trvalá omezení (nejsou chyby této bety)

TOFU důvěra v identitu kontaktu; vlastní neauditovaná implementace Signal protokolu (ne libsignal); lokální databáze není šifrovaná (SQLite bez SQLCipher); jedna instance API; přílohy do 256 KiB; zálohy max. 3 × 8 MiB na účet.
