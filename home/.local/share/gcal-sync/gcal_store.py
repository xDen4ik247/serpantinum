"""Local calendar store (an .ics file) with Google-Calendar-style editing of repeating events:
create, and edit/delete "this event" / "this and following events" / "all events".

An *item* is the editor/capture shape (JSON):
  title, date "YYYY-MM-DD", time "HH:MM"|None, duration (min), allDay, days (all-day length),
  location, notes, recurrence (gcal_rec dict)|None, reminders [minutes before start]
An occurrence is addressed by (uid, rid): rid is the occurrence's original start, ISO
("2026-10-13T11:00:00+03:00", or "2026-10-13" for all-day events), "" for a single event.
"""
from __future__ import annotations

import datetime as dt
import os
import uuid
from pathlib import Path

import gcal_rec as R

SCOPES = ("this", "following", "all")


def _utcnow():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def parse_rid(rid: str | None, tz):
    """ISO string -> date / aware datetime (None for "")."""
    if not rid:
        return None
    if len(rid) == 10:
        return dt.date.fromisoformat(rid)
    v = dt.datetime.fromisoformat(rid.replace("Z", "+00:00"))
    return v if v.tzinfo else v.replace(tzinfo=tz)


def rid_str(v, tz) -> str:
    if v is None:
        return ""
    if isinstance(v, dt.datetime):
        v = v if v.tzinfo else v.replace(tzinfo=tz)
        return v.astimezone(tz).isoformat()
    return v.isoformat()


def item_times(item: dict, tz):
    """item -> (start, end, all_day) as icalendar-ready values."""
    d = dt.date.fromisoformat(item["date"])
    if item.get("time") and not item.get("allDay"):
        h, m = (int(x) for x in item["time"].split(":"))
        s = dt.datetime.combine(d, dt.time(h % 24, m), tz)
        return s, s + dt.timedelta(minutes=int(item.get("duration") or 60)), False
    return d, d + dt.timedelta(days=max(1, int(item.get("days") or 1))), True


