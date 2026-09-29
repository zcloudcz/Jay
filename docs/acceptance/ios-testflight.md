# iOS TestFlight — postup (P5, dřív R01 / G3)

Stav: workflow a projekt připravené (bundle ID `cz.zcloud.jay`, min. iOS 15, `Runner.entitlements` s `aps-environment` a `applinks:jay.zcloud.cz`, ikona Jay bez alfa kanálu, purpose strings). **První upload: NOT_RUN** — čeká na kroky vlastníka Apple účtu níže a na public okno.

`ios-testflight.yml` byl nahrazen dispečerem `release-native.yml` → `_release-ios.yml`. Plán: `docs/superpowers/plans/2026-09-29-gap-platform.md` (P5, R-P4, oddíl 9).

## Co se změnilo proti dřívějšímu postupu

- **Archiv se podepisuje** (`xcodebuild archive` s automatickým podpisem přes App Store Connect API klíč, tým z proměnné `APPLE_TEAM_ID`). Dřív se stavěl `flutter build ipa --no-codesign` a podepisoval až export. Nepodepsaný archiv nenese entitlements a není jisté, že je export doplní — push a universal links by pak na zařízení tiše nefungovaly.
- Workflow po archivaci **zkontroluje entitlements** podepsané aplikace (`codesign -d --entitlements`): chybí-li `aps-environment` nebo `com.apple.developer.associated-domains`, skončí chybou.
- **Build number = počet commitů** do SHA (`.github/scripts/version.sh`), stejné jako Android a web. `CFBundleShortVersionString` = verze z `pubspec.yaml`. Stejný SHA podruhé App Store Connect odmítne; nutný re-upload: `-f build_number_offset=1`.
- `DEVELOPMENT_TEAM` se **necommituje** (hlídá `check-app-ids.sh`). CI ho předává na příkazové řádce. Pro podpis v Xcode na vlastním Macu: git-ignorovaný `ios/Flutter/Signing.xcconfig` s řádkem `DEVELOPMENT_TEAM = <Team ID>` (načítá se přes `#include?` v `Debug.xcconfig`/`Release.xcconfig`).
- Bez secrets (public okno bez environmentu, forky) workflow postaví **nepodepsanou** aplikaci (`…-unsigned`, jen důkaz kompilace). S `ios=testflight` bez secrets skončí chybou.
- Dart symboly (`build/symbols/ios`) a dSYMs jsou v artefaktu `calltype-release-ios-<sha>`.

## Jednorázově (vlastník Apple Developer účtu)

1. **Identifier:** developer.apple.com → Certificates, IDs & Profiles → Identifiers → `+` → App IDs → App → Bundle ID *Explicit* `cz.zcloud.jay`, popis „Jay“. Capabilities: **Push Notifications** a **Associated Domains** (bez nich automatický podpis nevytvoří profil s entitlements a kontrola v workflow selže).
2. **Aplikace:** appstoreconnect.apple.com → Apps → `+` New App → iOS, název „Jay“ (případně „Jay Messenger“, je-li obsazeno), bundle ID `cz.zcloud.jay`, SKU `jay-ios`.
3. **API klíč:** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → `+`. Pro iOS stačí role **App Manager**; pro macOS Developer ID (P6, vlna 2) bude možná potřeba **Admin** [OVĚŘIT]. Stáhnout `AuthKey_XXXXXXXXXX.p8` (jde jen jednou), opsat **Key ID** a **Issuer ID**.
4. **Team ID:** developer.apple.com → Membership details → Team ID (10 znaků).
5. **GitHub** (`zcloudcz/Jay` → Settings → Environments → `apple-testflight`, prostředí už existuje; *Required reviewers* = vlastník, *Deployment branches* = jen `master`):
   - secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (base64 obsahu `.p8`)
     PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXXXXXXXX.p8")) | gh secret set ASC_KEY_P8_BASE64 -R zcloudcz/Jay --env apple-testflight`
   - variable `APPLE_TEAM_ID`
   Soubor `.p8` poté uložit mimo repozitář (správce hesel); do Gitu nikdy.
