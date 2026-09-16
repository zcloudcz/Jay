# CallType — společné kontrakty pro dokončení bety

Platí společně s [hlavním zadáním](2026-09-16-beta-zadani.md). „Zachovat“ označuje existující chování; „nový požadavek“ označuje navrženou změnu. Implementace není součástí tohoto dokumentu.

## K01 — doručování a identita (zachovat)

Server odvozuje odesílatele/příjemce potvrzení z JWT; parametr `deviceId` v URL nesmí změnit identitu. Pro nové odesílání klient používá reliable metody:

```csharp
Task SendReliableMessage(Guid recipientDeviceId, Guid messageId, string encryptedBodyBase64);
Task SendReliableGroupMessage(Guid groupId, Guid messageId, Dictionary<Guid, string> encryptedPayloads);
Task AcknowledgeMessage(Guid senderId, Guid messageId);
Task RequestPendingMessages();
```

Událost `ReceiveMessage` nese `senderId`, `messageId`, `encryptedBody` (Base64), `createdAt` (UTC), `groupId` (UUID nebo null). Klíč doručení je trojice příjemce + odesílatel + messageId. Opakování stejného klíče nesmí vytvořit druhou zprávu ani změnit její obsah/routing. Skupinová mapa obsahuje samostatný ciphertext pro každého příjemce. Stejné messageId u jiného příjemce je legitimní.

Pořadí: klient vytvoří UUID a ciphertext → uloží outbox → server uloží ciphertext → příjemce ověří/dešifruje a atomicky uloží zprávu i odpovídající ratchet stav → teprve poté ACK → server odstraní ciphertext, ale ponechá deduplikační záznam do původní 30denní expirace. Retry používá stejné UUID a stejné ciphertext bajty. ACK není potvrzení přečtení člověkem.

Chybně dešifrovanou nebo neuloženou zprávu nepotvrdit. Opakování již uložené zprávy lze znovu potvrdit bez dalšího posunu ratchetu. Replay musí fungovat i při ztraceném prvním ACK. Opravy formátu řešit oběma stranami a verzí, nikdy tichým fallbackem na nešifrovaný obsah.

## K02 — šifrování, přílohy a hovory (zachovat)

- Zprávy používají envelope v2 a podepsané identity/prekeys; zachovat stávající serializaci z `session_manager.dart` a testových fixtures.
- Příloha: nejvýše 262144 bajtů původního souboru, validace před načtením/kódováním i při příjmu. Přesná hranice projde, hranice + 1 selže. Limit hubu 1 MiB nelze zaměňovat s velikostí jednoho souboru; skupinový fan-out může narazit na limit celé invokace dříve.
- Hovor: JSON `{ "v": 1, "callId": "UUID", "payload": ... }`; vnější signalType a typ vnitřního payload zachovat podle `webrtc_manager.dart`. Zpráva jiného callId nesmí změnit současný hovor. Nepřijímat starý raw SDP.
- Soukromé klíče zůstávají na klientovi. Logy testů obsahují pouze syntetická data.

## K03 — zálohy (zachovat API, doplnit omezení)

Existující endpointy:

```text
POST /backups/{accountId}                 multipart pole file
GET  /backups/{accountId}                 seznam od nejnovějšího
GET  /backups/{accountId}/{backupId}      application/octet-stream
```

Autorizace je vazba JWT zařízení na účet. Neautentizovaný požadavek vrací 401; cizí účet 403; neexistující záloha vlastního účtu 404. Zachovat `CreateBackupResponse(long Id, string BlobPath)` a `BackupDto(long Id, string BlobPath, long SizeBytes, DateTimeOffset CreatedAt)`.

**Nový požadavek D02:** níže jsou konzervativní vývojové výchozí hodnoty, nikoli odhad kapacity nebo již schválená produkční politika. I04 před nasazením ověří, že odpovídají rozpočtu a stávajícím datům.

| Konfigurační klíč | Výchozí hodnota | Význam |
| --- | --- | --- |
| BackupLimits:MaxFileBytes | 8388608 | 8 MiB šifrovaného souboru, multipart režie navíc |
| BackupLimits:MaxPerAccount | 3 | Nejvýše 3 dokončené či rezervované zálohy účtu |
| BackupLimits:MaxTotalBytes | 268435456 | 256 MiB součet rezervovaných a uložených souborů celé instalace |

Transportní limit HTTP těla zůstává 10 MiB. Prázdný soubor → 400, soubor nad limitem → 413. Při dosažení počtu nebo globálních bajtů → 409 s `{ "error": "Backup quota exceeded.", "code": "backup_quota_exceeded" }`. Nový úspěšný upload nadále 201. UI rozliší 413, 409, 401/403 a dočasnou chybu sítě, zobrazí srozumitelný text a nechá lokální historii beze změny.

