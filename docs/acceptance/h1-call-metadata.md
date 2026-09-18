# H1 — audit metadat hovorů (hub gate + archivátor), 2026-09-18

(Dodatek k `business-mode.md` — samostatný soubor, aby append do CRLF dokumentu
neriskoval poškození kódování; odkázáno z něj.)

Server: firemní hovor jde přes NOVOU hub metodu `BusinessCallSignal` (4 argumenty,
`businessGroupId` navíc) — `CallSignal` (3 argumenty) zůstává beze změny pro
anonymní hovory. Nepovinný 4. parametr na `CallSignal` byl první pokus a
neprošel: SignalR chybějící koncový argument NEdoplní výchozí hodnotou, takže
by shodil každého stávajícího 3-argumentového klienta (odhaleno hned regresním
testem `Anonymous_call_signal_still_works_with_exactly_three_arguments`).
`SignalRClient.sendCallSignal` volí metodu podle toho, zda je `businessGroupId`
zadán. Firemní
hovor: obě zařízení musí být členy skupiny (jinak `not_a_business_member`), u
`offer` navíc musí být auditor „živý" (`AuditorLivenessService`,
`Business:AuditorMaxBacklogAgeSeconds`, default 24 h) jinak
`auditor_unavailable` — nouzový kanál (`IsEmergencyChannel`) výjimka.
`answer`/`ice`/`hangup` liveness nekontrolují.

Hovor se archivuje jako běžná E2E zpráva `type: "call-event"` odeslaná do
konverzace po skončení hovoru (fan-out všem členům vč. auditora). Archivátor
(`group_message_source.dart`) ji striktně validuje a archivuje jako
`kind: "call-metadata"`.

**Rozhodnutí zadavatele 2026-09-18 (dodatečné):** metadata hovoru MUSÍ být
čitelná, ne jen hash — `AuditRecord.DetailsJson` (nullable, jedna migrace
`AuditRecordDetails`, žádná změna práv rolí — nový sloupec na existující
tabulce). `POST /orgs/{id}/audit/records` přijímá `details` jen pro
`kind == "call-metadata"` (jinak 422 `details_not_allowed`), vyžaduje ho a
validuje stejně striktně jako archivátor (422 `invalid_call_details`), a
ověřuje `ContentHash == SHA-256(details)` (422 `details_hash_mismatch`) —
čistý text je tak svázán do existujícího hash řetězu, aniž se změnil způsob
počítání `Hash`.

**Co auditor/pojišťovna z archivu na úrovni „metadata" MŮŽE vyčíst pro
hovor:** kdo hovor nahlásil (`SenderDeviceId`), s kým (`peerDeviceId` v
`details`), kdy začal/skončil dle KAŽDÉHO klienta zvlášť
(`startedAt`/`endedAt` — dva nezávislé reporty, caller i callee, server je
nemůže ověřit), audio/video, výsledek (`outcome`), a kdy byl záznam zapsán
(`ArchivedAt`). **Co NEMŮŽE:** obsah hovoru, IP adresy, ICE kandidáty ani
SDP — nic z toho se nikdy neukládá; trvání je tvrzení klienta, ne serverem
ověřený fakt.

**Ruční krok před nasazením na betu:** migrace `AuditRecordDetails` se pouští
ručně jako ops role, viz `docs/HANDOFF-2026-09-18.md` — nasazení tohoto buildu
BEZ toho kroku shodí každý zápis do archivu (chybějící sloupec).

Testy: `MessengerHubTests` (business call relay+businessGroupId, non-member,
non-business group, stale backlog → `auditor_unavailable`, emergency exempt,
answer/ice/hangup not gated, 3-arg regrese) a `AuditArchiveEndpointsTests`
(happy path, `details_not_allowed`, `invalid_call_details` ×2,
`details_hash_mismatch`) — Docker/Testcontainers. `jay_archiver` unit testy
(7 nových case pro `call-event`) a `calltype_core` wire-contract testy
(3/4-argument `sendCallSignal`) PASS bez Dockeru. Živé E2E rozšířeno o
offer+`businessGroupId` a `call-event` fan-out — NENÍ spuštěno (port 8080
sdílený s jinou session editující stejné E2E soubory pro MFA).

