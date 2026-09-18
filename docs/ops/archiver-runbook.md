# Runbook: jay_archiver (W2-E)

Co je `jay_archiver`: proces, který se v Business režimu připojí jako **auditor** —
viditelný tichý člen každé firemní skupiny (§ 316 ZP — nikdy skrytý audit). Pro
každou zprávu ji dešifruje v paměti, spočítá metadata a zapíše je přes
`POST /orgs/{id}/audit/records`. Zprávu potvrdí (ACK) až po úspěšném zápisu
(2xx) — nikdy dřív (K01). Server nikdy nevidí obsah zprávy; archivátor sám
obsah po zápisu zahazuje.

## Kdo co vidí — podle varianty hostingu

Auditor je jen další zařízení se svým párem klíčů. **Kdo drží klíč
(`BOT_STORE_KEY` + stavový adresář), ten může dešifrovat obsah firemních
konverzací**, ne server sám — proto na tom, kde archivátor běží, záleží.

| Varianta | Kde běží | Kdo drží klíč | Důsledek |
| --- | --- | --- | --- |
| **A — na serveru provozovatele** (beta) | Linux server provozovatele (stejný stroj jako PostgreSQL) | Provozovatel (technicky) | Provozovatel má technickou možnost číst obsah firemních konverzací zákazníka. Organizace tomu musí důvěřovat smluvně/procesně — technicky to omezené není. |
| **B — vyhrazený cloudový kontejner** (očekávaná běžná varianta) | Jeden kontejner na organizaci, izolovaný od ostatních zákazníků | Provozovatel (technicky), ale odděleně per organizace | Stejné jako A pro danou organizaci, ale žádná organizace nevidí data jiné — samostatný kontejner, samostatný svazek, samostatný klíč. |
| **C — hostováno zákazníkem** | Infrastruktura organizace samotné | Organizace | Nikdo mimo organizaci obsah nevidí — ani provozovatel Jay. Provozovatel dodává jen image. |

Image je pro všechny tři varianty **stejný** (`src/bots/jay_archiver/Dockerfile`),
liší se jen konfigurace (env proměnné, svazek). Nic v obrazu nepředpokládá
Azure ani společný stroj s databází.

## Provisioning

### 1. Kdo nastaví auditora

`provision` jen zaregistruje zařízení auditora a vypíše jeho `deviceId`.
Auditorem organizace ho udělá **admin organizace v aplikaci**
(Organizace → Zařízení auditora → vložit vypsané id). Provozovatel
archivátoru tak nikdy nedrží přihlašovací údaje admina a postup funguje
nezávisle na MFA (N03b) — admin se přihlašuje přes appku jako obvykle.

Volitelná zkratka pro automatizaci: `--admin-token <jwt>` zavolá
`PUT /orgs/{id}/auditor` rovnou. Od N03b musí být tento token **step-up**
(vrácený `POST /accounts/{id}/mfa/verify`, ne obyčejný token zařízení z
`POST /auth/token`) — `PUT /orgs/{id}/auditor` je OrgAdmin+ akce a bez MFA
odpoví 403 `mfa_required`. Token nesmí skončit v historii shellu ani v
compose souboru (`read -s ADMIN_JWT`).

### 2. `BOT_STORE_KEY`

```bash
openssl rand -base64 32
```

32 náhodných bajtů, base64. Toto je JEDINÝ tajný klíč archivátoru — bez něj
(a bez zálohy stavového adresáře, viz níže) nejde obnovit identitu zařízení.
Vlož do `infra/archiver/.env` (kopie `.env.example`, `.env` je gitignored).

### 3. Build a první spuštění

```bash
cd infra/archiver
cp .env.example .env   # a doplnit JAY_API_URL, JAY_ORG_ID, BOT_STORE_KEY
docker compose build

# Provisioning — jednorázově. Vypíše deviceId nového auditora; to admin
# organizace vloží v aplikaci (viz bod 1). Teprve potom má smysl ostrý běh.
docker compose run --rm archiver-org1 provision --state /data/archiver

# Ostrý běh:
docker compose up -d
```

## Čtení logů

```bash
docker compose logs -f archiver-org1
```

Archivátor loguje na stderr (chyby, varování) a stdout (start zprávy). Bez
`BOT_STORE_KEY` nebo s nesprávným klíčem proces skončí ihned s jasnou
jednořádkovou chybou a nenulovým exit kódem (restart policy `unless-stopped`
ho zkusí spustit znovu — u špatného klíče to bude smyčka, řešit ručně).

## Kontrola živosti (liveness)

`GET /orgs/{id}/audit/records/count` (admin JWT) nově vrací kromě `count`
i:

- `lastArchivedAt` — kdy byl zapsán poslední záznam. `null` = nikdy nic
  nearchivováno.
- `pendingForAuditor` — kolik zpráv čeká na doručení auditorskému zařízení
  (fronta store-and-forward). Rostoucí číslo = archivátor zprávy nevyzvedává.
- `oldestPendingAt` — kdy byla zařazena nejstarší čekající zpráva.

**Co je v pořádku:** `pendingForAuditor` nízké a kolísající kolem nuly,
`lastArchivedAt` čerstvé (řádově minuty až jednotky hodin podle provozu
organizace).

**Co je problém:** `pendingForAuditor` trvale roste a `oldestPendingAt` se
blíží 30 dnům (TTL fronty — po vypršení se zpráva ztratí, nedá se dohnat).
Zkontrolovat `docker compose logs`, zda proces vůbec běží a je připojený.

Toto je jediný signál dostupný dnes — žádná UI obrazovka ani alerting nad
tímto endpointem zatím neexistuje (mimo rozsah W2-E).

## Záloha stavového svazku

Svazek (`archiver-org1-state` → `/data`) obsahuje **klíče zařízení i SQLite
databázi relací** — obojí je potřeba k obnově po havárii stroje. `BOT_STORE_KEY`
zálohovat odděleně (např. password manager), ne ve stejném místě jako svazek.

```bash
docker run --rm -v archiver-org1-state:/data -v $(pwd):/backup debian:bookworm-slim \
  tar czf /backup/archiver-org1-$(date +%Y%m%d).tar.gz -C / data
```

**Ztráta klíče nebo svazku = nové auditorské zařízení.** `PUT /orgs/{id}/auditor`
změní jen nastavení organizace (příští nové skupiny dostanou nového auditora).
**Existující firemní skupiny svého auditora nezmění** — `auditorDeviceId`
členství ve skupině je dnes needitovatelné. Důsledek: staré skupiny zůstanou
bez fungujícího archivátora, dokud se pro ně neřeší ruční migrace (mimo rozsah
dnešního API) — nová identita auditora se týká jen nově vznikajících skupin.

## Upgrade

```bash
cd infra/archiver
docker compose build
docker compose up -d
```

Stav (klíče, DB) je ve svazku, ne v image — upgrade image nevyžaduje nový
`provision`.

## Známé limity

- Jeden proces = jedna organizace. Druhá organizace = druhá služba v
  `docker-compose.yml`, druhý svazek, druhý `BOT_STORE_KEY` (viz komentář
  v souboru).
- Archivuje jen metadata (E03b — plný obsah archivu — zatím není
  implementováno).
- Hovory (call) se nearchivují jako obsah, jen jako metadata podle typu.
- Zprávy čekající na mrtvého archivátora vyprší po 30 dnech (store-and-forward
  TTL) — nedají se zpětně dohnat.
