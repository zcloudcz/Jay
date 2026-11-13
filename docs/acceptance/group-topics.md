# Témata skupin, admini a boti, kteří čtou s námi - přejímka

Statusy: PASS / FAIL / BLOCKED / NOT_RUN. PASS jen pro skutečně provedený scénář.
Spec: `docs/superpowers/specs/2026-11-13-group-topics.md`. Větev `feat/group-topics`
(merge `feat/group-topics-server`, `feat/group-topics-app`, `feat/group-topics-bots`).
Migrace `AddGroupTopicsAndBotReading` (aditivní, před nasazením záloha DB).

Zařízení: P = telefon (primární, admin), W = web propojený s P, A, B = další lidé, S = starší
verze aplikace, LB = bot `llm_bridge`, HB = bot `hermes_bridge`, AB = `a2a_bridge` (vlastníkem
všech botů je P). Skupina G (P, A, B, LB, HB).

## Automatické ověření

| Co | Stav |
| --- | --- |
| Protocol, core, app (analyze, gen-l10n, test, web build), server (celá sada), boti (analyze + test), docker image bridge botů | viz report větve (`verify.sh`) |

## Ruční scénáře

| # | Scénář | Očekávání | Stav |
| --- | --- | --- | --- |
| G1 | P založí G s vyplněným tématem | Všichni členové (i W) vidí téma řádkem pod názvem skupiny; žádná nová nepřečtená zpráva ani notifikace | NOT_RUN |
| G2 | Ťuknout na řádek tématu | Otevře se Info o skupině: název, celé téma (jde označit), členové s rolemi | NOT_RUN |
| G3 | P upraví téma v Info o skupině | Změna dorazí všem; prázdné téma = téma zmizí | NOT_RUN |
| G4 | A (není admin) | Nevidí "Upravit téma" ani menu rolí | NOT_RUN |
| G5 | P udělá z A admina, A změní téma | A to smí, všichni vidí nové téma; seznam rolí se obnoví všem | NOT_RUN |
| G6 | P se pokusí odebrat admina sám sobě, když je jediný | Volba není nabídnuta; přes API 409 `last_admin` | NOT_RUN |
| G7 | U bota v seznamu členů | Menu "Udělat adminem" chybí (server 400 `bot_cannot_be_admin`) | NOT_RUN |
| G8 | Obchodní (firemní) skupina | Téma nejde nastavit (UI skryté, server 409 `business_group`) | NOT_RUN |
| G9 | Nastavení botů ve skupině: "Boti čtou vše" a "Odpovídat bez zmínky" | Výchozí vypnuto, mění jen admin; po změně to boti poznají bez restartu | NOT_RUN |
| G10 | LB ve skupině s tématem, P napíše @LB otázku | Odpověď respektuje téma (je v system promptu) | NOT_RUN |
| G11 | HB: první oslovení po nastavení tématu a po jeho změně | Hermes dostane blok `[Group topic: ...]` jen poprvé a po změně | NOT_RUN |
| G12 | "Boti čtou vše" zapnuto, A a B si píšou bez zmínky, pak P osloví HB | HB nic neodpovídá na neoslovené zprávy, ale v odpovědi na P zná jejich obsah (`[Meanwhile in the group: ...]`) | NOT_RUN |
| G13 | "Odpovídat bez zmínky" zapnuto, ve skupině P + LB | LB odpovídá na každou zprávu P bez @; dva boti ve skupině si navzájem bez zmínky neodpovídají | NOT_RUN |
| G14 | LB: dlouhý rozhovor (přes 20 zpráv) | Bot si pamatuje starší obsah (souhrn), `/new` paměť smaže | NOT_RUN |
| G15 | Menu skupiny > "Nové téma s těmito členy" | Formulář má předvybrané všechny členy G (i boty, bez sebe), po založení mají všichni novou skupinu s tématem | NOT_RUN |
| G16 | AB ve skupině s tématem | A2A agent dostane téma jako první textovou část a v metadatech `jayGroupTopic` | NOT_RUN |
| G17 | Záloha a obnova na čistém zařízení, propojení nového W s přenosem historie | Témata skupin jsou zpět | NOT_RUN |
| G18 | S (starší aplikace) ve skupině s tématem | Aplikace funguje dál, téma nevidí; změna režimu konverzace botů ze S nevypne "Boti čtou vše" | NOT_RUN |
| G19 | Nová aplikace proti starému serveru (před nasazením) | Nastavení tématu ukáže "server to zatím nepodporuje", nic se neodešle | NOT_RUN |
