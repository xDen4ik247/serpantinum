"""Fixture tests for the local event store: create + edit/delete "this / following / all" on
repeating events. Synthetic events only; works on a temp file.
Run: ~/.venvs/gcal/bin/python ~/.local/share/gcal-sync/tests/test_store.py"""
import datetime as dt
import sys
import tempfile
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import icalendar  # noqa: E402
import recurring_ical_events  # noqa: E402

import gcal_rec as R  # noqa: E402
from gcal_store import IcsStore  # noqa: E402

TZ = ZoneInfo("Europe/Berlin")
FAILS = []


def check(name, got, exp):
    if got != exp:
        FAILS.append(name)
        print(f"FAIL {name}\n   got {got!r}\n   exp {exp!r}")
    else:
        print(f"ok   {name}")


def expand(store, a="2026-10-01", b="2027-01-31"):
    """[(local start 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD', title)] between a and b."""
    cal = icalendar.Calendar.from_ical(store.path.read_bytes())
    out = []
    for ev in recurring_ical_events.of(cal).between(dt.date.fromisoformat(a), dt.date.fromisoformat(b)):
        s = ev.decoded("DTSTART")
        s = s.astimezone(TZ).strftime("%Y-%m-%d %H:%M") if isinstance(s, dt.datetime) else s.isoformat()
        out.append((s, str(ev.get("SUMMARY"))))
    return sorted(out)


def rid(day, hhmm="10:00"):
    return dt.datetime.combine(dt.date.fromisoformat(day), dt.time.fromisoformat(hhmm), TZ).isoformat()


def new_store():
    d = tempfile.mkdtemp(prefix="gcal-store-test-")
    return IcsStore(Path(d) / "local.ics", TZ)


def weekly(title="Lab", day="2026-10-05", t="10:00", **rec):
    r = {"freq": "weekly", "byday": ["MO"]}
    r.update(rec)
    return {"title": title, "date": day, "time": t, "duration": 90, "recurrence": r, "reminders": [10]}


# 1. create a weekly series (Mondays 10:00, 5 times)
s = new_store()
uid = s.create(weekly(count=5))
check("create weekly x5", [x[0] for x in expand(s)],
      ["2026-10-05 10:00", "2026-10-12 10:00", "2026-10-19 10:00", "2026-10-26 10:00", "2026-11-02 10:00"])
it = s.get(uid, rid("2026-10-19"))
check("get occurrence", (it["date"], it["time"], it["duration"], it["isFirst"], it["repeat"], it["reminders"]),
      ("2026-10-19", "10:00", 90, False, "Weekly on Monday, 5 times", [10]))
check("get first", s.get(uid, rid("2026-10-05"))["isFirst"], True)

# 2. delete this occurrence -> EXDATE
s.delete(uid, rid("2026-10-12"), "this")
check("delete this", [x[0] for x in expand(s)],
      ["2026-10-05 10:00", "2026-10-19 10:00", "2026-10-26 10:00", "2026-11-02 10:00"])

# 3. edit this occurrence -> override (moved to 14:00, renamed)
s.update(uid, rid("2026-10-19"), "this", dict(weekly(title="Lab (moved)", day="2026-10-20", t="14:00"), recurrence=R.normalize({"freq": "weekly", "byday": ["MO"], "count": 5})))
check("edit this", expand(s), [("2026-10-05 10:00", "Lab"), ("2026-10-20 14:00", "Lab (moved)"),
                               ("2026-10-26 10:00", "Lab"), ("2026-11-02 10:00", "Lab")])

# 4. edit all: rename only (no time change) keeps the exception and the moved occurrence
s.update(uid, rid("2026-10-26"), "all", weekly(title="Physics lab", day="2026-10-26", count=5))
check("edit all (rename)", expand(s), [("2026-10-05 10:00", "Physics lab"), ("2026-10-20 14:00", "Lab (moved)"),
                                       ("2026-10-26 10:00", "Physics lab"), ("2026-11-02 10:00", "Physics lab")])

# 5. edit all: move every occurrence one hour later (shifts EXDATEs too, drops overrides)
s.update(uid, rid("2026-10-26"), "all", weekly(title="Physics lab", day="2026-10-26", t="11:00", count=5))
check("edit all (move +1h)", [x[0] for x in expand(s)],
      ["2026-10-05 11:00", "2026-10-19 11:00", "2026-10-26 11:00", "2026-11-02 11:00"])

# 6. this and following with a COUNT-limited rule: the remaining count moves to the new series
s = new_store()
uid = s.create(weekly(title="Seminar", day="2026-10-06", byday=["TU"], count=6))
s.update(uid, rid("2026-10-20"), "following", weekly(title="Seminar B", day="2026-10-20", t="12:00", byday=["TU"], count=6))
check("edit following (count split)", expand(s),
      [("2026-10-06 10:00", "Seminar"), ("2026-10-13 10:00", "Seminar"), ("2026-10-20 12:00", "Seminar B"),
       ("2026-10-27 12:00", "Seminar B"), ("2026-11-03 12:00", "Seminar B"), ("2026-11-10 12:00", "Seminar B")])

