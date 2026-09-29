# Android — Google Play (P4)

Stav: podpis, R8 a workflow připravené (`.github/workflows/_release-android.yml`, volá ho `release-native.yml`). **Hosted běh ani upload: NOT_RUN** — čeká na kroky vlastníka níže a na public okno. Plán: `docs/superpowers/plans/2026-09-29-gap-platform.md` (P4, R-P3/R-P5/R-P6, oddíl 9).

Identifikátor: `cz.zcloud.jay` (namespace i `applicationId`). Po prvním nahrání do Play ho nejde změnit.

## Jak podepisování funguje

- AAB se podepisuje **upload klíčem**. Pro zařízení ho znovu podepíše Google (Play App Signing), takže testeři i uživatelé dostávají build podepsaný app signing klíčem z Play Console.
- Gradle (`android/app/build.gradle.kts`) bere klíč z env proměnných `JAY_ANDROID_KEYSTORE_PATH`, `JAY_ANDROID_KEYSTORE_PASSWORD`, `JAY_ANDROID_KEY_ALIAS`, `JAY_ANDROID_KEY_PASSWORD`. Lokálně stejně funguje git-ignorovaný `android/key.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). Env má přednost.
- Bez klíče je release build **debug-podepsaný** (lokální `flutter run --release`, `ci.yml`). Gradle vypíše varování.
- S `JAY_REQUIRE_RELEASE_SIGNING=true` (nastavuje release workflow) build bez klíče **selže**. Release tedy nikdy tiše nevydá debug-podepsaný AAB.
- Workflow po buildu porovná SHA-256 certifikátu v AAB (`keytool -printcert -jarfile`) s proměnnou `ANDROID_UPLOAD_CERT_SHA256`. Nesouhlasí-li, skončí chybou dřív, než by cokoli šlo do Play.
- Bez secretu `ANDROID_UPLOAD_KEYSTORE_B64` (public okno bez nastaveného environmentu, forky) workflow nespadne, ale postaví debug-podepsaný AAB s artefaktem `…-unsigned` a manifestem `"signed": false`. Upload do Play pak odmítne.
- R8 a zmenšení zdrojů jsou zapnuté explicitně. Keep pravidla: `android/app/proguard-rules.pro` (WebRTC, `flutter_callkit_incoming`) a `android/app/src/main/res/raw/keep.xml` (`ic_stat_jay`, zvuky hovorů v `res/raw`). Dart se **neobfuskuje** (R-P7), symboly jdou do artefaktu (`build/symbols/android`) spolu s `mapping.txt`.
- `targetSdk` = výchozí hodnota Flutteru 3.41 = **36** (ověřeno ve `FlutterExtension.kt`). Od 2025-08 Play vyžadoval pro nové aplikace API 35, 36 to splňuje. Aktuální požadavek k datu uploadu [OVĚŘIT v Play Console]; když bude vyšší, nastavit `targetSdk` v `build.gradle.kts` explicitně s komentářem.

## Jednorázově (vlastník)

1. **Upload klíč** (jednou, nikdy do gitu, originál + hesla do správce hesel):
   ```
   keytool -genkeypair -v -keystore jay-upload.jks -keyalg RSA -keysize 4096 -validity 10000 -alias jay-upload
   keytool -list -v -keystore jay-upload.jks -alias jay-upload   # řádek SHA256:
   ```
2. **GitHub** → Settings → Environments → **`android-release`** (nový): *Required reviewers* = vlastník, *Deployment branches* = jen `master`.
   - secrets `ANDROID_UPLOAD_KEYSTORE_B64` (base64 souboru `.jks`), `ANDROID_UPLOAD_KEYSTORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS` (`jay-upload`), `ANDROID_UPLOAD_KEY_PASSWORD`
   - variable `ANDROID_UPLOAD_CERT_SHA256` (hex z `keytool -list -v`; dvojtečky workflow odstraní)
   - PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("jay-upload.jks")) | gh secret set ANDROID_UPLOAD_KEYSTORE_B64 -R zcloudcz/Jay --env android-release`
3. **Firebase** (V3, repo-level secrets): `FIREBASE_CLIENT_CONFIG_JSON_B64`, `FIREBASE_ANDROID_GOOGLE_SERVICES_JSON_B64` (formát v `release-builds.md`). Bez nich build projde, push hlásí `notConfigured`.
4. **Google Play Console** (R-P6: účet organizace ZCloud, D-U-N-S): vytvořit aplikaci, balíček `cz.zcloud.jay`, zapnout **Play App Signing** (výchozí).
5. **První AAB ručně.** Publishing API neumí první release nové aplikace [OVĚŘIT]:
   ```
   gh workflow run release-native.yml -R zcloudcz/Jay -f commit_sha=<plný SHA na master> -f android=build
   ```
   Z artefaktu `calltype-release-android-<sha>` vzít `app-release.aab` → Play Console → Test and release → Internal testing → Create release → nahrát. Přidat testery (e-mailový seznam).
