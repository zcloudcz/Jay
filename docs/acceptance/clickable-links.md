# Klikatelné odkazy ve zprávách - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-10-clickable-links.md`. Větev `feat/clickable-links`.

Zařízení: P = telefon (Android nebo iOS), W = web v prohlížeči, D = desktop (Windows/macOS/Linux), A = druhý člověk, který posílá zprávy.

## Automatické ověření

| Co | Stav |
| --- | --- |
| App: `flutter analyze` + `flutter test` (vč. `links_test`, `link_text_test`, `channel_screens_test`) + `flutter build web --release` | viz report větve |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| L1 | A pošle "viz https://www.seznam.cz." , na P ťuknout na odkaz | Odkaz je podtržený, otevře se systémový prohlížeč na seznam.cz (tečka za odkazem není jeho součástí) | NOT_RUN |
| L2 | Totéž na W | Odkaz se otevře v nové záložce, Jay zůstane otevřený | NOT_RUN |
| L3 | Na D a W najet myší na odkaz | Kurzor ruky; mimo odkaz normální kurzor | NOT_RUN |
| L4 | Na P dlouze podržet odkaz > "Kopírovat odkaz", vložit jinam | Panel ukazuje celou adresu; ve schránce je přesně adresa; hláška "Odkaz zkopírován" | NOT_RUN |
| L5 | Na P dlouze podržet text zprávy mimo odkaz | Otevře se obvyklé menu zprávy (reakce, odpovědět, ...) | NOT_RUN |
| L6 | Na D/W pravé tlačítko na odkazu | Panel odkazu (na webu se může ukázat i menu prohlížeče, viz spec Limits); tři tečky u zprávy fungují dál | NOT_RUN |
| L7 | A pošle "pište na martin@zcloud.cz", ťuknout | Otevře se poštovní aplikace s adresátem | NOT_RUN |
| L8 | Vlastní zpráva s odkazem, světlý i tmavý motiv | Odkaz čitelný v mé i cizí bublině | NOT_RUN |
| L9 | Bot pošle zprávu s odkazem; upravená zpráva s odkazem | Stejné chování jako u člověka | NOT_RUN |
| L10 | Odkaz v příspěvku kanálu | Ťuknutí otevře odkaz, dlouhý stisk dál vybírá text | NOT_RUN |