# 7. delete this and following
cal = icalendar.Calendar.from_ical(s.path.read_bytes())
uid2 = [str(c["UID"]) for c in cal.walk("VEVENT") if str(c["SUMMARY"]) == "Seminar B"][0]
s.delete(uid2, rid("2026-11-03", "12:00"), "following")
check("delete following", [x[0] for x in expand(s)],
      ["2026-10-06 10:00", "2026-10-13 10:00", "2026-10-20 12:00", "2026-10-27 12:00"])

# 8. a new repeat rule on "this event" turns into this-and-following (like Google)
s = new_store()
uid = s.create(weekly(title="Run", day="2026-10-05", count=None, until="2026-11-30"))
r = s.update(uid, rid("2026-10-19"), "this", dict(weekly(title="Run", day="2026-10-19"), recurrence={"freq": "daily", "count": 3}))
check("rule change on this -> following", (r, [x[0] for x in expand(s)]),
      ("updated following", ["2026-10-05 10:00", "2026-10-12 10:00", "2026-10-19 10:00", "2026-10-20 10:00", "2026-10-21 10:00"]))

# 9. delete all
s.delete(uid, rid("2026-10-12"), "all")
check("delete all (first series)", [x[0] for x in expand(s)], ["2026-10-19 10:00", "2026-10-20 10:00", "2026-10-21 10:00"])

# 10. all-day yearly + monthly "last Friday" + "every weekday" + monthly day 31
s = new_store()
u1 = s.create({"title": "Anniversary", "date": "2026-10-10", "allDay": True, "recurrence": {"freq": "yearly"}})
u2 = s.create({"title": "Review", "date": "2026-10-30", "time": "16:00", "duration": 60,
               "recurrence": {"freq": "monthly", "byday": ["-1FR"], "count": 3}})
u3 = s.create({"title": "Standup", "date": "2026-10-08", "time": "09:30", "duration": 15,
               "recurrence": {"freq": "weekly", "byday": ["MO", "TU", "WE", "TH", "FR"], "until": "2026-10-13"}})
u4 = s.create({"title": "Bills", "date": "2026-10-31", "allDay": True, "recurrence": {"freq": "monthly", "bymonthday": [31], "count": 3}})
ex = expand(s, "2026-10-01", "2027-12-31")
check("yearly all-day", [d for d, t in ex if t == "Anniversary"], ["2026-10-10", "2027-10-10"])
check("monthly last friday", [d for d, t in ex if t == "Review"], ["2026-10-30 16:00", "2026-11-27 16:00", "2026-12-25 16:00"])
check("every weekday until", [d for d, t in ex if t == "Standup"],
      ["2026-10-08 09:30", "2026-10-09 09:30", "2026-10-12 09:30", "2026-10-13 09:30"])
check("monthly day 31 skips short months", [d for d, t in ex if t == "Bills"], ["2026-10-31", "2026-12-31", "2027-01-31"])
check("describe yearly", s.get(u1, "2026-10-10")["repeat"], "Annually on October 10")
check("describe last friday", s.get(u2, rid("2026-10-30", "16:00"))["repeat"], "Monthly on the last Friday, 3 times")
check("describe weekdays", s.get(u3, "")["repeat"], "Every weekday (Monday to Friday), until Oct 13, 2026")

# 11. all-day: delete this occurrence of a yearly series
s.delete(u1, "2027-10-10", "this")
check("all-day delete this", [d for d, t in expand(s, "2026-10-01", "2028-12-31") if t == "Anniversary"], ["2026-10-10", "2028-10-10"])

# 12. in-memory store (used for Google edits) never writes a file
m = IcsStore(None, TZ)
mu = m.create(weekly(title="Mem", count=2))
m.delete(mu, rid("2026-10-12"), "this")
check("in-memory store", len([c for c in m.cal.walk("VEVENT")]), 1)

# 13. regression: "edit all" on the first part of a split series must not bring back cut occurrences
s = new_store()
uid = s.create(weekly(title="Split", day="2026-10-13", t="18:00", byday=["TU"], count=5))
s.update(uid, rid("2026-11-03", "18:00"), "following", weekly(title="Split B", day="2026-11-03", t="17:00", byday=["TU"], count=5))
check("split: first part ends the day before", s.get(uid, rid("2026-10-13", "18:00"))["recurrence"]["until"], "2026-11-02")
s.update(uid, rid("2026-10-27", "18:00"), "all", dict(s.get(uid, rid("2026-10-27", "18:00")), title="Split A"))
check("edit all after split keeps the cut", expand(s), [("2026-10-13 18:00", "Split A"), ("2026-10-20 18:00", "Split A"), ("2026-10-27 18:00", "Split A"),
                                                         ("2026-11-03 17:00", "Split B"), ("2026-11-10 17:00", "Split B")])

print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED: ' + ', '.join(FAILS)}")
sys.exit(1 if FAILS else 0)
