# Infrastruktura bety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reprodukovat stávající levnou infrastrukturu, ověřit PostgreSQL a TURN a dodat proveditelný provozní postup s měřitelnými limity.

**Architecture:** Jedna instance Linux App Service B1 hostuje .NET API a SignalR. Flutter web běží na Static Web Apps Free, šifrované uživatelské zálohy v privátním Blob Storage; PostgreSQL a coturn zůstávají na existujícím externím serveru. Jedna instance je záměrná, směrování hovorů nyní závisí na paměti procesu.

**Tech Stack:** Azure Bicep a CLI, ASP.NET Core/.NET 10, PostgreSQL/Npgsql, coturn, Flutter WebRTC, GitHub Actions.

**Spec:** [Hlavní zadání](2026-09-16-beta-zadani.md), [sdílené kontrakty](2026-09-16-beta-kontrakty.md), [historický infrastrukturní plán](../../azure-beta-plan.md).

## Global Constraints

- Linux App Service B1, přesně jedna instance; Static Web Apps Free; privátní Blob Standard_LRS; PostgreSQL a coturn na existujícím serveru.
- Nevytvářet Azure VM, Container Apps, managed PostgreSQL, placený ACR, placený SignalR, Application Insights ani kupovanou doménu. Změna architektury vyžaduje samostatné rozhodnutí.
- Historický požadavek je nejvýše 20 USD měsíčně. Dosud není dokázáno, že jej provoz splní. Rozpočtové upozornění není finanční pojistka ani automatické zastavení spotřeby.
- Nové kapacitní hodnoty v tomto dokumentu jsou plánovací návrhy k potvrzení, nikoli existující limity nebo dokázaná kapacita.
- Tento dokument je zadání, jeho vytvoření nespouští nasazení ani obnovu dat. Nejprve dodat diff, validaci a odhad dopadu; produkční zásah provádí určený operátor v povoleném rozsahu.
- Žádná hesla, JWT, TURN credentials, connection strings, SAS, privátní klíče nebo dumpy do Gitu, reportů a veřejných CI artifacts. Zapisovat názvy nastavení a výsledek kontroly, nikoli hodnoty tajemství.
- `Program.cs`, `appsettings*.json` a migrace vlastní integrační koordinátor B00. Požadavky na změny těchto souborů předat B00. CI/CD v `.github/workflows/` vlastní R01.
- Historické `infra/main.bicep`, `infra/parameters.dev.json`, `infra/beta-vm.bicep` a `infra/beta-compose.yml` nejsou cílové nasazení. V těchto balíčcích je neupravovat ani nenasazovat.

## Co je skutečně známo

Při přípravě zadání 2026-09-16 byly přečteny soubory repozitáře. Azure, externí server, ceny ani běžící klienti nebyli nově ověřeni.

| Zjištění | Druh důkazu | Co musí nový vykonavatel udělat |
| --- | --- | --- |
| `rg-calltype-beta`, West Europe; `asp-calltype-beta`, B1; API `calltype-beta-zahy`; SWA `calltype-beta-web`; storage `calltypebetazahy` | Záznam z 2026-09-14 v `docs/azure-beta-plan.md` | Read-only inventura, potvrdit subscription, názvy, region a aktuální vlastnosti |
| TLS 1.3 k PostgreSQL, `SSL Mode=Require`, tři aplikované migrace | Historicky zaznamenané | Ověřit skutečnou verzi, tabulku migrací, připojení a validaci certifikátu |
| Coturn UDP/TCP přenesl 10 zpráv v každém testu | Historicky zaznamenané | Zopakovat protokolový test a odděleně provést skutečné audio/video s forced relay |
| 0,018 USD/h a 13,14 USD za 730 hodin Linux B1; odhad celku 14-16 USD před daní | Historický cenový snímek, není dnešní nabídka | Znovu ocenit konkrétní region, měnu, daň, délku měsíce a zbytek provozu |
| `deploy.yml` staví image do ACR a nasazuje Container Apps | Přečten aktuální lokální soubor | R01 nahradí nesoulad s App Service; do té doby workflow nepoužít pro tuto betu |
| `ci.yml` dovoluje fallback `API_BASE_URL` na localhost | Přečten aktuální lokální soubor | R01 zablokuje distribuci bety s lokální adresou |

