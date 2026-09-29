# Proud P — platformy, podpis, distribuce, CI (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Dodrž vlastnictví souborů (oddíl 3) a kontrakty X0 (oddíl 4). Nic nenasazuj a nic nenahrávej do obchodů. Každé public okno GitHubu, každý deploy a každé nahrání do Play/App Store/Partner Center schvaluje vlastník zvlášť (CLAUDE.md, oddíl Deploy).

**Goal:** Aby šel Jay dát lidem do ruky mimo prohlížeč. Jeden identifikátor `cz.zcloud.jay` na všech platformách. Podepsané buildy: Android AAB přes Play interní testování, iOS přes TestFlight, macOS Developer ID + notarizace (dmg), Windows MSIX. Nově Linux (AppImage). Jedno číslo verze a buildu pro všechny platformy, zobrazené v nastavení. Firebase konfigurace se do buildu dostane ze secrets a nikdy se necommituje.

**Architecture:** Build a podpis zůstávají v GitHub Actions, spouštěné ručně a připnuté na SHA (stejný model jako `deploy.yml`). Nový dispečer `release-native.yml` volá pro každou platformu jeden reusable workflow `_release-<platform>.yml`. Každý z nich běží ve vlastním GitHub environmentu, který drží jen své podpisové secrets. Testy klienta se sdílí přes reusable `_client-tests.yml`. `deploy.yml` dál nasazuje API + web a nativní buildy z něj odcházejí. Verze se počítá jedním skriptem `.github/scripts/version.sh`. Firebase konfiguraci materializuje skript `.github/scripts/firebase-config.sh` z base64 secrets do git-ignorovaných souborů a do `--dart-define-from-file`. Aplikace čte Firebase options přes `lib/core/config/firebase_config.dart`, který vlastní P a konzumuje N.

**Tech Stack:** GitHub Actions (hosted runnery, public okno), Gradle Kotlin DSL + R8, Xcode `xcodebuild archive/-exportArchive` s App Store Connect API klíčem (cloud signing), `notarytool`/`stapler`/`hdiutil`, `msix` (pub) + Azure Artifact Signing (dřív Trusted Signing), `appimagetool`, `package_info_plus`.

**Zdroje:** `docs/gap-analysis-2026-09-29.md` (oddíl 1), `docs/superpowers/plans/2026-09-29-gap-closure-paralelni.md`, `docs/superpowers/plans/2026-09-29-gap-ops.md` (V1–V7, O6), `docs/acceptance/{release-builds,ios-testflight,D03-push-handoff,matrix}.md`.

---

## 0. Současný stav (ověřeno v kódu, cesty relativně k `src/client/calltype/`)

| Oblast | Stav | Důkaz |
| --- | --- | --- |
| Android identifikátor | `namespace` i `applicationId` = `com.example.calltype` | `android/app/build.gradle.kts:9,24`; `android/app/src/main/kotlin/com/example/calltype/MainActivity.kt:1` |
| Android release podpis | debug klíč | `android/app/build.gradle.kts:33-38` |
| Android minifikace | není explicitně nastavená, chybí `proguard-rules.pro` | `android/app/build.gradle.kts` (žádné `isMinifyEnabled`) |
| Android keystore v gitu | správně ignorováno (`key.properties`, `*.jks`, `*.keystore`) | `android/.gitignore` |
| Android auto-backup | `android:allowBackup` není nastaveno (výchozí `true`), tedy Google záloha by kopírovala plaintext SQLite | `android/app/src/main/AndroidManifest.xml:13-17` |
| iOS bundle id | `cz.zcloud.jay` (Debug/Release/Profile) | `ios/Runner.xcodeproj/project.pbxproj:375,554,576` |
| iOS tým / entitlements | žádný `DEVELOPMENT_TEAM`, žádný `CODE_SIGN_ENTITLEMENTS`, soubor `Runner.entitlements` neexistuje | `grep` v `ios/Runner.xcodeproj/project.pbxproj`; `ls ios/Runner` |
| iOS `CFBundleName` | `calltype` | `ios/Runner/Info.plist:39-40` |
| iOS export compliance | `ITSAppUsesNonExemptEncryption` záměrně chybí | `docs/acceptance/ios-testflight.md` („Known limits“) |
| TestFlight workflow | archiv se staví **bez podpisu** (`flutter build ipa --no-codesign`) a podepisuje se až při exportu. Build number = `github.run_number` | `.github/workflows/ios-testflight.yml:98-102,121-130` |
| macOS bundle id | `com.calltype.calltype`, `PRODUCT_NAME = calltype` (uživatel vidí `calltype.app`) | `macos/Runner/Configs/AppInfo.xcconfig:8,11,14` |
| macOS podpis | ad-hoc `CODE_SIGN_IDENTITY = "-"`, bez hardened runtime, sandbox zapnutý, `keychain-access-groups` v entitlements | `macos/Runner.xcodeproj/project.pbxproj:450,526,582,630`; `macos/Runner/Release.entitlements` |
| Windows | `CompanyName`/`LegalCopyright` = `com.calltype`, exe `calltype.exe`, distribuce jen zip složky Release | `windows/runner/Runner.rc:92,96`; `windows/CMakeLists.txt:7,11`; `.github/workflows/deploy.yml:290-295` |
| Linux | složka `linux/` neexistuje. Kód na Linux už pamatuje (QR skener a push jsou vypnuté), `local_auth` chyby odchytává | `lib/app/router.dart:150-156`; `lib/core/network/push_service.dart:126-130`; `lib/core/auth/app_lock.dart:92-101` |
| Ikony | `flutter_launcher_icons` generuje Android/iOS/web/Windows/macOS, Linux ne. Master je 1024×1024 | `pubspec.yaml:83-101`; `assets/brand/jay-icon.png` |
| Verze | `version: 1.0.0+1` natvrdo. `deploy.yml` nepředává `--build-name/--build-number`. V nastavení je `'1.0.0'` natvrdo | `pubspec.yaml:4`; `.github/workflows/deploy.yml:283`; `lib/features/settings/settings_screen.dart:105-111` |
| Firebase | `Firebase.initializeApp()` bez options, v repu nejsou žádné konfigurační soubory | `lib/core/network/push_service.dart:40`; `docs/acceptance/release-builds.md` (K04) |
| API URL | `String.fromEnvironment('API_BASE_URL')` | `lib/main.dart:46-49` |
| CI | `ci.yml` = testy + sanity build 5 platforem s neplatnou URL. `deploy.yml` = testy + API + 5 nepodepsaných klientů s manifestem + nasazení API/web | `.github/workflows/ci.yml:143-208`; `.github/workflows/deploy.yml:211-330` |
| GitHub Actions | na privátním repu nestartují (billing), běží jen v public okně | `docs/HANDOFF-2026-09-18.md:9` |

---

## 1. Cíl a rozsah

| Priorita | Co | Balíček |
| --- | --- | --- |
| **P0** | Sjednotit identifikátory před prvním nahráním do obchodu (později nejdou změnit) | P1 (vlna 0) |
| **P0** | Jednotné verzování a verze v nastavení z `package_info_plus` | P2 |
| **P0** | Firebase konfigurace ze secrets do buildu (web, Android, iOS, macOS) | P3 (stub ve vlně 0) |
| **P0** | Android: upload keystore, `signingConfig`, R8, AAB, Play interní testování | P4 |
| **P0** | iOS: tým, entitlements, podepsaný archiv, první TestFlight, export compliance | P5 |
| **P0** | CI: reusable testy, dispečer `release-native.yml`, úprava `deploy.yml`/`ci.yml`, kontrola identifikátorů, seznam secrets | P9 |
| P2 | macOS Developer ID + notarizace + dmg | P6 |
| P2 | Windows MSIX + podpis (Artifact Signing) a/nebo Microsoft Store | P7 |
| P2 | Linux runner + AppImage | P8 |
| P2 | Distribuce desktopu mimo obchod: `latest.json`, kontrola aktualizací v aplikaci, stránka ke stažení | P10 |
| P2 | `deploy.yml` přes staging (kontrakt O6) | P11 (vlna 2) |

**Mimo rozsah:** push kód (N), nativní kód hovorů a CallKit (C), obsah entitlements a oprávnění v manifestech (X0), infrastruktura v `infra/**` (O), tray a notifikace na desktopu (N2), Mac App Store (případně později), Flatpak/Flathub, Sparkle/WinSparkle auto-update frameworky.

---

## 2. Rozhodnutí k potvrzení vlastníkem

- **[ROZHODNUTÍ] R-P1 Identifikátor** (= R-O1/V1): `cz.zcloud.jay` všude (Android `applicationId` + `namespace`, iOS, macOS, Linux `APPLICATION_ID`, MSIX identity pro přímou distribuci).
  - Důsledek jiné volby: iOS už `cz.zcloud.jay` má. Jiný identifikátor = změna i na iOS a nové App ID u Applu.
  - Po prvním uploadu do Play/App Store ho nejde změnit.
  - Existující nativní instalace (všechny jsou NOT_RUN) po změně přijdou o lokální data. Jde o novou aplikaci.
- **[ROZHODNUTÍ] R-P2 Kde běží podepisování:** doporučeno **GitHub Actions v public okně**, jen `workflow_dispatch`, podpisové secrets v environmentech s povinným schválením vlastníkem.
  - Proč to v public okně jde, i přes obavu v R-O2:
    - secrets se nikdy nepředávají do `pull_request` z forků,
    - `ci.yml` žádné podpisové secrets nečte,
    - všechny akce třetích stran jsou připnuté na SHA,
    - klíče se dekódují jen do `$RUNNER_TEMP` a mažou se přes `trap`.
  - Co v public okně zůstává veřejné:
    - logy běhu,
    - artefakty (stáhne je kterýkoli přihlášený uživatel GitHubu). Podepsané AAB/MSIX/dmg jsou distribuovatelné binárky, to je přijatelné.
    - Nikdy se nenahrává keystore, `.p8` ani `.p12`.
  - Alternativa A: opravit billing (R-O2). Plán funguje beze změny, jen odpadne přepínání viditelnosti.
  - Alternativa B: podepisovat lokálně na Macu/Windows vlastníka. Neopakovatelné, bez manifestu. Nedoporučeno.
  - **[OVĚŘIT]** Environment secrets a povinní schvalovatelé na **privátním** repu vyžadují placený plán (GitHub Free je u privátních rep nemá). Environmenty `calltype-beta` a `apple-testflight` už existují. Ověřit, že fungují i po návratu na private. Pro public okno to nevadí.
  - Hosted runnery včetně macOS jsou pro public repa zdarma **[OVĚŘIT aktuální ceník]**, public okno tedy zároveň odstraňuje náklad 10× macOS minut.
- **[ROZHODNUTÍ] R-P3 Nahrávání do Google Play:** doporučeno **`r0adkll/upload-google-play` v1.1.5** připnuté na SHA **[OVĚŘIT SHA tagu v1.1.5]**.
  - Proč: jeden krok bez Ruby, vstupy `serviceAccountJsonPlainText`, `packageName`, `releaseFiles`, `track`, `status`, `mappingFile`.
  - Alternativa fastlane `supply`: víc možností (metadata, screenshoty), ale Ruby toolchain na runneru a další supply-chain závislost. Vyplatí se až při správě listingu z repa.