6. **Firebase** (repo-level, V3): `FIREBASE_CLIENT_CONFIG_JSON_B64` (klíče `FIREBASE_APPLE_API_KEY`, `FIREBASE_IOS_APP_ID`, `FIREBASE_APPLE_BUNDLE_ID=cz.zcloud.jay` …), volitelně `FIREBASE_APPLE_GOOGLE_SERVICE_INFO_PLIST_B64` (rozhodne N, R-P12). Bez nich push hlásí `notConfigured`.
7. **Pro G:** `apple-app-site-association` potřebuje `<TeamID>.cz.zcloud.jay` — Team ID předat proudu G.

## Každé vydání

První běh bez uploadu (IPA jen do artefaktu, ověří podpis a entitlements):
```bash
gh workflow run release-native.yml -R zcloudcz/Jay -f commit_sha=<plný SHA na master> -f ios=build
```
Pak upload:
```bash
gh workflow run release-native.yml -R zcloudcz/Jay -f commit_sha=<plný SHA na master> -f ios=testflight
```

Jen v public okně se souhlasem vlastníka. Po ~5–15 min zpracování: App Store Connect → TestFlight → u buildu odpovědět na **Export Compliance** (níže) a přidat ho do skupiny testerů (interní testeři = členové týmu, bez review; externí = první build prochází Beta App Review).

## Export compliance (R-P4, čeká na rozhodnutí vlastníka)

Jay sám implementuje standardní algoritmy (X25519, Ed25519, HKDF, AES-256-GCM v pure Dart, `calltype_core/lib/crypto`), nepoužívá jen šifrování OS. `ITSAppUsesNonExemptEncryption` proto záměrně **není** v `Info.plist`; App Store Connect se ptá u každého buildu.

Doporučené odpovědi v dotazníku (právní prohlášení vlastníka účtu, ne technická rada):

| Otázka App Store Connect | Odpověď |
| --- | --- |
| Používá aplikace šifrování? | **Ano** |
| Používá proprietární / nestandardní algoritmy? | **Ne** (jen standardní: X25519, Ed25519, AES-GCM, HKDF, SHA-2) |
| Používá standardní algoritmy místo šifrování v iOS/macOS, nebo navíc k němu? | **Ano** |
| Bude aplikace dostupná ve Francii? | **Ne**, dokud není podána francouzská deklarace (ANSSI) [OVĚŘIT s právníkem] |

Po podání francouzské deklarace a získání kódu: přes koordinátora/X0 přidat do `Info.plist` `ITSAppUsesNonExemptEncryption = YES` a `ITSEncryptionExportComplianceCode = <kód>`. US strana: mass-market podle EAR 740.17(b)(1); zda je potřeba roční self-classification report pro BIS, potvrdí právník [OVĚŘIT]. Google Play a Microsoft Store se ptají podobně — odpovídat konzistentně.

## Ověření

| Kontrola | Stav | Poznámka |
| --- | --- | --- |
| `actionlint` + shellcheck `_release-ios.yml` | PASS (lokálně 2026-09-29, actionlint 1.7.9) | |
| `--config-only` spustí `pod install` a zapíše `SPLIT_DEBUG_INFO` | PASS (čtení zdrojů Flutter 3.41 tool, `ios/mac.dart`, `build_info.dart`) | hosted běh nepotvrdil |
| `ci.yml` `dev-build` `ios-unsigned` (kompilace bez týmu) | NOT_RUN | macOS runner jen v public okně |
| Podepsaný archiv s `aps-environment` + `associated-domains` | NOT_RUN | první hosted běh `ios=build` |
| Build v TestFlight, `CFBundleVersion` = commit count | NOT_RUN | `ios=testflight` |
| Instalace přes TestFlight na fyzický iPhone | NOT_RUN | `matrix.md` R-01, R-02 |

## Known limits

- **Push:** kód push pro iOS (APNs/FCM) je proud N. Entitlement `aps-environment` už v projektu je; export pro App Store ho přepíše na `production` podle profilu.
- **Náklady CI:** macOS runner. V public okně zdarma [OVĚŘIT aktuální ceník]; na private repu by vyžadoval placený plán.
- **Cloud signing** vyžaduje roli App Manager/Admin u API klíče a Xcode ≥ 13 na runneru (macos-latest splňuje).
