# Proud S: bezpečnost a kryptografie (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů (sekce 3) a kontrakty z `2026-09-29-gap-contracts.md`. Nic nenasazuj, necommituj mimo svůj balíček, neměň řetězce `CallType-*` v `calltype_core/lib/crypto/` (doménové separátory protokolu). **Každá změna pod `src/client/calltype_core/lib/crypto/` MUSÍ ve stejném balíčku upravit `docs/security/crypto-baseline.md`** (pravidlo z `CLAUDE.md`).

**Goal:** Zavřít bezpečnostní mezery z `docs/gap-analysis-2026-09-29.md` §5 a §7: IDOR na push tokenu, doplňování one-time pre-keys (P0), bezpečnostní čísla a řízená změna identity kontaktu, PIN přes KDF s limitem pokusů, ochrana obrazovky (P1), rotace signed pre-key, úklid kryptokódu (P2) a ve vlně 2 šifrovaná lokální databáze. Vše **drátově kompatibilní** se staršími klienty a boty (`src/bots/*` sdílí `calltype_core`).

**Architecture:** Server dostane tři nové endpointy pod `/devices/{id}/…` s jedním pravidlem autorizace „`{id}` z cesty == `sub` z JWT“. Klientská logika klíčů zůstává v čistém Dartu v `calltype_core` (`KeyManager`, nový `PreKeyMaintenance`, nový `SafetyNumber`), takže ji aplikace i boty používají stejně. UI změny zámku a ochrany obrazovky jsou v aplikaci (`lib/core/auth/**`, `lib/app/session_overlay.dart`). UI bezpečnostních čísel a změny klíče dělá proud G proti API z tohoto plánu.

**Tech Stack:** .NET 10 minimal API + EF Core/Npgsql (integrační testy Testcontainers), Dart `cryptography` 2.9.0 / `crypto` 3.0.7, Flutter 3.41.x (CI), `flutter_secure_storage` 10.3.1, `local_auth` 3.0.1, nový `screen_protector` (X0), ve vlně 2 `sqlite3` 3.x build hooks (`source: sqlite3mc`).

**Zdroje:** `docs/gap-analysis-2026-09-29.md` (§5, §7, pořadí P0–P2), `docs/security/crypto-baseline.md`, `docs/superpowers/plans/2026-09-29-gap-closure-paralelni.md`, `docs/superpowers/plans/2026-09-29-gap-ops.md` (O5). Kód ověřen proti commitu `4bd18ec`.

---

## 0. Ověřený současný stav (file:line)

| # | Zjištění | Kde |
|---|---|---|
| Z1 | `PUT /devices/{id}/push-token` má jen `RequireAuthorization()`; handler vůbec nepřijímá `ClaimsPrincipal` a přepíše token **libovolného** zařízení. Komentář „only the device owner should be able to set its push token“ neplatí. | `src/server/CallType.Api/Endpoints/DeviceEndpoints.cs:36-39,258-290` |
| Z2 | Existující vzor ověření: `AccountEndpoints.CallerDeviceId(user)` + `Results.Forbid()`. | `AccountEndpoints.cs:168,215-217`, `PrivacyEndpoints.cs:59` |
| Z3 | Test `Update_push_token_for_nonexistent_device_returns_not_found` volá PUT na cizí náhodné `{id}` a čeká 404; po opravě musí čekat 403. | `src/server/CallType.Api.Tests/Endpoints/DeviceEndpointsTests.cs:391-403` |
| Z4 | `GET /turn/credentials?deviceId=` bere `deviceId` z query, ne z JWT (komentář to přiznává). Soubor vlastní proud C. | `TurnCredentialEndpoints.cs:10-12,36-49` |
| Z5 | Klient vygeneruje 100 OPK jednou (keyId 1..100), server nemá endpoint pro doplnění. Když dojdou, `GetKeyBundle` vrátí `oneTimePreKey: null` a X3DH běží bez DH4 (kód to podporuje). | `key_manager.dart:101-104,189-208`, `DeviceEndpoints.cs:208-242`, `session_manager.dart:135-143,474-496` |
| Z6 | Každý `GET /devices/{id}/key-bundle` smaže jeden OPK. Limit „api“ je 100 req/min **na volající zařízení** → jedno zařízení vyčerpá cizích 100 OPK za minutu. | `DeviceEndpoints.cs:214-227`, `Program.cs:227-238` |
| Z7 | Unikátní index `(DeviceId, KeyId)` na `OneTimePreKeys` už existuje; délka klíče se při registraci neověřuje (testy registrují 3bajtové klíče). | `AppDbContext.cs:66-80`, `DeviceEndpoints.cs:127-154`, `DeviceEndpointsTests.cs:29-30` |
| Z8 | Signed pre-key má napevno `keyId: 1`, bez rotace. Server ukládá jen poslední SPK bez id; `Device.cs:29` tvrdí „rotated periodically“, což neplatí. | `key_manager.dart:162-179`, `Models/Device.cs:29-32` |
| Z9 | Pre-key zpráva nenese id SPK příjemce. Odpovídající strana vždy použije **aktuální** SPK (`getOrCreateSignedPreKey`). Po rotaci by zprávy postavené nad starým SPK nešly dešifrovat. | `session_manager.dart:233-242,455-465` |
| Z10 | AAD hlavičky je pevné JSON pole `['v2', sid, rk, pn, n, prologue]`, prolog má pevná pole `ik, ek, pkid, identityKey, signedPreKey, signingKey, signature`. **Nové pole v obálce, které není v AAD, starší klient ignoruje.** | `session_manager.dart:624-648` |
| Z11 | Změna identity kontaktu: `_verifyPeerIdentity` hodí `StateError('Contact identity changed…')`, stejně i při nesouladu s `contacts.identityKey`. Inbox chybu jen pošle do `_errors`, zprávu nepotvrdí, takže zůstane ve frontě serveru (redelivery při každém připojení, TTL 30 dní). | `session_manager.dart:381-403`, `message_inbox_service.dart:163-166` |
| Z12 | Pin identity = `'<identityKey b64>|<signingKey b64>'` v `BackupState` pod klíčem `peer_identity:<peer>`. Změna SPK pin nemění. | `session_manager.dart:389,405-425` |
| Z13 | **V dnešní architektuře nemůže stejné `deviceId` legitimně změnit identitu.** `POST /devices` vždy založí nové `DeviceId`, jiný endpoint `IdentityKey` nemění. Změna klíče u stejného `deviceId` tedy znamená podvržený key-bundle (server/MITM) nebo chybu. Přeinstalovaný kontakt přichází jako **nový** kontakt s novým `deviceId`. | `DeviceEndpoints.cs:109-124` |
| Z14 | Existující testy čekají `throwsStateError` u změny identity. | `calltype_core/test/crypto/identity_authentication_test.dart:104,175,191` |
| Z15 | PIN: nesolený `SHA-256(pin)` hex v `ct_pin_hash`, porovnání `==`, bez limitu pokusů. Zámek se zapne při každém `paused/hidden`, timeout nejde nastavit. | `app_lock.dart:53-83,147-157`, `secure_storage.dart:29,58-65`, `session_overlay.dart:63-69` |
| Z16 | Když je aplikace zamčená, příchozí hovor neotevře obrazovku hovoru (`_callChanged` končí na `_locked`). | `session_overlay.dart:82,90` |
| Z17 | Android: `MainActivity : FlutterFragmentActivity()` bez `FLAG_SECURE`; manifest nemá `allowBackup` → výchozí `true` (auto-backup dat aplikace včetně plaintext DB). | `android/app/src/main/kotlin/com/example/calltype/MainActivity.kt`, `AndroidManifest.xml:14-18` |
| Z18 | „COMPATIBILITY“ generátory `generateIdentityKeyPair/generatePreKeys/generateSignedPreKey` vyrábějí náhodný „veřejný klíč“, který není X25519 derivací. Volají je **jen testy** (`key_manager_test.dart:14-41,244-283`). Komentář `signal_protocol.dart:17-20` („SIMPLIFIED … omits the full DH ratchet“) je zastaralý: plný Double Ratchet existuje. Zastaralá je i hlavička wire formátu `session_manager.dart:43-51` (`"v": 1`, kód posílá `v: 2` + `sid`). `isInitialized` (`:39-42`) nic nepoužívá. | `signal_protocol.dart` |
| Z19 | Device secret: server ukládá `SHA-256(secret)` pro 256bitový náhodný secret, porovnání je `FixedTimeEquals`. | `DeviceEndpoints.cs:104-105`, `AuthEndpoints.cs:73-80` |
| Z20 | DB: drift_flutter otevírá `<ApplicationDocuments>/calltype.sqlite` (na iOS se Documents zálohují do iCloudu). `SecureStorage.getOrCreateDbKey()` (`ct_db_key`) už existuje, ale nikdo ho nevolá. `pubspec.lock`: `sqlite3 3.3.2` (build hooks), `sqlite3_flutter_libs 0.6.0+eol` a tranzitivní `sqlcipher_flutter_libs 0.7.0+eol` jsou prázdné EOL balíčky. | `lib/core/storage/database.dart:14-22`, `secure_storage.dart:28,39-51`, `pubspec.yaml:41`, `pubspec.lock` |
| Z21 | `cryptography_flutter` se registruje automaticky (dartPluginClass). Nativní PBKDF2 má jen na Androidu, iOS/macOS počítá PBKDF2 v background isolate v Dartu, web přes WebCrypto (`BrowserPbkdf2`). Argon2id je v `cryptography` jen v čistém Dartu, na webu bez akcelerace. | `cryptography_flutter-2.3.4/lib/src/flutter_cryptography.dart:163-199`, `flutter/flutter_pbkdf2.dart` |

### Audit „device id z cesty/query vs JWT“ (výsledek balíčku S1)

| Endpoint | Parametr | Ověření dnes | Verdikt |
|---|---|---|---|
| `PUT /devices/{id}/push-token` | `id` | žádné | ❌ **IDOR** → S1 (nebo X0, viz rozhodnutí R1) |
| `GET /devices/{id}/key-bundle` | `id` | jen autentizace | ✅ záměr (veřejné klíče cizího zařízení); ⚠️ vyčerpání OPK (Z6) → S2 |
| `GET /devices/by-handle/{handle}` | `handle` | jen autentizace | ✅ záměr (vyhledání kontaktu) |
| `DELETE /devices/{deviceId}` | `deviceId` | `CallerDeviceId == deviceId` (`PrivacyEndpoints.cs:59`) | ✅ |
| `POST /accounts/{accountId}/devices/{deviceId}` | oba | volající == `deviceId` + `authKey` (`AccountEndpoints.cs:168-175`) | ✅ |
| `GET /accounts/{accountId}/devices` | `accountId` | `IsLinkedAsync` (`AccountEndpoints.cs:205`) | ✅ |
| `DELETE /accounts/{accountId}`, `GET …/export` | `accountId` | `IsLinkedAsync` (`PrivacyEndpoints.cs:129,224`) + `authKey` u DELETE | ✅ |
| `/accounts/{accountId}/mfa/*` | `accountId` | `IsLinkedAsync` (`MfaEndpoints.cs:53,69,124,166,191,217`) | ✅ |
| `/backups/{accountId}[/{backupId}]` | oba | `IsLinkedAsync` (`BackupEndpoints.cs:69,133,157,200`) + `backup.AccountId == accountId` (`:163,211`) | ✅ |
| `/groups/{groupId}/…`, `DELETE …/members/{deviceId}` | oba | členství / role admin (`GroupEndpoints.cs:83-91`) | ✅ (pozn.: člen nemůže sám odejít, jen admin odebírá. Nejde o IDOR, předáno G) |
| `/channels/{id}/admins/{deviceId}` | oba | role Owner (`ChannelEndpoints.cs:286-327`) | ✅ |
| `/orgs/{id}/…`, `/orgs/{id}/members/{accountId}`, `…/enrollments/{deviceId}` | všechny | `RequireAccountAsync` + `RequireOrgAdminThenStepUpAsync` (`OrganizationEndpoints.cs:184-299`) | ✅ (namátkově; S1 projde všech 12 handlerů) |
| `/orgs/{orgId}/audit/records[/count]` | `orgId` | volající == `org.AuditorDeviceId` / admin (`AuditArchiveEndpoints.cs:76-114,227-243`) | ✅ |
| `/orgs/{id}/emergency/*` | `id`, `kitId`, `drillId` | `RequireAccountAsync` (`EmergencyEndpoints.cs:333-340`) | ✅ namátkově, **[OVĚŘIT]** všech 9 handlerů v S1 |
| `GET /turn/credentials?deviceId=` | query | žádné, id se jen vloží do TURN username | ⚠️ není únik dat, ale kredenciál na cizí id → **požadavek na C** |
| Hub (`MessengerHub`) | – | odesílatel vždy z JWT (`GetCallerDeviceId`, `MessengerHub.cs:424-441`); `TypingIndicator` 1:1 na libovolné zařízení | ✅ záměr (stejně jako zprávy) |
| **Nové** `/devices/{id}/prekeys`, `/devices/{id}/signed-prekey` | `id` | `RequireSelf` | ✅ od začátku (S2) |

