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

**Beta (R-O3): varianta A — DEFAULT DLE DOPORUČENÍ, čeká na potvrzení vlastníka.** Archivátor
běží v Dockeru na stejném Linux serveru jako PostgreSQL, spravuje ho `infra/archiver/docker-compose.yml`
(restart policy, healthcheck, pevně pojmenovaný svazek identity) a hlídá ho
`infra/archiver/check-backlog.sh` (cron). Na betě zatím **neběží — V-O4, NOT_RUN**.

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

Endpoint vyžaduje JWT admina organizace, proto ho automatické hlídání
nepoužívá — viz další oddíl.

## Hlídání a alert (O4)

Dvě úrovně, protože „kontejner běží“ nic neříká o tom, zda se archivuje:

1. **Healthcheck kontejneru** (`docker inspect jay-archiver-org1`): `healthy` = proces drží
   navázané TCP spojení na port API (SignalR WebSocket). Čte `/proc/net/tcp`, image nemá curl.
   Zachytí proces, který běží, ale není připojený (API nedostupné, smyčka reconnectu). Docker
   kontejner kvůli `unhealthy` sám nerestartuje — je to informace pro alert. Za HTTP proxy nastavit
   `ARCHIVER_HEALTH_PORT` na port proxy.
2. **Stáří fronty auditora** — `infra/archiver/check-backlog.sh` na DB serveru, stejný signál jako
   `AuditorLivenessService` (nejstarší nepotvrzená **skupinová** zpráva pro zařízení auditora):

   | Stav | Práh (výchozí) | Význam |
   | --- | --- | --- |
   | OK | stáří < 1 h | běžný provoz, restart i krátký výpadek |
   | WARN | ≥ 1 h (`WARN_AGE_SECONDS`), organizace bez auditora, kontejner ne-`healthy`/chybí | prověřit logy |
   | CRIT | ≥ 12 h (`CRIT_AGE_SECONDS`) | ve 24 h (`Business:AuditorMaxBacklogAgeSeconds`) API zastaví firemní komunikaci organizace |
   | UNKNOWN | kontrola nemůže číst DB | kontrola sama je rozbitá |

   Příprava (**V-O4, NOT_RUN**): `sudo -u postgres psql -f infra/archiver/monitor-role.sql`, pak
   `\password calltype_monitor` + `ALTER ROLE calltype_monitor LOGIN;`, řádek do `pg_hba.conf`
   (jen loopback), `.pgpass`. Role čte jen 4 sloupce fronty a 2 sloupce organizací — ne obsah
   zpráv ani e-maily (ověřeno: `permission denied`). Cron:
   ```
   */15 * * * * ALERT_WEBHOOK_FILE=/etc/calltype/alert-webhook.url /opt/calltype/check-backlog.sh >> /var/log/calltype-archiver-check.log 2>&1
   ```
   Webhook (Slack-kompatibilní `{"text": …}`, URL v souboru 0600) se pošle při změně stavu a pak
   nejvýš jednou za 6 h; zpráva obsahuje jen ID organizací a zařízení a čísla, nikdy názvy.
   Bez webhooku lze použít `MAILTO` cronu (pak bez přesměrování do logu). Kam alerty chodí, určí
   vlastník (**BLOCKER z `beta-operations.md`**).

Ověřeno lokálně 2026-09-29: organizace s 2h frontou → WARN, 13h → CRIT, jen 1:1 zpráva nebo
potvrzená stará zpráva → OK (jako `AuditorLivenessService`), bez auditora → WARN, chybějící
kontejner → WARN, špatné přihlášení → UNKNOWN `exit 3`; webhook jen při změně stavu.

## Záloha stavového svazku

Svazek **`jay-archiver-org1-state`** (→ `/data`; pevné jméno v compose, nezávislé na adresáři,
odkud se compose spouští) obsahuje **klíče zařízení i SQLite databázi relací** — obojí je potřeba
k obnově po havárii stroje. `BOT_STORE_KEY` zálohovat odděleně (např. password manager), ne ve
stejném místě jako svazek. **Nikdy `docker compose down -v`** — smaže identitu auditora.

Záloha je šifrovaná už klíčem `BOT_STORE_KEY` (úložiště klíčů), SQLite relací ale ne — archiv
proto zašifrovat stejným age klíčem jako zálohy DB (`postgres-restore.md` §4) a uložit mimo server.
Po změně relací (nová firemní skupina) zálohu zopakovat; stará záloha obnoví identitu, ale relace
novějších skupin se pak obnoví až dalšími pre-key zprávami (nebo vůbec — ověřit při V-O4).

```bash
# svazek se čte za běhu; pro konzistentní SQLite nejdřív zastavit (výpadek = jen zpožděný archiv)
docker compose -f infra/archiver/docker-compose.yml --env-file infra/archiver/.env stop
docker run --rm -v jay-archiver-org1-state:/data:ro debian:bookworm-slim tar czf - -C / data \
  | age -r "$AGE_RECIPIENT" -o /var/backups/calltype/archiver-org1-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age
docker compose -f infra/archiver/docker-compose.yml --env-file infra/archiver/.env start
```

Obnova: `docker volume create jay-archiver-org1-state`, rozbalit archiv do svazku
(`age -d … | docker run --rm -i -v jay-archiver-org1-state:/data debian:bookworm-slim tar xzf - -C /`,
vlastník souborů uid `bot` z image), `.env` se stejným `BOT_STORE_KEY`, `up -d`. V logu musí být
`as device <stejné id jako před havárií>`.

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

## Compose na serveru (O4) a jeho ověření

`infra/archiver/docker-compose.yml`: pevný název projektu `jay-archiver` a svazku
`jay-archiver-org1-state` (jiný pracovní adresář nebo `-p` by jinak založil nový prázdný svazek =
nový auditor), `container_name: jay-archiver-org1`, `restart: unless-stopped` (dockerd musí být
`systemctl enable docker`), `init: true`, `stop_grace_period: 30s`, healthcheck (výše),
`read_only`, `cap_drop: [ALL]`, `no-new-privileges`.

Ověřeno lokálně 2026-09-29 (image z `src/bots/jay_archiver/Dockerfile`, v sandboxu upravený jen o
CA proxy pro `pub get` a bez `apt-get install ca-certificates`, který sandbox blokuje — lokální API
běželo přes http; lokální API z tohoto commitu):

| Scénář | Výsledek |
| --- | --- |
| `provision` → `up` | device id vypsáno, kontejner `healthy`, log „Archiving organization … as device <id>“ |
| `down` (bez `-v`) → `up` | svazek zůstal, **stejné** device id; `down` trvá ~1 s |
| SIGKILL procesu archivátoru | restart policy ho spustila znovu (`restarts=1`), stejné device id, `healthy` |
| API zastavené 60 s | proces běží, `unhealthy`; po návratu API sám znovu připojen → `healthy`, bez restartu |
| `docker kill` | Docker to bere jako ruční stop → **nerestartuje** (očekávané chování Dockeru) |

**NOT_RUN (vlastník, V-O4):** nasazení na DB server, `provision` proti betě a nastavení auditora
adminem organizace, přejímka „zpráva ve firemní skupině se do 1 min objeví v `AuditRecords`“ a „po
restartu archivátoru se nic neztratí“ (logika ACK po zápisu je pokrytá živým E2E testem
`src/bots/jay_archiver/test/e2e`, který běží proti docker compose, nikdy proti betě).
