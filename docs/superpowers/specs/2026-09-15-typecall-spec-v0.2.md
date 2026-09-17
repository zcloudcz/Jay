# TypeCall — technická a produktová specifikace

**Verze:** 0.2 (draft)
**Datum:** 15. 9. 2026
**Autor:** Zahy (GROWELL)
**Status:** Koncept k validaci

> **Změny oproti 0.1:** Opraven regulatorní argument (E2EE není univerzální povinnost — viz 2.2). Nouzová komunikace povýšena na hlavní vstupní bod (2.3). Zúžena primární cílovka (2.5). Přidána správa klíčů, cryptographic baseline a doložitelnost jako produktové funkce (2.7–2.9).

---

## 1. Shrnutí

Šifrovaný komunikátor postavený na MLS (RFC 9420) se **třemi profily konverzace nad jednou kódovou bází** (viz kap. 2.6):

- **Denní firemní provoz** — E2E, firemní identita (SSO/SCIM), transparentní auditní člen, retence dle politiky.
- **Nouzový režim** — oddělený kanál nezávislý na infrastruktuře organizace, použitelný při kompromitaci M365/SSO/e-mailu.
- **Consumer** — bez registrace, lokální keypair, server neukládá doručená data, velké přílohy, bot API.

**Pozicování:** Doložitelně bezpečná firemní komunikace pro subjekty pod ZoKB/NIS2 — včetně nouzového kanálu, který zákon vyžaduje a pro který dnes neexistuje mainstreamový produkt. Hostováno v ČR, později self-hosted. Nasazení za den, ne za měsíc.

---

## 2. Proč to dělat

### 2.1 Tržní situace

Všichni existující hráči mají stejnou vadu — umí dvě ze tří věcí, nikdy všechny tři:

| Hráč | Anonymita / UX | Enterprise features | Self-hosting |
|---|---|---|---|
| Signal | ✅ (ale vyžaduje tel. číslo) | ❌ | ❌ |
| Threema Work | ✅ | ⚠️ chybí SSO, SCIM, federace | ⚠️ částečně |
| Wire | ⚠️ | ✅ | ⚠️ jen enterprise |
| Element / Matrix | ⚠️ | ⚠️ | ✅ (ale náročné) |
| Rocket.Chat / Mattermost | ❌ | ✅ | ✅ |

A žádný z nich neřeší nouzovou komunikaci jako produktovou funkci.

### 2.2 Regulatorní rámec — přesné znění

**Pozor na časté zkreslení:** Tvrzení „NIS2 nařizuje firmám E2E šifrovaný messenger" je nepřesné a při jednání s informovaným compliance manažerem poškodí důvěryhodnost. Pitch musí stát na tom, co zákon skutečně říká.

Právní základ:
- Směrnice (EU) 2022/2555 (NIS2) — čl. 21 odst. 2 písm. h): pravidla a postupy pro používání kryptografie a případně šifrování, **„podle potřeby"**.
- Zákon č. 264/2025 Sb. (ZoKB), účinný od 1. 11. 2025 — § 13, § 14.
- Vyhláška č. 408/2025 Sb. (regulované služby), č. 409/2025 Sb. (vyšší režim), č. 410/2025 Sb. (nižší režim).
- Prováděcí nařízení Komise (EU) 2024/2690 — přímo použitelné pro vybrané digitální poskytovatele, výrazně konkrétnější (bod 9 přílohy).

**Co zákon skutečně vyžaduje:**

| Požadavek | Zdroj |
|---|---|
| Kryptografická politika a postupy, doložitelné | NIS2 čl. 21/2h; nařízení 2024/2690 bod 9 |
| Důvěrnost a integrita přenášených dat odolnými algoritmy | vyhl. 409/2025 § 18 písm. g) |
| Bezpečná hlasová, obrazová, textová a e-mailová komunikace | vyhl. 409/2025 § 25 odst. 2; vyhl. 410/2025 § 13 |
| **Bezpečná nouzová komunikace uvnitř organizace** | vyhl. 409/2025 § 25 odst. 2; vyhl. 410/2025 § 13 |
| Aktuálně odolné algoritmy dle doporučení NÚKIB | vyhl. 409/2025 § 25; vyhl. 410/2025 § 13 |
| Řízení životního cyklu klíčů a certifikátů, kontrola a audit správy klíčů | vyhl. 409/2025 § 25 |
| Šifrování záloh | vyhl. 409/2025 § 26 odst. 3 písm. c) |

**Co zákon nevyžaduje:** E2EE jako univerzální povinnost. „Bezpečná komunikace" je širší pojem — zahrnuje šifrování přenosu, ověření identity, řízení přístupu, auditní záznamy, retenci a případně E2EE tam, kde to odůvodní riziková analýza.

