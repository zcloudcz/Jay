# Boti + Kanály — paralelní exekuce

Zadavatel 2026-09-17 výslovně spustil implementaci před uzavřením G1–G5 bety (přebíjí poznámku „nezačínat“ v obou plánech). Specifikace: `2026-09-17-bots.md`, `2026-09-16-channels.md` (§7 Rozhodnutí má přednost).

Integrační větev: `feat/bots-channels`. Každý proud pracuje ve vlastním worktree na větvi `feat/bc-<id>`, koordinátor merguje do integrační větve po každé vlně.

## Proč takhle nařezané

Paralelní proudy nesmí sdílet „horké“ soubory: `AppDbContext` + EF model snapshot (dvě souběžné migrace = konflikt snapshotu), `MessengerHub.cs`, `Program.cs`, klientský `database.dart` (jedno číslo `schemaVersion`), `signalr_client.dart`. Proto jsou balíčky z původních plánů sloučené podle vlastnictví souborů, ne podle feature.

## Vlny

| Vlna | Proud | Obsah (balíčky z plánů) | Výhradně vlastní |
| --- | --- | --- | --- |
| 1 | **S0** server základ | T01 + C00: `Device.IsBot`, entity kanálů vč. `ChannelReport` a `OwnerAccountId`, migrace, `Channels:*` konfigurace, `ChannelPostCleanupService`, `isBot` v device endpointech, testy | `Models/`, `Data/`, `Migrations/`, `DeviceEndpoints.cs` |
| 1 | **K0** sdílené jádro | T00: pure Dart package `src/client/calltype_core/` (crypto, session, API + SignalR protokol), appka na něm zelená | `lib/core/crypto`, `lib/core/network/{api_client,signalr_client}.dart`, `lib/core/auth`, nový package |
| 2 | **S1** server kanály | C01 + C02: `ChannelEndpoints`, `ChannelService`, report, hub `JoinChannels` + `ReceiveChannelPost`, push throttling, testy | `Endpoints/ChannelEndpoints.cs`, `Services/Channel*`, `Hubs/`, `PushNotificationService.cs` |
| 2 | **B1** bot | T02 + T04: `src/bots/calltype_bot/`, `src/bots/hermes_bridge/`, testy | `src/bots/` |
| 2 | **F1** Flutter | T03 + C03: odznak BOT, drift migrace (jedna pro `is_bot` i tabulky kanálů), `lib/features/channels/`, záložka Aktualizace, deep link/QR, nahlásit/blokovat, testy | `src/client/calltype/lib/` mimo soubory K0, `calltype_core` jen přidáním metod |
| 3 | koordinátor | merge, celé test suity, code review, `docs/acceptance/{bots,channels}.md` (T05/C04 ruční přejímka = NOT_RUN, čeká na Martina) | docs |

Kontrakt mezi S1 a F1/B1 je text plánů (§2–§3 channels, §1 bots) — F1 proti němu píše klienta bez čekání na S1.

## Známá omezení prostředí

Docker na vývojovém stroji neběží → Testcontainers integrační testy se lokálně jen kompilují; zelenou dává až hosted CI (`deploy.yml`/`ci.yml`). Každý proud to musí ve výstupu přiznat, ne tvrdit PASS.
