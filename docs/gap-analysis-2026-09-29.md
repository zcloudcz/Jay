# Analýza mezer — co Jay chybí (stav 2026-09-29)

Stav kódu na `master` (poslední commit `2bfa0c9`, 2026-09-18). Každé tvrzení je ověřené v kódu nebo v `docs/acceptance/`. Cesty aplikace jsou relativní k `src/client/calltype/`.

**Shrnutí:** Reálně běží jen **web** (https://jay.zcloud.cz) a API. Nativní aplikace se sestaví, ale žádná není podepsaná ani publikovaná a skoro nic se neotestovalo na zařízení. **Hovory fungují, jen když mají obě strany aplikaci otevřenou v popředí.** Nic nevyzvání, nepřijde push a při zamčeném telefonu hovor nedorazí. Chat umí text a soubor do 256 KiB, chybí mu většina běžných funkcí messengeru (potvrzení o přečtení, odpovědi, média, hlasovky, notifikace).

---

## 1. Platformy a distribuce

| Platforma | Build | Podpis / distribuce | Push | Stav na zařízení |
|---|---|---|---|---|
| Web | ✅ nasazen na SWA | ✅ | ❌ chybí `firebase-messaging-sw.js` a Firebase config | částečně PASS (Q01-01/02/13) |
| Android | ✅ APK | ❌ `applicationId = com.example.calltype` (`android/app/build.gradle.kts:24`), release podepsaný **debug klíčem** (`:33-38`), žádný AAB, žádný Play Console | ❌ chybí `google-services.json` a gradle plugin | vše NOT_RUN |
| iOS | ✅ unsigned; workflow `ios-testflight.yml` hotový | ❌ chybí Apple team, `DEVELOPMENT_TEAM`, entitlements (`aps-environment`), první upload NOT_RUN | ❌ APNs na serveru jen stub (`PushNotificationService.cs:168-173`), chybí `GoogleService-Info.plist` | BLOCKED |
| Windows | ✅ zip Release složky | ❌ žádný MSIX/instalátor, Authenticode ani Store | ❌ `firebase_messaging` nemá Windows implementaci → `unsupported` (`push_service.dart:126`) | NOT_RUN |
| macOS | ✅ tar.gz | ❌ ad-hoc podpis, žádná notarizace ani dmg, bundle id `com.calltype.calltype` ≠ iOS `cz.zcloud.jay` | ❌ blokováno stejně jako iOS | NOT_RUN |
| Linux | ❌ složka `linux/` neexistuje | — | — | mimo scope |

**Průřezově:**
- Na žádné platformě není Firebase config. `Firebase.initializeApp()` se volá bez options (`push_service.dart:40`), takže výsledek je všude `notConfigured`.
- Identifikátory jsou nejednotné (`com.example.calltype` / `cz.zcloud.jay` / `com.calltype.calltype`). **Sjednotit je je nutné před prvním nahráním do obchodů**, protože později už to nejde změnit.
- Verze je napevno `1.0.0+1` a `deploy.yml` build number nezvyšuje. V nastavení je verze natvrdo `'1.0.0'` (`settings_screen.dart:105-111`).
- GitHub Actions na privátním repu nestartují (billing). CI a deploy proto běží jen v krátkém public okně.
- Windows a desktop obecně: bez FCM potřebuje desktop vlastní cestu k notifikacím. Může to být tray ikona, SignalR spojení na pozadí a nativní toast. QR skener na Windows chybí (`router.dart:152-156`).

## 2. Hovory a vyzvánění — největší mezera

**Co funguje:**
- 1:1 audio a video přes WebRTC s trickle ICE.
- Zavěšení, odmítnutí, automatické „busy“, timeout 45 s, stav „nedostupný“, když je volaný offline.
- Tlačítka mikrofon, kamera a „zvuk off“.
- TURN (Cloudflare nebo coturn) a diagnostika „Force relay“.
- Firemní hovory se záznamem metadat (H1/H2).

**Co chybí:**

| Oblast | Stav | Důkaz |
|---|---|---|
| **Vyzváněcí tón, vibrace, vyzvánění u volajícího (ringback)** | ❌ žádný audio asset ani plugin, obrazovka hovoru je úplně tichá | `call_screen.dart:26-29`, `pubspec.yaml` |
| **Příchozí hovor na pozadí, po zabití aplikace nebo na zamčeném telefonu** | ❌ chybí CallKit + PushKit (iOS) i ConnectionService, full-screen intent a foreground service (Android) | `Info.plist:98-101` (jen `remote-notification`), manifest bez `FOREGROUND_SERVICE*`, `USE_FULL_SCREEN_INTENT` a `MANAGE_OWN_CALLS` |
| **Push pro hovor ze serveru** | ❌ offline volaný dostane jen `unavailable`, server žádný push neposílá | `MessengerHub.cs:289-309` |
| Zapnutý zámek aplikace (PIN) | ❌ obrazovka hovoru se neotevře, dokud uživatel aplikaci neodemkne, a volajícímu mezitím vyprší timeout | `session_overlay.dart:82,90` |
| Pokračování hovoru na pozadí (iOS) | ❌ chybí background mode `audio`/`voip` | `Info.plist` |
| Reproduktor / sluchátko / Bluetooth, senzor přiblížení | ❌ | — |
| Přepnutí kamery (přední/zadní) | ❌ `facingMode: 'user'` je napevno | `webrtc_manager.dart:329` |
| ICE restart, výměna sítě (Wi-Fi ↔ LTE), znovupřipojení SignalR během hovoru | ❌ stav `disconnected` se neobsluhuje | `webrtc_manager.dart:307-319` |
| Zmeškané hovory, historie hovorů | ❌ anonymní hovory nezanechají žádnou stopu, záznam mají jen firemní | `webrtc_manager.dart:573-598` |
| Rozlišení „obsazeno“ | ❌ volající „busy“ vidí stejně jako běžné zavěšení | `webrtc_manager.dart:435-437` |
| Hovor na více zařízeních účtu | ❌ volá se na jedno `deviceId`, chybí zpráva „přijato jinde“ | — |
| Skupinové hovory, sdílení obrazovky, systémový PiP, čekající hovor | ❌ design spec je odkládá na „future phase, SFU“ | spec :266-270 |
| Statistiky kvality (ztrátovost, RTT) | ❌ | — |
| **Chyba:** výpadek TURN (503) shodí celý hovor | 🐞 serverový komentář slibuje fallback na STUN, klient ho ale neimplementuje | `webrtc_manager.dart:265`, `TurnCredentialEndpoints.cs:53-54` |
| **Bezpečnost:** signalizace (SDP a ICE) jde přes hub v plaintextu | ⚠️ server vidí IP adresy a mohl by podvrhnout DTLS fingerprint. Komentář „encrypted-by-convention“ je zavádějící | `webrtc_manager.dart:366-371,447` |
| `/turn/credentials` neověřuje, že `deviceId` odpovídá JWT | ⚠️ | `TurnCredentialEndpoints.cs:10-12` |

Pro plnohodnotné vyzvánění je potřeba udělat všechno z tohoto seznamu:
1. Server musí posílat **push pro hovor**: VoIP push přes APNs PushKit pro iOS a vysokou prioritu přes FCM pro Android.
2. Nativní vrstva: iOS CallKit + PushKit a Android `ConnectionService` / `Telecom` nebo full-screen intent notifikace s foreground service typu `phoneCall`. Nabízí se např. `flutter_callkit_incoming`.
3. Vyzváněcí tón a ringback: assety a přehrávání.
4. Audio session a routing (sluchátko / reproduktor / BT).
5. Hovor musí jít přijmout i při zamčené aplikaci.

## 3. Zprávy a chat

Tabulka zpráv obsahuje jen sloupce id, conversationId, senderId, body, type, attachmentPath, status a čas (`calltype_core/lib/storage/tables.dart:84-121`). Pro většinu funkcí z tabulky níže proto chybí i datový model.

| Funkce | Stav |
|---|---|
| Text | ✅ (outbox, retry, deduplikace) |
| Soubory | ⚠️ jen do 256 KiB, posílané base64 uvnitř zprávy, bez náhledu. Ve firemních skupinách fan-out nad ~900 kB selže. Řešením jsou šifrované bloby v Azure. |
| Obrázky a video s náhledem | ❌ `image_picker` je v `pubspec.yaml`, ale kód ho nepoužívá |
| Hlasové zprávy | ❌ |
| Potvrzení doručení a přečtení | ❌ `AcknowledgeMessage` jen vyřadí zprávu z fronty a odesílatel vidí pouze „Odesláno“ |
| Indikátor psaní | ⚠️ hub i core ho umí, UI ho nepoužívá |
| Online / naposledy viděn | ❌ (možná záměr kvůli soukromí, bylo by dobré rozhodnout) |
| Odpověď / citace, přeposlání, úprava, smazání pro všechny | ❌ |
| Reakce | ❌ v chatu (existují jen u kanálů) |
| Zmínky, vyhledávání, připnuté a oblíbené zprávy, koncepty | ❌ |
| Mizející zprávy | ❌ (spec: post-MVP) |
| Náhledy odkazů, emoji picker, GIFy a samolepky | ❌ |
| Jméno odesílatele ve skupině | ⚠️ zobrazuje se syrové UUID zařízení (`chat_screen.dart:350-359`) |

## 4. Notifikace

- ❌ **Lokální notifikace nejsou vůbec** (chybí `flutter_local_notifications` a `onBackgroundMessage`). Server posílá data-only FCM, takže na pozadí se nic nezobrazí (`D03-push-handoff.md:36-60`).
- ❌ Ztlumení konverzace, zvuky notifikací, odpověď přímo z notifikace a počet na ikoně aplikace.
- ❌ APNs.
- Blokuje to i organizační krok: vlastník musí založit Firebase projekt (D03).

## 5. Skupiny, kontakty, identita, profil

- **Skupiny:**
  - Šifrování probíhá párově přes Double Ratchet pro každého člena zvlášť, bez Sender Keys. Na 100 členů to stačí.
  - Klient umí skupinu jen **vytvořit**. Chybí přidání a odebrání člena, opuštění skupiny, přejmenování, seznam členů a obrazovka s informacemi o skupině (server tyto operace umí).
  - Chybí pozvánky do skupiny odkazem.
- **Kontakty:**
  - ❌ Nejde je přejmenovat ani smazat. Sloupec `displayName` nic nezapisuje.
  - ❌ Blokování a nahlášení spamu (existuje jen pro kanály).
  - ❌ Odkaz `https://…/c/{handle}` ani schéma `ct://` nejsou registrované v OS (registrované je jen `calltype://channel`).
- **Ověření identity:**
  - ❌ Chybí bezpečnostní čísla a otisk v QR. Příznak `verified` nikdy nebude `true`.
  - ⚠️ Při změně klíče kontaktu klient vyhodí `StateError` a odeslání tiše selže. Chybí UI pro přijetí nebo ověření nového klíče (`session_manager.dart:390-393`).
- **Profil:** ❌ nejde nastavit vlastní jméno, avatar ani status. Uživatel je jen `CT-XXXX-XXXX`.

## 6. Více zařízení, zálohy, GDPR

- ❌ **Synchronizace zpráv mezi zařízeními jednoho účtu.** Obálky jdou vždy na jedno `deviceId`. Klient nevolá `GET /accounts/{id}/devices` a nemá obrazovku propojených zařízení.
- ⚠️ **Záloha je jen ruční** a obsahuje kontakty, konverzace a zprávy. Neobsahuje identitu, sessions, kanály, blokace ani přílohy. Obnova dává novou identitu. Na zařízeních neověřeno (NOT_RUN).
- ❌ UI pro smazání účtu nebo zařízení a pro export dat. Serverové endpointy (N09) existují.

## 7. Bezpečnost klienta a kryptografie

| Položka | Stav |
|---|---|
| SQLCipher (šifrovaná lokální DB) | ❌ plain SQLite, včetně stavu ratchetu |
| Rotace signed pre-key | ❌ napevno `keyId: 1` (`key_manager.dart:170-172`) |
| **Doplňování one-time pre-keys** | ❌ vygeneruje se 100 kusů jednou a server nemá endpoint pro dohrání dalších. Po vyčerpání nové X3DH sessions běží bez OPK. |
| Šifrování hlaviček | ❌ |
| PIN zámku | ⚠️ nesolený SHA-256 (`app_lock.dart:154-156`), bez limitu pokusů, wipe a nastavitelného timeoutu |
| Ochrana proti screenshotům a náhledu v přepínači aplikací | ❌ chybí `FLAG_SECURE` a iOS ekvivalent |
| Staré „COMPATIBILITY“ generátory klíčů | ⚠️ `signal_protocol.dart:104-149` (viz `crypto-baseline.md`) |
| Nezávislý audit kryptografie | ❌ vlastník rozhodl, že zatím ne |
| Postgres `SSL Mode=Require` bez ověření certifikátu | ⚠️ |

## 8. Provoz a infrastruktura (blokováno na vlastníkovi)

- GitHub billing: Actions na privátním repu nestartují.
- Firebase projekt (push), Apple Developer team a secrets (TestFlight).
- Beta:
  - Nespuštěný `audit-roles-upgrade-2026-09-18.sql`. Bez něj **každá změna organizace skončí HTTP 500**.
  - Dvě ruční migrace Audit DB (`AuditRecordDetails`, `OrgRequireBusinessConversations`) se musí spustit před dalším deployem.
- `jay_archiver` na betě neběží, takže se nic nearchivuje. Chybí rozhodnutí, kde poběží.
- `backup.sh` a `restore-verify.sh` nespuštěné (G2 infrastruktura = FAIL).
- Staging (N10), centrální logy a alerty (N01), SIEM export (N02) a dokumentační balík (N08) chybí.
- Jediná instance App Service: škálování potřebuje SignalR backplane.
- Ruční přejímka na zařízeních (`docs/acceptance/matrix.md`, `bots-channels.md`) je téměř celá NOT_RUN.

---

## Doporučené pořadí

**P0: aby šlo aplikaci dát lidem do ruky (mobil)**
1. Rozhodnutí vlastníka: Firebase projekt, Apple team, GitHub billing.
2. Sjednotit bundle id a applicationId, Android release keystore + AAB, první TestFlight upload.
3. Notifikace: `flutter_local_notifications`, background handler, `firebase-messaging-sw.js` pro web, APNs na serveru.
4. **Příchozí hovory a vyzvánění:** push pro hovor, CallKit/PushKit a ConnectionService (full-screen intent), vyzváněcí tón a ringback, audio routing, přijetí hovoru přes zámek aplikace.
5. Opravit fallback na STUN při výpadku TURN a obsloužit ICE restart a výměnu sítě.
6. Doplňování one-time pre-keys.

**P1: základní úroveň messengeru**
- Potvrzení doručení a přečtení, indikátor psaní v UI, odpověď / smazání / úprava.
- Obrázky s náhledem a přílohy jako šifrované bloby (odstraní limit 256 KiB a problém s fan-outem).
- Hlasové zprávy, historie hovorů a zmeškané hovory.
- Profil (jméno, avatar), správa kontaktů a skupin v UI, blokování kontaktů.
- Bezpečnostní čísla a UI pro změnu klíče.
- Ztlumení konverzací.
- PIN přes KDF s limitem pokusů, `FLAG_SECURE`.

**P2: později nebo podle poptávky**
- Více zařízení na účet (sync), SQLCipher, rotace SPK, šifrování signalizace hovorů.
- Skupinové hovory (SFU), sdílení obrazovky.
- Desktop: MSIX, notarizace, tray a notifikace. Linux.
- Mizející zprávy, vyhledávání, reakce v chatu.
- Sender Keys / MLS (krok 2 Business režimu).
