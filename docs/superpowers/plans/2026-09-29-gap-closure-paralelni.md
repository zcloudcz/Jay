# Uzavření mezer — paralelní exekuce (koordinátor)

Vychází z `docs/gap-analysis-2026-09-29.md`. Tento soubor obsahuje:
- řez práce na proudy a vlny,
- pravidla vlastnictví souborů,
- graf závislostí a kritickou cestu,
- souhrn rozhodnutí, na která se čeká od vlastníka.

Detailní plány jednotlivých proudů jsou v `2026-09-29-gap-<proud>.md`. Kontrakty mezi proudy, zmrazené ve vlně 0, jsou v **`2026-09-29-gap-contracts.md`** a při rozporu s plánem proudu mají přednost.

Princip je stejný jako u `2026-09-17-bots-channels-paralelni.md`: proudy se řežou podle **vlastnictví souborů**, ne podle funkcí.
- Integrační větev: `feat/gap-closure`.
- Každý proud pracuje ve vlastním worktree na větvi `feat/gc-<id>`.
- Koordinátor merguje po každé vlně, pouští celé testovací sady a slučuje ARB soubory.

## Plány proudů

| ID | Proud | Plán | Balíčky vlny 1 | Balíčky vlny 2 |
| --- | --- | --- | --- | --- |
| **X0** | Základ a kontrakty | `gap-contracts.md` | X0-S ∥ X0-K ∥ X0-A (vlna 0) | X1 (migrace vlny 2) |
| **P** | Platformy, podpis, distribuce, CI | `gap-platform.md` | P1 (ve vlně 0 jako součást X0-A), P2, P3, P4, P5, P9 | P6 macOS, P7 Windows, P8 Linux, P10 aktualizace, P11 staging |
| **N** | Notifikace a push | `gap-notifications.md` | N1–N11, N13 | N12 desktop tray, N14 NSE, N15, N16 |
| **C** | Hovory a vyzvánění | `gap-calls.md` | C01–C12 | C2-1 šifrovaná signalizace, C2-2 více zařízení, C2-3 spike skupinových hovorů, C2-4, C2-5 |
| **M** | Funkce zpráv | `gap-messaging.md` | M01–M07, M09, M10, M12 (M08 při volné kapacitě) | M08, M11 (jen návrh) |
| **M2** | Média a přílohy | `gap-media.md` | M2-1 až M2-9 | M2-10 integrace do chatu |
| **G** | Identita, kontakty, skupiny, profil | `gap-identity-groups.md` | G1–G8 | G9–G12 |
| **S** | Bezpečnost a kryptografie | `gap-security.md` | S1 (oprava IDOR už v X0), S2–S9 | S10 SQLCipher/sqlite3mc, S11 |
| **D** | Více zařízení, zálohy, GDPR | `gap-multidevice.md` | D1–D6, D13 | D7–D12 |
| **O** | Provoz a úkoly vlastníka | `gap-ops.md` | V1–V7, O1–O7 | O8–O10 (O11 jen jako podmínka) |

## Vlastnictví souborů

### Horké soubory (výjimky z běžného vlastnictví)

| Soubor | Pravidlo |
| --- | --- |
| `src/server/CallType.Api/{Data,Models,Migrations}/**` | Jen X0, vlna 1 = jedna migrace. Vlna 2 = X1 (entity D7 a G9/G10). **`CallType.Audit/Migrations` nikdo**, pokud to kontrakt výslovně nepovolí (ruční krok, O2). |
| `calltype_core/lib/storage/{tables,database}.dart` | Jen X0 (v4). Vlna 2 = X1 (v5, jen když je potřeba). |
| `pubspec.yaml` (závislosti), `AndroidManifest.xml`, `Info.plist`, `*.entitlements`, `build.gradle.kts`, `project.pbxproj`, `Podfile` | Jen X0. Ve vlně 1 je P smí měnit jen kvůli podpisu, verzování a `msix_config`. |
| `Hubs/MessengerHub.cs` | X0 → **C** (vlna 1) → **D** (vlna 2). C2-2 až po D8. |
| `Services/PushNotificationService.cs`, `FcmTokenProvider.cs`, nový `Apns*` | **N**. |
| `Endpoints/DeviceEndpoints.cs` | X0 (push-token) → **S**. |
| `Endpoints/PrivacyEndpoints.cs` | **D**. M2-4 a S jen připisují. |
| `Endpoints/GroupEndpoints.cs` | **G** (vlna 1) → **D** (vlna 2, jedna routa). |
| `Endpoints/AuditArchiveEndpoints.cs` | X0 → **M** (M09). |
| `Endpoints/TurnCredentialEndpoints.cs`, nový `CallEndpoints.cs` | **C**. |
| `lib/app/session_overlay.dart` | **S**. C smí měnit jen `_callChanged` a větev hovoru v `build` (K10). |
| `lib/features/chat/**` (včetně `message_bubble.dart`, `message_input.dart`, `inbound/**`), `lib/features/chat_list/**`, `lib/shared/widgets/main_navigation_bar.dart` | **M**. C připisuje záložku Hovory a `MissedCallIndicator`, G banner a lišty, M2 přebírá integraci ve vlně 2. |
| `lib/features/onboarding/onboarding_screen.dart`, `lib/features/settings/identity_screen.dart`, `web/.well-known/**` | **G**. D připisuje tlačítko „Obnovit ze zálohy“. |
| `ios/Runner/AppDelegate.swift`, `android/.../MainActivity.kt`, nativní kód hovorů | **C**. N připisuje delegáta notifikací (už v X0). |
| `lib/core/storage/secure_storage.dart` | X0 → **S** (ostatní jen přidávají metody). |
| `lib/app/router.dart`, `lib/main.dart`, `lib/features/settings/settings_screen.dart` | Kdokoli, **jen připisovat**. Merguje koordinátor. |
| `lib/l10n/app_*.arb` | Kdokoli, **jen klíče s prefixem proudu** (contracts §6.4), vždy ve všech 19 jazycích. Koordinátor slučuje sjednocením klíčů. |
| `calltype_core/lib/network/{api_client,signalr_client}.dart` | Kdokoli, **jen nové metody**. Nic nepřejmenovávat. |
| `CLAUDE.md` (tabulky entit a endpointů, Known limitations) | Jen koordinátor po merge vlny. Návrhy textu dodávají proudy. |
| `docs/security/crypto-baseline.md` | **S**. N, M2 a D dodávají text. |