Samotné HTTP 200 na `/health` nedokazuje obnovitelnost databáze, fungující SignalR, privátní Blob ani kvalitu hovorů. Záznam musí uvádět datum, commit aplikace, prostředí, nástroj/verzi, očekávaný a skutečný výsledek. Stav bez provedeného testu zapisovat `NOT_RUN`, nikoli `PASS`.

## Rozdělení souborů a paralelní práce

Všechny níže označené nové soubory jsou výstupy budoucí implementace. Tento plán je sám nevytváří.

| Balíček | Výhradně vlastněné soubory | Závislosti pro dokončení |
| --- | --- | --- |
| I01 | `infra/beta-appservice.bicep`, `infra/beta-appservice.parameters.example.json`, `docs/ops/beta-inventory.md`, `docs/ops/beta-infrastructure.md`, `docs/ops/evidence/I01.md` | B00 zmrazí konfigurační kontrakt; operátor dodá inventuru |
| I02 | `infra/postgres/README.md`, `infra/postgres/pg_hba.conf.example`, `docs/ops/postgres-restore.md`, `docs/ops/evidence/I02.md` | Přístup správce DB, certifikáty; B00 převezme změnu konfigurace aplikace |
| I03 | `infra/coturn/turnserver.conf.example`, `docs/ops/turn-validation.md`, `docs/ops/evidence/I03.md` | Inventura I01, přístup správce TURN, předběžné smluvní limity poskytovatele, D04 pro forced relay |
| I04 | `docs/ops/beta-cost-model.md`, `docs/ops/beta-operations.md`, `docs/ops/evidence/I04.md` | Inventura I01, výsledky I02/I03 a aplikační vynucování limitů přes B00 |

Po B00 lze I01 a lokální návrhy I02/I03/I04 připravovat paralelně; provozní kroky I02/I03 čekají na inventuru I01. I03 měří v rámci předběžně potvrzených limitů poskytovatele a nečeká na finální I04, čímž nevzniká kruhová závislost. I04 finalizuje čísla až po inventuře a měření I03. Každý pracovník mění jen své soubory. Změnu externího serveru pro DB a TURN provádí jeden operátor po sobě, aby restart nebo firewall nezkreslil testy druhého balíčku. R01 dostává výstupy I01 a I02; neupravuje infrastrukturu mimo svůj dohodnutý rozsah.

## I01: Inventura a reprodukovatelné IaC

**Výsledek:** Nová šablona popisuje schválenou topologii a její opakované použití nesmaže data ani nepřepíše tajemství. Nejde o migraci na jiný hosting.

**Vstupy blokující zásah:** subscription a tenant, práva read/deploy, potvrzený resource group, skutečná regionální dostupnost runtime, seznam existujících app settings z bezpečného inventáře bez jejich hodnot, vlastník tajemství. Bez těchto vstupů lze dodat lokální šablonu a dokumentaci, nelze označit Azure what-if nebo deployment za ověřený.

**Rozhraní:** Přijímá existující názvy prostředků a konfigurační kontrakt od B00. Předává R01 názvy App Service/SWA, region, runtime, veřejné URL, příkaz publikace .NET, pravidlo práce s tajemstvími a kontrolu jedné instance. Názvy `ConnectionStrings__DefaultConnection`, `ConnectionStrings__BlobStorage`, `Jwt__Secret`, `Turn__SharedSecret`, `Turn__TtlSeconds`, `Cors__AllowedOrigins__0` odpovídají ASP.NET konfiguraci; jejich skutečné hodnoty se předávají bezpečnou cestou. `Proxy__KnownProxy` měnit pouze po ověření proxy řetězce s B00, nikdy nenastavovat důvěru libovolnému proxy.

