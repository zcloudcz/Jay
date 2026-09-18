# Zvládání bezpečnostních incidentů (N04)

Platí pro Jay (CallType) — beta i budoucí produkci. Vychází z rozhodnutí
zadavatele 2026-09-18 (`docs/superpowers/plans/2026-09-18-nis2-auditovatelnost.md`,
§4 bod 5): bezpečnostní kontakt je Martin Zahálka, záložní osoba není.

## 1. Klasifikace

| Stupeň | Popis | Příklad |
| --- | --- | --- |
| **Kritický** | Únik obsahu zpráv, kompromitace privátních klíčů, únik podpisového tajemství (JWT, TOTP seed), plný přístup útočníka do produkční DB nebo Blob | Únik `Jwt:Secret`, RCE na App Service |
| **Vysoký** | Neoprávněný přístup k metadatům (kdo komu psal, kdy), výpadek dostupnosti přes SLA, obejití autentizace/autorizace bez potvrzeného zneužití | Zranitelnost v autorizaci endpointu bez důkazu zneužití |
| **Střední** | Zranitelnost v závislosti bez známého zneužití, konfigurace mimo baseline | Kritická CVE v NuGet/pub balíčku, dosud nevyužitá |
| **Nízký** | Kosmetická/provozní odchylka bez bezpečnostního dopadu | Chybějící hlavička, neaktuální dokumentace |

Klasifikaci provádí a mění pouze osoba z §2 — nejde o hlasování týmu (tým dnes
ani neexistuje jako oddělené role).

## 2. Kdo rozhoduje

**Jediná osoba: Martin Zahálka** (majitel produktu i provozu). Rozhoduje o
klasifikaci, o tom, zda incident zakládá oznamovací povinnost, a o obsahu
komunikace směrem k zákazníkům.

**Známé riziko:** neexistuje záložní osoba. Pokud je rozhodovatel
nedostupný, incident se nezpracuje, dokud se nevrátí, nebo dokud se
nerozhodne o svolání externí pomoci ad hoc. `TODO(owner)`: určit zástupce,
jakmile bude druhý člověk s dostatečným přístupem k produkci.

## 3. Kontaktní kanál

- Web: `www/.well-known/security.txt` (RFC 9116).
- API: `GET /.well-known/security.txt` — text/plain, `Contact` z konfigurace
  `Security:ContactUri`; není-li nastaveno, endpoint vrací 404 (raději žádný
  soubor než špatný kontakt).
- **Bezpečnostní kontakt: `martin@zcloud.cz`** (určil vlastník 2026-09-18).
  Na API se nastavuje jako `Security__ContactUri=mailto:martin@zcloud.cz`;
  web má vlastní statický `www/.well-known/security.txt`. Telefon určen není.

## 4. Lhůty podle NIS2 (dodavatel → zákazník)

Jay v roli dodavatele služby informuje své zákazníky (organizace v Business
režimu) analogicky k lhůtám, které NIS2 ukládá regulovaným subjektům vůči
orgánům. Bez potvrzení, že Jay je sám regulovaným subjektem, se tyto lhůty
berou jako **závazek vůči zákazníkům**, ne jako potvrzené právní podání:

| Krok | Lhůta od zjištění | Obsah |
| --- | --- | --- |
| Včasné varování | do **24 h** | stručné oznámení, že incident nastal, klasifikace, zda je podezření na protiprávní/úmyslnou příčinu |
| Hlášení / oznámení zákazníkům | do **72 h** | rozšířené posouzení dopadu, závažnost, dotčené organizace/rozsah dat |
| Závěrečná zpráva | do **1 měsíce** | popis incidentu, kořenová příčina, přijatá opatření, případný přeshraniční dopad |

Interní hodiny běží od okamžiku, kdy klasifikaci provede rozhodovatel z §2 —
ne od prvního podezření bez ověření.

## 5. Šablona oznámení zákazníkům (do 24 h)

```
Předmět: [Jay] Bezpečnostní oznámení — <stručný název incidentu>

Zjistili jsme bezpečnostní incident dne <datum/čas UTC>.

Co se stalo (stručně, bez citlivých detailů usnadňujících zneužití):
<...>

Koho se to týká:
<konkrétní organizace/rozsah, nebo "prověřujeme rozsah, doplníme do 72 h">

Co už jsme udělali:
<...>

Co doporučujeme vám:
<...>

Další update do 72 hodin na tomto kanálu.
Kontakt: <security.txt Contact>
```

## 6. Šablona postmortemu

```
# Postmortem — <název incidentu> (<datum>)

## Shrnutí
Stupeň závažnosti, dotčené komponenty, doba trvání.

## Časová osa (UTC)
- <čas> — zjištění
- <čas> — klasifikace
- <čas> — varování zákazníkům (pokud relevantní)
- <čas> — zmírnění
- <čas> — vyřešeno

## Kořenová příčina
...

## Dopad
Co bylo/nebylo vystaveno; obsah zpráv NIKDY není na serveru čitelný
(anonymní režim) — u Business režimu upřesnit, zda šlo o metadata archivu,
nebo o kompromitaci auditorského zařízení organizace.

## Přijatá opatření
...

## Co příště jinak
...
```

## 7. Evidence incidentů

Incidenty se zapisují jako soubory v `docs/security/incidents/`, ne do
databáze — append-only, verzované gitem, dostupné i offline. Jeden soubor na
incident: `docs/security/incidents/YYYY-MM-DD-strucny-nazev.md`, vyplněný
podle šablony postmortemu v §6 (i pro cvičné/tabletop incidenty — viz §8).

## 8. Cvičný záznam (tabletop) — únik JWT signing secretu

Záznam cvičení: `docs/security/incidents/2026-09-18-tabletop-jwt-secret-leak.md`.