### Výhradní vlastnictví

Výhradní vlastnictví ostatních souborů je uvedené v oddílu 3 každého plánu proudu.

## Vlny

| Vlna | Co | Podmínka startu | Hotovo, když |
| --- | --- | --- | --- |
| **0-V** (hned) | Úkoly vlastníka V1–V7, O1, O2 (`gap-ops.md` §6) | — | Účty a secrets existují. Beta DB je opravená. **O2 musí proběhnout před jakýmkoli dalším deployem.** |
| **0** | X0-S ∥ X0-K ∥ X0-A (`gap-contracts.md` §1) | Potvrzený identifikátor (V1) a iOS 15 (R-C1) | `gap-contracts.md` §7 bod 1–5 |
| **0.5** | Nasazení buildu X0 na betu: API, web, archivátor, boti | Souhlas vlastníka, public okno nebo opravený billing | Beta běží s tolerancí neznámých typů (K14) |
| **1** | P ∥ N ∥ C ∥ M ∥ M2 ∥ G ∥ S ∥ D(1) ∥ O(kód) | Merge X0 | Každý proud splnil kritéria svých balíčků. Koordinátor zmergoval a všechny sady jsou zelené. |
| **2** | X1 → D(2) ∥ M2-10 ∥ C2 ∥ S2 ∥ N12/N14–16 ∥ G9–G12 ∥ P6–P8, P10, P11 ∥ O8–O10 | Merge vlny 1 | Totéž |
| **3** | Přejímka na zařízeních (`docs/acceptance/matrix.md`, řádky z oddílu 7 každého plánu), vydání | Podepsané buildy z P | Vlastník |

### Pořadí uvnitř vlny 1

Každý plán ho má v oddílu 6.

| Proud | Pořadí |
| --- | --- |
| **P** | P9 (CI) → P2, P3b → P4, P5 |
| **N** | N1, N2, N4, N8 paralelně → N3, N5, N6 → N7, N9–N11 → N13 |
| **C** | C01 ∥ C02 ∥ C03 (C03 první den zmrazí API `WebRTCManager`) → C04–C11 → C12 |
| **M** | M01 → M02 → M03 → M04–M07, M09, M10 → M12 |
| **M2** | M2-1 ∥ M2-2 ∥ M2-3 ∥ M2-6 → M2-4, M2-5 → M2-7 ∥ M2-8 → M2-9 |
| **G** | G1 ∥ G2 ∥ G3 → G4–G8 |
| **S** | Server: S1 → S2.<br>Jádro: S3 → S6 → S4.<br>S5 paralelně s oběma.<br>Aplikace: S7 → S8.<br>S9 na konec. |
| **D** | D1 ∥ D2 ∥ D3 ∥ D5 → D4, D6 → D13 |

## Závislosti mezi proudy ve vlně 1

Všechny závislosti jdou přes stuby X0, takže nikdo nečeká na hotový kód jiného proudu. Závislý proud ale může funkci **ověřit na zařízení** až po merge dodavatele:

| Kdo | Na čem | Kontrakt | Blokuje ověření |
| --- | --- | --- | --- |
| C | N: doručení hovorového pushe (FCM/APNs VoIP) | K5, K6, KC4 | příchozí hovor při zabité aplikaci |
| C, N | P: podepsaný build + Firebase konfigurace; O: V3, V4 | firebase_config, entitlements | vše na zařízení |
| G (avatar), D (přenos historie ve vlně 2) | M2: `AttachmentService` | contracts §5 | avatar |
| G (UI) | S: `SafetyNumber`, API identity | K9 | ověření kontaktu |
| M, G, N, C | G: `PeerDirectory` | K8 | jména, blokace |
| G, D | M: `OutgoingMessages.sendControl` | K4 | distribuce profilu a `group-update` |
| N | M: `markConversationRead`, `ActiveConversation` | K4 | akce „Přečteno“ |
| D6 (obnova) | S6 + G6: UI změny klíče | K9 | užitečnost obnovy (kontakty vidí změnu klíče) |
| M2 | M: `ChatExtensions` | contracts §5 | jen vlna 2 |

