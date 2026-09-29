# PostgreSQL a Blob: zálohy, obnova, TLS (I02 → O3 / N05)

Runbook pro zálohu a obnovu bety. Server PostgreSQL je mimo Azure (`187.127.83.154:5544`), Blob je
účet `calltypebetazahy`. Rozhodnutí vlastníka z 2026-09-18: **RPO 24 h, RTO 8 h**.

**Stav 2026-09-29 (O3, vlna 1):** skripty jsou hotové a **ověřené lokálně** proti PostgreSQL 17
v Dockeru (obě databáze, souběžné zápisy, obnova do prázdné instance, čtyři negativní scénáře,
off-site kopie do Azurite). Na serveru bety **nic neběží — NOT_RUN, čeká na vlastníka** (kroky V-O3
níže). G2 přejde na PASS až po prvním měřeném běhu na serveru (§6).

## 1. Co se zálohuje a proč

| Data | Kde | Záloha | Pozn. |
| --- | --- | --- | --- |
| `calltype_prod` | PostgreSQL | `backup.sh`, denně, šifrovaně, lokálně + off-site | účty, zařízení, fronta zpráv (šifrované bloby), skupiny, kanály, metadata příloh |
| `calltype_audit` | PostgreSQL | totéž, ve stejné sadě | Business archiv metadat, append-only — ztráta = díra v hash řetězu |
| Blob `backups` | Azure | soft delete 7 dní + zámek účtu | uživatelské zálohy; primární kopie je na zařízení uživatele |
| Blob `channel-media` | Azure | soft delete 7 dní + zámek účtu | obrázky veřejných kanálů (retence 90 dní) |
| Blob `e2e-attachments` | Azure | soft delete 7 dní, **bez zálohy** | E2E šifrovaná média, TTL 30 dní; odesílatel má originál a může poslat znovu |
| Blob `db-backups` | Azure | je to samo záloha (off-site kopie DB) | lifecycle 35 dní, zápis jen přes SAS „create“ |

Provozní záloha databáze **není** uživatelská záloha historie (K03) — jedna nenahrazuje druhou.

## 2. Role na serveru

| Role | K čemu | Skript |
| --- | --- | --- |
| `calltype_prod` | aplikace (hlavní DB, dnes i migrace při startu) | — |
| `calltype_audit_app` / `calltype_audit_ops` | aplikace (INSERT/SELECT + UPDATE vybraných tabulek) / schéma auditní DB | `audit-roles.sql` |
| `calltype_backup` | **jen čtení všeho** (`pg_read_all_data`), jen z loopbacku | `infra/postgres/backup-role.sql` |
| `calltype_monitor` | 4 sloupce fronty + 2 sloupce organizací (hlídání archivátoru) | `infra/archiver/monitor-role.sql` |
| `postgres` | obnova do scratch DB (`CREATE DATABASE`) | — |

Proč zvláštní `calltype_backup`: heslo aplikační role nemá ležet v `.pgpass` cron úlohy, auditní
aplikační role záměrně nečte vše a ops roli nechceme v cronu. `pg_read_all_data` pokrývá i tabulky
z budoucích migrací (není třeba nic přegrantovat po deployi). Vyžaduje PostgreSQL 14+.

## 3. TLS a `VerifyFull`

Postup přepnutí `DefaultConnection` i `Audit` na `SSL Mode=VerifyFull`, umístění CA na App Service
a rotace certifikátu: **`docs/ops/beta-infrastructure.md` §4** (jediný zdroj pravdy). Lokálně ověřeno
2026-09-29: Npgsql 10.0.3 (stejná verze jako API) s `VerifyFull` odmítne podvržený certifikát, špatné
jméno i chybějící CA; dnešní `SSL Mode=Require` se k podvrženému serveru **připojí** (proto O5).

## 4. Záloha — `infra/postgres/backup.sh`

Každý běh vytvoří jednu **sadu** se společným časovým razítkem:

```
calltype_prod_<stamp>.dump.age       pg_dump -Fc, šifrováno veřejným age klíčem
calltype_prod_<stamp>.manifest.age   přesné počty řádků všech tabulek ZE STEJNÉHO snapshotu
calltype_audit_<stamp>.dump.age
calltype_audit_<stamp>.manifest.age
last-success                         heartbeat (zapíše se jen když prošly obě DB)
```

