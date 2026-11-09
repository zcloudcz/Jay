# Barvy účastníků ve skupinových chatech - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-09-participant-colors.md`. Větev `feat/participant-colors`.

Zařízení: P = telefon (primární), W = web propojený s P, A, B, C = další lidé (C má dvě zařízení), skupiny G1 (P, A, B, C) a G2 (P, A, C).

## Automatické ověření

| Co | Stav |
| --- | --- |
| App: `flutter analyze` + `flutter test` (vč. `participant_colors_test`, `participant_colors_widgets_test`, `backup_participant_colors_test`) | viz report větve |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| C1 | G1, světlý motiv, A, B i C napíšou zprávu | Jméno nad bublinou každého je v jeho barvě (tučnější), bublina má tenký obrys stejné barvy; moje bubliny beze změny; text dobře čitelný | NOT_RUN |
| C2 | Totéž v tmavém motivu | Světlejší odstíny, stále čitelné jméno i obrys | NOT_RUN |
| C3 | 1:1 chat s A | Žádný obrys ani barevné jméno, vše jako dřív | NOT_RUN |
| C4 | Ťuknout na jméno A nad bublinou | Panel "Barva pro A", 10 koleček, aktuální volba se značkou, "Automaticky"; výběr se hned projeví ve všech bublinách A | NOT_RUN |
| C5 | Dlouhý stisk (web: tři tečky) na zprávě B > "Barva účastníka" | Stejný panel; u vlastní zprávy položka není | NOT_RUN |
| C6 | Kontakty > menu u A > "Barva" | Stejný panel; zvolená barva platí v G1 i G2 | NOT_RUN |
| C7 | "Automaticky" u A | A má zase výchozí barvu (stejnou jako před volbou) | NOT_RUN |
| C8 | A v G1 a G2 bez ruční volby | Stejná barva v obou skupinách, i po restartu aplikace | NOT_RUN |
| C9 | C píše z obou svých zařízení | Jedna barva pro obě zařízení | NOT_RUN |
| C10 | Odpověď B na zprávu A (citace) | Proužek a jméno v citaci mají barvu A; citace mé zprávy zůstává v barvě aplikace | NOT_RUN |
| C11 | Zvolit barvy, záloha, obnova na čistém zařízení | Zvolené barvy jsou zpět | NOT_RUN |
| C12 | Propojit nový W s přenosem historie | W má barvy zvolené na P (pozdější změny se nesynchronizují, viz spec Limits) | NOT_RUN |
| C13 | Čtečka obrazovky (TalkBack / VoiceOver) v panelu barev | Kolečka se čtou jménem barvy, aktuální jako vybrané; panel jde ovládat i klávesnicí (web, Windows) | NOT_RUN |
