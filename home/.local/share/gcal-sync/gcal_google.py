"""Optional Google Calendar write-back (Calendar API v3, the user's own OAuth "Desktop app" client).

The secret iCal link the agenda reads is read-only. With this enabled, events created or edited in
the agenda go to Google directly: create, edit/delete "this event / this and following / all events"
(the same edit logic as the local store, computed on the cached feed, then sent as API calls).

Files (never in a repo, mode 600):
  ~/.config/gcal-sync/google-client.json   the OAuth client downloaded from Google Cloud Console
  ~/.config/gcal-sync/google-token.json    refresh/access token written by `gcal-setup oauth`
Only the standard library is used. Tests point GCAL_GOOGLE_API / GCAL_GOOGLE_TOKEN_URL at a fake server.
"""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CONF_DIR = Path(os.environ.get("GCAL_GOOGLE_DIR") or (Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "gcal-sync"))
CLIENT = CONF_DIR / "google-client.json"
TOKEN = CONF_DIR / "google-token.json"
API = os.environ.get("GCAL_GOOGLE_API", "https://www.googleapis.com/calendar/v3")
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = os.environ.get("GCAL_GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")
SCOPE = "https://www.googleapis.com/auth/calendar.events"


class GoogleError(RuntimeError):
    pass


def _write_secret(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def enabled() -> bool:
    return CLIENT.exists() and TOKEN.exists()


def _client() -> dict:
    try:
        raw = json.loads(CLIENT.read_text())
    except (OSError, ValueError) as e:
        raise GoogleError(f"cannot read {CLIENT}: {e}")
    c = raw.get("installed") or raw.get("web") or raw
    if not c.get("client_id"):
        raise GoogleError(f"{CLIENT} has no client_id (download the 'Desktop app' OAuth client JSON)")
    return c


def _post_form(url: str, fields: dict) -> dict:
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode(),
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:300]
        raise GoogleError(f"token endpoint: HTTP {e.code} {body}")


# ───────────────────────────── OAuth (loopback + PKCE) ─────────────────────────────

def install_client(path: str) -> None:
    """Copy a downloaded client_secret_*.json into ~/.config/gcal-sync (0600)."""
    raw = json.loads(Path(os.path.expanduser(path)).read_text())
    c = raw.get("installed") or raw.get("web") or raw
    if not c.get("client_id"):
        raise GoogleError("that file is not an OAuth client JSON (no client_id)")
    _write_secret(CLIENT, raw)


def authorize(open_browser=True, timeout=300) -> None:
    """One-time consent in the browser; stores the refresh token."""
    c = _client()
    verifier = secrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    state = secrets.token_urlsafe(16)
    got = {}

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [""])[0] == state and ("code" in q or "error" in q):
                got.update({k: v[0] for k, v in q.items()})
                msg = "Google Calendar access granted. You can close this tab." if "code" in q else "Access was not granted."
            else:
                msg = "Waiting for Google..."
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(msg.encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    redirect = f"http://127.0.0.1:{srv.server_port}"
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": c["client_id"], "redirect_uri": redirect, "response_type": "code", "scope": SCOPE,
        "access_type": "offline", "prompt": "consent", "state": state,
        "code_challenge": challenge, "code_challenge_method": "S256"})
    print("Opening the Google consent page in your browser. If it does not open, visit:\n  " + url + "\n")
    if open_browser:
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    t = threading.Thread(target=lambda: [srv.handle_request() for _ in iter(lambda: not got, False)], daemon=True)
    t.start()
    t.join(timeout)
    srv.server_close()
    if "code" not in got:
        raise GoogleError("no authorization received (" + got.get("error", "timed out") + ")")
    fields = {"code": got["code"], "client_id": c["client_id"], "redirect_uri": redirect,
              "grant_type": "authorization_code", "code_verifier": verifier}
    if c.get("client_secret"):
        fields["client_secret"] = c["client_secret"]
    tok = _post_form(TOKEN_URL, fields)
    if not tok.get("refresh_token"):
        raise GoogleError("Google returned no refresh token; remove the app's access at myaccount.google.com/permissions and retry")
    tok["expires_at"] = time.time() + int(tok.get("expires_in", 3600)) - 60
    _write_secret(TOKEN, tok)


