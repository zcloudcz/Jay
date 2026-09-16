# PostgreSQL TLS, zálohy a obnova (I02)

Balíček I02 z `docs/superpowers/plans/2026-09-16-beta-infrastruktura.md`. Server je mimo Azure,
`187.127.83.154:5544`, databáze/uživatel `calltype_prod` (dle `docs/azure-beta-plan.md`). Tento
dokument je runbook k provedení určeným operátorem s přístupem na server — **tento balíček sám
žádný krok na produkčním serveru neprovedl**, viz `docs/ops/evidence/I02.md` pro přesné blokace.

## 1. Zjištěný stav (co lze ověřit bez admin přístupu)

- TCP connect probe `187.127.83.154:5544` z tohoto prostředí: **selhal** (timeout), zaznamenáno v
  evidence. Nelze z toho odvodit, že port je celkově nedostupný — může jít o firewall vázaný na
  konkrétní zdrojovou IP (např. jen na App Service outbound rozsah z `beta-inventory.md`), o dočasný
  výpadek sítě mezi tímto prostředím a serverem, nebo o změnu na straně poskytovatele. Vyžaduje
  ověření operátorem se skutečným přístupem k serveru/síti.
- Aktuální connection string (dle historického záznamu) používá `SSL Mode=Require` — šifruje, ale
  neověřuje identitu serveru. To **není** splněním tohoto balíčku.
- Npgsql verze v projektu: `Npgsql.EntityFrameworkCore.PostgreSQL` `10.0.2`
  (`src/server/CallType.Api/CallType.Api.csproj`).
- Skutečná verze PostgreSQL serveru, velikost DB, provozní model a počet aplikovaných migrací
  nebyly v tomto balíčku znovu ověřeny (vyžaduje DB admin přístup) — **BLOCKED**, viz evidence.

## 2. Přístup: aplikační účet vs. migrační účet

- `calltype_app` — pouze DML práva (SELECT/INSERT/UPDATE/DELETE) na tabulky databáze `calltype`
  používané EF Core za běhu; **žádná DDL práva** (nesmí `CREATE`/`ALTER`/`DROP`), žádný superuser.
  Použije se v `ConnectionStrings__DefaultConnection` produkčního API.
- `calltype_migrate` — vlastník schématu, smí `CREATE`/`ALTER`/`DROP` v databázi `calltype`, ale
  nemá přístup mimo tuto databázi a nemá `SUPERUSER`. Použije se jen ručně nebo z odděleného,
  krátkodobého CI kroku při aplikaci migrace, nikdy z běžícího API procesu.
- Rozdělení potvrdit s B00 před změnou `Database__ApplyMigrationsOnStartup` — pokud je zapnuté
  spouštění migrací při startu, API proces by potřeboval `calltype_migrate` oprávnění, což je v
  rozporu s principem minimálních práv. Doporučení: migrace spouštět odděleně (mimo startup API),
  B00 rozhodne o změně configu.
- Nejprve ověřit oprávnění na obnovené (izolované) kopii DB, ne na produkci (viz bod 6).

## 3. Certifikát a `VerifyFull`

### Vydání/instalace certifikátu

1. Vydat certifikát s **SAN odpovídajícím tomu, jak se klient k serveru připojuje** — buď existující
   DNS jméno, nebo IP SAN pro `187.127.83.154` (bez platného SAN `VerifyFull` vždy selže, protože
   ověřuje i shodu jména/IP, ne jen řetěz důvěry).
2. Instalovat privátní klíč na serveru s omezenými právy (čitelný jen účtem PostgreSQL služby).
3. Root/CA certifikát distribuovat aplikaci (App Service) bezpečnou cestou — ne přes veřejné repo;
   Npgsql potřebuje CA soubor dostupný z běžícího kontejneru/instance.

### Syntaxe connection stringu (Npgsql 10.0.2 — k ověření před zásahem)

Očekávaný tvar dle veřejné Npgsql dokumentace pro Npgsql 6+ (klíče case-insensitive):

