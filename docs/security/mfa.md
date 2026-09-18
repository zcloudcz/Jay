# MFA (TOTP) — N03

Povinné dvoufaktorové ověření (TOTP, RFC 6238) pro role `Owner`, `OrgAdmin` a
`AuditorApprover` v každé organizaci Business režimu (NIS2, N03). Žádná
politika na úrovni organizace ji nevypíná a žádné přechodné období neplatí —
bez potvrzeného MFA odpoví každá administrátorská akce 403 `mfa_required`
(vynucení v N03b).

## Jak to funguje

1. **Založení** (`POST /accounts/{id}/mfa/enroll/start`) — server vygeneruje
   náhodný TOTP secret, zašifruje ho a vrátí ho jednou uživateli jako
   `secretBase32` + `otpauthUri` (naskenování QR kódem v autentikátoru).
   Opakované volání před potvrzením starý (nepotvrzený) secret nahradí.
2. **Potvrzení** (`POST /accounts/{id}/mfa/enroll/confirm`) — uživatel zadá
   šestimístný kód z autentikátoru; server ho ověří a vrátí **10 záložních
   kódů** (zobrazí se jen jednou, uložen je jen jejich hash).
3. **Ověření** (`POST /accounts/{id}/mfa/verify`) — kód (TOTP nebo záložní)
   vymění za krátkodobý "step-up" token (`Mfa:StepUpMinutes`, výchozí 15 min).
   Klient tento token posílá jako Bearer token na administrátorské endpointy.
4. **Odhlášení/zablokování** — 5 chybných pokusů po sobě zamkne účet na
   15 minut (429 `mfa_locked`); úspěšný pokus počítadlo vynuluje. Jeden
   časový krok TOTP lze použít jen jednou (ochrana proti replay).

## Co šifrování secretu chrání — a co ne

TOTP secret je v databázi uložen zašifrovaný (AES-256-GCM, klíč
`Mfa:EncryptionKey`, mimo databázi, v konfiguraci aplikace).

- **Chrání**: únik/zálohu samotné databáze — bez klíče je secret nepoužitelný.
- **NECHRÁNÍ**: kompromitovaný běžící API proces — ten má klíč v paměti, aby
  mohl MFA endpointy obsluhovat. Toto je vědomý kompromis (stejný jako u
  JWT signing key), ne mezera, na kterou se zapomnělo.

Bez nastaveného/platného `Mfa:EncryptionKey` MFA endpointy odpovídají 503
`mfa_not_configured` a administrátorské akce zůstávají **uzamčené** (403
`mfa_required`) — nikdy se tiše neodemknou jen proto, že klíč chybí.

## Nastavení, které musí být na betě před nasazením

`Mfa__EncryptionKey` — vygenerovat `openssl rand -base64 32` a nastavit v
konfiguraci App Service **předtím**, než se toto nasazení pustí do
produkčního provozu. Bez něj `ProductionConfigurationValidator` odmítne start
procesu, pokud je zároveň zapnutý Business režim (`ConnectionStrings:Audit`
nastaven) — jinak by administrace organizací zůstala trvale uzamčená.

## Ruční obnova — vlastník ztratil přístup k autentikátoru

Scénář: jediný `Owner` organizace ztratil telefon/autentikátor a nemá žádný
záložní kód. Automatický self-service reset v v1 neexistuje (bezpečnostně
záměrně — jinak by MFA obcházel sám sebe).

Postup:

1. **Ověření identity mimo pásmo** — telefonicky/e-mailem na již známý
   kontakt, nikdy jen na základě zprávy v aplikaci.
2. Operátor (`docs/security/incident-response.md`, kontakt Martin Zahálka)
   smaže řádek `AccountMfa` daného účtu přímo v databázi (cascade smaže i
   záložní kódy) — účet tím ztrácí MFA a administrátorské akce jsou znovu
   403 `mfa_required`, dokud se znovu nezaregistruje.
3. Uživatel se znovu zaregistruje (`enroll/start` → `enroll/confirm`).
4. Zápis do `docs/security/incidents/` — kdo, kdy, jak byla identita ověřena,
   který účet/organizace.

Náhradní osoba pro tento postup není určena — zapsáno jako známé riziko
(stejně jako u kontaktu pro `security.txt`).

## Jak si to admin zapne v aplikaci

Na obrazovce organizace (jen pro Owner/OrgAdmin/AuditorApprover) je sekce
„Dvoufázové ověření". Zapnutí: heslová fráze účtu → naskenování QR kódu
(nebo ruční zadání zobrazeného secretu) v autentikátoru → potvrzení 6místným
kódem → 10 záložních kódů zobrazených **jen jednou** (je nutné je hned
uložit — aplikace je znovu nezobrazí). Odtud jde ověření kdykoli vypnout
(vyžaduje platný kód) nebo vygenerovat nové záložní kódy (vyžaduje čerstvé
ověření).

Jakmile má admin MFA zapnuté, každá administrátorská akce (nastavení
auditora, pozvánky, role členů, export auditu, nouzové sady/cvičení) si při
potřebě čerstvého ověření sama vyžádá dialog s 6místným kódem (nebo
záložním kódem). Pokud MFA ještě zapnuté není, dialog to nejdřív vysvětlí a
provede enrollmentem, než akci zopakuje.

**Co uživatel vidí, když je uzamčeno:** pokud dialog zavře/zruší, obrazovka
místo syrové chyby zobrazí klidný uzamčený stav s tlačítkem „Odemknout" —
nikdy smyčku dialogů. Běžný člen organizace (bez administrátorské role)
žádný z těchto dialogů nikdy nevidí.
