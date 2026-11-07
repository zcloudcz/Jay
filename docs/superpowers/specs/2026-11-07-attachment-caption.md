# Attachment caption (contract)

Status: built on `fix/chat-composer` (app only, no server change). Not released.

## Decisions

| Topic | Decision |
|---|---|
| Where the caption lives | Inside the attachment body of the `type: file` message (owner's option B), not as a separate text message. |
| Several photos | One message per photo, as before. The caption goes on the FIRST photo only. |
| Length | Trimmed; at most 1024 user-perceived characters (longer is cut on encode and decode); omitted when empty. |
| Old clients | Read only `name` and `data` and ignore unknown keys: they show the photo without the caption. |
| Generic files | No review screen and no caption (unchanged). |

## Wire shape

Message payload `type: "file"`, `body` is JSON:

```json
{"name": "IMG_20261107_101500.jpg", "data": "<base64 bytes>", "caption": "Pohled z okna"}
```

- `name` (string, required), `data` (base64, required, decoded size <= 256 KiB): unchanged.
- `caption` (string, optional, new). A non-string value is ignored by readers.
- The whole body stays under the existing decode limit (2 x 256 KiB characters).

## Where the caption shows

- Under the image in the message bubble.
- Reply quote of a photo: the caption, else the file name (`ChatController.replyPreviewOf`).
- Forward: the body is forwarded verbatim, so the caption travels with it.
- Local notification: "Photo: <caption>" (`notificationPhotoCaption`), plain "Photo" without one.

## Bots and services

- `jay_archiver` hashes the body verbatim and reads only `data` for the size: compatible, the caption is archived as part of the body.
- `calltype_bot` / `hermes_bridge` / `a2a_bridge` ignore non-text messages: unaffected.

## Limits

- The review screen shows photos AFTER conversion to JPEG (the same bytes that are sent); conversion still happens before the review.
- iOS keyboard / photo picker behaviour of the review screen is verified only on the TestFlight build.
