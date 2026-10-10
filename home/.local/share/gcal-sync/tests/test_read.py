"""Fixture tests for reading repeating events from an iCal feed (synthetic events only):
RRULE DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, BYDAY (MO,WE / 2TU / -1FR), BYMONTHDAY, COUNT, UNTIL,
EXDATE, RECURRENCE-ID overrides and cancellations, all-day, multi-day, overnight, TZID with and
without VTIMEZONE, UTC, X-WR-TIMEZONE floating times, and DST changes on both sides.
Expected values are worked out by hand (output zone Europe/Berlin).
Run: ~/.venvs/gcal/bin/python ~/.local/share/gcal-sync/tests/test_read.py"""
import datetime as dt
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import gcal_sync as S  # noqa: E402

TZ = ZoneInfo("Europe/Berlin")
FAILS = []


def check(name, got, exp):
    if got != exp:
        FAILS.append(name)
        print(f"FAIL {name}\n   got {got!r}\n   exp {exp!r}")
    else:
        print(f"ok   {name}")


VTZ_NY = """BEGIN:VTIMEZONE
TZID:America/New_York
BEGIN:DAYLIGHT
TZOFFSETFROM:-0500
TZOFFSETTO:-0400
TZNAME:EDT
DTSTART:19700308T020000
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
END:DAYLIGHT
BEGIN:STANDARD
TZOFFSETFROM:-0400
TZOFFSETTO:-0500
TZNAME:EST
DTSTART:19701101T020000
RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
END:STANDARD
END:VTIMEZONE"""


def ev(uid, summary, *lines):
    return "\n".join(["BEGIN:VEVENT", f"UID:{uid}", "DTSTAMP:20261001T000000Z", f"SUMMARY:{summary}", *lines, "END:VEVENT"])


FEED = "\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//fixture//EN", "X-WR-CALNAME:Fixture", VTZ_NY,
    # A: weekly Mon+Wed in New York, 6 times, one EXDATE, one moved instance, one cancelled instance
    ev("a@google.com", "A weekly",
       "DTSTART;TZID=America/New_York:20261019T090000", "DTEND;TZID=America/New_York:20261019T100000",
       "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6", "EXDATE;TZID=America/New_York:20261021T090000"),
    ev("a@google.com", "A moved",
       "RECURRENCE-ID;TZID=America/New_York:20261026T090000",
       "DTSTART;TZID=America/New_York:20261026T150000", "DTEND;TZID=America/New_York:20261026T160000"),
    ev("a@google.com", "A weekly",
       "RECURRENCE-ID;TZID=America/New_York:20261028T090000", "STATUS:CANCELLED",
       "DTSTART;TZID=America/New_York:20261028T090000", "DTEND;TZID=America/New_York:20261028T100000"),
    # B: second Tuesday of the month, TZID without a VTIMEZONE block, UNTIL in UTC
    ev("b@google.com", "B second tuesday",
       "DTSTART;TZID=Europe/Berlin:20261013T180000", "DTEND;TZID=Europe/Berlin:20261013T190000",
       "RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261231T225959Z"),
    # C: last Friday of the month in UTC, 3 times
    ev("c@google.com", "C last friday", "DTSTART:20261030T080000Z", "DTEND:20261030T090000Z",
       "RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3"),
    # D: all-day on day 31 (skips 30-day months)
    ev("d@google.com", "D day 31", "DTSTART;VALUE=DATE:20261031", "DTEND;VALUE=DATE:20261101",
       "RRULE:FREQ=MONTHLY;BYMONTHDAY=31"),
    # E: every 3 days, 4 times, DURATION instead of DTEND
    ev("e@google.com", "E every 3 days", "DTSTART:20261001T200000Z", "DURATION:PT30M",
       "RRULE:FREQ=DAILY;INTERVAL=3;COUNT=4"),
    # F: yearly multi-day all-day event
    ev("f@google.com", "F yearly 3 days", "DTSTART;VALUE=DATE:20261224", "DTEND;VALUE=DATE:20261227", "RRULE:FREQ=YEARLY"),
    # G: every 2 weeks on Mon+Thu until a UTC instant
    ev("g@google.com", "G biweekly", "DTSTART;TZID=Europe/Berlin:20261005T070000", "DTEND;TZID=Europe/Berlin:20261005T080000",
       "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;UNTIL=20261101T000000Z"),
    # H: single overnight event in UTC
    ev("h@google.com", "H overnight", "DTSTART:20261015T210000Z", "DTEND:20261015T233000Z"),
    # J: yearly all-day series that started long ago
    ev("j@google.com", "J yearly", "DTSTART;VALUE=DATE:20001105", "DTEND;VALUE=DATE:20001106", "RRULE:FREQ=YEARLY"),
    "END:VCALENDAR", ""]).replace("\n", "\r\n").encode()

