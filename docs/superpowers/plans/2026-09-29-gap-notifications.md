# Jay — proud N: notifikace a push (server + klient + desktop) (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů (sekce 3) a kontrakty X0 (sekce 4, zmrazené v `2026-09-29-gap-contracts.md`). Nic nenasazuj, nepřepínej repo na public a necommituj bez pokynu koordinátora.

**Goal:** Uživatel se dozví o nové zprávě, hovoru a zmeškaném hovoru i tehdy, když Jay neběží v popředí. Platí to pro Android, iOS, web i macOS. Na Windows a Linuxu dostane notifikaci, dokud aplikace běží, a ve vlně 2 i po zavření okna (tray). Server dál **nevidí obsah zpráv** a Google ani Apple se z pushe nedozví, kdo komu píše ani co.

**Architecture:** Server posílá dva druhy pushe. (1) **FCM HTTP v1** pro Android, web, macOS a běžné notifikace iOS. U každého druhu zprávy nastavuje prioritu, TTL a collapse key a pro iOS přidává blok `apns` s `loc-key`, takže text lokalizuje až telefon. (2) **Přímé APNs** (token `.p8`, JWT ES256, HTTP/2) jen pro **VoIP push (PushKit)** hovorů na iOS, protože ten přes FCM poslat nejde. Push nese jen `type` a u hovoru `callId` a `video`. Volitelně nese i **šifrovaný hint** `h` (AES-256-GCM klíčem zařízení), ze kterého si klient zjistí konverzaci pro ztlumení, jméno a navigaci. Google ani Apple ho nepřečtou. Odesílání běží na pozadí přes `Channel<T>` dispatcher, takže hub nečeká na FCM. Klient má jednu vrstvu `lib/core/notifications/` nad `flutter_local_notifications`, která pokrývá Android, iOS, macOS, Windows, Linux i web. Top-level background handler FCM rozesílá podle `type`: `call` a `call_cancel` jdou do handleru proudu C, `new_message` a `channel_post` zobrazí lokální notifikaci. Web má vlastní `firebase-messaging-sw.js` bez Firebase SDK.

**Tech Stack:** .NET 10 minimal API (`System.Net.Http` HTTP/2, `ECDsa`, `AesGcm`, `System.Diagnostics.Metrics`), EF Core/Npgsql, Testcontainers; Flutter 3.41.x (`.github/workflows/ci.yml:59`), `firebase_messaging` 15.x, `flutter_local_notifications` 22.x, `app_badge_plus`, `package:web`; vlna 2 `tray_manager`, `window_manager`, `launch_at_startup`.

**Vstupy:** `docs/gap-analysis-2026-09-29.md` §1, §2 (push pro hovor), §4 · `docs/superpowers/plans/2026-09-29-gap-closure-paralelni.md` · `docs/acceptance/D03-push-handoff.md` · kontrakt K04 (`docs/superpowers/plans/2026-09-16-beta-kontrakty.md`).

---

## 0. Současný stav (ověřeno v kódu)

**Server**
- `PushNotificationService.SendPushAsync(Guid)` posílá **data-only** FCM zprávu `{ message: { token, data: { type } } }` bez `android.priority`, TTL a collapse key (`src/server/CallType.Api/Services/PushNotificationService.cs:257-264`). Typy jsou jen `new_message` (výchozí, `:234`) a `channel_post` (`:218`).
- APNs je stub, který jen zaloguje (`PushNotificationService.cs:168-175`). Push kanálů se posílá jen tokenům `fcm` (`:206-211`).
- Neplatný token se maže jen u FCM 404 + `UNREGISTERED`, a to podmíněně na přesnou shodu tokenu (`PushNotificationService.cs:276-291`, `FcmResponseEvaluator` `:49-87`). Tělo odpovědi se do logu nepíše (`:270-272`).
- Hub na push **čeká** pro každého offline příjemce zvlášť: `await pushService.SendPushAsync(message.RecipientId)` (`src/server/CallType.Api/Hubs/MessengerHub.cs:187-188`). U skupiny se sto offline členy je to sto sekvenčních HTTP volání uvnitř volání odesílatele.
- Pro online příjemce se push neposílá (`MessengerHub.cs:178-186`). Když je spojení „zombie“ (iOS aplikaci uspí, ale TCP ještě žije), zpráva čeká bez pushe, dokud server spojení neukončí.
- Hovor offline příjemci: hub vrátí volajícímu `unavailable` (`MessengerHub.cs:291-309`) a push neposílá.
- `Device.PushToken` a `Device.PushPlatform` (max. 10 znaků) jsou jediné sloty (`Models/Device.cs:37-47`, `Data/AppDbContext.cs:60`). `PUT /devices/{id}/push-token` přijímá jen `fcm|apns` (`Endpoints/DeviceEndpoints.cs:258-291`, DTO `:367`). Autorizaci opravuje proud S.
- `FcmTokenProvider` bere nepojmenovaný `HttpClient` (`FcmTokenProvider.cs:146`), testy si podstrkují vlastní factory (`CallType.Api.Tests/Services/FcmTokenProviderTests.cs:56-63,194-200`).
- Throttling existuje jen pro kanály: `ChannelPushThrottle` v paměti, jedna instance (`PushNotificationService.cs:94-122`), okno `Channels:PushThrottleMinutes = 10` (`appsettings.json:35`).
- Metriky nejsou. V `src/server` se nikde nepoužívá `Meter` ani `ActivitySource`.

**Klient** (cesty relativně k `src/client/calltype/`)
- `Firebase.initializeApp()` se volá bez options (`lib/core/network/push_service.dart:40`), takže bez nativních konfiguračních souborů je výsledek `notConfigured` a na webu nefunguje vůbec.
- **Chyba:** `defaultTargetPlatform == windows || linux` → `unsupported` (`push_service.dart:126-130`) platí i na **webu** v prohlížeči na Windows a Linuxu, protože chybí `!kIsWeb`.
- Chybí `FirebaseMessaging.onBackgroundMessage`, `getInitialMessage()` i lokální notifikace (`pubspec.yaml` nemá `flutter_local_notifications`). Token se registruje vždy jako `platform: 'fcm'` (`push_service.dart:203-210`).
- `PushService` se vytváří jen tehdy, když `deviceId` existuje už při startu (`lib/main.dart:142-152`). Po onboardingu se proto push nezaregistruje. `onRegistered` jen připojí SignalR (`lib/app/router.dart:100-107`). Callbacky `onMessageReceived` a `onNotificationOpened` nikdo nepředává (`main.dart:143-151`).
- Routa konverzace je **`/chats/:id`** (`router.dart:113-139`), ne `/chat/:id`. Web používá hash strategii (`usePathUrlStrategy` se nikde nevolá), takže URL je `/#/chats/<id>`.
- Příchozí zprávy dešifruje a ukládá `MessageInboxService` a vystavuje je přes `persistedMessages` (`lib/features/chat/message_inbox_service.dart:45-48,164`). ID konverzace je `groupId ?? senderId` (`:69`). `call-event` nezvyšuje unread (`:143-148`).
- Otevření chatu nastaví `unreadCount = 0` (`lib/features/chat/chat_controller.dart:176-180`).
- Zámek aplikace je overlay nad routerem (`lib/app/session_overlay.dart`). Aktuální routu čte přes `router.routerDelegate.currentConfiguration.uri.path` (`:97`), stejně může postupovat i navigace z notifikace.
- `SecureStorage` má obecné `read/write/delete` (`lib/core/storage/secure_storage.dart`) a použije se pro klíč push hintu.
- ARB zatím nemá žádný klíč `notif*`. Pro vyzvánění lze znovu použít `callIncomingVoice` a `callIncomingVideo` (`lib/l10n/app_en.arb:34-35`).
- Web: `web/firebase-messaging-sw.js` neexistuje, `web/staticwebapp.config.json` nemá hlavičky pro service worker a drift běží jako Web Worker `drift_worker.js`, ne jako service worker.
- Android: `POST_NOTIFICATIONS` je deklarované (`android/app/src/main/AndroidManifest.xml:10`), chybí receiver akcí notifikací a malá monochromatická ikona. `applicationId` je `com.example.calltype` a opravuje ho proud P.
- iOS: `UIBackgroundModes` obsahuje jen `remote-notification` (`ios/Runner/Info.plist:98-101`). V bundlu nejsou `Localizable.strings` a `AppDelegate.swift` neregistruje delegáta `UNUserNotificationCenter`.

---

## 1. Cíl a rozsah

| Priorita | In scope |
| --- | --- |
| **P0** | FCM payload s prioritou, TTL a collapse key podle druhu zprávy. Odesílání pushe mimo hub (dispatcher). Přímý APNs klient pro VoIP. `SendCallPushAsync` a `SendCallCancelPushAsync` (kontrakt d). Mazání neplatných tokenů u FCM i APNs. Oprava `kIsWeb`. Firebase options z `--dart-define`. Background handler s dispatchem `call` do proudu C. Lokální notifikace (Android kanály, iOS/macOS, Windows, Linux, web) pro nové zprávy a zmeškaný hovor. Klepnutí otevře `/chats/:id` nebo `/chats`. Registrace pushe po onboardingu. `web/firebase-messaging-sw.js`. iOS/macOS `Localizable.strings` pro `loc-key`. Metriky a logy. Dokumentace D03 a release-builds. |
| **P1** | Šifrovaný hint `h` (navigace na konverzaci, jméno odesílatele, ztlumení i v background handleru). Respektování `Conversations.mutedUntil`. Nastavení soukromí náhledu (`nameAndText`/`nameOnly`/`hidden`). Obrazovka nastavení notifikací a testovací push `POST /push/test`. Počet nepřečtených na ikoně. Akce „Odpovědět“ a „Označit jako přečtené“ (s otevřením aplikace). Opakovaný push pro nepotvrzené doručení („zombie“ spojení). Reconnect při návratu do popředí. Coalescing push zpráv. |
| **P2** (vlna 2) | **N2 desktop:** tray, běh na pozadí po zavření okna, spuštění po přihlášení, badge na hlavním panelu Windows. Odpověď z notifikace bez otevření aplikace (Android). iOS Notification Service Extension (jméno a ztlumení i u zabité aplikace). Spike stažení a dešifrování zpráv přímo v background isolate. |
| **Out** | Obsah zprávy v pushi (nikdy). Server-side seznam ztlumených chatů (viz R9). Vlastní zvuky notifikací (vybírají se v systémovém nastavení kanálu, assety zvuků má proud C). Vyzváněcí UI, CallKit, ConnectionService a full-screen intent (proud C). Přepínač ztlumení v UI chatu (proud M). Firebase projekt, Apple klíč `.p8` a secrets (vlastník a proud O). Podpis, bundle id, pbxproj a CI (proud P). |

---

## 2. Rozhodnutí k potvrzení vlastníkem

**[ROZHODNUTÍ R1] Jak doručovat push na iOS.** Doporučení: **hybrid.** Běžné notifikace (zprávy, zmeškaný hovor, test) jdou přes **FCM**, které je doručí přes APNs. Klient už dnes registruje FCM token i na iOS (`push_service.dart:209`) a FCM v1 umí blok `apns` s `loc-key`, `apns-collapse-id` a `apns-push-type`. **Přímé APNs** se použije jen pro **VoIP push (PushKit)**, protože VoIP push přes FCM poslat nejde. APNs klient se napíše obecně (typy `alert`, `background`, `voip`), takže pozdější přechod na čisté APNs znamená jen změnu registrace na klientovi.
Důsledek jiné volby (vše přímo přes APNs): Google by neviděl metadata iOS pushů. Klient by ale potřeboval nativní kód pro APNs device token (`AppDelegate.swift` patří proudu C) a na iOS by se nepoužil `firebase_messaging`. To znamená víc práce a riziko kolize s proudem C.

**[ROZHODNUTÍ R2] Co push obsahuje.** Doporučení: **`type` plus šifrovaný hint `h`.** `h` je AES-256-GCM pod klíčem `PushKey`, který vygeneruje klient a pošle ho s tokenem. Uvnitř je `{c: conversationId, s: senderId, m: messageId}`. Server tyto údaje zná tak jako tak, Google a Apple je nepřečtou. Díky hintu může klient v background handleru na Androidu respektovat ztlumení, ukázat „Nová zpráva od Jany“ a po klepnutí otevřít správný chat. Varianta bez hintu: klepnutí otevře jen seznam chatů, ztlumení a jméno fungují jen pro notifikace, které vytvořila běžící aplikace. Varianta s ID konverzace v čitelném tvaru je **zamítnutá**, protože by Google a Apple viděli sociální graf.