def revoke() -> None:
    for p in (TOKEN,):
        if p.exists():
            p.unlink()


def _access_token() -> str:
    try:
        tok = json.loads(TOKEN.read_text())
    except (OSError, ValueError):
        raise GoogleError("Google write access is not set up (gcal-setup oauth)")
    if tok.get("access_token") and tok.get("expires_at", 0) > time.time():
        return tok["access_token"]
    c = _client()
    fields = {"client_id": c["client_id"], "refresh_token": tok["refresh_token"], "grant_type": "refresh_token"}
    if c.get("client_secret"):
        fields["client_secret"] = c["client_secret"]
    new = _post_form(TOKEN_URL, fields)
    tok["access_token"] = new["access_token"]
    tok["expires_at"] = time.time() + int(new.get("expires_in", 3600)) - 60
    _write_secret(TOKEN, tok)
    return tok["access_token"]


def api(method: str, path: str, body: dict | None = None, _retry=True) -> dict:
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + _access_token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            data = r.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        if e.code == 401 and _retry:
            tok = json.loads(TOKEN.read_text())
            tok["expires_at"] = 0
            _write_secret(TOKEN, tok)
            return api(method, path, body, _retry=False)
        if e.code == 410 and method == "DELETE":   # already gone
            return {}
        msg = e.read().decode("utf-8", "replace")
        try:
            msg = json.loads(msg)["error"]["message"]
        except Exception:
            msg = msg[:200]
        raise GoogleError(f"Google API {method} {path.split('?')[0]}: HTTP {e.code} {msg}")


# ───────────────────────────── VEVENT <-> API resource ─────────────────────────────

def _q(s: str) -> str:
    return urllib.parse.quote(s, safe="")


def event_id(uid: str) -> str:
    if not uid.endswith("@google.com"):
        raise GoogleError("this event was not created in Google Calendar and cannot be edited there")
    return uid[: -len("@google.com")]


def instance_id(uid: str, rid) -> str:
    """Google's id of one occurrence: <eventId>_<UTC start> (timed) or _<date> (all-day)."""
    if isinstance(rid, dt.datetime):
        return event_id(uid) + "_" + rid.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return event_id(uid) + "_" + rid.strftime("%Y%m%d")


def _when(v, tz) -> dict:
    if isinstance(v, dt.datetime):
        v = v if v.tzinfo else v.replace(tzinfo=tz)
        return {"dateTime": v.isoformat(), "timeZone": getattr(tz, "key", "UTC")}
    return {"date": v.isoformat()}


def recurrence_lines(ve, tz) -> list[str]:
    out = []
    if "RRULE" in ve:
        rr = ve["RRULE"]
        rr = rr[0] if isinstance(rr, list) else rr
        out.append("RRULE:" + rr.to_ical().decode())
    ex = ve.get("EXDATE")
    for prop in (ex if isinstance(ex, list) else [ex] if ex else []):
        for v in prop.dts:
            x = v.dt
            if isinstance(x, dt.datetime):
                x = (x if x.tzinfo else x.replace(tzinfo=tz)).astimezone(tz)
                out.append(f"EXDATE;TZID={getattr(tz, 'key', 'UTC')}:" + x.strftime("%Y%m%dT%H%M%S"))
            else:
                out.append("EXDATE;VALUE=DATE:" + x.strftime("%Y%m%d"))
    return out