# floating times + X-WR-TIMEZONE (how some Google exports look)
FEED_XWR = "\r\n".join([
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//fixture//EN", "X-WR-TIMEZONE:America/New_York",
    ev("x@google.com", "X floating", "DTSTART:20261020T090000", "DTEND:20261020T093000", "RRULE:FREQ=DAILY;COUNT=2"),
    "END:VCALENDAR", ""]).encode()

CFG = {"name": "Fixture", "color": "blue", "url": "https://calendar.google.com/calendar/ical/fixture/basic.ics", "id": ""}
evs, _ = S.parse_calendar(CFG, FEED, dt.date(2026, 10, 1), dt.date(2027, 1, 1), TZ)


def rows(prefix):
    out = []
    for e in evs:
        if e["title"].startswith(prefix):
            s = dt.datetime.fromisoformat(e["start"])
            out.append(e["startDate"] if e["allDay"] else s.strftime("%Y-%m-%d %H:%M"))
    return out


def one(prefix, key):
    vals = {e[key] for e in evs if e["title"].startswith(prefix)}
    return vals.pop() if len(vals) == 1 else sorted(vals)


check("A weekly NY: COUNT, EXDATE, moved, cancelled, both DST changes",
      rows("A "), ["2026-10-19 15:00", "2026-10-26 20:00", "2026-11-02 15:00", "2026-11-04 15:00"])
check("A moved instance keeps its original slot as rid",
      [e["rid"] for e in evs if e["title"] == "A moved"], ["2026-10-26T14:00:00+01:00"])
check("A repeat text", one("A weekly", "repeat"), "Weekly on Monday and Wednesday, 6 times")
check("B 2TU until (TZID without VTIMEZONE)", rows("B "), ["2026-10-13 18:00", "2026-11-10 18:00", "2026-12-08 18:00"])
check("B repeat text", one("B ", "repeat"), "Monthly on the second Tuesday, until Dec 31, 2026")
check("C -1FR in UTC", rows("C "), ["2026-10-30 09:00", "2026-11-27 09:00", "2026-12-25 09:00"])
check("C repeat text", one("C ", "repeat"), "Monthly on the last Friday, 3 times")
check("D BYMONTHDAY=31 all-day", rows("D "), ["2026-10-31", "2026-12-31"])
check("D repeat text", one("D ", "repeat"), "Monthly on day 31")
check("E INTERVAL=3 COUNT=4 with DURATION", rows("E "), ["2026-10-01 22:00", "2026-10-04 22:00", "2026-10-07 22:00", "2026-10-10 22:00"])
check("E end from DURATION", [e["end"] for e in evs if e["title"].startswith("E ")][0], "2026-10-01T22:30:00+02:00")
check("E repeat text", one("E ", "repeat"), "Every 3 days, 4 times")
check("F yearly multi-day", [(e["startDate"], e["endDate"], e["allDay"]) for e in evs if e["title"].startswith("F ")],
      [("2026-12-24", "2026-12-26", True)])
check("F repeat text", one("F ", "repeat"), "Annually on December 24")
check("G INTERVAL=2 BYDAY=MO,TH UNTIL", rows("G "), ["2026-10-05 07:00", "2026-10-08 07:00", "2026-10-19 07:00", "2026-10-22 07:00"])
# UNTIL = Nov 1 01:00 Berlin, before the 07:00 start, so the last possible day is Oct 31
check("G repeat text", one("G ", "repeat"), "Every 2 weeks on Monday and Thursday, until Oct 31, 2026")
check("H overnight spans two days", [(e["startDate"], e["endDate"], e["start"][11:16], e["end"][11:16]) for e in evs if e["title"].startswith("H ")],
      [("2026-10-15", "2026-10-16", "23:00", "01:30")])
check("H single event has no rid/repeat", (one("H ", "rid"), one("H ", "repeat"), one("H ", "recurring")), ("", "", False))
check("J yearly from 2000", rows("J "), ["2026-11-05"])
check("all-day rid is a date", [e["rid"] for e in evs if e["title"].startswith("J ")], ["2026-11-05"])
check("source/editable for a read-only Google feed", (one("A weekly", "source"), one("A weekly", "editable")), ("google", False))
check("uid kept for editing", one("C ", "uid"), "c@google.com")

xe, _ = S.parse_calendar(CFG, FEED_XWR, dt.date(2026, 10, 1), dt.date(2027, 1, 1), TZ)
check("X-WR-TIMEZONE floating times", [dt.datetime.fromisoformat(e["start"]).strftime("%m-%d %H:%M") for e in xe], ["10-20 15:00", "10-21 15:00"])

print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED: ' + ', '.join(FAILS)}")
sys.exit(1 if FAILS else 0)