**[ROZHODNUTÍ R3] Výchozí náhled obsahu v notifikaci.** Doporučení: **`nameAndText`** (jméno a text), stejně jako Signal a WhatsApp. Na zamčeném displeji skrývá obsah OS: iOS má výchozí „Náhledy: když je odemčeno“ a Android dostane `visibility: private`. Volba `nameOnly` nebo `hidden` je v nastavení. Důsledek jiné výchozí volby (`hidden`): maximální soukromí, ale horší UX a vyšší riziko, že uživatel přehlédne důležitou zprávu. Upozornění: text zprávy se nikdy nedostane do **pushe**. Náhled `nameAndText` je možný jen u notifikací, které vytvoří běžící aplikace po dešifrování.

**[ROZHODNUTÍ R4] Kde je Firebase konfigurace.** Doporučení: **`--dart-define-from-file`** (klíče viz sekce 4.9). Kód sestaví `FirebaseOptions` sám a bez hodnot vrátí `notConfigured` bez výjimky. Mechanismus je stejný jako u `API_BASE_URL` (`main.dart:46-49`) a funguje stejně na Androidu, iOS, macOS i webu. Hodnoty dodá proud P z GitHub vars. Alternativa: `flutterfire configure` vygeneruje `lib/firebase_options.dart` a ten se commitne. Hodnoty jsou sice veřejné, ale pak se v repu míchají konfigurace prostředí (beta a produkce) a build bez souboru neprojde.

**[ROZHODNUTÍ R5] Service worker na webu.** Doporučení: **`firebase-messaging-sw.js` bez Firebase SDK.** Worker jen obslouží událost `push` (payload FCM je JSON s polem `data`), zobrazí notifikaci a zpracuje `notificationclick`. Nepotřebuje konfiguraci, skripty třetích stran ani verzi SDK a stačí, že existuje na cestě, kterou `getToken` registruje **[OVĚŘIT na reálném FCM webpush, že `event.data.json()` obsahuje `data`]**. Záloha: `importScripts` compat SDK z gstatic se zafixovanou verzí a `firebase-config.js` generovaným proudem P.

**[ROZHODNUTÍ R6] Push kanálů na iOS.** Doporučení: **tichý background push** (`content-available: 1`, `apns-priority: 5`). Aplikace se probudí, stáhne kanály a zobrazí lokální notifikaci s nízkou prioritou, pokud ji má uživatel zapnutou. Když uživatel aplikaci zabije, nepřijde nic. Pro obsah bez naléhavosti to stačí a server nemusí znát nastavení uživatele. Alternativa: viditelný alert `loc-key` „Nové příspěvky v kanálech“ s `interruption-level: passive`. Ten přijde vždy, ale nejde vypnout v aplikaci, jen v systému.

**[ROZHODNUTÍ R7] Akce „Odpovědět“ a „Označit jako přečtené“.** Doporučení ve vlně 1 (P1): akce **otevře aplikaci** (Android `showsUserInterface: true`, iOS `.foreground`) a hlavní isolate pak odešle odpověď nebo označí chat. Odeslání přímo z background isolate je P2 a potřebuje (a) sdílení stavu ratchetu mezi isolaty a (b) druhé spojení s hubem, které by ale nahradilo záznam hlavního spojení v `OnlineDevices` (`MessengerHub.cs:44,53`). Řešením je P2 balíček N15.

**[ROZHODNUTÍ R8] Počet na ikoně aplikace.** Doporučení: badge = součet `unreadCount` **neztlumených** konverzací (stejně jako WhatsApp). Kanály se nepočítají, mají vlastní počítadlo v záložce Updates.

**[ROZHODNUTÍ R9] Ztlumený chat na iOS, když aplikace neběží.** Doporučení: **přijmout a zdokumentovat.** Obecný push „Nová zpráva“ přijde na iOS i ze ztlumeného chatu, dokud nebude hotová NSE (N14, P2). Coalescing (R10) omezí počet. Alternativa: server-side seznam ztlumení (`DevicePushMute`). Znamenal by nová metadata na serveru, novou entitu a endpoint, a proto ho nedoporučuji.

**[ROZHODNUTÍ R10] Coalescing push zpráv.** Doporučení: nejvýš **1 push zprávy na zařízení za 15 s** (`Push:MessageCoalesceSeconds`). Collapse key `jay_msg` zajistí, že offline zařízení dostane jen poslední push. Hovory se neomezují nikdy a kanály dál podle `Channels:PushThrottleMinutes`.

**[ROZHODNUTÍ R11] Desktop (vlna 2).** Doporučení: na Windows a Linuxu zavření okna ve výchozím stavu **skryje aplikaci do trayi**. Při prvním zavření to aplikace jednou oznámí a volbu jde vypnout v nastavení. Bez toho by desktop nedostal žádnou notifikaci. „Spouštět po přihlášení“ je ve výchozím stavu **vypnuté**. macOS se zavřením posledního okna neukončuje, to je standard.

---

## 3. Vlastnictví souborů

**Výhradně vlastní (N)**
- Server: `src/server/CallType.Api/Services/PushNotificationService.cs`, `Services/FcmTokenProvider.cs`, nová složka `Services/Push/**`, nový `Endpoints/PushEndpoints.cs`.
- Serverové testy (nové nebo převzaté): `CallType.Api.Tests/Services/PushNotificationServiceTests.cs`, `FcmResponseEvaluatorTests.cs`, `FcmTokenProviderTests.cs`, nové `Services/Push/*Tests.cs`, `Endpoints/PushEndpointsTests.cs`, `TestFixtures/FakePushHttpHandler.cs`.
- Klient: `lib/core/network/push_service.dart`, `lib/core/notifications/**`, `lib/features/settings/notification_settings_screen.dart`, `web/firebase-messaging-sw.js`, `tool/gen_push_strings.dart` (nová složka `tool/`), vygenerované `ios/Runner/<lang>.lproj/Localizable.strings` a `macos/Runner/<lang>.lproj/Localizable.strings` (19 jazyků), `android/app/src/main/res/drawable/ic_stat_jay.xml` (nový soubor, P o něm ví).
- Klientské testy: `test/core/network/push_service_test.dart` (+ `.mocks.dart`), `test/core/notifications/**`, `test/features/settings/notification_settings_screen_test.dart`, `test/web/firebase_sw_strings_test.dart`, `test/tool/gen_push_strings_test.dart`.
- Dokumentace: `docs/acceptance/D03-push-handoff.md`, sekce „Firebase / push configuration (K04)“ v `docs/acceptance/release-builds.md`.

**Jen připisuje (horké soubory, merguje koordinátor)**
- `lib/main.dart`: registrace `FirebaseMessaging.onBackgroundMessage`, vytvoření `NotificationService` a jeho provider (nahrazuje blok `main.dart:138-152`).
- `lib/app/router.dart`: routa `/settings/notifications` a jeden řádek v `onRegistered` (`:100-107`).
- `lib/features/settings/settings_screen.dart`: dlaždice „Notifikace“.
- `lib/l10n/app_*.arb`: klíče s prefixem `notif`, ve všech 19 souborech.
- `calltype_core/lib/network/api_client.dart`: nové metody `registerPushToken`, `deletePushToken`, `sendTestPush`. Stávající `updatePushToken` (`:242-251`) zůstává beze změny.
- `src/server/CallType.Api/Program.cs`: registrace DI a `app.MapPushEndpoints()`.
- `src/server/CallType.Api/appsettings.json`: rozšíření sekce `Push`.
- `web/staticwebapp.config.json`: hlavička `Cache-Control: no-cache` pro `/firebase-messaging-sw.js`.
- `CLAUDE.md`: návrh textu pro odstavec „Push notifications (FCM)“. Vloží ho koordinátor.

**Jen čte**
- `Hubs/MessengerHub.cs` (C), `Endpoints/DeviceEndpoints.cs` (S), `Endpoints/PrivacyEndpoints.cs`, `Models/Device.cs` a `AppDbContext.cs` (X0).
- `lib/features/chat/message_inbox_service.dart` a `chat_controller.dart` (M), `calltype_core/lib/storage/{tables,database}.dart` (X0), `lib/core/storage/secure_storage.dart`, `lib/app/session_overlay.dart`, `lib/features/calls/**` (C).

---

## 4. Požadavky na X0 (kontrakty)

### 4.1 Server: entita `Device` (součást jedné EF migrace X0)

| Sloupec | Typ | Poznámka |
| --- | --- | --- |
| `VoipPushToken` | `string?`, `HasMaxLength(200)` | PushKit token (hex, 64 znaků, rezerva). Samostatný slot, protože zařízení s iOS má zároveň FCM token pro běžné notifikace. |
| `VoipPushEnvironment` | `string?`, `HasMaxLength(10)` | `production` nebo `sandbox`. Je to jen nápověda od klienta a server ji opraví podle odpovědi APNs (N2). |
| `PushKey` | `byte[]?` (`bytea`), přesně 32 B | Klíč pro šifrovaný hint `h` (R2). Není to tajemství vůči serveru. Chrání metadata před Googlem a Applem. |
| `PushTokenUpdatedAt` | `DateTimeOffset?` | Nastaví se při každém `PUT push-token`. Slouží k diagnostice a k rozhodnutí, jestli smazat token po APNs 410 (Apple vrací `timestamp`). |

`PushToken` a `PushPlatform` zůstávají beze změny. `PushPlatform ∈ {fcm, apns}`, `apns-voip` do `PushPlatform` **nepatří**. Mazání zařízení podle GDPR odstraní celý řádek `Device`, nové sloupce tím zmizí také. Export (`PrivacyEndpoints.cs:243`) doplní `hasVoipPushToken`.

### 4.2 Server: `PUT /devices/{id}/push-token` (rozšíření dělá X0, autorizaci opravuje S)

Request:
```json
{ "token": "…", "platform": "fcm" | "apns" | "apns-voip",
  "environment": "production" | "sandbox",     // volitelné, smysl jen pro apns*
  "pushKey": "<base64 32 B>" }                  // volitelné
```
- `apns-voip` zapíše `VoipPushToken` a `VoipPushEnvironment`. `fcm` a `apns` zapíšou `PushToken` a `PushPlatform` jako dnes.
- `pushKey`, pokud je přítomen, se uloží do `PushKey` bez ohledu na platformu. `PushTokenUpdatedAt` = now.
- 204. 400 `{error, code}` s `code ∈ invalid_platform | invalid_token` (prázdný nebo delší než 512 znaků) `| invalid_push_key` (není 32 B) `| invalid_environment`.

Nový `DELETE /devices/{id}/push-token?platform=fcm|apns|apns-voip` vrátí 204 (idempotentně) a vymaže odpovídající slot. Pro `fcm|apns` smaže i `PushKey`. Stejná autorizace jako PUT: `{id}` musí být volající zařízení (oprava proudu S).

### 4.3 Server: rozhraní push služby (X0 zmrazí jako stub, N implementuje, C volá)

Nový soubor `src/server/CallType.Api/Services/IPushNotificationService.cs`:
```csharp
namespace CallType.Api.Services;

public enum CallPushOutcome { Sent, NoToken, NotConfigured, Failed }
public enum CallCancelReason { CallerHangup, Timeout, AnsweredElsewhere, Rejected }
// wire: "caller_hangup" | "timeout" | "answered_elsewhere" | "rejected"

public interface IPushNotificationService
{
    /// Zpětná kompatibilita: push bez hintu.
    Task SendPushAsync(Guid recipientDeviceId);

    /// Offline příjemce zprávy. Vrací hned (zařadí do dispatcheru), nikdy nehází.
    Task SendMessagePushAsync(Guid recipientDeviceId, Guid senderDeviceId, Guid messageId, Guid? groupId);

    /// Příjemce byl online a zpráva mu šla přes SignalR. Pokud do Push:UnackedRepushSeconds
    /// nepřijde AcknowledgeMessage, pošle se push („zombie“ spojení). Neblokuje.
    void ScheduleUnackedPushCheck(Guid recipientDeviceId, Guid senderDeviceId, Guid messageId, Guid? groupId);

    Task SendChannelPostPushAsync(Guid channelId, TimeSpan throttleWindow, Func<Guid, bool> isOnline);

    /// Kontrakt d. Čeká na výsledek odeslání (max. ~5 s). Hub mapuje Sent → signal "pushed",
    /// cokoli jiného → "unavailable".
    Task<CallPushOutcome> SendCallPushAsync(Guid calleeDeviceId, Guid callerDeviceId, Guid callId,
        bool video, Guid? businessGroupId, CancellationToken ct = default);

    /// Zavěšení volajícího, timeout pending offer, přijetí jinde. Best-effort, nikdy nehází.
    Task SendCallCancelPushAsync(Guid calleeDeviceId, Guid callId, CallCancelReason reason,
        CancellationToken ct = default);
}
```
- X0 zaregistruje `AddSingleton<PushNotificationService>()` a `AddSingleton<IPushNotificationService>(sp => sp.GetRequiredService<PushNotificationService>())`. `MessengerHub` a `ChannelService` (`ChannelService.cs:48`) přepne na `IPushNotificationService`.
- Stub: `SendMessagePushAsync` deleguje na dnešní `SendPushAsync`, `ScheduleUnackedPushCheck` nic nedělá, `SendCallPushAsync` vrací `NoToken`, `SendCallCancelPushAsync` vrací `Task.CompletedTask`.
- **Úprava hubu, kterou X0 udělá před předáním souboru proudu C** (`MessengerHub.cs:176-189`, metoda `DeliverAsync`): offline větev zavolá `pushService.SendMessagePushAsync(message.RecipientId, message.SenderId, message.MessageId, message.GroupId)` **bez await na síti** (metoda vrací hned). Online větev po `SendAsync` přidá `pushService.ScheduleUnackedPushCheck(...)` se stejnými argumenty.