Kvóty musí počítat také současně probíhající uploady a být odolné vůči restartu; samotné `CountAsync` před uploadem nestačí. D02 navrhne rezervaci v PostgreSQL pod transakcí/DB zámkem a B00 začlení migraci. Upload do Blob neběží s dlouho drženým DB zámkem. Návrh musí mít expiraci rezervace, heartbeat nebo jiný důkaz, že cleanup nesmaže aktivní upload, a idempotentní úklid při pádu. Pokud to nedokáže, balíček není hotov.

**Nový endpoint:** `DELETE /backups/{accountId}/{backupId}` pro ruční uvolnění místa. U vlastního účtu vrací 204 i při opakování již odstraněného ID; při pokusu o existující ID jiného účtu vrací 404 bez smazání; cizí accountId vrací 403. Nejprve označit k odstranění, následně odstranit Blob a metadata; kvótu uvolnit až po potvrzeném odstranění Blob. Retry po výpadku musí dokončit stejnou operaci. Nepoužívat automatické mazání nejnovější úspěšné zálohy kvůli novému neúspěšnému uploadu.

Záloha obnovuje historii, nikoli identitu zařízení ani aktivní ratchet session. Chybné heslo nebo poškozený obsah nesmí částečně přepsat lokální data. Dosavadní PBKDF2-HMAC-SHA256/600000 + AES-GCM neměnit v tomto kole.

## K04 — push zpráv (nové dokončení nad existujícím FCM)

D03 zachová registraci platformy `fcm` také pro Apple přes Firebase. Přímou serverovou větev `apns` v tomto kole nerozšiřuje. Provider dostane jen obecné upozornění na novou zprávu; plaintext zprávy, kontakt ani skupinový název se neposílají. Otevření notifikace vede do seznamu konverzací a spustí stávající reconnect/replay, nikoli nový endpoint pro plaintext.

Push je best-effort pobídka, fronta je zdroj doručení. Selhání provideru nesmí zrušit uloženou zprávu. FCM 404 samo o sobě neprokazuje neplatný token: mazat jen při odpovídajícím kódu `UNREGISTERED` a pouze token, který byl použit v daném requestu. Nově otočený token se nesmí smazat odpovědí na starý request.

Na podporovaných platformách odlišit stav „nepovoleno“, „provider nenastaven“ a „registrováno“. Nelogovat token. Windows nadále bez FCM. Android/iOS/web/macOS se ověřují samostatně; nepředstírat podporu platformy pouhým úspěchem `Firebase.initializeApp`.

## K05 — konfigurace, health a provoz (nové doplnění)

Zachovat stávající názvy `ConnectionStrings__DefaultConnection`, `ConnectionStrings__BlobStorage`, `Jwt__Secret`, `Database__ApplyMigrationsOnStartup`, `Cors__AllowedOrigins__0`, `Turn__Urls__0`, `Turn__StunUrls__0`, `Turn__SharedSecret`, `Push__FcmServiceAccountJson`. Nové backup klíče používají v prostředí stejný převod dvojtečky na `__`.

Produkční konfigurace musí mít explicitní CORS origin, nesmí připustit známá lokální hesla/secrets a musí mít platnou délku JWT secretu nejméně 32 znaků. Výpis validační chyby uvádí jméno klíče, nikdy jeho hodnotu. Firebase může být vypnuté; chybějící Firebase nesmí zabránit spuštění chatu.

Zachovat anonymní `GET /health` = 200 pro živý proces. Nový `GET /health/ready`: 200 pouze pokud je dostupné PostgreSQL a privátní backup úložiště; 503 při nedostupnosti; pevný celkový timeout nejvýše 5 sekund. Odpověď pouze `{ "status": "ready" }` nebo `{ "status": "not_ready" }`, žádné adresy ani výjimky. Readiness se měří málo často a její Blob operace se započítají do nákladů. Na jednu instanci neaplikovat automatické restartování při každém jednotlivém výpadku úložiště.

Proxy trust konfigurovat podle doložené skutečné topologie. Nepřijímat libovolné X-Forwarded-For z internetu, nezrušit KnownProxies/KnownNetworks bez náhrady. Podvržená hlavička nesmí obejít limit autentizace. Pokud nelze stabilní proxy důvěru dokázat, reportovat blokaci, nevolit `AllowAll`.

## K06 — důkaz a status

Povolené statusy: PASS (provedeno a prošlo), FAIL (provedeno a selhalo), BLOCKED (nelze provést, uveden důvod), NOT_RUN (zatím neprovedeno), UNSUPPORTED (záměrně nepodporovaná funkce, explicitně uvedena). Pouhá implementace nebo úspěšný build neopravňuje napsat PASS pro uživatelský scénář.

Důkaz obsahuje commit, UTC datum, platformu/verzi, postup, očekávaný i skutečný výsledek, redigovaný log/screenshot a jméno ověřovatele. Při produkčním testu použít oddělené testovací identity; nesahat do dat jiných uživatelů.
