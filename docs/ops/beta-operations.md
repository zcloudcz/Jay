# Provozní dohled bety (I04)

## Pravidelné kontroly

| Kontrola | Metoda | Frekvence | Práh zásahu |
| --- | --- | --- | --- |
| API dostupnost | `GET /health` (200 = živý proces) a `GET /health/ready` (200 = DB+Blob dostupné, K05) | 5 minut | 3 po sobě jdoucí selhání |
| Veřejný web | HTTP GET na SWA hostname, očekávat 200 | 5 minut | 3 po sobě jdoucí selhání |
| Poslední úspěšná záloha | Kontrola timestampu poslední `pg_dump` (I02) | denně | žádná úspěšná záloha > 26 h (RPO 24 h + rezerva) |
| Expirace DB/TURN certifikátu | `openssl s_client`/obdobný nástroj, dny do expirace | týdně | < 30 dní do expirace |
| DB disk | Volné místo na externím serveru | denně (operátor serveru) | < 20 % volno |
| TURN traffic | Součet relay egress za měsíc (z coturn logů/metrik) | denně | > 80 % smluvního/rozpočtového limitu (viz `beta-cost-model.md`) |
| Omezené logy | Kontrola velikosti/retence App Service logů | týdně | růst nad nastavený strop |

Návrh: HTTP kontrola po 5 minutách, zásah po 3 po sobě jdoucích selháních (potlačuje jednorázový
blip, ale reaguje do ~15 minut). **Odpovědný operátor a dostupnost alertovacího mechanismu (kam
kontrola posílá výsledek) nejsou v tomto balíčku potvrzeny — BLOCKER, vlastník: operátor/B00.**
`/health` vždy 200 při běžícím procesu **neznamená** funkční DB/zálohy/TURN — použít `/health/ready`
a samostatné kontroly zálohy/certifikátu/TURN, ne jen `/health`.

## Logování — limity a redakce

- Logy omezit velikostí a retencí (App Service `WEBSITE_HTTPLOGGING_RETENTION_DAYS`, zjištěno
  nastaveno v app settings — viz `docs/ops/beta-inventory.md`; konkrétní hodnotu neevidujeme zde,
  je to app setting hodnota, ne jen název).
- Redigovat: `Authorization` hlavičku, SignalR query token (`access_token` v URL), connection
  stringy, text zpráv (šifrovaný payload i kdyby unikl, neloguje se), TURN credentials
  (`username`/`credential` v TURN REST API odpovědi).
- Výpadek logovacího subsystému nesmí shodit API — logování musí být best-effort, ne blokující
  cestu požadavku.
- Namátkou ověřit, že běžné chybové logy (500, validační chyby) netisknou secrets v exception
  message ani stack trace (typicky connection string bývá v `Npgsql` výjimkách — ověřit, že
  middleware chyby loguje bez tohoto detailu do veřejně čitelných logů).

## Postupy při incidentu

Každý postup: detekce → read-only diagnóza → povolená náprava → rollback → potvrzení obnovení.

### Restart API

- **Detekce:** `/health` selhává opakovaně (3+ po sobě).
- **Diagnóza (read-only):** `az webapp log tail` / App Service logy, zkontrolovat poslední deploy,
  paměť/CPU metriky.
- **Náprava:** `az webapp restart` (jediná povolená akce, žádná změna konfigurace za běhu incidentu).
- **Rollback:** pokud restart nepomůže a příčinou je poslední deploy, R01 vrátí artefakt na
  předchozí commit (samostatný proces, mimo I04).
- **Potvrzení:** `/health` a `/health/ready` vrací 200, aktivní SignalR klienti se znovu připojí a
  fronta zpráv se přehraje (přiznat přerušení aktivních hovorů — jedna instance).

### Nedostupná DB

- **Detekce:** `/health/ready` vrací 503 s příčinou DB.
- **Diagnóza:** TCP probe na DB port (jako v `docs/ops/evidence/I02.md`), kontrola DB serveru s
  operátorem, kontrola firewall pravidel vůči aktuálním App Service outbound IP.
- **Náprava:** pokud je příčina firewall/outbound IP posun, aktualizovat `pg_hba.conf` (operátor);
  API samo nic neopravuje, jen čeká/retry podle existující logiky.
- **Rollback:** žádná destruktivní akce; DB se needituje z tohoto postupu.
- **Potvrzení:** `/health/ready` 200, žádná zpráva nebyla tiše potvrzena jako doručená bez skutečného
  zápisu (koordinovat s B00 test na testovací instanci, ne na produkci).

### Plný disk DB

- **Detekce:** operátor serveru hlásí < 20 % volno nebo DB odmítá zápisy.
- **Diagnóza:** velikost tabulek (`QueuedMessage`, `Backup` metadata), stáří nejstarších
  nedoručených zpráv (TTL 30 dní by měl čistit sám, ověřit, že úklidový job běží).
  Toto je čistě read-only diagnostický krok pro tento balíček.
