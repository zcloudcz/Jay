# TURN bezpečnost, kapacita a validace (I03)

Coturn běží na existujícím serveru `187.127.83.154:3478` spolu s PostgreSQL, credentials vydává API
s historickým TTL 3600 s (`docs/azure-beta-plan.md`; skutečná hodnota app-setting `Turn__TtlSeconds`
je 86400 v `appsettings.json` výchozím configu — **rozdíl mezi vývojovým defaultem a nasazenou
hodnotou, ověřit se skutečným nastavením před závěrem, TTL změna se koordinuje s B00**).

## 0. Cloudflare TURN (preferovaná varianta od 2026-09-16)

Server umí místo vlastního coturn vydávat credentials z Cloudflare TURN. Přepnutí je jen konfigurace API, klient se nemění.

| App setting (Azure) | Hodnota |
| --- | --- |
| `Turn__Provider` | `cloudflare` |
| `Turn__Cloudflare__KeyId` | TURN key ID z Cloudflare dashboardu (Calls → TURN) |
| `Turn__Cloudflare__ApiToken` | API token ke stejnému klíči — **tajemství**, jen do app settings |
| `Turn__TtlSeconds` | zachovat (např. 3600) |
| `Turn__Urls__N`, `Turn__SharedSecret` | pro Cloudflare se nepoužívají; lze ponechat pro rychlý návrat na coturn |

Chování: `GET /turn/credentials` volá `POST /v1/turn/keys/{KeyId}/credentials/generate` (timeout 10 s) a vrací
`urls` z odpovědi Cloudflare (`stun:`, `turn:` UDP/TCP 3478, `turns:` TLS 5349). Při výpadku Cloudflare vrací
endpoint **503** a klient jede bez TURN (chat/signalizace nedotčeny). Tělo odpovědi Cloudflare se nikdy neloguje.

Co odpadá: sekce 2–4, 8 a 10 níže (provoz coturn). Co zůstává k ověření: sekce 5 (negativní scénáře — Cloudflare
odmítne expirované credentials sám), 7 (skutečný forced-relay hovor, D04 `forceIceRelay`) a 9 (síť bez UDP — TLS 5349
je nyní k dispozici, stále NOT_RUN). Traffic: Cloudflare uvádí zahrnutý objem měsíčně a cenu za GB nad ním — ověřit
aktuální ceník před závazkem v I04; do té doby limit externího serveru z I03 neplatí.

Návrat na coturn: `Turn__Provider=shared-secret` a restart; ostatní klíče zůstaly.

## 1. Zjištěný stav bez admin přístupu k serveru

- TCP connect probe `187.127.83.154:3478`: **PASS** — port je ze sítě tohoto agenta dosažitelný
  (na rozdíl od DB portu 5544, viz `docs/ops/evidence/I02.md`). To dokazuje jen otevřený TCP port,
  ne funkční TURN protokol, ne autentizaci a ne UDP cestu.
- Verze coturn, listener konfigurace, rozsah relay portů, NAT mapování, CPU/RAM/disk logů a čas
  serveru: **BLOCKED** — vyžaduje admin přístup k serveru, který tento balíček nemá.
- Zda coturn sdílí prostředky se stejným serverem jako PostgreSQL: podle `docs/azure-beta-plan.md`
  ano (stejná IP `187.127.83.154`). Riziko vzájemného vytlačení při zátěži je reálné a nebylo
  měřeno; runbook níže to zohledňuje jako otevřenou otázku pro operátora.

## 2. Konfigurace (`infra/coturn/turnserver.conf.example`)

Obsahuje: autentizaci sdíleným tajemstvím (`use-auth-secret`/`static-auth-secret`, hodnota jen
placeholder), explicitní `realm`, vypnuté `cli`/management, omezený `min-port`/`max-port`, návrh
`user-quota`/`total-quota`, `denied-peer-ip` pro loopback/private/link-local/metadata IPv4 i IPv6,
`no-multicast-peers`, a omezení logování. **Směrnice, ne nasazená konfigurace** — hodnoty portů a
kvót je nutné ověřit proti skutečně běžící verzi coturn (BLOCKED výše) před aplikací.

