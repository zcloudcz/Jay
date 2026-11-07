# Vyhledávání, připnuté zprávy a ankety v chatech - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-08-chat-extras.md`. Větev `feat/chat-extras`.

Zařízení: P = telefon (primární), W = web propojený s P (`https://jay.zcloud.cz`), B = druhý uživatel, S = starší verze aplikace (před touto změnou), G = běžná skupina P + B (+ případně bot), F = firemní skupina (Jay Business).

## Automatické ověření

| Co | Stav |
| --- | --- |
| `calltype_core`: `dart analyze` + `dart test` (vč. `pin_poll_test`, migrace v8 -> v9) | viz report větve |
| App: `flutter analyze` + `flutter test` (vč. `chat_extras_inbox_test`, `chat_extras_flow_test`, `chat_extras_widgets_test`, `message_search_test`, `backup_chat_extras_test`, `chat_message_list_test`) | viz report větve |
| Boti: `calltype_bot` (`chat_extras_test`), `hermes_bridge`, `a2a_bridge`, `jay_archiver` (`--exclude-tags e2e`) | viz report větve |

## Ruční scénáře

### Vyhledávání

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| H1 | Na P v seznamu chatů klepnout na lupu, napsat slovo ze staré zprávy | Výsledky ze všech chatů: název chatu, odesílatel, úryvek se zvýrazněnou shodou, datum; nejnovější nahoře | NOT_RUN |
| H2 | Hledat bez diakritiky a jinou velikostí písmen ("prilis" pro "Příliš") | Zpráva se najde | NOT_RUN |
| H3 | Klepnout na výsledek hluboko v historii | Otevře se chat odscrollovaný na zprávu, zpráva krátce zvýrazněná; tlačítko "nejnovější" vrátí dolů | NOT_RUN |
| H4 | V otevřeném chatu lupa v horní liště | Hledá jen v tomto chatu; klepnutí na výsledek se vrátí do chatu a skočí na zprávu | NOT_RUN |
| H5 | Hledat text smazané zprávy (smazat pro všechny) a název souboru | Nenajde se | NOT_RUN |
| H6 | Hledat otázku ankety a popisek fotky poslané přes šifrovaná média | Najde se | NOT_RUN |
| H7 | Na W (propojeném) hledat zprávu přijatou před propojením | Nenajde se (W má jen to, co přijal od propojení; uvedeno v limitech) | NOT_RUN |

### Připnuté zprávy

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| R1 | P v chatu s B: menu zprávy -> Připnout | Lišta "Připnutá zpráva" nahoře na P, W i B; v seznamu chatů se nic nemění, nepřečtené se nezvýší | NOT_RUN |
| R2 | Klepnout na lištu | Skok na připnutou zprávu se zvýrazněním; při více připnutých lišta přejde na další (1/3, 2/3, ...) | NOT_RUN |
| R3 | Ikona seznamu na liště | Seznam všech připnutých; klepnutí skočí, křížek odepne u všech | NOT_RUN |
| R4 | B odepne zprávu, kterou připnul P | Zmizí na P, W i B (připínat a odepínat smí kdokoli) | NOT_RUN |
| R5 | Připnout 4. zprávu | Dotaz "Nahradit nejstarší připnutou zprávu?"; po potvrzení jsou všude stejné 3 nejnovější | NOT_RUN |
| R6 | V G připnout zprávu, smazat ji pro všechny | Připnutí všude zmizí | NOT_RUN |
| R7 | S (stará verze) v chatu, kde P připne | S nic nezobrazí, nic nespadne (zpráva zůstává ve frontě serveru do TTL, přijatý limit jako u reakcí) | NOT_RUN |
| R8 | F (firemní skupina) | Akce Připnout v menu chybí | NOT_RUN |

### Ankety

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| A1 | P v chatu s B: sponka -> Anketa, otázka + 3 možnosti, jedna odpověď | Anketa v chatu na P, W i B; B dostane notifikaci "📊 otázka" | NOT_RUN |
| A2 | Tvůrce: prázdná otázka, 1 možnost, dvě stejné možnosti | Chybová hláška, nic se neodešle | NOT_RUN |
| A3 | B hlasuje, pak změní hlas, pak klepne na svou volbu znovu | Součty se živě mění na všech zařízeních; poslední klepnutí hlas stáhne | NOT_RUN |
| A4 | Anketa s více odpověďmi, P zvolí 2 možnosti na W | Na P i B se počítá jako hlas P (ne W), obě možnosti | NOT_RUN |
| A5 | "Zobrazit hlasy" | Kdo hlasoval pro kterou možnost (jména) | NOT_RUN |
| A6 | Anketa v G s botem (hermes_bridge) | Bot dostane text otázky s možnostmi (fallback), hlasy a připnutí ignoruje | NOT_RUN |
| A7 | S (stará verze) dostane anketu | Zobrazí text "📊 otázka / • možnosti / (Pro hlasování v anketě aktualizujte Jay.)"; hlasy nezobrazí nic | NOT_RUN |
| A8 | Smazat anketu pro všechny | Na všech zařízeních náhrobek, hlasy zmizí | NOT_RUN |
| A9 | Záloha a obnova na čistou instalaci | Ankety, hlasy i připnutí se obnoví | NOT_RUN |
| A10 | F (firemní skupina) | Položka Anketa ve sponce chybí | NOT_RUN |