- **[ROZHODNUTÍ] R-P4 Export compliance iOS (`ITSAppUsesNonExemptEncryption`):**
  - Fakta:
    - Jay **sám implementuje** standardní algoritmy (X25519, AES-256-GCM, HKDF, Ed25519 v pure Dart, `calltype_core/lib/crypto`). Nepoužívá jen šifrování OS.
    - Podle tabulky Applu („Export compliance documentation for encryption“) platí pro *standardní algoritmy*: dokumentace = **jen francouzská deklarace**, a to jen při distribuci v App Store ve Francii.
    - Pro *šifrování jen v OS* se dokumentace nevyžaduje.
    - Klíč `NO` je podle Applu určen pro aplikace, které šifrování nepoužívají, nebo používají jen formy „exempt from export compliance documentation requirements“.
  - Doporučení:
    1. **Teď:** klíč **nenastavovat** (dnešní stav) a u každého TestFlight buildu vyplnit dotazník v App Store Connect ručně: standardní algoritmy ano, proprietární ne, distribuce ve Francii ne. Uploady jsou vzácné a odpovědi jsou právní prohlášení vlastníka účtu.
    2. **Souběžně:** podat francouzskou deklaraci (ANSSI) **[OVĚŘIT formulář a lhůtu s právníkem]**, nahrát ji do App Store Connect a získaný kód dát do Info.plist jako `ITSEncryptionExportComplianceCode` + `ITSAppUsesNonExemptEncryption = YES` (změna Info.plist je X0/hot soubor, provede se přes koordinátora).
    3. **US strana:** mass-market podle EAR 740.17(b)(1). Zda je potřeba roční self-classification report pro BIS, musí potvrdit právník **[OVĚŘIT]**.
  - Důsledek volby `NO` + vyloučení Francie: rychlejší. Jde ale o tvrzení vlastníka o výjimce, které při pozdějším zpřístupnění ve Francii přestane platit.
  - Microsoft Store (Partner Center) a Google Play kladou podobnou otázku při odeslání. Odpovídat konzistentně.
- **[ROZHODNUTÍ] R-P5 Android distribuce:** doporučeno **jen Google Play** (interní testování → uzavřené → produkce).
  - Přímé APK nepodepisovat upload klíčem pro testery. APK podepsané upload klíčem má jiný podpis než instalace z Play (Play App Signing), takže mezi kanály nejde aktualizovat.
  - Nepodepsané/debug APK zůstává jen jako CI sanity artefakt.
  - Alternativa: Play App Signing s vlastním nahraným app signing klíčem, se kterým jde APK distribuovat i mimo Play. Víc odpovědnosti za klíč, nedoporučeno.
- **[ROZHODNUTÍ] R-P6 Typ vývojářského účtu Google Play:** doporučen **účet organizace** (ZCloud). Potřebuje D-U-N-S (vyřízení dny až týdny).
  - Osobní účty založené po 11/2023 musí před produkcí projít uzavřeným testem s ≥ 12 testery po 14 dní **[OVĚŘIT aktuální pravidlo]**. Interní testování to neblokuje.
- **[ROZHODNUTÍ] R-P7 Obfuskace Dartu:** doporučeno **ne** (`--obfuscate` vypnuto), ale **ano** `--split-debug-info` (menší binárka, symboly se ukládají jako artefakt pro symbolizaci).
  - Proč: protokol je otevřený, obfuskace nic nechrání a zhoršuje čitelnost stack traců v hlášeních.
  - R8 pro Java/Kotlin zapnuté (zmenšení APK).
- **[ROZHODNUTÍ] R-P8 Windows kanál:**
  - Doporučeno **přímé MSIX podepsané přes Azure Artifact Signing** + soubor `.appinstaller` (Windows si aktualizace stahuje sám). Microsoft Store až ve druhém kroku.
  - Podmínka: Artifact Signing (Public Trust) je pro **organizace** v EU, pro jednotlivce jen v USA/Kanadě. ZCloud musí být právnická osoba s ověřitelnou historií **[OVĚŘIT požadavky validace a cenu ~10 USD/měsíc]**.
  - Když ZCloud podmínku nesplní: **jen Microsoft Store** (Store balíček re-signuje Microsoft, certifikát netřeba, auto-update zdarma, ale review a listing).
  - Store MSIX a přímé MSIX mají různou package identity. Uživatel mezi nimi neaktualizuje a data mají oddělená.
- **[ROZHODNUTÍ] R-P9 macOS kanál:** doporučeno **Developer ID + notarizace + dmg**, ke stažení mimo obchod. Mac App Store (sandbox už je zapnutý) až podle poptávky.
- **[ROZHODNUTÍ] R-P10 Linux formát:** doporučen **AppImage** (jeden soubor, běží na většině distribucí bez instalace, bez repozitáře) + `tar.gz` jako záloha.
  - Flatpak/Flathub je lepší pro auto-update a sandbox, ale build Flutteru offline v Flathub manifestu je pracný. Až podle poptávky.
  - `.deb` nedoporučen: jen Debian/Ubuntu a vlastní závislosti.
- **[ROZHODNUTÍ] R-P11 Kde leží desktopové soubory ke stažení:** repo je privátní, GitHub Releases tedy veřejně nefungují. Static Web App Free má limit velikosti aplikace **[OVĚŘIT 250 MB]**.
  - Doporučen **samostatný veřejný Blob kontejner `downloads`** (nový storage account nebo static website, **ne** stávající privátní account s přílohami). Volitelně vlastní doména `download.jay.zcloud.cz`. Infra zakládá O (požadavek v oddílu 5).
  - Aktualizace: MSIX přes `.appinstaller`, macOS/Linux přes banner v aplikaci podle `latest.json` (P10). Žádný Sparkle.
- **[ROZHODNUTÍ] R-P12 Firebase na iOS/macOS:** jde FCM přes APNs (Firebase aplikace iOS), nebo přímé APNs? Rozhoduje N.
  - P dodá obě cesty konfigurace: Dart options vždy, `GoogleService-Info.plist` volitelně.
  - Když N zvolí přímé APNs pro iOS i macOS, secret `FIREBASE_APPLE_*` odpadá.
- **[ROZHODNUTÍ] R-P13 Název aplikace v souborovém systému:** macOS `PRODUCT_NAME = Jay` (uživatel vidí `Jay.app`, ne `calltype.app`).
  - Windows exe a Linux binárka zůstávají `calltype` (interní jméno, uživatel vidí jen `DisplayName`/`.desktop` = Jay).
  - iOS `CFBundleName` → `Jay` (Info.plist, X0).

---

## 3. Vlastnictví souborů

**Výhradně vlastní (P):**
- `src/client/calltype/android/build.gradle.kts`, `android/settings.gradle.kts`, `android/gradle.properties`, `android/app/build.gradle.kts`, `android/app/proguard-rules.pro` (nový), `android/.gitignore`
- `android/app/src/main/kotlin/cz/zcloud/jay/MainActivity.kt`: **jen přesun v P1 (vlna 0)**, pak ho vlastní C (nativní kód hovorů)
- `ios/Runner.xcodeproj/**`, `ios/Flutter/*.xcconfig`, `ios/Podfile`, `ios/ci/**`
- `macos/Runner.xcodeproj/**`, `macos/Runner/Configs/**`, `macos/ci/**` (nový)
- `windows/CMakeLists.txt`, `windows/runner/Runner.rc`, `windows/packaging/**` (nový). N2 ve vlně 2 smí sahat do `windows/runner/*.cpp` (tray).
- `linux/**` (nový)
- `.github/**` (workflows, `scripts/`)
- `src/client/calltype/.gitignore`
- `lib/core/config/**` (nový), `lib/core/update/**` (nový), `lib/shared/widgets/app_version_label.dart` (nový), `lib/shared/widgets/update_banner.dart` (nový)
- `web/firebase-config.js` (nový). `web/firebase-messaging-sw.js` vlastní N.
- `www/download.html` (nový, P10)
- `docs/acceptance/release-builds.md`, `docs/acceptance/ios-testflight.md`, `docs/acceptance/android-play.md` (nový), `docs/acceptance/desktop-release.md` (nový)
- testy: `test/core/config/**`, `test/core/update/**`, `test/shared/widgets/app_version_label_test.dart`, `test/shared/widgets/update_banner_test.dart`

**Jen připisuje (horké soubory):**
- `pubspec.yaml`: jen řádek `version:` (politika v P2) a blok `msix_config:` (výjimka z tabulky horkých souborů). Závislosti přidává X0.
- `lib/features/settings/settings_screen.dart`: nahrazení `Text(l10n.settingsVersion('1.0.0'))` (`:105-111`) widgetem `AppVersionLabel()`. Jedna změna v sekci About.
- `lib/main.dart`: jedno volání `UpdateChecker` (P10) za inicializací služeb.
- `lib/l10n/app_*.arb`: klíče s prefixem **`plat`** (P10), všech 19 jazyků.
- `docs/acceptance/matrix.md`: nové řádky R-xx (oddíl 7).

**Jen čte:** `lib/core/network/push_service.dart` (N), `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist`, `ios/Runner/Runner.entitlements`, `macos/Runner/*.entitlements`, `macos/Runner/Info.plist` (X0), `infra/**` (O), `www/.well-known/**` (G).

---

## 4. Požadavky na X0 (kontrakty)

Proud P nemění server, drift schema, hub ani typy zpráv. **Žádná EF migrace, žádná tabulka v schema v4, žádný nový typ zprávy.** Požadavky:

### X0-P1: zařadit balíček P1 do vlny 0
P1 (oddíl 6) je mechanický a na jeho výsledku závisí C (Kotlin kód v `android/app/src/main/kotlin/cz/zcloud/jay/`), N (registrace aplikací ve Firebase podle package name) i G (`assetlinks.json`, AASA). Proto musí proběhnout **před** vlnou 1: buď ho provede X0, nebo P jako první commit vlny 0 hned po X0.

### X0-P2: balíčky do `src/client/calltype/pubspec.yaml`
| Balíček | Sekce | Constraint | Platformy | Proč |
| --- | --- | --- | --- | --- |
| `package_info_plus` | dependencies | `^10.2.1` (pub.dev 2026-07-15, Dart ≥ 3.10, Flutter ≥ 3.38.1) | android, ios, web, windows, macos, linux | verze v nastavení, `latest.json` porovnání |
| `msix` | dev_dependencies | `^3.18.0` (pub.dev, Dart ≥ 2.19) | jen build nástroj pro Windows | `dart run msix:create` |

`flutter_launcher_icons` už je (`pubspec.yaml:68`). Pro P10 **není** potřeba `http`. Použije se existující `dio` (`pubspec.yaml:27`).

### X0-P3: iOS entitlements a Info.plist
- Vytvořit `ios/Runner/Runner.entitlements`:
  ```xml
  <key>aps-environment</key><string>development</string>
  <!-- G: --> <key>com.apple.developer.associated-domains</key><array><string>applinks:jay.zcloud.cz</string></array>
  ```
  Export pro App Store přepíše `aps-environment` na `production` podle profilu. Obsah finalizují N/G/C, P jen vyžaduje, aby soubor existoval s tímto názvem.