def body_of(ve, tz, with_recurrence=True) -> dict:
    s = ve.decoded("DTSTART")
    e = ve.decoded("DTEND") if "DTEND" in ve else s + (dt.timedelta(hours=1) if isinstance(s, dt.datetime) else dt.timedelta(days=1))
    b = {"summary": str(ve.get("SUMMARY", "")), "location": str(ve.get("LOCATION", "") or ""),
         "description": str(ve.get("DESCRIPTION", "") or ""), "start": _when(s, tz), "end": _when(e, tz)}
    mins = []
    for al in ve.walk("VALARM"):
        trg = al.decoded("TRIGGER")
        if isinstance(trg, dt.timedelta) and trg <= dt.timedelta(0):
            mins.append(int(-trg.total_seconds() // 60))
    b["reminders"] = {"useDefault": False, "overrides": [{"method": "popup", "minutes": m} for m in sorted(set(mins))[:5]]}
    if with_recurrence:
        b["recurrence"] = recurrence_lines(ve, tz)
    return b


# ───────────────────────────── edits ─────────────────────────────

def _scratch(feed_bytes: bytes | None, uid: str, tz):
    """In-memory store holding just this series (master + overrides) from the cached feed."""
    import icalendar
    from gcal_store import IcsStore
    cal = icalendar.Calendar()
    if feed_bytes:
        src = icalendar.Calendar.from_ical(feed_bytes)
        try:
            import x_wr_timezone
            src = x_wr_timezone.to_standard(src)
        except Exception:
            pass
        for c in src.walk("VEVENT"):
            if str(c.get("UID", "")) == uid:
                cal.add_component(c)
    return IcsStore(None, tz, cal=cal).load()


def _series(store, uid):
    master, overrides = store._comps(uid)
    return master, overrides


def create(calid: str, item: dict, tz) -> str:
    from gcal_store import IcsStore
    st = IcsStore(None, tz).load()
    uid = st.create(item)
    ve = st._comps(uid)[0]
    body = body_of(ve, tz)
    if not body["recurrence"]:
        del body["recurrence"]
    res = api("POST", f"/calendars/{_q(calid)}/events", body)
    return (res.get("iCalUID") or (res.get("id", "") + "@google.com"))


def delete(calid: str, uid: str, rid: str, scope: str, tz, feed_bytes: bytes | None) -> str:
    from gcal_store import parse_rid
    st = _scratch(feed_bytes, uid, tz)
    master, _ = _series(st, uid)
    ridv = parse_rid(rid, tz)
    recurring = master is not None and "RRULE" in master
    path = f"/calendars/{_q(calid)}/events/"
    if not recurring or scope == "all" or ridv is None:
        api("DELETE", path + _q(event_id(uid)))
        return "deleted"
    if scope == "this":
        api("DELETE", path + _q(instance_id(uid, ridv)))
        return "deleted this"
    r = st.delete(uid, rid, "following")
    m2, _ = _series(st, uid)
    if m2 is None:                          # "following" from the first occurrence = everything
        api("DELETE", path + _q(event_id(uid)))
        return "deleted"
    api("PATCH", path + _q(event_id(uid)), {"recurrence": recurrence_lines(m2, tz)})
    return r


def update(calid: str, uid: str, rid: str, scope: str, item: dict, tz, feed_bytes: bytes | None) -> str:
    from gcal_store import parse_rid
    st = _scratch(feed_bytes, uid, tz)
    master, _ = _series(st, uid)
    if master is None and not st._comps(uid)[1]:
        raise GoogleError("event not found in the cached feed; sync and try again")
    ridv = parse_rid(rid, tz)
    recurring = master is not None and "RRULE" in master
    path = f"/calendars/{_q(calid)}/events/"
    before = {str(c.get("UID")) for c in st.cal.walk("VEVENT")}
    r = st.update(uid, rid, scope, item)
    if not recurring or ridv is None:
        ve = master or st._comps(uid)[1][0]
        api("PATCH", path + _q(event_id(uid)), body_of(ve, tz))
        return r
    if r == "updated this":
        ov = next(o for o in st._comps(uid)[1] if _same(o.decoded("RECURRENCE-ID"), ridv))
        api("PATCH", path + _q(instance_id(uid, ridv)), body_of(ov, tz, with_recurrence=False))
        return r
    if r == "updated following":
        m2, _ = _series(st, uid)
        api("PATCH", path + _q(event_id(uid)), {"recurrence": recurrence_lines(m2, tz)})
        new = [c for c in st.cal.walk("VEVENT") if str(c.get("UID")) not in before]
        if new:
            api("POST", f"/calendars/{_q(calid)}/events", body_of(new[0], tz))
        return r
    m2, _ = _series(st, uid)                  # all events
    api("PATCH", path + _q(event_id(uid)), body_of(m2, tz))
    return r


def _same(a, b) -> bool:
    from gcal_store import _same_instant
    return _same_instant(a, b)