## Kritická cesta k aplikacím na telefonu s vyzváněním

1. **Vlastník: V1 (identifikátor), V3 (Firebase), V4 (Apple + .p8), V5 (Play).** Nejčastěji zdržuje právě tohle.
2. **X0** (týden práce agentů, tři části paralelně) → **W0.5 nasazení**.
3. **P4/P5** podepsané buildy ∥ **N1–N6** push ∥ **C02, C03, C06** hovory.
4. Přejímka na fyzickém iPhonu a Androidu. VoIP push a CallKit v simulátoru nejdou.

Vše ostatní (M, M2, G, S, D) jde souběžně a na kritické cestě není.

## Rozhodnutí vlastníka

### Blokují X0

| # | Rozhodnutí | Doporučení | Plán |
| --- | --- | --- | --- |
| R-O1 / R-P1 | Identifikátor aplikace | **POTVRZENO 2026-09-29: `cz.zcloud.jay`** | ops, platform |
| R-C1 | `flutter_callkit_incoming` a **iOS 15 jako minimum** | **POTVRZENO 2026-09-29** | calls |
| R-C2 | Každý hovor na iOS přes CallKit | **POTVRZENO 2026-09-29** (důsledek: vyloučit čínský App Store) | calls |
| K2 | Archivní kind `other` pro neznámé typy | ano | contracts |
| R-O2 | GitHub billing | **ROZHODNUTO 2026-09-29: neopravovat, CI a deploy dál v public okně** (platí R-P2) | ops, platform R-P2 |

### Blokují start konkrétního proudu

Doporučení je vždy uvedené v oddílu 2 příslušného plánu.

| Proud | Rozhodnutí |
| --- | --- |
| **N** | R1 iOS hybridně (FCM + přímé APNs pro VoIP), R2 šifrovaný hint v pushi, R3 výchozí náhled „jméno + text“ |
| **C** | R-C3 až R-C13 (tóny, STUN záloha Cloudflare, TTL 45 s, `declineToken`, jméno volajícího nad zámkem, záložka Hovory) |
| **M** | R-1 potvrzení o přečtení zapnutá a reciproční, R-2 psaní zůstane přes hub a vypínatelné, R-4/R-5 úprava a smazání do 24 h, R-12 bez stavu online |
| **M2** | R1 přístup k blobu jako capability, R3 limity (100 MiB na přílohu, 1 GiB na zařízení a den), R5 hlasovky AAC/m4a, R6 obrázky bez EXIF |
| **G** | R1 komu posílat profil, R3/R4 změna klíče se nikdy nepřijme automaticky, R5 blokace jen na klientovi, R8 HTTPS odkazy + `usePathUrlStrategy` |
| **S** | R2 PIN přes PBKDF2 200k, R3 prodlevy a volitelný wipe, R6 ochrana obrazovky jako volba, R7 rotace SPK po 30 dnech |
| **D** | D-1 více zařízení jen pro registrované účty, D-2 identita per zařízení + podepsaný seznam, D-4 žádný serverový lookup vazby zařízení↔účet, D-6 business konverzace se nesynchronizují, D-7/D-8 automatická záloha |
| **P** | R-P3 až R-P13 (Play přes r0adkll, export compliance ručně, Windows MSIX + Artifact Signing, macOS dmg, Linux AppImage, soubory ke stažení v Blob `downloads`) |
| **O** | R-O3 archivátor na DB serveru, R-O4 skupinové hovory (až po spiku C2-3) |

## Nálezy chyb, které plány opravují

Nálezy ověřily plánovací agenty v kódu.

| Nález | Oprava |
| --- | --- |
| `PUT /devices/{id}/push-token` neověřuje vlastníka zařízení (IDOR) | X0 |
| Android auto-backup vynáší nešifrovanou SQLite do Google Drive | X0 manifest |
| Obnova zálohy spadne, pokud historie obsahuje `call-event`; po obnově se vlastní zprávy zobrazí jako přijaté | D3 |
| `DELETE /accounts` nevyžaduje MFA | D2 |
| Výpadek TURN (503) shodí hovor | C04 |
| Vyčerpání cizích 100 OPK za minutu jedním zařízením | S2 |
| Hub čeká sekvenčně na FCM pro každého offline příjemce | N1 |
| Push se po onboardingu zaregistruje až po restartu aplikace | N4 |
| Push nebere v úvahu web v prohlížeči na Windows a Linuxu (chybí `!kIsWeb`) | N4 |

## Známá omezení prostředí

- Flutter SDK ani Docker nemusí v prostředí agentů běžet. Testcontainers a `flutter test` se pak ověřují v hosted CI.
- CI dnes běží jen v public okně se souhlasem vlastníka, dokud se neopraví billing (R-O2).
- Každý proud to musí ve výstupu přiznat a netvrdit PASS bez běhu.