### 4.4 Server: konfigurace (N připíše do `appsettings.json`, O doplní do `infra/beta-appservice.bicep` a App Settings)

```json
"Push": {
  "FcmServiceAccountJson": "",
  "Apns": { "TeamId": "", "KeyId": "", "PrivateKeyP8": "", "BundleId": "cz.zcloud.jay" },
  "MessageCoalesceSeconds": 15,
  "MessageTtlSeconds": 604800,
  "CallTtlSeconds": 30,
  "CallCancelTtlSeconds": 60,
  "UnackedRepushSeconds": 15,
  "DispatchQueueCapacity": 10000,
  "MaxParallelSends": 8
}
```
`Push__Apns__PrivateKeyP8` (celý PEM obsah `.p8`) je secret a patří do stejné pipeline jako `Jwt__Secret`. Prázdná APNs konfigurace znamená, že VoIP push je vypnutý: `SendCallPushAsync` pro zařízení jen s VoIP tokenem vrátí `NotConfigured` a zaloguje varování. `ProductionConfigurationValidator` APNs **nevaliduje**, protože je volitelné, stejně jako FCM (`ProductionConfigurationValidator.cs:122-123`).

### 4.5 Klient: drift schema v4 (`calltype_core/lib/storage/tables.dart`, X0)

- `Conversations.mutedUntil`: `DateTimeColumn`, nullable. Význam: `null` = neztlumeno, `> now` = ztlumeno, navždy = `DateTime.utc(9999, 12, 31)`. UI patří M, N ho jen čte.
- Tabulka `AppSettings(key TEXT PK, value TEXT)`. N používá tyto klíče:

| Klíč | Hodnoty | Výchozí |
| --- | --- | --- |
| `notif.preview` | `nameAndText` \| `nameOnly` \| `hidden` | `nameAndText` (R3) |
| `notif.channels` | `1` \| `0` | `1` |
| `notif.permissionAsked` | `1` | — |
| `notif.desktop.closeToTray` | `1` \| `0` | `1` na Windows a Linuxu (R11), vlna 2 |
| `notif.desktop.launchAtStartup` | `1` \| `0` | `0`, vlna 2 |

- N dál jen čte `Contacts.displayName`, `Contacts.profileName` (G), `Contacts.userHandle`, `Contacts.blocked` (G; od blokovaného kontaktu se notifikace nezobrazí) a `Conversations.title`.

### 4.6 Klient: `pubspec.yaml` (`src/client/calltype`, X0)

| Balíček | Constraint | Platformy | Vlna | Poznámka |
| --- | --- | --- | --- | --- |
| `flutter_local_notifications` | `^22.3.1` | android, ios, macos, linux, windows, web | 1 | Vyžaduje Flutter ≥ 3.38.1 (CI má 3.41.x) a Android minSdk 24 **[OVĚŘIT `flutter.minSdkVersion` ve Flutter 3.41]**. Na Androidu vyžaduje core library desugaring (viz 4.7). Podpora webu je nová (22.0.0) **[OVĚŘIT callback kliknutí na webu]**. |
| `app_badge_plus` | `^1.3.5` | android, ios, macos | 1 | Na Androidu jen některé launchery **[OVĚŘIT]**. Web řeší N přes `navigator.setAppBadge`. |
| `web` | `^1.1.1` | web | 1 | Dnes jen tranzitivně (`pubspec.lock` 1.1.1). Explicitně kvůli `setAppBadge` a `Notification.permission`. |
| `firebase_messaging` / `firebase_core` | **beze změny** `^15.2.4` / `^3.13.0` (lock 15.2.10 / 3.15.2) | android, ios, macos, web | — | Upgrade na 16.x / 4.x není potřeba a je mimo tuto vlnu. |
| `tray_manager` | `^0.6.1` | windows, macos, linux | **2** | 0.7.0 vyžaduje Flutter ≥ 3.47, proto ne. |
| `window_manager` | `^0.5.2` | windows, macos, linux | **2** | |
| `launch_at_startup` | `^0.5.1` | windows, macos, linux **[OVĚŘIT]** | **2** | Čistý Dart, pub.dev neuvádí platformy. |

Balíčky vlny 2 přidá X0 hned jen tehdy, pokud ověří, že `flutter build web` projde (desktopové pluginy bez webové implementace). Jinak je přidá X0 vlny 2.

### 4.7 Klient: nativní konfigurace (X0 s P)

- **AndroidManifest** (`<application>`):
  ```xml
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver" />
  <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id"
      android:value="jay_messages" />
  <meta-data android:name="com.google.firebase.messaging.default_notification_icon"
      android:resource="@drawable/ic_stat_jay" />
  ```
  a `<uses-permission android:name="android.permission.VIBRATE"/>`. Receiver přesně podle README `flutter_local_notifications` 22 **[OVĚŘIT]**. `ic_stat_jay` dodá N jako vektor.
- **`android/app/build.gradle.kts`** (P/X0): `compileOptions { isCoreLibraryDesugaringEnabled = true }` a `dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:<verze z README fln 22>") }` **[OVĚŘIT verzi]**.
- **iOS `Info.plist`**: do `UIBackgroundModes` přidat `voip` (potřebuje C). `remote-notification` už tam je.
- **iOS entitlements** (P): `aps-environment` (`development` pro Debug, `production` pro Release a TestFlight). Volitelně `com.apple.developer.usernotifications.time-sensitive`, pokud vlastník chce, aby záložní alert hovoru prošel režimem Soustředění.
- **macOS entitlements** (P): `com.apple.developer.aps-environment` v `DebugProfile.entitlements` i `Release.entitlements`.
- **Xcode projekt** (P/X0): přidat do Runner targetu variant group `Localizable.strings` pro 19 jazyků (soubory vygeneruje N9), stejně i pro macOS. Bez toho iOS klíč `loc-key` nenajde a zobrazí se syrový klíč.
- **`ios/Runner/AppDelegate.swift`** (vlastní C, řádky vloží X0): `UNUserNotificationCenter.current().delegate = self` v `didFinishLaunching` a `FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in GeneratedPluginRegistrant.register(with: registry) }`. Kombinace s `FlutterImplicitEngineDelegate` (`AppDelegate.swift:5,13-15`) **[OVĚŘIT podle README fln 22]**.

### 4.8 Klient: stuby a rozhraní, která X0 vytvoří

1. **`lib/features/calls/call_push_handler.dart`** (vlastní C; X0 vytvoří stub, C napíše tělo):
   ```dart
   /// Called from the FCM background isolate AND from the foreground handler.
   /// Must not need a BuildContext or Provider — it is constructed via the
   /// top-level factory below because the background isolate has no DI.
   abstract interface class CallPushHandler {
     Future<void> onCallPush(CallPush push);
     Future<void> onCallCancelPush(CallCancelPush push);
   }
   class CallPush {
     const CallPush({required this.callId, required this.video,
       this.callerDeviceId, this.businessGroupId, required this.inBackground});
     final String callId; final bool video;
     final String? callerDeviceId;   // from the decrypted hint, null if unavailable
     final String? businessGroupId;  // from the decrypted hint
     final bool inBackground;
   }
   class CallCancelPush {
     const CallCancelPush({required this.callId, required this.reason});
     final String callId;
     final String reason; // caller_hangup | timeout | answered_elsewhere | rejected
   }
   CallPushHandler createCallPushHandler() => const _NoopCallPushHandler();
   ```
2. **`lib/core/notifications/missed_call_notifier.dart`** (vlastní N; X0 vytvoří rozhraní a no-op, aby C mohl kódovat):
   ```dart
   abstract interface class MissedCallNotifier {
     Future<void> showMissedCall({required String callId, String? peerDeviceId, required bool video});
     Future<void> cancelMissedCall(String callId);
   }
   ```
3. **`lib/features/chat/outgoing_message_service.dart`** (vlastní M; X0 vytvoří rozhraní a stub, který hází `UnimplementedError`). Používají ho akce notifikací v N10:
   ```dart
   abstract interface class OutgoingMessageService {
     Future<void> sendText(String conversationId, String text, {String? replyToId});
     /// Sets unreadCount=0 and sends `receipt kind:read` if M implements receipts.
     Future<void> markConversationRead(String conversationId);
   }
   ```
4. **`PushService.registerVoipToken`** (N, zmrazená signatura pro C): `Future<void> registerVoipToken(String token, {required String environment})` s `environment ∈ production|sandbox`.

### 4.9 Firebase konfigurace v buildu (požadavek na P, ne na X0)

Kód čte přes `String.fromEnvironment` tyto klíče: `FIREBASE_API_KEY`, `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_APP_ID_ANDROID`, `FIREBASE_APP_ID_IOS`, `FIREBASE_APP_ID_MACOS`, `FIREBASE_APP_ID_WEB`, `FIREBASE_AUTH_DOMAIN` (web), `FIREBASE_IOS_BUNDLE_ID` (`cz.zcloud.jay`), `FIREBASE_WEB_VAPID_KEY`. P je předá přes `--dart-define-from-file=<vygenerovaný json>` ve všech workflow, které stavějí klienta. Když hodnota chybí nebo je prázdná, výsledek je `PushStatus.notConfigured`, nikdy pád. `google-services.json` ani `GoogleService-Info.plist` kód **nevyžaduje** **[OVĚŘIT, že FCM na Androidu funguje jen s Dart inicializací; jinak P přidá `google-services.json` a gradle plugin]**.

### 4.10 ARB

Prefix klíčů proudu je **`notif`**. Úplný seznam je v N5, N7, N10 a N13.

### 4.11 Hub a zprávy

N nepřidává žádnou hub metodu ani typ zprávy. Signal `pushed` definuje a implementuje C.

---

## 5. Závislosti na jiných proudech

| Proud | Co N konzumuje / dodává | Přes co (lze kódovat bez čekání) |
| --- | --- | --- |
| **X0** | entita `Device`, endpoint push-token, `IPushNotificationService` stub, úprava `DeliverAsync`, schema v4, pubspec, manifest a plist, stuby 4.8 | sekce 4 |
| **C** | C volá `SendCallPushAsync` a `SendCallCancelPushAsync` z hubu a implementuje `CallPushHandler`. N volá `createCallPushHandler()` z background handleru a dodává `MissedCallNotifier` a `PushService.registerVoipToken`. **VoIP push na iOS zpracovává nativně C** (PushKit, CallKit) a do Dart background handleru nikdy nedojde. Payload VoIP pushe je definován v N3. | 4.3, 4.8. Integrační test hovoru dělá C s fake `IPushNotificationService`. |
| **M** | M nastavuje `mutedUntil` a `unreadCount` a implementuje `OutgoingMessageService`. N čte `persistedMessages` z inboxu. Nové typy zpráv (`receipt`, `reaction`, `edit`, `delete`) **nenotifikovat**, `media` notifikovat s popisem podle `kind`. | `MessageInboxService.persistedMessages` (existuje), stub 4.8/3 |
| **M2** | `Messages.type == 'media'` s `body` = JSON reference (`kind: image|video|voice|file`, `name?`). N z něj bere jen `kind` a `name` pro text „Fotka“, „Hlasová zpráva“ a podobně. | kontrakt a) |
| **G** | `Contacts.profileName`, `Contacts.blocked` pro jméno a potlačení notifikace | schema v4 |
| **S** | Autorizace `PUT/DELETE /devices/{id}/push-token`. S doplní do `docs/security/crypto-baseline.md` odstavec o push hintu (text dodá N v N3). | 4.2 |
| **P** | dart-define Firebase klíčů (4.9), entitlements, pbxproj s `Localizable.strings`, bundle id `cz.zcloud.jay` a stejný `applicationId` (kontrakt e), MSIX identita (AUMID) pro toasty Windows ve vlně 2 | 4.7, 4.9 |
| **O** | Firebase projekt, APNs klíč `.p8` (Team ID, Key ID) nahraný i do Firebase konzole (pro FCM→APNs), App Settings `Push__*`, doplnění `infra/beta-appservice.bicep` | 4.4 |
| **D** (vlna 2) | Při odhlášení nebo smazání zařízení zavolá `NotificationService.unregister()` | 4.8 veřejné API N4 |