- Snapshot: skript otevře transakci `REPEATABLE READ`, exportuje snapshot (`pg_export_snapshot`),
  v něm spočítá řádky a `pg_dump --snapshot` čte přesně tatáž data. Proto může ověření obnovy chtít
  **přesnou** shodu počtů i na živé DB, do které se během zálohy zapisuje (ověřeno lokálně).
- `calltype_prod` se zálohuje před `calltype_audit` (auditní DB jen roste, pozdější snapshot je
  nadmnožinou organizací, na které může hlavní DB odkazovat).
- Jedna DB selže → druhá se přesto zálohuje, běh skončí `exit 1` a řádkem `FAIL`.
- Rotace: lokálně `KEEP=7` sad na DB; off-site adresář `OFFSITE_KEEP=35`; Blob drží lifecycle 35 dní.

### Jednorázová příprava na serveru (vlastník / operátor — **V-O3a, NOT_RUN**)

1. `apt install age curl postgresql-client-<major serveru>` (klient ≥ verze serveru, jinak `pg_dump`
   odmítne; lokální test byl na 17).
2. `sudo -u postgres psql -v ON_ERROR_STOP=1 -f infra/postgres/backup-role.sql`, pak v `psql`:
   `\password calltype_backup` a `ALTER ROLE calltype_backup LOGIN;`.
3. `pg_hba.conf`: řádek pro `calltype_backup` jen z `127.0.0.1` (`infra/postgres/pg_hba.conf.example`).
4. Na **operátorském** stroji `age-keygen -o calltype-backup.key`; privátní klíč do trezoru (dvě
   kopie, mimo server), na server jen řádek `public key: age1…`.
5. Off-site (doporučeno Azure, nebo `OFFSITE_DIR` na jiném disku/stroji):
   - nasadit `infra/beta-appservice.bicep` (vytvoří kontejner `db-backups` a lifecycle, §7),
   - SAS **jen pro create**, podepsaný klíčem **key2** (odvolání = rotace key2, API používá key1):
     ```bash
     az storage container generate-sas --account-name calltypebetazahy --account-key "$(az storage account keys list -n calltypebetazahy --query '[1].value' -o tsv)" \
       --name db-backups --permissions c --expiry 2027-09-30T00:00Z --https-only -o tsv
     ```
   - na server do `/etc/calltype/backup-sas.url` (0600, vlastník uživatel cronu) celé URL
     `https://calltypebetazahy.blob.core.windows.net/db-backups?<sas>`. Skript URL předává curl přes
     stdin, nikdy v argv. S právem jen `c` server **nemůže** zálohy číst, přepsat ani smazat
     (ověřeno lokálně: PUT stejného jména, DELETE i GET → 403).
   - expirace SAS je v tabulce kontrol `beta-operations.md` (30 dní předem obnovit).
6. `.pgpass`: `127.0.0.1:5544:*:calltype_backup:<heslo>`, `chmod 600`.
7. Cron (denně 03:15 UTC):
   ```
   15 3 * * * AGE_RECIPIENT=age1… OFFSITE_AZURE_SAS_FILE=/etc/calltype/backup-sas.url /opt/calltype/backup.sh >> /var/log/calltype-backup.log 2>&1
   ```
8. Hned první běh ručně a zapsat výstup (řádky `OK … size= duration=`) do §6.

## 5. Obnova a její ověření — `infra/postgres/restore-verify.sh`

```bash
AGE_KEY=/secure/calltype-backup.key RESTORE_HOST=<prázdná instance> RESTORE_PORT=5432 \
  BACKUP_DIR=/var/backups/calltype ./restore-verify.sh            # nejnovější úplná sada
AGE_KEY=… ./restore-verify.sh 20260929T031500Z                    # konkrétní sada
```