**Kde NIS2 E2EE naopak výslovně podporuje:** Bod 98 odůvodnění — u veřejných elektronických komunikačních služeb má být používání E2EE podporováno a kde nezbytné i povinné, přičemž zákonný přístup orgánů nemá E2EE oslabovat. Užitečný argument proti požadavkům na backdoor, ale odůvodnění směrnice není totéž co konkrétní povinnost.

**Důsledek pro pozicování:** Prodejním argumentem není E2EE. Prodejním argumentem je **doložitelnost, řízení klíčů a nouzový kanál** — tedy věci, které zákon vyžaduje a firmy je dnes nemají čím splnit.

### 2.3 Nouzová komunikace — hlavní vstupní bod

**Nejméně obsazená povinnost v celé regulaci.** Obě vyhlášky ji vyžadují výslovně, a neexistuje pro ni mainstreamový produkt.

Scénář, který si zákazník okamžitě představí:

1. Organizaci padne nebo je kompromitován M365 tenant.
2. Teams je nedostupný. E-mail je nedostupný. SSO je nedostupné — a možná mu nelze věřit.
3. Incident response tým se potřebuje domluvit okamžitě, mimo kompromitovanou infrastrukturu.
4. Dnešní praxe: soukromá WhatsApp skupina → přesně to, co auditor vytkne.

**Proč to sedí na původní produktové zadání:**

| Původní záměr | V nouzovém režimu se mění na |
|---|---|
| Bez registrace | Nezávislost na firemním SSO — jinak nouzový kanál padá spolu s ním |
| Server bez přístupu k obsahu | V incident režimu nevíš, čemu můžeš věřit |
| Vlastní infrastruktura | Celý smysl odděleného kanálu |

Consumer feature se tím mění na regulatorní požadavek. To je nejsilnější věc v celém konceptu.

**Go-to-market důsledek:** Nouzový kanál je levný vstup do firmy (malý rozsah, jasná povinnost, nízká cena), z něhož lze expandovat na denní provoz. Není nutné hned nahrazovat Teams.

### 2.4 Prázdný střední segment

Firma v režimu nižších povinností:
- Nemá rozpočet na Wire Enterprise.
- Nemá IT tým na provoz Matrix federace.
- Dnes typicky používá WhatsApp a doufá, že to nikdo nebude kontrolovat.

**Pozor na kritérium:** Neplatí jednoduché pravidlo „NIS2 = každá firma nad 50 zaměstnanců". Zařazení se určuje podle druhu regulované služby, velikosti a kritérií vyhlášky č. 408/2025 Sb. Při cílení je nutné pracovat se seznamem druhů služeb, ne s počtem zaměstnanců.

### 2.5 Primární cílová skupina

Zúženo podle vymahatelnosti požadavků:

| Priorita | Segment | Proč |
|---|---|---|
| **1** | Digitální poskytovatelé pod nařízením 2024/2690 (cloud, datová centra, CDN, DNS, MSP, MSSP, on-line tržiště, sociální sítě, služby vytvářející důvěru) | Přímo použitelné nařízení, konkrétní požadavky na kryptografickou politiku a životní cyklus klíčů. Nejméně prostoru pro „to nějak vyřešíme dokumentem". |
| **2** | Režim vyšších povinností | § 25 vyhl. 409/2025 vyžaduje nástroj pro řízení životního cyklu klíčů a auditovatelnost — to je produkt, ne směrnice |
| **3** | Režim nižších povinností | Nižší detail požadavků, ale povinnost trvá; větší objem, nižší cena |

### 2.6 Jedna aplikace, tři profily

Ne tři produkty. Jedna MLS implementace, kde se profily liší **pouze politikou a složením skupiny**:

| | Denní provoz | Nouzový režim | Consumer |
|---|---|---|---|
| **Identita** | Firemní SSO / SCIM | Předem vydaný offline klíč + recovery kód | Lokální keypair, bez registrace |
| **Auditní člen** | Ano | Ano, s odloženou synchronizací | Ne |
| **Retence** | Dle politiky organizace | Dle politiky organizace | TTL, mazání po doručení |
| **Závislost na infrastruktuře zákazníka** | Ano | **Žádná** | Žádná |
| **Distribuce klíčů** | Directory Service | Offline, předem (enrollment balíček) | Peer-to-peer |

Technicky jde stále o jedno jádro — mění se složení MLS skupiny a politika, ne protokol.

### 2.7 Rozšíření auditní vrstvy: správa klíčů a certifikátů

