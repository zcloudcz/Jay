# Rozpočtový model bety (I04)

Datum přípravy: 2026-09-16 (UTC). Ceny **nebyly znovu dotazovány přes Azure Retail Prices API v
tomto balíčku** — internetový přístup pro cenový dotaz nebyl v tomto běhu proveden. Číslo
13,14 USD/730 h z `docs/azure-beta-plan.md` (zaznamenáno 2026-09-14, zdroj: Azure Retail Prices API,
West Europe, Linux B1 0,018 USD/h) se přebírá **jen jako historický příklad**, ne jako dnešní
nabídka — před jakýmkoli závazkem k rozpočtu je nutné cenu znovu ověřit (viz Blokace níže).

## Vzorec

```
Celkem = B1_hodinová_cena × skutečné_hodiny_měsíce
       + Blob_GB_měsíc × použité_GB
       + Blob_operace
       + Azure_outbound_traffic
       + přírůstek_externího_serveru_(DB+TURN)
       + daň
```

- Hodiny měsíce: použít **744 h** (31denní měsíc) jako horní odhad, ne 730 h — 730 je jen
  normalizační průměr použitý v historickém dokumentu, skutečná fakturace jde podle kalendářních
  dnů v daném měsíci (28–31 dní × 24 h = 672–744 h).
- Při historické sazbě 0,018 USD/h: 744 h × 0,018 = **13,39 USD** (přepočet historické sazby na
  744 h, ne nová cenová nabídka — viz blocker níže, sazba může být dnes jiná).

## Položky a jejich stav

| Položka | Historická hodnota | Stav dnes |
| --- | --- | --- |
| Linux App Service B1 | 0,018 USD/h (West Europe, 2026-09-14) | **BLOCKER** — neověřeno k dnešnímu datu, ceny se mění, region/měna nutno potvrdit |
| Static Web Apps Free | 0 USD v rámci limitů | Aktuální kvóty nebyly ověřeny (viz `beta-operations.md` bod SWA) — historické "100 GB" je z oficiálního ceníku citovaného 2026-09-14, ne dnes znovu ověřené |
| Private Blob Storage (Standard_LRS) | Neuvedeno v historickém záznamu | **BLOCKER** — GB-měsíc cena, cena operací (PUT/GET) a odhad objemu (viz K03 limity níže) nebyly oceněny |
| Azure outbound (egress) | Neuvedeno | **BLOCKER** — první ~5 GB/měsíc bývá u Azure zdarma, nad tím se účtuje; skutečný objem záloh+API provozu neznámý |
| Externí server (DB + coturn) | "Zero incremental cost only if spare capacity included" (`docs/azure-beta-plan.md`) | **BLOCKER** — smluvní podmínky serveru (paušál vs. měřený traffic) nejsou v tomto repozitáři; I03 evidence potvrzuje TURN port dosažitelný, ale ne cenu ani limit provozu |
| Daň (DPH) | Neuvedeno, "před daní" | **BLOCKER** — zda 20 USD limit zahrnuje DPH, není potvrzeno (viz zadání K05/I04 vstupy) |
| Měna fakturace | Historicky USD (Azure Retail Prices API) | **BLOCKER** — skutečná fakturační měna účtu (může být CZK/EUR s kurzovým rozdílem) neověřena |

**Žádná z výše uvedených BLOCKER položek se nezapisuje jako 0** — jde o pojmenované chybějící
vstupy, ne o prokázanou nulovou cenu, dle požadavku zadání.

## TURN traffic (z I03 měření)

Podle `docs/ops/turn-validation.md`: přibližně 0,9 GB/h egress na jeden obousměrný hovor při 2×1
Mbit/s bez protokolové režie (odhad, ne měření skutečného kodeku). Pro 2 současné hovory až ~1,8–3,6
GB/h podle toho, zda poskytovatel účtuje jen egress nebo ingress+egress. **Měsíční objem závisí na
počtu a délce hovorů beta uživatelů, což není známo** — bez odhadu použití nelze převést na USD.
Poskytovatelův zahrnutý traffic a chování při překročení: **BLOCKER**, vlastník operátor externího
serveru (viz `docs/ops/evidence/I03.md`).

## K03 limity záloh — dopad na kapacitu, ne na cenu