- [ ] Přečíst `docs/azure-beta-plan.md`, `docs/beta-status.md`, `infra/main.bicep` a `infra/beta-vm.bicep`; do inventury zapsat, že poslední dvě šablony nemají být nasazeny.
- [ ] Read-only příkazem `az account show --query '{subscription:id,tenant:tenantId}'` ověřit cíl. Do veřejného důkazu stačí potvrzení shody, není nutné publikovat identifikátory účtu.
- [ ] Použít `az resource list --resource-group rg-calltype-beta --query '[].{name:name,type:type,location:location}' -o table`; následně read-only ověřit plan SKU, Linux, počet workerů, web runtime, HTTPS, TLS, WebSockets, Always On, vypnuté FTP, privátnost storage a Free SKU SWA. Neexportovat kompletní konfiguraci do logu.
- [ ] Přečíst aktuální outbound i possible outbound IP aplikace. Se správcem DB porovnat firewall. Nepřebírat historický seznam IP jako trvalou garanci.
- [ ] V `infra/beta-appservice.bicep` definovat pouze plan, web app, SWA a privátní storage cílové topologie. Fixovat Linux B1 a capacity 1; nepřidávat autoscale. Public Blob access zakázat, vyžadovat HTTPS a nejméně TLS 1.2. Výstupy smějí obsahovat URL a resource IDs, nikdy klíče.
- [ ] Oddělit provisionování prostředků od změn app settings. U existující aplikace šablona nesmí nasadit prázdnou kolekci app settings a smazat tajemství. Pokud Azure API při změně konfigurace nahrazuje celou kolekci, dokumentovat tento fakt a konfiguraci předat samostatnému kroku R01 se zachováním všech potřebných nastavení.
- [ ] V example parameters uvést pouze nesekretní hodnoty. Pro novou instalaci runbook vyžaduje bezpečné doplnění tajemství před prvním startem; nikdy nezavádět výchozí produkční heslo.
- [ ] V `docs/ops/beta-infrastructure.md` popsat dvě cesty: převzetí existujícího prostředí a instalaci od nuly v předem povoleném cíli. Neprovádět test nové placené instalace bez potřebného souhlasu s konkrétním nákladem.
- [ ] Spustit `az bicep build --file infra/beta-appservice.bicep --outfile "$env:TEMP/calltype-beta-template.json"`. Očekávat exit 0; kontrolovat typy prostředků a nepřítomnost tajemství ve výstupech.
- [ ] S potvrzenými parametry provést `az deployment group what-if --resource-group rg-calltype-beta --template-file infra/beta-appservice.bicep --parameters @infra/beta-appservice.parameters.example.json`. Neprovádět `create` jako součást validace. Vysvětlit každý rozdíl; nejasný destruktivní diff znamená zastavení nasazení.
- [ ] Předat R01 požadavek na Bicep build a kontrolu infra cest v CI, aby změna `infra/**` neminula kontroly. Vlastník I01 workflow sám neupravuje.
- [ ] Uložit redigovaný diff a výsledky do `docs/ops/evidence/I01.md`; zapsat omezení what-if, protože nejde o důkaz runtime funkčnosti.

**Akceptace a negativní scénáře:** Lokální build projde; what-if nenavrhuje zrušení DB/storage, druhou instanci, změnu hostingu ani smazání app settings. Neautorizovaný anonymní přístup k existujícímu testovacímu Blob objektu selže bez úniku obsahu. Neznámý CORS origin není povolen; přesný veřejný origin funguje i pro SignalR. Po povoleném nasazení fungují `/health` a WebSocket spojení, opakovaný what-if nevykazuje neodůvodněné změny. Bez skutečného nasazení zůstává poslední podmínka `NOT_RUN`.

**Rollback:** Uchovat předchozí nesekretní konfiguraci a bezpečný snapshot tajemství mimo repo. Vrátit jednotlivou změněnou vlastnost, případně aplikační artifact přes R01. Nepoužívat delete resource group ani complete deployment mode; rollback šablony není obnova dat. Při restartu přiznat přerušení aktivních hovorů a ověřit reconnect fronty zpráv.

## I02: PostgreSQL TLS, zálohy a ověřená obnova

**Výsledek:** API ověřuje identitu DB serveru a operátor dokáže obnovit databázi do izolovaného cíle bez zásahu do běžící bety.

**Vstupy blokující zásah:** Verze serveru a Npgsql, administrátorský přístup, certifikát s odpovídajícím DNS jménem nebo IP SAN, řetězec důvěry dostupný aplikaci, kapacita izolované testovací DB, úložiště záloh a držitel dešifrovacího klíče. Doména se nekupuje automaticky; lze využít existující jméno nebo řádný IP SAN. Bez splnitelné identity certifikátu nepřepnout konfiguraci naslepo.