```
Host=187.127.83.154;Port=5544;Database=calltype;Username=calltype_app;Password=...;
SSL Mode=VerifyFull;Root Certificate=/path/to/ca.pem
```

**Toto není ověřeno proti běžící instanci v tomto balíčku** — vyžaduje testovací připojení ze
stejného prostředí jako API (App Service, ne lokální stroj), viz bod 4. Pokud test ukáže jiný
formát klíče nebo chování u verze `10.0.2`, tento dokument aktualizovat před předáním B00/R01.
`SSL Mode=Require` zůstává v produkci, dokud `VerifyFull` není potvrzeno funkční — necouvat na
`Require` tiše jako "dočasné řešení", to je bezpečnostní regrese (viz Rollback níže).

### Rotace certifikátu

1. Vydat nový certifikát před expirací (doporučeno: upozornění 30 dní předem, viz
   `docs/ops/beta-operations.md`).
2. Nainstalovat nový cert vedle starého (pokud PostgreSQL/proxy podporuje), nebo naplánovat krátké
   servisní okno.
3. Aktualizovat CA/root certifikát na straně aplikace, pokud se mění CA, **před** rotací serverového
   certifikátu — jinak `VerifyFull` odmítne nový cert dřív, než ho aplikace důvěryhodně zná.
4. Po rotaci: testovací připojení z izolovaného klienta (bod 4) musí projít; teprve pak restartovat
   produkční app-settings/proces.
5. Synchronizace času: ověřit, že hodiny serveru i klienta jsou v rámci NTP tolerance — vypršelý
   nebo "budoucí" certifikát kvůli časovému driftu se projeví jako TLS chyba nerozlišitelná od
   špatné CA na první pohled.

### Testovací připojení (izolovaně, ne výměnou na živé DB)

- Připravit samostatné testovací připojení (skript/konzole) používající stejnou verzi Npgsql jako
  API, spuštěné ideálně ze stejné sítě/instance jako produkční app (aby TLS cesta byla identická).
- Očekávané výsledky: správný hostname + platná CA → úspěch; špatný hostname → selhání; nedůvěryhodná
  CA → selhání; platný hostname s vypršelým certifikátem → selhání. Žádný z těchto scénářů nesmí tiše
  spadnout zpět na `Require`.
- **NOT_RUN** v tomto balíčku — vyžaduje síťový přístup k serveru (TCP probe na `5544` selhal, viz
  evidence) a admin-vydaný certifikát, které tento balíček nemá.

## 4. Zálohy — provozní (`pg_dump`) vs. uživatelský export historie

Toto jsou dvě oddělené věci, nezaměňovat:

| | Provozní záloha (tento dokument) | Uživatelská záloha historie (K03, Blob) |
| --- | --- | --- |
| Co zálohuje | Celá databáze `calltype` (schéma, metadata, fronty, účty) | Jeden šifrovaný export historie zpráv jednoho účtu |
| Kdo spouští | Operátor / plánovaná úloha na serveru | Uživatel klienta, na vyžádání |
| Kde je uložena | Mimo disk zdrojové DB, šifrovaně | Azure Blob (`calltypebetazahy`), max 8 MiB/soubor, viz K03 |
| Účel | Obnova celého provozu po ztrátě DB | Obnova historie jednoho uživatele na novém zařízení |
| Nahrazuje druhou? | Ne | Ne |

### Návrh provozní zálohy (k potvrzení operátorem)

- `pg_dump --format=custom --host=187.127.83.154 --port=5544 --dbname=calltype --username=calltype_app` —
  heslo **výhradně** z `.pgpass` nebo `PGPASSFILE` s právy `600`, nikdy na příkazové řádce ani v
  historii shellu (`~/.bash_history` apod.).
- `pg_dump` klient musí být kompatibilní verze se serverem (ověřit `pg_dump --version` vs. skutečná
  verze serveru — blokováno stejně jako bod 1, verze serveru nebyla ověřena).
- Šifrovat výstup (např. `age`/GPG) a ukládat mimo disk zdrojové DB — konkrétní cíl (jiný Blob
  container, jiný server) potvrdí operátor podle rozpočtu v `docs/ops/beta-cost-model.md`.
