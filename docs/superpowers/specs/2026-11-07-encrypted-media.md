# Encrypted media: large files, voice messages, audio, video (design + contract)

Status: draft for Martin, prepared by Hermes Dev 2026-11-07. Owner decisions fixed: max file size 5 GB, server keeps
media 3 days after upload then deletes blob + metadata, end-to-end encryption (server never sees plaintext or keys),
NO automatic download ever, "Save to device" for every downloaded media message.
Branch `feat/encrypted-media` (from `origin/master` e401258). Server work in `feat/encrypted-media-server`, app work in
`feat/encrypted-media-app`. Every layer codes against this file.

## Why

Attachments today travel inline in the Signal-encrypted message (type `file`, JSON `{name, data}` base64, 256 KiB,
`lib/features/chat/attachment.dart`). That cannot carry a voice message of a few minutes, a video or a real file:
SignalR caps a hub message at 1 MiB and every byte sits in the store-and-forward queue for up to 30 days.
Large media needs its own encrypted transport with a short server lifetime.

## Decisions

| # | Decision | Why |
|---|---|---|
| M1 | Client encrypts each file with a fresh random 256-bit key in **4 MiB chunks, AES-256-GCM per chunk**, STREAM-style nonce `prefix(7) \|\| index(uint32 BE) \|\| final(1)`. Key, nonce prefix, size and plaintext SHA-256 travel only inside the Signal-encrypted chat message (`media` object, section 3). | E2E: the server stores ciphertext only. Per-chunk tags allow streaming from/to disk (never a whole 5 GB file in memory); the final flag and the exact expected length detect truncation, extension and reordering. |
| M2 | **Upload and download go through the API** (chunked proxy endpoints, section 2), not through Blob SAS URLs. The API stages each chunk as an Azure block (`StageBlock`) and commits the block list on `complete`. | Existing setup proxies every blob (backups, channel images); Azurite in docker-compose is reachable only as `azurite:10000`, so SAS URLs would not work locally; SAS for web needs CORS on the storage account (an Azure change, out of scope); a write SAS cannot enforce the declared size, the quota or the 5 GB cap, the API can (exact chunk lengths). Cost: the bytes cross the App Service (see Ops). SAS download offload is a later optimisation behind the same message format. |
| M3 | **Download authorization = capability**: any authenticated device that presents the media id may download it. The id is a server-generated random GUID v4 (122 random bits), only ever sent inside E2E messages. | The server does not know (and should not learn) which conversation a blob belongs to; a participant check would need the uploader to declare recipients (new metadata), would break multi-device own copies, groups whose membership changes and forwarding. The ciphertext is useless without the key from the message. JWT + rate limit stop anonymous scraping. |
| M4 | Upload is **resumable**: chunk index -> fixed block id; `GET /media/{id}/upload` lists received chunks from Azure's uncommitted block list; re-encrypting a chunk gives identical bytes (same key/nonce/index), so retrying a chunk is idempotent. | Large files on mobile networks; app restarts. |
| M5 | **Retention**: completed media expires `completedAt + 72 h`; an unfinished upload expires `createdAt + 24 h`. `MediaCleanupService` deletes blob + row every 10 min. Device deletion and account deletion delete the media of the device(s) immediately. | Owner decision: the server is a relay, media lives on the devices. |
| M6 | **Quota / abuse** per uploader device: active bytes (uploading + completed, not expired) <= 10 GiB, declared bytes created in a rolling 24 h <= 20 GiB, uploads created in 24 h <= 500; global active bytes <= 500 GiB; dedicated rate-limit policy `media` 600 req/min per device for chunk PUT and download GET. All configurable. | Anonymous devices are free, so the global cap bounds the storage bill; per-device caps keep one device from filling it. 600 x 4 MiB/min = 40 MiB/s, above a phone uplink. |
| M7 | **Wire compatibility**: a media message is sent as payload `type: "text"` with a fallback `body` and an extra `media` object. New clients store it locally as type `media`. | Old clients throw on unknown types (`message_inbox_service.dart`), the message then stays queued on the server for 30 days and is never shown. As `text` they show the fallback ("Voice message 0:12, update Jay to play it") and ignore the unknown key. |
| M8 | **No automatic download, ever**, and no setting for it. Received media shows a placeholder bubble (kind, name, size, inline thumbnail / duration / waveform from the message, "expires in X" / "expired") and a Download button. Only a tap downloads. Same for voice, image, video, audio, file. | Owner decision. |
| M9 | Downloaded (and sent) media is kept **decrypted in app-private storage** (`<applicationSupport>/media/<mediaId>/<name>`) and stays playable after the server copy expires. The sender copies the picked file there before upload. | Players (video_player, audioplayers) need a plain file; app sandbox + OS file protection. Encrypting local files at rest is out of scope (Limits). |
| M10 | **Save to device** on every downloaded media message: images and videos -> photo gallery (`gal`, mobile + macOS), everything else -> system save/share (iOS share sheet to Files, Android/desktop save dialog via `file_picker.saveFile`, web browser download). | Owner decision; reuses the `AttachmentMedia` seam. |
| M11 | **Backup**: the chat backup contains media message rows (including the `media` object with key and id) but **not the files**. A restored media message is downloadable while the server copy lives, else it shows "expired". | The existing backup cap is 8 MiB per file; 5 GB media cannot fit. Keys in the backup are as safe as message text in it (same passphrase encryption). |
| M12 | Inline path stays for compressed photos <= 256 KiB (existing photo flow and the `fix/chat-composer` preview screen). Voice messages, audio, video and any file > 256 KiB use the media path. `ChatController.sendMedia(...)` (section 4.1) is the entry point the preview screen can call later for large files. | Keeps the in-progress composer branch working; small photos stay instant. Open question for the owner whether all images should go through the media path (M8 strictness). |
| M13 | **Web cap 512 MiB** per file (send and download), enforced in the client. Web keeps downloaded media in memory for the session only (blob URLs), not persisted. | No `dart:io` files on web; a decrypted download must be assembled in browser memory before it can be played or saved. Mobile and desktop stream from/to disk, so the 5 GB cap applies there. |
| M14 | Plugins: `record` (voice, all platforms), `audioplayers` (playback with rate 1x/1.5x/2x, Android/iOS/macOS/web/Windows/Linux), `video_player` (Android/iOS/macOS/web; Windows/Linux: "Open with system app" fallback), existing `image_picker`/`file_picker`/`gal`/`share_plus`. Video is sent **original, not compressed** unless a maintained plugin fits (app branch decides, documents). Video thumbnail via a maintained plugin if one fits, else none. | Maintained, broad platform coverage; macOS minimum stays 11.0. iOS native code cannot be compiled on the Linux host: native changes are limited to Info.plist strings. |