Vyhláška 409/2025 § 25 vyžaduje nástroj pro řízení životního cyklu klíčů a certifikátů, zajištění jejich důvěrnosti a integrity a **možnost kontroly a auditu správy klíčů**. Většina firem to dnes řeší tabulkou.

Produkt to může pokrýt nativně:
- Inventář klíčů a certifikátů s odpovědnou osobou
- Rotace, revokace, reakce na kompromitaci — jako workflow, ne jako dokument
- Logování a audit všech operací s klíči
- Alerty před expirací

To je přímý přenos logiky z GIRS (evidence, lhůty, odpovědnosti, auditní stopa) do jiné domény.

### 2.8 Cryptographic baseline jako feature

Zákon vyžaduje používání aktuálně odolných algoritmů a zohlednění doporučení NÚKIB (dokument *Minimální požadavky na kryptografické algoritmy*, aktualizace 2025 — vyřazení dosluhujících algoritmů, finální postkvantové standardy NIST, KMAC a GMAC, parametry pro ukládání hesel).

Produktová podoba: **politika se nekonfiguruje v dokumentu, ale v aplikaci, a aplikace ji vynucuje.**

- Předvyplněná baseline dle aktuálního doporučení NÚKIB
- Verzování politiky s datem účinnosti
- Export politiky a její konfigurace jako doklad pro kontrolu
- Notifikace při změně doporučení NÚKIB

Tohle je diferenciátor, který žádný existující messenger nemá — protože žádný z nich není postavený pro český regulatorní kontext.

### 2.9 Doložitelnost jako produkt

Sankce: až 250 mil. Kč nebo 2 % čistého celosvětového ročního obratu (§ 59 ZoKB), případně 175 mil. Kč nebo 1,4 %; rozhoduje vyšší částka. **Nejde o pokutu za jednotlivý nezašifrovaný e-mail**, ale za nezavedení nebo neprovádění bezpečnostních opatření.

Z toho plyne klíčový insight: **postihuje se nedoložitelnost, ne technický detail.** Compliance se musí dát prokázat — nestačí mít fakticky zapnuté TLS.

Co tedy produkt musí umět vyexportovat:
- Hodnocení a klasifikaci komunikačních kanálů
- Platnou kryptografickou politiku a její historii
- Konfiguraci, výjimky a jejich schválení
- Evidenci klíčů a certifikátů včetně revizí
- Auditní stopu komunikace v požadovaném rozsahu
- Doklad o existenci a funkčnosti nouzového kanálu

### 2.10 Vlastní výhoda

Doménová znalost compliance, evidence a reportingu z GIRS. Žádný z existujících hráčů neumí vygenerovat doklad použitelný při kontrole NÚKIB — a všichni jsou ze Švýcarska, UK nebo USA, tedy bez vazby na český regulatorní kontext.

### 2.11 Vztah ke GDPR

GDPR se u osobních údajů uplatní souběžně. Čl. 32 uvádí šifrování a pseudonymizaci mezi příklady vhodných opatření, opět bez univerzální povinnosti.

Rozdíl v chráněném zájmu:
- ZoKB/NIS2 chrání regulovanou službu a její aktiva
- GDPR chrání osobní údaje a práva fyzických osob

Jeden incident může zakládat povinnosti vůči NÚKIB i ÚOOÚ současně. **Produktová příležitost:** jeden auditní export použitelný pro obě řízení.

---

## 3. Architektonický princip

> **Server je slepý v obou režimech.** Auditor není backdoor na serveru, ale kryptograficky viditelný účastník konverzace.

Z toho plyne:
- Server nikdy nedrží dešifrovací klíče.
- Auditní přístup je viditelný v seznamu členů skupiny — žádná skrytá strana.
- Consumer a business režim sdílí 100 % kryptografického jádra; liší se pouze složením skupiny.

Tohle je zásadní i právně: skrytý odposlech je nelegální, transparentní archivace se souhlasem zaměstnance je standardní firemní praxe.

---

## 4. Volba protokolu: MLS (RFC 9420)

### 4.1 Proč ne Signal Protocol / Double Ratchet

| Kritérium | Signal Protocol | MLS |
|---|---|---|
| Skupinové šifrování | N párových kanálů, O(n²) | Strom klíčů, O(log n) |
| Přidání člena | Ad-hoc, mimo protokol | Nativní operace protokolu |
| Standardizace | De facto standard | IETF RFC 9420 |
| Post-compromise security | ✅ | ✅ |
| Vhodné pro auditního člena | ❌ obtížné | ✅ přirozené |

### 4.2 Proč MLS vyhrává