- **Návrh, ne slib:** denní záloha, 7 denních kopií, RPO 24 h, RTO 2 h. Dokud neproběhne měřený
  restore (bod 6), RTO se nesmí prezentovat jako splněné.

## 5. Obnova do izolovaného cíle

1. Vytvořit **novou, izolovanou databázi** na testovacím/povoleném cíli (ne přepsat existující DB).
2. `pg_restore --exit-on-error --no-owner --dbname=<isolated_test_db> <dump_file>` — nikdy
   `--clean` proti živé DB, nikdy restore přímo do `calltype` produkční databáze.
3. Poškozený/neúplný dump musí `pg_restore` ukončit chybou (`--exit-on-error`); takový pokus se
   nesmí označit jako úspěšná obnova.
4. Po obnově porovnat schéma a `__EFMigrationsHistory` (nebo ekvivalent) s originálem — počet a
   pořadí aplikovaných migrací musí sedět.
5. Traktovat dump produkčních dat jako citlivý i při šifrovaném obsahu zpráv — obsahuje metadata
   (kontakty, časy, e-maily registrovaných účtů, hash hesel) i mimo šifrovaný payload zpráv.
   Testovací instanci izolovat od push notifikací, reálných uživatelů a produkčního Blob účtu.
6. Změřit čas dumpu a čas obnovy; ověřit čitelnost nezávisle získaným dešifrovacím klíčem, pokud je
   dump dodatečně šifrovaný. Do `docs/ops/evidence/I02.md` zapsat jen souhrn (časy, PASS/FAIL),
   nikdy obsah dat.
7. **NOT_RUN** v tomto balíčku — vyžaduje DB admin přístup, izolovanou testovací DB a skutečný dump,
   které tento balíček nemá k dispozici.

## 6. Předání R01 a koordinace s B00

- Checkpoint zálohy před migrací: R01/B00 spustí zálohu (bod 4) těsně před aplikací nové EF Core
  migrace, aby existoval bod návratu.
- Kompatibilní rollback: pokud migrace selže na produkci, neprovádět "slepý" downgrade databáze
  (žádné ruční `DROP`/`ALTER` bez odpovídající down-migrace) — obnovit ze zálohy do izolovaného
  cíle, ověřit, a teprve pak rozhodnout o dalším postupu s B00.
- Startup migrace (`Database__ApplyMigrationsOnStartup`) zůstávají v gesci B00; I02 pouze
  doporučuje oddělení účtů (bod 2), samo config nemění.

## Akceptace a negativní scénáře (K06 stav)

| Kritérium | Status |
| --- | --- |
| Ověřené TLS (`VerifyFull`) funkční spojení z API | NOT_RUN — chybí síťový přístup + platný certifikát |
| Špatné jméno / nedůvěryhodná CA / neplatné credentials selžou | NOT_RUN |
| Odmítnutí nespustí automatický fallback na `Require` | NOT_RUN (návrh v tomto dokumentu, neotestováno) |
| Obnova do izolovaného cíle proběhla a je změřená | NOT_RUN — chybí DB admin přístup a testovací cíl |
| Poškozený dump vrátí chybu, není označen jako obnovený | NOT_RUN |
| `pg_hba.conf.example` bez `0.0.0.0/0`/`trust` | **PASS** (lokální artefakt, viz `infra/postgres/pg_hba.conf.example`) |

## Rollback

- Před jakoukoli TLS změnou ověřit, že současné `SSL Mode=Require` spojení funguje, a mít domluvené
  servisní okno.
- Preferovat opravu CA/jména certifikátu před návratem na nižší úroveň ověření.
- Dočasný návrat k `Require` po neúspěšném `VerifyFull` pokusu **je bezpečnostní regrese** — zapsat
  vlastníka a termín nápravy, balíček I02 zůstává nesplněný, dokud `VerifyFull` neprojde.
- Chyba migrace: neprovádět slepý downgrade DB; obnovit ze zálohy do izolovaného cíle a vyhodnotit
  ztrátu novějších dat s B00 před jakýmkoli zásahem do produkční DB.
