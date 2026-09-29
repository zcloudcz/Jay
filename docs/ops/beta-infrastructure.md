# Infrastruktura bety — provoz s `beta-appservice.bicep` (I01)

Šablona `infra/beta-appservice.bicep` popisuje schválenou topologii z
`docs/superpowers/plans/2026-09-16-beta-infrastruktura.md`: Linux App Service B1 (přesně 1 instance),
Static Web Apps Free, privátní Blob Storage. `infra/main.bicep` a `infra/beta-vm.bicep` jsou
historické a touto šablonou se nenasazují ani neupravují.

## 1. App settings jsou mimo tuto šablonu

Azure `PUT` na kolekci app settings (`Microsoft.Web/sites/config/appsettings`) nahrazuje **celou**
kolekci. Kdyby `beta-appservice.bicep` obsahoval `siteConfig.appSettings` prázdný nebo neúplný,
nasazení by smazalo `Jwt__Secret`, `Turn__SharedSecret`, connection stringy i CORS origins uvedené v
`docs/ops/beta-inventory.md`. Proto šablona `appSettings` vůbec nenastavuje.

**Výjimka od 2026-09-29 (O7):** netajné výchozí hodnoty (`Attachments__*`, `Calls__*`,
`Push__Apns__BundleId`) přidává modul `infra/modules/appsettings-merge.bicep`. Ten při nasazení
načte živou kolekci (`list(.../config/appsettings)`) a zapíše `union(výchozí, živé)` — **existující
hodnoty vždy vyhrají**, přidají se jen chybějící klíče, nic se nemaže. Viz §5.

**Požadavek na R01:** deploy pipeline musí před zápisem app settings načíst existující kolekci
(`az webapp config appsettings list`), sloučit ji s novými/měněnými klíči a zapsat celek zpět
(read-merge-write), nikdy neposílat jen podmnožinu. Totéž platí pro `Cors__AllowedOrigins__N` a
`Turn__Urls__N` pole indexovaná číslem — chybějící index v novém zápisu pole zkrátí.

## 2. Dvě cesty nasazení

### A) Převzetí existujícího prostředí (aktuální stav bety)

1. Ověřit shodu názvů/regionu s `docs/ops/beta-inventory.md`.
2. `az bicep build --file infra/beta-appservice.bicep --outfile <tmp>.json` → očekávat exit 0.
3. `az deployment group what-if --resource-group rg-calltype-beta --template-file infra/beta-appservice.bicep --parameters @infra/beta-appservice.parameters.example.json` a vysvětlit každý řádek diffu (viz `docs/ops/evidence/I01.md`).
4. Nejasný destruktivní diff (mazání DB/storage, druhá instance, změna hostingu, mazání app settings) = zastavit, neposílat `create`.
5. Skutečné `az deployment group create` provádí až určený operátor po schválení diffu z kroku 3, mimo rozsah tohoto balíčku (I01 dodává jen validaci, ne provedení).

### B) Instalace od nuly v novém, předem povoleném cíli

1. Zvolit novou resource group / názvy (musí být globálně unikátní pro web app, SWA a storage account).
2. Upravit `infra/beta-appservice.parameters.example.json` na nové názvy, region ponechat podle
   schváleného rozpočtu (West Europe má ověřenou cenu B1 v `docs/ops/beta-cost-model.md`).
3. `az bicep build` a `what-if` stejně jako výše — u nového cíle bude what-if ukazovat čisté `Create`.
4. Před prvním startem aplikace bezpečnou cestou (ne v repozitáři) doplnit `Jwt__Secret` (≥32 znaků,
   ne `REPLACE_ME_IN_PRODUCTION...` z `appsettings.json`), `Turn__SharedSecret`, connection stringy a
   CORS origin. Nikdy nenasazovat s výchozím vývojovým heslem/secretem.
5. Náklad nové placené instalace (druhý B1 plán, druhý storage account) vyžaduje samostatný souhlas s
   konkrétní částkou — tento balíček takový test sám neprovádí.

## 3. Rozhraní pro R01

- Web app: `calltype-beta-zahy`, plán `asp-calltype-beta` (Linux B1, capacity 1), region West Europe.
- SWA: `calltype-beta-web`, SKU Free.
- Runtime: `.NET 10` (`linuxFxVersion: DOTNETCORE|10.0`), publikační příkaz zůstává existující
  `dotnet publish` workflow — nahradit nesoulad v `.github/workflows/deploy.yml` (staví do ACR/Container
  Apps) publikací do App Service; sám workflow needituje I01.
- Veřejné URL: `https://calltype-beta-zahy.azurewebsites.net`,
  `https://orange-bush-07e1b5803.6.azurestaticapps.net`.
- Pravidlo tajemství: nikdy nezapisovat hodnoty do Gitu/CI logů; jen názvy klíčů (viz
  `docs/ops/beta-inventory.md`).
- Jedna instance: `beta-appservice.bicep` fixuje `sku.capacity: 1` a nenabízí autoscale parametr;
  R01 nesmí capacity zvyšovat bez samostatného architektonického rozhodnutí (viz Global Constraints).
