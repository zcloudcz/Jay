# Q01-02 — nelze najít, kam vložit kód kontaktu

- **Datum:** 2026-09-17 (UTC) · **Commit:** `9816709` · **Platforma:** web, `https://calltype.zcloud.cz` · **Ověřovatel:** Martin (nález), Claude (reprodukce)
- **Kroky:** čistá instalace → onboarding → *Start Messaging* → seznam konverzací „No conversations yet. Add a contact to start.“
- **Očekávání:** zřejmá akce pro přidání kontaktu kódem/handlem.
- **Realita:** FAIL (použitelnost, blokuje všechny chatové scénáře). Vstup pro handle existoval, ale až po: neoznačený FAB s ikonou bubliny → obrazovka Contacts → malá ikona „osoba+“ v app baru. Na hlavní obrazovce je přitom podobná ikona „osoba+“ = *New group*, která uživatele svede jinam. Tester kód neměl kam vložit.
- **Závažnost:** vysoká pro betu (nefunkční základní tok z pohledu uživatele), žádná ztráta dat.
- **Oprava:** commit `c7048e9` — prázdný stav seznamu konverzací má tlačítko *Add contact*; FAB je popsaný *New chat*; obrazovka Contacts má v prázdném stavu tlačítka *Enter handle or invite* a *Scan QR code* a trvalý FAB *Add contact*.
- **Nasazeno:** 2026-09-17, run 35193671677 (commit `6f4802a`). Na `https://calltype.zcloud.cz` je v prázdném stavu vidět tlačítko *Add contact* a FAB *New chat* (ověřil Claude, screenshot v relaci).
- **Retest celého scénáře (dvě identity, zpráva oběma směry):** NOT_RUN — čeká na testera.