Poznámka k jednotkám: `user-quota`/`total-quota` v coturn počítají počet současných **allocations**
(relay session), ne šířku pásma ani počet uživatelských účtů. Jeden obousměrný audio+video hovor s
jedním TURN serverem typicky potřebuje 1–2 allocations na účastníka (podle toho, zda audio a video
jdou stejnou relay session). Hodnoty `user-quota=4`/`total-quota=20` v example souboru jsou
konzervativní výchozí odhad pro plánovací cíl "2 současné obousměrné hovory" (viz bod 4), **nikoli
změřená hodnota** — potvrdit po skutečném testu s konkrétní verzí coturn.

## 3. Ochrana cílových adres

`denied-peer-ip` v example souboru pokrývá RFC 1918 (10/8, 172.16/12, 192.168/16), loopback
(127/8, ::1), link-local (169.254/16, fe80::/10), CGNAT (100.64/10), benchmark (198.18/15), TEST-NET
dokumentační rozsah (192.0.0/24) a IPv4-mapovaná/NAT64 metadata cesta (64:ff9b::/96) i klasickou
cloud metadata adresu `169.254.169.254`. Testovat ochranu jen proti vlastním kontrolovaným cílům
(např. loopback na testovacím klientovi), nikdy skenováním cizích sítí. Toto je oddělené od
autentizace: `denied-peer-ip` brání i **platně autentizovanému** klientovi nasměrovat relay na
interní cíl (SSRF přes TURN), ne komu je allocation vůbec povolena.

## 4. Kapacitní plán (2 současné obousměrné hovory)

Plánovací cíl: 2 současné obousměrné audio/video hovory. Počet TURN allocations **není** roven počtu
uživatelů ani počtu hovorů 1:1 — musí se odvodit z měření (bod 6), ne opsat naslepo.

### Výpočet propustnosti (ingress/egress odděleně)

Pokud každý ze 2 účastníků jednoho hovoru posílá 1 Mbit/s, TURN relay musí tento tok přijmout
(ingress) a přeposlat druhé straně (egress):

- 1 hovor, 2 směry: ingress ≈ 2× 1 Mbit/s = 2 Mbit/s do relaye; egress ≈ 2 Mbit/s z relaye ke druhé
  straně (relay v podstatě zdvojuje provoz, jde skrz něj tam i zpět).
- Egress přibližně 2 Mbit/s × 3600 s / 8 = 900 Mbitů... v desetinných jednotkách (2 Mbit/s = 0,25
  MB/s = 900 MB/h = 0,9 GB/h) — odpovídá hodnotě ze zadání, **bez** protokolové režie (RTP/SRTP
  hlavičky, retransmise, keepalive).
- Je-li poskytovatelem účtován ingress i egress zvlášť, celkový objem se přibližně zdvojnásobí
  (≈1,8 GB/h na jeden hovor při těchto parametrech).
- Pro 2 současné hovory: ≈1,8 GB/h (jen egress) až ≈3,6 GB/h (ingress+egress), bez protokolové režie.
  **Toto je aproximace, ne měřená hodnota** — kodeky (Opus/VP8/VP9/H.264), skutečný bitrate a
  overhead z RTP/SRTP/ICE keepalive mění výsledek. Změřit v bodě 8 a doplnit skutečné číslo do
  `docs/ops/beta-cost-model.md`.

## 5. Negativní scénáře autentizace (checklist, k provedení operátorem/D04)

- [ ] Anonymní allocation (bez credentials) — nová allocation musí být odmítnuta. **NOT_RUN**
- [ ] Špatné credentials (neplatný HMAC) — odmítnuto. **NOT_RUN**
- [ ] Expirované credentials (po TTL) — nová allocation odmítnuta. **NOT_RUN**
- [ ] Chování JIŽ EXISTUJÍCÍ allocation po expiraci credential — coturn typicky nepřeruší již
  navázané médium okamžitě při vypršení TTL credential (TTL platí pro vytvoření nové allocation, ne
  pro její trvání). Toto se **musí ověřit proti konkrétní verzi** a nepředpokládat žádné chování bez
  testu. **NOT_RUN**
- [ ] Chování při obnově (refresh) credentials před vypršením — ověřit, že klient dokáže obnovit
  relay bez přerušení hovoru. **NOT_RUN**

## 6. Protokolové testy (UDP/TCP relay)

