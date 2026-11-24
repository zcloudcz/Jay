# Go-live: manual acceptance

Spec: `docs/superpowers/specs/2026-11-14-go-live.md`. Automated coverage is
listed per row; every manual scenario stays NOT_RUN until it was done by hand
on a real device or browser against beta, with date and tester.

| # | Scenario | Platform | Automated | Manual |
|---|----------|----------|-----------|--------|
| M1 | Anonymous primary: Settings > Account > Delete account, read consequences, type own handle, confirm. App lands on onboarding with no chats; a contact's message to the old handle is not delivered; `GET /devices/{old}` gives 404. | Android | `account_deletion_test.dart`, server `PrivacyEndpointsTests` | NOT_RUN |
| M2 | Registered account with a linked laptop: delete on the phone with the passphrase. The laptop is signed out (device gone); the account e-mail can register again. | iOS + web | same | NOT_RUN |
| M3 | Wrong passphrase in M2: error shown, nothing deleted, app still works. | iOS | `account_deletion_test.dart` | NOT_RUN |
| M4 | App lock on: delete asks for PIN/biometrics before the confirmation step. | Android | none (platform dialog) | NOT_RUN |
| M5 | Settings > Privacy > Export my data: share sheet on iOS/Android, download on web, save dialog on Windows; the JSON lists groups, mutes and blocks. | all | `account_deletion_test.dart` (exportMyData), server export tests | NOT_RUN |
| M6 | Block from the 1:1 menu: chat disappears from the list; the blocked person's messages and calls do not arrive (their app shows them as sent); Settings > Privacy > Blocked people > Unblock brings delivery back. | Android + iOS | `user_safety_test.dart`, server `UserSafetyTests` | NOT_RUN |
| M7 | Block a member from group info: their group messages no longer appear for me, others still see them. | any | server `UserSafetyTests` | NOT_RUN |
| M8 | Report from a message long-press with the text attached; the operator list `GET /admin/user-reports` shows the text and no reporter. | any + operator token | `user_safety_test.dart`, server `UserSafetyTests` | NOT_RUN |
| M9 | Onboarding shows the consent line; both links open the cs page in a Czech UI and the en page otherwise. Same in Settings > About. | iOS + Android | `user_safety_test.dart` | NOT_RUN |
| M10 | Every URL below opens the page (not the Flutter app), and `/.well-known/security.txt` is plain text. | browser | `test/web/legal_pages_test.dart` | NOT_RUN |
| M11 | The web deletion link `https://jay.zcloud.cz/#/settings/account/delete` opens the delete screen in the web app. | browser | none | NOT_RUN |
| M12 | Owner check of facts in the privacy policy: Hostinger data centre location (the page names Hostinger without a location on purpose), whether App Service HTTP logs are on in production (the page says the app keeps IPs only in memory). | owner | none | NOT_RUN |

URLs for M10:

- https://jay.zcloud.cz/legal/privacy-cs.html, https://jay.zcloud.cz/legal/privacy-en.html
- https://jay.zcloud.cz/legal/terms-cs.html, https://jay.zcloud.cz/legal/terms-en.html
- https://jay.zcloud.cz/legal/delete-account-cs.html, https://jay.zcloud.cz/legal/delete-account-en.html
- https://jay.zcloud.cz/legal/support-cs.html, https://jay.zcloud.cz/legal/support-en.html
- https://jay.zcloud.cz/.well-known/security.txt