Pro každou DB: dešifruje dump i manifest (age ověřuje integritu — poškozený nebo zkrácený soubor
selže už tady), vytvoří **prázdnou** `<db>_restore_verify`, `pg_restore --exit-on-error
--single-transaction`, spočítá řádky všech tabulek a porovná je s manifestem. **PASS** jen při
shodné množině tabulek a shodném počtu řádků v každé. Výstup obsahuje jen názvy tabulek, počty,
ID migrací a časy, nikdy obsah. Scratch DB se na konci smaže (`KEEP_RESTORED=1` ji nechá — obsahuje
produkční metadata, smazat ručně). Nikdy se nevolá `--clean` a nikdy se nesahá na zdrojové DB.

**Kde ověřovat:** ideálně na **jiném** stroji/instanci (skutečná „obnova do prázdné instance“);
na DB serveru jen tehdy, když má místo na dvojnásobek dat. Obnova ze Azure: stáhnout sadu
(`az storage blob download-batch -s db-backups --pattern '*_<stamp>.*' -d <dir>` s operátorovým
přihlášením) a spustit skript s `BACKUP_DIR=<dir>`.

**Pravidelnost:** čtvrtletně (N05) + po každé změně skriptu nebo major verze PostgreSQL. Výsledek
(řádky `RESULT`, časy) zapsat do §6.

### Ztráta serveru (postup na RTO 8 h)

1. Nový Linux server / instance PostgreSQL stejné nebo vyšší major verze (odhad 1–3 h vč. TLS, §3).
2. Role: `audit-roles.sql` (+ hesla), `calltype_prod`, `backup-role.sql`, `monitor-role.sql`.
3. Stáhnout poslední sadu z `db-backups` a obnovit **pod produkčními jmény**: `createdb calltype_prod
   -O calltype_prod` / `createdb calltype_audit -O calltype_audit_ops`, `pg_restore --exit-on-error
   --single-transaction --no-owner --role=<vlastník> -d <db> <dump>`; počty porovnat s manifestem
   (stejný dotaz jako skript). Pak znovu `audit-roles.sql` (granty na obnovené tabulky).
4. `pg_hba.conf` + firewall pro outbound IP App Service; změnit `Host` v connection stringech,
   restart API, `GET /health/ready` = 200.
5. Archivátor (`docs/ops/archiver-runbook.md`) — stav je ve volume, obnovit z jeho zálohy.
6. Zapsat skutečné časy. Data vzniklá po poslední záloze jsou ztracená (RPO ≤ 24 h); fronta
   zpráv se vrátí do stavu ze zálohy — zprávy, které server přijal po záloze a ještě nedoručil,
   jsou pryč, a zprávy doručené po záloze mohou přijít znovu (klient je musí odmítnout jako
   duplicitu podle `MessageId`; ověřit s proudem M). **Uživatele informovat** (`incident-response.md`).

## 6. Měření RPO / RTO

| Měření | Kde | Výsledek |
| --- | --- | --- |
| Záloha obou DB (200 400 řádků fronty, 50 009 řádků auditu, 22,8 MB + 3,8 MB šifrovaně) | lokálně, PG 17 v Dockeru, 2026-09-29 | `OK` za 23 s + 8 s (vč. ~1 s režie `docker run` na každé volání klienta) |
| Konzistence při souběžných zápisech | lokálně | během zálohy 40× INSERT 500 / DELETE 100; manifest 200 400 řádků, živá DB poté 216 000, obnova **přesně** 200 400 → PASS |
| Obnova do prázdné instance + ověření | lokálně | `calltype_prod` 19 tabulek / 202 909 řádků za 12 s, `calltype_audit` 15 / 50 009 za 3 s, celkem 16 s → **PASS** |
| Off-site do Blob (Azurite, SAS `c`) | lokálně | 4 soubory nahrány; přepsání, smazání i čtení tím SAS → 403 |
| Negativní: zkrácený dump / manifest nesedí / špatný klíč / nedostupná DB | lokálně | FAIL + `exit 1` ve všech čtyřech; druhá DB se přesto zálohovala |
| Záloha a obnova **na serveru bety** | DB server | **NOT_RUN — V-O3a/V-O3b, vlastník** |
| Obnova Blob ze soft delete | Azure | **NOT_RUN** — Azurite soft delete nepodporuje; postup §7 |

