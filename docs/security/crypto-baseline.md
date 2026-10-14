# Kryptografická základní linie (crypto baseline) — Jay / CallType

> **Údržba:** tento dokument se reviduje při každé změně pod
> `src/client/calltype_core/lib/crypto/` (a při změně souvisejících míst na
> serveru uvedených níže). Revizor ověří, že tabulky odpovídají aktuálnímu
> kódu, a upraví je při rozporu.
>
> **Ověřeno proti commitu:** `b315688774436b9813a928e80ef0339a73719775`

## 1. Rozsah a čestný stavový řádek

Jay používá **vlastní implementaci** Signal-like protokolu v čistém Dartu
(balíček [`cryptography`](https://pub.dev/packages/cryptography), který
deleguje na platformní primitiva tam, kde je `cryptography_flutter`
k dispozici — `src/client/calltype_core/lib/crypto/signal_protocol.dart:13-15`).

**Tato implementace NEBYLA nezávisle auditována.** Produkt to komunikuje
uživatelům jako "bez nezávislého auditu" a toto rozhodnutí platí i po tomto
dokumentu — cílem je auditovatelnost (N07), ne externí audit.

## 2. Inventář primitiv

| Účel | Algoritmus / parametry | Zdroj v kódu |
|---|---|---|
| DH key agreement (X3DH, ratchet) | X25519 | `signal_protocol.dart:26` (`_x25519 = X25519()`) |
| Podpis signed pre-key / identity bundle | Ed25519 | `signal_protocol.dart:30`, `key_manager.dart:34-56` |
| Zprávy (AEAD) | AES-256-GCM, nonce 12 B náhodný, tag 16 B | `signal_protocol.dart:35,212-247` |
| KDF po X3DH a v DH ratchetu (KDF_RK) | HKDF-SHA256 | `signal_protocol.dart:187-200`, `session_manager.dart:602-615` |
| KDF v symetrickém ratchetu (KDF_CK) | HMAC-SHA256, konstanty `0x01`/`0x02` | `signal_protocol.dart:249-258`, `session_manager.dart:76-79` |
| Domain-separation stringy (doslovně) | `"CallType-X3DH-v1"`, `"CallType-DR-Root-v1"`, `"CallType-session-v2\|..."`, `"CallType-SignedIdentity-v1\0"` | `session_manager.dart:73-74,620-622`, `key_manager.dart:62` |
| Zdroj náhodnosti (klient) | `Random.secure()` (Dart) resp. `RandomNumberGenerator` pod `cryptography` package interně pro klíče | `signal_protocol.dart:37,260-267` |
| Group messaging | žádný skupinový klíč — per-recipient fan-out, N samostatných pairwise obálek | `group_cipher.dart:15-34` |
| Přílohy (1:1 chat) | uvnitř stejné AES-GCM zprávy jako text, limit 256 KiB | `src/client/calltype/lib/features/chat/attachment.dart:4,13-17` |
| Zálohy — KDF | PBKDF2-HMAC-SHA256, 600 000 iterací, salt 16 B | `backup_crypto.dart:30-73` |
| Zálohy — šifrování | AES-256-GCM, nonce 12 B, tag 16 B | `backup_crypto.dart:96-130` |
| Device secret (JWT exchange) | 256bitový náhodný secret, server ukládá SHA-256(secret), bez stretchingu | `src/server/CallType.Api/Endpoints/AuthEndpoints.cs:12-15,73-81` |
| JWT podpis | HMAC-SHA256 (symetrický), životnost 24 h, refresh grace 7 dní | `src/server/CallType.Api/Services/JwtService.cs:26-34,76` |
| Účet (Argon2id) — hash auth klíče | Argon2id, salt 16 B, hash 32 B, parallelism 4, paměť 64 MiB, iterace 3 | `src/server/CallType.Api/Endpoints/AccountEndpoints.cs:33-37` |
| TURN (shared-secret varianta) | HMAC-SHA1 nad `expiry:deviceId`, TTL výchozí 24 h | `src/server/CallType.Api/Services/TurnCredentialService.cs:19,66-83` |
| TURN (Cloudflare varianta) | delegováno na Cloudflare Calls API (`Turn:Cloudflare:KeyId`/`ApiToken`) | `src/server/CallType.Api/Services/CloudflareTurnCredentialService.cs:45-48` |
| Audit hash chain (Business mode) | SHA-256(PrevHash ‖ kanonický záznam), separátor `\x1f` | `src/server/CallType.Audit/Application/HashChain.cs:22,39-63` |
| Emergency kód (uchovaný jako hash) | 128 b náhodnosti (Crockford base32), hash SHA-256, bez stretchingu | `src/server/CallType.Audit/Emergency/EmergencyCodes.cs:9-11,22,59-64` |
| Bot encrypted file store | AES-256-GCM (`BackupCrypto` reused), klíč z env `BOT_STORE_KEY` (32 B) | `src/bots/calltype_bot/lib/src/encrypted_file_store.dart:9-22,29-48` |
| Channel media (kanály) | **beze šifrování** — nešifrovaný obrázek v Blob kontejneru `channel-media`, limit `Channels:MaxImageBytes` (2 MiB výchozí) | `src/server/CallType.Api/Configuration/ChannelsOptions.cs:28`, `src/server/CallType.Api/appsettings.json:33`, `src/server/CallType.Api/Endpoints/ChannelEndpoints.cs:592-640` |

### X3DH — vstupy a odvození

- DH1 = DH(IK_a, SPK_b), DH2 = DH(EK_a, IK_b), DH3 = DH(EK_a, SPK_b),
  DH4 = DH(EK_a, OPK_b) *(pouze pokud je k dispozici one-time pre-key)*
  — `session_manager.dart:110-143`.
- Konkatenace: 32 B `0xFF` prefix (dle X3DH spec "F") + DH1‖DH2‖DH3(‖DH4)
  — `session_manager.dart:128-133`.
- `SK = HKDF-SHA256(salt=32×0x00, ikm=dhConcat, info="CallType-X3DH-v1", 32 B)`
  — `session_manager.dart:145-150`.

### Double Ratchet — root/chain/message keys

- `KDF_RK(rootKey, dhOutput) = HKDF-SHA256(salt=rootKey, ikm=dhOutput, info="CallType-DR-Root-v1", 64 B)`,
  prvních 32 B = nový root key, druhých 32 B = chain key — `session_manager.dart:602-615`.
- `KDF_CK`: message key = HMAC-SHA256(chainKey, 0x01), next chain key =
  HMAC-SHA256(chainKey, 0x02) — `session_manager.dart:76-79,208-211,340-343`.
- **Skipped-message-key handling:** max 256 přeskočených klíčů v jednom
  řetězu (`_maxSkip`), max 512 uložených skip klíčů na relaci
  (`_maxStoredSkippedKeys`, FIFO eviction) — `session_manager.dart:62-70,569-600`.
  Limit chrání proti DoS (vynucené odvození velkého počtu klíčů) i proti
  neomezenému růstu úložiště; důsledek: velmi staré out-of-order zprávy
  se po překročení limitu stanou nedešifrovatelnými (standardní Signal
  trade-off, komentář v kódu to přiznává).
- Hlavička (ratchet public key, `pn`, `n`) je v plaintextu, ale je vázána
  na ciphertext jako AES-GCM AAD (`_headerAad`, `session_manager.dart:624-648`)
  — manipulace s hlavičkou způsobí selhání dešifrování, i když hlavička
  sama cestuje nešifrovaně.

### Pre-key message wire format

JSON obálka (viz `session_manager.dart:43-51,233-246`):
```json
{ "v": 2, "sid": "<sha256 hex>", "t": "pk" | "m",
  "ik": "...", "ek": "...", "pkid": 3, "identityBundle": {...},  // jen "pk"
  "rk": "...", "pn": 0, "n": 0, "c": "<base64 ciphertext>" }
```
`sid = SHA-256("CallType-session-v2|<identityKey>|<ephemeralKey>")` —
`session_manager.dart:620-622`.

### Group messaging

Žádné Sender Keys — `GroupCipher.encryptForGroup` prostě zavolá
`SessionManager.encryptMessage` pro každého člena skupiny zvlášť
(per-recipient fan-out), takže náklady rostou lineárně s počtem členů
— `group_cipher.dart:15-34`.

### Seznam zařízení (multi-device)

Důvěra v další zařízení identity stojí na seznamu podepsaném primárním
zařízením; server seznam jen ukládá a podle něj směruje, podpisy neověřuje.
Kód: `src/client/calltype_core/lib/crypto/device_list.dart`,
`src/client/calltype_core/lib/devices/device_directory.dart`. Návrh:
`docs/superpowers/specs/2026-10-13-multi-device-sync-design.md`.

| Co | Definice | Zdroj v kódu |
|---|---|---|
| Podpis seznamu | Ed25519 nad `"CallType-DeviceList-v1" \|\| 0x00 \|\| přesné bajty payloadu` (UTF-8 JSON), klíč = signing klíč primárního zařízení (`ct_signing_seed`) | `device_list.dart` (`signDeviceList`, `verifyDeviceList`) |
| Souhlas zařízení | Ed25519 nad `"CallType-DeviceLink-v1" \|\| 0x00 \|\| UUID primárního (16 B) \|\| UUID companionu (16 B)`, klíč = signing klíč companionu | `device_list.dart` (`signDeviceLinkConsent`, `verifyDeviceLinkConsent`) |
| Kořen důvěry | signing klíč primárního zařízení tak, jak je připnutý v `peer_identity:<deviceId>` (TOFU, beze změny) | `device_directory.dart` (`_signingKeyOf`) |
| Ochrana proti rollbacku | `version` musí být větší než nejvyšší ověřená uložená v `known_device_lists`; znovu se kontroluje uvnitř zápisové transakce | `verifyDeviceList(minVersion)`, `DeviceDirectory._refresh` |
| Tvar payloadu | ověří se podpis nad uloženými bajty, pak parsování a porovnání s kanonickým re-encodem (jinak `malformed`); UUID jen malými písmeny; max 16 KB, max 5 companionů | `verifyDeviceList`, `_canonicalUuid` |
| Vazba souhlasu na zařízení | `consentSig` dokazuje jen to, že souhlasil klíč zapsaný v položce; zařízení se připíše identitě až po shodě `identityKey\|signingKey` s připnutými klíči (`assertListedKeys`, při zápisu seznamu i `listed_keys_mismatch`); bez připnutí selže (fail closed) | `DeviceDirectory.assertListedKeys`, `FanoutSender` |
| Odmítnutí únosu | seznam musí týkat se dotazovaného zařízení (`unrelated_list`); seznam jmenující NAŠE zařízení musí nést naše klíče (`self_not_consented`); zařízení patřící jiné identitě se nepřesune (`device_claimed_by_other_identity`) | `DeviceDirectory._refresh` |
| Obálky | šifrují se jen pro zařízení z ověřeného seznamu; server smí požadovat vynechání zařízení, ne přidání neověřeného (`server_requires_unverified_device`) | `fanout_sender.dart` |

Meze (viz též sekci 4):
- Server může aktualizaci seznamu zadržet nebo zpozdit; odebrání zařízení se
  protějšku projeví při jeho příští `device_list_stale` odpovědi nebo refreshi.
  Server nemůže přidat čtenáře.
- Protějšky i server znají počet zařízení identity.
- Webový companion drží klíče v úložišti prohlížeče (lokální DB není SQLCipher).
- Žádný cross-signing: ztracené primární zařízení seznam nezmění.
- První kontakt je TOFU jako dosud.
- `LinkOffer` / `LinkConsent` na serveru nemají rate limit (uživatel potvrzuje
  handle primárního zařízení, jde o obtěžování, ne převzetí).
- Companion, který se přeinstaluje s novými klíči, je protějšky odmítán, dokud
  se starý pin neresetuje.

## 3. Životní cyklus klíčů

| Klíč | Generování | Úložiště / platforma | Rotace | Mazání |
|---|---|---|---|---|
| Identity key pair (X25519) | jednou při prvním spuštění | `SecretStore` (abstraktní rozhraní, `secret_store.dart:12-40`); app používá `flutter_secure_storage` → Keychain (iOS) / EncryptedSharedPreferences (Android) / libsecret (Linux) — `src/client/calltype/lib/core/storage/secure_storage.dart:5-8`; bot používá `EncryptedFileStore` (AES-GCM soubor, klíč z env) — `encrypted_file_store.dart:9-22` | **žádná** rotace v kódu (nenalezeno) | nenalezeno v kódu (ztráta = nová identita, jak popisuje `key_manager.dart:12-15`) |
| Signed pre-key (X25519) | líně při prvním volání `getOrCreateSignedPreKey`, keyId natvrdo `1` | stejné `SecretStore` | **žádná** — komentář v kódu to přiznává jako budoucí hardening ("Rotation... is a future hardening step") — `key_manager.dart:170-172` | nenalezeno |
| One-time pre-keys (X25519) | dávka 100 při prvním volání `getOrCreateOneTimePreKeys` | stejné `SecretStore` | doplňování (replenish) nenalezeno v prošlém kódu crypto adresáře | mažou se při spotřebování (`consumeOneTimePreKey`, `key_manager.dart:216-229`) — ale až PO úspěšné autentizaci zprávy (`peekOneTimePreKey` používaný nejdřív, komentář `key_manager.dart:231-232`), takže padělané první zprávy klíč nezničí |
| Ed25519 signing seed | líně při prvním volání `getSignedIdentityBundle` | stejné `SecretStore`, klíč `ct_signing_seed` | žádná | nenalezeno |
| Device secret (256 b) | server při registraci, jednorázově vydán | `SecretStore` (`ct_device_secret`) | není — ztráta = nutná re-registrace (`secret_store.dart:31-33`) | nenalezeno |
| Session state (Double Ratchet) | za běhu | SQLite (drift) — `SignalSessions` tabulka, JSON blob v `sessionData` | ratchet key se otáčí při každém DH ratchet stepu (ne "rotace" v bezpečnostním smyslu, ale běžný chod protokolu) | staré relace se archivují pod `peerId:sid`; nad 16 archivovaných relací na peer se nejstarší mažou (`session_manager.dart:711-735`) |

Poznámka: replenishment one-time pre-keys (doplnění zásoby na serveru) nebyl
v souborech `core/crypto/*` nalezen — pokud existuje, je mimo prohledaný
rozsah tohoto dokumentu.

## 4. Známé meze

| Mez | Důsledek |
|---|---|
| TOFU (Trust On First Use), žádné UI pro ověření safety number | Aktivní MITM při prvním kontaktu není detekovatelný uživatelem — identity se jen "pinnou" a další změna vyhodí chybu (`session_manager.dart:390-402`), ale první kontakt nikdo neověřuje mimo pásmo. |
| Signed pre-key SE OVĚŘUJE (na rozdíl od CLAUDE.md) — viz sekci 6 | `verifyIdentityBundle` (`key_manager.dart:67-93`) kontroluje Ed25519 podpis nad identity+signedPreKey při každém příchozím/odchozím handshake — pokud podpis chybí nebo je neplatný, relace se odmítne. Zbývající mez: server podpis needeleguje, důvěra stojí čistě na klientském ověření + TOFU pinningu. |
| Chybí header encryption | Ratchet public key, `pn`, `n` cestují v plaintextu (jen AAD-vázané) — server (a kdokoliv na cestě) vidí metadata patternu komunikace v rámci relace, i když ne obsah. |
| Lokální SQLite plaintext | Drift databáze na klientovi NENÍ SQLCipher (`CLAUDE.md`, potvrzeno v `database.dart`/`tables.dart` — žádné šifrování schématu nalezeno) — zprávy a session state jsou čitelné komukoliv s přístupem k souborovému systému zařízení (mimo OS-level sandboxing). |
| Metadata viditelná serveru | Kdo komu píše, kdy, velikost zprávy — server je store-and-forward relay, ale směrovací metadata nutně vidí. |
| Business mode: auditor dešifruje firemní konverzace by design | Auditorovo zařízení je plnohodnotný člen konverzace (obdrží vlastní pairwise obálku jako kterýkoliv jiný člen) — ne "zadní vrátka" mimo protokol, ale viditelný účastník. Server kontroluje jen PŘÍTOMNOST auditorovy obálky u odeslané zprávy, ne shodu jejího obsahu s ostatními obálkami — plnou content-level garanci řeší až MLS krok 2 (KB2, `docs/superpowers/plans/2026-09-18-business-mode.md`). |
| Kanály jsou plaintext by design | `ChannelPost` je nešifrovaný text/obrázek (`CLAUDE.md` databázová tabulka), server ho čte a ukládá — jde o veřejný, ne E2E kanál. |
| Group messaging bez Sender Keys | Odesílání do skupiny stojí O(počet členů) šifrování a serverových zpráv — funkční mez, ne bezpečnostní díra, ale je to zdokumentovaný kompromis v `group_cipher.dart`. |
| Skipped-key limit (256/512) | Zprávy doručené s velkým zpožděním nebo mimo pořadí za hranicí limitu se stanou trvale nedešifrovatelnými. |
| Žádná rotace signed pre-key ani identity key | Kompromitace dlouhodobého klíče není časově omezena rotací — jen ruční re-registrace zařízení. |
| Multi-device: seznam zařízení podepisuje jen primární zařízení | Server může zadržet aktualizaci seznamu, počet zařízení je viditelný protějškům i serveru, bez cross-signingu nelze po ztrátě primárního zařízení seznam změnit. Podrobnosti v sekci 2, "Seznam zařízení". |

## 5. Mapování na doporučení NÚKIB pro kryptografické algoritmy

Text doporučení NÚKIB nebyl k dispozici v tomto prostředí — obsah ani verzi
si nevymýšlím. Druhý sloupec vychází z obecně zavedené praxe (NIST/OWASP
mainstream), ne z konkrétního znění NÚKIB dokumentu.

| Primitivum (z kódu) | V obecně doporučené moderní sadě? | Poznámka |
|---|---|---|
| X25519 (ECDH) | ano — mainstreamová moderní volba | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| Ed25519 | ano — mainstreamová moderní volba | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| AES-256-GCM | ano — mainstreamová moderní volba (AEAD) | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| SHA-256 | ano — mainstreamová moderní volba | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| HKDF-SHA256 / HMAC-SHA256 | ano — mainstreamová moderní volba | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| Argon2id (účet, 64 MiB/3 iter/paralelismus 4) | ano jako rodina, konkrétní parametry jsou pod OWASP "first choice" (47 MiB/1 iter je jiná OWASP linka — projektový komentář to zdůvodňuje vysokou entropií vstupu) | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| PBKDF2-HMAC-SHA256, 600k iterací (zálohy) | uznávaná, ale slabší než memory-hard KDF (Argon2id) proti GPU/ASIC útoku | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| HMAC-SHA1 (TURN shared-secret) | legacy protokolové omezení (RFC 5766 vyžaduje SHA-1) — týká se jen TURN autentizace, ne obsahu médií (DTLS-SRTP zůstává E2E) | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |
| SHA-256 bez stretchingu (device secret, emergency kód) | přijatelné jen pro vysokoentropické náhodné secrety (256b / 128b) — kód to zdůvodňuje, ne heslo | TODO(owner): ověřit proti aktuálnímu znění doporučení NÚKIB |

## 6. Nesoulady dokumentace a kódu

1. **Zálohy: CLAUDE.md tvrdí Argon2id, kód používá PBKDF2-HMAC-SHA256.**
   `CLAUDE.md` ("Backup encryption — independent passphrase-derived key
   (Argon2id)") neodpovídá `backup_crypto.dart:16-21`, kde je explicitně
   PBKDF2-HMAC-SHA256 s 600 000 iteracemi a komentář vysvětluje, proč ne
   Argon2id ("the `crypto` package provides it natively"). Kód vyhrává —
   dokumentace v `CLAUDE.md` je nepřesná.
2. **Signed pre-key signature verification EXISTUJE, CLAUDE.md tvrdí opak.**
   `CLAUDE.md` uvádí jako known limitation: "no signed pre-key signature
   verification (server doesn't store it)". Ve skutečnosti `registerDevice`
   posílá `signingKey`/`signature` a klient je AKTIVNĚ ověřuje:
   `KeyManager.verifyIdentityBundle` (`key_manager.dart:67-93`) se volá při
   `initiateSession` (`session_manager.dart:98`) i při zpracování pre-key
   zprávy (`session_manager.dart:294`), a bez platného podpisu relace
   selže. Je pravda, že **server** signaturu needeleguje/needeleguje
   ověření — ověření je čistě klientské, end-to-end. `CLAUDE.md`
   formulace je zastaralá; doporučuji ji opravit (mimo rozsah tohoto
   dokumentačního úkolu — jen zaznamenáno zde).
3. **CLAUDE.md "no header encryption"** — potvrzeno v kódu (sekce 4), zde
   nesoulad není.

## 7. Nálezy při revizi

Nálezy jsou zaznamenány pro info, NEOPRAVENY (mimo rozsah tohoto úkolu).

- `src/client/calltype_core/lib/crypto/signal_protocol.dart:104-149` —
  `generateIdentityKeyPair`, `generatePreKeys` a `generateSignedPreKey`
  jsou synchronní "COMPATIBILITY" metody, které generují náhodný veřejný
  klíč jako nezávislé náhodné bajty, NE jako skutečnou X25519 derivaci ze
  soukromého klíče (komentář na řádku 108-111 to sám přiznává: "the
  corresponding public key is NOT the X25519 derivation"). Pokud je
  některá z těchto metod stále volána z produkční cesty (mimo testy),
  vzniklý pár klíčů by byl kryptograficky nepoužitelný pro DH. Stojí za
  ověření, zda je live cesta (`getOrCreateIdentityKeyPair` v
  `key_manager.dart:113-130`) skutečně jediné volané místo — ta již
  správně používá `SignalProtocol.generateKeyPair()` (async, opravdové
  X25519).
- `src/client/calltype_core/lib/crypto/key_manager.dart:170-172` — signed
  pre-key nemá rotaci; dlouhodobá platnost jednoho keyId=1 zvyšuje dopad
  kompromitace soukromého klíče.
- `src/server/CallType.Api/Endpoints/AuthEndpoints.cs:73-76` — device
  secret hash je prostý `SHA-256(secret)` bez soli/pepře. Zdůvodněno
  vysokou entropií (256 b náhodný secret) — přijatelné, ale zaznamenáno
  jako odchylka od "vždy stretched hash" zvyku jinde v projektu (Argon2id
  pro účty).

## Co nebylo z kódu zjištěno

- Replenishment (doplňování) one-time pre-keys na serveru — nenalezeno v
  prohledaném rozsahu `core/crypto` + auth soubory; může existovat jinde
  (endpoint pro upload nových pre-keys) mimo zadaný seznam souborů.
- TLS terminace / HSTS — v `Program.cs` nebyl nalezen `UseHttpsRedirection`
  ani `UseHsts` v prohledané části; Azure App Service obvykle TLS
  terminuje na platformní úrovni mimo aplikační kód. Toto je **operátorem
  závislé, mimo kód** — nepotvrzeno ani vyvráceno v tomto repozitáři.
- Obsah a verze doporučení NÚKIB pro kryptografické algoritmy — dokument
  nebyl k dispozici, sloupec v sekci 5 je proto vědomě neúplný (TODO).
