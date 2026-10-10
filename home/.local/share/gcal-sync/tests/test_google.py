"""Google write-back against a FAKE Calendar API + token endpoint on 127.0.0.1 (no network, no real
credentials): checks token refresh and the exact calls for create / this / following / all.
Run: ~/.venvs/gcal/bin/python ~/.local/share/gcal-sync/tests/test_google.py"""
import datetime as dt
import http.server
import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path
from zoneinfo import ZoneInfo

CALLS = []


class Fake(http.server.BaseHTTPRequestHandler):
    def _do(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        if self.path == "/token":
            CALLS.append(("TOKEN", raw))
            out = {"access_token": "fresh", "expires_in": 3600}
        else:
            body = json.loads(raw) if raw else None
            CALLS.append((self.command, self.path, body, self.headers.get("Authorization")))
            out = {"id": "newid", "iCalUID": "newid@google.com"} if self.command == "POST" else {}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PATCH = do_DELETE = _do

    def log_message(self, *a):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_port}"
tmp = Path(tempfile.mkdtemp(prefix="gcal-google-test-"))
os.environ.update(GCAL_GOOGLE_DIR=str(tmp), GCAL_GOOGLE_API=base + "/api", GCAL_GOOGLE_TOKEN_URL=base + "/token")
(tmp / "google-client.json").write_text(json.dumps({"installed": {"client_id": "test-client", "client_secret": "fake"}}))
(tmp / "google-token.json").write_text(json.dumps({"refresh_token": "test-refresh", "access_token": "old", "expires_at": time.time() - 5}))

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import gcal_google as G  # noqa: E402

TZ = ZoneInfo("Europe/Berlin")
FAILS = []


def check(name, got, exp):
    if got != exp:
        FAILS.append(name)
        print(f"FAIL {name}\n   got {got!r}\n   exp {exp!r}")
    else:
        print(f"ok   {name}")


FEED = "\r\n".join(["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//t//t//EN",
                    "BEGIN:VEVENT", "UID:s1@google.com", "DTSTAMP:20261001T000000Z", "SUMMARY:Series",
                    "DTSTART;TZID=Europe/Berlin:20261005T100000", "DTEND;TZID=Europe/Berlin:20261005T110000",
                    "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=6", "END:VEVENT",
                    "BEGIN:VEVENT", "UID:one@google.com", "DTSTAMP:20261001T000000Z", "SUMMARY:Single",
                    "DTSTART;TZID=Europe/Berlin:20261007T090000", "DTEND;TZID=Europe/Berlin:20261007T093000", "END:VEVENT",
                    "END:VCALENDAR", ""]).encode()
CAL = "test@example.com"
P = "/api/calendars/test%40example.com/events"
rid = lambda d, t="10:00": dt.datetime.combine(dt.date.fromisoformat(d), dt.time.fromisoformat(t), TZ).isoformat()  # noqa: E731
item = lambda **k: dict({"title": "Series", "date": "2026-10-19", "time": "10:00", "duration": 60,  # noqa: E731
                         "recurrence": {"freq": "weekly", "byday": ["MO"], "count": 6}, "reminders": [10]}, **k)

# create (recurring) -> token refresh + POST with RRULE and a popup reminder
CALLS.clear()
G.create(CAL, {"title": "New", "date": "2026-10-13", "time": "18:00", "duration": 90,
               "recurrence": {"freq": "monthly", "byday": ["2TU"]}, "reminders": [30]}, TZ)
check("token refreshed first", CALLS[0][0], "TOKEN")
m, path, body, auth = CALLS[1]
check("create call", (m, path), ("POST", P))
check("create bearer", auth, "Bearer fresh")
check("create body", (body["start"], body["end"]["dateTime"], body["recurrence"], body["reminders"]),
      ({"dateTime": "2026-10-13T18:00:00+02:00", "timeZone": "Europe/Berlin"}, "2026-10-13T19:30:00+02:00",
       ["RRULE:FREQ=MONTHLY;BYDAY=2TU"], {"useDefault": False, "overrides": [{"method": "popup", "minutes": 30}]}))