## 1. Encryption (client only)

Constants: `chunkSize = 4 MiB = 4194304` plaintext bytes (decoders accept 1 MiB..8 MiB), `tag = 16`,
`aad = utf8("jay-media-v1")`.

- Fresh per file: `key` = 32 random bytes, `nonce` (prefix) = 7 random bytes (CSPRNG).
- `n = max(1, ceil(size / chunkSize))`. Plaintext chunk `i` = bytes `[i*chunkSize, min((i+1)*chunkSize, size))`.
  An empty file is one empty final chunk.
- `nonce_i = prefix(7) || uint32_be(i) || (i == n-1 ? 0x01 : 0x00)` (12 bytes).
- `C_i = AES-256-GCM-Encrypt(key, nonce_i, P_i, aad)` = ciphertext || 16-byte tag.
- Blob = `C_0 || C_1 || ... || C_{n-1}`. Encrypted size `size + 16*n`, encrypted chunk size `chunkSize + 16`.
- `sha256` = SHA-256 of the whole plaintext, computed while streaming.
- Decrypt: the receiver derives `n` and the exact encrypted size from `size`/`chunkSize` in the message and rejects a
  blob of any other length; decrypts chunk by chunk to a `.part` file; any tag failure aborts and deletes the partial
  file; after the last chunk the SHA-256 must match, then the `.part` file is renamed. Errors: `MediaTampered`
  (tag/length/flag) and `MediaHashMismatch`.
- Neither side ever holds more than a couple of chunks in memory (mobile/desktop). Upload resume re-encrypts the
  missing chunks from the local copy; download resume continues at `doneChunks * (chunkSize + 16)` with a Range
  request.
- Client plaintext cap: `5 GiB - 1 MiB` = 5367660544 bytes on mobile/desktop (the server cap is on encrypted
  bytes, the reserve covers the tags); 512 MiB on web.