- Wiring `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` v `project.pbxproj` (Debug/Release/Profile cíle Runner) udělá **P1** (pbxproj vlastní P).
- `Info.plist`: `CFBundleName` → `Jay` (R-P13). `ITSAppUsesNonExemptEncryption` **nepřidávat**, dokud vlastník nerozhodne R-P4 (pak přes koordinátora).

### X0-P4: macOS entitlements
- `macos/Runner/Release.entitlements`: ponechat sandbox, `network.client`, `device.camera`, `device.audio-input`, `files.user-selected.read-write`, `keychain-access-groups` (dnešní obsah). **Nepřidávat** `cs.allow-jit` do Release (Dart AOT ho nepotřebuje, hardened runtime by ho musel povolit).
- Pokud N chce push na macOS: `com.apple.developer.aps-environment` = `development`. Pak export Developer ID vyžaduje provisioning profil (řeší cloud signing, P6).

### X0-P5: AndroidManifest (bezpečnost, koordinace se S)
- `<application android:allowBackup="false" android:fullBackupContent="false" android:dataExtractionRules="@xml/data_extraction_rules">` + `res/xml/data_extraction_rules.xml` s vyloučením všeho (`<cloud-backup><exclude domain="root"/>…`).
- Proč: bez toho Android auto-backup kopíruje plaintext SQLite (zprávy a stav ratchetu, CLAUDE.md: „not SQLCipher yet“) do Google Drive. Přímo se to týká publikace přes Play.

### X0-P6: kontrakt Firebase konfigurace (stub, který vytvoří P3a ve vlně 0)
Soubor `lib/core/config/firebase_config.dart` (vlastní P). N ho v `push_service.dart:40` zavolá místo `Firebase.initializeApp()`:
```dart
/// Firebase client options come from --dart-define-from-file at build time
/// (see .github/scripts/firebase-config.sh). Public identifiers, never secrets,
/// but kept out of git so forks and dev builds cannot hit our project.
abstract final class FirebaseConfig {
  /// Pure mapping, unit-testable without dart-defines.
  static FirebaseOptions? fromDefines(Map<String, String> d,
      {required TargetPlatform platform, required bool isWeb});

  /// Options for the running platform, or null when this build has no config
  /// (dev, CI sanity, Windows, Linux). Callers treat null as PushStatus.notConfigured.
  static FirebaseOptions? get currentPlatform;

  /// Web push VAPID public key (FirebaseMessaging.getToken(vapidKey:)), or null.
  static String? get webVapidKey;

  static bool get isConfigured => currentPlatform != null;
}
```
Názvy dart-define klíčů (zmrazené). Hodnoty jsou prázdný řetězec = nenastaveno:

| Klíč | Použití |
| --- | --- |
| `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_STORAGE_BUCKET` | všechny platformy |
| `FIREBASE_WEB_API_KEY`, `FIREBASE_WEB_APP_ID`, `FIREBASE_WEB_AUTH_DOMAIN`, `FIREBASE_WEB_VAPID_KEY` | web |
| `FIREBASE_ANDROID_API_KEY`, `FIREBASE_ANDROID_APP_ID` | Android |
| `FIREBASE_APPLE_API_KEY`, `FIREBASE_IOS_APP_ID`, `FIREBASE_MACOS_APP_ID` (smí být = iOS app id), `FIREBASE_APPLE_BUNDLE_ID` (= `cz.zcloud.jay`) | iOS, macOS |

Web service worker (N) načte konfiguraci přes `importScripts('firebase-config.js')`. P commitne výchozí `web/firebase-config.js`:
```js
// Overwritten at release build time by .github/scripts/firebase-config.sh.
// null = this build has no Firebase project; the service worker must no-op.
self.JAY_FIREBASE_CONFIG = null;
```
Release build ho přepíše na `self.JAY_FIREBASE_CONFIG = {apiKey, authDomain, projectId, storageBucket, messagingSenderId, appId};` (klíče přesně jako Firebase JS SDK).

### X0-P7: další dart-define klíče (zmrazené)
| Klíč | Hodnoty | Kdo čte |
| --- | --- | --- |
| `API_BASE_URL` | beze změny (`lib/main.dart:46`) | app |
| `JAY_DISTRIBUTION` | `dev` (výchozí) \| `web` \| `play` \| `testflight` \| `direct` \| `msstore` | P10 (update check jen pro `direct`), případně N/C pro diagnostiku |
| `JAY_COMMIT_SHA` | plný SHA, výchozí `''` | `AppVersionLabel` (zkrácený v tooltipu), diagnostika |
| `JAY_UPDATE_FEED_URL` | HTTPS URL `latest.json`, výchozí `''` = kontrola vypnutá | P10 |

### X0-P8: prefix ARB klíčů
Prefix **`plat`**. Klíče (P10, ve vlně 2; ve vlně 1 žádné nové klíče):
- `platUpdateAvailable`: „Jay {version} is available.“ (placeholder `version: String`)
- `platUpdateDownload`: „Download“
- `platUpdateRequired`: „This version of Jay is no longer supported. Please update.“

`settingsVersion` (existuje, `app_en.arb:246`) se použije beze změny s hodnotou `"1.2.0 (142)"`.

### X0-P9: `ProductionConfigurationValidator`, EF, hub, drift
Nic.

---

## 5. Závislosti na jiných proudech

| Od koho | Co | Kontrakt / jak pracovat bez čekání |
| --- | --- | --- |
| **O / vlastník** V1 | potvrzení `cz.zcloud.jay` | P1 se dá napsat hned. Merge až po potvrzení. |
| **O / vlastník** V2 | billing nebo public okno | Workflowy se ověří `actionlint` lokálně. Hosted běh až v okně. |
| **O / vlastník** V3 | Firebase projekt + secrets (formát v oddílu 9) | P3 funguje s prázdnými defines (`notConfigured`). Test mapování přes fake JSON. |
| **O / vlastník** V4, V7 | Apple team, ASC API klíč, App ID s capabilities | P5/P6 hotové proti `APPLE_TEAM_ID` proměnné. Bez ní workflow selže v kroku „Refuse to build“ (existující vzor `ios-testflight.yml:58-78`). |
| **O / vlastník** V5 | Play Console, upload keystore, service account | P4 bez `PLAY_SERVICE_ACCOUNT_JSON` jen staví a podepisuje, nenahrává (`android: build`). |
| **O / vlastník** V6 | Artifact Signing nebo Partner Center | P7 umí `windows: store` (bez podpisu) i `windows: direct`. |
| **O** (nový požadavek, O7/infra) | veřejný Blob kontejner `downloads` + federovaná identita s rolí *Storage Blob Data Contributor* jen na tento kontejner + CORS `GET` z `https://jay.zcloud.cz` (pro `www/download.html`) | P10 publikuje přes `az storage blob upload --auth-mode login`. Bez proměnných `DOWNLOADS_*` se krok přeskočí. |
| **O** O6 | staging App Service + SWA, názvy proměnných | P11 (vlna 2) |
| **N** | `push_service.dart` volá `FirebaseConfig.currentPlatform`. `web/firebase-messaging-sw.js` dělá `importScripts('firebase-config.js')` a při `JAY_FIREBASE_CONFIG === null` nic neregistruje. Rozhodnutí R-P12. | Kontrakt X0-P6 |
| **C** | Kotlin nativní kód do `android/app/src/main/kotlin/cz/zcloud/jay/` (až po P1). Potřebné keep pravidla R8 pro plugin hovorů (např. `flutter_callkit_incoming`) nahlásí C a P je připíše do `proguard-rules.pro`. | P4 test release buildu musí zahrnout hovor |
| **G** | `www/.well-known/assetlinks.json` potřebuje SHA-256 **app signing** certifikátu z Play Console (App integrity), `apple-app-site-association` potřebuje `<TeamID>.cz.zcloud.jay`. P je předá v `docs/acceptance/android-play.md` / `ios-testflight.md`. Custom schéma pro Windows MSIX (`protocol_activation`) dodá G. P ho zapíše do `msix_config`. | hodnoty přijdou od vlastníka po V4/V5 |
| **S** | Souhlas s X0-P5 (allowBackup). | — |

---

## 6. Balíčky práce

Společné pro všechny balíčky:
- Každý nový YAML/skript má komentář **PROČ** (CLAUDE.md).
- Žádný krok nesmí vypsat secret (`set -x` zakázáno v krocích se secrets).
- Akce třetích stran pouze připnuté na plný SHA s komentářem verze.
- Lokální ověření workflowů: `actionlint` (binárka z GitHub releases, **[OVĚŘIT verzi]**) + `python -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))"`.
- Hosted běh jen v public okně se souhlasem vlastníka.
- Integrační testy s Testcontainers: **nerelevantní**, proud nemění server. Backend testy běží dál beze změny v `deploy.yml`/`ci.yml`.

### P1: Sjednocení identifikátorů + wiring entitlements (P0, S, **vlna 0**)
**Cíl:** jeden identifikátor `cz.zcloud.jay`, správné jméno firmy, iOS target odkazuje na entitlements, CI hlídá, že se to nerozjede.

**Soubory a kroky:**
1. `android/app/build.gradle.kts:9,24`: `namespace = "cz.zcloud.jay"`, `applicationId = "cz.zcloud.jay"`. Smazat TODO komentář (`:23`) a nahradit komentářem PROČ („must match iOS/macOS; immutable after first Play upload“).
2. `git mv android/app/src/main/kotlin/com/example/calltype/MainActivity.kt android/app/src/main/kotlin/cz/zcloud/jay/MainActivity.kt`, `package cz.zcloud.jay`. Prázdné adresáře `com/example` smazat. Manifest používá relativní `.MainActivity` (`AndroidManifest.xml:19`), takže bez změny.
3. `macos/Runner/Configs/AppInfo.xcconfig`:
   - `PRODUCT_NAME = Jay` (R-P13),
   - `PRODUCT_BUNDLE_IDENTIFIER = cz.zcloud.jay`,
   - `PRODUCT_COPYRIGHT = Copyright © 2026 ZCloud. All rights reserved.` (**[OVĚŘIT]** přesné obchodní jméno).
   - `macos/Runner.xcodeproj/project.pbxproj:388,402,416`: `RunnerTests` → `cz.zcloud.jay.RunnerTests`.
   - Ověřit, že nic nečte `calltype.app` (deploy tar bere celou složku `Release`, `deploy.yml:286`).
