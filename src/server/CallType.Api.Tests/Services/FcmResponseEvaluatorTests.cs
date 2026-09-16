// ---------------------------------------------------------------------------
// FcmResponseEvaluatorTests.cs — Pure unit tests for FCM response evaluation
// ---------------------------------------------------------------------------
// K04 requires that a bare 404 from FCM HTTP v1 must NOT be treated as proof
// a push token is dead — only a 404 carrying the FCM "UNREGISTERED" error
// code may. These tests exercise FcmResponseEvaluator.Evaluate directly
// against canned status codes/bodies, with no database and no real HTTP call,
// so they run even when Testcontainers/Docker is unavailable.
// ---------------------------------------------------------------------------

using System.Net;
using FluentAssertions;
using CallType.Api.Services;

namespace CallType.Api.Tests.Services;

public class FcmResponseEvaluatorTests
{
    private const string UnregisteredBody = """
        {
          "error": {
            "code": 404,
            "message": "Requested entity was not found.",
            "status": "NOT_FOUND",
            "details": [
              {
                "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                "errorCode": "UNREGISTERED"
              }
            ]
          }
        }
        """;

    [Fact]
    public void NotFound_with_UNREGISTERED_error_code_marks_token_unregistered()
    {
        var outcome = FcmResponseEvaluator.Evaluate(HttpStatusCode.NotFound, UnregisteredBody);

        outcome.Should().Be(FcmSendOutcome.TokenUnregistered);
    }

    [Fact]
    public void Generic_404_without_error_code_does_not_mark_token_unregistered()
    {
        // A 404 can also mean "wrong project/URL" or a proxy error page —
        // none of that proves the specific token is dead.
        const string body = """{ "error": { "code": 404, "status": "NOT_FOUND" } }""";

        var outcome = FcmResponseEvaluator.Evaluate(HttpStatusCode.NotFound, body);

        outcome.Should().Be(FcmSendOutcome.Ok);
    }

    [Fact]
    public void NotFound_with_unparseable_body_does_not_mark_token_unregistered()
    {
        var outcome = FcmResponseEvaluator.Evaluate(HttpStatusCode.NotFound, "not json at all");

        outcome.Should().Be(FcmSendOutcome.Ok);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public void Non_404_failures_never_mark_token_unregistered(HttpStatusCode statusCode)
    {
        // 401/429/500 are provider/auth/rate-limit problems, not proof of a
        // dead token — must never trigger a delete.
        var outcome = FcmResponseEvaluator.Evaluate(statusCode, UnregisteredBody);

        outcome.Should().Be(FcmSendOutcome.Ok);
    }
}