## 2. Server contract

Container `media`, blob name `{mediaId}` (no uploader, no name: the server stores no metadata beyond size and times).
All routes `RequireAuthorization()`. Caller = device id from the JWT (`NameIdentifier`/`sub`).
Errors are JSON `{"error": "...", "code": "<code>"}` like the rest of the API.

### 2.1 Create
`POST /media` body `{"size": <long, encrypted bytes>, "chunkSize": <int, encrypted chunk bytes>}`, rate policy `api`.
- `chunkSize` must be in `[1 MiB + 16, 8 MiB + 16]`, `size >= 16` (one empty chunk), else 400 `invalid_media_size`.
- `size > Media:MaxFileBytes` -> 413 `media_too_large`.
- Per device: active bytes + size > `MaxActiveBytesPerDevice` -> 409 `media_quota_exceeded`; uploads created in the last
  24 h >= `MaxUploadsPerDay`, or their declared bytes + size > `MaxDailyBytesPerDevice` -> 429 `media_rate_limited`.
- Global active bytes + size > `MaxTotalBytes` -> 503 `media_storage_full`.
- Quota check and row insert are atomic per device (transaction with a row lock on the device, or serializable),
  so two concurrent creates cannot both pass the last slot.
- 201 `{"id": "<guid>", "chunkSize": <int>, "chunkCount": <int>, "uploadExpiresAt": "<ISO-8601 UTC>"}`.
  `chunkCount = ceil(size / chunkSize)`.

### 2.2 Upload a chunk
`PUT /media/{id}/chunks/{index}` body `application/octet-stream`, rate policy `media`.
- Only the uploader; another device or unknown id -> 404 `media_not_found` (no existence oracle).
- Status must be `Uploading`, else 409 `media_not_uploading`; past `uploadExpiresAt` -> 410 `media_expired`.
- `0 <= index < chunkCount`, body length exactly `chunkSize` (last chunk: `size - chunkSize*(chunkCount-1)`),
  else 400 `invalid_chunk`. Read the body as a stream with the exact length, never more than `chunkSize + 1` bytes.
- Stage as block id `base64(ascii(index.ToString("D6")))` (fixed width as Azure requires). Re-uploading an index
  replaces it. 204.

### 2.3 Upload state (resume)
`GET /media/{id}/upload`, uploader only (else 404), policy `api`.
200 `{"id", "status": "uploading"|"completed", "chunkCount", "received": [<index>...], "uploadExpiresAt", "expiresAt"?}`.
`received` = staged (uncommitted) blocks with the correct length; for `completed` all indexes.

### 2.4 Complete
`POST /media/{id}/complete`, uploader only (else 404), policy `api`.
- Every index present with the correct length, else 409 `media_incomplete` with `"missing": [<index>...]`.
- Commits the block list in index order, sets `Status = Completed`, `CompletedAt = now`, `ExpiresAt = now + RetentionHours`.
- 200 `{"id", "size", "expiresAt"}`. Idempotent: an already completed upload returns the same body.

### 2.5 Delete (cancel)
`DELETE /media/{id}`, uploader only (else 404), policy `api`. Deletes the blob (and its uncommitted blocks, see 2.7),
marks the row `Deleted` (row kept until `createdAt + 24 h` so the daily caps cannot be bypassed by deleting). 204,
idempotent for an already deleted row.

### 2.6 Download
`GET /media/{id}`, any authenticated device, policy `media`.
- Unknown id, `Uploading` or `Deleted` -> 404 `media_not_found`; `Completed` but past `ExpiresAt` (cleanup not run
  yet) -> 410 `media_expired`.
- 200 `application/octet-stream` with `Content-Length`, or 206 for a single `Range: bytes=a-` / `bytes=a-b`
  (resume). Streams from Blob (`DownloadStreamingAsync` with the range), never buffers. `Cache-Control: no-store`.
- CORS: expose `Content-Length`, `Content-Range`, `Accept-Ranges` to browsers (`WithExposedHeaders`).