def reminders_of(item: dict) -> list[int]:
    """Explicit reminder minutes; a capture-style {"date","time"} reminder is converted."""
    if item.get("reminders") is not None:
        out = []
        for m in item["reminders"]:
            try:
                m = int(m)
            except (TypeError, ValueError):
                continue
            if 0 <= m <= 40320 and m not in out:
                out.append(m)
        return sorted(out)
    rem = item.get("reminder")
    if rem and item.get("time") and rem.get("date") and rem.get("time"):
        start = dt.datetime.combine(dt.date.fromisoformat(item["date"]), dt.time.fromisoformat(item["time"]))
        at = dt.datetime.combine(dt.date.fromisoformat(rem["date"]), dt.time.fromisoformat(rem["time"]))
        return [max(0, int((start - at).total_seconds() // 60))]
    return []


def _same_instant(a, b) -> bool:
    if isinstance(a, dt.datetime) != isinstance(b, dt.datetime):
        a = a.date() if isinstance(a, dt.datetime) else a
        b = b.date() if isinstance(b, dt.datetime) else b
        return a == b
    if isinstance(a, dt.datetime):
        if a.tzinfo is None or b.tzinfo is None:
            return a.replace(tzinfo=None) == b.replace(tzinfo=None)
    return a == b


def _as_type_of(v, like, tz):
    """Convert an occurrence start to the value type of `like` (DTSTART): date <-> datetime."""
    if isinstance(like, dt.datetime):
        if isinstance(v, dt.datetime):
            return v.astimezone(like.tzinfo) if (like.tzinfo and v.tzinfo) else v
        return dt.datetime.combine(v, like.timetz() if like.tzinfo else like.time())
    return v.date() if isinstance(v, dt.datetime) else v


class IcsStore:
    def __init__(self, path: Path | None, tz, calname: str = "Captured", cal=None):
        """path=None keeps the calendar in memory only (`cal`); used to compute Google API edits
        with exactly the same logic as local edits."""
        self.path = Path(path) if path is not None else None
        self.tz = tz
        self.calname = calname
        self.cal = cal

    # ── file ──
    def load(self):
        import icalendar
        if self.path is None:
            if self.cal is None:
                self.cal = icalendar.Calendar()
            return self
        if self.path.exists() and self.path.stat().st_size:
            self.cal = icalendar.Calendar.from_ical(self.path.read_bytes())
        else:
            self.cal = icalendar.Calendar()
            self.cal.add("prodid", "-//gcal-sync//capture//EN")
            self.cal.add("version", "2.0")
            self.cal.add("x-wr-calname", self.calname)
        return self

    def save(self):
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_bytes(self.cal.to_ical())
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def _comps(self, uid):
        master, overrides = None, []
        for c in self.cal.subcomponents:
            if c.name == "VEVENT" and str(c.get("UID", "")) == uid:
                if "RECURRENCE-ID" in c:
                    overrides.append(c)
                else:
                    master = c
        return master, overrides

    def _remove(self, comps):
        for c in comps:
            if c in self.cal.subcomponents:
                self.cal.subcomponents.remove(c)

    # ── building ──
    def _fill(self, ev, item, start, end, keep_rrule=False):
        import icalendar
        for k in ("SUMMARY", "LOCATION", "DESCRIPTION", "DTSTART", "DTEND", "DURATION", "DTSTAMP", "LAST-MODIFIED"):
            if k in ev:
                del ev[k]
        ev.add("summary", (item.get("title") or "(no title)").strip())
        ev.add("dtstamp", _utcnow())
        ev.add("dtstart", start)
        ev.add("dtend", end)
        if (item.get("location") or "").strip():
            ev.add("location", item["location"].strip())
        if (item.get("notes") or "").strip():
            ev.add("description", item["notes"].strip())
        ev.subcomponents = [c for c in ev.subcomponents if c.name != "VALARM"]
        for m in reminders_of(item):
            al = icalendar.Alarm()
            al.add("action", "DISPLAY")
            al.add("description", (item.get("title") or "Reminder").strip())
            al.add("trigger", dt.timedelta(minutes=-m))
            ev.add_component(al)
        if not keep_rrule:
            for k in ("RRULE", "EXDATE", "RDATE"):
                if k in ev:
                    del ev[k]
            rec = R.normalize(item.get("recurrence"))
            if rec:
                ev.add("rrule", icalendar.vRecur.from_ical(R.to_rrule(rec, not isinstance(start, dt.datetime), self.tz)))

    def _new_event(self, item, uid=None):
        import icalendar
        ev = icalendar.Event()
        ev.add("uid", uid or f"{uuid.uuid4()}@gcal-sync.local")
        start, end, _ = item_times(item, self.tz)
        self._fill(ev, item, start, end)
        return ev

    # ── reading ──
    def occurrence_count_before(self, master, rid) -> int:
        """How many occurrences of the series start before `rid` (for COUNT-limited splits)."""
        import recurring_ical_events
        import icalendar
        cal = icalendar.Calendar()
        cal.add_component(master)
        start = master.decoded("DTSTART")
        lo = start if isinstance(start, dt.datetime) else start
        n = 0
        for occ in recurring_ical_events.of(cal).between(lo, rid):
            n += 1
        return n

    def get(self, uid: str, rid: str = "") -> dict | None:
        """The editable item for an occurrence (override values win) + series info."""
        self.load()
        master, overrides = self._comps(uid)
        if master is None and not overrides:
            return None
        ridv = parse_rid(rid, self.tz)
        comp = master
        for o in overrides:
            if ridv is not None and _same_instant(o.decoded("RECURRENCE-ID"), ridv):
                comp = o
        comp = comp or overrides[0]
        start = comp.decoded("DTSTART")
        end = comp.decoded("DTEND") if "DTEND" in comp else (start + comp.decoded("DURATION") if "DURATION" in comp else None)
        if comp is master and ridv is not None and master is not None and "RRULE" in master:
            # the occurrence itself: same time of day as the series, on the rid's day
            delta = (end - start) if end is not None else dt.timedelta(hours=1)
            start = _as_type_of(ridv, start, self.tz)
            end = start + delta
        item = from_component(comp, self.tz, start, end)
        rec = R.from_rrule(master.get("RRULE"), self.tz, master.decoded("DTSTART")) if master is not None and "RRULE" in master else None
        item["recurrence"] = rec
        mstart = master.decoded("DTSTART") if master is not None else None
        item["seriesStart"] = rid_str(mstart, self.tz) if mstart is not None else ""
        item["isFirst"] = bool(mstart is not None and ridv is not None and _same_instant(mstart, ridv)) or not rec
        item["uid"], item["rid"] = uid, rid or ""
        item["repeat"] = R.describe(rec, item["date"]) if rec else ""
        return item

    # ── writing ──
    def create(self, item: dict, uid: str | None = None) -> str:
        self.load()
        ev = self._new_event(item, uid)
        self.cal.add_component(ev)
        self.save()
        return str(ev["UID"])

    def _truncate_before(self, master, overrides, ridv):
        """End the series just before occurrence `ridv` (this-and-following)."""
        import icalendar
        start = master.decoded("DTSTART")
        rv = _as_type_of(ridv, start, self.tz)
        rr = dict(master["RRULE"])
        rr.pop("COUNT", None)
        if isinstance(start, dt.datetime):
            until = (rv - dt.timedelta(seconds=1)).astimezone(dt.timezone.utc)
        else:
            until = rv - dt.timedelta(days=1)
        rr["UNTIL"] = [until]
        del master["RRULE"]
        master.add("rrule", icalendar.vRecur(rr))
        self._remove([o for o in overrides if _as_type_of(o.decoded("RECURRENCE-ID"), start, self.tz) >= rv])

    def delete(self, uid: str, rid: str = "", scope: str = "all") -> str:
        self.load()
        master, overrides = self._comps(uid)
        if master is None and not overrides:
            raise KeyError(uid)
        ridv = parse_rid(rid, self.tz)
        recurring = master is not None and "RRULE" in master
        if not recurring or scope == "all" or ridv is None:
            self._remove([c for c in [master] + overrides if c is not None])
            self.save()
            return "deleted"
        start = master.decoded("DTSTART")
        rv = _as_type_of(ridv, start, self.tz)
        if scope == "following":
            if rv <= start:
                self._remove([master] + overrides)
                self.save()
                return "deleted"
            self._truncate_before(master, overrides, ridv)
            self.save()
            return "deleted following"
        # this occurrence only
        master.add("exdate", rv)
        self._remove([o for o in overrides if _same_instant(o.decoded("RECURRENCE-ID"), ridv)])
        self.save()
        return "deleted this"

    def update(self, uid: str, rid: str, scope: str, item: dict) -> str:
        import icalendar
        self.load()
        master, overrides = self._comps(uid)
        if master is None and not overrides:
            raise KeyError(uid)
        ridv = parse_rid(rid, self.tz)
        recurring = master is not None and "RRULE" in master
        new_rec = R.normalize(item.get("recurrence"))
        old_rec = R.from_rrule(master.get("RRULE"), self.tz, master.decoded("DTSTART")) if recurring else None
        start_new, end_new, all_day = item_times(item, self.tz)

        if not recurring or ridv is None:
            target = master or overrides[0]
            self._fill(target, item, start_new, end_new)
            self.save()
            return "updated"

        mstart = master.decoded("DTSTART")
        rv = _as_type_of(ridv, mstart, self.tz)
        rule_changed = _rec_key(new_rec) != _rec_key(old_rec)
        if scope == "this" and rule_changed:
            scope = "following"          # like Google: a new repeat rule never applies to one occurrence
        if scope == "following" and rv <= mstart:
            scope = "all"

        if scope == "this":
            ov = next((o for o in overrides if _same_instant(o.decoded("RECURRENCE-ID"), ridv)), None)
            if ov is None:
                ov = icalendar.Event()
                ov.add("uid", uid)
                ov.add("recurrence-id", rv)
                self.cal.add_component(ov)
            self._fill(ov, dict(item, recurrence=None), start_new, end_new)
            self.save()
            return "updated this"

        if scope == "following":
            if new_rec and new_rec.get("count") and old_rec and old_rec.get("count") and not rule_changed:
                done = self.occurrence_count_before(master, rv)
                new_rec = dict(new_rec, count=max(1, old_rec["count"] - done))
            self._truncate_before(master, overrides, ridv)
            self.cal.add_component(self._new_event(dict(item, recurrence=new_rec)))
            self.save()
            return "updated following"

        # all events: move the whole series by how much this occurrence moved
        if not new_rec:
            self._remove(overrides)
            self._fill(master, item, start_new, end_new)
            self.save()
            return "updated all"
        occ_start = rv
        if isinstance(start_new, dt.datetime) and isinstance(occ_start, dt.datetime):
            delta = start_new - occ_start
        else:
            a = start_new.date() if isinstance(start_new, dt.datetime) else start_new
            b = occ_start.date() if isinstance(occ_start, dt.datetime) else occ_start
            delta = dt.timedelta(days=(a - b).days)
        dur = end_new - start_new
        if isinstance(start_new, dt.datetime):
            base = mstart if isinstance(mstart, dt.datetime) else dt.datetime.combine(mstart, dt.time(), self.tz)
            if isinstance(mstart, dt.datetime):
                s2 = (base.astimezone(self.tz) + delta)
            else:   # all-day series becomes timed: keep its days, take the new clock time
                s2 = dt.datetime.combine(mstart + dt.timedelta(days=delta.days), start_new.timetz())
        else:
            s2 = (mstart.date() if isinstance(mstart, dt.datetime) else mstart) + dt.timedelta(days=delta.days)
        # EXDATEs follow the series; overrides keep their own data unless the times moved
        exd = []
        for prop in (master.get("EXDATE") if isinstance(master.get("EXDATE"), list) else [master.get("EXDATE")] if master.get("EXDATE") else []):
            for v in prop.dts:
                x = v.dt
                x = _as_type_of(x, mstart, self.tz)
                if isinstance(s2, dt.datetime):
                    x = (x + delta) if isinstance(x, dt.datetime) else dt.datetime.combine(x + dt.timedelta(days=delta.days), s2.timetz())
                else:
                    x = (x.date() if isinstance(x, dt.datetime) else x) + dt.timedelta(days=delta.days)
                exd.append(x)
        if delta != dt.timedelta(0) or isinstance(s2, dt.datetime) != isinstance(mstart, dt.datetime):
            self._remove(overrides)
        else:
            old_title, old_loc = str(master.get("SUMMARY", "")), str(master.get("LOCATION", ""))
            for o in overrides:   # propagate renames to occurrences that kept the series' values
                if str(o.get("SUMMARY", "")) == old_title:
                    del o["SUMMARY"]
                    o.add("summary", item.get("title") or old_title)
                if str(o.get("LOCATION", "")) == old_loc and (item.get("location") or "") != old_loc:
                    if "LOCATION" in o:
                        del o["LOCATION"]
                    if item.get("location"):
                        o.add("location", item["location"])
        if new_rec.get("until") and old_rec and new_rec.get("until") == old_rec.get("until"):
            pass
        self._fill(master, dict(item, recurrence=new_rec), s2, s2 + dur)
        for x in exd:
            master.add("exdate", x)
        self.save()
        return "updated all"


def _rec_key(rec):
    rec = R.normalize(rec)
    if not rec:
        return None
    return (rec["freq"], rec["interval"], tuple(rec["byday"]), tuple(rec["bymonthday"]), rec["count"], rec["until"])


def from_component(comp, tz, start=None, end=None) -> dict:
    """VEVENT -> item (the times of one occurrence can be passed in)."""
    start = comp.decoded("DTSTART") if start is None else start
    if end is None:
        end = comp.decoded("DTEND") if "DTEND" in comp else (start + comp.decoded("DURATION") if "DURATION" in comp else None)
    all_day = not isinstance(start, dt.datetime)
    item = {"title": str(comp.get("SUMMARY", "") or ""), "location": str(comp.get("LOCATION", "") or "") or None,
            "notes": str(comp.get("DESCRIPTION", "") or "") or None, "allDay": all_day, "kind": "event"}
    if all_day:
        item["date"] = start.isoformat()
        item["time"] = None
        item["duration"] = None
        item["days"] = max(1, ((end - start).days if end is not None else 1))
    else:
        s = start.astimezone(tz) if start.tzinfo else start.replace(tzinfo=tz)
        item["date"] = s.date().isoformat()
        item["time"] = s.strftime("%H:%M")
        e = end if end is not None else s + dt.timedelta(hours=1)
        e = e.astimezone(tz) if getattr(e, "tzinfo", None) else e.replace(tzinfo=tz)
        item["duration"] = max(1, int((e - s).total_seconds() // 60))
        item["days"] = 1
    rem = []
    for al in comp.walk("VALARM"):
        try:
            trg = al.decoded("TRIGGER")
            if isinstance(trg, dt.timedelta) and trg <= dt.timedelta(0):
                rem.append(int(-trg.total_seconds() // 60))
        except Exception:
            pass
    item["reminders"] = sorted(set(rem))
    return item
