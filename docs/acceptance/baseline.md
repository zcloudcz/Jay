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