---

## 1. Cíl a rozsah

| Priorita | Položka | Balíček | Vlna |
|---|---|---|---|
| **P0** | Oprava IDOR `push-token` + systematický audit | S1 | 1 (případně už X0) |
| **P0** | Doplňování OPK: server (status/upload, limit vyčerpání) | S2 | 1 |
| **P0** | Doplňování OPK: klient + boty (`PreKeyMaintenance`) | S3 | 1 |
| P1 | Bezpečnostní čísla + otisk do QR pozvánky (čistá funkce) | S5 | 1 |
| P1 | API „identita kontaktu se změnila“ v `SessionManager` | S6 | 1 |
| P1 | PIN přes KDF, limit pokusů a prodleva, volitelný wipe, auto-lock timeout, migrace, rozhraní pro hovor přes zámek | S7 | 1 |
| P1 | Ochrana obrazovky (Android `FLAG_SECURE`, iOS krytí v přepínači) | S8 | 1 |
| P2 | Rotace signed pre-key (klient + server PUT, `spkid` v obálce) | S4 (server část v S2) | 1 |
| P2 | Úklid kryptokódu, rozhodnutí o device secretu, revize `crypto-baseline.md` | S9 | 1 |
| P2 | SQLCipher / SQLite3MultipleCiphers | S10 | 2 |
| P2 | Rozhodovací záznam: šifrování hlaviček, rotace identity | S11 | 2 |
| – | Postgres `SSL Mode=VerifyFull` | O5 (proud O) | 1 |

**Mimo rozsah:** UI bezpečnostních čísel a obrazovka změny klíče (G), sealed sender, Sender Keys/MLS, šifrování signalizace hovorů (C/P2), nezávislý audit (vlastník rozhodl ne), multi-device (D).

---

## 2. Rozhodnutí k potvrzení vlastníkem

**[ROZHODNUTÍ R1] Kde opravit IDOR.** Doporučeno: **v X0**, protože X0 stejně mění `UpdatePushToken` (platformy `apns-voip`) a jde o jednořádkovou P0 opravu. Jinak ji udělá S1 hned na začátku vlny 1. Důsledek jiné volby: díra zůstane otevřená do merge vlny 1.

**[ROZHODNUTÍ R2] KDF pro PIN.** Doporučeno: **PBKDF2-HMAC-SHA256 přes `cryptography` (`Pbkdf2`)**, 16B sůl, počet iterací uložený v záznamu, výchozí **200 000** (kalibrovat na cíl ≤ 500 ms na referenčním telefonu, **[OVĚŘIT]** měřením v S7). Argon2id je v `cryptography` jen v čistém Dartu (na webu pomalý, Z21). Poctivě: 4–6místný PIN má ≤ 10⁶ kombinací a žádný KDF ho offline neochrání. Skutečnou ochranou je hardwarově chráněné úložiště (Keychain/Keystore) a limit pokusů. KDF brání předpočítaným tabulkám a zdražuje hromadné zkoušení. Jiná volba (Argon2id 64 MiB): na webu jednotky sekund na každé odemčení.

**[ROZHODNUTÍ R3] Politika pokusů.** Doporučeno: pokusy 1–4 bez prodlevy, 5. → 30 s, 6. → 1 min, 7. → 5 min, 8. → 15 min, 9. a další → 1 h. **Wipe po 10 neúspěších je volitelný a ve výchozím stavu vypnutý.** Biometrie během prodlevy povolená, protože OS má vlastní limit a padá na systémový kód. Jiná volba (wipe zapnutý defaultně): riziko zničení dat hrou dítěte, což u messengeru bez automatické zálohy znamená nevratnou ztrátu historie.

**[ROZHODNUTÍ R4] Co dělá wipe.** Doporučeno: (1) best-effort `DELETE /devices/{id}` s timeoutem 3 s (server zahodí frontu a klíče, kontakty uvidí, že zařízení zmizelo), (2) zavřít a smazat lokální DB, (3) `FlutterSecureStorage.deleteAll()`, (4) obrazovka „Data vymazána, spusťte aplikaci znovu“. Jiná volba (jen lokálně): server 30 dní hromadí zprávy pro mrtvé zařízení a protistrany dál posílají.

**[ROZHODNUTÍ R5] Auto-lock.** Doporučeno: volby Ihned (výchozí, dnešní chování) / 1 min / 5 min / 15 min / 1 h. Uloženo v secure storage, ne v DB, protože zámek se musí načíst dřív, než se (ve vlně 2 šifrovaná) DB otevře.

**[ROZHODNUTÍ R6] Ochrana obrazovky.** Doporučeno: přepínač „Ochrana obrazovky“, **výchozí vypnuto**. Android: `FLAG_SECURE` (blokuje screenshoty, nahrávání obrazovky a náhled v Recents). iOS: v přepínači aplikací barevné krytí; screenshoty zablokovat nejdou. Web a desktop: přepínač se nezobrazí. Jiná volba (výchozí zapnuto): uživatelé přijdou o screenshoty a část z nich to bude hlásit jako chybu. Business organizace si ho může vynutit později (mimo rozsah).

**[ROZHODNUTÍ R7] Rotace SPK.** Doporučeno: perioda **30 dní**, vyřazené SPK držet **90 dní** (max. 4 v úložišti). 90 dní pokrývá TTL fronty 30 dní i dlouho neodpovídající iniciátory, kteří dál posílají prolog se starým SPK. Jiná volba (kratší retence): zprávy od kontaktu, který se 30+ dní neozval, přestanou jít dešifrovat.

**[ROZHODNUTÍ R8] Přijetí změněné identity.** Vzhledem k Z13 je změna klíče u stejného `deviceId` **podezřelá vždy**. Doporučeno: UI (G) ukáže varování a jako první akci nabídne „Ověřit bezpečnostní číslo“. „Přesto přijmout“ je až druhá akce s potvrzením. Zprávy od změněné identity zůstávají ve frontě serveru, dokud uživatel nerozhodne. Jiná volba (automatické přijetí jako WhatsApp): tichý MITM přes server.

**[ROZHODNUTÍ R9] Šifrovaná DB (vlna 2).** Doporučeno: **SQLite3MultipleCiphers (`source: sqlite3mc`)** na všech nativních platformách. Jeden engine, licence MIT, bez OpenSSL. Web zůstane **plaintext** s poctivým textem: klíč by ležel ve stejném úložišti prohlížeče jako DB, takže by šifrování nic nepřidalo. Jiná volba (SQLCipher community): linkuje OpenSSL na Androidu/Windows/Linuxu a obsahuje starší SQLite (`sqlite3/doc/hook.md`).

**[ROZHODNUTÍ R10] Šifrování hlaviček a rotace identity klíče.** Doporučeno: **nedělat**, zapsat jako vědomé meze (S11). Zdůvodnění je tam.

