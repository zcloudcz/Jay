# llm_bridge: záložní modely a záchranné akce - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-12-llm-bridge-fallback-rescue.md`. Větev `feat/llm-bridge-rescue`.

Zařízení: P = telefon vlastníka, R = záchranný bot na `llm_bridge` (Claude Code CLI, `LLM_FALLBACK=codex-cli`,
`--rescue-hermes`), na stejném stroji běží Hermes (Linux: systemd user unit `hermes-gateway`), W = počítač
s Windows a Hermes jako Scheduled Task.

## Automatické ověření

| Co | Stav |
| --- | --- |
| `llm_bridge`: `dart analyze` + `dart test` (vč. `fallback_test`, `actions_test`, `os_process_test`) | PASS: bez nálezů, 200 testů (master 131) |
| `calltype_bot`, `hermes_bridge`, `a2a_bridge`: analyze + test (regrese, beze změn) | PASS: 155 / 174 / 47 testů |
| Pravidla Windows (spouštění `.cmd` přes cmd.exe, `taskkill /T`, kódování, CRLF) přes OS seam `HostOs` | PASS v unit testech (12 testů seamu); na skutečném Windows NOT_RUN (AC7) |
| Docker build `llm_bridge`, `dart build cli` linux-x64 | PASS |
| `infra/bots/test-scripts.sh` v kontejneru jako runner (PowerShell, shellcheck, PSScriptAnalyzer 1.22.0) + `koalaman/shellcheck:stable` | PASS: 380 kontrol (309 před `--fallback`); lokálně se skutečným bubblewrap 336 kontrol (bez PowerShell), vč. falešné instalace se dvěma CLI v sandboxu |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| AC1 | `LLM_PROVIDER=claude-cli`, `CLAUDE_BIN=/nonexistent`, `LLM_FALLBACK=codex-cli`, P napíše "ahoj" | Odpoví Codex; v `bot.log` řádek `LLM: Claude Code CLI failed (...), trying Codex CLI.` | NOT_RUN |
| AC2 | Obě CLI rozbité (např. i `CODEX_BIN=/nonexistent`) | Jedna omluva, která jmenuje obě chyby; reakce ❌ | NOT_RUN |
| AC3 | Bez `LLM_FALLBACK` a bez `LLM_ACTIONS` | Chování i argv CLI stejné jako na masteru (jen limit prvního výstupu 60 s) | NOT_RUN |
| AC4 | R, P napíše "restartuj Hermes" | Model si řekne o akci `restart`, bridge spustí přesně nastavený příkaz (`Running: restart`), model nahlásí výsledek | NOT_RUN |
| AC5 | R, P napíše "smaž /tmp/x" nebo "restart hermes && rm -rf /tmp/x" | Odmítnuto, nic se nesmaže (model nemůže předat argumenty ani spustit nic mimo seznam) | NOT_RUN |
| AC6 | R s rozbitým Claude (běží Codex), znovu AC4 a AC5 | Stejné výsledky (seznam vynucuje bridge, Codex nemá nástroje) | NOT_RUN |
| AC7 | W, `-RescueHermes '<task>'`, P napíše "status" | Spustí se nastavený `schtasks.exe /query` a model ho nahlásí | NOT_RUN |
| AC8 | Linux: `jay-new-bot.sh --provider claude-cli --fallback codex-cli --rescue-hermes hermes-gateway`, pak rozbít Claude (`claude auth logout` nebo vyčerpaný plán), P napíše "status" | Skript při instalaci ověří obě CLI v sandboxu; odpoví Codex přes `cli-codex.sh` v sandboxu, v `bot.log` řádek o přepnutí | NOT_RUN (automaticky: falešné claude + codex + node s opravdovým bubblewrap, obě CLI startují v sandboxu, `~/.hermes` neviditelný: PASS) |

Poznámky pro ruční test:

- Akce smí spustit jen vlastník v 1:1 chatu; ve skupině se direktiva zahodí a zaloguje (pokryto unit a runtime testy).
- Na Linuxu je s akcemi v sandboxu jen CLI (`cli-claude.sh`, `cli-codex.sh`), ne celý bridge. Zkontrolovat `~/.jay-bots/<name>/cli-claude.sh`
  a že `~/.jay-bots/<name>/sandbox.sh /bin/sh -c 'ls ~/.hermes'` selže.
- `LLM_FALLBACK` nastaví skript volbou `--fallback codex-cli` (Windows `-Fallback codex-cli`, spec F12): uloží
  `LLM_FALLBACK`, `CODEX_BIN`, dá složku node na `PATH` v `run.sh` a sandbox zpřístupní obě CLI i oba loginy.
  S akcemi vzniknou `cli-claude.sh` i `cli-codex.sh`. Zkontrolovat:
  `~/.jay-bots/<name>/sandbox.sh /bin/sh -c 'ls ~/.claude ~/.codex'` projde, `... 'ls ~/.hermes'` selže.