4. `windows/runner/Runner.rc:92,96`: `CompanyName` = `ZCloud`, `LegalCopyright` = `Copyright (C) 2026 ZCloud. All rights reserved.` `InternalName`/`OriginalFilename` zůstávají `calltype` (interní jméno).
5. `ios/Runner.xcodeproj/project.pbxproj`: do build konfigurací Debug/Release/Profile cíle Runner (bloky s `PRODUCT_BUNDLE_IDENTIFIER = cz.zcloud.jay`, `:362-380`, `:540-560`, `:562-580`) přidat `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;` a přidat soubor do skupiny Runner (PBXFileReference, **ne** do Copy Bundle Resources). Soubor vytváří X0-P3. Pokud P1 běží dřív než X0, vytvořit ho s obsahem z X0-P3.
6. `src/client/calltype/.gitignore`: připsat
   ```
   # Firebase client config is materialized from GitHub secrets at release time
   # (.github/scripts/firebase-config.sh) and never committed.
   /android/app/google-services.json
   /ios/Runner/GoogleService-Info.plist
   /macos/Runner/GoogleService-Info.plist
   /build-defines/
   ```
7. Nový `.github/scripts/check-app-ids.sh` (bash, `set -euo pipefail`). Ověří, že `cz.zcloud.jay` je v:
   - `android/app/build.gradle.kts` (namespace i applicationId),
   - `ios/…/project.pbxproj` (všechny ne-test `PRODUCT_BUNDLE_IDENTIFIER`),
   - `macos/Runner/Configs/AppInfo.xcconfig`,
   - `linux/CMakeLists.txt` (`APPLICATION_ID`, pokud složka existuje),
   - `pubspec.yaml` `msix_config.identity_name` (pokud existuje).

   A že `com.example` ani `com.calltype` se nevyskytuje nikde v `src/client/calltype/{android,ios,macos,windows,linux}`. Chybu vypíše s cestou.

**Testy:** `check-app-ids.sh` v CI (P9, job `platform-config`). Lokálně: `flutter build apk --debug` a `flutter build macos --debug` (na Macu), `flutter build windows` (na Windows). Mimo tyto stroje až v public okně přes `ci.yml` `dev-build`.

**Přijetí:**
- skript projde,
- `aapt dump badging app-release.apk | grep package` → `name='cz.zcloud.jay'`,
- `defaults read build/macos/Build/Products/Release/Jay.app/Contents/Info.plist CFBundleIdentifier` → `cz.zcloud.jay`,
- `dev-build` zelený pro všech 5 platforem.

**Paralelně:** nic (vlna 0, jeden commit).

### P2: Jednotné verzování + verze v nastavení (P0, S, vlna 1)
**Cíl:** Jedno `BUILD_NAME` a jedno monotónní `BUILD_NUMBER` pro všechny platformy a workflowy. Uživatel vidí v nastavení skutečnou verzi.

**Politika:**
- `BUILD_NAME` = `major.minor.patch` z `pubspec.yaml` `version:` (část před `+`). Zvyšuje se ručně commitem před vydáním (P připíše do `docs/acceptance/release-builds.md`).
- `BUILD_NUMBER` = `git rev-list --count <commit_sha>` (počet předků commitu).
  - Proč: deterministický pro SHA, stejný v `deploy.yml` i `release-native.yml` (na rozdíl od `github.run_number`, který má každý workflow vlastní, `ios-testflight.yml:101`) a monotónní podél `master`.
  - Vyžaduje `actions/checkout` s `fetch-depth: 0`.
  - Release se smí stavět jen z commitu, který je předkem `origin/master` (jinak by větev mohla mít menší číslo). Kontroluje se v `version.sh`.
- Limity:
  - Android `versionCode` ≤ 2 100 000 000,
  - Windows `FILEVERSION` a MSIX: každá část ≤ 65 535, MSIX pro Store vyžaduje revizi 0,
  - iOS `CFBundleVersion` celé číslo.
  - `BUILD_NUMBER` ≤ 65 535 → skript jinak selže (při dnešním tempu commitů to na desítky let nehrozí).
- `MSIX_VERSION` = `major.minor.BUILD_NUMBER.0`. Monotónní, protože `BUILD_NUMBER` roste vždy.
- Nové nahrání téhož SHA do Play/ASC selže (stejné číslo). To je záměr, protože stejné bajty se nenahrávají dvakrát. Pro nutný re-upload má `release-native.yml` vstup `build_number_offset` (výchozí 0), který se přičte a zapíše do manifestu.

**Soubory a kroky:**
1. `.github/scripts/version.sh <commit_sha> [offset]` vypíše do `$GITHUB_OUTPUT` (a na stdout při lokálním běhu) `build_name`, `build_number`, `msix_version`, `commit_sha`. Kroky:
   - `git merge-base --is-ancestor "$SHA" origin/master` (jinak `::error::` a exit 1),
   - parsování `version:` z `git show "$SHA:src/client/calltype/pubspec.yaml"` (regex `^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+`),
   - kontroly limitů.
2. `.github/scripts/test-version.sh`: bash test nad dočasným git repem (`git init` v `mktemp -d`, 3 commity, ověří čísla a odmítnutí ne-master SHA a špatného `version:`).
3. `pubspec.yaml:4`: ponechat `1.0.0+1`. Číslo za `+` je jen pro lokální buildy a komentář to vysvětlí (připsat komentář nad řádek: „+N is ignored by CI; build numbers come from .github/scripts/version.sh“).
4. Všechny `flutter build` v `deploy.yml`, `release-native.yml` a `_release-*.yml` dostanou `--build-name=… --build-number=… --dart-define=JAY_COMMIT_SHA=… --dart-define=JAY_DISTRIBUTION=…`. Build manifest (`deploy.yml:313-322` vzor) dostane pole `"buildName"`, `"buildNumber"`, `"distribution"`.
5. `lib/shared/widgets/app_version_label.dart`:
   ```dart
   /// Shows "Jay 1.2.0 (142) beta" from the real bundle metadata. Replaces the
   /// hard-coded '1.0.0' (settings_screen.dart:105-111), which lied on every
   /// build after the first.
   class AppVersionLabel extends StatelessWidget {
     const AppVersionLabel({super.key, this.loader = PackageInfo.fromPlatform});
     final Future<PackageInfo> Function() loader;
     // FutureBuilder: while loading / on error renders settingsVersion('') is
     // wrong — render nothing (SizedBox.shrink) instead; on data renders
     // l10n.settingsVersion('${info.version} (${info.buildNumber})'),
     // Tooltip with the 7-char JAY_COMMIT_SHA when non-empty.
   }
   ```
   Na webu `package_info_plus` čte `version.json`, který generuje `flutter build web`. Proto se `--build-name/--build-number` musí předat i webovému buildu v `deploy.yml`.
6. `lib/features/settings/settings_screen.dart:105-118`: nahradit `Text(l10n.settingsVersion('1.0.0'), …)` za `const AppVersionLabel()` (styl `bodySmall`/`onSurfaceVariant` se přesune do widgetu). Smazat zastaralý komentář `:106-107`.

**Testy:**
- `test/shared/widgets/app_version_label_test.dart`: `PackageInfo.setMockInitialValues(appName: 'Jay', packageName: 'cz.zcloud.jay', version: '1.2.0', buildNumber: '142', buildSignature: '')`, pump přes `localizedApp(home: Scaffold(body: AppVersionLabel()))` → `find.text(l10nEn.settingsVersion('1.2.0 (142)'))`.
- Druhý test s `loader` vracejícím `Future.error` → žádný text, žádná výjimka.
- `test/l10n/locale_screens_test.dart` musí dál projít (cs/de/ar).
- `.github/scripts/test-version.sh` v CI.

**Přijetí:**
- nastavení na webu z `deploy.yml` ukazuje `Jay <build_name> (<commit count>) beta`,
- manifesty všech platforem nesou stejné `buildNumber` pro stejný SHA,
- `no_hardcoded_strings_test` zelený.

**Paralelně:** s P3, P4, P5.

### P3: Firebase konfigurace do buildu (P0, M; **P3a stub ve vlně 0**, P3b ve vlně 1)
**Cíl:** Release buildy mají Firebase konfiguraci ze secrets. Dev a CI sanity buildy ji nemají a fungují dál (`notConfigured`). Nic Firebase se necommituje.

**P3a (vlna 0, S):**
- `lib/core/config/firebase_config.dart` přesně podle X0-P6. `currentPlatform` volá `fromDefines` s mapou z `const String.fromEnvironment(...)` pro každý klíč. Mapování:
  - web → `FIREBASE_WEB_*`,
  - android → `FIREBASE_ANDROID_*`,
  - iOS → `FIREBASE_APPLE_API_KEY` + `FIREBASE_IOS_APP_ID` + `iosBundleId`,
  - macOS → totéž s `FIREBASE_MACOS_APP_ID` (fallback na iOS app id),
  - windows/linux/fuchsia → `null`.

  Chybí-li kterýkoli povinný klíč dané platformy (`apiKey`, `appId`, `messagingSenderId`, `projectId`), vrátí `null`. Neúplná konfigurace se nesmí tvářit jako platná.
- `web/firebase-config.js` s `null` (X0-P6).
- Test `test/core/config/firebase_config_test.dart`:
  - `fromDefines({}, …)` → null pro všechny platformy,
  - kompletní fake mapa → správné `FirebaseOptions` pro web/android/ios/macos,
  - macOS bez `FIREBASE_MACOS_APP_ID` → iOS app id,
  - windows/linux → null,
  - chybějící `appId` → null.

**P3b (vlna 1, M):**
1. `.github/scripts/firebase-config.sh <platform>` (bash, `set -euo pipefail`, žádné `set -x`). Vstup z env:
   - `FIREBASE_CLIENT_CONFIG_JSON_B64` (base64 plochého JSON s klíči z X0-P6),
   - `FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64`,
   - volitelně `FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64`.

   Výstupy:
   - vždy `src/client/calltype/build-defines/firebase.json`. Když secret chybí, `{}` a `::warning::Firebase not configured for <platform> — push will report notConfigured`.
   - `web`: přepíše `web/firebase-config.js` z JSON (přes `jq`, klíče `apiKey/authDomain/projectId/storageBucket/messagingSenderId/appId`).
   - `android`: `android/app/google-services.json`.
   - `ios`/`macos`: `ios/Runner/GoogleService-Info.plist` resp. `macos/…`, jen když je secret nastaven (R-P12).
   - Validace: `jq -e .FIREBASE_PROJECT_ID` a u google-services `jq -e '.client[] | select(.client_info.android_client_info.package_name=="cz.zcloud.jay")'`. Jiný package name = chyba (chrání před nahráním configu jiné aplikace).
2. Build příkazy dostanou `--dart-define-from-file=build-defines/firebase.json` (Flutter ≥ 3.7 podporuje JSON soubor).
3. `android/settings.gradle.kts` `plugins {}`: `id("com.google.gms.google-services") version "4.4.2" apply false` **[OVĚŘIT aktuální verzi pluginu]**.
   `android/app/build.gradle.kts` po bloku `plugins`:
   ```kotlin
   // google-services.json is materialized from a GitHub secret only in release
   // workflows; dev and CI sanity builds have none and must still compile.
   if (file("google-services.json").exists()) {
       apply(plugin = "com.google.gms.google-services")
   }
   ```
   Proč i na Androidu soubor, když Dart options stačí na inicializaci: FCM služba spuštěná v ukončeném procesu potřebuje výchozí `FirebaseApp` z nativních resources (jinak hrozí „Default FirebaseApp is not initialized“) **[OVĚŘIT na zařízení ve scénáři R-05]**.
