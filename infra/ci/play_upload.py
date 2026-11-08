#!/usr/bin/env python3
"""Upload an Android App Bundle to a Google Play track (Android Publisher API v3).

Used by .github/workflows/android-play.yml. Needs only the standard library
plus `cryptography` (for signing the service account JWT), so the workflow
does not depend on a third-party upload action.

Environment:
  PLAY_SERVICE_ACCOUNT_JSON  service account key (JSON text), invited in Play
                             Console with release permissions for the app.
Arguments:
  --package cz.zcloud.jay --aab path/to/app-release.aab --track internal
  [--status completed|draft] [--notes "text"] [--notes-lang en-US]

Exit code 0 only after the edit is committed. Prints the version code and
the track, never the key.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"


def _b64(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def access_token(sa: dict) -> str:
    now = int(time.time())
    header = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({
        "iss": sa["client_email"], "scope": SCOPE, "aud": sa["token_uri"],
        "iat": now, "exp": now + 3600,
    }).encode())
    key = serialization.load_pem_private_key(sa["private_key"].encode(), None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ValueError("service account key is not an RSA key")
    signature = _b64(key.sign(header + b"." + claims, padding.PKCS1v15(), hashes.SHA256()))
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": (header + b"." + claims + b"." + signature).decode(),
    }).encode()
    with urllib.request.urlopen(sa["token_uri"], data=body, timeout=60) as resp:
        return json.load(resp)["access_token"]


class Play:
    def __init__(self, token: str, package: str):
        self.token = token
        self.package = package

    def call(self, method, url, body=None, data=None, content_type="application/json", timeout=120):
        if body is not None:
            data = json.dumps(body).encode()
        req = urllib.request.Request(url, method=method, data=data, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": content_type})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:2000]
            raise RuntimeError(f"{method} {url.split('?')[0]} -> HTTP {err.code}: {detail}") from None

    def api(self, method, path, body=None):
        return self.call(method, API + self.package + path, body=body)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", required=True)
    ap.add_argument("--aab", required=True)
    ap.add_argument("--track", default="internal")
    ap.add_argument("--status", default="completed", choices=["completed", "draft"])
    ap.add_argument("--notes", default="")
    ap.add_argument("--notes-lang", default="en-US")
    args = ap.parse_args()

    raw = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "")
    if not raw.strip():
        print("::error::PLAY_SERVICE_ACCOUNT_JSON is not set.", file=sys.stderr)
        return 1
    play = Play(access_token(json.loads(raw)), args.package)

    edit_id = play.api("POST", "/edits", {})["id"]
    try:
        with open(args.aab, "rb") as fh:
            bundle = play.call(
                "POST",
                f"{UPLOAD}{args.package}/edits/{edit_id}/bundles?uploadType=media",
                data=fh.read(), content_type="application/octet-stream", timeout=900)
        version_code = str(bundle["versionCode"])
        print(f"Uploaded bundle versionCode={version_code} sha256={bundle.get('sha256', '?')}")

        release = {"versionCodes": [version_code], "status": args.status}
        if args.notes:
            release["releaseNotes"] = [{"language": args.notes_lang, "text": args.notes[:500]}]
        try:
            play.api("PUT", f"/edits/{edit_id}/tracks/{args.track}",
                     {"track": args.track, "releases": [release]})
        except RuntimeError as err:
            # An app that was never published to production only accepts
            # draft releases through the API; Play Console can still roll
            # the draft out by hand.
            if args.status == "completed" and "draft app" in str(err).lower():
                print("::warning::Play accepts only draft releases for this app yet; "
                      "uploading as draft. Roll it out in Play Console.")
                release["status"] = "draft"
                play.api("PUT", f"/edits/{edit_id}/tracks/{args.track}",
                         {"track": args.track, "releases": [release]})
            else:
                raise
        play.api("POST", f"/edits/{edit_id}:commit")
    except Exception:
        try:
            play.api("DELETE", f"/edits/{edit_id}")
        except Exception:
            pass
        raise
    print(f"Committed versionCode {version_code} to track '{args.track}' ({release['status']}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