**Rozhraní:** Přijímá DB endpoint a bezpečně dodané credentials. Dodává B00/R01 schválenou změnu connection stringu na ověřování plného jména serveru, cestu důvěryhodného CA a postup rotace. `SSL Mode=Require` není úspěch tohoto balíčku; přesná syntaxe `VerifyFull` a root certificate se ověří proti skutečné verzi Npgsql před zásahem.

- [ ] Zapsat skutečnou verzi PostgreSQL, velikost DB, způsob provozu, správce, firewall a počty migrací. Nezaměňovat úspěšný TCP connect s úspěšnou DB autentizací.
- [ ] V `infra/postgres/pg_hba.conf.example` popsat `hostssl` pravidla omezená na aplikační databázi, její účet a povolené zdroje. Nepřidávat veřejné `0.0.0.0/0` nebo `trust`; administrativní přístup řešit odděleně.
- [ ] Přípravou testovacího připojení ze stejného prostředí jako API ověřit správný certifikát, hostname a CA. Npgsql musí odmítnout chybný hostname i nedůvěryhodný CA. Testovat pomocí izolovaných připojení, ne výměnou certifikátu živé DB za chybný.
- [ ] V runbooku rozepsat vydání/instalaci certifikátu, obnovu před expirací, synchronizaci času a ověření po rotaci. Soukromý klíč zůstává na serveru s omezenými právy.
- [ ] Dohodnout s B00 oddělení aplikačního účtu od účtu pro migrace; doložit nutná oprávnění, neudělovat aplikaci superuser. Změnu privilegii nejdříve ověřit na obnovené kopii.
- [ ] Jako návrh stanovit denní zálohu, 7 denních kopií, RPO 24 hodin a RTO 2 hodiny. Operátor potvrdí nebo zpřísní hodnoty podle velikosti DB a rozpočtu; dokud chybí úspěšný restore s naměřeným časem, RTO není slíbeno.
- [ ] Připravit `pg_dump --format=custom` pomocí klienta kompatibilního s verzí serveru. Heslo číst z chráněného credential souboru s omezenými právy, ne z příkazové řádky nebo historie shellu. Zálohu šifrovat a ukládat mimo disk původní DB podle potvrzeného rozpočtu.
- [ ] V `docs/ops/postgres-restore.md` rozlišit PostgreSQL provozní zálohu od uživatelského šifrovaného exportu historie do Blob. Jedna nenahrazuje druhou.
- [ ] Na existujícím povoleném testovacím cíli vytvořit izolovanou databázi. Obnovit `pg_restore --exit-on-error --no-owner` s explicitním cílem; nepoužít `--clean` na živou DB. Dump produkčních dat považovat za citlivý i při šifrovaném obsahu zpráv, protože obsahuje metadata a přihlašovací údaje v uložené podobě.
- [ ] Porovnat schéma a migration history s originálem. Pro vlastní syntetická data ověřit offline zprávu před ACK a její nepřehrání po ACK, vlastnictví záloh, vazby zařízení a skupin. Testovací aplikaci izolovat od push, skutečných uživatelů a produkčních Blob zápisů.
- [ ] Změřit délku dumpu a obnovy, ověřit čitelnost nezávisle získaným klíčem. Uložit pouze souhrn bez obsahu dat do `docs/ops/evidence/I02.md`.
- [ ] Předat R01 checkpoint zálohy před migracemi a postup kompatibilního rollbacku. Startup migrace nezapínat bez koordinace s B00.

**Akceptace a negativní scénáře:** Ověřené TLS spojení funguje z API; špatné jméno, chybějící důvěryhodná CA a neplatné credentials selžou. Odmítnutí nesmí automaticky spustit fallback na `Require`. Obnova projde do izolovaného cíle, podmínky RPO/RTO jsou potvrzené a změřené; poškozený dump vrátí chybu a nesmí být označen jako obnovený. Výpadek DB nesmí přimět aplikaci potvrdit trvalé uložení nedoručené zprávy, tento scénář koordinovat s B00 na testovací instanci.

**Rollback:** Před TLS změnou ověřit fungující původní konfiguraci a servisní okno. Preferovat opravu CA/jména; případný dočasný návrat k historickému `Require` označit jako bezpečnostní regresi s vlastníkem a termínem nápravy, balíček zůstává nesplněný. Při chybě migrace neprovádět slepý downgrade DB. R01 vrátí jen kompatibilní aplikaci; obnova produkční DB vyžaduje samostatný výběr bodu obnovy a vyhodnocení ztráty novějších dat.