- Auditor je prostě další člen skupiny — nevyžaduje to žádnou úpravu protokolu.
- Skupiny o stovkách členů (firemní kanály) jsou výpočetně zvládnutelné.
- Ověřitelný seznam členů je vestavěná vlastnost, ne nadstavba.
- IETF standard váží u compliance zákazníka a při bezpečnostním auditu víc než vlastní kryptografie.
- Precedent: Wire staví na MLS z týchž důvodů.

### 4.3 Implementace

**Vlastní kryptografii nepsat. Nikdy.**

Doporučená cesta: `OpenMLS` (Rust) jako krypto jádro, .NET binding přes FFI.

Alternativy k prověření:
- `mls-rs` (AWS) — Rust, aktivně vyvíjený
- Zjistit stav .NET MLS implementací (k datu psaní žádná produkčně zralá)

**Rozhodovací bod:** Pokud FFI vrstva vyjde jako příliš křehká, zvážit Rust mikroslužbu pro krypto operace s gRPC rozhraním vůči .NET backendu. Náklad: jeden síťový hop navíc, zisk: čistší hranice a snadnější audit krypta.

---

## 5. Auditní model

### 5.1 Klíčová hierarchie

```
Organizace
└── OrgAuditKey (asymetrický pár)
    ├── Veřejný klíč → distribuován klientům při enrollmentu
    └── Privátní klíč → HSM (Azure Key Vault Managed HSM)
                         přístup jen přes schválený workflow
                         princip 4 očí (dva schvalovatelé)
```

### 5.2 Životní cyklus firemní konverzace

1. Klient vytváří skupinu.
2. Klient ověří, že `OrgAuditKey` je v seznamu členů (vynuceno politikou organizace).
3. Pokud auditní člen chybí a politika ho vyžaduje → klient odmítne odeslat.
4. Server routuje šifrované obálky, nemá klíč.
5. Auditní služba přijímá svou kopii jako řádný člen skupiny.

### 5.3 Oddělení od skupinového ratchetu

**Problém:** MLS má forward secrecy — staré klíče se zahazují. Auditní archiv musí být čitelný za 5 let.

**Řešení:** Auditní kopie se šifruje **samostatně** klíčem `OrgAuditKey`, nezávisle na epoch klíčích skupiny. Rotace klíčů skupiny neovlivní čitelnost archivu.

### 5.4 Rozsah archivace — konfigurovatelný

| Úroveň | Co se archivuje | Pro koho |
|---|---|---|
| **Metadata-only** | Kdo, komu, kdy, hash obsahu, velikost, typ | ZoKB / NIS2 — dostačuje |
| **Full content** | Metadata + dešifrovatelný obsah zpráv | MiFID II, advokáti, zdravotnictví |
| **Full + přílohy** | Vše včetně souborů | Nejvyšší regulace |

Metadata-only dramaticky snižuje nároky na storage. Výchozí nastavení.

### 5.5 Append-only log

- Hash chain — každý záznam obsahuje hash předchozího.
- WORM storage (Azure Immutable Blob Storage s time-based retention).
- Periodické kotvení kořenového hashe (denně) do odděleného úložiště → důkaz, že se archiv zpětně neměnil.
- Každé dešifrování pro eDiscovery je samostatná událost s vlastním záznamem: kdo, kdy, proč, na základě čeho.

### 5.6 Notarizace archivu — kvalifikované časové razítko

**Problém:** Hash chain sám o sobě nedokáže, že archiv nebyl zpětně přepsán. Kdo má přístup k databázi, může přepsat celý řetěz. Je potřeba externí, nezávislý důkaz existence hashe v čase.

**Zamítnuto: blockchain.** Technicky funkční (OpenTimestamps → Bitcoin), ale právně neustálené a u cílové skupiny kontraproduktivní — compliance manažer nebo právník slyší "blockchain" a přepne do režimu "hype produkt". Navíc by u soudu vyžadoval znalecké vysvětlení.

**Zvoleno: kvalifikované elektronické časové razítko dle eIDAS.** Má zákonnou presumpci správnosti. Poskytovatelé v ČR: I.CA, PostSignum, eIdentity.

#### Mechanismus

```
Zprávy/události → hash každého záznamu
                → Merkle strom za den
                → denní kořenový hash
                → kvalifikované časové razítko na kořen
                → měsíční kořen → roční kořen
```

Nerazítkuje se každá zpráva, ale denní kořen. Jednotlivý záznam se prokazuje Merkle proof vůči orazítkovanému kořeni.

#### Ekonomika (PostSignum, ceny s DPH, stav 9/2026)