---

## 6. Balíčky práce

Konvence: každý nový serverový soubor má hlavičkový komentář PROČ (vzor `PushNotificationService.cs:1-19`). Integrační testy dědí z `IntegrationTestBase` (Testcontainers Postgres + Azurite). Klientské widget testy obalují obrazovky `test/helpers/localized_app.dart`. Pokud lokálně neběží Docker, pusť jen unit testy (`dotnet test --filter "FullyQualifiedName~Push&Category!=Integration"`) a integrační nech na hosted CI v public okně (s OK vlastníka). V plánu i v PR výslovně napiš, které testy neběžely.

### N1 — FCM zprávy podle druhu, dispatcher, coalescing, metriky (server) · M · vlna 1 · P0

**Cíl:** Hub nečeká na FCM, každý druh pushe má správnou prioritu, TTL a collapse key a neplatné tokeny se mažou u všech relevantních chyb.

**Soubory:** `Services/PushNotificationService.cs`, `Services/FcmTokenProvider.cs`, nové `Services/Push/{PushOptions,PushKind,FcmMessageBuilder,PushDispatcher,MessagePushCoalescer,PushMetrics}.cs`, `Program.cs` (připsat), `appsettings.json` (připsat).

**Kroky**
1. `PushOptions` (bind `Push`, výchozí hodnoty viz 4.4) a `enum PushKind { NewMessage, ChannelPost, Call, CallCancel, Test }`. Wire `type`: `new_message`, `channel_post`, `call`, `call_cancel`, `test`. `new_message` a `channel_post` zůstávají kvůli kompatibilitě s nasazenými klienty (`push_service.dart:192`).
2. `FcmMessageBuilder.Build(PushKind kind, string token, IReadOnlyDictionary<string,string> data, PushOptions o, DateTimeOffset now)` vrátí `JsonObject`. Je čistě statický, aby šel testovat. Tvary:
   - **new_message**
     ```json
     { "message": { "token": "…",
       "data": { "type": "new_message", "v": "1", "h": "<volitelné>" },
       "android": { "priority": "HIGH", "ttl": "604800s", "collapse_key": "jay_msg" },
       "webpush": { "headers": { "Urgency": "high", "TTL": "604800", "Topic": "jay_msg" } },
       "apns": {
         "headers": { "apns-push-type": "alert", "apns-priority": "10",
                      "apns-collapse-id": "jay_msg", "apns-expiration": "<now+ttl unix>" },
         "payload": { "aps": { "alert": { "loc-key": "JAY_PUSH_NEW_MESSAGE" },
                               "sound": "default", "thread-id": "jay_msg", "mutable-content": 1 } } } } }
     ```
     `mutable-content` připravuje NSE (N14). Bez extension ho iOS ignoruje.
   - **channel_post:** `android.priority: "NORMAL"`, `ttl: "86400s"`, `collapse_key: "jay_ch"`. `webpush` `Urgency: normal`, `Topic: jay_ch`. `apns`: `apns-push-type: background`, `apns-priority: 5`, `aps: { "content-available": 1 }` (R6).
   - **call:** `data: { type: "call", v: "1", callId, video: "1"|"0", h? }`. `android.priority: "HIGH"`, `ttl: "30s"`, bez collapse. `webpush` `Urgency: high`, `TTL: 30`. `apns` (jen záloha pro iOS a macOS bez VoIP tokenu): `alert`, priority 10, `apns-collapse-id: "call-<callId>"`, expirace now+30, `aps.alert.loc-key` `JAY_PUSH_INCOMING_CALL` nebo `JAY_PUSH_INCOMING_VIDEO_CALL`, `sound: "default"`, `interruption-level: "time-sensitive"`.
   - **call_cancel:** `data: { type: "call_cancel", v: "1", callId, reason }`. `android.priority: "HIGH"`, `ttl: "60s"`. `webpush` `Urgency: high`, `TTL: 60`. `apns`: pro `caller_hangup|timeout` alert `loc-key: JAY_PUSH_MISSED_CALL` se **stejným** `apns-collapse-id: "call-<callId>"`, takže nahradí alert o příchozím hovoru. Pro `answered_elsewhere|rejected` `background` s `content-available: 1`.
   - **test:** jako new_message, ale `loc-key: JAY_PUSH_TEST`, `collapse_key: "jay_test"`, TTL 300 s.
   - Hodnoty v `data` jsou vždy **stringy** (požadavek FCM). Hodnota enumu `android.priority` **[OVĚŘIT: FCM v1 přijímá `"HIGH"`, případně `"high"`; test ověří konstantu, ruční přejímka N-01 skutečné doručení]**.
3. `FcmTokenProvider`: `CreateClient()` → `CreateClient("fcm")` (`FcmTokenProvider.cs:146`). V `Program.cs`: `AddHttpClient("fcm", c => c.Timeout = TimeSpan.FromSeconds(10))`.
4. Rozšířit `FcmResponseEvaluator.Evaluate` (`PushNotificationService.cs:58-86`) na `FcmSendOutcome { Ok, TokenUnregistered, AuthFailed, Retryable, Failed }`:
   - 404 + `UNREGISTERED` → `TokenUnregistered`.
   - 403 + `SENDER_ID_MISMATCH` → `TokenUnregistered`, protože token patří jinému projektu.
   - 400 `INVALID_ARGUMENT` → `Failed`. Token **nemazat**, může jít o chybu payloadu. Zaloguje se `errorCode`, nikdy tělo.
   - 401 → `AuthFailed`: zahodit cache OAuth tokenu (nová metoda `FcmTokenProvider.Invalidate()`) a jednou zopakovat.
   - 429, 500, 503 → `Retryable`: jedno opakování po 1 s pro `Call` a `CallCancel`, ostatní bez opakování.
   - Pravidlo „holé 404 není důkaz“ zůstává.
5. Mazání tokenu: jako dnes podmíněně na přesnou shodu (`:286-290`) a navíc `PushKey = null`.
6. `PushDispatcher : BackgroundService` a `PushDispatchQueue` (singleton, `Channel.CreateBounded<PushJob>(DispatchQueueCapacity)`, `FullMode = DropOldest` s metrikou `dropped`). Čte s paralelismem `MaxParallelSends` (`Parallel.ForEachAsync` nad `ReadAllAsync`). `PushJob(Guid DeviceId, PushKind Kind, IReadOnlyDictionary<string,string> Data)`. DB lookup tokenu probíhá až v dispatcheru, ve vlastním scope.
7. `SendPushAsync(Guid)` a `SendMessagePushAsync(...)` jen zařadí job a vrátí `Task.CompletedTask`. `SendMessagePushAsync` nejdřív zkontroluje `MessagePushCoalescer.TryAcquire(deviceId, now, window)` (stejný CAS vzor jako `ChannelPushThrottle`, `:94-122`, s komentářem o jedné instanci). Pro test i internal `Task SendNowAsync(PushJob)` a `Task DrainForTestsAsync()`.
8. `SendChannelPostPushAsync`: chování zachovat (throttle, jeden JOIN dotaz, jen online filtr), jen každý cíl zařadit jako job `ChannelPost`. Hodnoty `PushPlatform == "apns"` zatím nikdo neregistruje (R1), výběr zůstává `fcm`.
9. `PushMetrics` (`Meter("CallType.Push")`):
   - `Counter<long> calltype.push.sent{provider=fcm|apns, kind, result=ok|unregistered|failed|auth_failed|retry_ok|not_configured}`
   - `Counter<long> calltype.push.coalesced{kind}`, `calltype.push.dropped`, `calltype.push.token_cleared{provider, slot=regular|voip}`
   - `Histogram<double> calltype.push.send.duration{provider}` (ms)
   - `ObservableGauge<int> calltype.push.queue.length`

   Export (App Insights / OTel) je věc proudu O. Meter funguje i bez exportéru (`dotnet-counters`).
10. Logy s `EventId`: 3001 `PushSent` (Debug; DeviceId, kind, provider), 3002 `PushFailed` (Warning; HTTP status a provider `errorCode`/`reason`), 3003 `PushTokenCleared` (Information), 3004 `PushAuthFailed` (Error), 3005 `PushQueueFull` (Warning), 3006 `PushNotConfigured` (Warning, **nejvýš jednou za 10 min**, aby nezahltil log jako dnes `:236-241`). **Nikdy** nelogovat token, `h`, `PushKey` ani tělo odpovědi.

**Testy**
- Unit `Services/Push/FcmMessageBuilderTests.cs`: pro každý `PushKind` přesný JSON (priority, ttl, collapse, apns headers, `loc-key`), všechny hodnoty `data` jsou string, `apns-expiration` = now+TTL.
- Unit `FcmResponseEvaluatorTests.cs` (rozšířit): SENDER_ID_MISMATCH, 401, 429, 503, 400 INVALID_ARGUMENT, nečitelné tělo.
- Unit `MessagePushCoalescerTests.cs`: okno, souběh (2× `TryAcquire` paralelně → jen jeden `true`), jiné zařízení nezávislé.
- Integrační `PushNotificationServiceTests.cs` (rozšířit; FCM nakonfigurované testovacím service accountem z `FcmTokenProviderTests.CreateServiceAccountJson`, přesunout do `TestFixtures/FakePushHttpHandler.cs`, `token_uri` na fake host; `services.AddHttpClient("fcm").ConfigurePrimaryHttpMessageHandler(() => fake)`):
  (a) UNREGISTERED smaže `PushToken`, `PushPlatform` a `PushKey`;
  (b) token změněný během requestu přežije;
  (c) 3 zprávy do 15 s → 1 FCM request;
  (d) `SendPushAsync` se vrátí dřív, než fake handler odpoví (handler blokovaný `TaskCompletionSource`);
  (e) 401 → nový OAuth token a jeden retry;
  (f) push kanálu stále jen FCM tokenům a throttlovaný.
- Stávající testy `PushNotificationServiceTests` (`:36-137`) musí dál projít.

**Kritéria přijetí:** hub `SendReliableGroupMessage` se 100 offline příjemci neprovede žádné HTTP volání v kontextu invokace (test (d)). Každý druh má payload podle tabulky. Log neobsahuje token (test zachytí `ILogger` fakem a hledá řetězec tokenu).

### N2 — APNs klient (server) · M/L · vlna 1 · P0

**Cíl:** Server umí poslat VoIP push (a obecně `alert` a `background`) přímo do APNs.

**Soubory:** nové `Services/Push/{ApnsJwtProvider,ApnsClient,ApnsResponseEvaluator}.cs`, `Program.cs` (připsat).