## I03: TURN bezpečnost, kapacita a skutečné forced-relay hovory

**Výsledek:** Coturn je autentizovaný, omezený proti zneužití a existuje důkaz skutečného obousměrného média přes relay mezi dvěma sítěmi.

**Vstupy blokující zásah:** Verze a provozní způsob coturn, správce serveru, veřejná IP/NAT, firewall listener a relay portů, poskytovatelův zahrnutý traffic a podmínky překročení, dostupné dvě sítě a dvě cílová zařízení, klientský testovací přepínač forced relay. TURN TLS navíc vyžaduje certifikát a volný port; veřejný HTTPS port nelze předpokládat volný.

**Rozhraní:** Využívá stávající krátkodobé credentials vydávané API. Historický TTL je 3600 sekund; změnu TTL koordinovat s B00. Klientský pracovník dodá testovací režim WebRTC `iceTransportPolicy: relay` a export souhrnu selected candidate pair bez credentials. I03 neposouvá produkční klienty natrvalo do forced relay.

- [ ] Inventarizovat listener UDP/TCP, rozsah relay portů, NAT mapování, service manager, CPU/RAM, disk logů a čas serveru. Zjistit, zda coturn sdílí server s DB a jak zabránit vytlačení DB při zátěži.
- [ ] V `infra/coturn/turnserver.conf.example` definovat autentizaci, explicitní realm, vypnutý veřejný management, omezený relay port range, omezení allocations a ochranu cílových adres podle skutečné verze coturn. Secret pouze bezpečným runtime vstupem, žádná funkční hodnota v example souboru.
- [ ] Zakázat přístup relay k loopback, interním/private/link-local a metadata adresám pro IPv4 i IPv6; zahrnout skutečně routované interní subnety. Testovat ochranu na vlastních kontrolovaných cílech, ne skenováním cizích sítí. Nezaměňovat omezení klientských zdrojů s omezením peer cílů.
- [ ] Nejdříve potvrdit plánovací rozsah 2 současných obousměrných audio/video hovorů. Počet TURN allocations nemusí být roven počtu uživatelů; z měření odvodit `user-quota`, `total-quota` a propustnost. Neopisovat kvótu do produkce bez ověření jednotek a chování konkrétní verze.
- [ ] Pro kapacitu počítat odděleně ingress a egress. Pokud každý ze dvou účastníků posílá 1 Mbit/s, přibližný egress relaye je 2 Mbit/s, tedy 0,9 GB za hodinu hovoru v desetinných jednotkách bez protokolové režie. Je-li účtován ingress i egress, objem se přibližně zdvojnásobí. Skutečné kodeky, overhead a účetní metriku změřit.
- [ ] Ověřit anonymní allocation, špatné credentials a expirované credentials: nové allocations musí být odmítnuty. Samostatně popsat chování již existující allocation po expiraci credential a při obnově, nepředpokládat okamžité ukončení média.
- [ ] Zopakovat autentizovaný UDP a TCP relay test a uvést skutečný počet odeslaných/přijatých datagramů a ztráty. TCP listener není sám o sobě důkaz funkčního TURN TLS.
- [ ] S klientským pracovníkem uskutečnit 10minutový audio a 10minutový video hovor přes forced relay na dvou odlišných sítích. Potvrdit `relay` ve selected candidate pair a růst sent/received media bytes v obou směrech; pouhé SDP nebo spojení SignalR nestačí.
- [ ] Změřit dobu sestavení, RTT, jitter, packet loss, CPU/RAM a traffic. Pro plánovací profil navrhnout sestavení do 10 sekund a žádné samovolné ukončení během testu; hranice kvality podle cílové sítě potvrdit před vyhodnocením. Pokud navržený profil selže, uvést výsledek jako fail, ne snížit mez zpětně.
- [ ] V izolovaném testu dosáhnout allocation kvóty. Nový pokus má srozumitelně selhat, existující hovory ani DB se nesmějí zhroutit. Po uvolnění allocation musí nový hovor znovu projít.
- [ ] Ověřit síť s blokovaným UDP a odpovídající fallback; chybějící TURN TLS výslovně označit jako neověřenou podporu restriktivních sítí. Není dovoleno nahradit chybějící důkaz slibem univerzální konektivity.
- [ ] Zapsat výsledky do `docs/ops/evidence/I03.md`, včetně platforem, verzí, sítí, časů a omezení; poskytovatelův traffic limit předat I04.