4. iOS/macOS `GoogleService-Info.plist`: jen pokud R-P12 = FCM a N potvrdí, že Dart options nestačí **[OVĚŘIT]**. Pak do `ios/Runner.xcodeproj` přidat Run Script build phase „Copy optional GoogleService-Info.plist“: `[ -f "$SRCROOT/Runner/GoogleService-Info.plist" ] && cp … "$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app/"`. Soubor nesmí být v Copy Bundle Resources, protože chybějící soubor by rozbil dev build.
5. `docs/acceptance/release-builds.md`: oddíl „Firebase / push configuration (K04)“ přepsat na nový mechanismus + formát secretů (oddíl 9).

**Testy:**
- P3a unit test,
- `firebase-config.sh` test: `.github/scripts/test-firebase-config.sh` s fake base64 vstupy (včetně špatného package name → exit ≠ 0) v CI jobu `platform-config`.

**Přijetí:**
- dev build → `PushStatus.notConfigured` (beze změny chování),
- release web build obsahuje `firebase-config.js` s `projectId` (ověřit `curl https://jay.zcloud.cz/firebase-config.js` po deployi, se souhlasem),
- `git status` po lokálním běhu skriptu je čistý (soubory ignorované).

**Paralelně:** P3b s P2, P4, P5.

### P4: Android release — podpis, R8, AAB, Play (P0, M, vlna 1)
**Cíl:** Podepsaný AAB (upload key), R8 bez rozbití WebRTC, automatické nahrání do Play interního testování.

**Soubory a kroky:**
1. `android/app/build.gradle.kts`:
   ```kotlin
   import java.util.Properties
   // Upload key: CI passes env vars (JAY_ANDROID_KEYSTORE_PATH, _STORE_PASSWORD,
   // _KEY_ALIAS, _KEY_PASSWORD); locally a git-ignored android/key.properties
   // with storeFile/storePassword/keyAlias/keyPassword works the same way.
   val keyProps = Properties().apply {
       val f = rootProject.file("key.properties"); if (f.exists()) f.inputStream().use { load(it) }
   }
   fun signingValue(prop: String, env: String): String? = System.getenv(env) ?: keyProps.getProperty(prop)
   val uploadStoreFile = signingValue("storeFile", "JAY_ANDROID_KEYSTORE_PATH")
   ```
   - `signingConfigs { if (uploadStoreFile != null) create("upload") { storeFile = file(uploadStoreFile); storePassword = …; keyAlias = …; keyPassword = … } }`.
   - `buildTypes.release`:
     - `signingConfig` = `upload`, pokud existuje.
     - Jinak, když `System.getenv("JAY_REQUIRE_RELEASE_SIGNING") == "true"`, `throw GradleException("Release signing required but no upload key configured")`. Tím se zabrání tomu, aby release workflow tiše vydal debug-podepsaný AAB.
     - Jinak `debug` (lokální `flutter run --release`, `ci.yml` sanity) s `logger.warn`.
   - `isMinifyEnabled = true`, `isShrinkResources = true`, `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")`. Komentář PROČ: explicitně, protože default Flutter Gradle pluginu se mezi verzemi měnil **[OVĚŘIT, že Flutter 3.41 nepřebije]**.
2. `android/app/proguard-rules.pro`:
   ```
   # flutter_webrtc: JNI + reflection into org.webrtc; stripping it breaks calls at runtime only.
   -keep class org.webrtc.** { *; }
   # Flutter deferred components reference Play Core; we do not use them.
   -dontwarn com.google.android.play.core.**
   ```
   Pravidla C (plugin hovorů) a N (`flutter_local_notifications` potřebuje keep pro Gson typy **[OVĚŘIT README pluginu]**) se připíšou.
3. `targetSdk`: ponechat `flutter.targetSdkVersion`. Přijetí kontroluje, že odpovídá aktuálnímu požadavku Play pro nové aplikace **[OVĚŘIT požadavek Play k 2026-09 — API 35/36]**. Když ne, nastavit explicitně s komentářem.
4. `.github/workflows/_release-android.yml` (`on: workflow_call`, vstupy `commit_sha`, `build_name`, `build_number`, `play_track` (`none|internal`), `play_status` (`draft|completed`, výchozí `draft`)). Job `android`, `runs-on: ubuntu-latest`, `environment: android-release`, `timeout-minutes: 45`. Kroky:
   1. checkout `ref: commit_sha`,
   2. setup-java 17, flutter-action (pin jako dnes `deploy.yml:268`),
   3. codegen core + app,
   4. `firebase-config.sh android`,
   5. dekódovat `ANDROID_UPLOAD_KEYSTORE_B64` do `$RUNNER_TEMP/upload.jks` (`trap` smaže), export `JAY_ANDROID_*` + `JAY_REQUIRE_RELEASE_SIGNING=true`,
   6. `flutter build appbundle --release --build-name … --build-number … --split-debug-info=build/symbols/android --dart-define=API_BASE_URL=${{ vars.CALLTYPE_API_BASE_URL }} --dart-define=JAY_DISTRIBUTION=play --dart-define=JAY_COMMIT_SHA=… --dart-define-from-file=build-defines/firebase.json`,
   7. **ověření podpisu:** `keytool -printcert -jarfile build/app/outputs/bundle/release/app-release.aab` → SHA-256 musí být rovno proměnné `vars.ANDROID_UPLOAD_CERT_SHA256` (není secret). Jinak fail. Tím se debug klíč nikdy nedostane do Play.
   8. manifest (vzor `deploy.yml:296-322` + `buildName/buildNumber/distribution/signingCertSha256`),
   9. upload artefaktu `calltype-release-android-<sha>` (AAB, `mapping.txt`, symboly, manifest),
   10. `if: inputs.play_track != 'none'`: `r0adkll/upload-google-play@<SHA v1.1.5>` s `serviceAccountJsonPlainText: ${{ secrets.PLAY_SERVICE_ACCOUNT_JSON }}`, `packageName: cz.zcloud.jay`, `releaseFiles: …/app-release.aab`, `track: internal`, `status: ${{ inputs.play_status }}`, `mappingFile: build/app/outputs/mapping/release/mapping.txt`.

   Komentář PROČ `draft`: dokud aplikace v Play neprošla první revizí, API přijme jen `status: draft` **[OVĚŘIT]**.
5. `docs/acceptance/android-play.md` (nový, česky), obsah:
   - jednorázové kroky vlastníka (oddíl 9),
   - vygenerování upload klíče:
     ```
     keytool -genkeypair -v -keystore jay-upload.jks -keyalg RSA -keysize 4096 -validity 10000 -alias jay-upload
     ```
     heslo do správce hesel, soubor nikdy do gitu,
   - **první AAB se nahrává ručně** v Play Console (API neumí první release nové aplikace) **[OVĚŘIT]**, vezme se z artefaktu běhu s `play_track: none`,
   - zápis SHA-256 app signing certifikátu (Play Console → Test and release → App integrity) pro G,
   - Data safety formulář, URL zásad ochrany soukromí, obsahové hodnocení.

**Testy:**
- lokálně bez klíče: `flutter build appbundle --release` projde s varováním (debug podpis),
- s `JAY_REQUIRE_RELEASE_SIGNING=true` bez klíče selže (ruční test, zapsat do `android-play.md`),
- s testovacím keystorem (`keytool` v `$RUNNER_TEMP`) `ci.yml` job `android-signing-smoke` (P9) ověří, že `keytool -printcert` ukazuje testovací certifikát. Testovací keystore se generuje v jobu a nikdy se necommituje.
- R8 smoke: release APK z `ci.yml` na emulátoru není v CI. Pokrývá přejímka R-01 (hovor v release buildu).

**Přijetí:**
- běh `release-native.yml` s `android: build` vyrobí AAB s upload certifikátem a `versionCode` = commit count,
- s `android: internal` je build v Play Console → Internal testing,
- hovor mezi release buildem a webem funguje (R-02).

**Paralelně:** s P2, P3b, P5.

### P5: iOS — podepsaný archiv, TestFlight, export compliance (P0, M, vlna 1)
**Cíl:** Spolehlivý TestFlight upload se správnými entitlements. První upload provede vlastník.

**Proč změnit dnešní postup:** `flutter build ipa --no-codesign` + export s cloud signing (`ios-testflight.yml:98-130`) staví archiv **bez podpisu**, a tedy bez vložených entitlements. Export pak podepíše aplikaci. Není ale jisté, že doplní `aps-environment` a `associated-domains` **[OVĚŘIT]**. Bez nich push i universal links tiše nefungují. Bezpečnější je podepsat už archiv, protože automatický podpis přes API klíč umí i archive.

**Soubory a kroky:**
1. `.github/workflows/_release-ios.yml` (`workflow_call`, vstupy `commit_sha`, `build_name`, `build_number`, `upload` (bool)). `runs-on: macos-latest`, `environment: apple-testflight`. Kroky:
   1. kontrola secrets (převzít `ios-testflight.yml:58-78`),
   2. flutter + codegen, `firebase-config.sh ios`,
   3. `flutter build ios --release --config-only --build-name … --build-number … --dart-define=… --dart-define-from-file=build-defines/firebase.json`. Zapíše `Generated.xcconfig` s defines a čísly.
   4. `(cd ios && pod install)` **[OVĚŘIT, zda to `--config-only` dělá samo]**,
   5. dekódovat `.p8` do `$RUNNER_TEMP` (vzor `:110-119`),
   6. `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release -destination 'generic/platform=iOS' -archivePath build/ios/archive/Runner.xcarchive archive -allowProvisioningUpdates -authenticationKeyPath … -authenticationKeyID … -authenticationKeyIssuerID … DEVELOPMENT_TEAM=${{ vars.APPLE_TEAM_ID }} CODE_SIGN_STYLE=Automatic`,
   7. **kontrola entitlements:** `codesign -d --entitlements :- build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app > ent.plist` a `plutil -extract aps-environment raw ent.plist`. Chybí-li → `::error::` a konec.
   8. export: `sed` do `ExportOptions.plist` (existující `ios/ci/ExportOptions.plist`). Když `upload == false`, pak `destination=export` a IPA jde do artefaktu. Jinak `upload` jako dnes.
   9. manifest (+ `buildName`, `buildNumber`, `distribution: testflight`), artefakt se symboly (`build/ios/archive/Runner.xcarchive/dSYMs`).
2. `DEVELOPMENT_TEAM` se **necommituje** do pbxproj. Předává se jako build setting z proměnné `APPLE_TEAM_ID`, aby šel stejný projekt stavět i bez týmu (`ci.yml` `--no-codesign`).
   Pro lokální vývoj v Xcode: volitelný, git-ignorovaný `ios/Flutter/Signing.xcconfig` s `DEVELOPMENT_TEAM = …` a `#include? "Signing.xcconfig"` na konci `ios/Flutter/Debug.xcconfig` a `Release.xcconfig` (**[OVĚŘIT]**, že `#include?` u Flutter xcconfig nekoliduje s Pods include, který přidává `pod install`).