- `Proxy__KnownProxy`: neměnit bez ověření skutečného proxy řetězce s B00; tato šablona proxy
  nastavení vůbec neobsahuje (je součástí app settings, ne infra topologie).

## 3a. Rollback

Šablona mění vlastnosti existujících prostředků (SKU, TLS, FTP, WebSockets, tagy) a od 2026-09-29
přidává podřízené prostředky storage (kontejnery, soft delete, lifecycle, zámek) a chybějící netajné
app settings (§5, §6) — nepoužívá `complete` deployment mode ani mazání resource group. Inkrementální
nasazení nic neodebere: vypnutí zámku nebo pravidla parametrem ho **neodstraní**, to je ruční
`az lock delete` / `az storage account management-policy` se souhlasem vlastníka. Návrat k předchozímu stavu:

1. Zaznamenat aktuální hodnoty vlastností před zásahem (tento dokument + `beta-inventory.md`).
2. Vrátit jednotlivou vlastnost (`az webapp config set ...`) nebo redeploy šablony s předchozími
   parametry — nikdy `az group delete` ani deployment mode `Complete`.
3. Aplikační artefakt (kód, ne infrastrukturu) vrací R01 samostatně.
4. Restart App Service přeruší aktivní hovory (jedna instance drží stav hovorů v paměti) — přiznat
   výpadek a po restartu ověřit, že klienti znovu navážou SignalR spojení a fronta zpráv se přehraje.

## 4. PostgreSQL TLS: `VerifyFull` pro `Default` i `Audit` (O5)

**Proč:** dnešní `SSL Mode=Require` šifruje, ale neověřuje, s kým API mluví. Lokální test
(2026-09-29, Npgsql 10.0.3 = verze API, cesta `UseNpgsql` jako v `Program.cs`) ukázal, že se s
`Require` API **připojí i k serveru s podvrženým certifikátem** a pošle mu heslo. S `VerifyFull`:

| Případ | Výsledek |
| --- | --- |
| náš CA + certifikát s IP SAN `127.0.0.1`, `Host=127.0.0.1` | připojeno (`ssl=true`) |
| podvržený server (jiná CA, stejná jména) | **odmítnuto** (`AuthenticationException`) |
| správný server, jméno mimo SAN (`localhost`) | **odmítnuto** |
| `VerifyFull` bez `Root Certificate` (jen systémové CA) | **odmítnuto** — privátní CA musí být uvedená |
| chybějící soubor CA | **odmítnuto** (`DirectoryNotFoundException`), žádný tichý fallback |
| `VerifyCA` se špatným jménem | připojeno → proto `VerifyFull`, ne `VerifyCA` |
| zápis `SslMode=VerifyFull;RootCertificate=…` | funguje stejně jako `SSL Mode` / `Root Certificate` |

### Postup (vlastník / operátor — **V-O5, NOT_RUN**)

1. **CA a certifikát serveru** (na operátorském stroji, ne na DB serveru):
   ```bash
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
     -subj "/CN=CallType DB CA" -keyout calltype-db-ca.key -out calltype-db-ca.pem \
     -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=calltype-db" \
     -keyout server.key -out server.csr
   printf 'subjectAltName=IP:187.127.83.154\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > san.cnf
   openssl x509 -req -in server.csr -CA calltype-db-ca.pem -CAkey calltype-db-ca.key -CAcreateserial \
     -days 825 -extfile san.cnf -out server.crt
   ```
   SAN musí odpovídat přesně tomu, co je v `Host=` (dnes IP; při přechodu na DNS jméno přidat
   `DNS:` a vydat znovu). Klíč CA do trezoru, **nikdy** na server ani do repozitáře.
2. **Server:** `server.crt` + `server.key` (0600, vlastník `postgres`) do datového adresáře,
   `ssl = on`, `ssl_cert_file`, `ssl_key_file` v `postgresql.conf`, `SELECT pg_reload_conf();`
   (reload stačí, restart ne). Ověřit: `openssl s_client -starttls postgres -connect 187.127.83.154:5544
   -CAfile calltype-db-ca.pem -verify_return_error` → `Verify return code: 0`.
3. **CA na App Service** (veřejný certifikát, není tajemství) — mimo `wwwroot`, aby ho zip deploy
   nepřepsal (`/home` je persistentní):
   ```bash
   az webapp deploy -g rg-calltype-beta -n calltype-beta-zahy --type static --restart false \
     --src-path calltype-db-ca.pem --target-path /home/site/certs/calltype-db-ca.pem
   ```
4. **Connection stringy** — oba (`ConnectionStrings__DefaultConnection` i `ConnectionStrings__Audit`)
   změnit jen v části TLS, heslo se nemění:
   `…;SSL Mode=VerifyFull;Root Certificate=/home/site/certs/calltype-db-ca.pem`
   (read-merge-write, nikdy zápis podmnožiny). `ConnectionStrings__AuditMigrations` na betě
   nastavené není; operátorův `psql` pro ruční migrace použije `sslmode=verify-full sslrootcert=calltype-db-ca.pem`.
