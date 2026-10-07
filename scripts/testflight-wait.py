# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Waits for App Store Connect to process TestFlight build `argv[1]` and fails loudly when it does not take it.

Reads the API key from ASC_KEY_P8_B64 (base64 of the .p8), ASC_KEY_ID and ASC_ISSUER_ID; never prints them.
ASC_APP_ID is the app's Apple ID in App Store Connect (App Information > Apple ID).
"""
import base64, os, sys, time, jwt, requests

APP = os.environ.get("ASC_APP_ID") or sys.exit("ASC_APP_ID is not set")
API = "https://api.appstoreconnect.apple.com/v1"
POLL = 30
DEADLINE = time.monotonic() + 30 * 60


class Unreachable(Exception):
    """App Store Connect did not answer this time (network, 429, 5xx): asked again later."""


def get(path, **params):
    now = int(time.time())
    token = jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        base64.b64decode(os.environ["ASC_KEY_P8_B64"]), algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )
    try:
        r = requests.get(API + path, params=params, headers={"Authorization": f"Bearer {token}"}, timeout=30)
    except requests.RequestException as e:
        raise Unreachable(type(e).__name__) from None
    if r.status_code == 429 or r.status_code >= 500:
        raise Unreachable(f"HTTP {r.status_code}")
    try:
        body = r.json()
    except ValueError:
        sys.exit(f"{path}: HTTP {r.status_code}, no JSON")
    if r.status_code != 200:
        errors = body.get("errors", []) if isinstance(body, dict) else []
        sys.exit(f"{path}: HTTP {r.status_code} {[e.get('code') for e in errors]}")
    return body["data"]


def wait(what, read, busy):
    while True:
        try:
            state = read()
        except Unreachable as e:
            state = f"unknown ({e})"
        else:
            if state not in busy:
                return state
        if time.monotonic() > DEADLINE:
            sys.exit(f"{what} still {state} after 30 min")
        print(f"{what} {state}, checking again in {POLL} s", flush=True)
        time.sleep(POLL)


def upload_state(build):
    # A retried upload leaves its earlier reservation behind with the same build number: the one that arrived counts.
    found = get(f"/apps/{APP}/buildUploads", **{"filter[cfBundleVersion]": build, "sort": "-uploadedDate", "limit": 200})
    uploads = [u["attributes"] for u in found]
    if not uploads:
        return "NOT_LISTED", {}
    upload = max(uploads, key=lambda u: (u["uploadedDate"] is not None, u["createdDate"]))
    return upload["state"]["state"], upload["state"]


def main():
    build = sys.argv[1]
    report = {}

    def read_upload():
        state, detail = upload_state(build)
        report.update(detail)
        return state

    state = wait(f"upload {build}", read_upload, {"NOT_LISTED", "AWAITING_UPLOAD", "PROCESSING"})
    print(f"upload {build}: {state}")
    for kind in ("errors", "warnings"):
        for item in report.get(kind, []):
            print(f"  {kind[:-1]} {item.get('code')}: {item.get('description')}")
    if state != "COMPLETE":
        sys.exit(f"upload {build} ended {state}")

    def read_build():
        builds = get("/builds", **{"filter[app]": APP, "filter[version]": build})
        return builds[0]["attributes"]["processingState"] if builds else "NOT_LISTED"

    state = wait(f"build {build}", read_build, {"NOT_LISTED", "PROCESSING"})
    print(f"build {build}: {state}")
    if state != "VALID":
        sys.exit(f"build {build} is {state}, not VALID")


main()
