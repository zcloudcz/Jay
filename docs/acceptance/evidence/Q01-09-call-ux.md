# Q01-09 — nálezy z testu hovorů (web, iOS Safari)

- **Datum:** 2026-09-17 (UTC) · **Commit:** `e88620d` · **Platforma:** web `https://jay.zcloud.cz` v Safari na iPhonu · **Ověřovatel:** Martin
- **Výsledek scénáře:** hovor, video i offline zprávy funkční (viz `matrix.md` ⁸).

## Nález 1 — volání offline uživatele „zvoní do prázdna“

- **Realita:** volající nevidí, že protistrana není připojená; UI vyzvání až do 45s timeoutu „No answer“.
- **Příčina:** hub signál `offer` pro nepřipojené zařízení tiše zahodil (záměr z původního návrhu: timeout na klientovi).
- **Oprava:** hub na `offer` pro offline cíl odpoví volajícímu signálem `unavailable` (echo obálky kvůli `callId`); klient hovor ihned ukončí s hláškou „User is offline right now. Try again later.“ a uvolní média. Ostatní signály offline cíli se dál tiše zahazují. Formát call envelope (K02) beze změny; přibyl jen nový `signalType`, starší klient ho ignoruje.
- **Testy:** `CallSignal_offer_to_offline_target_tells_the_caller_immediately` (hub, Testcontainers — poběží v CI), `offline callee: server "unavailable" ends ringing at once…` (klient, PASS lokálně; cizí `callId` hovor neukončí).
- **Vědomě neřešeno:** trvalý indikátor online/offline u kontaktu (presence). Vyžadoval by nové API a zveřejňuje metadata o přítomnosti komukoli, kdo zná ID zařízení — samostatné rozhodnutí.
- **Závažnost:** střední (použitelnost). **Retest:** NOT_RUN — po nasazení.

## Nález 2 — chybí zřetelné ztlumení mikrofonu a zvuku

- **Realita:** ikona mikrofonu existovala, ale jako nenápadný `IconButton` bez popisku a bez barevného stavu; ztlumení příchozího zvuku neexistovalo.
- **Oprava:** tři popsané kulaté přepínače *Mic / Sound / Camera* (aktivní omezení = červený stav + text „… off“). *Sound* vypíná vzdálené audio stopy (funguje stejně na webu i nativně), platí i pro stopy, které dorazí až po ztlumení, a resetuje se po hovoru.
- **Testy:** `speaker toggle silences remote audio only, even for late tracks` (klient, PASS).
- **Závažnost:** nízká–střední. **Retest:** NOT_RUN — po nasazení.