**Kroky**
1. `ApnsJwtProvider` (singleton, vzor `FcmTokenProvider`): z `Push:Apns:PrivateKeyP8` (PEM PKCS#8, EC P-256) `ECDsa.ImportFromPem`. `IsConfigured` = TeamId, KeyId i klíč jsou platné. Chybná konfigurace se zaloguje jako Error a nevyhodí API z běhu.
   - JWT se skládá **ručně** (bez `JwtSecurityTokenHandler`, který přidává `typ`, `nbf` a `exp`): header `{"alg":"ES256","kid":KeyId}`, claims `{"iss":TeamId,"iat":<unix>}`, podpis `ECDsa.SignData(..., HashAlgorithmName.SHA256)` (formát IEEE P1363 = r‖s, jak vyžaduje JWS), vše base64url.
   - Cache 50 min: Apple token odmítne po 60 min a nechce refresh častěji než jednou za 20 min. `Invalidate()` pro 403.
   - `internal string CreateToken(DateTimeOffset now)` pro testy.
2. `Program.cs`:
   ```csharp
   builder.Services.AddHttpClient("apns", c => {
       c.DefaultRequestVersion = HttpVersion.Version20;
       c.DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact;
       c.Timeout = TimeSpan.FromSeconds(10);
   }).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler {
       PooledConnectionLifetime = TimeSpan.FromMinutes(30),
       EnableMultipleHttp2Connections = true });
   ```
3. `ApnsClient.SendAsync(ApnsRequest r, CancellationToken ct)` → `ApnsResult(ApnsOutcome Outcome, string? Reason, string? EnvironmentUsed)`.
   - `ApnsRequest(string DeviceToken, string Topic, string PushType /*alert|background|voip*/, int Priority, DateTimeOffset Expiration, string? CollapseId, JsonObject Payload, string Environment)`.
   - Host `https://api.push.apple.com` nebo `https://api.sandbox.push.apple.com`, cesta `/3/device/{token}`.
   - Hlavičky `authorization: bearer <jwt>`, `apns-topic`, `apns-push-type`, `apns-priority`, `apns-expiration` (unix s), volitelně `apns-collapse-id`, `apns-id` (nový Guid kvůli dohledání v logu Applu).
4. `ApnsResponseEvaluator` (čistá funkce `(HttpStatusCode, string body) → ApnsOutcome`):

| Odpověď | `ApnsOutcome` | Akce |
| --- | --- | --- |
| 200 | `Ok` | — |
| 400 `BadDeviceToken` | `WrongEnvironmentOrBadToken` | 1× zkusit druhé prostředí. Když projde, uložit `VoipPushEnvironment` (podmíněně na shodu tokenu). Když ne, smazat token. |
| 400 `DeviceTokenNotForTopic` | `TokenUnregistered` | smazat (VoIP token pro jiné téma) |
| 410 `Unregistered` / `ExpiredToken` | `TokenUnregistered` | smazat, pokud `PushTokenUpdatedAt < timestamp` z odpovědi nebo timestamp chybí; vždy jen podmíněně na shodu tokenu |
| 403 `ExpiredProviderToken` / `InvalidProviderToken` | `AuthFailed` | `Invalidate()` + 1 retry, log Error 3004 |
| 429, 500, 503 | `Retryable` | 1 retry po 1 s |
| 413, jiné 400 | `Failed` | log `reason` |

   Mazání VoIP slotu: `ExecuteUpdateAsync` nastaví `VoipPushToken = null`, `VoipPushEnvironment = null` s podmínkou `d.VoipPushToken == token`.
5. Topic: `BundleId + ".voip"` pro `voip`, jinak `BundleId`.

**Testy**
- Unit `ApnsJwtProviderTests.cs`: vygenerovaný P-256 klíč → PEM do konfigurace. Token má 3 části, header je přesně `alg` + `kid`, claims přesně `iss` + `iat`. Podpis ověřený veřejným klíčem (`VerifyData`). Cache vrací stejný token do 50 min, pak nový. Neplatný PEM znamená `IsConfigured == false` bez výjimky.
- Unit `ApnsResponseEvaluatorTests.cs`: celá tabulka.
- Integrační (v `PushNotificationServiceTests`, fake handler pro `"apns"`): 410 smaže jen VoIP slot a FCM token zůstane. `BadDeviceToken` v produkci a 200 v sandboxu uloží `sandbox`. Request má `apns-push-type: voip`, topic `cz.zcloud.jay.voip` a `:path` s tokenem.
- Ruční: N-14 (sekce 7) na reálném zařízení. HTTP/2 z App Service Linux k Applu ověří první přejímka.

**Kritéria přijetí:** všechny unit a integrační testy zelené. Bez APNs konfigurace žádná výjimka, jen varování 3006 a `NotConfigured`.

### N3 — Hovorový push, šifrovaný hint, repush nepotvrzených, `POST /push/test` (server) · M · vlna 1 · P0 (hint a repush P1)

**Soubory:** `Services/PushNotificationService.cs`, nové `Services/Push/PushHint.cs`, `Endpoints/PushEndpoints.cs`, `Program.cs` (připsat).

**Kroky**
1. **`PushHint.Seal(byte[] key32, string type, JsonObject plaintext)`**: vrátí `string` (base64url bez paddingu) z `nonce(12) ‖ ciphertext ‖ tag(16)`. Používá `AesGcm` s náhodným nonce a `AAD = UTF8("CallType-PushHint-v1|" + type)`. Typ je v AAD, aby hint ze zprávy nešel podstrčit jako hint hovoru. Nový doménový separátor se jmenuje `CallType-…` konzistentně s ostatními. Stávající řetězce `CallType-*` se nemění.
   - Plaintext pro `new_message`: `{"c":"<conversationId>","s":"<senderId>","m":"<messageId>"}`, kde `c = groupId ?? senderId`, stejně jako klient (`message_inbox_service.dart:69`).
   - Pro `call`: `{"s":"<callerId>","g":"<businessGroupId>"|null}`.
   - Bez `PushKey` se `h` vynechá.
   - Deterministický test vektor (pevný klíč, nonce a plaintext → očekávaný výstup) je sdílený s Dart testem N6. Nonce je v testu injektovaný přes `internal Seal(..., byte[] nonce)`.
2. **`SendMessagePushAsync`**: načte `PushKey` v dispatcheru, sestaví hint a zařadí job `NewMessage`.
3. **`SendCallPushAsync`** (nečeká ve frontě, volá přímo `SendNowAsync` s `CancellationTokenSource` 5 s):
   - Načte zařízení. Nemá-li `PushToken` ani `VoipPushToken`, vrátí `NoToken`.
   - Má-li `VoipPushToken` a APNs je nakonfigurované, pošle **VoIP** přes APNs. Payload:
     ```json
     { "aps": {}, "type": "call", "v": 1, "callId": "<uuid>", "video": true, "h": "<volitelné>" }
     ```
     Hlavičky: `apns-push-type: voip`, `apns-priority: 10`, `apns-expiration: now+CallTtlSeconds`, bez collapse.
   - Jinak, nebo když VoIP selže a existuje FCM token, pošle **FCM `call`**. Na iOS bez VoIP tokenu to znamená záložní alert.
   - Výsledek: alespoň jedno `Ok` → `Sent`. Tokeny existují, ale chybí konfigurace → `NotConfigured`. Jinak `Failed`.
   - Metriky `kind=call`. **Neomezuje se.**
4. **`SendCallCancelPushAsync`**: best-effort a fire-and-forget uvnitř (vrací až po odeslání, ale nikdy nehází).
   - **Nikdy neposílat jako VoIP push.** iOS 13+ ukončí aplikaci, která na VoIP push nezavolá `reportNewIncomingCall`, a po opakování PushKit přestane doručovat.
   - Posílá jen FCM `call_cancel` (tvar v N1). Zařízení bez FCM tokenu: nic, zmeškaný hovor si C odvodí po připojení.
5. **`ScheduleUnackedPushCheck`**: in-memory `ConcurrentDictionary<(Guid recipient, Guid messageId), PendingCheck(DueAt, Sender, GroupId)>` a smyčka v `PushDispatcher` (`PeriodicTimer` 5 s). Po `DueAt` jeden dotaz `db.QueuedMessages.Where(m => keys… && m.AcknowledgedAt == null)` (sloupec `AcknowledgedAt`, `MessageQueueService.cs:61-63`). Pro nepotvrzené zavolá `SendMessagePushAsync` (projde coalescingem). Komentář: jen jedna instance (CLAUDE.md, rozhodnutí 6), restart znamená ztrátu kontroly, nikoli zprávy. Velikost je omezená (max. 50 000 položek, pak se nové kontroly zahazují s metrikou).
6. **`POST /push/test`** (`Endpoints/PushEndpoints.cs`, `RequireAuthorization()`, `RequireRateLimiting("api")` a navíc in-memory limit 3 za 10 min na zařízení). `deviceId` se bere **jen z JWT** (stejný claim jako hub), nikdy z cesty, takže nevzniká IDOR jako v nálezu S. Posílá synchronně `PushKind.Test` jen na běžný token (VoIP nikdy):
   - 200 `{ "provider": "fcm", "result": "ok" }`
   - 409 `{ "error": "…", "code": "no_push_token" }`
   - 429 `{ "code": "push_test_rate_limited" }`
   - 503 `{ "code": "push_not_configured" }`
   - 502 `{ "code": "push_rejected", "reason": "<errorCode|reason>" }`
7. Text pro `docs/security/crypto-baseline.md` (předá S): primitivum, AAD, velikost klíče, co hint chrání (metadata před FCM a APNs) a co ne (před serverem, který klíč zná).

**Testy**
- Unit `PushHintTests.cs`: round-trip, pevný vektor, jiný `type` v AAD → dešifrování selže.
- Integrační:
  - `SendCallPushAsync`: bez tokenů → `NoToken`; FCM 200 → `Sent` a request má `android.priority HIGH`, `ttl 30s`, `data.callId`; VoIP token a APNs 200 → `Sent` a FCM se nevolá; APNs 410 a FCM 200 → `Sent` a VoIP token smazán; FCM nenakonfigurované a jen FCM token → `NotConfigured`.
  - `SendCallCancelPushAsync` nikdy nevolá APNs voip (assert na fake).
  - Repush: zpráva `EnqueueReliableAsync` + `ScheduleUnackedPushCheck` s `UnackedRepushSeconds=1` v konfiguraci testu → bez ACK přijde 1 FCM request, s `AcknowledgeAsync` před termínem 0 requestů.
- Integrační `Endpoints/PushEndpointsTests.cs`: 401 bez tokenu, 409 bez push tokenu, 200 s fake FCM, 4. volání do 10 min → 429, zařízení A nemůže poslat test zařízení B (endpoint žádné id nebere).

**Kritéria přijetí:** C může v hubu jen zavolat metody a namapovat výsledek. Hint nikdy neodchází bez `PushKey`. VoIP push nikdy nenese `call_cancel`.

### N4 — Firebase bootstrap a `PushService` (klient) · M · vlna 1 · P0

**Soubory:** `lib/core/network/push_service.dart`, nové `lib/core/notifications/{firebase_config,push_key_store,notification_service}.dart`, `lib/main.dart` (připsat), `lib/app/router.dart` (připsat), `calltype_core/lib/network/api_client.dart` (připsat metody).

**Kroky**
1. `firebase_config.dart`: `class JayFirebaseConfig { static FirebaseOptions? get currentPlatform; static String? get webVapidKey; }` z `String.fromEnvironment` (klíče 4.9). Pro platformu bez hodnot vrací `null`. Výběr: `kIsWeb` → web, jinak podle `defaultTargetPlatform`. Windows a Linux vrací `null`.
2. `PushMessagingClient.initializeFirebase()` přijme `FirebaseOptions`. Když jsou options `null`, nastaví se `PushStatus.notConfigured` bez volání SDK.
3. **Oprava** `push_service.dart:126`: `if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux))`.
4. `PushStatus` se rozšíří o `notRequested` (web a první spuštění: oprávnění zatím nikdo nežádal). Safari vyžaduje žádost z gesta uživatele, proto se na **webu nikdy nežádá automaticky**. Žádá se jen z tlačítka v N7. Na mobilu se žádá jednou po dokončení onboardingu (`notif.permissionAsked`). `getNotificationSettings()` přidat do seamu `PushMessagingClient`.
5. Registrace tokenu přes novou metodu `ApiClient.registerPushToken({required deviceId, required token, required platform, String? environment, String? pushKey})`, která volá `PUT /devices/{id}/push-token` s tělem 4.2. `PushKeyStore` (nad `SecureStorage.read/write`, klíč `ct_push_key`) vygeneruje 32 B jednou na instalaci (`Random.secure()`) a posílá je s každou registrací. Na webu `getToken(vapidKey: JayFirebaseConfig.webVapidKey)`.
6. `registerVoipToken(token, environment:)` volá `platform: 'apns-voip'` (pro C). `unregister()` volá `DELETE` pro `fcm` a `apns-voip`, pak `FirebaseMessaging.deleteToken()`.
7. `getInitialMessage()` po initu a `onMessageOpenedApp` → `NotificationTap.fromRemoteMessage(data)` → `NotificationService.handleTap`.
8. `onMessage` (popředí): `type` `call`/`call_cancel` → `createCallPushHandler()` (`inBackground: false`); `channel_post` → callback `onChannelPost` jako dnes (`main.dart:149-150`); `new_message` → `signalRClient.connect()`, pokud není připojeno (spojení nejspíš spadlo). Nic se nezobrazuje, zobrazí to až `MessageNotifier`, když inbox zprávu uloží.
9. `NotificationService` (ChangeNotifier, jedna instance, vytváří se v `main.dart`) vlastní `PushService`, `NotificationPresenter` (N5), `MessageNotifier`, `BadgeUpdater` (N7) a `ConnectionLifecycle` (N11). Veřejné API:
   ```dart
   Future<void> start();                              // main.dart, before runApp
   Future<void> onDeviceRegistered(String deviceId);  // router.dart onRegistered
   Future<PushStatus> requestPermission();            // settings button (user gesture on web)
   PushStatus get pushStatus;
   Future<void> unregister();                         // D: logout / device delete
   Future<void> registerVoipToken(String token, {required String environment}); // C
   MissedCallNotifier get missedCalls;                // C
   ```
10. `main.dart`: hned po `WidgetsFlutterBinding.ensureInitialized()` volat `FirebaseMessaging.onBackgroundMessage(jayFirebaseBackgroundHandler)` (jen `!kIsWeb`, na webu to obsluhuje service worker). Blok `:138-152` nahradit `NotificationService(...).start()` a přidat `ChangeNotifierProvider.value(value: notifications)`.
11. `router.dart` `onRegistered` (`:100-107`): po `connection.connect()` přidat `unawaited(ctx.read<NotificationService>().onDeviceRegistered(id))`.

**Testy** (`test/core/network/push_service_test.dart` rozšířit, `FakePushMessagingClient` už existuje):
- web a Windows host: status není `unsupported`. Pro test: `debugDefaultTargetPlatformOverride` a parametr `isWeb` v seamu (`@visibleForTesting`).
- `null` options → `notConfigured` a SDK se nevolá.
- registrace posílá `pushKey`, který je stabilní napříč dvěma `initialize()`.
- `registerVoipToken` posílá `apns-voip` a `environment`.
- `getInitialMessage` s `type=new_message` a hintem vyvolá tap na `/chats/<c>`.
- `unregister` volá DELETE 2×.

Unit `firebase_config_test.dart`: bez dart-define vrací `null`.

**Kritéria přijetí:** po onboardingu se token zaregistruje bez restartu. Web na Windows není `unsupported`. Aplikace bez Firebase konfigurace startuje beze změny chování.

### N5 — Lokální notifikace: presenter, kanály, message notifier, navigace (klient) · L · vlna 1 · P0 (ztlumení a náhled P1)

**Soubory:** nové `lib/core/notifications/{notification_presenter,fln_notification_presenter,notification_ids,notification_payload,notification_l10n,message_notifier,notification_settings,missed_call_notifier}.dart`, `android/app/src/main/res/drawable/ic_stat_jay.xml`, ARB (připsat).

**Kroky**
1. `notification_ids.dart`:
   - Android kanály: `jay_messages` (Importance.high, zvuk a vibrace výchozí), `jay_channels` (Importance.low, bez zvuku), `jay_missed_calls` (Importance.defaultImportance). `jay_calls` je **rezervované pro C**.
   - ID notifikací: `1` = obecná „Nová zpráva“ z pushe, `2` = kanály, `3` = test, `10–99` rezervované pro C (vyzvánění), `100–999` zmeškané hovory (`100 + fnv1a31(callId) % 900`), konverzace = `1000 + fnv1a31(conversationId) % 2^30` (deterministické napříč isolaty, `String.hashCode` stabilní není).
   - `groupKey: 'jay_messages'` a souhrnná notifikace na Androidu.
2. `notification_payload.dart`: lokální payload JSON `{"k":"chat","c":"<id>"}` / `{"k":"list"}` / `{"k":"channels"}` / `{"k":"call","callId":"…"}` a `NotificationTap.route` → `/chats/<id>`, `/chats`, `/updates`. Parser toleruje neznámé `k` a vrátí `/chats`.
3. `NotificationPresenter` (rozhraní, seam pro testy):
   ```dart
   abstract interface class NotificationPresenter {
     Future<void> initialize();                  // channels, categories, tap callbacks
     Future<void> showConversation(ConversationNotification n);
     Future<void> showGenericNewMessage({String? conversationId, String? senderName});
     Future<void> showChannelPosts();
     Future<void> showMissedCall({required String callId, String? peerName, required bool video});
     Future<void> showTest();
     Future<void> cancelConversation(String conversationId);
     Future<void> cancelGeneric();
     Future<void> cancelById(int id);
     Stream<NotificationTap> get taps;
     Future<NotificationTap?> launchTap();       // getNotificationAppLaunchDetails
     Future<void> openSystemSettings();          // openAppNotificationSettings (fln ≥22.3)
   }
   ```
   `FlnNotificationPresenter` implementuje pro Android, iOS, macOS, Windows, Linux a web. iOS/macOS kategorie `jay_message` (akce doplní N10). Windows: `WindowsInitializationSettings(appName: 'Jay', appUserModelId: 'cz.zcloud.jay', guid: <pevný GUID v kódu>)` **[OVĚŘIT AUMID po MSIX od P]**. Linux: `LinuxInitializationSettings(defaultActionName: …)`. Web: implementace z fln 22; pokud neumí doručit kliknutí, použije se záložní `web_notification_presenter.dart` přes `package:web` (`ServiceWorkerRegistration.showNotification` + zprávy od service workeru) **[OVĚŘIT]**.
4. `notification_l10n.dart`: `AppLocalizations notificationL10n()` = `lookupAppLocalizations(basicLocaleListResolution(PlatformDispatcher.instance.locales, AppLocalizations.supportedLocales))`. **Komentář PROČ:** notifikace se tvoří mimo strom widgetů, někdy i v background isolate bez `BuildContext`. Nejde o globální singleton, locale se vyhodnocuje při každém volání stejným pravidlem jako `MaterialApp`. Výjimku z pravidla CLAUDE.md „no global localization singleton“ zapsat do komentáře.
5. `MessageNotifier`:
   - Poslouchá `MessageInboxService.persistedMessages` (jen čtení, `message_inbox_service.dart:47`) a `AppLifecycleListener`.
   - Pro každou zprávu platí pravidla v tomto pořadí (každé má test):
     1. `senderId == myDeviceId` → nic.
     2. typ `call-event|receipt|reaction|edit|delete|profile` nebo neznámý → nic.
     3. kontakt `blocked` → nic.
     4. `mutedUntil > now` → nic.
     5. aplikace `resumed` a aktuální routa je `/chats/<conversationId>` → nic.
     6. jinak `showConversation`.
   - Text podle `notif.preview`:
     - `nameAndText`: titulek = jméno (1:1) nebo „{sender} v {group}“, tělo = text zkrácený na 200 znaků; `file`/`media` → `notifAttachmentFile`/`notifPhoto`/`notifVideo`/`notifVoiceMessage`.
     - `nameOnly`: titulek = jméno, tělo = `notifNewMessageBody`.
     - `hidden`: titulek „Jay“, tělo = `notifNewMessageBody`, konverzační ID se zachová kvůli navigaci.
   - Jméno = `profileName ?? displayName ?? userHandle` (kontakt), ve skupině `Conversations.title ?? notifGroupFallback`. Nikdy syrové UUID.
   - Android: `MessagingStyleInformation` s posledními max. 5 zprávami konverzace (buffer v paměti hlavního isolate), `visibility: NotificationVisibility.private`, `category: message`.
   - Po `resumed`: `cancelGeneric()` a zrušení notifikací konverzací s `unreadCount == 0`. Drift `watch` nad `Conversations` zruší notifikaci, jakmile M vynuluje unread (`chat_controller.dart:176-180`), aniž by N sahal do kódu M.
6. Navigace: `NotificationService.handleTap(tap)` počká na první frame a pak zavolá `router.go(tap.route)`. `go` na `/chats/<id>` postaví zásobník `/chats` → `:id` (`router.dart:113-139`). Když konverzace v DB neexistuje, otevře se `/chats`. Zámek aplikace: navigace proběhne pod `SessionOverlay` (overlay je nad routerem, `app.dart:31-32`), obsah chatu je tedy vidět až po odemčení (test).
7. `MissedCallNotifier` implementuje `showMissedCall` a `cancelMissedCall`: kanál `jay_missed_calls`, ID z rozsahu `100–999` (krok 1). Po klepnutí `/chats/<peerDeviceId>`, bez známého protějšku `/chats`.

**ARB klíče (en; přeložit do všech 19):** `notifChannelMessagesName`, `notifChannelMessagesDescription`, `notifChannelChannelsName`, `notifChannelChannelsDescription`, `notifChannelMissedCallsName`, `notifNewMessageBody` („New message“), `notifNewMessagesCount` (ICU plural `{count}`), `notifNewMessageFrom` („New message from {name}“), `notifGroupTitle` („{sender} in {group}“), `notifGroupFallback` („Group“), `notifAttachmentFile` („File: {name}“), `notifPhoto`, `notifVideo`, `notifVoiceMessage`, `notifChannelPostsBody` („New posts in your channels“), `notifMissedCallTitle`, `notifMissedVideoCallTitle`, `notifMissedCallBody` („{name} tried to call you“), `notifMissedCallBodyUnknown`, `notifTestBody` („Test notification from Jay“).

**Testy** (`test/core/notifications/`, fake `NotificationPresenter`, in-memory `AppDatabase.forTesting`):
- `message_notifier_test.dart`: každé pravidlo 1–6, tři režimy náhledu, jméno ve skupině (ne UUID), zrušení při vynulování unread, `cancelGeneric` po resume.
- `notification_payload_test.dart`: routy a neznámé `k`.
- `notification_ids_test.dart`: determinismus FNV a oddělení rozsahů.
- `notification_l10n_test.dart`: `cs_CZ` → cs, `xx` → en, `ar` → ar.
- Widget test (localized_app): tap při zamčené aplikaci otevře chat pod zámkem a obsah není vidět do odemčení.

**Kritéria přijetí:** v popředí se v otevřeném chatu nic nezobrazí, v jiném chatu ano. Ztlumený chat nic nezobrazí. `hidden` neukáže jméno ani text.

### N6 — Background handler FCM (klient) · M · vlna 1 · P0 (hint P1)

**Soubory:** nové `lib/core/notifications/{push_background_handler,push_hint}.dart`.

**Kroky**
1. Top-level `@pragma('vm:entry-point') Future<void> jayFirebaseBackgroundHandler(RemoteMessage m)`:
   - `WidgetsFlutterBinding.ensureInitialized()` (nutné pro pluginy v background isolate).
   - `Firebase.initializeApp(options: JayFirebaseConfig.currentPlatform)`.
   - `FlnNotificationPresenter().initialize()` s `onDidReceiveBackgroundNotificationResponse: jayNotificationBackgroundResponse` (také top-level `vm:entry-point`; ve vlně 1 jen uloží tap, akce řeší N10).
   - Celé tělo je v `try/catch` s limitem 8 s. Při jakékoli chybě se ukáže obecná notifikace, aby push neskončil bez viditelné notifikace (FCM jinak high-priority zprávy deprioritizuje).
2. Dispatch podle `m.data['type']`:
   - `call` → `createCallPushHandler().onCallPush(CallPush(callId, video == '1', callerDeviceId: hint?.s, businessGroupId: hint?.g, inBackground: true))`. **N nic nezobrazuje**, UI hovoru je věc C.
   - `call_cancel` → `onCallCancelPush(CallCancelPush(callId, reason))`.
   - `new_message`:
     - Dešifrovat `h` (`PushHint.open(key, type, h)`; klíč z `PushKeyStore`).
     - S hintem otevřít DB **jen pro čtení** (`openAppDatabase('calltype')`, po použití `close()`): `mutedUntil > now` → nic. Jinak podle `notif.preview` `showGenericNewMessage(conversationId: c, senderName: nameOnly|nameAndText ? jméno : null)`. Text zprávy se tu nikdy nezobrazí, protože ho push nenese.
     - Bez hintu nebo při chybě `showGenericNewMessage()` s ID 1.
     - Nápověda: `openAppDatabase` v druhém isolate otevře druhé SQLite spojení. Pro čtení je to bezpečné (zamykání souboru v SQLite), ale nesmí se zapisovat. `DriftNativeOptions(shareAcrossIsolates: true)` **[OVĚŘIT v drift_flutter 0.3.0]** je volitelné zlepšení.
   - `channel_post` → `notif.channels == '1'` → `showChannelPosts()`.
   - `test` → `showTest()`.
   - jiné → nic, jen debug log.
3. Pokus o předání hlavnímu isolate: `IsolateNameServer.lookupPortByName('jay.main')`. Pokud hlavní isolate žije (Android, aplikace na pozadí, proces běží), pošle se mu `{"type":"new_message"}`. Hlavní isolate zavolá `signalRClient.connect()` a zobrazí plnou notifikaci přes N5 po dešifrování. Background handler pak ukáže jen obecnou notifikaci s ID konverzace, kterou N5 nahradí (stejné ID). Port registruje `NotificationService.start()`.
4. `push_hint.dart`: `PushHint.open(List<int> key, String type, String h)` → `Map<String,String?>?`. Používá AES-GCM z `cryptography` (`AesGcm.with256bits()`), AAD shodné s N3. Chyba vrátí `null`.

**Testy**
- `push_hint_test.dart`: pevný vektor z N3 a špatné AAD vrátí `null`.
- `push_background_handler_test.dart`: dispatch přes injektovatelné závislosti (`@visibleForTesting Future<void> handleBackgroundPush(Map<String,String> data, BackgroundDeps deps)`). `call` → fake `CallPushHandler` a žádná notifikace. Ztlumený chat → nic. Chybějící klíč → obecná. `channel_post` s vypnutým nastavením → nic. Výjimka v DB → obecná notifikace.

**Kritéria přijetí:** zabitá aplikace na Androidu ukáže notifikaci do 10 s (N-01). `call` se nikdy nezobrazí jako notifikace zprávy.

### N7 — Nastavení notifikací a badge (klient) · M · vlna 1 · P1

**Soubory:** nové `lib/features/settings/notification_settings_screen.dart`, `lib/core/notifications/{badge_updater,web_badge,web_badge_stub}.dart`, `settings_screen.dart` a `router.dart` (připsat), ARB.

**Kroky**
1. Routa `/settings/notifications` a dlaždice v `settings_screen.dart` (ikona `Icons.notifications_rounded`, vzor `_SettingsTile`).
2. Obrazovka:
   - **Stav pushe** (`registered` / `permissionDenied` s tlačítkem „Otevřít nastavení systému“ / `notRequested` s tlačítkem „Zapnout notifikace“, které volá `requestPermission()` z gesta / `unsupported` s vysvětlením pro desktop / `notConfigured`).
   - **Náhled obsahu** (3× `RadioListTile`, `notif.preview`).
   - **Notifikace z kanálů** (`SwitchListTile`, `notif.channels`).
   - **Zvuky a vibrace** → `presenter.openSystemSettings()` (na Androidu se zvuk nastavuje per kanál).
   - **Odeslat zkušební notifikaci** → `ApiClient.sendTestPush()` (`POST /push/test`), výsledek ve SnackBaru podle `code`.
   - **Poznámka o soukromí** `notifPrivacyNote`.
3. `BadgeUpdater`: drift `watch` nad `SUM(unreadCount) WHERE mutedUntil IS NULL OR mutedUntil < now` (R8). `app_badge_plus` `AppBadgePlus.updateBadge(n)` na iOS, macOS a Androidu. Na webu `navigator.setAppBadge(n)` / `clearAppBadge()` přes `package:web` v `try` (API existuje jen v nainstalované PWA). Windows v N12. Každá chyba se ignoruje.

**ARB:** `notifSettingsTitle`, `notifSettingsSubtitle`, `notifStatusRegistered`, `notifStatusDenied`, `notifStatusNotRequested`, `notifStatusUnsupported` („Push is not available on this device. Jay notifies you only while it is running.“), `notifStatusNotConfigured`, `notifEnableButton`, `notifOpenSystemSettings`, `notifPreviewTitle`, `notifPreviewNameAndText`, `notifPreviewNameOnly`, `notifPreviewHidden`, `notifChannelsToggle`, `notifSoundsTitle`, `notifTestButton`, `notifTestSent`, `notifTestNoToken`, `notifTestNotConfigured`, `notifTestRateLimited`, `notifTestFailed`, `notifPrivacyNote` („Google and Apple only learn that something arrived for this device — never who wrote or what.“). **Bezpečnostní formulace musí zachovat význam ve všech jazycích** (CLAUDE.md).

**Testy:** widget test `notification_settings_screen_test.dart` (localized_app, cs, de, ar RTL): každý stav, přepnutí náhledu zapíše `AppSettings`, výsledky testovacího tlačítka pro 200/409/503. `badge_updater_test.dart`: ztlumený chat se nepočítá a změna unread vyvolá update. Guard `no_hardcoded_strings_test` musí projít.

### N8 — Web: `firebase-messaging-sw.js` (klient) · M · vlna 1 · P0

**Soubory:** nový `web/firebase-messaging-sw.js`, `web/staticwebapp.config.json` (připsat), test `test/web/firebase_sw_strings_test.dart`.

**Kroky**
1. Service worker bez Firebase SDK (R5):
   - `self.addEventListener('push', e => …)`: `const p = e.data?.json() ?? {}; const d = p.data ?? p;`.
   - Podle `d.type` zavolat `self.registration.showNotification(title, {body, tag, icon: 'icons/Icon-192.png', badge, data: {route}, renotify})`:
     - `new_message`: tag `jay_msg`, route `/#/chats`.
     - `channel_post`: tag `jay_ch`, route `/#/updates`.
     - `call`: tag `call-<callId>`, `requireInteraction: true`, route `/#/chats`. Pending offer doručí hub po připojení (kontrakt d).
     - `call_cancel`: zavře notifikaci s tagem `call-<callId>` a zobrazí zmeškaný hovor.
     - `test`.
   - **Každý push musí skončit `showNotification`.** Jinak Chrome ukáže vlastní obecnou hlášku a Safari po opakování odebere oprávnění (povinné `userVisibleOnly`).
   - `e.waitUntil(...)` vždy.
   - Hint `h` se na webu nedešifruje, protože service worker nemá přístup ke klíči v úložišti stránky. Omezení je popsané v D03 a řeší ho P2.
2. `notificationclick`: `clients.matchAll({type:'window', includeUncontrolled:true})`. Existující okno → `focus()` + `postMessage({type:'jay_notification_click', route})`. Jinak `clients.openWindow(route)`.
3. Řetězce: blok mezi značkami `// BEGIN JAY STRINGS` a `// END JAY STRINGS` je objekt `{ "<lang>": { newMessage, channelPosts, incomingCall, incomingVideoCall, missedCall, test } }` pro 19 jazyků, vygenerovaný `tool/gen_push_strings.dart` (N9). Jazyk se volí z `navigator.language` s fallbackem `en`.
4. Koexistence: FCM registruje worker se scope `/firebase-cloud-messaging-push-scope`, takže nekoliduje s drift **Web Workerem** (`drift_worker.js` není service worker) ani s případným `flutter_service_worker.js` (jiný scope) **[OVĚŘIT, že Flutter 3.41 `flutter build web` negeneruje kolidující SW]**.
5. `staticwebapp.config.json`: `"routes": [{ "route": "/firebase-messaging-sw.js", "headers": { "Cache-Control": "no-cache" } }]`. Soubor už je vyňatý z navigationFallback (`/*.js`).
6. Hlavní isolate na webu poslouchá `navigator.serviceWorker` `message` → `NotificationService.handleTap`.

**Testy:** `firebase_sw_strings_test.dart` vyparsuje blok a porovná ho s ARB (klíče `notifNewMessageBody`, `notifChannelPostsBody`, `callIncomingVoice`, `callIncomingVideo`, `notifMissedCallTitle`, `notifTestBody`) pro všech 19 jazyků. Syntaxi ověří `node --check web/firebase-messaging-sw.js` v CI (požadavek na P), lokálně pokud je `node` k dispozici. Ruční N-08 a N-09.

### N9 — Nativní řetězce pro `loc-key` (iOS a macOS) a generátor · S · vlna 1 · P0

**Soubory:** `tool/gen_push_strings.dart`, `ios/Runner/<lang>.lproj/Localizable.strings` a `macos/Runner/<lang>.lproj/Localizable.strings` (19×2, generované a commitnuté), blok v `web/firebase-messaging-sw.js`, test `test/tool/gen_push_strings_test.dart`.

**Kroky**
1. Mapování `JAY_PUSH_NEW_MESSAGE ← notifNewMessageBody`, `JAY_PUSH_CHANNEL_POST ← notifChannelPostsBody`, `JAY_PUSH_INCOMING_CALL ← callIncomingVoice`, `JAY_PUSH_INCOMING_VIDEO_CALL ← callIncomingVideo`, `JAY_PUSH_MISSED_CALL ← notifMissedCallTitle`, `JAY_PUSH_TEST ← notifTestBody`. Klíče C se jen čtou.
2. `dart run tool/gen_push_strings.dart` zapíše soubory: `"KEY" = "value";` s escapováním `"` a `\`, UTF-8, a pro čínštinu složku `zh-Hans.lproj` **[OVĚŘIT, jaký název složky iOS očekává pro ARB `zh`]**. Zároveň přepíše JS blok (N8).
3. Test spustí generátor do paměti a porovná výstup s commitnutými soubory. Když se ARB změní a soubory ne, test selže.
4. Požadavek na P/X0: přidat soubory do pbxproj (4.7).

### N10 — Akce „Odpovědět“ a „Označit jako přečtené“ · M · vlna 1 · P1

**Soubory:** `lib/core/notifications/{fln_notification_presenter,notification_service}.dart`, ARB.

**Kroky**
1. Android: `AndroidNotificationAction('reply', notifActionReply, inputs: [AndroidNotificationActionInput(label: notifReplyHint)], showsUserInterface: true)` a `AndroidNotificationAction('read', notifActionMarkRead, showsUserInterface: true, cancelNotification: true)`. iOS/macOS: kategorie `jay_message` s `DarwinNotificationAction.text('reply', …, options: {DarwinNotificationActionOption.foreground})` a `.plain('read', …, options: {foreground})`. Windows: tlačítka a textové pole podle API fln Windows **[OVĚŘIT]**. Web: bez akcí.
2. Akce jsou jen u notifikací s konverzací (`showConversation` a `showGenericNewMessage` s `conversationId`) a ne u `hidden`.
3. Obsluha v hlavním isolate (R7): `reply` → `OutgoingMessageService.sendText(c, text)` a zrušení notifikace, při chybě notifikace `notifReplyFailed` s tapem do chatu. `read` → `markConversationRead(c)`.
4. Pokud zatím běží jen stub M (`UnimplementedError`), akce se nezobrazí. Řídí to přepínač `NotificationService.actionsEnabled`, který se zapne, až M dodá implementaci. Koordinátor ho zapne při merge.

**ARB:** `notifActionReply`, `notifActionMarkRead`, `notifReplyHint`, `notifReplyFailed`.
**Testy:** fake `OutgoingMessageService` a fake presenter emitující `NotificationResponse` → `sendText` se správným ID. Se stubem M se akce nezaregistrují.

### N11 — Životní cyklus spojení · S · vlna 1 · P1

**Soubor:** `lib/core/notifications/connection_lifecycle.dart` (volá ho `NotificationService.start`).

**Kroky**
1. `AppLifecycleListener`: `resumed` a nepřipojeno → `signalRClient.connect()`. Automatický reconnect po `retryDelaysMs` (`calltype_core/lib/network/signalr_client.dart:45`) po 4 pokusech končí a dnes nic nepřipojí znovu.
2. **Jen iOS:** `paused` → po 3 s `signalRClient.close()`, **pokud neprobíhá hovor** (`WebRTCManager.state` ∈ {idle, ended}). iOS proces stejně uspí a „zombie“ spojení by blokovalo push. Android se neodpojuje. Server zombie spojení pokryje díky `ScheduleUnackedPushCheck` (N3).

**Koordinace s C:** C může řešit reconnect během hovoru. Tento soubor hovor **nikdy** neruší, a pokud C zavede vlastní politiku, sloučí se u koordinátora.

**Testy:** fake lifecycle a fake SignalR: resume → connect, iOS paused s aktivním hovorem → close se nezavolá, Android paused → close se nezavolá.

### N12 — Desktop „N2“: tray, běh na pozadí, spuštění po přihlášení · L · **vlna 2** · P2

**Soubory:** nové `lib/core/notifications/desktop/{tray_controller,desktop_background}.dart`, `assets/tray/` (ikona; `pubspec.yaml` assets dělá X0 vlny 2), ARB, rozšíření `notification_settings_screen.dart`.

**Kroky**
1. `window_manager`: `setPreventClose(true)` na Windows a Linuxu, pokud `notif.desktop.closeToTray == '1'`. `onWindowClose` → `hide()` a při prvním skrytí jednou toast `notifTrayHint`.
2. `tray_manager`: ikona a menu `notifTrayShow`, `notifTrayQuit`. „Ukončit“ volá `windowManager.destroy()` po `signalRClient.close()`. Klik na ikonu → `show()` + `focus()`.
3. `launch_at_startup`: `setup(appName: 'Jay', appPath: Platform.resolvedExecutable)` a enable/disable podle `notif.desktop.launchAtStartup`. Na MSIX **[OVĚŘIT, jestli je potřeba StartupTask v manifestu od P]**.
4. Toasty: N5 už funguje, dokud proces běží, a SignalR v něm zůstává připojený.
5. Badge na Windows: overlay ikona na hlavním panelu **[OVĚŘIT balíček `windows_taskbar` ^1.1.2; jinak P2+]**.
6. Nastavení: dva přepínače (jen desktop).

**ARB:** `notifTrayShow`, `notifTrayQuit`, `notifTrayHint`, `notifDesktopCloseToTray`, `notifDesktopLaunchAtStartup`.
**Testy:** unit test s fake `WindowManager`/`TrayManager` seamy (zavření → hide / quit → destroy). Widget test přepínačů jen na desktopu. Ruční N-10.

### N13 — Dokumentace · S · vlna 1 · P0

- `docs/acceptance/D03-push-handoff.md` přepsat:
  - Firebase konfigurace přes dart-define (4.9).
  - APNs `.p8` na serveru (`Push:Apns:*`) **a zároveň** nahraný do Firebase konzole pro FCM→APNs.
  - Rozhodnutí R1 až R11.
  - Sekci „Known gap“ nahradit popisem, co se zobrazí kde (tabulka platforma × stav aplikace).
  - Omezení: iOS ztlumení u zabité aplikace, web bez hintu, desktop bez pushe.
  - `PushService` API.
- `docs/acceptance/release-builds.md`, sekce „Firebase / push configuration (K04)“: dart-define klíče, entitlements a Localizable.strings, `firebase-messaging-sw.js` existuje. BLOCKED zůstává jen to, co opravdu čeká na vlastníka.
- Řádky N-01 až N-19 do `docs/acceptance/matrix.md` (sekce 7, merguje koordinátor).
- Návrh textu pro CLAUDE.md, odstavec „Push notifications (FCM)“: APNs už není mezera, VoIP přímo, hint.

### N14 — iOS Notification Service Extension · L · vlna 2 · P2

Nový target `ios/JayNotificationService` (Swift, CryptoKit AES.GCM). Extension dešifruje `h` klíčem ze sdíleného Keychain access group a z JSON cache v App Group, kterou zapisuje aplikace (`conversationId → {name, mutedUntil}`), nastaví titulek, `threadIdentifier` a u ztlumených chatů `interruptionLevel = .passive` bez zvuku. Úplné potlačení vyžaduje entitlement `com.apple.developer.usernotifications.filtering` a schválení Applem **[ROZHODNUTÍ později]**. Potřebuje App Group a sdílený Keychain (P), klíč v Keychain s přístupností `afterFirstUnlock` a `aps.mutable-content: 1` (už je v N1).

### N15 — Odpověď z notifikace bez otevření aplikace (Android) · M · vlna 2 · P2

Background response → port `jay.main`. Když hlavní isolate žije, odešle zprávu bez UI. Jinak se text uloží do `Conversations.draft` (jediný zápis, hlavní isolate neběží) a zobrazí se notifikace „Odpověď uložena jako koncept“. Plné odeslání z background isolate vyžaduje serverovou cestu mimo hub (HTTP `POST /messages`) a zámek ratchetu napříč isolaty. Rozhodne spike N16.

### N16 — Spike: stažení a dešifrování v background isolate · M · vlna 2 · P2

Spike ověří, jestli jde u zabité aplikace na Androidu (a u iOS NSE) ukázat skutečný text: HTTP pull fronty (`GET /messages/pending` + ACK, nový endpoint), sdílený drift isolate, serializace ratchetu. Výstupem je `spikes/background-decrypt/REPORT.md`, do `src/` se nic nemerguje.

### Paralelizace uvnitř proudu

- Server (N1 → N3, N2 paralelně s N1) a klient (N4 → N5 → N6/N7/N10/N11, N8 a N9 paralelně s N4) jsou nezávislé větve.
- N3 potřebuje dispatcher z N1 a APNs klienta z N2.
- N5 potřebuje `NotificationService` z N4.
- N13 průběžně, finálně po N8.
- Vlna 2: N12, N14, N15, N16.

| ID | Název | Velikost | Vlna | Priorita |
| --- | --- | --- | --- | --- |
| N1 | FCM podle druhu, dispatcher, coalescing, metriky | M | 1 | P0 |
| N2 | APNs klient (.p8, HTTP/2, VoIP) | M/L | 1 | P0 |
| N3 | Hovorový push, hint, repush, `/push/test` | M | 1 | P0/P1 |
| N4 | Firebase bootstrap, PushService, NotificationService | M | 1 | P0 |
| N5 | Presenter, kanály, MessageNotifier, navigace | L | 1 | P0/P1 |
| N6 | Background handler + hint | M | 1 | P0/P1 |
| N7 | Nastavení notifikací + badge | M | 1 | P1 |
| N8 | Web service worker | M | 1 | P0 |
| N9 | Generátor řetězců (iOS/macOS/web) | S | 1 | P0 |
| N10 | Akce Odpovědět / Přečteno | M | 1 | P1 |
| N11 | Životní cyklus spojení | S | 1 | P1 |
| N12 | Desktop tray a běh na pozadí | L | 2 | P2 |
| N13 | Dokumentace | S | 1 | P0 |
| N14 | iOS NSE | L | 2 | P2 |
| N15 | Odpověď na pozadí (Android) | M | 2 | P2 |
| N16 | Spike background decrypt | M | 2 | P2 |

---

## 7. Přejímka na zařízení (řádky do `docs/acceptance/matrix.md`)

Q01-12 se nahradí těmito řádky. Sloupce: Web desktop · Web iOS Safari (PWA) · Android · Windows · macOS · iOS nativní. Každý řádek musí mít datum UTC, zařízení a OS, protistranu a důkaz.

| ID | Scénář | Očekávání |
| --- | --- | --- |
| N-01 | Aplikace zabitá (swipe), B pošle zprávu | notifikace do 10 s. Android: „Nová zpráva od B“ (hint, `nameOnly`/`nameAndText`). iOS: „Nová zpráva“ v jazyce OS |
| N-02 | Android Doze (displej zhasnutý 30 min, na nabíječce ne) | doručení do 30 s (high priority) |
| N-03 | Klepnutí na notifikaci z N-01 | otevře `/chats/<B>` a zpráva je vidět (iOS a web: `/chats`) |
| N-04 | Popředí: otevřený chat s B vs. jiný chat | u B nic, u jiného chatu notifikace |
| N-05 | Ztlumený chat, aplikace na pozadí a zabitá | Android: nic. iOS zabitá: obecná „Nová zpráva“ (R9, zdokumentované omezení) |
| N-06 | Režimy náhledu × zamčený displej | `nameAndText`/`nameOnly`/`hidden` odpovídají. Na zamčeném Androidu s „skrýt citlivý obsah“ se text neukáže |
| N-07 | Badge ikony | součet nepřečtených neztlumených. Po otevření chatu klesne (iOS, macOS, Android launcher, web PWA) |
| N-08 | Web Chrome/Edge, karta zavřená | notifikace ze service workeru. Klik otevře nebo zaostří Jay na `/#/chats` |
| N-09 | Web iOS Safari PWA (iOS ≥ 16.4, přidáno na plochu) | povolení z tlačítka v nastavení, notifikace dorazí |
| N-10 | Windows: aplikace minimalizovaná; vlna 2: zavřená do trayi; po restartu s autostartem | toast. Klik otevře chat. Tray menu Ukončit ukončí proces |
| N-11 | Nový příspěvek v kanálu, aplikace na pozadí | Android: tichá notifikace „Nové příspěvky“ (max. 1 za 10 min). iOS: podle R6 |
| N-12 | Odinstalace aplikace, pak zpráva na zařízení | server smaže token (log 3003, metrika `token_cleared`) |
| N-13 | Příchozí hovor, Android zabitý (s proudem C) | push `call` do 3 s, UI hovoru podle C. Volající vidí stav `pushed` |
| N-14 | Příchozí hovor, iOS zamčený (s proudem C) | VoIP push → CallKit. Zavěšení volajícího → „Zmeškaný hovor“ |
| N-15 | Volající zavěsí dřív, než callee přijme (Android, iOS) | vyzvánění skončí a zobrazí se zmeškaný hovor |
| N-16 | Nastavení → Odeslat zkušební notifikaci | notifikace dorazí. Bez Firebase: hláška „push není nakonfigurován“ |
| N-17 | Akce Odpovědět a Označit jako přečtené (Android, iOS, macOS) | odpověď dorazí B. Unread = 0 |
| N-18 | Oprávnění zamítnuto | Nastavení ukazuje „Blokováno“ a tlačítko otevře systémové nastavení |
| N-19 | macOS (podepsaný build od P) | notifikace přes FCM a klik otevře chat |

---

## 8. Rizika a otevřené otázky

1. **Deprioritizace FCM:** když high-priority data zprávy často nevedou k viditelné notifikaci (ztlumené chaty), Google je může přestat doručovat okamžitě. Zmírnění: coalescing (R10), ztlumené chaty jsou menšina a metrika poměru. Pokud se to potvrdí, přehodnotit R9 (server-side mute).
2. **Firebase bez nativních souborů:** funkčnost FCM na Androidu jen s Dart `initializeApp(options:)` **[OVĚŘIT]**. Záloha: P přidá `google-services.json` a gradle plugin, kód se nemění.
3. **Dva isolaty nad jednou SQLite:** background handler jen čte, zápis je zakázaný (kromě N15 ve vlně 2). Nejhorší případ při chybě je obecná notifikace, ne ztráta dat.
4. **iOS Keychain v pozadí:** `flutter_secure_storage` na iOS ve výchozím stavu `unlocked`, takže klíč hintu na zamčeném iPhonu v pozadí nepřečte. Na iOS se hint čte až při klepnutí (odemčeno), s NSE (N14) je potřeba `afterFirstUnlock` pro sdílenou položku.
5. **VoIP push pravidla Applu:** každý VoIP push musí skončit `reportNewIncomingCall`, jinak iOS aplikaci ukončí a PushKit přestane doručovat. Proto `call_cancel` nikdy nejde přes VoIP a pending offer TTL (45 s, C) je delší než `CallTtlSeconds` (30 s). Test v N3 hlídá, že se `call_cancel` na APNs voip neposílá.
6. **sandbox vs. production:** token z Debug buildu je sandbox, z TestFlightu production. Klient posílá nápovědu (`kReleaseMode`) a server se opraví podle `BadDeviceToken`. Riziko je jeden zbytečný request navíc.
7. **Jedna instance App Service:** coalescing, repush kontroly a throttle jsou v paměti (stejně jako dnes `ChannelPushThrottle`). Škálování vyžaduje sdílené úložiště spolu s backplane (CLAUDE.md, rozhodnutí 6).
8. **Web:** podpora webu v `flutter_local_notifications` je nová. Payload FCM webpush bez SDK je potřeba ověřit (R5). Safari vyžaduje gesto uživatele pro oprávnění a PWA na ploše.
9. **Business režim:** push nenese obsah ani metadata nad rámec hintu, takže KB1–KB6 se nemění. Auditní zařízení (`jay_archiver`) push token neregistruje. **Otázka:** mají zprávy nouzového kanálu (E07) obcházet ztlumení a mít vlastní Android kanál `jay_emergency` s vyšší prioritou? Doporučení: ano, jako samostatný malý balíček po potvrzení vlastníkem. Klient dnes nemá lokální příznak nouzové skupiny **[OVĚŘIT]**.
10. **Metadata u Googlu a Applu:** vidí token zařízení, čas a `type`, tedy že přišla zpráva nebo hovor. To je neodstranitelné minimum pushe. Uživatelsky viditelný text `notifPrivacyNote` to musí říkat pravdivě.
11. **Závislost na vlastníkovi:** bez Firebase projektu a APNs klíče (O) nejde nic z N-01 až N-19 ověřit na zařízení. Kód a automatické testy na tom nezávisí (fake HTTP handlery).
