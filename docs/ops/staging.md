# Staging na F1 (N10 / O6) a kontrakt pro `deploy.yml` (P11)

**Rozhodnutí vlastníka 2026-09-18:** staging ano, App Service **F1 (Free)**, vlastní databáze na
stávajícím PostgreSQL serveru, druhá SWA Free. **Cíl N10:** produkce nejde nasadit bez úspěšného
stagingu téhož SHA a ručního schválení.

Stav 2026-09-29: šablona a skript databází jsou hotové a ověřené lokálně (`bicep build` + `lint`
čisté; `staging-databases.sh` proti PostgreSQL 17). **Nic není nasazené — V-O6, NOT_RUN.** Změnu
`deploy.yml` provádí proud P (P11) podle §4; tento proud workflow needituje.

## 1. Co vznikne

| Prostředek | Název (výchozí) | Pozn. |
| --- | --- | --- |
| Resource group | `rg-calltype-staging` (doporučeno, West Europe) | oddělené náklady, `az group delete` stagingu nikdy nezasáhne betu |
| App Service plán | `asp-calltype-staging`, **F1 Linux** | 0 USD compute |
| Web app | `calltype-staging-zahy` | `DOTNETCORE|10.0`, bez Always On, `healthCheckPath=/health` |
| Static Web App | `calltype-staging-web`, Free | vlastní web build (API URL je v buildu, viz §4) |
| Storage | `calltypestagingzahy`, LRS | stejné názvy kontejnerů jako beta, lifecycle 7 dní, bez soft delete |
| DB | `calltype_staging`, `calltype_audit_staging` | na serveru bety, **vlastní role** (`calltype_staging`, `calltype_audit_staging_app/_ops`) |

**Limity F1** (Microsoft Learn „Azure App Service limits“, ověřeno 2026-09-29): Linux Free max.
**5 souběžných WebSocketů** (6. dostane HTTP 429), 60 CPU minut/den, 1 GB RAM, **165 MB odchozích
dat/den**; po překročení je aplikace do půlnoci UTC zastavená (HTTP 403). Bez Always On (studený
start), bez vlastní domény, bez SLA. .NET 10 na Linux F1: `linuxFxVersion` je stejný jako na B1,
**[OVĚŘIT při zakládání]** že ho region nabízí i pro Free (`az webapp list-runtimes --os linux`).
F1 vedle B1 ve stejné RG je od 2021 možné, samostatná RG je doporučená kvůli izolaci, ne kvůli limitu.

## 2. Založení (vlastník — **V-O6, NOT_RUN**)

```bash
az group create -n rg-calltype-staging -l westeurope
az deployment group what-if -g rg-calltype-staging -f infra/staging-appservice.bicep \
  -p @infra/staging-appservice.parameters.example.json      # čisté Create
az deployment group create  -g rg-calltype-staging -f infra/staging-appservice.bicep \
  -p @infra/staging-appservice.parameters.example.json
```
Výstup `webAppPossibleOutboundIpAddresses` → firewall / `pg_hba.conf` DB serveru (řádky „Staging“ v
`infra/postgres/pg_hba.conf.example` — role stagingu smějí jen do databází stagingu).

## 3. Databáze

```bash
sudo -u postgres infra/postgres/staging-databases.sh      # DB + role, hesla NULL (zamčené)
sudo -u postgres psql -c '\password calltype_staging'      # totéž pro _app a _ops
# auditní schéma stagingu jako calltype_audit_staging_ops (stejně jako O2 na betě):
dotnet ef migrations script --idempotent --context AuditDbContext \
  --project src/server/CallType.Audit --startup-project src/server/CallType.Api -o audit.sql
psql "host=… dbname=calltype_audit_staging user=calltype_audit_staging_ops sslmode=verify-full sslrootcert=calltype-db-ca.pem" -v ON_ERROR_STOP=1 -f audit.sql
sudo -u postgres infra/postgres/staging-databases.sh      # znovu: granty na nové tabulky
```
Hlavní DB stagingu migruje API při startu (`Database__ApplyMigrationsOnStartup=true`, jako beta).
Ruční migrace Audit DB se od teď **nejdřív** pouští na stagingu, pak na betě.

Ověřeno lokálně: skript je idempotentní; role stagingu mají model z `audit-roles.sql`
(UPDATE `Organizations` ano, UPDATE `AuditRecords` ne, INSERT ano); do `calltype_staging` se připojí
jen vlastník. **Nález:** PostgreSQL dává `CONNECT` na každou databázi roli `PUBLIC`, takže role
stagingu se umí *připojit* k `calltype_audit` (práva na tabulky nemají). Hlavní ochrana je
`pg_hba.conf` (DB + role na řádek). Doporučený doplněk na betě (vlastník, po kontrole grantů):
`REVOKE CONNECT ON DATABASE calltype_prod, calltype_audit FROM PUBLIC;` — aplikační, backup a
monitor role mají `CONNECT` explicitně.

