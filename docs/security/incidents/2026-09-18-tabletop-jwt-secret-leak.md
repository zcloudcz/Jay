# Postmortem (TABLETOP) — Únik JWT signing secretu (2026-09-18)

## Shrnutí
Cvičný scénář: `Jwt:Secret` App Service (`calltype-beta-zahy`) unikl —
například do veřejného CI logu při přepnutí repozitáře do public okna
(`/gh-actions-public`). Stupeň: Kritický (§1) — útočník s tajemstvím může
razit platné JWT pro libovolné zařízení/účet.

## Časová osa (cvičná, UTC)
- T+0 — zjištění (např. secret-scanning alert nebo review před push do public
  okna)
- T+0 až T+1 h — klasifikace rozhodovatelem (§2): Kritický, protože umožňuje
  vydávat se za libovolné zařízení
- T+1 h — zmírnění: rotace `Jwt:Secret` v App Service konfiguraci, restart
  (jedna instance, viz CLAUDE.md bod 6 — krátký výpadek očekávaný), invalidace
  existujících tokenů rotací tajemství samotnou (tokeny jsou stateless, žádná
  revoke-lista dnes neexistuje — `TODO(owner)`: zvážit krátkou platnost JWT
  jako zmírnění tohoto rizika)
- do T+24 h — včasné varování zákazníkům Business režimu podle šablony §5
- do T+72 h — rozšířené hlášení: rozsah (byl secret skutečně zneužit, nebo
  jen exponován?), dotčené organizace
- do T+1 měsíc — závěrečná zpráva: kořenová příčina, přijatá opatření

## Kořenová příčina (cvičná)
Tajemství se do public okna nemělo nikdy dostat — `ProductionConfigurationValidator`
kontroluje jen sílu tajemství při startu, ne jeho případný únik do logů/CI.
Repo bylo dočasně public kvůli billing omezení GitHub Actions (viz
`docs/HANDOFF-2026-09-18.md`) — to zvyšuje expoziční plochu při každém okně.

## Dopad (cvičný)
Obsah zpráv v anonymním režimu zůstává nedotčen (E2E, server ho nikdy
neviděl). V Business režimu by útočník s platným JWT mohl číst metadata,
která server ukládá (§ podle `CallType.Audit`), ne obsah — obsah tam vidí
jen auditorské zařízení organizace, ne server ani útočník s JWT samotným.
Reálné riziko: útočník s platným JWT se může vydávat za zařízení/účet a volat
API v jeho rozsahu.

## Přijatá opatření (cvičná — k realizaci, ne provedená)
- Rotovat `Jwt:Secret` mimo public okno, kdykoli je to možné.
- Přidat `Jwt:Secret` a další produkční tajemství do secret-scanning
  vyloučení z CI logů (ověřit, že GitHub Actions je nikdy needchovávat plain).
- `TODO(owner)`: rozhodnout o krátké platnosti přístupových JWT +
  refresh tokenu, aby rotace tajemství rychleji vypudila staré tokeny.

## Co příště jinak (cvičné)
Tento tabletop ukázal, že incident-response postup (§1–§7) je proveditelný,
ale lhůta T+1 h na zmírnění je optimistická, pokud rozhodovatel není u
počítače — viz známé riziko v §2 (žádná záložní osoba).