**Akceptace a negativní scénáře:** Oba směry média skutečně používají relay a projdou dohodnutým profilem. Interní peer cíle, anonymní a expirované nové allocations jsou odmítnuty. Po restartu coturn je dopad na aktivní hovory popsán a nový hovor projde. Nedostupný TURN nezpůsobí nekonečný spinner klienta ani blokaci zpráv, ověří klientský pracovník. Protokolový smoke samotný neopravňuje uzavřít I03 jako hotový.

**Rollback:** Bezpečně uložit původní konfiguraci, verzi a firewall pravidla. Změnu aplikovat s možností zachovat administrativní přístup. Při regresi vrátit konkrétní nastavení a restartovat službu v servisním okně, přiznat přerušení hovorů. Nevracet relay do anonymního režimu a neotevírat veškeré interní cíle. Rotaci společného secret koordinovat s API a expirací credentials, aby obě strany používaly stejnou konfiguraci.

## I04: Rozpočet, limity a provozní dohled

**Výsledek:** Operátor ví, co stojí provoz, co se děje při dosažení limitu, jak rozpoznat výpadek a jak obnovit službu. Výstup neslibuje garantovaný cenový strop bez účinného mechanismu a ověřených podmínek účtování.

**Vstupy blokující závazek k ceně:** Zda 20 USD zahrnuje daň a existující server, měna fakturace, ceny B1/storage/operací/egress, rozsah zahrnutého provozu externího serveru, aktivní beta uživatelé a očekávané hodiny videa. Chybějící údaj je pojmenovaný blocker v cost modelu, nikoli automatická nula.

**Rozhraní:** Přijímá inventuru I01 a měření I03. B00 obdrží požadavky na aplikační kvóty a chování při jejich dosažení podle sdílených kontraktů. I04 nepřidává vlastní API statusy nebo duplicitní konfiguraci do zdrojového kódu. Provozní dohled může využít existující bezplatné možnosti a lokální omezené logy; případná placená služba není výchozí volba.