| Balíček | Cena | Kč / razítko |
|---|---|---|
| 350 ks | 847 Kč | 2,42 |
| 1 000 ks | 2 178 Kč | 2,18 |
| 3 500 ks | 5 445 Kč | 1,56 |
| 10 000 ks | 14 520 Kč | 1,45 |

Fixní paušál pro vyšší objemy: do 10 000 ks/měsíc za 12 100 Kč (doplatek 0,97 Kč nad limit), do 100 000 ks za 72 600 Kč (doplatek 0,48 Kč).

**Reálný náklad:** 1 razítko denně = 365 ročně ≈ **730 Kč/rok na organizaci**. I při hodinovém razítkování (8 760/rok) pod 13 000 Kč ročně. Při ceně 150–300 Kč za uživatele měsíčně jde o zlomek procenta tržby.

#### Multi-tenant optimalizace (cloud varianta)

V cloudu se razítkuje **jeden společný kořen** přes všechny zákazníky; každá organizace dostane Merkle proof pro svou větev. Náklad na razítka pak neroste s počtem zákazníků prakticky vůbec.

U self-hosted varianty si razítka obstarává a platí zákazník sám — je to argument pro cloud v cenovém srovnání.

#### Obnova razítek

Časové razítko prodlužuje platnost o 5 let. Pro delší retenci je nutné archiv **přerazítkovat** před vypršením (ETSI archivní časová razítka).

- Naplánovat jako automatizovanou úlohu od začátku, ne řešit v pátém roce.
- Díky hierarchii hashů se přerazítkovává jen nejvyšší úroveň, ne celý archiv.
- Alert 6 měsíců před expirací nejstaršího razítka.

---

## 6. Komponenty systému

| Vrstva | Technologie | Odpovědnost |
|---|---|---|
| **Krypto jádro** | OpenMLS (Rust) + .NET binding | MLS group operace, šifrování |
| **Delivery Service** | ASP.NET Core + SignalR / WebSocket | Routování šifrovaných obálek, presence |
| **Directory Service** | ASP.NET Core | Distribuce key packages, ne klíčů samotných |
| **Identity Service** | ASP.NET Core + IdentityServer | SSO (SAML/OIDC), SCIM provisioning — jen business režim |
| **Audit Service** | Oddělená služba, vlastní DB, vlastní deployment | Append-only log, retence, eDiscovery, reporting |
| **Attachment Service** | Azure Blob / S3 kompatibilní | Šifrované bloby s TTL |
| **Admin konzole** | Blazor Server | Správa uživatelů, politik, reporty |
| **Metadata DB** | PostgreSQL | Uživatelé, skupiny, zařízení, politiky |

**Architektonické pravidlo:** Audit Service je nasazen odděleně a má vlastní přístupová práva. Kompromitace Delivery Service nesmí dát útočníkovi přístup k archivu.

### 6.1 Varianty nasazení

| | Cloud (hostovaný v ČR) | Self-hosted |
|---|---|---|
| **Kdo to provozuje** | My | Zákazník |
| **Aktualizace** | Průběžné, jedna verze | Verzované release, podpora N verzí zpět |
| **Časová razítka** | Sdílený kořen, náklad ~0 na zákazníka | Zákazník si obstarává sám |
| **Onboarding** | Hodiny | Dny až týdny |
| **Podpora** | Standardní | Nutná znalost prostředí zákazníka |
| **Cena** | Za uživatele/měsíc | Licence + support smlouva |
| **Marže** | Vyšší | Nižší (vysoký podíl lidské práce) |

**Strategie: cloud-first, self-hosted jako pozdější varianta pro velké zakázky.**

Cloud je technicky výrazně snazší — jedna verze, jedno prostředí, plná kontrola nad provozem, žádná debugging session přes sdílenou obrazovku v cizí infrastruktuře. Pro solo foundera je to jediná udržitelná cesta v prvních fázích.

Self-hosted poptávka reálně přijde (veřejná správa, obrana, energetika, velké banky) — ale jako **enterprise varianta s odpovídající cenou a podmínkami**, ne jako standardní produkt. Do té doby stačí umět říct "na roadmapě je".

**Technický důsledek pro architekturu už teď:** Stavět od začátku tak, aby self-hosted nebyl přepis, ale konfigurace.

- Žádná tvrdá závislost na proprietárních Azure službách v jádře — abstrahovat za rozhraní (storage, queue, secrets).
- Docker Compose / Helm chart jako deployment artefakt od první verze, i pro vlastní cloud.
- Konfigurace přes env proměnné, ne hardcoded endpointy.
- Žádný předpoklad multi-tenancy v doménovém modelu — single-tenant je podmnožina, ne výjimka.

