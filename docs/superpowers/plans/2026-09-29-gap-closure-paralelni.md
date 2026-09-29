# Uzavření mezer — paralelní exekuce (NÁVRH, koordinátor)

Vychází z `docs/gap-analysis-2026-09-29.md`. Tento soubor je **řez na proudy a vlny + pravidla vlastnictví souborů**. Detailní plán každého proudu je v `2026-09-29-gap-<proud>.md`, kontrakty mezi proudy (zmrazené ve vlně 0) v `2026-09-29-gap-contracts.md`.

Stejný princip jako `2026-09-17-bots-channels-paralelni.md`: proudy se řežou podle **vlastnictví souborů**, ne podle feature. Paralelní proudy nesmějí sdílet „horké“ soubory — ty mění jen vlna 0 (X0), nebo platí pravidlo „jen připisovat“ a konflikty řeší koordinátor.

## Horké soubory

| Soubor | Pravidlo |
| --- | --- |
| `src/server/CallType.Api/Data/AppDbContext.cs`, `Migrations/**`, `Models/**` | **Jen X0** (jedna EF migrace pro všechny proudy vlny 1). Vlna 2 má vlastní jednu migraci. |
| `src/client/calltype_core/lib/storage/{tables,database}.dart` | **Jen X0** (jedno `schemaVersion` 3→4). |
| `src/client/calltype/pubspec.yaml` (závislosti), `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`, entitlements, `macos/Runner/*.entitlements` | **Jen X0** (všechny nové balíčky, oprávnění a background modes najednou, ověřeno buildem všech platforem). Výjimka: P smí měnit signing / identifikátory / `msix_config`. |
| `src/server/CallType.Api/Hubs/MessengerHub.cs` | Vlna 1: **jen C** (hovory). Vlna 2: D. |
| `src/server/CallType.Api/Services/PushNotificationService.cs` (+ nový APNs klient) | **Jen N**. Rozhraní pro hovorový push zmrazí X0 (stub). |
| `src/server/CallType.Api/Endpoints/DeviceEndpoints.cs` | **Jen S** (pre-keys, oprava autorizace push-token). Rozšíření platforem push tokenu dělá X0. |
| `lib/app/router.dart`, `lib/main.dart`, `lib/features/settings/settings_screen.dart` | Kdokoli, **jen připisovat** (nová routa / nová služba / nová položka). Koordinátor merguje. |
| `lib/l10n/app_*.arb` (19 souborů) | Kdokoli, **jen připisovat klíče s prefixem proudu**. Každý klíč ve všech 19 jazycích. Koordinátor při merge dělá sjednocení klíčů. |
| `calltype_core/lib/network/{api_client,signalr_client}.dart` | Kdokoli, **jen přidávat metody**. Nic nepřejmenovávat ani neměnit signatury. |

## Proudy

| ID | Proud | Plán | Jádro vlastnictví |
| --- | --- | --- | --- |
| **X0** | Základ a kontrakty (vlna 0, sekvenčně) | `2026-09-29-gap-contracts.md` | horké soubory výše, tolerance neznámých typů zpráv |
| **P** | Platformy, podpis, distribuce, CI | `2026-09-29-gap-platform.md` | `android/` (gradle, signing), `ios/`+`macos/` xcodeproj, `windows/`, `linux/` (nový), `.github/workflows/**` |
| **N** | Notifikace a push (server + klient + desktop) | `2026-09-29-gap-notifications.md` | `PushNotificationService.cs`, `FcmTokenProvider.cs`, nový `Apns*`, `lib/core/network/push_service.dart`, `lib/core/notifications/**`, `web/firebase-messaging-sw.js` |
| **C** | Hovory a vyzvánění | `2026-09-29-gap-calls.md` | `MessengerHub.cs` (vlna 1), `TurnCredentialEndpoints.cs`, `lib/core/network/webrtc_manager.dart`, `lib/features/calls/**`, `ios/Runner/AppDelegate.swift`, nativní kód Androidu pro hovory, `assets/sounds/**` |
| **M** | Zprávy: potvrzení, psaní, odpověď, úprava, smazání, reakce, koncepty, hledání, ztlumení | `2026-09-29-gap-messaging.md` | `lib/features/chat/**`, `lib/features/chat_list/**`, `lib/shared/widgets/message_*.dart`, typy zpráv v `src/bots/**` (vlastní receivery) |
| **M2** | Média: šifrované bloby, obrázky, video, hlasovky | `2026-09-29-gap-media.md` | `Endpoints/AttachmentEndpoints.cs` (nový), `Services/E2eAttachment*` (nový), `lib/core/attachments/**`, `lib/features/media/**` |
| **G** | Kontakty, skupiny, profil, ověření identity, pozvánky | `2026-09-29-gap-identity-groups.md` | `lib/features/{contacts,groups,profile}/**`, `www/.well-known/**` |
| **S** | Bezpečnost a krypto | `2026-09-29-gap-security.md` | `calltype_core/lib/crypto/**`, `lib/core/auth/**`, `DeviceEndpoints.cs`, `docs/security/**` |
| **D** | Více zařízení, zálohy, GDPR UI (vlna 2) | `2026-09-29-gap-multidevice.md` | `lib/features/backup/**`, `lib/features/devices/**` (nový), `lib/features/settings/account*`, hub ve vlně 2 |
| **O** | Provoz a infrastruktura | `2026-09-29-gap-ops.md` | `infra/**`, `docs/ops/**` |

## Vlny (návrh, finální verzi doplní koordinátor)

| Vlna | Co | Poznámka |
| --- | --- | --- |
| 0 | **X0** + úkoly vlastníka z O (Firebase, Apple, billing, beta DB skripty) | X0 je krátký, mechanický a sekvenční. Úkoly vlastníka běží souběžně. |
| 1 | P, N, C, M, M2, G, S, O (kód) | Plně paralelně proti kontraktům X0 |
| 2 | D, M2 integrace do chatu, C2 (skupinové hovory, spike SFU), S2 (SQLCipher), N2 (desktop tray) | Po merge vlny 1 |
| 3 | Přejímka na zařízeních (vlastník), vydání | `docs/acceptance/matrix.md` |