6. **Service account pro upload**: Google Cloud → service account → JSON klíč. Play Console → Users and permissions → pozvat e-mail service accountu, oprávnění „Release to testing tracks“ jen pro Jay. JSON (celý, jako text, ne base64) do secretu `PLAY_SERVICE_ACCOUNT_JSON` v `android-release`.
7. **App integrity**: Play Console → Test and release → App integrity → SHA-256 **app signing** certifikátu → předat proudu G do `www/.well-known/assetlinks.json` (App Links `jay.zcloud.cz/c/`, `/ch/`, `/g/`). Upload certifikát tam nepatří, zařízení vidí app signing certifikát.
8. **Povinné formuláře Play**: Data safety (šifrované zprávy na serveru jen dočasně, žádné kontakty, volitelný e-mail u registrace), URL zásad ochrany soukromí, obsahové hodnocení, cílová skupina. Otázka na šifrování konzistentně s iOS (R-P4).

## Každé vydání

```
gh workflow run release-native.yml -R zcloudcz/Jay -f commit_sha=<plný SHA na master> -f android=internal
```

- Jen v public okně se souhlasem vlastníka (CLAUDE.md, Deploy). Environment `android-release` čeká na schválení.
- `versionCode` = počet commitů do SHA (`.github/scripts/version.sh`), `versionName` = verze z `pubspec.yaml`. Stejný SHA podruhé Play odmítne (stejné číslo). Nutný re-upload: `-f build_number_offset=1`.
- Status vydání je `draft`, dokud aplikace neprojde první revizí [OVĚŘIT]. Pak v `_release-android.yml` přepnout výchozí `play_status` na `completed`.

## Ověření (NOT_RUN do prvního hosted běhu)

| Kontrola | Stav | Jak |
| --- | --- | --- |
| Logika podpisu v Gradle bez skutečných secrets | NOT_RUN | `ci.yml` job `android-signing-smoke`: bez klíče s `JAY_REQUIRE_RELEASE_SIGNING=true` musí selhat, s dočasným keystorem musí být AAB podepsaný `CN=CI Smoke` |
| Parsování `keytool -printcert` | PASS (lokálně 2026-09-29) | JAR podepsaný dočasným klíčem, SHA-256 z `-printcert -jarfile` = SHA-256 z `keytool -list -v` |
| `flutter build appbundle --release` (R8, keep pravidla) | NOT_RUN | v tomto prostředí není Android SDK; `ci.yml` `dev-build` android staví APK i AAB |
| Lokálně bez klíče → debug podpis + varování | NOT_RUN | `flutter build appbundle --release` na stroji s Android SDK |
| Release AAB s upload certifikátem, `versionCode` = commit count | NOT_RUN | `release-native.yml` `android=build`, manifest `signingCertSha256` a `buildNumber` |
| Upload do Internal testing | NOT_RUN | `android=internal` po ručním prvním AAB |
| Hovor v release buildu (R8 nerozbil WebRTC) | NOT_RUN | `matrix.md` R-02 |
| Záloha Androidu neobsahuje DB | NOT_RUN | `matrix.md` R-08 |

## Otevřená otázka: oprávnění z manifest mergeru

`app_badge_plus` 1.3.5 a `flutter_callkit_incoming` 3.1.6 si přes manifest merger přinesou oprávnění, která `AndroidManifest.xml` (vlastní X0) neuvádí:

- `app_badge_plus`: odznaky launcherů Samsung/HTC/Sony/Huawei/Honor/Vivo/… (`com.sec.android.provider.badge.permission.*`, `com.huawei.android.launcher.permission.*` atd.) — neškodná, ale v Play je uvidí jen jako seznam.
- `flutter_callkit_incoming`: `DISABLE_KEYGUARD`, `TURN_SCREEN_ON`, `ACCESS_NOTIFICATION_POLICY`, `${applicationId}.PERMISSION_CALL`.

Plán P4 o `tools:node="remove"` nerozhoduje a manifest nevlastní P, proto **nic neodebíráno**. Otázka pro vlastníka + C/N: odebrat `ACCESS_NOTIFICATION_POLICY` (přístup k režimu Nerušit — Play ho může chtít zdůvodnit) a `DISABLE_KEYGUARD` (C má zobrazit hovor přes `showWhenLocked` aktivity, ne odemykat)? Odebrání by znamenalo `xmlns:tools` a `<uses-permission … tools:node="remove"/>` v manifestu (X0/C). Ověřit na zařízení, že vyzvánění na zamčeném telefonu funguje i bez nich.