Tenhle přístup stojí na začátku zhruba 10–15 % navíc a ušetří kompletní refaktoring v momentě, kdy přijde první zákazník s požadavkem na on-premise.

### 6.2 Technologická rozhodnutí a jejich odůvodnění

#### 6.2.1 Jazyk: .NET, Rust jen jako krypto knihovna

Otázka "nemá to být celé v Rustu kvůli výkonu" vychází ze špatného předpokladu. Messaging server netráví čas počítáním — tráví ho čekáním na sockety.

| Komponenta | Charakter zátěže | Volba |
|---|---|---|
| Delivery Service | I/O bound — WebSocket spojení | .NET (desítky tisíc souběžných spojení na instanci) |
| MLS krypto operace | CPU bound | Rust — ale binduje se OpenMLS, nepíše se vlastní |
| Attachment pipeline | I/O bound, streaming | .NET — šifrování dělá klient, server jen streamuje |
| Audit Service | I/O + hashování | .NET — SHA-256 běží na hardwarových instrukcích |
| Admin konzole | Zanedbatelná | .NET / Blazor |

Precedent: Discord (Elixir, Go) a WhatsApp (Erlang) nevolily svůj stack kvůli raw výkonu, ale kvůli concurrency modelu. `async/await` + `Channel<T>` v .NET dává totéž.

**Riziko polyglot stacku u solo foundera je vyšší než jakýkoli výkonový zisk.** Jeden jazyk, jeden CI pipeline, jedna sada nástrojů.

**Co si ohlídat — FFI hranice.** Marshalling přes P/Invoke je místo, kde vznikají memory safety chyby. Pokud se ukáže jako křehký, fallback je Rust mikroslužba s gRPC rozhraním: jeden síťový hop navíc, zato čistá hranice a snadnější bezpečnostní audit krypta.

#### 6.2.2 Clean Architecture a DDD — ortogonální, ne alternativy

- **Clean Architecture** = strukturální pravidlo. Závislosti směřují dovnitř, doména nezná infrastrukturu.
- **DDD** = způsob modelování. Ubiquitous language, agregáty, bounded contexts, invarianty v doméně.

Clean Architecture platí všude. **DDD se aplikuje selektivně**, jen tam, kde existuje skutečná doménová složitost:

| Bounded context | DDD? | Odůvodnění |
|---|---|---|
| **Audit & Compliance** | ✅ Rozhodně | Složité invarianty (retenční politiky, rozsah archivace, kdo smí dešifrovat), doména se bude měnit s legislativou. Tady se vrátí každá investovaná hodina. |
| **Organization & Policy** | ✅ Ano | Politiky, role, enrollment pravidla — bohatá doména |
| **Messaging / Delivery** | ❌ Ne | Je to transport. Zpráva je neprůhledný šifrovaný blob, doménová logika prakticky nulová. Agregáty a doménové eventy by tu byly čistý overhead. |
| **Attachments** | ❌ Ne | Pipeline, ne doména |

**Závěr:** Delivery Service má být tenký a rychlý. Audit Service potřebuje disciplínu, protože tam žije skutečná složitost produktu.

#### 6.2.3 Databáze: PostgreSQL, oddělené schéma pro audit

Jedna instance, ale **oddělené databáze nebo schémata** pro Delivery a Audit. Důvod není výkon, ale architektonická zásada z kapitoly 6 — kompromitace Delivery nesmí dát přístup k archivu.

| | Delivery DB | Audit DB |
|---|---|---|
| **Profil zátěže** | Vysoký zápis, krátká retence | Append-only, dlouhá retence |
| **Práva aplikačního účtu** | Plná | **Pouze INSERT a SELECT** — žádné UPDATE ani DELETE |
| **Partitioning** | Po dnech na tabulce zpráv | Po měsících |
| **Mazání** | `DROP PARTITION`, ne `DELETE` | Nikdy (jen po vypršení retenční lhůty) |
| **Přístupová vrstva** | Dapper / raw SQL | EF Core |

**Proč Dapper na Delivery:** Hot path, kde EF change tracking nic nepřináší a jen přidává alokace. Na Audit a Organization naopak EF Core dává smysl — bohatý model, migrace, méně častý zápis.

#### 6.2.4 Message broker: zatím ne

Před přidáním brokeru je nutné projít, co se skutečně frontuje:

| Use case | Broker? | Řešení |
|---|---|---|
| Doručení online příjemci | ❌ | Přímo přes SignalR — broker jen přidá latenci |
| Zpráva pro offline příjemce | ❌ | Persistentní outbox tabulka v Postgresu |
| Push notifikace (APNs/FCM) | ✅ | Externí volání, může selhat, chce retry a backoff |
| Zápis do auditního logu | ⚠️ | Spíš transakční garance než fire-and-forget |
| Denní časové razítko | ❌ | Scheduled job |
| Cleanup expirovaných blobů | ❌ | Background service s timerem |
| Fan-out do velké skupiny | ⚠️ | Až při stovkách členů |

**Rozhodnutí pro fázi 1: bez brokeru.**

- `SELECT ... FOR UPDATE SKIP LOCKED` v Postgresu — zvládne tisíce zpráv za sekundu, daleko nad potřebou pilota, a transakční konzistenci dostaneš zdarma.
- `Channel<T>` pro in-process předávání mezi SignalR hubem a workery.
- `LISTEN/NOTIFY` pro signalizaci mezi instancemi při horizontálním škálování.

**Kdy broker přidat:** Až při federaci mezi organizacemi (fáze 4) — tam je skutečně asynchronní komunikace mezi nezávislými instancemi přes nespolehlivou síť. To je klasický broker use case.

**Volba až v ten moment:** RabbitMQ nebo Redis Streams. **Azure Service Bus je vyloučen** — tvrdá závislost na Azure by porušila zásadu z kap. 6.1. V každém případě abstrahovat za `IMessagePublisher`, aby šel v self-hosted nahradit.

---

## 7. Attachment pipeline

Přílohy se **nešifrují MLS klíčem** — to by neúnosně zatížilo protokol.

```
1. Klient vygeneruje náhodný AES-256-GCM klíč pro tento soubor
2. Zašifruje soubor lokálně
3. Nahraje šifrovaný blob → dostane URL + TTL
4. Pošle MLS kanálem: { url, fileKey, hash, filename, size, mime }
5. Příjemce stáhne blob, dešifruje fileKey z MLS zprávy, otevře soubor
6. Po vypršení TTL (nebo po potvrzení doručení) se blob maže
```

Vlastnosti:
- Server drží šifrovaný blob a nemá klíč.
- Velikost limitována jen storage politikou, ne protokolem → řeší bolest WhatsApp (2 GB) a Signal (100 MB).
- Chunked upload s resume pro velké soubory.
- V business režimu se `fileKey` archivuje spolu s metadaty (při Full + přílohy).

---

## 8. Známá rizika a bolestivá místa

### 8.1 Mobilní klienti — největší riziko projektu

Ne kryptografie. Mobilní platformy.

**Push notifikace u E2E:** Server neví, co zpráva obsahuje. Možnosti:
- Prázdná notifikace ("Nová zpráva") — bezpečné, ale špatné UX
- Dešifrování v notification service extension — lepší UX, ale iOS má tvrdé limity (cca 30 s, omezená paměť, samostatný proces)

**Důsledek pro volbu technologie:** .NET MAUI zde spíš uškodí — notification service extension vyžaduje nativní kód a přístup ke klíčence. Pravděpodobně nativní klienti (Swift / Kotlin) nebo MAUI + nativní extension jako hybrid.

**Rozhodnutí:** Mobil odložit. Viz kapitola 10.

### 8.2 Multi-device sync

Každé zařízení = samostatný MLS klient s vlastním klíčem. Historie se nedá stáhnout ze serveru, protože ji server nemá.

Možnosti:
- Device-to-device transfer při párování (QR kód)
- Šifrovaná záloha, klíč odvozený z recovery fráze
- Kombinace obojího

**Backup na Google účet / vlastní úložiště:** Ukládá se šifrovaný blob, klíč zůstává u uživatele. Metadata "kdo zálohuje" jsou u poskytovatele úložiště — to je akceptovatelný kompromis, který je ale nutné transparentně komunikovat.

### 8.3 Bez registrace vs. business režim

- **Consumer:** Identita = lokálně generovaný keypair. Žádný telefon, žádný e-mail. Model jako SimpleX Chat.
- **Business:** Identita napojená na firemní adresář (LDAP/AD, SCIM). Anonymita zde není žádoucí ani přípustná.

Jedna kódová báze, dva enrollment flow.

### 8.4 Bot API

Bot jako plnohodnotný účastník konverzace (model Telegram / Discord — umožňuje připojení vlastního agenta typu Hermes).

Zásadní důsledek pro E2E: **bot musí mít vlastní MLS identitu a být viditelným členem skupiny.** Žádné dešifrování na serveru.

- Uživatel si připojí vlastního agenta a vidí ho v seznamu členů.
- API náklady nese uživatel u svého providera — pro nás nulový náklad.
- Není to monetizace, je to platformová feature. Právě ta udělala z Telegramu platformu místo aplikace.