5. Restart, `GET /health/ready` = 200 (obě DB), v logu žádné `AuthenticationException`.
6. Když readiness nenaběhne: **nevracet tiše `Require`** — nejdřív ověřit SAN proti `Host=` a cestu
   k CA (Kudu SSH `ls -l /home/site/certs`). Návrat na `Require` jen jako zapsaná dočasná regrese.

### Rotace certifikátu serveru (každé ~2 roky, upozornění 30 dní předem — `beta-operations.md`)

1. Vydat nový `server.crt` **stejnou CA** (kroky 1b–1c) → aplikace nic nemění.
2. Nahradit soubory na serveru, `pg_reload_conf()`; nová spojení dostanou nový certifikát, stávající
   dožijí.
3. Ověřit `openssl s_client … -verify_return_error` a `/health/ready`.

### Rotace CA (výjimečně: kompromitace, konec platnosti)

1. Vydat novou CA. Na App Service nahrát **bundle obou CA** (`cat old.pem new.pem > calltype-db-ca.pem`,
   krok 3) a restartovat — API teď věří staré i nové CA.
2. Na serveru nasadit certifikát od nové CA, reload, ověřit.
3. Nahrát bundle jen s novou CA, restart. Pořadí je nutné: opačně by `VerifyFull` odmítl nový
   certifikát dřív, než mu API věří.
4. Hodiny serveru i App Service v NTP toleranci — posunutý čas vypadá jako neplatný certifikát.

## 5. App settings: co je tajné a kdo je nastavuje (O7)

| Klíč | Tajné | Kdo nastavuje |
| --- | --- | --- |
| `Attachments__RetentionDays` (30), `__UploadWindowHours` (24), `__MaxCiphertextBytes`, `__MaxBytesPerDevicePerDay`, `__MaxTotalBytesPerDay` | ne | bicep (merge, jen chybějící) — kapacitní/nákladové knoby; `RetentionDays` musí zůstat **< 35** (lifecycle) |
| `Calls__PendingTtlSeconds` (45), `Calls__MaxCallPushesPerCallerPerMinute` (6) | ne | bicep (merge) |
| `Push__Apns__BundleId` (`cz.zcloud.jay`) | ne | bicep (merge) |
| `Push__Apns__TeamId`, `Push__Apns__KeyId`, `Push__Apns__PrivateKeyP8` (celý PEM `.p8`) | **ano** (`PrivateKeyP8`) | vlastník, **všechny tři najednou** (V4) — validátor produkce odmítne start, když je nastavená jen část |
| `Push__FcmServiceAccountJson` | **ano** | vlastník (V3) |
| `ConnectionStrings__*`, `Jwt__Secret`, `Mfa__EncryptionKey`, `Turn__Cloudflare__ApiToken` | **ano** | vlastník |

Změna výchozí hodnoty v bicepu **nezmění** hodnotu, která už v App Service je (existující vyhrává);
k tomu `az webapp config appsettings set` nebo nejdřív klíč smazat. Smazaný klíč přidá další
nasazení bicepu znovu s výchozí hodnotou.

## 6. Změny šablony 2026-09-29 — co ukáže `what-if`

Očekávané řádky (vše `Create` nebo `Modify`, žádné `Delete`):
- `blobServices/default` Modify: `deleteRetentionPolicy` a `containerDeleteRetentionPolicy` 7 dní.
  Pozor: PUT nastaví blob service vlastnosti podle šablony — kdyby na účtu byla ručně nastavená
  CORS pravidla, what-if je ukáže jako mazaná (dnes žádná nejsou známa; API bloby proxuje).
- `containers` `backups`, `channel-media` (Modify/NoChange — vytvořilo je API), `e2e-attachments`,
  `db-backups` (Create).
- `managementPolicies/default` Create — **vlastní všechna lifecycle pravidla účtu**; pravidla
  přidaná ručně v portálu by další nasazení smazalo.
- `Microsoft.Authorization/locks` Create — nasazující potřebuje Owner / User Access Administrator
  (OIDC principál z `deploy.yml` s rolí Website Contributor to neumí a nemá).
- `deployments/calltype-nonsecret-appsettings` → `sites/config/appsettings` Modify: jen **přidané**
  klíče z §5; jakýkoli řádek „remove“ u existujícího klíče = zastavit a nenasazovat.
- `az bicep build` / `bicep lint`: 0 chyb, 0 varování (Bicep CLI 0.47.16, 2026-09-29).

## 7. Staging (N10 / O6)

Samostatná šablona `infra/staging-appservice.bicep` (F1 + SWA Free + vlastní storage) a databáze
`calltype_staging` / `calltype_audit_staging` (`infra/postgres/staging-databases.sh`). Postup a
kontrakt pro `deploy.yml` (proud P, P11): `docs/ops/staging.md`.
