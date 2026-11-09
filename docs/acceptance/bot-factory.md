# Továrna na boty (llm_bridge, jay-new-bot, "Nový bot") - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-09-bot-factory.md`. Větev `feat/bot-factory`.

Předpoklad pro ruční scénáře: workflow `llm-bridge-release.yml` (a pro Docker `llm-bridge-image.yml`) proběhl na commitu z `master` a balíky jsou na `https://github.com/zcloudcz/Jay/releases/tag/llm-bridge-latest`; web s `/bots/new-bot.sh` a `.ps1` je nasazený. Do té doby jsou všechny ruční scénáře BLOCKED na release.

Zařízení: P = telefon majitele (primární), W = web propojený s P, L = počítač s Linuxem (systemd), M = Mac (Apple Silicon), Win = Windows 10/11, D = stroj s Dockerem.

## Automatické ověření (lokálně na větvi)

| Co | Stav |
| --- | --- |
| `llm_bridge`: `dart analyze`, `dart test` (config, HTTP provideři proti falešnému serveru, CLI provideři s falešnými programy, logika tahů, skutečný runtime bota s falešným hubem) | PASS, 58 testů |
| `llm_bridge`: `dart build cli` linux-x64, binárka bez env skončí kódem 78 s jasnou hláškou | PASS |
| `llm_bridge`: Docker image `docker build -f src/bots/llm_bridge/Dockerfile src`, kontejner bez env skončí 78 | PASS |
| `infra/bots/test-scripts.sh`: shellcheck, `--dry-run` matice (5 providerů x Linux/macOS/Docker), žádné tajemství ve výstupu, chybové argumenty, rerun drží identitu, PowerShell parse + `-DryRun` matice (pwsh z oficiálního Docker image, PSScriptAnalyzer v něm není) | PASS, 199 kontrol |
| Skript naostro v čistém Debian kontejneru s lokálním balíkem (`JAY_BOT_BUNDLE_BASE=file://`), API nedostupné: stažení, kontrola SHA256, rozbalení, `bot.env` 600, `run.sh`, rerun drží `BOT_STORE_KEY` i API klíč, poškozený balík odmítnut beze změny, `--remove` bez tty identitu ponechá, `--remove --yes` smaže | PASS |
| Skript pod bash 3.2 (výchozí na macOS), `--dry-run` všech providerů | PASS |
| App: `flutter gen-l10n` (`l10n_untranslated.json` = `{}`), `flutter analyze`, celý `flutter test` (vč. `new_bot_screen_test`, `bot_scripts_test`) | PASS, 792 testů; `calltype_core` 187 testů |
| `flutter build web`: `build/web/bots/new-bot.sh` a `.ps1` jsou skutečné soubory shodné s `infra/bots/` | PASS |
| `actionlint` nad `llm-bridge-release.yml`, `llm-bridge-image.yml`, `ci.yml` | PASS |
| `calltype_bot`, `hermes_bridge`, `a2a_bridge`, `jay_archiver` | nezměněny, nespouštěno |
| Oprava `fix/bot-cli-path` (spec B6b): `llm_bridge` `dart analyze` + `dart test` (mapování chyb CLI: 127 a "env: 'node': No such file" = chyba spuštění s radou na PATH služby, bez "signed in"; 401/"Not logged in" = rada přihlásit se; jinak neutrální "failed with exit code N") | PASS, 65 testů |
| Oprava `fix/bot-cli-path`: `infra/bots/test-scripts.sh` vč. falešného npm CLI (`#!/usr/bin/env node`, node v nestandardní složce): PATH služby v `run.sh`, plistu i `run.ps1` obsahuje složku node; chybějící interpret a neprojitá kontrola spuštění ukončí instalaci jasnou hláškou dřív, než se cokoli zapíše; shellcheck; pwsh z Docker image; PSScriptAnalyzer 1.22 bez nálezů | PASS, 225 kontrol |
| Oprava na tomto stroji (a): skutečný `~/.local/bin/codex` (npm, `#!/usr/bin/env node`), skript spuštěný přes `env -i` s PATH bez `~/.local/bin`: `--check-only` sestaví PATH služby se složkou `~/.hermes/tools/node-26.7.0-linux-x64/bin` a `env -i ... codex --version` projde | PASS |
| Oprava (b): totéž s PATH, kde node chybí: instalace skončí hláškou "is a script that runs 'node' ..., but 'node' is not on your PATH"; ruční `env -i PATH=<PATH služby bez složky node> codex --version` = exit 127 | PASS |
| Oprava (c): `--dry-run --provider codex-cli` vypíše `service PATH=` se složkou node a příkaz kontroly | PASS |

## Ruční scénáře

### Skript na jednotlivých systémech

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| S1 | L: příkaz z aplikace (Linux, Claude API), klíč zadat do skrytého promptu | Služba `jay-bot-<jméno>` běží (`systemctl --user status`), skript vypíše handle a invite, klíč se nikde nevypsal; hint na `loginctl enable-linger`, pokud chybí | NOT_RUN |
| S2 | M: příkaz z aplikace (macOS) | LaunchAgent `cz.zcloud.jay-bot-<jméno>` načtený, bot běží i po odhlášení a přihlášení | NOT_RUN |
| S3 | Win: příkaz z aplikace v PowerShellu 5.1 (bez admin práv) | Naplánovaná úloha "Jay bot <jméno>" existuje a běží, `bot.env.json` čitelný jen pro uživatele, po odhlášení/přihlášení bot znovu naběhne | NOT_RUN |
| S4 | Win: totéž v PowerShellu 7 | Totéž | NOT_RUN |
| S5 | D: příkaz s `--docker` | Kontejner `jay-bot-<jméno>` s restart policy a volume, skript vypíše handle | NOT_RUN |
| S6 | L bez systemd (WSL1) | Bot běží na pozadí, skript upozorní, že nepřežije restart | NOT_RUN |
| S7 | Intel Mac | Skript odmítne s radou `--docker` | NOT_RUN |

