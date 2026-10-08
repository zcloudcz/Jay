# iOS TestFlight — postup (R01 / G3)

Stav: workflow a projekt připraveny (bundle ID `cz.zcloud.jay`, min. iOS 14, ikona Jay bez alfa kanálu, purpose strings pro kameru, mikrofon, Face ID a knihovnu fotek). **Jednorázové kroky vlastníka HOTOVO 2026-10-08** (přes Chrome): App ID `cz.zcloud.jay` s capability Push Notifications, ASC aplikace **„Jay Messenger“** (název „Jay“ je v App Store obsazený; iOS + macOS, SKU `jay`, ASC id 6820712543), Team Key „Jay CI“ (App Manager, Key ID `6KCGY8AF8B`), Team ID `DZR3FD9ZNT`; v GitHub env `apple-testflight` nastaveny `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` a `APPLE_TEAM_ID`. `.p8` leží v `Downloads` vlastníka — přesunout do správce hesel. **První upload: NOT_RUN** — čeká na public okno.

## Jednorázově (vlastník Apple Developer účtu)

1. **Identifier:** developer.apple.com → Certificates, IDs & Profiles → Identifiers → `+` → App IDs → App → Bundle ID *Explicit* `cz.zcloud.jay`, popis „Jay“. Capabilities zatím žádné (Push Notifications přidat, až bude Firebase/APNs).
2. **Aplikace:** appstoreconnect.apple.com → Apps → `+` New App → iOS, název „Jay“ (případně „Jay Messenger“, je-li obsazeno), jazyk, bundle ID `cz.zcloud.jay`, SKU `jay-ios`.
3. **API klíč:** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → `+`, role **App Manager** (cloud signing nižší roli nepovolí). Stáhnout `AuthKey_XXXXXXXXXX.p8` (jde jen jednou), opsat **Key ID** a **Issuer ID**.
4. **Team ID:** developer.apple.com → Membership details → Team ID (10 znaků).
5. **GitHub** (`zcloudcz/Jay` → Settings → Environments → `apple-testflight`, prostředí už existuje):
   - secret `ASC_KEY_ID`, secret `ASC_ISSUER_ID`
   - secret `ASC_KEY_P8_BASE64` = base64 obsahu `.p8`
     PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXXXXXXXX.p8")) | gh secret set ASC_KEY_P8_BASE64 -R zcloudcz/Jay --env apple-testflight`
   - variable `APPLE_TEAM_ID`
   Soubor `.p8` poté uložit mimo repozitář (správce hesel); do Gitu nikdy.

## Každé vydání

```bash
gh workflow run ios-testflight.yml -R zcloudcz/Jay -f commit_sha=<plný SHA, který prošel deploy.yml>
```

Build number = číslo běhu workflow (roste samo). Po ~5–15 min zpracování: App Store Connect → TestFlight → u buildu odpovědět na **Export Compliance** a přidat ho do skupiny testerů (interní testeři = členové týmu, bez review; externí = první build prochází Beta App Review).

## Known limits / rozhodnutí k potvrzení

- **Export compliance:** aplikace používá šifrování (E2EE, standardní algoritmy AES-GCM/X25519/Ed25519). `ITSAppUsesNonExemptEncryption` záměrně **není** nastaveno — odpověď je právní prohlášení vlastníka účtu; dokud klíč chybí, ptá se App Store Connect u každého buildu.
- **Push:** bez APNs klíče a Firebase projektu; `UIBackgroundModes=remote-notification` je v Info.plist, entitlement `aps-environment` ne → Apple pošle varovný e-mail (ITMS-90078), upload neblokuje.
- **Náklady CI:** macOS runner (10× minuty). Na private repu vyžaduje spending limit, nebo dočasně public repo jako u `deploy.yml`.
- **Cloud signing** vyžaduje roli App Manager/Admin u API klíče a Xcode ≥ 13 na runneru (macos-latest splňuje).
