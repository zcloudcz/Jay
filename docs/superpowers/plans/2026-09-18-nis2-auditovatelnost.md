# Jay — NIS2 a auditovatelnost (plán)

> Navazuje na `2026-09-18-business-mode.md` (organizace, role, auditní člen, archiv, `AdminAuditEvent`). **Neduplikuje ho.** Tento plán pokrývá, co Business plán nechává mimo rozsah a co NIS2 (směrnice 2022/2555, v ČR nový ZoKB + vyhlášky NÚKIB) po *poskytovateli* i po *zákazníkovi* vyžaduje nad rámec funkcí v aplikaci. Stav před tímto plánem: v kódu ani v plánech není nic z níže uvedeného, web to uvádí jen jako „plán“.

**Dvě role Jay vůči NIS2** (nesměšovat):
1. **Jay jako dodavatel** povinné osobě — zákazník musí doložit řízení dodavatelů (bezpečnostní opatření dodavatele, smluvní podmínky, hlášení incidentů dodavatelem). Potřebujeme *dokumentaci a procesy*, ne kód.
2. **Jay jako nástroj**, kterým zákazník plní vlastní opatření (řízení přístupů, evidence, zálohy, nouzová komunikace). To dodává Business plán; tady jen doplňujeme exporty a logování.

Jay **není** sám povinnou osobou (velikost), ale zákazníci ho budou hodnotit, jako by byl.

## 0. Co už řeší Business plán (jen odkaz)

Organizace a role (E01), odebrání přístupu/revokace (E02), append-only `AdminAuditEvent` s exportem CSV/JSON (KB6), integrita archivu — hash řetěz + denní Merkle kořen + časové razítko (KB3/KB4), přístup „čtyři oči“ (KB5), nouzový kanál + cvičení + doklad (E07), oddělené DB a credentials.

## 1. Mezery a balíčky

| ID | Mezera (NIS2 / ZoKB oblast) | Výstup | Typ |
| --- | --- | --- | --- |
| **N01** | **Bezpečnostní logy poskytovatele** (evidence událostí, detekce): App Service logy jsou soubory s krátkou retencí, bez centrálního úložiště, bez alertů | Strukturované logy bezpečnostních událostí API (přihlášení zařízení, selhání JWT, rate-limit hity, 403/401 vzory, změny konfigurace, migrace, start/stop) → Azure Log Analytics / Application Insights **nebo** syslog do vlastního SIEM (self-hosted zásada: adaptér `ILogSink`, ne tvrdá vazba); retence ≥ 12 měsíců **[PŘEDPOKLAD, viz Q3]**; 3 základní alerty (nárůst 401/403, pád readiness, přihlášení z nového ASN pro admin účet); redakce tajných údajů už řeší I04 | kód + infra |
| **N02** | **Export auditu pro zákazníka do jeho SIEM** | `GET /orgs/{id}/admin-audit` (KB6) doplnit o formát **CEF/JSON Lines** a **pull přes API klíč organizace** (rotovatelný, jen čtení) + volitelný **webhook push** s podpisem HMAC; dokument „napojení na Splunk/Sentinel/Elastic“ | kód |
| **N03** | **Řízení přístupu správců**: dnes heslo (Argon2id) bez druhého faktoru; NIS2 vyžaduje MFA pro privilegované účty | TOTP (RFC 6238) pro role `owner/org-admin/auditor-approver`, záložní kódy, vynucení politikou organizace; **SSO (OIDC)** zůstává fáze 2 (Business plán ho vylučuje) | kód |
| **N04** | **Zvládání incidentů + hlášení**: NIS2 lhůty — včasné varování 24 h, hlášení 72 h, závěrečná zpráva 1 měsíc; zákazník to potřebuje i od dodavatele | `docs/security/incident-response.md`: klasifikace, kdo rozhoduje, kontaktní kanál pro zákazníky (bezpečnostní e-mail + PGP klíč nebo `security.txt`), šablona hlášení zákazníkům do 24 h, postmortem šablona; `/.well-known/security.txt` na webu i API; evidence incidentů (soubor/issue tracker, ne DB) | proces + drobný kód |
| **N05** | **Kontinuita a obnova**: skripty zálohy PostgreSQL existují, na serveru **NOT_RUN**; Blob bez ověřené obnovy; RPO/RTO nedefinované | Spustit a doložit `infra/postgres/backup.sh` + `restore-verify.sh` na serveru (cron), test obnovy Blob, deklarované RPO/RTO **[Q4]**, runbook ztráty App Service/serveru, čtvrtletní test obnovy zapsaný v `docs/ops/` | provoz + doklad |
| **N06** | **Řízení zranitelností a dodavatelského řetězce**: závislosti se kontrolují ad hoc | `dotnet list package --vulnerable` + `dart pub outdated`/`osv-scanner` v CI jako blokující krok; Dependabot; SBOM (CycloneDX) generovaný v `deploy.yml` a přiložený k release; SHA-pinned actions (už je); pravidlo lhůt oprav (kritická 7 dní, vysoká 30 dní **[PŘEDPOKLAD]**) | CI |
| **N07** | **Kryptografie a její doložení**: vlastní implementace X3DH/Double Ratchet bez auditu; TOFU; lokální DB v plaintextu | Dokument `docs/security/crypto-baseline.md` (algoritmy, délky klíčů, rotace, známé meze — mapovat na doporučení NÚKIB pro kryptografické algoritmy); **externí audit** kryptografie a serveru = rozpočet **[Q1]**; SQLCipher/šifrovaná lokální DB jako samostatné zadání | dokument + externí |
| **N08** | **Bezpečnostní dokumentace pro posouzení zákazníkem** (dodavatelské řízení) | Balík v `docs/security/`: architektura a datové toky (co server vidí — metadata; anonymní vs. business režim), subdodavatelé (Azure regiony, Cloudflare TURN, Firebase, TSA), umístění dat, retence, role a přístupy provozovatele, změnové řízení (deploy = SHA-pinned workflow, kdo schvaluje), politika hesel/MFA, kontakt; vyplněný **dotazník dodavatele** podle přílohy vyhlášky NÚKIB (self-assessment matice: opatření → jak Jay plní / neplní / N/A); DPIA šablona pro business režim (zákazník si dokončí) | dokument |
| **N09** | **Zpracování osobních údajů (GDPR, souvisí)**: chybí smazání účtu/zařízení, export dat | `DELETE /accounts/{id}` + `DELETE /devices/{id}` (kaskády — pozor na `Channel.FollowerCount`, viz komentář v `AppDbContext`), export dat účtu (JSON), zpracovatelská smlouva (DPA) šablona | kód + dokument |
| **N10** | **Řízení změn a oddělení prostředí**: jen jedno prostředí (beta = produkce) | Staging slot / druhá App Service s vlastní DB pro nasazení před produkcí; `deploy.yml` nejdřív na staging + smoke, produkce až po ručním schválení (GitHub environment protection) | infra |

