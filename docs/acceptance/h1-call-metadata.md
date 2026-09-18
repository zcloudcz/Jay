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