### 2.7 Retention and deletion
- `MediaCleanupService` (hosted, every `CleanupIntervalMinutes`, uses the injected `TimeProvider`): rows with
  `ExpiresAt <= now` (completed past retention, uploads past `uploadExpiresAt`) -> delete blob, delete row.
  `Deleted` rows past `createdAt + 24 h` -> delete row. A blob with only uncommitted blocks is released by committing
  an empty block list, then deleting it (otherwise Azure keeps uncommitted blocks up to 7 days). Blob deletion is
  `DeleteIfExists`; a failure is logged and retried on the next run (the row stays until the blob is gone).
  A single run is callable from tests (`RunOnceAsync`).
- `DELETE /devices/{id}` (PrivacyEndpoints): delete the device's media rows and blobs.
- `DELETE /accounts/{id}`: delete media of every device linked to the account (collected before the links cascade);
  blob deletion post-commit, best effort + logged, same pattern as backups.
- `GET /accounts/{id}/export`: add `media: [{id, sizeBytes, status, createdAt, expiresAt}]` of the linked devices.

### 2.7a Edge cases decided in `feat/encrypted-media-server`
- `GET /media/{id}/upload` on a `Deleted` row -> 404 `media_not_found`.
- `POST /media/{id}/complete` on a `Deleted` row -> 409 `media_not_uploading`; past the upload window -> 410 `media_expired`.
- Download with a range starting at or past the end -> 416 with `Content-Range: bytes */<size>`. A suffix range,
  several ranges or a malformed `Range` header are ignored (200, whole file).
- After completion, `uploadExpiresAt` in the upload state is `CreatedAt + UploadWindowHours` (`ExpiresAt` then holds
  the retention end).
- `MaxTotalBytes` is serialized per device only (row lock on `Devices`): concurrent creates from different devices
  can overshoot the global cap by at most one file each.
- `POST /media` with a valid JWT whose device row is gone -> 401. Export shows `status` in lowercase.

### 2.7b Hardening from the release review (release/2026-11-07)
- Chunk PUT: at most `MaxConcurrentChunkUploadsPerDevice` in flight per device (429 `media_rate_limited`), and the
  chunk buffer grows with the bytes received instead of being allocated up front, so slow requests cannot pin memory.
- `GET /media/{id}/upload` of an `Uploading` row past its upload window -> 410 `media_expired` (the client then starts
  a new upload with a new key instead of failing on every chunk until cleanup runs).
- Download of a `Completed` row whose blob is missing -> 404 `media_not_found` (was 500).

### 2.8 Data model
Entity `MediaUpload` (table `MediaUploads`), migration `AddMediaUploads`:
`Id` Guid (PK, `Guid.NewGuid()`), `UploaderDeviceId` Guid (no FK, deleted explicitly with blobs), `SizeBytes` long
(encrypted), `ChunkSize` int, `Status` (`Uploading`, `Completed`, `Deleted`, stored as string), `CreatedAt`,
`CompletedAt`?, `ExpiresAt` (DateTimeOffset UTC; upload deadline while uploading). Indexes `(UploaderDeviceId, CreatedAt)`,
`(ExpiresAt)`.

### 2.9 Settings (`MediaOptions`, section `Media`, env `Media__X`)

| Setting | Default | Meaning |
|---|---|---|
| `Media:MaxFileBytes` | 5368709120 (5 GiB) | Max encrypted size of one file |
| `Media:RetentionHours` | 72 | Completed media lifetime from completion |
| `Media:UploadWindowHours` | 24 | Time to finish an upload |
| `Media:MaxActiveBytesPerDevice` | 10737418240 (10 GiB) | Uploading + completed, not expired |
| `Media:MaxDailyBytesPerDevice` | 21474836480 (20 GiB) | Declared bytes of uploads created in a rolling 24 h |
| `Media:MaxUploadsPerDay` | 500 | Uploads created per device in a rolling 24 h |
| `Media:MaxTotalBytes` | 536870912000 (500 GiB) | Whole installation, active bytes |
| `Media:CleanupIntervalMinutes` | 10 | Cleanup period |
| `Media:MaxConcurrentChunkUploadsPerDevice` | 8 | Chunk PUTs in flight per device; above it 429 `media_rate_limited` |
| `RateLimiting:MediaPermitLimit` | 600 | Requests/min per device on chunk PUT + download GET |

Kestrel `MaxRequestBodySize` stays 10 MB (a chunk is at most 8 MiB + 16).

