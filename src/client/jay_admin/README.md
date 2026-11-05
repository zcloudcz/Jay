# jay_admin

Operator web for channel moderation, served at `https://jay.zcloud.cz/admin/`
(same Static Web App as the app, built with `--base-href /admin/`). Contract:
`docs/superpowers/specs/2026-11-05-channel-moderation-contract.md` section 4
(API) and section 8 (this package).

```bash
cd src/client/jay_admin
flutter pub get            # also runs gen-l10n (generated files are git-ignored)
flutter analyze
flutter test
flutter run -d chrome --dart-define=CALLTYPE_API_BASE_URL=http://localhost:8080
flutter build web --release --base-href /admin/ \
  --dart-define=CALLTYPE_API_BASE_URL=https://<api host>
```

- Login: e-mail + passphrase (authKey = hex SHA-256, as in the app) + TOTP or
  backup code. The account must be in `Moderation:OperatorAccountIds` and have
  MFA enabled. The operator token lives in memory only: a reload or 30 minutes
  means a new login, which returns to the same screen.
- API base URL: `CALLTYPE_API_BASE_URL` (falls back to the app's
  `API_BASE_URL`, default `http://localhost:8080`). Anything other than HTTPS
  or a loopback HTTP address is refused at startup.
- Screens: overview, report queue (j/k/Enter), case detail with decision
  panel, channel search, audit log with CSV export. Locales cs + en.