- **Náprava:** operátor uvolní místo (rozšíření disku, ruční VACUUM) — mimo rozsah I04, je to
  provozní zásah na externím serveru.
- **Rollback:** žádný specifický pro I04.
- **Potvrzení:** volné místo nad prahem, `/health/ready` 200.

### Výpadek Blob

- **Detekce:** `/health/ready` vrací 503 s příčinou storage, nebo upload/download zálohy selhává.
- **Diagnóza:** `az storage account show` (read-only, stav účtu), Azure Service Health status.
- **Náprava:** pokud je výpadek na straně Azure, čekat na obnovu (Azure SLA), žádný zásah možný;
  pokud je příčina konfigurace (např. omylem povolený veřejný přístup), opravit vlastnost přes I01
  šablonu/`az storage account update` s minimální změnou.
- **Rollback:** vrátit vlastnost na předchozí ověřenou hodnotu.
- **Potvrzení:** upload/download testovací (ne produkční) zálohy projde.

### Vyčerpaný TURN traffic

- **Detekce:** měsíční součet z coturn logů/metrik překročí smluvní/rozpočtový limit (I03/I04).
- **Diagnóza:** ověřit, zda jde o legitimní nárůst hovorů nebo zneužití (např. cizí klient používá
  uniklé credentials — TTL a `denied-peer-ip` by měly omezit dopad, viz `turn-validation.md`).
- **Náprava:** předem definované chování po vyčerpání musí být rozhodnuto před nasazením — buď
  blokovat nové relayed hovory (informovat klientský tým, aby zobrazil srozumitelnou chybu, ne
  nekonečný spinner), nebo akceptovat překročení do dalšího zúčtovacího období. **Toto rozhodnutí
  není v tomto balíčku učiněno — BLOCKER, vlastník: produkt/B00**, protože vyžaduje shodu s
  poskytovatelem serveru o smluvním limitu (`docs/ops/evidence/I03.md`).
- **Rollback:** obnovit relay bez omezení po potvrzení nového zúčtovacího období nebo navýšení limitu.
- **Potvrzení:** nový hovor přes forced relay opět projde (stejný test jako I03 bod 8).

### Expirovaný certifikát (DB nebo TURN TLS)

- **Detekce:** týdenní kontrola dnů do expirace (viz tabulka výše), nebo TLS handshake selže s
  chybou expirovaného certifikátu.
- **Diagnóza:** `openssl s_client -connect <host>:<port>` (read-only), ověřit skutečné datum expirace.
- **Náprava:** rotace certifikátu podle `docs/ops/postgres-restore.md` bodu 3 (Rotace certifikátu);
  pro TURN TLS analogický postup na straně coturn.
- **Rollback:** pokud rotace selže, dočasný návrat k `SSL Mode=Require` je **bezpečnostní regrese**
  s vlastníkem a termínem nápravy (viz `postgres-restore.md` Rollback), ne tichá náhrada.
- **Potvrzení:** testovací TLS připojení s novým certifikátem projde `VerifyFull`.

### Nedostupný operátor

- **Detekce:** incident vyžaduje zásah na externím serveru (DB/TURN), ale určený operátor
  neodpovídá v očekávaném čase.
- **Diagnóza:** ověřit, zda je incident řešitelný jen z Azure strany (restart API, dočasné
  odmítání nových backup uploadů) bez zásahu na externím serveru.
- **Náprava:** pokud ne, eskalovat na náhradního vlastníka/kontakt (konkrétní eskalační cesta mimo
  rozsah tohoto dokumentu — **BLOCKER, vlastník: B00/produkt** — musí existovat alespoň jeden
  náhradní kontakt s přístupem k externímu serveru).
- **Rollback:** žádný specifický; postup je čistě organizační.
- **Potvrzení:** incident uzavřen po zásahu odpovědného nebo náhradního operátora.

## Rozpočtový incident

Zastavení web app (`az webapp stop`) přeruší provoz API, ale **nezastaví účtování App Service
plánu** — plán (`asp-calltype-beta`, B1) se účtuje podle SKU/kapacity nezávisle na tom, zda na něm
běží aplikace. Zrušení plánu nebo resource group **není automatická náprava** — znamená ztrátu
služby (a u resource group i dat, pokud obsahuje storage/DB), vyžaduje samostatné rozhodnutí po
vyhodnocení dopadu, ne reflexní akci při prvním alertu.

## Testy alertů a limitů (izolovaně)

Test provést na izolovaném cíli (ne generovat velký skutečný účet) — např. simulovat práh v testovací
konfiguraci limitů (K03 backup kvóty jsou implementovány v aplikaci přes B00/D02, I04 zde jen ověřuje
chování z pohledu provozu, neimplementuje druhou sadu limitů). **NOT_RUN** v tomto balíčku — vyžaduje
nasazenou aplikační kvótu (D02/B00) a přístup k testovacímu prostředí, které I04 nemá k dispozici
samostatně; viz `docs/ops/evidence/I04.md`.