## 3. Message format (inside the Signal-encrypted payload)

Outer payload unchanged (`v`, `id`, `groupId`, `to`, `createdAt`, `replyTo`, `mentions`, ...), with
`"type": "text"`, `"body": "<fallback text>"` and the extra key `"media"`:

```json
{
  "v": 1,
  "id": "6f1c...-guid",
  "kind": "voice",
  "name": "voice-20261107-101500.m4a",
  "mime": "audio/mp4",
  "size": 183422,
  "sha256": "<base64, 32 bytes>",
  "key": "<base64, 32 bytes>",
  "nonce": "<base64, 7 bytes>",
  "chunkSize": 4194304,
  "expiresAt": "2026-11-10T09:15:02Z",
  "durationMs": 12345,
  "waveform": "<base64, 1..128 bytes, amplitude 0..255>",
  "caption": "optional text"
}
```

| Field | Rule |
|---|---|
| `v` | 1. A newer `v` -> the client shows the fallback body as text. |
| `id` | Server media id (GUID). |
| `kind` | `image`, `video`, `audio`, `voice`, `file`; unknown -> `file`. |
| `name` | Same rules as `Attachment` (1..255, no `/ \\` or control chars). |
| `mime` | `type/subtype`, max 127; untrusted (only for choosing a viewer). |
| `size` | Plaintext bytes, 0..client cap. |
| `sha256`, `key`, `nonce` | Exact decoded lengths 32 / 32 / 7, else the media part is invalid. |
| `chunkSize` | Plaintext chunk size, 1 MiB..8 MiB. |
| `expiresAt` | From `complete`; drives "expires in X" / "expired". |
| `durationMs` | Optional, >= 0, audio/voice/video. |
| `width`, `height` | Optional, > 0, image/video. |
| `thumbnail` | Optional base64 JPEG, decoded <= 24 KiB, longest side <= 320 px (image/video). |
| `waveform` | Optional, voice (and audio if available). |
| `caption` | Optional, max 4096 chars (same idea as the `caption` the `fix/chat-composer` branch adds to `file`). |

Unknown keys are ignored. An invalid `media` object -> the message is stored as plain `text` with the fallback body
(never dropped, never crashes the inbox).