check("token cached after refresh", json.loads((tmp / "google-token.json").read_text())["access_token"], "fresh")
check("token file is private", oct((tmp / "google-token.json").stat().st_mode & 0o777), "0o600")

# edit this occurrence -> PATCH the instance id (UTC start), no recurrence
CALLS.clear()
G.update(CAL, "s1@google.com", rid("2026-10-19"), "this", item(title="Moved", time="14:00"), TZ, FEED)
m, path, body, _ = CALLS[0]
check("edit this -> instance", (m, path, body["summary"], body["start"]["dateTime"], "recurrence" in body),
      ("PATCH", P + "/s1_20261019T080000Z", "Moved", "2026-10-19T14:00:00+02:00", False))

# edit this and following -> truncate the master (UNTIL) + POST the new series with the remaining count
CALLS.clear()
G.update(CAL, "s1@google.com", rid("2026-10-19"), "following", item(time="12:00"), TZ, FEED)
check("edit following: 2 calls", [(c[0], c[1]) for c in CALLS], [("PATCH", P + "/s1"), ("POST", P)])
check("edit following: master truncated", CALLS[0][2], {"recurrence": ["RRULE:FREQ=WEEKLY;UNTIL=20261019T075959Z;BYDAY=MO"]})
check("edit following: new series", (CALLS[1][2]["start"]["dateTime"], CALLS[1][2]["recurrence"]),
      ("2026-10-19T12:00:00+02:00", ["RRULE:FREQ=WEEKLY;COUNT=4;BYDAY=MO"]))

# edit all -> PATCH the master with the series moved by the same amount
CALLS.clear()
G.update(CAL, "s1@google.com", rid("2026-10-19"), "all", item(title="Renamed", time="11:00"), TZ, FEED)
check("edit all -> master", (CALLS[0][0], CALLS[0][1], CALLS[0][2]["summary"], CALLS[0][2]["start"]["dateTime"], CALLS[0][2]["recurrence"]),
      ("PATCH", P + "/s1", "Renamed", "2026-10-05T11:00:00+02:00", ["RRULE:FREQ=WEEKLY;COUNT=6;BYDAY=MO"]))

# deletes
CALLS.clear()
G.delete(CAL, "s1@google.com", rid("2026-10-26"), "this", TZ, FEED)
G.delete(CAL, "s1@google.com", rid("2026-10-26"), "following", TZ, FEED)
G.delete(CAL, "s1@google.com", rid("2026-10-05"), "following", TZ, FEED)
G.delete(CAL, "s1@google.com", rid("2026-10-26"), "all", TZ, FEED)
G.delete(CAL, "one@google.com", "", "all", TZ, FEED)
check("deletes", [(c[0], c[1], c[2]) for c in CALLS],
      [("DELETE", P + "/s1_20261026T090000Z", None),
       ("PATCH", P + "/s1", {"recurrence": ["RRULE:FREQ=WEEKLY;UNTIL=20261026T085959Z;BYDAY=MO"]}),
       ("DELETE", P + "/s1", None), ("DELETE", P + "/s1", None), ("DELETE", P + "/one", None)])

# single event edit
CALLS.clear()
G.update(CAL, "one@google.com", "", "all", {"title": "Single 2", "date": "2026-10-08", "time": "09:00", "duration": 30, "recurrence": None}, TZ, FEED)
check("single edit", (CALLS[0][0], CALLS[0][1], CALLS[0][2]["start"]["dateTime"], CALLS[0][2]["recurrence"]),
      ("PATCH", P + "/one", "2026-10-08T09:00:00+02:00", []))

# non-Google UIDs are refused
try:
    G.event_id("abc@example.org")
    check("foreign uid refused", "no error", "GoogleError")
except G.GoogleError:
    check("foreign uid refused", "GoogleError", "GoogleError")

srv.shutdown()
print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED: ' + ', '.join(FAILS)}")
sys.exit(1 if FAILS else 0)
