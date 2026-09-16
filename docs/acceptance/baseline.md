# B00 — baseline a integrace (2026-09-16)

## Baseline

- Baseline commit: `17a8196` (`codex/beta-B00`) — snapshot všech dosud necommitnutých beta změn; `FABLE.md` a `.claude/` zůstávají netrackované.
- Nástroje: .NET SDK 10.0.401, Flutter 3.41.2 (stable), Docker Desktop **nedostupný** (nešel spustit) → Testcontainers integrační testy BLOCKED v tomto prostředí.
- Větve balíčků (worktrees `C:\GIT\ZCLOUD\ZMessanger-wt\<ID>`): D01 `c78591f`, D02 `8375d61`, D03 `19465f4`, D04 `5d8bce6`, D05 `aa5377a`, R01 `3e8635a`, INF (I01–I04) `ab4c247`. Všechny sloučeny do `codex/beta-B00` bez konfliktů (Program.cs auto-merge D02 + D05).

## Ověření na sloučeném commitu

| Sada | Příkaz | Výsledek |
| --- | --- | --- |
| Backend build | `dotnet build src/server/CallType.Api.Tests -c Release` | exit 0, 0 chyb |
| Backend unit (bez DB) | `dotnet test … --filter ProductionConfigurationValidator\|FcmResponseEvaluator\|FcmTokenProvider` | PASS |
| Backend integrační (Testcontainers) | `dotnet test src/server/CallType.Api.Tests -c Release` | BLOCKED — Docker nedostupný; nutno spustit na stroji s Dockerem nebo v hosted CI |
| Flutter | `flutter analyze` / `flutter test` | No issues / 143 passed |

## Schéma

- Jediná nová migrace `20260916094035_BackupQuotas` (D02): přidává `Backups.Status` (default `Completed` pro existující řádky) a `Backups.ReservationExpiresAt`, index `IX_Backups_AccountId_Status`. Aditivní; aplikovat přes `dotnet ef database update` (deploy.yml krok), startup migrace zůstávají vypnuté.
- Migrační test nad kopií předchozího schématu (B00-B): NOT_RUN (Docker).

## Nové konfigurační klíče

- `BackupLimits:MaxFileBytes` (8388608), `BackupLimits:MaxPerAccount` (3), `BackupLimits:MaxTotalBytes` (268435456) — env `BackupLimits__*`.
- Nový endpoint `GET /health/ready`, `DELETE /backups/{accountId}/{backupId}`.
- Produkční start nyní odmítne dev hodnoty `Jwt:Secret`, `Turn:SharedSecret`, `ConnectionStrings:*` a chybějící `Cors:AllowedOrigins` (D05).

## Code review B00 (nálezy opravené při integraci)

- deploy.yml: job `deploy-api` neměl checkout ani .NET SDK pro `dotnet ef database update` → doplněno.
- deploy.yml: Windows zip se ukládal o úroveň jinam, než čekal manifest/upload → cesta opravena.
- deploy.yml: SWA `app_location` neodpovídalo struktuře staženého artefaktu (`build/web`) → opraveno.
- ProductionConfigurationValidator: `Contains("Password=postgres")` odmítal každé heslo začínající na `postgres` → parsování přes `NpgsqlConnectionStringBuilder`, doplněn test.

## Známé limity / otevřené položky

- Rezervace zálohy má pevné TTL 10 min bez heartbeatu (ponytail); upload delší než TTL skončí 500 a osiřelý blob. Při ≤ 8 MiB přijatelné.
- Q01 (zařízení), I02/I03 provozní kroky, hosted CI běh, Apple podpis, reálný push a TURN hovor: BLOCKED — viz reporty balíčků a `docs/ops/evidence/`.
- Rozpočet ≤ 20 USD nepotvrzen (I04 blockery).

## Nasazení 2026-09-16 (commit `0feeac4`)

| Krok | Stav |
| --- | --- |
| Repo `github.com/zcloudcz/Jay` (private), master + `codex/beta-*` pushnuty | PASS |
| Migrace `BackupQuotas` přes Kudu helper (`/home/data/db-probe`, `dotnet DbProbe.dll --migrate`) | PASS (provedl operátor, hlásí "Migrations applied") |
| API `az webapp deploy` zip → `/health` 200, `/health/ready` 200 | PASS |
| Web SWA (`swa deploy --env production`) → 200, `sqlite3.wasm` `application/wasm` | PASS |
| Autentizovaný SignalR / backup smoke po nasazení | NOT_RUN |
| Hosted CI (`deploy.yml`) | NOT_RUN — nasazeno ručně z lokálních artefaktů stejného commitu |

## Nasazení Cloudflare TURN 2026-09-16 (commit `830c110`)

| Krok | Stav |
| --- | --- |
| Azure app settings `Turn__Provider=cloudflare`, `Turn__Cloudflare__KeyId`, `Turn__Cloudflare__ApiToken` (nastavil operátor) | PASS (ověřeny jen názvy) |
| API zip deploy → `/health` 200, `/health/ready` 200 (po studeném startu) | PASS |
| Autentizovaný `GET /turn/credentials` (dočasná testovací identita) → 200, `urls` = Cloudflare stun/turn UDP+TCP 3478 + turns TLS 5349, TTL 3600 | PASS |
| Skutečný hovor přes Cloudflare relay (forced relay, dvě sítě) | NOT_RUN |

Pozn.: `Turn__StunUrls__0` stále ukazuje na `stun:187.127.83.154:3478`; Cloudflare STUN je v `urls`, starý záznam lze odstranit při vyřazení coturn.

## Vyřazení coturn 2026-09-16

- Z App Service smazány `Turn__StunUrls__0`, `Turn__Urls__0`, `Turn__Urls__1`, `Turn__SharedSecret`; zůstávají `Turn__Provider=cloudflare`, `Turn__Cloudflare__*`, `Turn__TtlSeconds`. `/health/ready` 200 po restartu.
- Serverová část (stop/disable coturn, zavření 3478 a relay rozsahu) — provedl operátor serveru 2026-09-16; TCP 3478 z vývojářského stroje nedosažitelný (PASS, dle probe níže v commitu).

## Hosted CI/CD deploy 2026-09-16 (commit `9816709`, run 35129788149)

| Krok | Stav |
| --- | --- |
| `deploy.yml` (workflow_dispatch, SHA-pinned, `confirm_backup=true`) | PASS — run https://github.com/zcloudcz/Jay/actions/runs/35129788149 |
| Testcontainers backend sada na hosted runneru | PASS 154/154 (první skutečný běh integračních testů D01/D02/D05) |
| Flutter analyze + test | PASS |
| Artefakty (stejné SHA): api 3 MiB, web 12 MiB, android 52 MiB, windows 22 MiB, macos 229 MiB, ios-unsigned 14 MiB + manifesty | PASS (retention 90 dní) |
| `deploy-api` přes OIDC (federated credential musí mít GitHub subject s ID `repo:zcloudcz@…/Jay@…:environment:calltype-beta`) | PASS; migrace při startu (`Database__ApplyMigrationsOnStartup=true`) |
| `deploy-web` SWA | PASS |
| Smoke `/health` 200, `/health/ready` 200, web 200 | PASS |
| SignalR autentizovaný smoke ve workflow | NOT_RUN (dokumentovaná mezera) |

Poznámky: iOS build vyžadoval zvýšení deployment target na 14.0 (`file_picker_darwin`). Repo bylo dočasně PUBLIC kvůli vyčerpaným Actions minutám pro private repo (macOS runnery); po úspěšném runu vráceno na PRIVATE — další hosted runy vyžadují spending limit nebo public repo.