3. Smazat `.github/workflows/ios-testflight.yml`, nahrazuje ho `release-native.yml` se vstupem `ios: testflight`. `docs/acceptance/ios-testflight.md` přepsat:
   - nový příkaz: `gh workflow run release-native.yml -f commit_sha=<sha> -f ios=testflight`,
   - build number = commit count,
   - capabilities App ID: Push Notifications + Associated Domains,
   - ASC klíč role **App Manager** stačí pro iOS, pro P6 viz níže,
   - export compliance podle R-P4.
4. Export compliance: zapsat do `ios-testflight.md` přesné odpovědi dotazníku podle R-P4 a to, že klíč v Info.plist přidá X0/koordinátor až po rozhodnutí.

**Testy:**
- `actionlint`,
- `ci.yml` `dev-build` `ios-unsigned` zůstává (kompilace bez týmu),
- první hosted běh s `upload: false` (IPA do artefaktu, žádný upload), pak `upload: true`.

**Přijetí:**
- build v TestFlight,
- `codesign -d --entitlements` u exportované IPA ukazuje `aps-environment = production` a `com.apple.developer.associated-domains`,
- `CFBundleVersion` = commit count,
- instalace přes TestFlight na fyzický iPhone (R-01, R-02).

**Paralelně:** s P2–P4.

### P6: macOS — Developer ID, notarizace, dmg (P2, M, vlna 2)
**Cíl:** `Jay-<ver>-<build>.dmg`, který Gatekeeper otevře bez varování.

**Kroky:**
1. `macos/Runner.xcodeproj/project.pbxproj` (Release a Profile cíle Runner): `ENABLE_HARDENED_RUNTIME = YES;`. Notarizace ho vyžaduje. Oprávnění pro kameru a mikrofon pokrývají stávající klíče `com.apple.security.device.camera`/`audio-input`.
2. `macos/ci/ExportOptions-developer-id.plist`: `method = developer-id`, `signingStyle = automatic`, `teamID = __TEAM_ID__`, `destination = export`.
3. `.github/workflows/_release-macos.yml` (`workflow_call`, `environment: apple-testflight`, `macos-latest`):
   1. `flutter build macos --release --config-only …` **[OVĚŘIT, že `--config-only` existuje pro macOS ve Flutter 3.41; jinak `flutter build macos` a pak re-archive]**,
   2. `xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release archive -archivePath build/macos/Runner.xcarchive -allowProvisioningUpdates <API key args> DEVELOPMENT_TEAM=…`,
   3. `xcodebuild -exportArchive … -exportOptionsPlist …developer-id… -allowProvisioningUpdates <API key args>` → `build/macos/export/Jay.app`,
   4. `ditto -c -k --keepParent Jay.app Jay.zip` a `xcrun notarytool submit Jay.zip --key … --key-id … --issuer … --wait`, pak `xcrun stapler staple Jay.app`,
   5. dmg: `mkdir dmg && cp -R Jay.app dmg/ && ln -s /Applications dmg/Applications && hdiutil create -volname Jay -srcfolder dmg -ov -format UDZO Jay-$BUILD_NAME-$BUILD_NUMBER.dmg` (vestavěné nástroje, žádný `create-dmg`),
   6. `notarytool submit` dmg + `stapler staple` dmg,
   7. ověření: `spctl -a -vv -t exec Jay.app` → `source=Notarized Developer ID` a `spctl -a -vv -t open --context context:primary-signature Jay-….dmg`,
   8. manifest, artefakt.
4. **Riziko a fallback:**
   - Cloud-managed *Developer ID Application* certifikát smí vytvořit jen API klíč s rolí **Admin** (nebo Account Holder) **[OVĚŘIT]**. Pokud to nejde, fallback: klasický `.p12` (secrets `MACOS_DEVELOPER_ID_P12_B64`, `MACOS_DEVELOPER_ID_P12_PASSWORD`) importovaný do dočasné keychain (`security create-keychain`, `import`, `set-key-partition-list`) + Developer ID provisioning profil (`MACOS_PROVISIONING_PROFILE_B64`). Profil je nutný kvůli `keychain-access-groups`, které na macOS vyžaduje profil **[OVĚŘIT]**.
   - S lokální identitou pak jde podepsat i dmg (`codesign --sign "Developer ID Application: …" --timestamp`).
5. `docs/acceptance/desktop-release.md` (nový): postup pro macOS + Windows + Linux, ověřovací příkazy, známé meze.

**Testy:** `actionlint`, hosted běh s `macos: true`, ruční ověření na čistém Macu (R-01, R-07).

**Přijetí:**
- `spctl` hlásí Notarized Developer ID,
- po stažení z prohlížeče (quarantine) se aplikace otevře bez dialogu „nelze ověřit vývojáře“,
- identita přežije restart (keychain funguje).

### P7: Windows — MSIX + podpis / Store (P2, M, vlna 2)
**Cíl:** Instalovatelný MSIX s kamerou a mikrofonem, podepsaný důvěryhodným certifikátem (přímá distribuce), nebo připravený pro Store.

**Kroky:**
1. `pubspec.yaml`, blok `msix_config:` (výjimka P):
   ```yaml
   # MSIX packaging (dart run msix:create). Version, publisher and identity are
   # overridden from CI (.github/workflows/_release-windows.yml) so the Store
   # and the direct-download package can differ without editing this file.
   msix_config:
     display_name: Jay
     publisher_display_name: ZCloud        # [OVĚŘIT] legal name
     identity_name: cz.zcloud.jay          # direct channel; Store uses the Partner Center identity
     logo_path: assets/brand/jay-icon.png
     capabilities: internetClient,internetClientServer,privateNetworkClientServer,microphone,webcam
     languages: en-us,cs-cz,sk-sk,de-de,fr-fr,es-es,it-it,pt-pt,pl-pl,nl-nl,uk-ua,ro-ro,hu-hu,zh-cn,hi-in,ar-sa,ru-ru,ja-jp,tr-tr
     build_windows: false
     sign_msix: false
     install_certificate: false
   ```
   - Proč `webcam`/`microphone`: zabalená full-trust aplikace bez nich nedostane přístup a nezobrazí se v nastavení soukromí Windows **[OVĚŘIT na zařízení]**.
   - Protokol pro deep link dodá G (`protocol_activation`).