### Provideři

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| P1 | `anthropic` s platným klíčem, výchozí model `claude-sonnet-5-5` | Odpověď přijde; delší odpověď se streamuje do zprávy "Working on it..." | NOT_RUN |
| P2 | `anthropic` se špatným klíčem | Bot odpoví jednou omluvou "refused the credentials (HTTP 401 ...)" | NOT_RUN |
| P3 | `openai` s klíčem, výchozí `gpt-6.1-sol` | Odpověď přijde, streamuje se | NOT_RUN |
| P4 | `openai` s `--base-url http://localhost:11434/v1 --model <model>` (Ollama) bez klíče | Odpověď přijde | NOT_RUN |
| P5 | `claude-cli`: Claude Code nainstalovaný a přihlášený předplatným | Odpověď přijde; v `~/.claude` nevznikají sessions bota; bot nespouští žádné nástroje | NOT_RUN |
| P6 | `claude-cli` bez přihlášení | Skript varuje; bot odpoví omluvou s radou přihlásit se | NOT_RUN |
| P7 | `codex-cli`: Codex přihlášený přes ChatGPT | Odpověď přijde | NOT_RUN |
| P8 | `hermes` proti běžícímu Hermes API | Bot (hermes_bridge) odpovídá; skript radí přidat bota podle handle (pozdrav jen u llm_bridge) | NOT_RUN |
| P9 | Windows + `claude-cli` (claude.exe i npm `claude.cmd`) | Odpověď přijde (prázdný argument `--tools ""` přes cmd) | NOT_RUN |
| P10 | L: `codex-cli` z npm, node jen v nestandardní složce (nvm, `~/.hermes/tools/node-*`), bot založený skriptem z opravy B6b (stávající bot: znovu spustit jeho instalační příkaz) | Skript ohlásí "Checked: codex starts with the bot service PATH", `run.sh` obsahuje `PATH=` se složkou node, bot odpovídá; bez node skript skončí jasnou hláškou a nic nenainstaluje | NOT_RUN |
| P11 | Win: `codex-cli` přes npm `codex.cmd`, node z instalátoru nebo nvm-windows | `run.ps1` dává složku `node.exe` na začátek PATH, bot odpovídá | NOT_RUN |

### Chování bota

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| G1 | První start nového bota | Do minuty přijde na P zpráva "Ahoj, jsem <jméno>. Napiš mi." (+ anglický řádek), bot je v seznamu chatů; po odpovědi je v kontaktech | NOT_RUN |
| G2 | Restart služby | Pozdrav se neopakuje | NOT_RUN |
| G3 | Konverzace o 3+ zprávách, pak `/new` | Bot si pamatuje kontext; po `/new` ne | NOT_RUN |
| G4 | Cizí uživatel napíše botovi | Žádná odpověď, žádné "píše..." | NOT_RUN |
| G5 | Skupina P + B + bot: P zmíní bota | Odpoví do skupiny; B bota neovládá | NOT_RUN |
| G6 | `/help` a menu "/" | Menu ukazuje `/new` a `/help`, `/help` popíše bota a providera | NOT_RUN |

### Aplikace (průvodce)

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| A1 | W (prohlížeč na Windows): Nastavení -> Boti -> Nový bot | Předvolen Windows, příkaz pro PowerShell, Kopírovat funguje | NOT_RUN |
| A2 | P (telefon): totéž | Předvolen Linux; příkaz jde zkopírovat a poslat si ho | NOT_RUN |
| A3 | Kontakty (z "Nový chat"): ikona robota | Otevře průvodce | NOT_RUN |
| A4 | Docker v průvodci | Volby předplatného jsou nedostupné, příkaz končí `--docker` | NOT_RUN |
| A5 | W jako propojené zařízení (companion) | `--owner` je handle primárního P | NOT_RUN |
| A6 | Čeština a jeden RTL jazyk (arabština) | Texty přeložené, rozložení v pořádku | NOT_RUN |

### Aktualizace a odstranění

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| R1 | Spustit stejný příkaz znovu (po novém release balíků) | Binárka aktualizovaná, handle stejný, kontakty a historie zůstanou, nezeptá se znovu na klíč | NOT_RUN |
| R2 | Znovu s jiným `--provider` | Zeptá se na klíč nového providera, identita zůstane | NOT_RUN |
| R3 | `--remove` (Windows `-Remove`) a odpověď "n" | Služba pryč, `~/.jay-bots/<jméno>` zůstane; nový běh příkazu vrátí stejného bota | NOT_RUN |
| R4 | `--remove` a odpověď "y" | Služba i identita pryč | NOT_RUN |

### Web hosting

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| W1 | `curl -sI https://jay.zcloud.cz/bots/new-bot.sh` a `.ps1` | 200, `text/plain; charset=utf-8`, `Cache-Control: no-cache`, obsah začíná `#!/usr/bin/env bash` / komentářem skriptu, ne `<!DOCTYPE html>` | NOT_RUN |

### Release workflow

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| C1 | První běh `llm-bridge-release.yml` | Všechny 4 cíle zelené (vč. linux-arm64 runneru a Windows smoke testu), release `llm-bridge-latest` je prerelease a NENÍ "latest", 8 zipů + `SHA256SUMS`; `/releases/latest/download/Jay-windows-x64.zip` dál vede na Windows aplikaci | NOT_RUN |
| C2 | První běh `llm-bridge-image.yml` a zveřejnění balíčku `ghcr.io/zcloudcz/jay-llm-bridge` | Image public, `docker pull` bez přihlášení | NOT_RUN |
