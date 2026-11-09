# Přístup k botům (serverová politika, skupiny s majitelem, boti v llm_bridge, sandbox) - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-09-bot-access.md`. Větev `feat/bot-access` (nevydáno).

Předpoklad pro ruční scénáře P1-P5, P7: server z této větve nasazený na betu (migrace `AddBotInboundPolicy`, potřeba zálohy DB) a nové balíky botů (`llm-bridge-release.yml`) z `master`. Do té doby BLOCKED na release.

Zařízení: P = telefon majitele, X = telefon jiného člověka (ne majitel), L = Linux se systemd a `bwrap`, M = Mac, Win = Windows.

## Automatické ověření (lokálně na větvi)

| Co | Stav |
| --- | --- |
| Server: build, cílené testy (`FanoutHubTests`, `BotCommandsEndpointsTests`, `DeviceEndpointsTests`, `DatabaseSchemaTests`) | PASS, 89 testů |
| Server: celá sada (Testcontainers) | PASS, 719 testů |
| `calltype_protocol` analyze + test (nový `prekey_replenish_test`) | PASS, 142 testů |
| `calltype_core` codegen, analyze + test | PASS, 193 testů |
| App: `flutter gen-l10n` (`l10n_untranslated.json` = `{}`), `flutter analyze`, celý `flutter test` (vč. `new_bot_screen_test`) | PASS, 889 testů |
| Boti analyze + test: `calltype_bot` / `hermes_bridge` / `llm_bridge` / `a2a_bridge` / `jay_archiver` | PASS, 110 / 108 / 72 / 41 / 33 (+7 přeskočených e2e bez serveru) testů |
| `infra/bots/test-scripts.sh`: shellcheck, dry-run matice vč. sandboxu a varování, chybové argumenty | PASS, 193 kontrol bez pwsh; s pwsh (oficiální Docker image `mcr.microsoft.com/powershell`, bez PSScriptAnalyzer) 233 kontrol |
| `flutter build web --release` | PASS |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| P1 | llm_bridge bot (API klíč) na nové betě; X mu napíše 1:1 | Bot nic nedostane (`bot.log` bez záznamu, v `QueuedMessages` pro bota nic), X vidí odeslanou zprávu jako normálně; P dostane odpověď | NOT_RUN |
| P2 | Skupina P + X + bot; X napíše `@bot otázka` | Bot odpoví X s citací jeho zprávy; model vidí `[from CT-...]` X | NOT_RUN |
| P3 | Skupina X + bot (bez majitele); X bota zmíní | Bot mlčí; server zprávu botovi neuloží | NOT_RUN |
| P4 | Skupina P + bot A (llm_bridge) + bot B, konverzace botů zapnutá, limit 3 | Boti si odpoví nejvýš 3 tahy, pak jedna hláška "Bot limit reached, waiting for a human."; zpráva člověka konverzaci obnoví | NOT_RUN |
| P5 | hermes_bridge po restartu na nové betě | Log "Inbound policy: owners only (...)"; Hermes dál odpovídá majiteli | NOT_RUN |
| P6 | Bot nové verze proti STARÉMU serveru (beta bez endpointů) | Log "Server has no bot inbound policy yet..." a "Server has no one-time pre-key endpoint; not replenishing.", bot normálně odpovídá | PASS (2026-11-09, dočasný bot `a7-test` proti betě) |
| P7 | Bot na nové betě, server drží < 20 jednorázových pre-keys | Log "Uploaded N one-time pre-keys (server had M)." | NOT_RUN |
| P8 | L: `jay-new-bot.sh --provider codex-cli --group-replies members` s lokálním balíkem, pak odpověď na zprávu majitele | Skript hlásí sandbox, `sandbox.sh` 700, `bot.env` 600, unit má `NoNewPrivileges=yes`, proces běží v jiném mount namespace pod `bwrap`; v sandboxu není vidět `~/.hermes/jay-bridge.env`, `~/.ssh` ani jiní boti, `~/.codex` ano; bot odpověděl `SANDBOX-OK`; `--remove --yes` vše smazal | PASS (2026-11-09, zahy-dev, Ubuntu 26.04) |
| P9 | L: totéž s `--provider claude-cli` (rerun se stejným jménem) | Identita zachovaná, v sandboxu jen `.claude`, `.claude.json`, `.jay-bots`, `.local`; bot odpověděl `SANDBOX-OK` | PASS (2026-11-09) |
| P10 | M: `--provider claude-cli --group-replies members` | Varování "no sandbox ... separate macOS user" | NOT_RUN (dry-run PASS) |
| P11 | Win: `-Provider codex-cli -GroupReplies members` | Varování "no sandbox on Windows" | NOT_RUN (pwsh dry-run v Dockeru PASS) |
| P12 | App: Nastavení > Boti > Nový bot, každý provider | Pod kroky text, kdo může bota oslovit a kdo platí; u předplatného volba `--group-replies members` / `-GroupReplies members` podle systému | NOT_RUN (widget test PASS) |
| P13 | HackerBot na tomto stroji: po vydání znovu spustit jeho instalační příkaz | Stejný handle, běží v sandboxu, publikuje politiku | NOT_RUN |