App settings stagingu (vlastník, jako beta — `beta-infrastructure.md` §5): vlastní `Jwt__Secret`,
`Mfa__EncryptionKey`, `ConnectionStrings__DefaultConnection` (→ `calltype_staging`),
`ConnectionStrings__BlobStorage` (→ `calltypestagingzahy`), `Cors__AllowedOrigins__0` (SWA stagingu),
`Turn__*`. `ConnectionStrings__Audit` až po kroku 3 (bez něj je Business režim na stagingu vypnutý
a smoke Business endpointů je NOT_RUN). Push (`Push__*`) na stagingu **nenastavovat** — staging nemá
posílat notifikace skutečným zařízením. Šablona sama přidá jen netajné výchozí hodnoty
(`ASPNETCORE_ENVIRONMENT=Production`, aby platil stejný validátor konfigurace jako na betě).

## 4. Kontrakt pro `deploy.yml` (implementuje proud P, P11)

Pořadí jobů v **jednom běhu** workflow pro jeden `commit_sha`:

```
validate-inputs → test → build-api ─┬→ deploy-api-staging ─┐
                  build-clients ────┤  (build-web-staging) ├→ smoke-staging → deploy-api (beta) → deploy-web (beta) → smoke-test (beta)
                                    └→ deploy-web-staging ─┘                    ▲ environment calltype-beta: required reviewer
```

1. **Stejný artefakt.** `deploy-api-staging` a `deploy-api` stahují **týž** artifact
   `calltype-release-api-<sha>`; nic se mezi stagingem a produkcí znovu nestaví. Web je výjimka:
   `API_BASE_URL` je `--dart-define` v době buildu, takže staging potřebuje vlastní web build ze
   stejného SHA s `vars.CALLTYPE_STAGING_API_BASE_URL` (P rozhodne: druhý krok buildu, nebo runtime
   konfigurace webu).
2. **Environment `calltype-staging`** bez schvalování; vlastní federated credential (Entra app, subject
   `repo:zcloudcz/Jay:environment:calltype-staging`) s rolí **Website Contributor jen na
   `rg-calltype-staging`**; proměnné `AZURE_STAGING_RESOURCE_GROUP`, `AZURE_STAGING_WEBAPP_NAME`,
   `CALLTYPE_STAGING_API_BASE_URL`, `CALLTYPE_STAGING_SWA_URL`, secret `AZURE_STAGING_SWA_DEPLOYMENT_TOKEN`.
3. **`smoke-staging`** (musí respektovat limity F1):
   - warm-up: `curl --retry 12 --retry-delay 10 --retry-all-errors …/health` (studený start F1 trvá
     desítky sekund),
   - `GET /health/ready` = 200 (DB stagingu + Blob stagingu),
   - web stagingu vrací 200,
   - volitelně ověření verze (až bude endpoint verze — dnes neexistuje, pak se SHA neověřuje),
   - **max. 2 souběžné SignalR/WebSocket spojení** (limit 5, rezerva pro ruční test),
   - nestahovat velké soubory (165 MB/den).
4. **`deploy-api` (beta)** má `needs: [smoke-staging]` a `environment: calltype-beta` s **required
   reviewer** (vlastník). Tím platí „produkce jen po úspěšném stagingu téhož SHA a ručním schválení“ —
   `needs` v rámci jednoho běhu váže obě nasazení na stejný `commit_sha`.
5. Selhání stagingu = běh končí, beta se nedotkne. Žádný `continue-on-error` na staging jobech.
6. **HTTP 403 ze stagingu** může znamenat vyčerpanou denní kvótu F1, ne chybu buildu — smoke to má
   hlásit zvlášť (hlavička/obsah 403 stránky App Service), aby se neopakoval deploy naslepo.
7. CI stále běží jen v public okně se souhlasem vlastníka (R-O2); staging na tom nic nemění.

## 5. Náklady

Compute F1 a SWA Free 0 USD. Storage stagingu: jednotky centů měsíčně (lifecycle 7 dní). DB na
stávajícím serveru (bez přírůstku, pokud má server rezervu — `beta-cost-model.md`).

## 6. Rizika

- Staging DB na stejném serveru jako produkce: izolace jen rolemi + `pg_hba` (gap-ops §8). Pro
  produkci s organizacemi znovu posoudit.
- F1 je sdílený hardware bez SLA — výpadek stagingu zablokuje deploy produkce. Nouzový postup
  (vlastník): ruční schválení výjimky, zapsané v `beta-operations.md`, nikdy ne trvalé vypnutí `needs`.