---

## 9. Co vědomě neděláme

| Zamítnuto | Důvod |
|---|---|
| **Placení uživatelům za reklamu** | Netargetovaná reklama v E2E prostředí vynese ~1 Kč/uživatel/měsíc. Za to nikdo nezmění messenger. Zato přitáhne click farmy a boty. Navíc: posílání peněz = KYC/AML povinnosti → anonymita padá. |
| **Reklama obecně** | Reklamní hodnota stojí na targetingu. Bez přístupu k obsahu a identitě prodáváš nejlevnější inventory. Přímo v rozporu s produktovým slibem. |
| **Storage jako hlavní monetizace** | Nízká marže, silná konkurence, není to diferenciátor. |
| **Consumer-first go-to-market** | Network effect je pro solo foundera nepřekonatelná bariéra. Produkt má nulovou hodnotu pro prvního uživatele. |

---

## 10. Vývojová sekvence

### Fáze 1 — Jádro (MVP pro pilota)
- Krypto jádro + MLS group lifecycle
- Delivery Service
- **Desktop / web klient** (Blazor nebo Electron)
- Admin konzole — základ
- Audit Service — metadata-only
- **Nouzový režim** — offline enrollment, nezávislost na SSO (viz 2.3)
- Export dokladu o existenci a funkčnosti nouzového kanálu

**Proč ne mobil první:** Mobil je nejvyšší nákladová položka a nejnižší část hodnoty pro B2B pilota. Firma v prvním kroku chce vidět, že to funguje a že má admin konzoli.

**Proč nouzový režim už ve fázi 1:** Je to nejlevnější vstup do firmy — malý rozsah, jasná zákonná povinnost, nízká cena, nevyžaduje nahradit Teams. Denní provoz se doprodává až potom.

### Fáze 2 — Pilot
- Jeden zákazník, přednostně z kategorie 1 nebo 2 dle kap. 2.5
- Vstup přes nouzový kanál, ne přes nahrazení denní komunikace
- Cíl: potvrzená ochota platit, ne dokonalý produkt
- Výstup: reference + zpětná vazba k reportingu

### Fáze 2b — Compliance vrstva
- Správa klíčů a certifikátů (2.7)
- Cryptographic baseline dle doporučení NÚKIB (2.8)
- Exporty doložitelnosti (2.9)

### Fáze 3 — Mobil
- Nativní klienti
- Multi-device sync
- Push infrastruktura

### Fáze 4 — Enterprise
- SSO / SCIM
- Federace mezi organizacemi
- Full content archivace
- Self-hosted balíček

### Fáze 5 — Consumer free tier
- Marketingový kanál, ne zdroj příjmů
- Bez auditního člena, bez registrace

---

## 11. Otevřené otázky

- [ ] Ověřit produkční zralost OpenMLS a kvalitu .NET FFI vrstvy
- [ ] Rozhodnout: FFI binding vs. Rust mikroslužba s gRPC
- [ ] Právní posouzení — je transparentní auditní člen dostatečný z hlediska zákoníku práce a GDPR? (nutná konzultace s advokátem)
- [ ] Zjistit, co přesně NÚKIB při kontrole požaduje doložit ohledně komunikace — formát reportu
- [ ] Ověřit, zda existuje certifikace/atestace, která by u zákazníků fungovala jako důvěryhodnostní zkratka
- [ ] Cenový model: za uživatele/měsíc? Za organizaci? Rozdíl cloud vs. self-hosted?
- [ ] Identifikovat 10 konkrétních firem v JMK pro validační rozhovory
- [ ] Rozhodnout finální název (viz samostatná rešerše ochranných známek)

---

## 12. Validační milník

**Nekódovat, dokud neplatí:**

Alespoň 3 organizace spadající pod ZoKB (přednostně kategorie 1 nebo 2 dle kap. 2.5) v rozhovoru řeknou, že:

- (a) nemají funkční oddělený nouzový komunikační kanál, nebo ho řeší soukromým WhatsAppem,
- (b) vědí, že je to zákonná povinnost dle § 25 odst. 2 vyhl. 409/2025 Sb. resp. § 13 vyhl. 410/2025 Sb.,
- (c) zaplatily by za řešení konkrétní částku.

Bez toho je to technicky zajímavý projekt bez trhu.

**Kontrolní otázka do rozhovoru, která odhalí skutečný stav:**
„Kdyby vám dnes padl nebo byl kompromitován M365 tenant, kde by se váš incident response tým domluvil na dalším postupu — a dokázali byste to doložit při kontrole?"