2. `windows/packaging/Jay.appinstaller.tmpl`: XML App Installer s `Uri` na `latest` MSIX v kontejneru `downloads`, `<UpdateSettings><OnLaunch HoursBetweenUpdateChecks="12"/><AutomaticBackgroundTask/></UpdateSettings>`, placeholdery `__VERSION__`, `__PUBLISHER__`, `__MSIX_URL__`, `__APPINSTALLER_URL__`.
3. `.github/workflows/_release-windows.yml` (`workflow_call`, vstup `channel`: `direct|store`, `windows-latest`):
   1. `flutter build windows --release --build-name … --build-number … --dart-define=JAY_DISTRIBUTION=${{ channel == 'store' && 'msstore' || 'direct' }} …`,
   2. `dart run msix:create --version $MSIX_VERSION --publisher "$PUBLISHER" --identity-name "$IDENTITY" [--store]` **[OVĚŘIT názvy CLI přepínačů msix 3.18]**,
   3. `direct`:
      - `environment: windows-signing`, `azure/login` (OIDC, jiná app registration než deploy, federovaná jen na env `windows-signing`),
      - `Azure/artifact-signing-action@<SHA>` **[OVĚŘIT verzi a názvy vstupů: endpoint, signing-account-name, certificate-profile-name, files-folder, files-folder-filter: msix, file-digest: SHA256, timestamp-rfc3161: http://timestamp.acs.microsoft.com, timestamp-digest: SHA256]**,
      - pak `signtool verify /pa /v Jay.msix`.
      - `MSIX_PUBLISHER` (proměnná) musí **přesně** odpovídat subjektu certifikátu z Artifact Signing, jinak instalace selže.
   4. `store`: `vars.MSSTORE_IDENTITY_NAME`, `vars.MSSTORE_PUBLISHER`, `vars.MSSTORE_PUBLISHER_DISPLAY_NAME` (z Partner Center → Product identity), nepodepisovat. Upload do Partner Center **ručně** (automatizace `msstore` CLI je P2+).
   5. Artefakt: MSIX, `Jay.appinstaller` (jen `direct`), manifest. Zip Release složky zůstává jako ladicí artefakt.

**Testy:** `actionlint`, `ci.yml` dev-build Windows přidá `dart run msix:create --sign-msix false` (ověří, že konfigurace balí).

**Přijetí:**
- na čistém Windows 11 se MSIX z `downloads` nainstaluje bez varování SmartScreen o neznámém vydavateli,
- hovor s kamerou funguje,
- instalace vyššího buildu přes `.appinstaller` zachová identitu (R-01, R-03).

### P8: Linux — runner a AppImage (P2, M, vlna 2)
**Kroky:**
1. V `src/client/calltype`: `flutter create --platforms=linux --org cz.zcloud --project-name calltype .`. Commitnout jen `linux/**`. Změny v `.metadata` zkontrolovat, jiné vygenerované soubory vrátit.
2. `linux/CMakeLists.txt`: `set(APPLICATION_ID "cz.zcloud.jay")`, `BINARY_NAME` zůstává `calltype`. `linux/runner/my_application.cc`: titulek okna `"Jay"` (oba výskyty, header bar i `gtk_window_set_title`).
3. `linux/packaging/jay.desktop`:
   ```
   Name=Jay
   Exec=calltype %u
   Icon=cz.zcloud.jay
   Categories=Network;InstantMessaging;
   StartupWMClass=calltype
   ```
   Plus `MimeType=x-scheme-handler/calltype;` podle G. Ikona `linux/packaging/cz.zcloud.jay.png` (256×256), commitnutá, vyrobená z `assets/brand/jay-icon.png`. `flutter_launcher_icons` Linux neumí (`pubspec.yaml:83-101`).
4. `.github/workflows/_release-linux.yml`:
   - `runs-on: ubuntu-22.04`. Proč: AppImage poběží jen na systémech s glibc ≥ té z build stroje, takže se staví na nejstarším podporovaném.
   - apt: `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev libjsoncpp-dev` **[OVĚŘIT úplnost pro flutter_webrtc/flutter_secure_storage Linux]**,
   - `flutter build linux --release …`,
   - AppDir (`AppRun` → `usr/bin/calltype`, bundle do `usr/bin`, desktop + ikona do kořene AppDir),
   - `appimagetool` stažený z připnutého release s ověřením SHA-256 **[OVĚŘIT verzi a hash]**,
   - `Jay-$BUILD_NAME-$BUILD_NUMBER-x86_64.AppImage` + `tar.gz` bundle, manifest.
5. `ci.yml` `dev-build`: nový řádek `linux` (ubuntu-22.04, apt deps, `flutter build linux --release`).
6. Známé meze do `desktop-release.md`:
   - bez push (`push_service.dart:126`) a bez QR skeneru (`router.dart:150-156`),
   - biometrie nedostupná, jen PIN (`app_lock.dart:92-101`),
   - `flutter_secure_storage` potřebuje běžící Secret Service (GNOME Keyring/KWallet),
   - AppImage potřebuje `libfuse2`,
   - podpora `flutter_webrtc` na Linuxu **[OVĚŘIT]**. Když hovory nejdou, UI to musí říct (požadavek na C, ne tichá chyba).

**Přijetí:**
- AppImage se spustí na Ubuntu 22.04 a 24.04 a na Fedoře,
- identita přežije restart,
- chat funguje (R-01, R-07).

### P9: CI a release orchestrace (P0, M, vlna 1, **začít první ve vlně 1**)
**Cíl:** Jeden ruční vstup pro nativní vydání, sdílené testy, podpisové secrets oddělené po environmentech, kontrola konfigurace platforem v CI.

**Soubory a kroky:**
1. `.github/workflows/_client-tests.yml` (`on: workflow_call`, vstup `commit_sha`): přesun kroků Flutter z `deploy.yml:104-116` (core codegen+analyze+test, app codegen+analyze+test). `deploy.yml` job `test` dál spouští backend testy a Flutter část volá přes `uses:`. Nebo zůstane inline, pokud reusable uvnitř jobu nejde, pak jako samostatný job `client-tests`.
2. `.github/workflows/release-native.yml` (`workflow_dispatch`), vstupy:
   - `commit_sha` (string, povinný),
   - `android` (choice `skip|build|internal`),
   - `ios` (choice `skip|build|testflight`),
   - `macos` (bool),
   - `windows` (choice `skip|direct|store`),
   - `linux` (bool),
   - `publish_downloads` (bool),
   - `build_number_offset` (number, 0).

   Joby:
   - `version` (ubuntu, `fetch-depth: 0`, `version.sh`, výstupy),
   - `client-tests` (`uses: ./.github/workflows/_client-tests.yml`),
   - `android` / `ios` / `macos` / `windows` / `linux` (`if:` podle vstupu, `needs: [version, client-tests]`, `uses: ./.github/workflows/_release-<p>.yml`, `secrets: inherit`),
   - `publish-downloads` (P10).

   `concurrency: release-native`, `cancel-in-progress: false` (souběžné uploady se stejným build number by se praly). Nahoře komentář se seznamem environmentů a secrets (vzor `deploy.yml:15-34`).
   Platformní reusable soubory vytvoří P9 jako **stuby** (`run: echo "::error::not implemented yet (P4..P8)"; exit 1`), aby dispečer byl validní. P4–P8 je nahradí.
3. `deploy.yml`:
   - `build-clients` matrix zúžit na `web`. Nativní legy odchází do `release-native.yml` (proč: podpis a obchody potřebují vlastní environment a macOS minuty nemají běžet při každém deployi webu).
   - Webový build dostane `--build-name/--build-number` (z `version.sh`, nový job `version`), `JAY_DISTRIBUTION=web`, `JAY_COMMIT_SHA` a `firebase-config.sh web`.
   - Hlavička: seznam secrets doplnit o `FIREBASE_CLIENT_CONFIG_JSON_B64`.
   - `docs/acceptance/matrix.md` pozn. ⁶ (Q01-13 manifest) odkáže na manifesty z `release-native.yml`.
4. `ci.yml`:
   - nový job `platform-config` (ubuntu, rychlý): `check-app-ids.sh`, `test-version.sh`, `test-firebase-config.sh`, `actionlint` nad `.github/workflows/*.yml` (připnutá binárka + SHA-256),
   - `dev-build`: `android` staví `flutter build appbundle --release` (ověří AAB cestu, debug podpis) + APK zůstává, přidat `linux` (po P8),
   - nový job `android-signing-smoke` (ubuntu):
     - vygeneruje testovací keystore (`keytool -genkeypair … -dname "CN=CI Smoke"` s náhodným heslem),
     - postaví `flutter build appbundle --release` s `JAY_REQUIRE_RELEASE_SIGNING=true`,
     - ověří certifikát `keytool -printcert -jarfile` (`CN=CI Smoke`),
     - chrání gradle logiku podpisu bez skutečných secrets.
   - `paths` filtru přidat `.github/scripts/**` a nové workflowy.
5. Bezpečnost workflowů (komentář v každém release souboru):
   - jen `workflow_dispatch`/`workflow_call`,
   - `permissions: contents: read` (+ `id-token: write` jen u jobů s OIDC),
   - žádné `pull_request_target`,
   - environmenty s povinným schválením vlastníkem,
   - `persist-credentials: false` u checkoutu v release jobech.
6. `docs/acceptance/release-builds.md`: přepsat oddíly „Deploy“, „Required repository configuration“ a „Verification status“ podle nového uspořádání. Úplná tabulka secrets a proměnných (oddíl 9). Postup public okna pro vydání:
   1. souhlas vlastníka,
   2. repo → public,
   3. `gh workflow run deploy.yml …` / `release-native.yml …`,
   4. schválit environmenty,
   5. po doběhnutí repo → private,
   6. zapsat run id do `docs/acceptance/`.

**Testy:** `actionlint` + YAML parse lokálně, `platform-config` job, první hosted běh `release-native.yml` se vším `skip`/`false` kromě `android: build` (nejlevnější).

**Přijetí:**
- `release-native.yml` s `android: build` projde a vyrobí AAB s manifestem,
- `deploy.yml` nasadí web s verzí v nastavení,
- `ci.yml` `platform-config` odhalí úmyslně rozbitý identifikátor (ověřit na lokální větvi, necommitovat).

**Paralelně:** krok 2 (stuby) první, pak P4/P5 plní své soubory nezávisle.

### P10: Distribuce desktopu mimo obchod a kontrola aktualizací (P2, M, vlna 2)
**Cíl:** Stabilní URL ke stažení a informace v aplikaci, že je nová verze. Bez auto-update frameworku.

**Kontrakt `latest.json`** (v kořeni kontejneru `downloads`, `Cache-Control: no-cache`):
```json
{
  "schema": 1,
  "channel": "beta",
  "buildName": "1.1.0",
  "buildNumber": 142,
  "commitSha": "<40 hex>",
  "publishedAt": "2026-10-01T12:00:00Z",
  "minSupportedBuild": 0,
  "platforms": {
    "windows": { "url": "https://…/windows/Jay-1.1.0-142.msix", "appInstallerUrl": "https://…/windows/Jay.appinstaller", "sha256": "<hex>", "sizeBytes": 0 },
    "macos":   { "url": "https://…/macos/Jay-1.1.0-142.dmg", "sha256": "<hex>", "sizeBytes": 0 },
    "linux":   { "url": "https://…/linux/Jay-1.1.0-142-x86_64.AppImage", "sha256": "<hex>", "sizeBytes": 0 }
  }
}
```
`minSupportedBuild` > vlastní build → blokující hláška `platUpdateRequired` (pro budoucí nekompatibilní změnu protokolu). Výchozí `0`.

**Kroky:**
1. Job `publish-downloads` v `release-native.yml` (`environment: downloads`, OIDC):
   - stáhne artefakty z jobů `macos/windows/linux` tohoto běhu,
   - `az storage blob upload --auth-mode login --account-name ${{ vars.DOWNLOADS_STORAGE_ACCOUNT }} -c ${{ vars.DOWNLOADS_CONTAINER }}` do `<platform>/`,
   - vygeneruje `Jay.appinstaller` a `latest.json`. Nahraje je **až po** binárkách, aby feed nikdy neukazoval na neexistující soubor.
   - Přeskočí platformy, které se v běhu nestavěly (ponechá jejich poslední záznam: nejdřív stáhne aktuální `latest.json`).
2. `lib/core/update/update_feed.dart`:
   - `class UpdateFeed { final int buildNumber; final String buildName; final int minSupportedBuild; final Map<String, UpdateAsset> platforms; static UpdateFeed parse(Map<String, dynamic> json); }` (odmítne `schema != 1`),
   - `UpdateStatus evaluate({required int currentBuild, required String platformKey})` → `upToDate | available | required`.
3. `lib/core/update/update_checker.dart`:
   - `class UpdateChecker extends ChangeNotifier { UpdateChecker({required Dio dio, required String feedUrl, required Future<PackageInfo> Function() packageInfo}); Future<void> check(); UpdateStatus get status; UpdateAsset? get asset; }`,
   - aktivní jen když `JAY_DISTRIBUTION == 'direct'` a `JAY_UPDATE_FEED_URL` není prázdné, jinak `check()` nic nedělá.
   - Požadavek bez identifikátorů zařízení a bez cookies (soukromí: server se dozví jen IP a User-Agent). Kontrola při startu a jednou za 24 h, chyby tiše ignoruje.
4. `lib/shared/widgets/update_banner.dart`: `MaterialBanner` s `platUpdateAvailable(version)` a tlačítkem `platUpdateDownload`, které otevře URL. Pro `required` nezavíratelná verze s `platUpdateRequired`.
   - Otevření URL: X0 nepřidává `url_launcher`. Použít existující `share_plus`? Ne, nevhodné. **Požadavek na X0 ve vlně 2:** `url_launcher` **[OVĚŘIT verzi]**. Alternativa: zkopírovat odkaz do schránky přes `Clipboard.setData` (bez nové závislosti). Rozhodne koordinátor.
   - Umístění banneru: `lib/main.dart` (připsat provider) + router shell. Koordinátor.
5. ARB: 3 klíče `plat*` ve všech 19 jazycích (X0-P8).
6. `www/download.html`: statická stránka ve stylu `www/styles.css`, načte `latest.json` (`fetch`, CORS z O) a vypíše odkazy + SHA-256. Bez JS zobrazí odkaz na `latest.json`. `www/verify.mjs` se nemění.

**Testy:**
- `test/core/update/update_feed_test.dart` (parse, špatné schema, `evaluate` pro všechny tři stavy, chybějící platforma → `upToDate`),
- `test/core/update/update_checker_test.dart` (Dio s fake `HttpClientAdapter`, `distribution != direct` → žádný request),
- `test/shared/widgets/update_banner_test.dart` přes `localizedApp` v en/cs/ar,
- l10n guardy.

**Přijetí:** direct build s nižším buildem než feed ukáže banner, store/play/web build nikdy nevolá feed (R-06).

### P11: `deploy.yml` přes staging (P2, S, vlna 2, závisí na O6)
Podle kontraktu O6:
- nový job `deploy-staging` (environment `calltype-staging`, proměnné `STAGING_WEBAPP_NAME`, `STAGING_SWA_*`) + `smoke-staging`,
- produkční `deploy-api`/`deploy-web` s `needs: smoke-staging` a environmentem `calltype-beta` s povinným schválením.

Přijetí: produkce nejde nasadit bez zeleného stagingu téhož SHA.

### Pořadí a paralelismus uvnitř proudu
- Vlna 0: P1, P3a.
- Vlna 1: P9 (stuby dispečera jako první commit), pak paralelně P2, P3b, P4, P5.
- Vlna 2: P6, P7, P8, P10 paralelně. P11 až po O6.

| ID | Název | Velikost | Vlna | Priorita |
| --- | --- | --- | --- | --- |
| P1 | Identifikátory + wiring entitlements + check | S | 0 | P0 |
| P2 | Verzování + verze v nastavení | S | 1 | P0 |
| P3 | Firebase config (a: stub, b: CI) | M | 0 / 1 | P0 |
| P4 | Android podpis, R8, AAB, Play | M | 1 | P0 |
| P5 | iOS podepsaný archiv, TestFlight, compliance | M | 1 | P0 |
| P6 | macOS Developer ID, notarizace, dmg | M | 2 | P2 |
| P7 | Windows MSIX + podpis / Store | M | 2 | P2 |
| P8 | Linux runner + AppImage | M | 2 | P2 |
| P9 | CI a release orchestrace | M | 1 | P0 |
| P10 | Desktop downloads + kontrola aktualizací | M | 2 | P2 |
| P11 | Deploy přes staging | S | 2 | P2 |

---

## 7. Přejímka na zařízení (řádky pro `docs/acceptance/matrix.md`)

Všechny scénáře jsou NOT_RUN, dokud je neprovede člověk na fyzickém zařízení. Ke každému: datum UTC, zařízení/OS, build (`buildName (buildNumber)`, SHA), výsledek, důkaz.

| Scénář | Android | iOS | macOS | Windows | Linux | Web |
| --- | --- | --- | --- | --- | --- | --- |
| R-01 instalace z obchodu/stažení na čisté zařízení, první spuštění, identifikátor `cz.zcloud.jay` | Play interní test | TestFlight | dmg: Gatekeeper bez dialogu, `spctl` Notarized | MSIX: bez varování SmartScreen, vydavatel ZCloud | AppImage na Ubuntu 22.04/24.04 + Fedora | — |
| R-02 hovor audio+video v **release** buildu (R8/hardened runtime nerozbily WebRTC, oprávnění kamera/mikrofon) | ✓ | ✓ | ✓ | ✓ | ✓ (pokud WebRTC podporuje) | — |
| R-03 aktualizace buildu N → N+1 zachová identitu a historii | Play | TestFlight | přepsání `Jay.app` | `.appinstaller` auto-update | nový AppImage | reload |
| R-04 verze v Nastavení = `buildName (buildNumber)` z manifestu | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| R-05 Firebase: release build hlásí jiný stav než `notConfigured` (push samotný testuje N) | ✓ | ✓ | ✓ (pokud N zapne) | UNSUPPORTED | UNSUPPORTED | ✓ |
| R-06 banner aktualizace z `latest.json` (jen direct) | — | — | ✓ | ✓ | ✓ | — |
| R-07 identita po restartu OS (keychain / secure storage / libsecret) | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| R-08 Android: zapnutá Google záloha neobsahuje DB aplikace (`adb shell bmgr backupnow cz.zcloud.jay` → nic k záloze), po X0-P5 | ✓ | — | — | — | — | — |

---

## 8. Rizika a otevřené otázky

1. **Entitlements v nepodepsaném archivu iOS.** Dnešní postup je může ztratit (P5 to řeší podepsaným archivem a kontrolou `codesign`). Hlavní riziko prvního TestFlight buildu.
2. **Cloud signing pro Developer ID** možná vyžaduje API klíč s rolí Admin. Fallback `.p12` + profil (P6) znamená víc secrets.
3. **R8 odstraní třídy pluginů,** které se volají přes reflexi/JNI (WebRTC, plugin hovorů C, notifikace N). Chyba se projeví až za běhu. Proto R-02 v release buildu a keep pravidla od C/N.
4. **Build number = počet commitů:**
   - vyžaduje `fetch-depth: 0` a release jen z předků `master`,
   - přepsání historie `master` (force push) by čísla snížilo, takže `master` musí být chráněný proti force push,
   - lokální klon je dnes shallow, takže lokální `version.sh` hlásí nepravdivé číslo, dokud se nespustí `git fetch --unshallow`.
5. **Změna identifikátoru** = nová aplikace. Případné dosavadní instalace (Android APK z artefaktů, macOS tar.gz) přijdou o lokální identitu a zprávy. Oznámit testerům.
6. **Play:**
   - D-U-N-S pro účet organizace může trvat týdny,
   - první AAB ručně,
   - `draft` status do první revize,
   - Data safety a zásady soukromí jsou povinné,
   - cílové API podle aktuálních pravidel **[OVĚŘIT]**.
7. **Public okno:**
   - logy a artefakty jsou po dobu okna veřejné,
   - akce třetích stran mají přístup k secrets jobu → jen SHA-pinned a jen v jobech, které je potřebují,
   - base64 secrets jsou maskované, dekódované hodnoty se nikdy nevypisují.
   - **[OVĚŘIT]** environment secrets/schvalovatelé na privátním repu bez placeného plánu.
8. **Firebase na Androidu bez `google-services.json`** v ukončeném procesu. Řešeno souborem ze secretu, ověří N na zařízení.
9. **Store vs. přímé MSIX** mají různou identitu. Uživatelé si mohou nainstalovat obě varianty a mít dvě identity Jay. Doporučit jeden kanál na uživatele.
10. **Artifact Signing** pro ZCloud: způsobilost organizace, validace identity (dny), měsíční poplatek. Když neprojde, jen Store.
11. **Linux:** zralost `flutter_webrtc`, závislost na Secret Service a FUSE. AppImage z ubuntu-22.04 nepoběží na starších distribucích.
12. **Export compliance** je právní otázka (R-P4). Plán dává jen technické možnosti a Apple citace. Odpovědi ve formulářích dává vlastník účtu.
13. **SWA a `firebase-config.js`:** service worker se může cachovat. N musí v SW počítat s `null` a nový build musí invalidovat SW (verze v názvu nebo `self.skipWaiting` řeší N).
14. **Hot soubory:** P mění `settings_screen.dart` jen v sekci About. Pokud D ve vlně 2 přestaví nastavení, koordinátor ohlídá, že `AppVersionLabel` zůstane.

---

## 9. Účty a secrets pro vlastníka (přesně, v tomto pořadí)

Konvence: binární nebo víceřádkové hodnoty jako **base64** (`_B64`), aby je GitHub spolehlivě maskoval. Nic z toho se nikdy necommituje. Originály (keystore, `.p8`, `.p12`) patří do správce hesel.

| # | Krok (vlastník) | GitHub: kde | Název | Typ |
| --- | --- | --- | --- | --- |
| 1 | Potvrdit `cz.zcloud.jay` (R-P1) a GitHub billing / režim public okna (R-P2) | — | — | rozhodnutí |
| 2 | Android upload klíč: `keytool -genkeypair -v -keystore jay-upload.jks -keyalg RSA -keysize 4096 -validity 10000 -alias jay-upload` | env `android-release` | `ANDROID_UPLOAD_KEYSTORE_B64`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS` (`jay-upload`), `ANDROID_UPLOAD_KEY_PASSWORD` | secrets |
| 2b | SHA-256 upload certifikátu (`keytool -list -v -keystore jay-upload.jks`) | env `android-release` | `ANDROID_UPLOAD_CERT_SHA256` (hex bez dvojteček, velká písmena) | variable |
| 3 | Firebase projekt (V3): aplikace Android `cz.zcloud.jay`, Apple `cz.zcloud.jay`, Web. Web Push certifikát (VAPID). Service account JSON → App Service `Push__FcmServiceAccountJson` (O/N, ne GitHub) | repo | `FIREBASE_CLIENT_CONFIG_JSON_B64` (plochý JSON s klíči z X0-P6), `FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64`, volitelně `FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64` (R-P12) | secrets |
| 4 | Apple Developer Program (V4): Team ID. App ID `cz.zcloud.jay` s Push Notifications + Associated Domains. App v App Store Connect (SKU `jay-ios`). API klíč **Admin** (kvůli Developer ID v P6, pro samotný iOS stačí App Manager) | env `apple-testflight` (existuje) | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (název zachován kvůli kontinuitě) | secrets |
| 4b | | env `apple-testflight` | `APPLE_TEAM_ID` | variable |
| 5 | Export compliance (R-P4): odpovědi v ASC u prvního buildu. Případně francouzská deklarace → kód | — (později Info.plist přes X0) | `ITSEncryptionExportComplianceCode` | Info.plist |
| 6 | Google Play Console (V5, organizace + D-U-N-S): vytvořit aplikaci `cz.zcloud.jay`, zapnout Play App Signing, **ručně** nahrát první AAB (artefakt `release-native` s `android: build`) do Internal testing, testeři | — | — | ruční |
| 6b | Google Cloud service account → Play Console → Users and permissions → pozvat s oprávněním „Release to testing tracks“ pro Jay. Stáhnout JSON klíč | env `android-release` | `PLAY_SERVICE_ACCOUNT_JSON` (plain JSON, akce ho očekává jako text) | secret |
| 6c | SHA-256 **app signing** certifikátu z Play Console → App integrity → předat G (`assetlinks.json`) | — | — | předání |
| 7 | macOS (V7): nic nového, pokud cloud signing Developer ID projde (P6). Jinak Developer ID Application `.p12` + Developer ID provisioning profil | env `apple-testflight` | `MACOS_DEVELOPER_ID_P12_B64`, `MACOS_DEVELOPER_ID_P12_PASSWORD`, `MACOS_PROVISIONING_PROFILE_B64` | secrets (jen fallback) |
| 8a | Windows přímé MSIX (R-P8, V6): Azure Artifact Signing účet + validace identity organizace + certificate profile (Public Trust). App registration s federovaným credentialem pro env `windows-signing` a rolí *Artifact Signing Certificate Profile Signer* **[OVĚŘIT název role]** | env `windows-signing` | secrets `AZURE_SIGNING_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`; variables `ARTIFACT_SIGNING_ENDPOINT`, `ARTIFACT_SIGNING_ACCOUNT`, `ARTIFACT_SIGNING_PROFILE`, `MSIX_PUBLISHER` (přesný subjekt certifikátu `CN=…, O=…, L=…, C=CZ`) | mix |
| 8b | Windows Store (alternativa/doplněk): účet v Partner Center, rezervace jména „Jay“, Product identity | env `windows-signing` nebo repo | `MSSTORE_IDENTITY_NAME`, `MSSTORE_PUBLISHER`, `MSSTORE_PUBLISHER_DISPLAY_NAME` | variables |
| 9 | Downloads (R-P11, zakládá O): veřejný kontejner, identita s *Storage Blob Data Contributor* na kontejner, federace na env `downloads` | env `downloads` | secrets `AZURE_DOWNLOADS_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`; variables `DOWNLOADS_STORAGE_ACCOUNT`, `DOWNLOADS_CONTAINER`, `DOWNLOADS_BASE_URL` | mix |
| 10 | Environmenty `android-release`, `apple-testflight`, `windows-signing`, `downloads`: *Required reviewers* = vlastník, *Deployment branches* = jen `master` | — | — | nastavení |

Existující a beze změny: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_SWA_DEPLOYMENT_TOKEN` (env `calltype-beta`), proměnné `AZURE_RESOURCE_GROUP`, `AZURE_WEBAPP_NAME`, `CALLTYPE_API_BASE_URL`, `CALLTYPE_SWA_URL` (`docs/acceptance/release-builds.md`).
