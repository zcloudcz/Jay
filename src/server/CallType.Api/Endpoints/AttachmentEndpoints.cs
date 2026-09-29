// ---------------------------------------------------------------------------
// AttachmentEndpoints.cs — /attachments (E2E encrypted media blobs) — X0 STUB
// ---------------------------------------------------------------------------
// Stream M2 (package M2-3) maps the group here: POST /attachments,
// PUT /attachments/{blobId}/chunks/{index} (rate limit "attachment-chunks"),
// GET /attachments/{blobId}/upload, POST /attachments/{blobId}/commit,
// GET /attachments/{blobId} (Range), DELETE /attachments/{blobId}; everything
// else under rate limit "attachments". Contract: gap-media.md M2-3.
// X0 only wires MapAttachmentEndpoints into Program.cs and registers both rate
// limit policies. No 501 placeholder routes: nothing compiles against them.
// ---------------------------------------------------------------------------

namespace CallType.Api.Endpoints;

public static class AttachmentEndpoints
{
    public static WebApplication MapAttachmentEndpoints(this WebApplication app) => app;
}