## H2 — aplikace (Flutter), 2026-09-18

Klientská strana H1: `WebRTCManager` (`lib/core/network/webrtc_manager.dart`)
protahuje `businessGroupId` každým signálem hovoru (offer/answer/ice/hangup)
přes `_sendSignal`; u příchozí nabídky ho čte z relayované obálky
(`data['businessGroupId']`, nikoli ze zašifrovaného SDP payloadu). Po skončení
firemního hovoru emituje jeden `CallReport` na streamu `callReports` — výsledek
(`outcome`) je odvozen ze stavového automatu (spojeno alespoň jednou →
`completed`; timeout 45 s bez odpovědi → `missed`; zavěšeno před spojením bez
chyby → `rejected`; server ohlásil cíl offline → `unavailable`; ICE selhalo /
start selhal → `failed`). Odmítnutí nabídky hubem (`auditor_unavailable` /
`not_a_business_member`) je vlastní `CallError`, hovor se nikdy nekonal, takže
se neemituje žádný report.

Odeslání: nová app-wide služba `CallEventSender`
(`lib/features/calls/call_event_sender.dart`, spouští se v `main.dart` stejně
jako `MessageInboxService` — dřív než se SignalR připojí) poslouchá
`callReports` a posílá zprávu `type: "call-event"` s tělem přesně těch 6 klíčů,
co validuje archivátor. Používá stejnou cestu šifrování+outbox a stejnou
`MessageProcessingQueue` jako běžná zpráva — žádná druhá kryptografická cesta.
Příchozí `call-event` `MessageInboxService` nyní přijímá (dřív by ho zahodil
jako "Unsupported message type") a nepočítá do nepřečtených. `ChatScreen` ho
vykresluje jako kompaktní lokalizovaný systémový řádek, ne jako bublinu.

UI: obrazovka hovoru zobrazuje trvalé upozornění "je logován, ne nahráván" pro
OBĚ strany firemního hovoru, včetně příchozí nabídky ještě před přijetím
(`manager.businessGroupId != null`). Tlačítka hovoru v `ChatScreen` se u
firemní skupiny zobrazí jen když má skupina přesně jednoho dalšího člena mimo
auditora (`ChatController.businessCallTarget`) — víc členů znamená žádné
tlačítko (skupinové hovory neexistují).

Testy: `webrtc_manager_test.dart` (+11 nových — businessGroupId na každém
signálu, všech 5 outcomes, žádný report pro anonymní hovor, žádný report a
vlastní `CallError` pro obě odmítnutí hubu), `call_event_sender_test.dart`
(přesná sada 6 klíčů dešifrovaná na straně příjemce, neúspěšné odeslání
zůstává ve frontě jako `failed` místo aby zmizelo, příchozí `call-event`
nespadne a nezvedne unread), `call_screen_test.dart` (upozornění vidí obě
strany včetně nepřijaté příchozí nabídky, u anonymního hovoru chybí),
`test/l10n` (parita a ICU plurály pro `callEventMinutes` ve všech 19 ARB) —
vše PASS bez Dockeru. Tlačítka hovoru v `ChatScreen` (viditelnost podle počtu
členů skupiny) NEMAJÍ dedikovaný widget test — pokryto jen nepřímo přes
`ChatController.businessCallTarget`, který widget test nevolá.

**NENÍ spuštěno:** skutečný dvou-zařízení hovor v tomto prostředí nebyl možný
(žádný druhý fyzický/emulovaný klient, žádný běžící server) — vše výše je
ověřeno testovacími dvojníky (`TestSignal`/`TestApi`), ne živým hubem ani
živým archivátorem.