## 2. Pořadí a vlny

Levné a nezávislé na Business plánu (lze hned): **N04, N06, N08 (první verze), N05**.
Po E00/E01 Business plánu: **N02, N03, N09**.
Rozpočtové/externí: **N07 (audit), N01 (Log Analytics = měsíční náklad), N10 (druhé prostředí = náklad)**.

Vlny: (N04 ∥ N06 ∥ N05) → N08 v1 → (N02 ∥ N03 ∥ N09 po E01) → N01 → N10 → N07 externí audit → N08 v2 (po auditu).

## 3. Přejímací kritéria

- **N01:** bezpečnostní událost (10× špatný JWT z jedné IP) je do 5 min vidět v centrálním logu a spustí alert; logy neobsahují tokeny ani obsah zpráv (syntetický marker test); retence odpovídá rozhodnutí Q3.
- **N02:** zákazník s API klíčem stáhne CEF/JSONL export; klíč po rotaci starý přístup odmítne; webhook má platný HMAC a při chybě opakuje s backoffem; export neobsahuje obsah zpráv.
- **N03:** admin bez TOTP se do správy organizace nedostane, pokud to politika vyžaduje; záložní kód je jednorázový; test proti replay.
- **N04:** `security.txt` dostupný; cvičný incident („únik JWT secretu“) projde postupem a vznikne zápis + hlášení zákazníkům v šabloně do 24 h (tabletop, datovaný záznam).
- **N05:** záloha běží denně, `restore-verify.sh` dokládá obnovu do prázdné DB s kontrolou počtů řádků; deklarované RPO/RTO splněné při testu; zapsáno v `docs/ops/`.
- **N06:** CI selže na známé zranitelnosti (test: dočasně přidat zranitelnou verzi); SBOM je v artefaktech release.
- **N07:** dokument existuje a odpovídá kódu (revize při každé změně `core/crypto`); auditní zpráva třetí strany (až bude) přiložená v `docs/security/` bez redakce nálezů.
- **N08:** dotazník dodavatele vyplněný bez „TBD“; každý řádek „plní“ odkazuje na kód/test/doklad; každý „neplní“ má termín nebo „záměrně ne“.
- **N09:** smazání účtu odstraní účet, vazby, zálohy v Blob a push tokeny; export vrátí vše, co o účtu server drží; smazání zařízení nesnese `FollowerCount`.
- **N10:** produkce nejde nasadit bez předchozího úspěšného stagingu téhož SHA a ručního schválení.

## 4. Otázky pro zadavatele

Viz konverzace 2026-09-18; odpovědi doplnit sem jako „Rozhodnutí“.

1. Externí bezpečnostní audit (kryptografie + server): kdy a jaký rozpočet?
2. MFA pro správce už ve verzi 1 Business režimu (TOTP), nebo počkat na SSO?
3. Retence bezpečnostních logů poskytovatele: 12 měsíců, 18, jiná?
4. RPO/RTO, ke kterým se zavážeme (návrh: RPO 24 h, RTO 8 h pro betu).
5. Kdo je bezpečnostní kontakt Jay pro zákazníky a incidenty (jméno, e-mail, telefon) a existuje záložní osoba?
6. Cílový trh pro dokumentaci: jen ČR (ZoKB/NÚKIB), nebo i EU obecně (anglická verze)?
7. Druhé prostředí (staging) — přijatelný náklad ~ další B1 + malá DB (odhad 15–20 USD/měsíc)?
8. Self-hosted varianta pro zákazníky (Business plán ji předpokládá) — má být doložitelnost N01/N05 řešena i pro on-premise (tj. bez Azure služeb), nebo pro betu stačí Azure?

## 5. Mimo rozsah

Získání certifikace (ISO 27001) — plán ji nepředjímá, ale N08 je k ní krok; právní posudky a smlouvy (jen šablony); SSO/SCIM (fáze 2 Business plánu); MDM politiky zařízení.