Převzato z K03 (`docs/superpowers/plans/2026-09-16-beta-kontrakty.md`), implementuje D02/B00, I04
zde jen počítá dopad:

- `BackupLimits:MaxFileBytes` = 8 MiB, `MaxPerAccount` = 3, `MaxTotalBytes` = 256 MiB (globální).
- Pro 20 plánovaných účtů (**modelovací scénář, ne vynucený limit registrací**): plné využití by
  vyžadovalo `20 × 3 × 8 = 480 MiB`, což je **více než globální limit 256 MiB**. Globální limit tedy
  odmítne nové uploady dříve, než každý účet vyčerpá svých 3× 8 MiB — nelze slíbit všem účtům tři
  maximálně velké zálohy současně.
- Cenový dopad: 256 MiB (≈0,25 GiB) Blob úložiště je při typických Azure Standard_LRS sazbách řádu
  jednotek centů měsíčně — přesná sazba je součástí BLOCKER výše (Blob GB-měsíc neověřen), ale i
  horní odhad při 256 MiB je zanedbatelný proti ceně B1 plánu. Operace (PUT při uploadu, GET při
  stažení/obnově) mohou při častém použití převážit nad cenou samotného úložiště — neoceněno
  (BLOCKER).
- DB metadata (řádky v `Backup` tabulce), provozní `pg_dump` zálohy a jejich úložiště se oceňují
  odděleně od uživatelských Blob záloh (viz `docs/ops/postgres-restore.md` rozlišení).

## Alerty (50/80/100 %)

Návrh (implementace mimo I04, viz `docs/ops/beta-operations.md`):

| Práh | Adresát | Zásah |
| --- | --- | --- |
| 50 % potvrzeného měsíčního rozpočtu | operátor (e-mail/Action Group) | Sledovat, žádný okamžitý zásah |
| 80 % | operátor | Zkontrolovat neočekávaný traffic/storage růst, zvážit dočasné omezení nových backup uploadů |
| 100 % | operátor | Rozhodnout o zastavení nepodstatné spotřeby (např. dočasně odmítat nové zálohy); **nezastavuje** již vzniklé náklady |

Azure billing má zpoždění (typicky hodiny až ~1 den) — alert na 100 % může přijít až po překročení.
[Azure budget alert nezastaví spotřebu](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
(citováno z `docs/azure-beta-plan.md`, samo tvrzení nebylo v tomto balíčku znovu ověřeno webem, ale
je obecně známé chování Azure Cost Management budgets). **Zastavení web app (`az webapp stop`)
nezastaví účtování App Service plánu** — plán se účtuje podle SKU/kapacity bez ohledu na to, zda
aplikace běží; zrušení plánu nebo resource group je samostatné rozhodnutí se ztrátou dat/služby, ne
automatická náprava.

## SWA Free kvóta

Historický záznam cituje 100 GB zahrnutého bandwidth (`docs/azure-beta-plan.md`, odkaz na oficiální
ceník k 2026-09-14). **Nebylo v tomto balíčku znovu ověřeno** (vyžaduje webový přístup k aktuálnímu
ceníku) — označeno jako `unverified`, nepoužívat jako potvrzenou dnešní garanci bez revize.

## Blokace (souhrn, vlastník I04/operátor)

1. Zda 20 USD zahrnuje DPH a existující server — **chybí rozhodnutí zadavatele/operátora**.
2. Fakturační měna účtu — **operátor** (Azure portál → Cost Management).
3. Aktuální ceny B1/Blob GB-měsíc/operace/egress pro West Europe — **operátor** (Azure Retail
   Prices API dotaz nebo portál, s dnešním datem).
4. Rozsah a cena zahrnutého provozu externího serveru (DB + TURN) — **operátor externího serveru**
   (smlouva/poskytovatel).
5. Očekávaní aktivní beta uživatelé a hodiny videa/měsíc — **produktové rozhodnutí**, potřebné pro
   odhad TURN egressu a Blob operací.
6. Aktuální SWA Free kvóty a podmínky — **operátor** (ověřit oficiální ceník před rolloutem).

Dokud nejsou blokace 1–6 vyřešeny, tento dokument **nepotvrzuje** rozpočtový strop 20 USD/měsíc.