**[ROZHODNUTÍ R11] Vlastnictví `lib/app/session_overlay.dart`.** Doporučeno: vlastní **S** (logika zámku). „Hovor přes zámek“ (gap §4, P0 #4) dostane od S hotový slot a proud C dodá jen widget `LockedCallView` (stub z X0). Jiná volba: soubor vlastní C, pak S7 potřebuje sekvenci C → S nad stejným souborem.

---

## 3. Vlastnictví souborů

**Výhradně vlastní (vlna 1):**
- `src/client/calltype_core/lib/crypto/**`: `key_manager.dart`, `session_manager.dart`, `signal_protocol.dart`, nové `safety_number.dart`, `prekey_maintenance.dart`, `identity_change.dart`
- `src/client/calltype_core/lib/network/prekey_dtos.dart` (nový)
- `src/client/calltype_core/test/crypto/**` (+ nové testy)
- `src/client/calltype/lib/core/auth/**`: `app_lock.dart`, nové `pin_hasher.dart`, `data_wiper.dart`, `screen_security.dart`, `lock_policy.dart`
- `src/client/calltype/lib/app/session_overlay.dart` (R11)
- `src/client/calltype/lib/features/settings/app_lock_settings_screen.dart`
- `src/client/calltype/test/core/auth/**`, `test/app/session_overlay_*_test.dart`
- `src/server/CallType.Api/Endpoints/DeviceEndpoints.cs` (po X0)
- `src/server/CallType.Api.Tests/Endpoints/DeviceEndpointsTests.cs`, nový `PreKeyEndpointsTests.cs`
- `docs/security/**` (hlavně `crypto-baseline.md`)

**Vlna 2 navíc:** `src/client/calltype/lib/core/storage/database.dart` (opener), nový `lib/core/storage/db_encryption_migration.dart`.

**Jen připisuje (horké soubory, koordinátor merguje):**
- `calltype_core/lib/network/api_client.dart`: jen **nové** metody `getPreKeyStatus`, `uploadOneTimePreKeys`, `updateSignedPreKey` (pokud je nepřidá X0)
- `src/client/calltype/lib/core/storage/secure_storage.dart`: jen nové metody/klíče (`ct_pin_v2`, …)
- `lib/main.dart`: vytvoření `PreKeyMaintenance` + listener na připojení, `ScreenSecurity.apply()` při startu
- `lib/l10n/app_*.arb`: klíče s prefixem **`sec`**, ve všech 19 jazycích
- `src/bots/calltype_bot/lib/calltype_bot.dart` a `src/bots/jay_archiver/bin/jay_archiver.dart`: po 3–4 řádcích (spuštění `PreKeyMaintenance`). Tyto soubory jinak patří M/O, řádky přidá S po dohodě s koordinátorem.

**Jen čte:** `message_inbox_service.dart`, `chat_controller.dart`, `webrtc_manager.dart`, `router.dart`, `onboarding_controller.dart`, `Program.cs`, `AppDbContext.cs`, `Models/**`.

---

## 4. Požadavky na X0 (kontrakty)

### 4.1 Server: EF migrace (jedna společná)
| Entita | Změna | SQL (Npgsql) |
|---|---|---|
| `Device` | `public int SignedPreKeyId { get; set; } = 1;` | `"SignedPreKeyId" integer NOT NULL DEFAULT 1` |
| `Device` | `public DateTimeOffset? SignedPreKeyUpdatedAt { get; set; }` | `"SignedPreKeyUpdatedAt" timestamp with time zone NULL` |
| `Device` | oprava komentáře `Device.cs:29` („rotated periodically by the client“ → „client rotates it via PUT /devices/{id}/signed-prekey, see SignedPreKeyId“) | – |

`OneTimePreKey` beze změny (unikátní index `(DeviceId, KeyId)` už je, `AppDbContext.cs:72-74`). Konfigurace v `AppDbContext`: `entity.Property(d => d.SignedPreKeyId).HasDefaultValue(1);`.

### 4.2 Server: HTTP kontrakty (implementuje S2, X0 je zmrazí v `gap-contracts.md`)
Autorizace u všech: `{id}` musí být `sub` z JWT, jinak **403** (`Results.Forbid()`). Smazané zařízení vrací **404**. Rate limit `"api"`. Chyby mají tvar `{ "error": "<text>", "code": "<code>" }`.

`GET /devices/{id}/prekeys` → **200**
```json
{ "oneTimePreKeyCount": 37,
  "oneTimePreKeyIds": [101, 102, 140],
  "maxOneTimePreKeys": 200,
  "signedPreKeyId": 3,
  "signedPreKeyUpdatedAt": "2026-09-29T10:00:00+00:00" }
```
(`signedPreKeyUpdatedAt` je `null`, dokud zařízení nerotovalo. Místo návrhu koordinátora `/prekeys/count` vrací i seznam id, protože klient z něj pozná spotřebované klíče a může je uklidit. Jeden dotaz místo dvou.)

`POST /devices/{id}/prekeys`, request:
```json
{ "oneTimePreKeys": [ { "keyId": 101, "publicKey": "<base64, přesně 32 B>" } ] }
```
- **200** `{ "stored": 63, "total": 100 }`. Opakování se stejnými `(keyId, publicKey)` je no-op (`stored: 0`), takže je idempotentní.
- **400** `invalid_prekeys`: prázdný seznam, > 100 položek, `keyId <= 0`, duplicitní `keyId` v požadavku, neplatné base64, délka ≠ 32.
- **409** `prekey_conflict`: `keyId` už na serveru existuje s **jiným** klíčem. Nic se neuloží.
- **409** `prekey_limit`: po odečtení duplicit by celkový počet překročil 200. Nic se neuloží. Body obsahuje i `total` a `max`.

`PUT /devices/{id}/signed-prekey`, request:
```json
{ "keyId": 4, "publicKey": "<base64 32 B>", "signature": "<base64 64 B Ed25519>" }
```
Podpis je `Ed25519(signingKey, "CallType-SignedIdentity-v1\0" ‖ identityKey ‖ publicKey)`, tedy stávající `KeyManager.signedIdentityPayload` (`key_manager.dart:58-65`).
- **204**: uloženo (`SignedPreKey`, `Signature`, `SignedPreKeyId`, `SignedPreKeyUpdatedAt = now`). Stejné `keyId` + stejný klíč znovu = 204 no-op.
- **400** `invalid_signed_prekey`: délky 32/64 nebo `keyId <= 0`.
- **409** `stale_signed_prekey`: `keyId < current`, nebo `== current` s jiným klíčem. Body obsahuje `currentKeyId`.
- **409** `unsigned_device`: `Device.SigningKey == null` (legacy zařízení bez podpisu, peers by SPK neověřili).
- Server Ed25519 **neověřuje** (.NET BCL Ed25519 nemá, nechceme novou NuGet závislost). Ověřuje každý peer v `verifyIdentityBundle` a špatný podpis poškodí jen samotné zařízení.

`GET /devices/{id}/key-bundle`: odpověď **rozšířená** o `"signedPreKeyId": 3` (poslední parametr recordu `KeyBundleResponse`, výchozí 1). Starší klienti neznámé pole ignorují (`Map<String, dynamic>`).

### 4.3 Klient: drift schema v4 (to, co S potřebuje)
- `Contacts.verifiedAt` `DateTimeColumn` nullable (sémantika: čas posledního úspěšného ověření. `verified` zůstává a S6 drží obě pole konzistentní).
- `Contacts.identityKeyChangedAt` `DateTimeColumn` nullable (nastaví `acceptIdentityChange`).
- **Nic dalšího.** Piny, čekající změny identity a očekávané otisky zůstávají v existující key-value tabulce `BackupState` (klíče `peer_identity:*`, `pending_identity:*`, `peer_expected_fp:*`), stejným vzorem jako dnes (`session_manager.dart:417-424`). Nastavení zámku jsou v secure storage (R5), `AppSettings` S nepotřebuje.

### 4.4 Balíčky a platformy
| Balíček | Constraint | Platformy | Účel |
|---|---|---|---|
| `screen_protector` | `^1.5.3` **[OVĚŘIT]** build na Flutter 3.41 (pubspec: `sdk >=2.12`, `flutter >=2.5`, minSdk 21) | android, ios | S8. `no_screenshot 2.0.1` vyžaduje Flutter ≥ 3.44, proto ne. |
| `sqlite3_flutter_libs` | **odebrat** z `pubspec.yaml:41` | – | EOL prázdný balíček („update to version 3.x of package:sqlite3“). Nativní knihovnu už dodává `sqlite3` 3.x přes hooks. **[OVĚŘIT]** build všech platforem po odebrání. |
| (vlna 2) `hooks: user_defines: sqlite3: source: sqlite3mc` | v `src/client/calltype/pubspec.yaml` | android, ios, macos, windows, linux | S10, syntaxe podle `sqlite3/doc/hook.md`. Web beze změny (R9). |

Žádný nový balíček do `calltype_core` (SHA-512 je v `crypto`, PBKDF2 v `cryptography`).

### 4.5 AndroidManifest / Info.plist
- `AndroidManifest.xml` `<application>`: `android:allowBackup="false"` a `android:fullBackupContent="false"`, pro API 31+ `android:dataExtractionRules="@xml/data_extraction_rules"` se souborem, který vylučuje `database` a `sharedpref` (Z17). Důvod: auto-backup dnes vynese plaintext DB. EncryptedSharedPreferences se po obnově stejně nedají přečíst, protože klíč z Keystore se nezálohuje, a obnovené zařízení skončí v rozbitém stavu.
- Pro `screen_protector` žádná oprávnění **[OVĚŘIT]**. `NSFaceIDUsageDescription` a `USE_BIOMETRIC` už existují.

### 4.6 Rozhraní / stuby, které X0 vytvoří
- `src/client/calltype/lib/features/calls/locked_call_view.dart` (vlastník C), stub:
  ```dart
  /// Minimal call UI shown ABOVE the app lock (SessionOverlay). Implemented by stream C.
  class LockedCallView extends StatelessWidget {
    const LockedCallView({super.key});
    @override
    Widget build(BuildContext context) => const SizedBox.shrink();
  }
  ```
- `ApiClient` (pokud je X0 přidává centrálně): `Future<PreKeyStatus> getPreKeyStatus(String deviceId)`, `Future<PreKeyUploadResult> uploadOneTimePreKeys(String deviceId, List<Map<String, dynamic>> keys)`, `Future<void> updateSignedPreKey(String deviceId, {required int keyId, required String publicKey, required String signature})`, `Future<void> deleteDevice(String deviceId)` (sdílí D pro GDPR UI a S pro wipe). DTO `PreKeyStatus`/`PreKeyUploadResult` jsou v `calltype_core/lib/network/prekey_dtos.dart` (S je dodá v S3; X0 může založit prázdnou kostru).
- Veřejné signatury nových tříd v `calltype_core/lib/crypto/` (sekce 6: S5, S6), aby G mohl kódovat UI proti stubu: X0 zkopíruje signatury `SafetyNumber`, `PartyIdentity`, `SafetyNumberScanResult`, `IdentityChangedException`, `PendingIdentityChange` a metod `SessionManager` z S6 do `gap-contracts.md`. Stub tělo `throw UnimplementedError()` je přípustné.

### 4.7 Typy zpráv, hub
Žádné nové typy zpráv ani hub metody. Jediná změna na drátu je **volitelné pole `spkid` v pre-key obálce** (S4, sekce 6), které není v AAD.

### 4.8 ARB prefix
**`sec`** (např. `secLockTimeoutTitle`). Existující `lock*` a `appLock*` klíče se nepřejmenovávají.

---

## 5. Závislosti na jiných proudech

| Proud | Co S potřebuje / dává | Kontrakt |
|---|---|---|
| X0 | migrace `Device.SignedPreKeyId/UpdatedAt`, `screen_protector`, manifest, stub `LockedCallView`, zmrazené DTO | 4.1–4.6 |
| G | **G konzumuje:** `SafetyNumber` (UI porovnání + QR sken), `SessionManager.identityChanges/acceptIdentityChange/markVerified/expectIdentity`, parametr `fp` v QR pozvánce `ct://<deviceId>/<handle>?fp=<b64url 32 B>`. **[OVĚŘIT]** u G, že starší parser `ct://` snese query (jinak nová verze pozvánky). Po `acceptIdentityChange` volá G `SignalRClient.requestPendingMessages()` (`signalr_client.dart:264`), aby server doručil zadržené zprávy. | sekce 6 S5, S6 |
| M | `chat_controller.dart:336-343` (`_ensureSession`) by měl mapovat `IdentityChangedException` na stav „identita změněna“ (stejně jako `auditor_unavailable`, `:320-326`) a zobrazit banner s odkazem na G obrazovku. Inbox (`message_inbox_service.dart`) **nemusí nic měnit**: nepotvrzená zpráva zůstane ve frontě (Z11). | typ výjimky z S6 |
| C | (1) Opravit `GET /turn/credentials`: `deviceId` brát z JWT (`AccountEndpoints.CallerDeviceId`), query parametr ignorovat, ale přijímat kvůli starším klientům (Z4). (2) Implementovat `LockedCallView` (přijmout/odmítnout/zavěsit, bez navigace do aplikace). | stub 4.6, S7 krok 7 |
| N | Push nic nemění. Až bude background handler dešifrovat (pokud vůbec), musí sdílet zámek `KeyManager` (S3, „pre-key mutex“) nebo nedešifrovat mimo hlavní isolate. **[OVĚŘIT]** s N. | S3 |
| O | O5: `SSL Mode=VerifyFull` + CA pro **obě** connection stringy (`ConnectionStrings:Default` i `ConnectionStrings:Audit`, a `AuditMigrations`, pokud se nastavuje ručně). S dodá jen řádek do `crypto-baseline.md` a označí položku za uzavřenou až po O5. | `gap-ops.md` O5 |
| D (vlna 2) | Wipe (S7) používá `ApiClient.deleteDevice`. Záloha identity/sessions (D) musí počítat s tím, že po S10 je DB šifrovaná klíčem `ct_db_key`. | 4.6 |
| Koordinátor | Po S4, S5 a S6 upravit v `CLAUDE.md` odstavec „Known limitations“ (návrh textu dodá S9). S nesmí `CLAUDE.md` měnit. | S9 |

Vše jde naprogramovat proti kontraktům: server S2 nezávisle, klient S3/S4 proti JSON z 4.2 (**mocky kopírovat z kontraktu, ne z implementace**, viz poučení v `CLAUDE.md`), G proti signaturám S5/S6.

---

## 6. Balíčky práce

Pořadí uvnitř proudu (kvůli sdíleným souborům):
- **Dráha A (server):** S1 → S2
- **Dráha B (core crypto):** S3 → S6 → S4 (všechny sahají na `key_manager.dart`/`session_manager.dart`)
- **Dráha C:** S5 (nový soubor, paralelně s čímkoli)
- **Dráha D (app):** S7 → S8 (oba sahají na `app_lock_settings_screen.dart`)
- **S9** jako poslední (úklid a finální revize baseline). Vlna 2: S10, S11.

Dráhy A, B, C a D běží paralelně. Klientské S3 a S4 kódují proti kontraktu 4.2, integrační ověření proti serveru je až po S2.

---

### S1: Oprava IDOR a audit autorizace (S, vlna 1, P0)

**Cíl:** `PUT /devices/{id}/push-token` přijme jen vlastní `{id}`. Audit všech endpointů s id v cestě/query je zdokumentovaný.

**Soubory:** `DeviceEndpoints.cs`, `DeviceEndpointsTests.cs`, `docs/security/crypto-baseline.md` (nová sekce „Autorizace podle identity zařízení“ s tabulkou ze sekce 0).

**Kroky:**
1. V `DeviceEndpoints.cs` přidat helper:
   ```csharp
   /// Every /devices/{id}/... write must act on the CALLER's own device: the
   /// JWT "sub" is the only proof of which device is calling (path ids are
   /// attacker-controlled). Shared by push-token and the pre-key endpoints.
   private static IResult? RequireSelf(Guid id, ClaimsPrincipal user) =>
       AccountEndpoints.CallerDeviceId(user) == id ? null : Results.Forbid();
   ```
2. `UpdatePushToken(Guid id, UpdatePushTokenRequest request, ClaimsPrincipal user, AppDbContext db, CancellationToken ct)`: jako **první** příkaz `if (RequireSelf(id, user) is { } denied) return denied;`, ještě před validací těla, aby se neprozrazovalo, zda zařízení existuje. Opravit komentář na `:36-38`.
3. Projít handlery z tabulky auditu, které jsou označené „namátkově“ (`OrganizationEndpoints.cs` 12 handlerů, `EmergencyEndpoints.cs` 9 handlerů). Když najdeš další díru, **neopravuj ji v cizím souboru**: zapiš ji jako nález do `crypto-baseline.md` a pošli požadavek koordinátorovi.
4. `crypto-baseline.md`: nová sekce 8 „Autorizace podle identity zařízení“ (tabulka ze sekce 0 + pravidlo „path id == JWT sub“).

**Testy (Testcontainers, `DeviceEndpointsTests.cs`):**
- `Update_push_token_for_foreign_device_returns_forbidden`: A se autentizuje, PUT na id zařízení B → 403 a token B se nezmění (ověřit v DB).
- Přejmenovat a upravit `Update_push_token_for_nonexistent_device_returns_not_found` → `…_foreign_or_unknown_device_returns_forbidden` (403).
- Stávající testy fcm/apns/replace musí dál projít (volají vlastní id).

**Přijetí:** všechny testy `DeviceEndpointsTests` zelené v CI. Tabulka auditu je v baseline. Při R1 = X0 odpadá kód a zůstává krok 3–4.

**Ověření bez Dockeru:** `dotnet build src/server/CallType.Api` lokálně. `dotnet test` v hosted CI (public okno, `/gh-actions-public`) se svolením vlastníka.

---

### S2: Serverové endpointy pre-keys (M, vlna 1, P0 + P2 část SPK)

**Cíl:** Kontrakt 4.2: status/upload OPK, PUT SPK, `signedPreKeyId` v key-bundle a omezení vyčerpání OPK.

**Soubory:** `DeviceEndpoints.cs`, nový `src/server/CallType.Api.Tests/Endpoints/PreKeyEndpointsTests.cs`, `crypto-baseline.md` (§3 životní cyklus: server část).

**Kroky:**
1. Konstanty v `DeviceEndpoints` (s komentářem PROČ):
   ```csharp
   internal const int MaxOneTimePreKeysPerDevice = 200;   // 2× the client's target stock: room for one in-flight batch
   internal const int MaxOneTimePreKeysPerUpload = 100;   // bounds request size and the per-request DB work
   internal static readonly TimeSpan OtkPerRequesterWindow = TimeSpan.FromHours(1);
   ```
2. Routy v `MapDeviceEndpoints`:
   ```csharp
   app.MapGet("/devices/{id:guid}/prekeys", GetPreKeyStatus).RequireAuthorization().RequireRateLimiting("api");
   app.MapPost("/devices/{id:guid}/prekeys", UploadOneTimePreKeys).RequireAuthorization().RequireRateLimiting("api");
   app.MapPut("/devices/{id:guid}/signed-prekey", UpdateSignedPreKey).RequireAuthorization().RequireRateLimiting("api");
   ```
3. DTO (na konci souboru):
   ```csharp
   public record PreKeyStatusResponse(int OneTimePreKeyCount, int[] OneTimePreKeyIds, int MaxOneTimePreKeys,
       int SignedPreKeyId, DateTimeOffset? SignedPreKeyUpdatedAt);
   public record UploadOneTimePreKeysRequest(List<OneTimePreKeyInput>? OneTimePreKeys);
   public record UploadOneTimePreKeysResponse(int Stored, int Total);
   public record UpdateSignedPreKeyRequest(int KeyId, string? PublicKey, string? Signature);
   // KeyBundleResponse: append `int SignedPreKeyId = 1` as the LAST positional parameter.
   ```
4. `GetPreKeyStatus`: `RequireSelf`. `SELECT KeyId FROM OneTimePreKeys WHERE DeviceId = id ORDER BY KeyId`, device → `SignedPreKeyId`, `SignedPreKeyUpdatedAt`.
5. `UploadOneTimePreKeys`: `RequireSelf` → validace (400 `invalid_prekeys`) → `await using var tx = await db.Database.BeginTransactionAsync(ct)` → `SELECT 1 FROM "Devices" WHERE "DeviceId" = @id FOR UPDATE` (serializuje souběžné uploady jednoho zařízení, aby kontrola limitu nebyla TOCTOU) → načíst existující `(KeyId, PublicKey)` pro id z požadavku → shodné = duplicita, jiný klíč = 409 `prekey_conflict` → `existingCount + nové > 200` = 409 `prekey_limit` → insert nových → commit → 200 `{stored, total}`.
6. `UpdateSignedPreKey`: `RequireSelf` → validace délek → device → `SigningKey is null` = 409 `unsigned_device` → porovnání `keyId` se `SignedPreKeyId` (pravidla 4.2) → update `SignedPreKey`, `Signature`, `SignedPreKeyId`, `SignedPreKeyUpdatedAt = timeProvider.GetUtcNow()` → 204.
7. `GetKeyBundle`: doplnit parametry `ClaimsPrincipal user, IMemoryCache cache, TimeProvider clock` (obojí je už registrované, `Program.cs:89,167`). Před `DELETE … RETURNING` zkontrolovat klíč `$"otk:{caller}:{id}"`. Když existuje, OPK **nespotřebovat** a vrátit `oneTimePreKey: null`. Jinak spotřebovat a klíč uložit s expirací `OtkPerRequesterWindow`. Komentář PROČ: bez tohoto jedno autentizované zařízení vyčerpá cizí zásobu za minutu (Z6). Bundle bez OPK je bezpečně použitelný (X3DH bez DH4, `session_manager.dart:135-143`). Stav v paměti stačí díky jediné instanci (`CLAUDE.md` rozhodnutí 6).
8. Do `KeyBundleResponse` doplnit `device.SignedPreKeyId`.

**Testy (`PreKeyEndpointsTests.cs`, reálný Postgres):**
- status vlastní → 200, počet a id odpovídají registraci. Cizí id → 403 u GET/POST/PUT (tři testy).
- upload 50 nových → `stored 50`. Opakování stejného požadavku → `stored 0, total` beze změny (idempotence).
- upload se stejným `keyId` a jiným klíčem → 409 `prekey_conflict`, nic neuloženo.
- upload nad 200 → 409 `prekey_limit`, nic neuloženo. 101 položek → 400. Duplicitní `keyId` v požadavku → 400. Klíč 31 B → 400.
- dva souběžné uploady (`Task.WhenAll`) se stejnými klíči → oba 200, v DB bez duplicit.
- PUT SPK keyId 2 → 204, key-bundle vrací nový SPK, podpis a `signedPreKeyId: 2`. Znovu stejné → 204. keyId 1 → 409 `stale_signed_prekey`. Zařízení registrované bez podpisu → 409 `unsigned_device`.
- key-bundle: stejný volající 2× → druhé volání `oneTimePreKey == null` a v DB ubyl jen 1 klíč. Jiný volající → dostane OPK.
- regrese: `Get_key_bundle_returns_keys_and_consumes_one_time_key` a `Signed_bundle_and_handle_lookup_roundtrip_without_consuming_prekeys` beze změny zelené.

**Přijetí:** kontrakt 4.2 splněn bit po bitu (názvy polí camelCase ze System.Text.Json). Testy zelené v CI. `crypto-baseline.md` §3 má řádky „OPK: server max 200, upload ≤ 100, limit 1 OPK / (volající, cíl) / h“ a „SPK: `SignedPreKeyId`, PUT bez serverového ověření podpisu (zdůvodnění)“.

---

### S3: Doplňování OPK na klientu a v botech (M, vlna 1, P0)

**Cíl:** Zásoba OPK na serveru neklesne pod 25, pokud je zařízení alespoň občas online. Nikdy se nepoužije jedno `keyId` dvakrát. Lokální úložiště nebobtná.

**Soubory:** `calltype_core/lib/crypto/key_manager.dart`, nový `calltype_core/lib/crypto/prekey_maintenance.dart`, nový `calltype_core/lib/network/prekey_dtos.dart`, `api_client.dart` (jen přidat metody), `lib/main.dart` (připsat), `src/bots/calltype_bot/lib/calltype_bot.dart` a `src/bots/jay_archiver/bin/jay_archiver.dart` (připsat), testy, `crypto-baseline.md` §3.

**Úložiště (SecretStore, zpětně kompatibilní):**
- `ct_one_time_prekeys`: stejný JSON seznam. Položky nově mají navíc `createdAt` (ISO UTC) a `uploaded` (bool). Staré položky bez těchto polí se berou jako `uploaded: true`, `createdAt` = čas prvního běhu údržby (zapíše se).
- `ct_next_prekey_id`: int. Když chybí: `max(101, max(lokální keyId) + 1)`. Počáteční dávka má vždy id 1..100 (`key_manager.dart:196-203`), takže 101 je bezpečné minimum.
- `ct_prekeys_last_sync`: ISO UTC. `ct_prekeys_consumed_since_sync`: int.

**API `KeyManager` (nové, stávající metody beze změny signatury):**
```dart
static const oneTimePreKeyTarget = 100;           // server stock we top up to
static const oneTimePreKeyLowWatermark = 25;      // below this, replenish
static const oneTimePreKeyLocalRetention = Duration(days: 90); // > 30 d queue TTL + slow initiators

/// Generates [count] new pairs with fresh, never-reused keyIds, persists the
/// private halves FIRST (uploaded: false), and returns only {keyId, publicKey}.
Future<List<Map<String, dynamic>>> generateOneTimePreKeys(int count);
Future<List<Map<String, dynamic>>> pendingOneTimePreKeyUploads(); // uploaded == false, public halves only
Future<void> markOneTimePreKeysUploaded(Iterable<int> keyIds);
/// Removes local keys that the server no longer has (=> consumed) AND are older
/// than [oneTimePreKeyLocalRetention]. Never touches uploaded == false keys.
Future<int> pruneOneTimePreKeys({required Set<int> serverKeyIds, DateTime? now});
Stream<void> get oneTimePreKeyConsumed; // fires after consumeOneTimePreKey removed a key
```
- `getOrCreateOneTimePreKeys()` při prvním vytvoření nastaví `ct_next_prekey_id = 101`, `createdAt` a `uploaded: true` (registrace je nahrává).
- **Pre-key mutex:** všechny read-modify-write nad `ct_one_time_prekeys` (generate, mark, prune, `consumeOneTimePreKey`) serializovat přes interní `Future`-řetěz `_preKeyLock`. Komentář PROČ: údržba běží souběžně s inboxem a ztracený zápis by buď vrátil spotřebovaný klíč, nebo smazal právě nahraný klíč. Druhé by znamenalo, že server rozdá klíč, jehož privátní půlku nemáme.

**`PreKeyMaintenance` (čistý Dart):**
```dart
abstract interface class PreKeyApi {
  Future<PreKeyStatus> getPreKeyStatus(String deviceId);
  Future<PreKeyUploadResult> uploadOneTimePreKeys(String deviceId, List<Map<String, dynamic>> keys);
  Future<void> updateSignedPreKey(String deviceId, {required int keyId, required String publicKey, required String signature});
}

class PreKeyMaintenance {
  PreKeyMaintenance({
    required KeyManager keyManager,
    required PreKeyApi api,
    required Future<String?> Function() deviceId, // null/empty until onboarding completes
    DateTime Function() now = DateTime.now,
    Duration minInterval = const Duration(hours: 6),
    void Function(String line)? log,
  });

  /// Never throws: network/HTTP failures are logged and retried on the next trigger.
  Future<PreKeyMaintenanceReport> run({bool force = false});

  /// Re-runs (throttled) after every 10 locally consumed one-time pre-keys.
  StreamSubscription<void> attachToConsumption();

  /// Bots: periodic run.
  Timer startPeriodic(Duration every);
}

class PreKeyMaintenanceReport { final bool skipped; final int serverCount; final int uploaded; final int pruned; final bool signedPreKeyRotated; }
```
`prekey_dtos.dart`: `PreKeyStatus.fromJson` (pole přesně podle 4.2), `PreKeyUploadResult.fromJson`, výjimka `PreKeyApiException(code)` pro 409 `prekey_conflict|prekey_limit|stale_signed_prekey|unsigned_device`. `ApiClient implements PreKeyApi`: přidat tři metody a `implements` na třídu. Pokud by `implements` kolidoval s pravidlem „jen přidávat“, použije se adaptér `ApiClientPreKeyApi(ApiClient)` v `prekey_maintenance.dart`.

**Algoritmus `run()`:**
1. Bez `force`: přeskočit, když od `ct_prekeys_last_sync` uplynulo méně než `minInterval` a `consumed_since_sync < 10`.
2. `deviceId` null/prázdné → přeskočit.
3. `status = GET`.
4. Nahrát `pendingOneTimePreKeyUploads()` po dávkách ≤ 100 → `markUploaded`. `prekey_conflict` znamená kolizi id (obnovená stará data): posunout `ct_next_prekey_id` nad `max(status.oneTimePreKeyIds)`, konfliktní lokální klíče smazat, vygenerovat nové a zalogovat. `prekey_limit` → přestat nahrávat.
5. Když `count < 25`: `generateOneTimePreKeys(100 - count)` → upload → mark.
6. `pruneOneTimePreKeys(serverKeyIds: status.oneTimePreKeyIds)`.
7. SPK rotace (S4, do S4 no-op hook).
8. Zapsat `last_sync`, vynulovat `consumed_since_sync`.

**Napojení:**
- `lib/main.dart` (připsat za `sessionManager`): `final preKeys = PreKeyMaintenance(keyManager: keyManager, api: apiClient, deviceId: secureStorage.getDeviceId);` + `preKeys.attachToConsumption();` a samostatný listener na `signalRClient` (stejný vzor jako `main.dart:124-131`): při přechodu na „connected“ `unawaited(preKeys.run())`. Po onboardingu se aplikace připojí (`router.dart:100-105`), takže první běh proběhne sám.
- `calltype_bot.dart`: po `_signalR.connect()` (`:223`) `unawaited(_preKeys.run(force: true)); _preKeys.startPeriodic(const Duration(hours: 6));`. Totéž v `jay_archiver.dart` `_run` po připojení. **Auditor je příjemcem pre-key zpráv od každého člena organizace, OPK spotřebuje nejrychleji ze všech.**

**Testy (`dart test` v `calltype_core`, bez Dockeru):**
- `key_manager_prekey_test.dart`: `ct_next_prekey_id` roste monotónně i přes restart (nová instance nad stejným `InMemorySecureStorage`). Legacy úložiště (100 klíčů bez `createdAt`) → další id = 101. Prune neodstraní `uploaded: false` ani klíč mladší 90 dní. 50 paralelních `consumeOneTimePreKey` + souběžné `generateOneTimePreKeys` nic neztratí (mutex).
- `prekey_maintenance_test.dart` s falešným `PreKeyApi`, jehož JSON je **zkopírovaný z kontraktu 4.2**: count 10 → nahraje 90. Síťová chyba → report bez výjimky, klíče zůstanou `uploaded: false` a další běh je nahraje. 409 conflict → posun id. Throttling (6 h / 10 spotřebovaných).
- Integrační přes hub: rozšířit `test/crypto/session_manager_test.dart` o scénář „101 iniciátorů“: po vyčerpání prvních 100 OPK údržba doplní a 101. relace se naváže **s** OPK.
- Živé E2E (volitelné, `JAY_E2E_API`, jen lokální compose): `src/bots/jay_archiver/test/e2e` nový test „auditor doplní OPK“. Pozor na limit 10 auth volání/min (`CLAUDE.md`).

**Přijetí:** nový i legacy klient doplní zásobu. Žádné `keyId` se nepoužije dvakrát (test). `crypto-baseline.md` §3 řádek „One-time pre-keys: Rotace“ = „doplnění pod 25 na 100, údržba při připojení / po 10 spotřebách / boti à 6 h“ a odstavce „Poznámka: replenishment … nebyl nalezen“ a „Co nebylo zjištěno“ jsou smazané.

---

### S4: Rotace signed pre-key (M, vlna 1, P2)

**Cíl:** SPK se mění po 30 dnech. Zprávy postavené nad starým SPK jde dešifrovat 90 dní po jeho vyřazení. Drát zůstává kompatibilní.

**Soubory:** `key_manager.dart`, `session_manager.dart`, `prekey_maintenance.dart` (krok 7), testy, `crypto-baseline.md` (§2 wire format, §3, §4).

**Úložiště:**
- `ct_signed_prekey`: aktuální SPK, JSON jako dnes + `createdAt` (legacy bez něj → doplnit „teď“ při prvním běhu údržby, první rotace tedy za 30 dní od aktualizace).
- `ct_signed_prekey_pending`: `{keyId, publicKey, privateKey, createdAt}`, vygenerovaný a ještě nepotvrzený serverem.
- `ct_signed_prekeys_retired`: seznam `{keyId, publicKey, privateKey, retiredAt}`, max 4.

**API `KeyManager`:**
```dart
static const signedPreKeyRotationPeriod = Duration(days: 30);
static const signedPreKeyRetention = Duration(days: 90);
Future<bool> isSignedPreKeyRotationDue({DateTime? now});
/// Creates (or returns the existing) pending SPK with keyId = current + 1 and
/// its Ed25519 signature over signedIdentityPayload(identityKey, publicKey).
Future<({int keyId, String publicKey, String signature})> prepareSignedPreKeyRotation();
/// pending -> current, old current -> retired(retiredAt = now). Idempotent.
Future<void> commitSignedPreKeyRotation(int keyId);
/// Ordered candidates for the responder: [preferred?, current, pending?, ...retired newest first].
Future<List<Map<String, dynamic>>> signedPreKeyCandidates({int? preferredKeyId});
Future<int> pruneRetiredSignedPreKeys({DateTime? now});
Future<String> signSignedPreKey(String publicKeyB64); // extracted from getSignedIdentityBundle (ct_signing_seed)
```
`getSignedIdentityBundle()` podepisuje dál **aktuální** SPK (beze změny chování).

**Údržba (krok 7 z S3):** pending existuje → PUT (idempotentní) → commit. Jinak když je rotace splatná → prepare → PUT → commit. `stale_signed_prekey` (server má vyšší id, obnovená stará data) → přepsat pending na `currentKeyId + 1` a zkusit jednou znovu. `unsigned_device` → rotaci trvale vypnout (`ct_spk_rotation_disabled`). Nakonec `pruneRetiredSignedPreKeys`.

**Wire (`session_manager.dart`):**
1. `initiateSession`: když `keyBundle['signedPreKeyId'] is int`, přidat ho do mapy `pending` jako `'spkid'`. Obálka ho díky `...pending` (`:237`) ponese.
2. **`spkid` NESMÍ jít do `_headerAad`.** Prolog AAD zůstává `[ik, ek, pkid, identityKey, signedPreKey, signingKey, signature]` (`:637-645`), jinak by starší příjemce spočítal jiné AAD a zprávu zahodil. Podvržené `spkid` způsobí jen neúspěšný pokus s jiným kandidátem, protože autenticitu dál zajišťuje AEAD. Doplnit komentář PROČ.
3. `decryptMessage`: navazování relace (`:277-296`) + kroky 1–4 (`:312-351`) vyčlenit do `_decryptWithState(Map<String, dynamic> state, Map envelope, List<int> aad)` bez perzistence. Pro pre-key zprávu bez relace projít `signedPreKeyCandidates(preferredKeyId: envelope['spkid'] as int?)`: pro každého kandidáta `_establishFromPreKeyMessage(envelope, spk)` a `_decryptWithState`. `SecretBoxAuthenticationError` → další kandidát. Když selžou všichni, hodit poslední chybu. Perzistence (`:358-376`) až po úspěchu, beze změny. OPK se jen „peekuje“ (`:480-482`), takže opakované pokusy nic nespotřebují.
4. `_establishFromPreKeyMessage(envelope, Map<String, dynamic> signedPreKey)` bere SPK parametrem místo `getOrCreateSignedPreKey()` (`:455`).

**Testy:**
- A rotuje (vynucené přes `now`), B iniciuje nad **starým** bundle (bez `spkid`, tj. starý klient) → A dešifruje. B iniciuje nad novým bundle s `spkid` → A dešifruje prvním kandidátem.
- Obálka se `spkid` jde dešifrovat kódem **před** S4. Test drží v `test/crypto/fixtures/` zmrazenou kopii starého `_headerAad` a ověří, že AAD je shodné.
- Vyřazený SPK starší než 90 dní se smaže a zpráva nad ním selže `StateError`/auth chybou bez poškození relací.
- Crash mezi PUT a commit (simulace: pending zůstane) → další běh commit dokončí a zprávy nad pending SPK mezitím jdou dešifrovat.
- Bot (`calltype_bot`) testy beze změny zelené.

**Přijetí:** `crypto-baseline.md`: §2 wire format doplněn o `"spkid": 3 // volitelné, jen "pk", mimo AAD`, §3 řádek SPK (perioda 30 d, retence 90 d, max 4), §4 řádek „Žádná rotace signed pre-key…“ upraven na „Rotace SPK ano, identity key ne (S11)“, §7 nález `key_manager.dart:170-172` uzavřen.

---

### S5: Bezpečnostní čísla a otisk do QR (M, vlna 1, P1)

**Cíl:** Čistá, deterministická funkce pro safety number a QR payload. G nad ní postaví UI.

**Soubory:** nový `calltype_core/lib/crypto/safety_number.dart`, `calltype_core/test/crypto/safety_number_test.dart`, `crypto-baseline.md` (§2 inventář, §4 TOFU řádek).

**Formát v1 (nový doménový separátor, stávající `CallType-*` se nemění):**
```
fp(party) = H_5200 kde
  H_1     = SHA-512( "CallType-SafetyNumber-v1\0" ‖ identityKey(32 B) ‖ signingKey(32 B) ‖ utf8(lowercase(deviceId)) )
  H_{i+1} = SHA-512( H_i ‖ identityKey ‖ signingKey )          (celkem 5200 volání, jako Signal)
digits(party) = pro i v 0..5: uint40_be(H[5i .. 5i+5]) mod 100000, 5 číslic s nulami zleva → 30 číslic
safetyNumber  = (digitsA < digitsB) ? digitsA ‖ digitsB : digitsB ‖ digitsA   → 60 číslic, zobrazit 12 skupin po 5
qrPayload     = "jaysn:1:" ‖ b64url_nopad(fpLocal[0..32]) ‖ ":" ‖ b64url_nopad(fpRemote[0..32])
```
Proč i `signingKey`: pin identity v aplikaci je dvojice `identityKey|signingKey` (Z12) a útočník, který vymění jen podpisový klíč, musí změnit i číslo. Proč `deviceId`: identita je vázaná na zařízení a stejné klíče pod jiným id nesmí dát stejné číslo.

**API:**
```dart
class PartyIdentity {
  const PartyIdentity({required this.deviceId, required this.identityKey, required this.signingKey}); // base64 32 B each
  final String deviceId, identityKey, signingKey;
}
enum SafetyNumberScanResult { match, mismatch, unsupportedVersion, malformed }
class SafetyNumber {
  static const version = 1;
  static const iterations = 5200;
  factory SafetyNumber.compute({required PartyIdentity local, required PartyIdentity remote}); // sync, uses package:crypto sha512
  /// 32-byte per-party fingerprint; also used by the invite QR `fp` parameter.
  static Uint8List fingerprint(PartyIdentity party);
  static String fingerprintBase64Url(PartyIdentity party);
  final String digits;          // 60 digits
  List<String> get groups;      // 12 × 5
  String get qrPayload;         // shown by LOCAL
  SafetyNumberScanResult verifyScanned(String payload); // payload shown by the OTHER device
}
```
`verifyScanned`: payload od druhé strany má `local` = její otisk a `remote` = její pohled na nás. `match` platí, když `payload.local == fp(remote)` a zároveň `payload.remote == fp(local)`. Neplatné délky klíčů (≠ 32 B) → `ArgumentError`.

**Testovací vektory (spočítané referenční implementací v Pythonu `hashlib`, musí sedět bit po bitu):**
- A: `identityKey = 32×0x01`, `signingKey = 32×0x02`, `deviceId = 11111111-1111-1111-1111-111111111111`
- B: `identityKey = 32×0x03`, `signingKey = 32×0x04`, `deviceId = 22222222-2222-2222-2222-222222222222`
- `digits(A) = 916964128177812998851181192570`
- `digits(B) = 265983468515702636337461463066`
- safety number (A↔B i B↔A): `26598 34685 15702 63633 74614 63066 91696 41281 77812 99885 11811 92570`
- `fp32(A) = KdCvCxDg2aNwQfDbrKz0BWBLio04nV1jg8nE16IaSxE`, `fp32(B) = oDhiMUZdOEV1fcbK2hnW4SFbJ5HfLaAb1jQVEvQaF6E`
- QR zobrazený A: `jaysn:1:KdCvCxDg2aNwQfDbrKz0BWBLio04nV1jg8nE16IaSxE:oDhiMUZdOEV1fcbK2hnW4SFbJ5HfLaAb1jQVEvQaF6E`
- B s vyměněným `identityKey = 32×0x05` (stejný signingKey a id): `digits(B') = 710117060674059249333599436551`, safety number `71011 70606 74059 24933 35994 36551 91696 41281 77812 99885 11811 92570`

Další testy: symetrie A↔B, `verifyScanned` pro match/mismatch/`jaysn:2:`/rozbitý řetězec, velká písmena v `deviceId` dávají totéž co malá, výkon ≤ 100 ms na VM (web **[OVĚŘIT]** v S9: `dart compile js` + benchmark, případně `compute()` v UI G).

**Přijetí:** vektory sedí. `crypto-baseline.md` §2 nový řádek „Safety number: iterovaný SHA-512 ×5200, doménový separátor `CallType-SafetyNumber-v1`, 60 číslic, QR `jaysn:1`“. §4 TOFU řádek: „ověření mimo pásmo je k dispozici (UI G), první kontakt bez ověření zůstává TOFU“.

---

### S6: Řízená změna identity kontaktu (M, vlna 1, P1)

**Cíl:** Místo tichého `StateError` má UI (G) událost, perzistentní stav a akce přijmout / ověřit. Ke QR pozvánce s otiskem se váže automatické ověření.

**Soubory:** `session_manager.dart`, nový `calltype_core/lib/crypto/identity_change.dart`, `key_manager.dart` (jen `ownPartyIdentity`), testy, `crypto-baseline.md` (§4 TOFU, §7).

**Typy (`identity_change.dart`):**
```dart
enum IdentityChangeDirection { incoming, outgoing }

/// Extends StateError on purpose: existing callers and tests match on
/// StateError (identity_authentication_test.dart:104,175,191) and must keep working.
class IdentityChangedException extends StateError {
  IdentityChangedException(this.change)
      : super('Contact identity changed. Verify the contact before starting a new session.');
  final PendingIdentityChange change;
}

/// Invite-QR fingerprint did not match the server's key bundle: likely MITM.
class IdentityMismatchException extends StateError {
  IdentityMismatchException(this.peerDeviceId) : super('Contact key does not match the scanned code.');
  final String peerDeviceId;
}

class PendingIdentityChange {
  final String peerDeviceId;
  final String previousIdentityKey, previousSigningKey;   // base64
  final String newIdentityKey, newSigningKey;             // base64
  final DateTime detectedAt;                              // UTC
  final IdentityChangeDirection direction;
  Map<String, dynamic> toJson(); factory PendingIdentityChange.fromJson(Map<String, dynamic> j);
}
```

**API `SessionManager`:**
```dart
Stream<PendingIdentityChange> get identityChanges;            // broadcast
Future<PendingIdentityChange?> pendingIdentityChange(String peerDeviceId);
Future<List<PendingIdentityChange>> pendingIdentityChanges();
/// Re-pins the NEW keys, updates contacts.identityKey, sets verified=false,
/// verifiedAt=null, identityKeyChangedAt=now, deletes the ACTIVE session row
/// (address == peer; archives "peer:sid" stay so in-flight messages still
/// decrypt) and removes the pending record. Caller then requests redelivery.
Future<void> acceptIdentityChange(String peerDeviceId);
Future<void> dismissIdentityChange(String peerDeviceId);      // hide banner, keep old pin
Future<PartyIdentity?> peerIdentity(String peerDeviceId);     // from peer_identity:<peer>
Future<void> markVerified(String peerDeviceId);               // verified=true, verifiedAt=now
Future<void> clearVerified(String peerDeviceId);
/// From an invite QR `fp` parameter: the next bundle for this peer must match.
Future<void> expectIdentity(String peerDeviceId, String fingerprintBase64Url);
```
`KeyManager`: `Future<PartyIdentity> ownPartyIdentity()` (deviceId ze `SecretStore.getDeviceId()`, klíče z `getSignedIdentityBundle()`. Neprovisionované zařízení → `StateError`).

**Chování `_verifyPeerIdentity` (`:381-403`):**
1. Když existuje `peer_expected_fp:<peer>`: spočítat `SafetyNumber.fingerprintBase64Url` z bundle. Neshoda → `IdentityMismatchException` (nic nepinovat). Shoda → pokračovat a po pinnutí `markVerified` + smazat očekávání.
2. Když se pin liší (`:390`) nebo `contacts.identityKey` nesedí (`:398-401`) → sestavit `PendingIdentityChange` (směr `outgoing` z `initiateSession`, `incoming` z `decryptMessage`), **zapsat ho mimo transakci volajícího** a hodit `IdentityChangedException`.
   - **Proč mimo transakci:** `decryptMessage` běží uvnitř `_db.transaction` inboxu (`message_inbox_service.dart:84-91`) a výjimka ji vrátí zpět, takže zápis v ní by zmizel.
   - Řešení: zápis a emit spustit v `Zone.root` jako neočekávaný (`unawaited`) `Future`. Drift směruje dotaz podle zóny, takže zápis půjde mimo transakci a počká ve frontě executoru na její konec, bez deadlocku. **[OVĚŘIT]** testem nad `NativeDatabase.memory()`.
   - Zápis je idempotentní: `insertOnConflictUpdate` podle `pending_identity:<peer>`.
3. Zpráva, u které došlo ke změně, zůstává nepotvrzená ve frontě serveru (Z11). Po `acceptIdentityChange` G zavolá `requestPendingMessages()` a pre-key zpráva nové identity naváže novou relaci.

**Testy (`identity_change_test.dart`):**
- příchozí pre-key zpráva od změněné identity uvnitř `db.transaction` → výjimka typu `IdentityChangedException` (a zároveň `StateError`). Po návratu je `pending_identity` v DB a stream emitoval právě jednou.
- `acceptIdentityChange` → opakované doručení téže obálky dešifruje. `contacts.verified == false` a `identityKeyChangedAt != null`. Stará archivní relace dál dešifruje zpožděnou zprávu staré identity.
- `expectIdentity` se správným otiskem → relace + `verified = true`. Se špatným → `IdentityMismatchException` a žádný pin.
- `dismissIdentityChange` nic nepřepinuje.
- stávající `identity_authentication_test.dart` beze změny zelený.

**Přijetí:** G může kódovat proti signaturám, `crypto-baseline.md` §4 řádek TOFU popisuje nový tok a §7 poznámka o `StateError` je uzavřená.

---

### S7: PIN zámek: KDF, pokusy, wipe, timeout, migrace, hovor přes zámek (L, vlna 1, P1)

**Cíl:** Z15/Z16 podle R2–R5 a R11.

**Soubory:** `lib/core/auth/app_lock.dart`, nové `lib/core/auth/pin_hasher.dart`, `lib/core/auth/lock_policy.dart`, `lib/core/auth/data_wiper.dart`, `lib/app/session_overlay.dart`, `lib/features/settings/app_lock_settings_screen.dart`, `lib/core/storage/secure_storage.dart` (připsat), ARB (`sec*`), testy, `crypto-baseline.md` (§2 nový řádek PIN).

**Úložiště (secure storage):**
- `ct_pin_v2` = `{"v":2,"kdf":"pbkdf2-hmac-sha256","iter":200000,"salt":"<b64 16 B>","hash":"<b64 32 B>"}`
- `ct_pin_hash` (legacy SHA-256 hex). Po migraci se **přepíše sentinelem `"v2"`**, ne smaže. Starší verze aplikace (návrat na starší web build z cache) tak uvidí zapnutý zámek, ale neodemkne: fail-closed místo tichého vypnutí zámku.
- `ct_pin_failures` (int), `ct_pin_locked_until` (ISO UTC), `ct_pin_wipe_enabled` (`"true"`), `ct_lock_timeout_sec` (int, výchozí 0).

**`pin_hasher.dart`:**
```dart
class PinHasher {
  PinHasher({this.iterations = 200000, Random? random});
  final int iterations;
  /// cryptography Pbkdf2(macAlgorithm: Hmac.sha256(), iterations, bits: 256):
  /// native on Android, background isolate on iOS/macOS, WebCrypto on web.
  Future<String> createRecord(String pin);                 // JSON of ct_pin_v2
  Future<bool> verify(String pin, String recordJson);      // constant-time compare of the 32 B hash
  static bool verifyLegacy(String pin, String sha256Hex);  // constant-time
}
```
Vektory: `PBKDF2-HMAC-SHA256("1234", salt = 00 01 … 0f, 1000 it, 32 B) = IkDqKiJ1SjxGEDVu+OTXrPJa8qw9LRGGbel6i3gSxSw=`, `200000 it = UCb67joTBPxs1iyVkC1ZY0AXft5NUBiXB9OaJnIOj7o=`. Legacy `SHA-256("1234") = 03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4`.

**`lock_policy.dart`:**
```dart
/// Delay after the Nth consecutive failure (R3). Pure, unit-tested.
Duration? lockoutAfterFailures(int failures);  // 1-4 null, 5: 30 s, 6: 1 min, 7: 5 min, 8: 15 min, >=9: 1 h
const wipeAfterFailures = 10;
const autoLockTimeouts = [Duration.zero, Duration(minutes: 1), Duration(minutes: 5), Duration(minutes: 15), Duration(hours: 1)];
```

**`AppLock` (rozšíření, `verifyPin` zůstává jako obálka kvůli kompatibilitě):**
```dart
sealed class PinCheck {}
final class PinAccepted extends PinCheck {}
final class PinRejected extends PinCheck { final int failures; final int? attemptsBeforeWipe; final DateTime? lockedUntil; }
final class PinLockedOut extends PinCheck { final DateTime until; }
final class PinWiped extends PinCheck {}

Future<PinCheck> checkPin(String pin);
Future<bool> verifyPin(String pin) async => await checkPin(pin) is PinAccepted;
Future<void> recordBiometricUnlock();              // resets failures
Future<({int failures, DateTime? lockedUntil})> lockoutState();
Future<Duration> autoLockTimeout(); Future<void> setAutoLockTimeout(Duration value);
Future<bool> wipeOnFailureEnabled(); Future<void> setWipeOnFailure(bool enabled);
```
Pořadí v `checkPin` (komentář PROČ):
1. Když `now < lockedUntil` → `PinLockedOut`, KDF se vůbec nespouští.
2. **Nejdřív** zapsat `failures + 1`, až potom počítat KDF. Zabití aplikace během výpočtu tak pokus nevynuluje.
3. Ověřit v2 nebo legacy. Úspěch → `failures = 0`, smazat `lockedUntil`. U legacy navíc zapsat `ct_pin_v2` a sentinel.
4. Neúspěch → `lockedUntil = now + lockoutAfterFailures(n)`. Když je zapnutý wipe a `n >= 10` → `DataWiper.wipe()` → `PinWiped`.

`setPin` zapíše v2 + sentinel a vynuluje čítače. `removePin` smaže v2, legacy, čítače a biometrii, timeout ponechá.

**`data_wiper.dart`:**
```dart
class DataWiper {
  DataWiper({required ApiClient api, required SecureStorage storage, required AppDatabase db,
             required Future<void> Function() deleteDatabaseFiles});
  /// R4 order: best-effort server delete (3 s timeout, needs the device secret, so
  /// BEFORE clearing storage) -> db.close() -> delete DB files -> storage.deleteAll().
  Future<void> wipe();
}
```
Mazání souborů na nativních platformách: `<getApplicationDocumentsDirectory()>/calltype.sqlite` + `-wal` + `-shm` (výchozí cesta drift_flutter, Z20). Web: **[OVĚŘIT]** API drift pro smazání OPFS/IndexedDB DB (`WasmDatabase.deleteDatabase`). Když neexistuje, na webu smazat jen secure storage a hlásit, že historie v prohlížeči zůstává („vymažte data webu“).

**`session_overlay.dart`:**
1. `didChangeAppLifecycleState`: `paused/hidden` → uložit `_backgroundedAt`. Když timeout = 0, zamknout hned (dnešní chování). `resumed` → zamknout, když `now - _backgroundedAt >= timeout`. Studený start je vždy zamčený.
2. Odemykání přes `checkPin`. `PinRejected` → `secPinAttemptsBeforeWipe` (když je wipe zapnutý) nebo obecná chyba. `PinLockedOut` → pole zakázané + odpočet (`Timer.periodic` 1 s, zrušit v `dispose`).
3. Biometrie → `recordBiometricUnlock()`.
4. `PinWiped` → `SecWipedScreen` (text + na Androidu tlačítko „Zavřít“ přes `SystemNavigator.pop()`).
5. **Hovor přes zámek (R11):** když `_locked` a `_calls.state` ∈ {`ringing`, `connecting`, `connected`}, `build` vrátí `Stack` se zámkem vespod a `const LockedCallView()` (stub X0, implementuje C) navrchu. Aplikace pod zámkem se nevykreslí. Po `ended/idle` zůstane zámek. `_callChanged` dál neotvírá `/call/…`, dokud je zamčeno.
6. Chyba úložiště zůstává fail-closed (`:52-59`).

**`app_lock_settings_screen.dart`:** nové položky „Automaticky zamknout“ (výběr z `autoLockTimeouts`), „Vymazat data po 10 neúspěšných pokusech“ (přepínač, potvrzovací dialog s varováním o nevratnosti, jen při zapnutém PINu). Vypnutí PINu (`:236`) přes `checkPin`, takže se počítá do limitu.

**ARB klíče (`sec*`, všech 19 jazyků, ICU plural pro počty):**
`secLockTimeoutTitle`, `secLockTimeoutImmediately`, `secLockTimeoutMinutes` (`{count, plural, =1{After 1 minute} other{After {count} minutes}}`), `secLockTimeoutHours` (plural), `secPinAttemptsBeforeWipe` (plural), `secPinLockedOutSeconds` (plural), `secPinLockedOutMinutes` (plural), `secWipeTitle`, `secWipeSubtitle`, `secWipeConfirmTitle`, `secWipeConfirmBody`, `secWipeConfirmButton`, `secWipedTitle`, `secWipedBody`, `secWipedClose`.
Text wipe musí ve všech jazycích říct, že smazání je nevratné a bez zálohy znamená ztrátu historie.

**Testy:**
- `test/core/auth/pin_hasher_test.dart`: vektory výše. Konstantní porovnání. Record s jiným `iter` se ověří.
- `test/core/auth/app_lock_test.dart`: **přepsat** (dnes testuje jen kopii SHA-256, `app_lock_test.dart:1-60`) na skutečnou třídu přes `FlutterSecureStorage.setMockInitialValues`: migrace legacy → v2 + sentinel, prodlevy 5–9 s falešným `now`, `failures` zapsané před KDF (hasher, který hodí výjimku → čítač vzrostl), wipe po 10 volá `DataWiper` (fake), biometrie čítač nuluje.
- `test/core/auth/lock_policy_test.dart`: tabulka R3.
- `test/app/session_overlay_lock_test.dart` (s `localized_app.dart`): timeout 1 min (resume po 30 s → odemčeno, po 61 s → zamčeno), odpočet při lockoutu, příchozí hovor při zámku zobrazí `LockedCallView` a zámek zůstane, `session_overlay_call_test.dart` beze změny zelený.
- `test/l10n/*` zelené, žádný `Text('…')` literál.

**Přijetí:** R2–R5 a R11 implementované. `crypto-baseline.md` §2 nový řádek „PIN zámku: PBKDF2-HMAC-SHA256, 16 B sůl, 200k it (kalibrováno), limit pokusů R3; PIN chrání hlavně hardwarové úložiště + limit, ne KDF“. Na webu poctivá poznámka: čítač leží v úložišti prohlížeče a jde vymazat, takže je to ochrana soukromí, ne bezpečnostní hranice.

---

### S8: Ochrana obrazovky (S, vlna 1, P1)

**Cíl:** R6.

**Soubory:** nový `lib/core/auth/screen_security.dart`, `app_lock_settings_screen.dart`, `lib/main.dart` (připsat 1 řádek), ARB, testy.

```dart
/// Android: FLAG_SECURE via screen_protector (blocks screenshots, screen recording,
/// Recents thumbnail). iOS: colour cover in the app switcher (screenshots cannot be
/// blocked on iOS). Other platforms: unsupported -> the setting is hidden.
class ScreenSecurity {
  ScreenSecurity({required SecureStorage storage, TargetPlatform? platform});
  bool get isSupported;                       // android || ios, !kIsWeb
  Future<bool> isEnabled();                   // ct_screen_security == 'true', default false
  Future<void> setEnabled(bool enabled);      // persists + apply()
  Future<void> apply();                       // at startup and after toggle
}
```
Android: `ScreenProtector.protectDataLeakageOn()` / `…Off()`. iOS: `ScreenProtector.protectDataLeakageWithColor(<barva pozadí motivu, petrol #003840>)` / `…WithColorOff()`. **`preventScreenshotOn` na iOS nepoužívat** (trik se secure text fieldem, riziko rozbití layoutu, **[OVĚŘIT]**). Volání `apply()` v `main.dart` před `runApp`.

ARB: `secScreenSecurityTitle`, `secScreenSecuritySubtitleAndroid` („Blokuje snímky obrazovky a skryje obsah v přehledu aplikací“), `secScreenSecuritySubtitleIos` („Skryje obsah v přepínači aplikací“).

**Testy:** unit s fake `MethodChannel` (`screen_protector` channel name **[OVĚŘIT]** ze zdrojů balíčku): zapnutí volá správnou metodu podle platformy, web/desktop `isSupported == false` a položka v nastavení se nevykreslí (widget test).

**Přijetí:** ruční přejímka S-05 (sekce 7). Nový dokument se nezakládá, stačí řádek v §4 baseline „Ochrana obrazovky: volitelná, Android FLAG_SECURE, iOS jen přepínač aplikací, web/desktop ne“.

---

### S9: Úklid kryptokódu, device secret, finální revize baseline (S, vlna 1, P2)

**Cíl:** Z18, Z19 a konzistentní dokumentace.

**Soubory:** `signal_protocol.dart`, `session_manager.dart` (jen komentáře), `calltype_core/test/crypto/key_manager_test.dart`, `crypto-baseline.md`, návrh textu pro koordinátora.

**Kroky:**
1. Smazat `generateIdentityKeyPair`, `generatePreKeys`, `generateSignedPreKey`, `_randomBase64`, `_rng`, import `dart:math` a `isInitialized` (`signal_protocol.dart:37-42,104-149,260-267`). Nejdřív `grep -rn` přes `src/` včetně `src/bots` (dnes jen testy, Z18) a smazat skupiny testů `key_manager_test.dart:14-41,244-283`. Testy `generateSigningKeyPair/sign/verify` (`:293-345`) zůstávají.
2. `signal_protocol.dart:17-20` přepsat na pravdu: „X3DH + full Double Ratchet live in `session_manager.dart`; this class only wraps primitives. No header encryption (see crypto-baseline §4).“
3. `session_manager.dart:43-51` (dokumentace wire formátu) sjednotit se skutečností: `v: 2`, `sid`, `identityBundle`, `spkid` (S4).
4. **Device secret (Z19): nemigrovat.** Zdůvodnění do baseline §5/§7: secret je 256 b z CSPRNG. Předobraz ze `SHA-256` je nedosažitelný, sůl chrání jen nízkoentropické vstupy a pepř by nic nepřidal. Porovnání je konstantní (`AuthEndpoints.cs:79`). Migrace by bez přínosu zablokovala všechna existující zařízení (hash nejde přepočítat bez secretu). Nález v §7 přeřadit z „odchylky“ na „vědomé rozhodnutí“.
5. Postgres: do §4 baseline řádek „DB spojení: `SSL Mode=Require` bez ověření certifikátu, oprava v O5 (`gap-ops.md`)“. Uzavřít až po O5.
6. Revize baseline: aktualizovat „Ověřeno proti commitu“, projít všechny tabulky proti kódu (řádková čísla se po S3–S8 posunou), smazat „Co nebylo zjištěno → replenishment“.
7. Návrh textu pro `CLAUDE.md` (Key design decisions §2 „Known limitations“) předat koordinátorovi: „no header encryption, TOFU with optional safety-number verification (`SafetyNumber`), signed pre-key rotated every 30 days (kept 90 days), one-time pre-keys replenished below 25, Sender Keys for groups pending.“

**Testy:** `dart test` v `calltype_core` a všech třech botech zelené. `dart analyze` bez varování o nepoužitých importech.

**Přijetí:** `grep -rn "COMPATIBILITY\|generateIdentityKeyPair" src/` je prázdný. Baseline odpovídá kódu.

---

### Vlna 2 (proud S2)

#### S10: Šifrovaná lokální databáze (L, vlna 2, P2)

**Cíl:** R9: nativní platformy mají DB šifrovanou klíčem z Keychain/Keystore. Existující plaintext DB se převede bez ztráty historie a ratchet stavu.

**Soubory:** `src/client/calltype/pubspec.yaml` (`hooks.user_defines`, přes X0 vlny 2 nebo koordinátora), `lib/core/storage/database.dart`, nový `lib/core/storage/db_encryption_migration.dart`, `secure_storage.dart` (připsat), testy, `crypto-baseline.md` §2/§4, `CLAUDE.md` řádek „SQLite via drift (plaintext … not SQLCipher yet)“ (návrh pro koordinátora).

**Fakta (ověřeno ve zdrojích 2026-09-29):** `sqlite3` 3.x vybírá nativní knihovnu přes build hooks. `hooks: user_defines: sqlite3: source: sqlite3mc | sqlcipher | sqlite3` (`sqlite3.dart/sqlite3/doc/hook.md`). `sqlcipher_flutter_libs` je `0.7.0+eol` („Not used anymore, update to version 3.x of package:sqlite3“). drift_flutter 0.3.x má `DriftNativeOptions.setup` (callback nad otevřenou DB v izolátu, `drift_flutter/lib/src/native.dart:133,158`). Na webu existuje `sqlite3mc.wasm` v releasech `sqlite3.dart`, ale drift web by potřeboval vlastní worker (**[OVĚŘIT]**). R9 web neřeší.

**Kroky:**
1. `pubspec.yaml`: `hooks: user_defines: sqlite3: source: sqlite3mc`. Ověřit build android/ios/macos/windows/linux v CI (P).
2. Klíč: `SecureStorage.getOrCreateDbKey()` (existuje, `secure_storage.dart:39-51`). Pro `ct_db_key` zapisovat s `IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device)` a `MacOsOptions` ekvivalentem, aby se klíč **nemigroval v iCloud záloze** spolu s DB z `Documents` (Z20). Na Androidu stačí EncryptedSharedPreferences + `allowBackup=false` (4.5).
3. `openAppDatabase` → `DriftNativeOptions(setup: (db) { db.execute("PRAGMA hexkey = '<64 hex>';"); db.select('SELECT count(*) FROM sqlite_master'); })`. Syntaxe `hexkey` pro sqlite3mc **[OVĚŘIT]**. Druhý příkaz ověří klíč hned při otevření. Klíč se do izolátu dostane přes closure. **[OVĚŘIT]**, že jde poslat (String je sendable).
4. Migrace (`db_encryption_migration.dart`, spustit v `main.dart` před `openAppDatabase`): když existuje `calltype.sqlite` a `ct_db_encrypted != 'true'`:
   1. otevřít plaintext přes `sqlite3` přímo,
   2. `ATTACH DATABASE 'calltype.enc.sqlite' AS enc KEY …` + `SELECT sqlcipher_export('enc')`, nebo sqlite3mc `PRAGMA rekey` nad kopií (**[OVĚŘIT]**, co sqlite3mc podporuje; preferovat export do nového souboru, aby původní zůstal nedotčený do konce),
   3. ověřit `PRAGMA integrity_check` + počty řádků všech tabulek,
   4. atomicky přejmenovat (`calltype.sqlite` → `calltype.plain.bak`, `calltype.enc.sqlite` → `calltype.sqlite`),
   5. zapsat `ct_db_encrypted = 'true'`,
   6. záložní plaintext přepsat nulami a smazat.
   Crash v libovolném kroku → při dalším startu se začne znovu od plaintextu (idempotentní).
5. Nečitelná DB (ztracený `ct_db_key`, např. obnova z iCloud/Google zálohy) → přejmenovat na `calltype.unreadable-<ts>.sqlite`, začít s prázdnou DB a zobrazit `secDbResetNotice`. Relace se znovu navážou pre-key zprávami a historie je pryč. Tichá smyčka pádů není přípustná.
6. Web: beze změny. `CLAUDE.md` a baseline: „web: plaintext v úložišti prohlížeče (origin sandbox)“.
7. Boty (volitelné): `NativeDatabase(File, setup:)` s klíčem odvozeným z `BOT_STORE_KEY` přes HKDF (`info = "CallType-BotDb-v1"`). Hooks platí pro kořenový balíček bota (`src/bots/*/pubspec.yaml`), **[OVĚŘIT]** s P/O pro Docker image archivátoru.

**Testy:** migrace na Linux VM (`flutter test` s `sqlite3mc`, **[OVĚŘIT]**, že test runner hooks použije): plaintext DB s konverzací a relací → migrace → data shodná, soubor nejde otevřít bez klíče (`file is not a database`). Crash po kroku 4.2 → druhý běh doběhne. Špatný klíč → reset-notice cesta.

**Přijetí:** přejímka S-10. `crypto-baseline.md` §4 řádek „Lokální SQLite plaintext“ → „nativně šifrováno (sqlite3mc, klíč v Keychain/Keystore), web plaintext“.

#### S11: Rozhodovací záznam: šifrování hlaviček a rotace identity (S, vlna 2)

**Soubory:** `crypto-baseline.md` §4 (+ nová podsekce „Vědomě nerealizováno“).
- **Šifrování hlaviček (DR „header encryption“ varianta): nerealizovat.** Přínos: server nevidí ratchet klíč, `pn`, `n`, tedy počty zpráv a okamžiky DH kroků v relaci. Odesílatele, příjemce, čas a velikost vidí server stejně (store-and-forward). Náklad: nová verze obálky `v3` nekompatibilní se staršími klienty a boty, zkusmé dešifrování hlaviček přes současný a další header key a složitější skip-keys. Metadatově má větší cenu *sealed sender* (skrýt odesílatele před serverem), a ten je mimo rozsah. Revize: až při přechodu na MLS (Business krok 2).
- **Rotace identity klíče: nerealizovat.** Identity key je kotva TOFU a bezpečnostních čísel. Rotace by u všech kontaktů vyvolala varování „identita změněna“, nerozlišitelné od MITM (Z13), a naučila by uživatele varování odklikávat. Časové omezení kompromitace řeší rotace SPK (S4) a self-healing Double Ratchetu. Kompromitace identity = nové zařízení (nové `deviceId`), jak je dnes. Signal identity klíče také nerotuje.

---

## 7. Přejímka na zařízení (řádky pro `docs/acceptance/matrix.md`)

| Scénář | Web | Android | iOS | Windows | macOS |
|---|---|---|---|---|---|
| S-01 PIN: nastavit, zamknout, 5× špatně → prodleva 30 s s odpočtem, správný PIN odemkne | ✓ | ✓ | ✓ | ✓ | ✓ |
| S-02 Migrace PINu: build před S7 s PINem → aktualizace → starý PIN odemkne. Návrat na starší build (jen web cache) → zamčeno, neodemkne (fail-closed) | ✓ | ✓ | ✓ | – | – |
| S-03 Wipe po 10 neúspěších (zapnutý): data pryč, onboarding. Protistrana vidí, že zařízení zmizelo (zpráva nedoručena) | – | ✓ | ✓ | – | – |
| S-04 Auto-lock 1 min: návrat po 30 s bez zámku, po 70 s se zámkem. Studený start vždy se zámkem | ✓ | ✓ | ✓ | ✓ | ✓ |
| S-05 Ochrana obrazovky: Android screenshot → systémová hláška, Recents prázdné. iOS přepínač aplikací zakrytý. Vypnuto → vše jako dřív | – | ✓ | ✓ | – | – |
| S-06 Bezpečnostní čísla: dvě zařízení ukážou stejných 60 číslic. Sken QR → „ověřeno“. QR pozvánka s `fp` → kontakt rovnou ověřený (spolu s G) | ✓ | ✓ | ✓ | ✓ | ✓ |
| S-07 Příchozí hovor při zamčené aplikaci: vyzvání, přijetí přes `LockedCallView`, po zavěšení zámek (spolu s C) | – | ✓ | ✓ | ✓ | ✓ |
| S-08 Rotace SPK: vynutit rotaci (diagnostika nebo změna času). Kontakt, který měl starý bundle a byl offline, pošle první zprávu → doručí se | ✓ | ✓ | – | – | – |
| S-09 OPK: nové zařízení přijme 30 nových relací (bot skript) → `GET /devices/{id}/prekeys` ≥ 25 | ✓ | ✓ | – | – | – |
| S-10 (vlna 2) Aktualizace na šifrovanou DB: historie i relace zachované. `calltype.sqlite` z adb/Finderu nejde otevřít `sqlite3` CLI | – | ✓ | ✓ | ✓ | ✓ |

S-08 a S-09 jde částečně automatizovat živým E2E (`JAY_E2E_API`, jen lokální compose, nikdy beta, `CLAUDE.md`).

---

## 8. Rizika a otevřené otázky

1. **Trial-dešifrování SPK (S4)** zvyšuje práci na pre-key zprávu až 5× (≤ 5 kandidátů × 4 DH). Pro běžného uživatele zanedbatelné. Auditor (`jay_archiver`) u organizace se stovkami členů to zaznamená jen při navazování relací.
2. **Zápis mimo transakci v `Zone.root` (S6)** stojí na chování drift zón. Když test ukáže deadlock, alternativa je vrátit změnu přes výjimku a nechat perzistenci na listeneru streamu v UI (G). Tím se ale přesune logika do app vrstvy.
3. **Dvojí zdroj pravdy o OPK:** server maže při rozdání, klient při použití. Prune po 90 dnech může výjimečně smazat klíč, jehož pre-key zpráva přijde později (iniciátor, který 90+ dní posílá prolog bez odpovědi). Akceptováno a zdokumentováno. Opravou by byl „stale pending re-init“ na straně iniciátoru, který by šel do `chat_controller` (M).
4. **Web lock** je jen ochrana soukromí (čítač i PIN záznam jsou v úložišti prohlížeče). Musí to říkat UI i baseline.
5. **PBKDF2 na iOS** běží v Dartu v background isolate (Z21). Kalibrace 200k je odhad. Když unlock přesáhne 500 ms, snížit `iter` pro nové záznamy (formát to umožňuje), ne pod 100k.
6. **`screen_protector` 1.5.3** s Flutter 3.41 a AGP projektu nebyl ověřen buildem. Záložní varianta: 10řádkový `MethodChannel` v `MainActivity.kt` + `AppDelegate.swift`, ale ty soubory patří C/P, takže by šlo o požadavek na X0.
7. **Downgrade** po S7 (sentinel) a po S10 (šifrovaná DB) je fail-closed: starší build DB neotevře. Obchody downgrade nedovolí, web servíruje vždy nejnovější. Riziko jen u ručně instalovaných APK/MSIX.
8. **Business režim:** změna identity auditora (nové provisioning archivátoru) vyvolá u všech členů `IdentityChangedException`, pokud archivátor dostane stejné `deviceId`. Dnes nedostane (provisioning = nové zařízení + `PUT /orgs/{id}/auditor`). Ověřit s O4, že persistentní volume identity archivátoru se při redeployi nemaže.
9. **QR `fp` a starší klienti:** pokud dnešní parser `ct://` neunese query, musí G zvolit novou verzi pozvánky. **[OVĚŘIT]** u G.
10. **Ověření bez Dockeru:** serverové testy (S1, S2) poběží jen v hosted CI v public okně se svolením vlastníka. Lokálně jde `dotnet build`, `dart test` (core, boty) a `flutter test` na stroji s Flutter SDK. Toto prostředí Flutter/Dart SDK nemá.