Fallback body (sender's locale, ARB `mediaFallbackBody`): e.g. `"🎤 Voice message (0:12). Update Jay to play it."`,
`"📎 report.pdf (12.4 MB). Update Jay to download it."`, followed by `\n` + caption when present.

New clients store the row as `type = 'media'`, `body = jsonEncode(media)` (canonical, without the fallback).
Local download state is client-side only (not in the message). Reply preview of a media message: caption, else a
kind label + name/duration. Forward: re-sends the same `media` object while not expired; after expiry, forwarding a
locally available file re-uploads it (or the action is hidden; app branch decides and documents).
Backup export/import accept type `media` (old clients cannot import such a backup, see Limits).
Notifications: local notification preview uses the kind label ("Voice message", "Video", file name), server pushes
are unchanged (generic).

## 4. App behaviour

### 4.1 Sending
- `ChatController.sendMedia(PickedMedia source, {MediaKind? kind, String? caption, int? durationMs, Uint8List? waveform, ...})`:
  copy into local media storage (mobile/desktop) -> optimistic row `type 'media'` status `sending` with upload
  progress -> `POST /media` -> encrypt + `PUT` chunks (bounded concurrency, e.g. 2) -> `complete` -> send the
  payload through the existing encrypted pipeline -> `sent`.
- Progress and Cancel on the bubble; cancel = `DELETE /media/{id}` and the row becomes `failed` (deletable/retryable).
- Upload state is persisted (`backupState` key `mediaup:<messageId>`: media id, key, nonce, local path), so after an
  app restart the outbox retry resumes via `GET /media/{id}/upload`. If the upload window passed, it starts a new
  upload with a new key.
- Composer: attachment sheet gains Video (gallery, camera on mobile) and Audio/File (any file, media path above
  256 KiB). Picked files are read as streams, never fully into memory (`file_picker` `withReadStream`, `XFile.openRead`).
- Video: duration/size/thumbnail if available, original file (M14). Image via media path: thumbnail + dimensions.

### 4.2 Voice messages
- Mic button replaces Send while the text field is empty. Hold to record, release to send, slide left past a threshold
  to cancel (haptic + "Slide to cancel"), shown timer. Shorter than 1 s -> discarded with hint "Hold to record".
  Max 30 min (auto stop + send). Locked hands-free mode out of scope.
- Format: AAC-LC in `.m4a` (`audio/mp4`) where `record` supports it (iOS, Android, macOS, Windows); web records what
  the browser offers (Opus/WebM on Chrome/Firefox, MP4 on Safari) and labels `mime` truthfully.
- Waveform: amplitude samples during recording, reduced to 64 bars (0..255).
- Recorder behind a seam (`VoiceRecorder` interface) so widget tests use a fake.
- Permissions: iOS `NSMicrophoneUsageDescription` text extended to voice messages; Android `RECORD_AUDIO` and macOS
  `audio-input` already present. Permission denied -> snackbar pointing to Settings.

### 4.3 Receiving and the bubble (M8)
States: `notDownloaded` (Download button, size, "expires in X"), `downloading` (progress + Cancel),
`downloaded` (viewer/player), `expired` (no button, "Media expired"), `failed` (Retry; tamper -> "File is damaged"),
`tooLargeForWeb` (web, > 512 MiB). Voice bubble before download: duration + waveform from the message.
After download:
- image: inline preview, tap -> full-screen viewer;
- video: thumbnail with play -> in-app player (`video_player`), Windows/Linux -> "Open" with the system app;
- audio and voice: inline player, play/pause, seek on progress/waveform, speed 1x/1.5x/2x;
- file: name + size, Open (system app) and Save.
Every downloaded media message has "Save to device" (M10) in its actions. Delete for me also deletes the local file
when no other message references the same media id. Download resumes from the `.part` file after a restart (user taps
again). 404/410 -> `expired`.

### 4.4 Localisation
All new strings in `app_en.arb` with `@key` descriptions and translated in all 19 `app_*.arb` files.

## 5. Tests (minimum)

Server (`MediaEndpointsTests`, `MediaCleanupServiceTests`, additions to `PrivacyEndpointsTests`): create/size cap/
invalid chunk size; chunk length and index validation; non-uploader 404; resume listing; complete with missing chunks
409 + `missing`; complete idempotent; download by another device 200, Range 206, unauthenticated 401; per-device quota
409, daily cap 429, global cap 503; expired 410 before cleanup and 404 after; cleanup deletes blob + row for completed
and abandoned uploads (FakeTimeProvider); delete marks `Deleted` and still counts for the daily cap; device deletion and
account deletion remove media blobs + rows; export lists media.

App: chunk encrypt/decrypt round trip (multiple chunks, exact chunk boundary, empty file) from/to temp files;
truncation (drop last chunk), extension, chunk swap, bit flip, wrong key -> errors, partial file removed; SHA-256
mismatch; `media` object encode/decode + validation; inbound `type:text` + `media` -> row type `media`; invalid
`media` -> plain text fallback; old `file` type still decodes (with and without `caption`); backup import accepts
`media`; voice recorder UI states with a fake recorder (idle, recording, cancel by slide, too short, send);
bubble states (not downloaded, downloading, expired, downloaded) with fakes; no download request without a tap.

## Limits (v1, honest)

- Bytes go through the App Service (no SAS offload yet): throughput and egress are bounded by the API plan.
- Local media files are stored decrypted in app-private storage (OS sandbox/file protection only).
- Web: max 512 MiB per file, downloaded media is kept only for the browser session.
- No video compression and no video thumbnail where no maintained plugin fits (sent as original).
- Windows/Linux: no in-app video player, "Open" with the system app.
- Voice recorded on web as Opus/WebM may not play on old iOS/Safari.
- Backups do not include media files; restored media is available only while the server copy lives. Old clients cannot
  import a backup that contains `media` rows.
- Old clients see only the fallback text; they cannot download the media.
- No storage-management screen for local media yet (delete messages to free space).
- Abuse controls are per device; anonymous device creation means the global cap is the real cost bound.
- iOS native behaviour (mic permission prompt, gallery save of videos) is unverified until a TestFlight build.
- Windows (and Linux) encrypt and decrypt with the pure Dart AES-GCM of `package:cryptography` (no native
  backend there), noticeably slower than Android / iOS / macOS (native) and web (WebCrypto).
- Web: an unfinished upload cannot resume after a page reload (the picked file lived in memory); the row stays
  `failed`.
- Android "Save to device" of a non-image file over 100 MiB opens the share sheet (Files / Drive) instead of
  the save dialog: the Storage Access Framework target is a content URI and file_picker needs the bytes in memory.
- "Open" on iOS / Android goes through the share sheet (no maintained open-with plugin added).

## App implementation notes (`feat/encrypted-media-app`)

- Plugins: `record` 6.2.1 (voice), `audioplayers` 6.7.1 (inline player, rate 1x/1.5x/2x), `video_player` 2.11.1
  (Android, iOS, macOS, web), `fc_native_video_thumbnail` 2.2.0 (video thumbnail on Android, iOS, macOS, Windows;
  macOS 11.0 like the app; its Linux part needs FFmpeg dev libraries, the app has no Linux target). The newest
  majors need Flutter 3.44, the repo is on 3.41. No video compression (no maintained plugin fits), the original
  is sent. Video duration and size come from `video_player` where it exists.
- Expiry is shown as "Available until <date, time>" (localized `DateFormat`) instead of "expires in X": same
  information, no plural forms in 19 languages.
- Forwarding a media message re-sends the same `media` object; the action is hidden once `expiresAt` passed (no
  re-upload in v1).
- Upload resume after a restart is implemented: the row body holds the draft `media` object (id, key, nonce,
  sha256 once known) and `mediaup:<messageId>` the local folder; the outbox retry asks `GET /media/{id}/upload`
  and sends only missing chunks, a 404 / 410 starts a new upload with a new key.
- A delete for everyone of a media message (sent or received) also removes the local file when no other row
  references the media id.

## App hardening from the release review (release/2026-11-07)

- Business conversations get NO media (fail closed like edit, delete and reactions): `sendMedia` throws
  `MediaNotAllowed`, the attachment sheet hides video and audio, there is no mic button, and a file over the inline
  limit is refused as too large. Reason: the compliance archive (K01) would only record the fallback text.
- A received `thumbnail` is rendered only if it is a JPEG whose frame header says at most 320 x 320 px; anything else
  drops the preview (not the message). A sender-declared PNG/WebP canvas could otherwise decode to gigabytes.
- The media `id` is stored in lower case (it names the local folder; case-insensitive file systems).
- Media names additionally reject `: < > " | ? *`, DEL, bidi controls (U+202A..202E, U+2066..2069), a trailing dot or
  space and Windows device names (CON, NUL, COM1, ...).
- Desktop "Open" refuses programs, scripts, installers and shortcuts (exe, bat, sh, app, desktop, ...): the OS shell
  would run them. Mobile opens through the share sheet.
- An "image" over 50 MiB is shown as a file tile, never read into memory for an inline preview.
- Reactions work on `media` rows (the reactions branch predates the media type).
- The backup export skips in-flight `reaction` rows (an older app's import rejects that type).

## Bots (`fix/bridge-media`)

- The format code is shared: `calltype_core/lib/media/media_crypto.dart` (`MediaCipher`, moved from the app) and
  `media_info.dart` (`MediaInfo`, `MediaKind`, validation, `jpegDimensions`). The app's `features/media` files
  re-export them; the bots decrypt with the same code.
- `calltype_bot`: a received `text` + `media` message is a `BotMessage` with `attachment` (metadata, `saveTo` /
  `readBytes` = download, chunked decrypt, SHA-256 check); `text` stays the fallback body. Old inline `type: file`
  only with `onMessage(receiveFiles: true)`. Nothing is downloaded without the bot asking.
- `hermes_bridge`: owners' voice messages and audio are transcribed (ElevenLabs Speech-to-Text, optional key),
  images go to Hermes as `image_url` input, other files are saved under `MEDIA_DIR` (7 days, 200 MB cap) and passed as
  a path. Details and env: `src/bots/hermes_bridge/README.md`, "Voice messages, images and files".

## Ops (deploy notes)

- New App Service settings only if the defaults should change (section 2.9). The container `media` is created on first
  use (`CreateIfNotExistsAsync`).
- Optional safety net: Blob lifecycle rule on container `media` deleting blobs older than 4 days (Azure change, not
  done by this branch).
- EF migration `AddMediaUploads` runs on startup.
