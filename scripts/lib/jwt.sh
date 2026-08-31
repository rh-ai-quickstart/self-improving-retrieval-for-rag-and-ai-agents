#!/usr/bin/env bash

jwt_expiry_utc() {
    python3 -c '
import base64
import datetime
import json
import sys

token = sys.stdin.read().strip()
try:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    expires_at = datetime.datetime.fromtimestamp(
        int(claims["exp"]), tz=datetime.timezone.utc
    )
except (IndexError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Unable to read token expiry: {exc}")

print(expires_at.strftime("%Y-%m-%dT%H:%M:%S"))
'
}
