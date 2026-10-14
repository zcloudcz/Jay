# Práva subjektu údajů (GDPR) — N09

Tři endpointy, žádné UI (klient zatím nemá tlačítko — jen server):

- `DELETE /devices/{deviceId}` — zapomenutí zařízení.
- `DELETE /accounts/{accountId}` — zapomenutí účtu (nevratné).
- `GET /accounts/{accountId}/export` — export všeho, co server o účtu drží.

## Co se maže

**Smazání zařízení** (jen samo zařízení, podle JWT):
- Jednorázové pre-klíče (`OneTimePreKeys`), vazba na účet (`AccountDevices`),
  členství ve skupinách (`GroupMembers`), sledování/reakce/hlasy/admin role u
  kanálů, push token — vše kaskádou z řádku `Devices`.
- Čekající zprávy OD i K tomuto zařízení (`QueuedMessages`) — bez FK, mažou se
  ručně, protože zpráva by jinak přežila i po smazání odesílatele.
- `Channel.FollowerCount` se o smazaná sledování sníží jedním hromadným
  UPDATE ve stejné transakci (viz komentář v `AppDbContext`), aby počítadlo
  po kaskádě `ChannelFollowers` nezůstalo vyšší, než je pravda.
- Seznamy zařízení (`DeviceLists`, `DeviceListMembers`) - kaskádou z řádku
  `Devices`: smazaný companion zmizí ze směrování, smazané primární zařízení
  odstraní celý seznam (zbylé companiony pak server směruje jako samostatná
  zařízení). Podepsaný payload, který si protějšky uložily lokálně
  (`known_device_lists`), je mimo dosah serveru a nelze jej smazat na dálku.
- Skupiny, které zařízení VYTVOŘILO (`Group.CreatedBy`), a kanály vlastněné
  přes JEHO účet zůstávají — vlastnictví kanálu je vázané na účet, ne na
  zařízení, a `CreatedBy` je jen informativní sloupec bez cizího klíče.

Zařízení, které je nastavené jako **auditor organizace** (Business režim),
nejde smazat — vrací se 409 `device_is_auditor`. Bez ruční záměny auditora
by smazání tiše rozbilo KB1 (viditelný tichý člen) ve všech firemních
skupinách organizace.

**Smazání účtu** (volající zařízení musí být na účet napojené A prokázat
znalost `authKey` v těle požadavku — stejná kontrola jako `LinkDevice`,
protože jde o nevratnou akci a samotný JWT dokazuje jen identitu zařízení):
- Řádek účtu, vazby na zařízení (`AccountDevices`) a zálohy (`Backups`) —
  kaskádou z `Accounts`. Samotná zařízení zůstávají a stávají se opět
  anonymními.
- Bloby záloh v Azure Blob Storage se mažou AŽ PO commitu DB transakce
  (viz komentář v kódu — selhání blob storage po commitu nesmí "oživit" účet,
  jen se zaloguje a blob zůstane k ručnímu úklidu).
- Kanály vlastněné účtem procházejí existujícím soft-delete (tombstone +
  hub událost `ChannelDeleted`) přes `ChannelService.DeleteChannelAsync` —
  žádná duplicitní logika.

Účet, který je **vlastníkem organizace** (Business režim), nejde smazat —
409 `account_owns_organization`. Převod vlastnictví organizace zatím
neexistuje, smazání vlastníka by organizaci osiřelo.

## Co se NEMAže a proč

Záznamy v auditní databázi (`calltype_audit`) — členství v organizaci
(`OrgMembers`), zápisy o zapojení zařízení (`OrgEnrollments`) — se nikdy
nemažou, ani při smazání zařízení, ani účtu. Auditní databáze je
"append-only" historie (KB3) ze zákonného důvodu (NIS2 dohledatelnost,
§316 ZP transparentnost vůči zaměstnancům). Guid identifikátor zařízení
nebo účtu sám o sobě není osobní údaj — je to náhodné číslo bez vazby na
jméno mimo systém. Smazáním e-mailu z `Accounts` a `Devices` z tabulky
`Devices` je osobní údaj (e-mail, klíčový materiál) odstraněn; historický
záznam "zařízení X bylo v čase T členem organizace Y" zůstává jako
legitimní firemní/bezpečnostní historie.

## Export (`GET /accounts/{accountId}/export`)

Vrací JSON se vším, co server o účtu drží:
- `account` — e-mail, `createdAt` (NIKDY hash klíče).
- `devices` — id, handle, časy, `isBot`, `hasPushToken` (bool, ne token).
- `backups` — metadata (cesta, velikost, stav, čas), ne obsah.
- `channelsOwned` / `channelsAdministered` / `channelsFollowed`.
- `channelReportsFiled` — hlášení, která podala zařízení tohoto účtu
  (jinak se identita nahlašovatele nikde nevrací — tady je to vlastní údaj
  subjektu).
- `deviceLists` - podepsané seznamy zařízení (multi-device), jejichž součástí
  je některé zařízení účtu, jako primární i jako companion: `primaryDeviceId`,
  `version`, `payload` (base64; ID a veřejné klíče zařízení), `updatedAt`.
  Podpis se nevrací.
- `queuedMessages.perDevice` — POUZE počet čekajících zpráv na zařízení,
  nikdy šifrovaný obsah (ten patří i druhé straně konverzace, která
  export nežádala).
- `organizations` — členství a zápisy o zapojení, pokud je Business režim
  zapnutý.

## Mimo rozsah

Šablona zpracovatelské smlouvy (DPA) — mimo rozsah tohoto balíčku.