- [ ] Do `docs/ops/beta-cost-model.md` zapsat datum cen, zdroj, SKU, region, měnu, daň a tarif externího serveru. Před budoucím nasazením ověřit aktuální primární ceníky; historické číslo 13,14 USD použít jen jako historický příklad.
- [ ] Vypočítat `B1 hodinová cena × skutečné hodiny měsíce + Blob GB-měsíc + operace + Azure outbound + přírůstek externího serveru/traffic + daň`. Zahrnout 744hodinový měsíc; počet 730 je jen normalizační příklad.
- [ ] Pro měsíční traffic uvést počet audio/video hodin, naměřený egress za hodinu z I03 a účetní režii. Pokud server nemá potvrzenou zahrnutou kapacitu, nezapisovat jeho cenu jako nulu.
- [ ] Převzít jediný návrh limitů K03: 3 zálohy na účet, nejvýše 8 MiB šifrovaného souboru a globálně 256 MiB včetně rezervací. Pro 20 plánovaných účtů by plné využití vyžadovalo `20 × 3 × 8 = 480 MiB`, tedy více než globální limit. Globální limit proto může odmítnout upload dříve než limit účtu; neslibovat všem účtům tři maximálně velké zálohy. Číslo 20 je pouze modelovací scénář, nikoli vynucený limit registrací. DB, metadata, provozní zálohy a operace ocenit samostatně. Kvóty implementuje D02 přes B00; I04 nesmí zavést druhou sadu hodnot.
- [ ] Rozlišit byte limit payloadu od limitu multipart HTTP requestu; existující Kestrel limit 10 MiB není per-account ani globální storage kvóta. Retence DB zpráv 30 dní není pravidlo pro mazání uživatelských Blob záloh.
- [ ] Dohodnout retenci, evidenci celkových uložených bajtů a pravidlo započítání souběžných uploadů. Limit musí odmítnout nový zápis bez smazání poslední platné zálohy; samostatně testovat dva uploady soutěžící o poslední dostupnou kapacitu. Mechanismus implementuje backend vlastník, I04 přebírá důkaz.
- [ ] Pro TURN převzít allocation a bandwidth limity I03 a stanovit měsíční traffic limit podle smlouvy serveru. Předem definovat, zda po vyčerpání blokovat nové relayed hovory; informovat klientský tým o očekávaném stavu. Denní měření není tvrdé vynucení měsíčního limitu.
- [ ] Ověřit aktuální kvóty a chování SWA Free při vyčerpání. Historický údaj 100 GB nelze bez potvrzení období a podmínek považovat za aktuální garanci.
- [ ] Navrhnout upozornění na 50 %, 80 % a 100 % z potvrzeného měsíčního rozpočtu. Uvést zpoždění účtování, adresáta a konkrétní zásah, ale označit, že upozornění nezastavuje výdaje.
- [ ] V `docs/ops/beta-operations.md` popsat kontrolu API, veřejného webu, poslední úspěšné zálohy, expirace DB/TURN certifikátů, DB disku, TURN trafficu a omezených logů. Pro návrh použít kontrolu HTTP po 5 minutách a zásah po 3 po sobě jdoucích selháních; potvrdit odpovědného operátora a dostupnost mechanismu.
- [ ] Logy omezit velikostí a retencí; redigovat autorizaci, query tokens SignalR, connection strings, text zpráv a TURN credentials. Výpadek logování nesmí shodit API. Ověřit, že běžné error logy netisknou secrets.
- [ ] Doplnit postupy pro restart API, nedostupnou DB, plný DB disk, výpadek Blob, vyčerpaný TURN traffic, expirovaný certifikát a nedostupného operátora. Každý postup má detekci, diagnostický read-only krok, povolenou nápravu, rollback a potvrzení obnovení služby.
- [ ] U rozpočtového incidentu výslovně vysvětlit, že zastavení web app nezruší účtování existujícího App Service plánu. Rušení plánu nebo prostředků s daty není automatická náprava; vyžaduje samostatné rozhodnutí po vyhodnocení ztráty služby a dat.
- [ ] Provést řízené testy alertů a limitů na izolovaném cíli bez generování velkého účtu. Do `docs/ops/evidence/I04.md` zapsat čas detekce, příjem upozornění, zásah a čas obnovy.

**Akceptace a negativní scénáře:** Existuje datovaný výpočet nákladů se všemi známými položkami, vlastník každého limitu a důkaz jeho vynucení. Dva souběžné uploady nepřekročí poslední dostupnou kvótu. Vyčerpaný limit odmítne novou spotřebu před vznikem nákladu tam, kde to lze řídit; neřiditelné položky jsou výslovně uvedeny. Simulovaná ztráta DB/TURN a zastaralá záloha vyvolá detekci a předepsaný zásah. Dostupný `/health` při vadné záloze nesmí uzavřít incident obnovitelnosti. Bez ověření poskytovatelských cen a limitů nelze prohlásit rozpočet za splněný.

**Rollback:** Alert threshold a monitoring konfiguraci lze vrátit na poslední ověřenou hodnotu. Kvóty uvolnit jen po vyhodnocení rozpočtu a potvrzení vlastníkem; při chybě nového kvótového mechanismu preferovat dočasné odmítnutí nových nákladových operací před nekontrolovanou spotřebou. Existující zprávy, zálohy a databázi automaticky nemazat.

## Předání R01 a závěrečný důkaz

I01 předá topologii, nesekretní parametry, postup what-if, konfiguraci runtime a požadavek zachovat app settings. I02 předá ověřené DB TLS a checkpoint zálohy/migrace. I03 předá platné TURN URL, TTL a ověřené transporty. I04 předá provozní gate a případné blokující cenové údaje. Samotný CI/CD soubor upravuje R01.

Při závěrečném reportu pro každý balíček uvést status podle K06 (`PASS`, `FAIL`, `BLOCKED`, `NOT_RUN` nebo `UNSUPPORTED`), odkaz na diff a důkaz. Neověřený externí krok nelze nahradit tvrzením o úspěchu z historického plánu. Pokud chybí přístup, kapacita testovacího cíle, certifikát nebo údaje o účtování, dokončit dostupné lokální artefakty a vypsat přesný chybějící vstup a odpovědného vlastníka. Žádný balíček nezvyšuje počet App Service instancí, nepřesouvá DB a nemění architekturu jen proto, aby obešel neúspěšný test.