**RPO:** denní záloha v 03:15 UTC + okamžitá off-site kopie → nejhorší případ 24 h (plus doba do
odhalení selhání; heartbeat `last-success` hlídá práh 26 h, `beta-operations.md`).
**RTO:** datová část (dešifrování + obnova + ověření) je při dnešní velikosti řádově minuty; zbytek
RTO tvoří nový server, TLS, `pg_hba` a přepojení App Service (§5, odhad 2–4 h). 8 h je splnitelných,
**doložené** to bude až po měření na serveru.

## 7. Blob — ochrana a obnova

V `infra/beta-appservice.bicep` (O3/O7):
- **soft delete** blobů a kontejnerů 7 dní (`blobSoftDeleteDays`) — obnova po chybném smazání
  (chyba úklidové služby, omyl operátora),
- **zámek `CanNotDelete`** na storage účtu — smazání účtu (a s ním všech blobů i soft-deleted kopií)
  je dvoukrokový záměrný úkon,
- kontejnery `backups`, `channel-media`, `e2e-attachments`, `db-backups` (vše private),
- lifecycle: `e2e-attachments` smazat po 35 dnech bez změny (pojistka vedle aplikačního úklidu
  po 30 dnech), `db-backups` smazat po 35 dnech.

Obnova smazaného blobu (operátor, přihlášený `az`):
```bash
az storage blob list  --account-name calltypebetazahy -c <kontejner> --include d --prefix <cesta> --auth-mode login -o table
az storage blob undelete --account-name calltypebetazahy -c <kontejner> -n <blob> --auth-mode login
az storage container restore --account-name calltypebetazahy -n <kontejner> --deleted-version <ver> --auth-mode login   # smazaný kontejner
```
Test obnovy (**V-O3c, NOT_RUN**): nahrát testovací blob do `db-backups` (operátor), smazat, `undelete`,
porovnat MD5 (`az storage blob show --query properties.contentSettings.contentMd5`). Zapsat do §6.

**Co soft delete NEchrání:** ztrátu regionu/datacentra (účet je `Standard_LRS`). Pro betu vědomě
akceptováno: `backups` jsou kopie dat ze zařízení, `e2e-attachments` jsou dočasné, `channel-media`
je veřejný obsah s retencí 90 dní. Při přechodu do produkce zvážit GRS nebo off-site kopii
`channel-media`.

**Soukromí (upozornění pro proud D / `data-subject-rights.md`):** soft delete prodlužuje fyzické
smazání blobů (smazané zálohy účtu, přílohy po GDPR výmazu zařízení) o `blobSoftDeleteDays`. Obsah je
šifrovaný klientem, přesto to má být v textu o výmazu uvedeno („do 7 dní“) nebo nastavit 0.

## 8. Checkpoint před migrací a rollback

- Před každou ruční migrací Audit DB (`beta-operations.md`, O2) a před deployem s migrací hlavní DB
  spustit `backup.sh` ručně a počkat na `OK backup set … complete`.
- Neúspěšná migrace: žádný slepý downgrade ani ruční `DROP`/`ALTER`. Obnovit sadu do scratch DB
  (`restore-verify.sh KEEP_RESTORED=1`), porovnat a rozhodnout.
- Dočasný návrat z `VerifyFull` na `Require` je bezpečnostní regrese (zapsat vlastníka a termín).

## Akceptace (N05 / G2)

| Kritérium | Stav |
| --- | --- |
| Záloha obou DB, šifrovaně, off-site | **PASS lokálně**, server NOT_RUN (V-O3a) |
| Obnova do prázdné instance s přesnou kontrolou počtů | **PASS lokálně**, server NOT_RUN (V-O3b) |
| Poškozený dump / nesedící počty / špatný klíč → FAIL | **PASS lokálně** |
| Blob: soft delete + zámek + lifecycle v IaC | **PASS** (`bicep build` + `lint` čisté), nasazení NOT_RUN |
| Blob: test obnovy | NOT_RUN (V-O3c) |
| Doložené RPO 24 h / RTO 8 h na betě | NOT_RUN — G2 zůstává FAIL do prvního měření na serveru |
| `VerifyFull` odmítne podvržený certifikát | **PASS lokálně** (§3), beta NOT_RUN (V-O5) |
