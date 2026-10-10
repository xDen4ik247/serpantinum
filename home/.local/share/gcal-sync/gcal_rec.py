"""Recurrence helpers shared by the capture parser, the local event store and the sync.

A repeat rule is a plain dict (JSON-friendly, used by the QML UI too):
  freq        "daily" | "weekly" | "monthly" | "yearly"
  interval    int >= 1
  byday       ["MO", "TU"] (weekly) or ["2TU"] / ["-1FR"] (monthly "Nth weekday")
  bymonthday  [15] (monthly "on day 15")
  count       int | None          (ends after N occurrences)
  until       "YYYY-MM-DD" | None (last day an occurrence may start, inclusive)
  text        Obsidian Tasks-style text ("every 2 weeks on Tuesday until 2026-11-30")
"""
from __future__ import annotations

import datetime as dt
import re

WD_CODES = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
WD_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August",
               "September", "October", "November", "December"]
ORD_WORDS = {1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", -1: "last", -2: "second to last"}
FREQS = ("daily", "weekly", "monthly", "yearly")
_BYDAY_RE = re.compile(r"^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$")


def _ordinal(n: int) -> str:
    return f"{n}{'th' if 11 <= n % 100 <= 13 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def normalize(rec: dict | None) -> dict | None:
    """Validate/clean a rule dict (from the UI, the LLM or a file). None = does not repeat."""
    if not rec or not isinstance(rec, dict):
        return None
    freq = str(rec.get("freq") or "").lower()
    if freq not in FREQS:
        return None
    try:
        interval = max(1, min(999, int(rec.get("interval") or 1)))
    except (TypeError, ValueError):
        interval = 1
    byday = []
    for d in rec.get("byday") or []:
        m = _BYDAY_RE.match(str(d).upper().strip())
        if m and (freq in ("monthly", "yearly") or not m.group(1)):
            code = (str(int(m.group(1))) if m.group(1) else "") + m.group(2)
            if code not in byday:
                byday.append(code)
    if freq == "weekly":
        byday.sort(key=lambda c: WD_CODES.index(c[-2:]))
    if freq == "daily":
        byday = [c for c in byday if not _BYDAY_RE.match(c).group(1)]
    bymonthday = []
    for n in rec.get("bymonthday") or []:
        try:
            n = int(n)
        except (TypeError, ValueError):
            continue
        if 1 <= abs(n) <= 31 and n not in bymonthday:
            bymonthday.append(n)
    count = rec.get("count")
    try:
        count = int(count) if count not in (None, "", 0) else None
        if count is not None and not 1 <= count <= 9999:
            count = None
    except (TypeError, ValueError):
        count = None
    until = rec.get("until") or None
    if until:
        try:
            until = dt.date.fromisoformat(str(until)[:10]).isoformat()
        except ValueError:
            until = None
    if count:
        until = None          # RFC 5545: COUNT and UNTIL are mutually exclusive
    out = {"freq": freq, "interval": interval, "byday": byday, "bymonthday": bymonthday,
           "count": count, "until": until}
    out["text"] = tasks_text(out)
    return out


# ───────────────────────────── RRULE <-> dict ─────────────────────────────

def to_rrule(rec: dict, all_day: bool = False, tz=None) -> str:
    """dict -> RRULE value (without the "RRULE:" prefix). A timed event's UNTIL is the end of
    that local day in UTC, as RFC 5545 (and Google) require for DTSTART;TZID=… events."""
    rec = normalize(rec)
    parts = [f"FREQ={rec['freq'].upper()}"]
    if rec["interval"] > 1:
        parts.append(f"INTERVAL={rec['interval']}")
    if rec["byday"]:
        parts.append("BYDAY=" + ",".join(rec["byday"]))
    if rec["bymonthday"]:
        parts.append("BYMONTHDAY=" + ",".join(map(str, rec["bymonthday"])))
    if rec["count"]:
        parts.append(f"COUNT={rec['count']}")
    elif rec["until"]:
        d = dt.date.fromisoformat(rec["until"])
        if all_day:
            parts.append("UNTIL=" + d.strftime("%Y%m%d"))
        else:
            end = dt.datetime.combine(d, dt.time(23, 59, 59))
            end = end.replace(tzinfo=tz) if tz is not None else end.replace(tzinfo=dt.timezone.utc)
            parts.append("UNTIL=" + end.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    return ";".join(parts)


def from_rrule(value, tz=None, start=None) -> dict | None:
    """RRULE (string, "RRULE:…" line or icalendar vRecur) -> dict. Unknown parts are ignored
    (the summary then describes the closest rule we understand). `start` (the series DTSTART)
    makes a date-time UNTIL exact: "until" becomes the last day whose occurrence starts no later
    than UNTIL (a series cut at 17:59:59 before an 18:00 occurrence ends the day before)."""
    if value is None:
        return None
    if hasattr(value, "to_ical"):
        value = value.to_ical().decode()
    s = str(value).strip()
    if s.upper().startswith("RRULE:"):
        s = s[6:]
    kv = {}
    for part in s.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            kv[k.strip().upper()] = v.strip()
    rec = {"freq": kv.get("FREQ", "").lower(), "interval": kv.get("INTERVAL", 1),
           "byday": [d for d in kv.get("BYDAY", "").split(",") if d],
           "bymonthday": [d for d in kv.get("BYMONTHDAY", "").split(",") if d],
           "count": kv.get("COUNT")}
    # monthly "Nth weekday" can also be written BYDAY=TU;BYSETPOS=2
    if kv.get("BYSETPOS") and len(rec["byday"]) == 1 and rec["freq"] == "monthly":
        try:
            rec["byday"] = [f"{int(kv['BYSETPOS'])}{rec['byday'][0][-2:]}"]
        except ValueError:
            pass
    u = kv.get("UNTIL")
    if u:
        try:
            if "T" in u:
                udt = dt.datetime.strptime(u.rstrip("Z")[:15], "%Y%m%dT%H%M%S")
                if u.endswith("Z"):
                    udt = udt.replace(tzinfo=dt.timezone.utc)
                    if tz is not None:
                        udt = udt.astimezone(tz)
                day = udt.date()
                if isinstance(start, dt.datetime):
                    st = start
                    if st.tzinfo is not None and udt.tzinfo is not None:
                        st = st.astimezone(udt.tzinfo)
                    if udt.time().replace(tzinfo=None) < st.time().replace(tzinfo=None):
                        day -= dt.timedelta(days=1)
                rec["until"] = day.isoformat()
            else:
                rec["until"] = dt.datetime.strptime(u[:8], "%Y%m%d").date().isoformat()
        except ValueError:
            pass
    return normalize(rec)


# ───────────────────────────── text ─────────────────────────────

def _day_list(codes: list[str]) -> str:
    names = [WD_NAMES[WD_CODES.index(c[-2:])] for c in codes]
    if len(names) <= 2:
        return " and ".join(names)
    return ", ".join(n[:3] for n in names)


def describe(rec: dict | None, start: dt.date | str | None = None) -> str:
    """Google-Calendar-style summary: "Weekly on Tuesday", "Monthly on the last Friday",
    "Every 2 weeks on Monday and Wednesday, until Nov 30, 2026", "Annually on May 3, 5 times"."""
    rec = normalize(rec)
    if not rec:
        return "Does not repeat"
    if isinstance(start, str):
        try:
            start = dt.date.fromisoformat(start[:10])
        except ValueError:
            start = None
    n, f = rec["interval"], rec["freq"]
    unit = {"daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"}[f]
    head = {"daily": "Daily", "weekly": "Weekly", "monthly": "Monthly", "yearly": "Annually"}[f] if n == 1 else f"Every {n} {unit}s"
    tail = ""
    if f == "weekly":
        days = rec["byday"] or ([WD_CODES[start.weekday()]] if start else [])
        if days == WD_CODES[:5] and n == 1:
            head, days = "Every weekday (Monday to Friday)", []
        if days:
            tail = " on " + _day_list(days)
    elif f == "monthly":
        if rec["byday"]:
            m = _BYDAY_RE.match(rec["byday"][0])
            k = int(m.group(1) or 1)
            tail = f" on the {ORD_WORDS.get(k, _ordinal(k))} {WD_NAMES[WD_CODES.index(m.group(2))]}"
        elif rec["bymonthday"]:
            tail = " on day " + ", ".join(str(d) if d > 0 else "last" for d in rec["bymonthday"])
        elif start:
            tail = f" on day {start.day}"
    elif f == "yearly" and start:
        tail = f" on {MONTH_NAMES[start.month - 1]} {start.day}"
    elif f == "daily" and rec["byday"]:
        tail = " on " + _day_list(rec["byday"])
    out = head + tail
    if rec["count"]:
        out += ", 1 time" if rec["count"] == 1 else f", {rec['count']} times"
    elif rec["until"]:
        u = dt.date.fromisoformat(rec["until"])
        out += f", until {MONTH_NAMES[u.month - 1][:3]} {u.day}, {u.year}"
    return out


def tasks_text(rec: dict) -> str:
    """Obsidian Tasks plugin wording: "every 2 weeks on Tuesday", "every month on the last Friday"."""
    n, f = rec["interval"], rec["freq"]
    unit = {"daily": "day", "weekly": "week", "monthly": "month", "yearly": "year"}[f]
    s = f"every {unit}" if n == 1 else f"every {n} {unit}s"
    if f == "weekly" and rec["byday"] == WD_CODES[:5] and n == 1:
        s = "every weekday"
    elif f == "weekly" and rec["byday"]:
        s += " on " + ", ".join(WD_NAMES[WD_CODES.index(c)] for c in rec["byday"])
    elif f == "monthly" and rec["byday"]:
        m = _BYDAY_RE.match(rec["byday"][0])
        k = int(m.group(1) or 1)
        s += f" on the {ORD_WORDS.get(k, _ordinal(k))} {WD_NAMES[WD_CODES.index(m.group(2))]}"
    elif f == "monthly" and rec["bymonthday"]:
        s += " on the " + ", ".join(_ordinal(d) if d > 0 else "last" for d in rec["bymonthday"])
    if rec.get("count"):
        s += f" for {rec['count']} times"
    elif rec.get("until"):
        s += f" until {rec['until']}"
    return s


# ───────────────────────────── occurrences ─────────────────────────────

def _rrule_obj(rec: dict, start: dt.datetime):
    from dateutil import rrule as R
    rec = normalize(rec)
    kw = {"dtstart": start, "interval": rec["interval"]}
    wd = [R.MO, R.TU, R.WE, R.TH, R.FR, R.SA, R.SU]
    if rec["byday"]:
        days = []
        for c in rec["byday"]:
            m = _BYDAY_RE.match(c)
            w = wd[WD_CODES.index(m.group(2))]
            days.append(w(int(m.group(1))) if m.group(1) else w)
        kw["byweekday"] = days
    if rec["bymonthday"]:
        kw["bymonthday"] = rec["bymonthday"]
    if rec["count"]:
        kw["count"] = rec["count"]
    elif rec["until"]:
        kw["until"] = dt.datetime.combine(dt.date.fromisoformat(rec["until"]), dt.time(23, 59, 59))
    freq = {"daily": R.DAILY, "weekly": R.WEEKLY, "monthly": R.MONTHLY, "yearly": R.YEARLY}[rec["freq"]]
    return R.rrule(freq, **kw)


def first_on_or_after(rec: dict, start: dt.date, t: str | None, not_before: dt.datetime | None = None) -> dt.date:
    """First day >= start (and, with a clock time, not before `not_before`) on which the rule
    fires. Used to move a new series' start onto a real occurrence ("last Friday of the month")."""
    rec = normalize(rec)
    if not rec:
        return start
    hh, mm = (int(x) for x in (t or "00:00").split(":"))
    probe = dict(rec, count=None, until=None, interval=1)   # the series is anchored on its first matching day
    begin = dt.datetime.combine(start, dt.time(hh % 24, mm))
    if rec["freq"] == "weekly" and not rec["byday"]:
        probe["byday"] = [WD_CODES[start.weekday()]]
    try:
        it = iter(_rrule_obj(probe, begin))
        for _ in range(400):
            occ = next(it)
            if not_before is None or t is None or occ >= not_before:
                return occ.date()
    except StopIteration:
        pass
    return start


def occurrences(rec: dict, start: dt.date, limit: int = 10) -> list[str]:
    """The first `limit` occurrence dates of a series starting on `start` (for tests/previews)."""
    out = []
    probe = normalize(rec)
    if probe["freq"] == "weekly" and not probe["byday"]:
        probe["byday"] = [WD_CODES[start.weekday()]]
    for occ in _rrule_obj(probe, dt.datetime.combine(start, dt.time())):
        out.append(occ.date().isoformat())
        if len(out) >= limit:
            break
    return out