Historicky zaznamenáno: "10 zpráv odesláno/přijato v každém testu" (UDP i TCP) — **historický
záznam, nikoli výsledek tohoto balíčku** (viz `docs/superpowers/plans/2026-09-16-beta-infrastruktura.md`,
"Co je skutečně známo"). Zopakování vyžaduje TURN klientský nástroj a platné credentials z API —
**NOT_RUN** v tomto balíčku (žádný přístup k API pro vydání credentials byl v rozsahu tohoto testu
proveden mimo TCP port probe). TCP listener na 3478 samo o sobě není důkaz funkčního TURN TLS —
TURN TLS (obvykle port 5349 nebo jiný vyhrazený port) nebyl testován vůbec a vyžaduje samostatný
certifikát a volný port (veřejný HTTPS port nelze předpokládat volný, viz bod 9).

## 7. Skutečný forced-relay hovor (10 min audio + 10 min video, dvě sítě)

Vyžaduje D04 (klientský test switch `iceTransportPolicy: relay`), dvě odlišná zařízení na dvou
odlišných sítích a export selected candidate pair. **NOT_RUN** — mimo rozsah a nástroje tohoto
balíčku (I03 dodává jen serverovou konfiguraci a runbook; koordinace s D04 je vstup, který zatím
neproběhl). Kritérium úspěchu: `relay` v selected candidate pair na obou stranách, rostoucí
sent/received media bytes v obou směrech po celou dobu, žádné samovolné ukončení. Cíl sestavení
spojení: do 10 sekund (plánovací profil, potvrdit před vyhodnocením podle cílové sítě). Pokud
profil selže, zaznamenat jako FAIL, ne posouvat mez zpětně.

## 8. Vyčerpání kvóty

Test: dosáhnout `total-quota`/`user-quota` v izolovaném prostředí; nový pokus o allocation má
srozumitelně selhat (ne spadnout celý coturn proces), existující hovory pokračují, DB na sdíleném
serveru není ovlivněna. Po uvolnění allocation (ukončení hovoru) musí nový pokus projít. **NOT_RUN**
— vyžaduje admin přístup pro izolovaný test bez dopadu na produkční kapacitu.

## 9. Síť s blokovaným UDP a TURN TLS

Bez TURN TLS (samostatný port, certifikát) nelze prokázat konektivitu z restriktivních sítí, které
blokují i TCP na atypických portech, ale povolují HTTPS 443. **Explicitně neověřeno** — nenahrazovat
slibem univerzální konektivity. Veřejný HTTPS port (443) je již obsazen App Service / SWA, TURN TLS
by potřeboval vlastní port a certifikát na externím serveru — potvrdit s operátorem serveru, zda je
volný port a certifikát k dispozici, než se plánuje jako řešení.

## 10. Restart dopad

Restart coturn ukončí aktivní relay allocations a tedy probíhající hovory používající tento server
jako TURN. Klient by měl detekovat pád média a nabídnout redial; toto chování ověřuje D04/klientský
tým, ne I03. Po restartu s obnovenou konfigurací musí nový hovor projít (ověřit stejně jako bod 8).

## Souhrn akceptačních kritérií (K06)

| Kritérium | Status | Chybějící vstup / vlastník |
| --- | --- | --- |
| TCP port 3478 dosažitelný | PASS | — |
| Verze/konfigurace serveru ověřena | BLOCKED | admin přístup k serveru — operátor |
| `turnserver.conf.example` s auth/realm/quota/denied-peer-ip | PASS (lokální artefakt) | — |
| Anonymní/špatné/expirované credentials odmítnuty | NOT_RUN | přístup k API pro vydání credentials + testovací klient — D04/operátor |
| UDP+TCP relay protokolový test zopakován | NOT_RUN | TURN test nástroj + credentials — operátor |
| 10min audio + 10min video forced relay na 2 sítích | NOT_RUN | D04 test switch, 2 zařízení, 2 sítě |
| Kapacitní matematika (ingress/egress) | PASS (odhad, ne měření) | skutečné měření — bod 4/7 |
| Vyčerpání kvóty testováno izolovaně | NOT_RUN | admin přístup — operátor |
| UDP-blocked fallback / TURN TLS | NOT_RUN | certifikát + volný port — operátor |
