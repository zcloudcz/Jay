# Potvrzení přijetí zprávy reakcí bota - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-11-bot-ack-reactions.md`. Větev `feat/bot-ack-reactions`.

Zařízení: P = telefon vlastníka bota, H = bot na `hermes_bridge` (jay-bridge na zahy-dev), L = bot na `llm_bridge`
(např. HackerBot), A = bot na `a2a_bridge`, G = skupina P + H + L se zapnutou konverzací botů.

## Automatické ověření

| Co | Stav |
| --- | --- |
| `calltype_bot`: `dart analyze` + `dart test` (vč. `ack_reaction_test`) | viz report větve |
| `hermes_bridge`, `llm_bridge` (vč. `ack_test`), `a2a_bridge` (vč. `ack_test`), `jay_archiver`: analyze + test | viz report větve |
| Docker build `hermes_bridge`, `llm_bridge`, `a2a_bridge` | viz report větve |
| N1 server: `MutePushTests` (tiché odeslání bez pushe, doručení po připojení, fallback text) + celá serverová sada | viz report větve |
| N2/N4 `calltype_core` `signalr_client_test`, `calltype_bot` `reaction_send_test` | viz report větve |
| N3 app: `notification_service_test`, `notification_directory_test`, `message_reactions_inbox_test` | viz report větve |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| K1 | P napíše H "ahoj" | Na zprávě hned 👀, pak odpověď, 👀 se změní na ✅ | NOT_RUN |
| K2 | P napíše H "díky" | 👀, pak 👍, žádná textová odpověď | NOT_RUN |
| K3 | P napíše L "ahoj", pak "díky" | Jako K1 a K2 | NOT_RUN |
| K4 | Zastavit jay-bridge (H), P napíše H | Žádné 👀 (signál, že bridge neběží); po spuštění přijde 👀 a odpověď | NOT_RUN |
| K5 | P zadá H dlouhou úlohu | 👀 hned, po chvíli "Working on it...", na konci odpověď a ✅ | NOT_RUN |
| K6 | Chyba modelu (např. L se špatným klíčem) | Omluva s důvodem a ❌ | NOT_RUN |
| K7 | V G: P zmíní L, L odpoví a zmíní H | Obě zprávy (od P i od bota L) mají 👀 a pak ✅ od adresovaného bota | NOT_RUN |
| K8 | V G vypnout konverzaci botů, L zmíní H | H nic neudělá, žádná reakce | NOT_RUN |
| K9 | V G dojde limit výměny botů | Jedna hláška "Bot limit reached...", bez reakce; boti se navzájem nezacyklí reakcemi | NOT_RUN |
| K10 | P dá na odpověď H 👍 (REACTION_MODE=silent) | Funguje jako dřív; H na tuto reakci nereaguje reakcí | NOT_RUN |
| K11 | `ACK_REACTIONS=off` u H, P napíše "ahoj" | Jen odpověď, žádné 👀 ani ✅ | NOT_RUN |
| K12 | P zavře aplikaci a napíše H z webu W | P dostane push jen kvůli odpovědi, ne kvůli 👀 ani ✅ (N1) | NOT_RUN |
| K13 | P má aplikaci na pozadí (připojenou), napíše H | Upozornění jen na odpověď, žádné "H reacted 👀/✅" (N3) | NOT_RUN |
| K14 | Kamarád dá 👍 na zprávu P, pak ji změní na ❤️ | Jedno upozornění (na 👍), změna už ne (N3) | NOT_RUN |
