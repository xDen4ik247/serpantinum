#!/usr/bin/env python3
"""gcal-sync: Google Calendar (secret iCal links) + Obsidian -> one JSON file for the desktop.

Reads   ~/.config/gcal-sync/calendars.conf   (mode 600, written by `gcal-setup`)
Writes  ~/.cache/gcal-sync/events.json       (read by the Serpantinum calendar widget / agenda panel)

Subcommands
  run              fetch calendars when due (every `interval` minutes), rescan Obsidian,
                   write events.json, send event reminders (systemd timer runs this every minute)
  sync             like run, but always refetch the calendars
  daily [--date D] [--no-open]
                   open (create if missing) the Obsidian daily note for today / date D
  capture TEXT     append "- [ ] TEXT" to the vault inbox (if one exists) or today's daily note
  event TEXT       (optional, needs gcalcli + one-time OAuth) quick-add a Google event
  setup | list | remove NAME   manage calendars (see gcal-setup)
  status           print a short status
"""
from __future__ import annotations

import argparse
import base64
import configparser
import contextlib
import datetime as dt
import fcntl
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

HOME = Path.home()
CONF_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "gcal-sync"
CONF = Path(os.environ.get("GCAL_SYNC_CONF", CONF_DIR / "calendars.conf"))
CACHE = Path(os.environ.get("GCAL_SYNC_CACHE", Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "gcal-sync"))
OUT = CACHE / "events.json"
STATE = CACHE / "state.json"
PARSED = CACHE / "gcal-parsed.json"
RAW_DIR = CACHE / "raw"
SERP_SETTINGS = HOME / ".config/serpantinum/settings.json"
GCALCLI_TOKEN = HOME / ".local/share/gcalcli/oauth"
LOCAL_ICS = Path(os.environ.get("GCAL_SYNC_LOCAL_ICS", HOME / ".local/share/gcal-sync/local-events.ics"))

PARSER_VERSION = 3  # bump to invalidate cached parses
PALETTE = ["blue", "mauve", "teal", "peach", "pink", "green", "yellow", "sapphire"]
SETTINGS_SECTION = "gcal-sync"
DEFAULTS = {
    "vault": "~/Obsidian/Vault",
    "vault_name": "",
    "days": "60",
    "past_days": "35",
    "interval": "5",
    "remind_minutes": "10",
    "reminders": "yes",
    "timezone": "",
    "capture": "auto",
    "llm_url": "http://127.0.0.1:8765",
    "llm": "auto",
    "local_color": "teal",
}


# ───────────────────────────── helpers ─────────────────────────────

def log(*a):
    print(*a, file=sys.stderr)


def mask_url(url: str) -> str:
    """Never print secrets: hide the private token of an iCal link."""
    u = re.sub(r"(private-)[0-9a-fA-F]+", r"\1••••", url)
    u = re.sub(r"([?&](?:token|key|secret|auth)[^=]*=)[^&]+", r"\1••••", u, flags=re.I)
    if u == url and len(u) > 60 and u.startswith("http"):
        u = u[:40] + "…"
    return u


def atomic_write(path: Path, data: str | bytes, mode: int = 0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


@contextlib.contextmanager
def locked(timeout=30.0):
    CACHE.mkdir(parents=True, exist_ok=True)
    os.chmod(CACHE, 0o700)
    fd = os.open(CACHE / ".lock", os.O_CREAT | os.O_RDWR, 0o600)
    t0 = time.monotonic()
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() - t0 > timeout:
                os.close(fd)
                raise SystemExit("gcal-sync: another run is still busy")
            time.sleep(0.1)
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def local_tz(settings) -> ZoneInfo:
    name = settings.get("timezone") or ""
    if not name:
        try:
            name = os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[1]
        except Exception:
            name = "UTC"
    try:
        return ZoneInfo(name)
    except Exception:
        return ZoneInfo("UTC")


# ───────────────────────────── config ─────────────────────────────

def read_conf():
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str
    if CONF.exists():
        cp.read(CONF)
    settings = dict(DEFAULTS)
    if cp.has_section(SETTINGS_SECTION):
        settings.update({k: v.strip() for k, v in cp.items(SETTINGS_SECTION)})
    cals = []
    for i, sec in enumerate(s for s in cp.sections() if s != SETTINGS_SECTION):
        url = cp.get(sec, "url", fallback="").strip()
        if not url:
            continue
        cals.append({
            "name": sec,
            "url": url,
            "color": cp.get(sec, "color", fallback="").strip() or PALETTE[i % len(PALETTE)],
            "id": cp.get(sec, "id", fallback="").strip(),
            "enabled": cp.get(sec, "enabled", fallback="yes").strip().lower() not in ("no", "false", "0", "off"),
        })
    if LOCAL_ICS.exists():
        cals.append({"name": "Captured", "url": LOCAL_ICS.as_uri(), "color": settings["local_color"], "id": "",
                     "enabled": True, "local": True})
    vault = Path(os.path.expanduser(settings["vault"]))
    settings["vault_path"] = vault
    settings["vault_name"] = settings["vault_name"] or vault.name
    return cp, settings, cals


def write_conf(cp: configparser.ConfigParser):
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONF_DIR, 0o700)
    import io
    buf = io.StringIO()
    buf.write("# gcal-sync calendars (managed by `gcal-setup`; safe to edit by hand).\n"
              "# Each [section] is one calendar: url = secret iCal address, color = theme name\n"
              "# (blue mauve teal peach pink green yellow sapphire red) or #rrggbb, enabled = yes/no.\n"
              "# Keep this file private (mode 600): the URLs give read access to your calendar.\n\n")
    cp.write(buf)
    atomic_write(CONF, buf.getvalue(), 0o600)


# ───────────────────────────── fetching ─────────────────────────────

def raw_path(url: str) -> Path:
    return RAW_DIR / (hashlib.sha256(url.encode()).hexdigest()[:20] + ".ics")


def normalize_url(url: str) -> str:
    url = url.strip()
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    if url.startswith("/") or url.startswith("~"):
        url = "file://" + os.path.expanduser(url)
    return url


def looks_like_ics(data: bytes) -> bool:
    return data.lstrip(b"\xef\xbb\xbf \r\n\t").upper().startswith(b"BEGIN:VCALENDAR")


def fetch(url: str, meta: dict, timeout=25) -> tuple[bool, str | None]:
    """Fetch one calendar into the raw cache. Returns (changed, error)."""
    real = normalize_url(url)
    dest = raw_path(url)
    headers = {"User-Agent": "gcal-sync/1.0 (+desktop)", "Accept": "text/calendar, */*"}
    if dest.exists() and real.startswith("http"):
        if meta.get("etag"):
            headers["If-None-Match"] = meta["etag"]
        if meta.get("last_modified"):
            headers["If-Modified-Since"] = meta["last_modified"]
    req = urllib.request.Request(real, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
            etag = r.headers.get("ETag") if hasattr(r, "headers") else None
            lm = r.headers.get("Last-Modified") if hasattr(r, "headers") else None
    except urllib.error.HTTPError as e:
        if e.code == 304:
            return False, None
        if e.code in (401, 403, 404):
            return False, f"HTTP {e.code}: link not valid any more (re-copy the secret address)"
        return False, f"HTTP {e.code}"
    except urllib.error.URLError as e:
        return False, f"offline ({getattr(e, 'reason', e)})"
    except Exception as e:  # timeouts etc.
        return False, f"{type(e).__name__}: {e}"
    if not looks_like_ics(data):
        return False, "not an iCal feed (did you paste the 'Secret address in iCal format'?)"
    meta["etag"] = etag or ""
    meta["last_modified"] = lm or ""
    old = dest.read_bytes() if dest.exists() else None
    if old == data:
        return False, None
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(RAW_DIR, 0o700)
    atomic_write(dest, data, 0o600)
    return True, None


# ───────────────────────────── ICS parsing ─────────────────────────────

MEET_RE = re.compile(r"https://(?:meet\.google\.com/[a-z0-9-]+|[\w.-]*zoom\.us/[^\s<>\"']+|teams\.microsoft\.com/[^\s<>\"']+|telemost\.yandex\.ru/[^\s<>\"']+)", re.I)


def google_calendar_id(url: str, explicit: str) -> str:
    if explicit:
        return explicit
    m = re.search(r"/calendar/ical/([^/]+)/", url)
    return urllib.parse.unquote(m.group(1)) if m else ""


def google_event_link(uid: str, calid: str, recurrence: dt.date | dt.datetime | None, is_recurring: bool) -> str:
    if not calid or not uid.endswith("@google.com"):
        return ""
    eid = uid[: -len("@google.com")]
    if is_recurring and recurrence is not None:
        if isinstance(recurrence, dt.datetime):
            r = recurrence.astimezone(dt.timezone.utc) if recurrence.tzinfo else recurrence
            eid += "_" + r.strftime("%Y%m%dT%H%M%SZ")
        else:
            eid += "_" + recurrence.strftime("%Y%m%d")
    token = base64.urlsafe_b64encode(f"{eid} {calid}".encode()).decode().rstrip("=")
    return "https://calendar.google.com/calendar/event?eid=" + token


def day_link(d: dt.date) -> str:
    return f"https://calendar.google.com/calendar/r/day/{d.year}/{d.month}/{d.day}"


def to_local(v, tz):
    """date stays date; naive datetime = floating local time; aware -> local."""
    if isinstance(v, dt.datetime):
        if v.tzinfo is None:
            return v.replace(tzinfo=tz)
        return v.astimezone(tz)
    return v


def parse_calendar(cal_cfg: dict, data: bytes, win_start: dt.date, win_end: dt.date, tz) -> tuple[list, str]:
    import icalendar
    import recurring_ical_events
    try:
        import x_wr_timezone
    except Exception:  # optional
        x_wr_timezone = None

    cal = icalendar.Calendar.from_ical(data)
    feed_name = str(cal.get("X-WR-CALNAME", "") or "")
    if x_wr_timezone is not None:
        try:
            cal = x_wr_timezone.to_standard(cal)
        except Exception:
            pass
    calid = google_calendar_id(cal_cfg["url"], cal_cfg.get("id", ""))
    out = []
    # UIDs that belong to a recurring series (the library tags every occurrence with RECURRENCE-ID)
    rec_uids = {str(c.get("UID", "")) for c in cal.walk("VEVENT")
                if "RRULE" in c or "RDATE" in c or "RECURRENCE-ID" in c}
    query = recurring_ical_events.of(cal, skip_bad_series=True)
    for ev in query.between(win_start, win_end):
        if str(ev.get("STATUS", "")).upper() == "CANCELLED":
            continue
        try:
            start = ev.decoded("DTSTART")
        except Exception:
            continue
        if "DTEND" in ev:
            end = ev.decoded("DTEND")
        elif "DURATION" in ev:
            end = start + ev.decoded("DURATION")
        else:
            end = start + dt.timedelta(days=1) if not isinstance(start, dt.datetime) else start
        all_day = not isinstance(start, dt.datetime)
        start = to_local(start, tz)
        end = to_local(end, tz)
        if all_day and isinstance(end, dt.datetime):
            end = end.date()
        if all_day:
            if end <= start:
                end = start + dt.timedelta(days=1)
            s_dt = dt.datetime.combine(start, dt.time(), tz)
            e_dt = dt.datetime.combine(end, dt.time(), tz)
            first, last = start, end - dt.timedelta(days=1)
        else:
            if end < start:
                end = start
            s_dt, e_dt = start, end
            first = start.date()
            # an event ending exactly at midnight does not occupy the next day
            last = (end - dt.timedelta(microseconds=1)).date() if end > start else start.date()
        uid = str(ev.get("UID", ""))
        rid = ev.get("RECURRENCE-ID")
        rid_v = rid.dt if rid is not None else None
        is_rec = uid in rec_uids
        title = str(ev.get("SUMMARY", "") or "").strip() or "(no title)"
        location = str(ev.get("LOCATION", "") or "").strip()
        desc = str(ev.get("DESCRIPTION", "") or "")
        url_prop = str(ev.get("URL", "") or "")
        meet = ""
        conf = str(ev.get("X-GOOGLE-CONFERENCE", "") or "")
        for src in (conf, location, desc, url_prop):
            m = MEET_RE.search(src)
            if m:
                meet = m.group(0).rstrip(".,)")
                break
        link = google_event_link(uid, calid, rid_v if rid_v is not None else ev.decoded("DTSTART"), is_rec) \
            or (url_prop if url_prop.startswith("http") else "") or day_link(first)
        alarms = []
        for al in ev.walk("VALARM") if hasattr(ev, "walk") else []:
            try:
                trg = al.decoded("TRIGGER")
                if isinstance(trg, dt.timedelta) and trg <= dt.timedelta(0):
                    alarms.append(int(-trg.total_seconds() // 60))
            except Exception:
                pass
        key_src = f"{cal_cfg['name']}|{uid}|{s_dt.isoformat()}"
        out.append({
            "id": hashlib.sha1(key_src.encode()).hexdigest()[:16],
            "title": title,
            "start": s_dt.isoformat(),
            "end": e_dt.isoformat(),
            "startMs": int(s_dt.timestamp() * 1000),
            "endMs": int(e_dt.timestamp() * 1000),
            "startDate": first.isoformat(),
            "endDate": last.isoformat(),
            "allDay": all_day,
            "location": location,
            "meet": meet,
            "url": link,
            "calendar": cal_cfg["name"],
            "color": cal_cfg["color"],
            "recurring": bool(is_rec),
            "busy": str(ev.get("TRANSP", "OPAQUE")).upper() != "TRANSPARENT",
            "alarms": sorted(set(alarms)),
            "local": bool(cal_cfg.get("local")),
        })
    return out, feed_name


# ───────────────────────────── Obsidian ─────────────────────────────

MOMENT_TOKENS = [
    ("YYYY", lambda d: f"{d.year:04d}"), ("YY", lambda d: f"{d.year % 100:02d}"),
    ("MMMM", lambda d: d.strftime("%B")), ("MMM", lambda d: d.strftime("%b")),
    ("MM", lambda d: f"{d.month:02d}"), ("M", lambda d: str(d.month)),
    ("DDDD", lambda d: f"{d.timetuple().tm_yday:03d}"), ("DDD", lambda d: str(d.timetuple().tm_yday)),
    ("Do", lambda d: str(d.day) + ("th" if 11 <= d.day <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(d.day % 10, "th"))),
    ("DD", lambda d: f"{d.day:02d}"), ("D", lambda d: str(d.day)),
    ("dddd", lambda d: d.strftime("%A")), ("ddd", lambda d: d.strftime("%a")),
    ("dd", lambda d: d.strftime("%a")[:2]), ("d", lambda d: str(d.isoweekday() % 7)),
    ("E", lambda d: str(d.isoweekday())),
    ("GGGG", lambda d: f"{d.isocalendar()[0]:04d}"), ("WW", lambda d: f"{d.isocalendar()[1]:02d}"),
    ("W", lambda d: str(d.isocalendar()[1])), ("ww", lambda d: f"{d.isocalendar()[1]:02d}"),
    ("w", lambda d: str(d.isocalendar()[1])), ("Q", lambda d: str((d.month - 1) // 3 + 1)),
]


def moment_format(fmt: str, d: dt.date) -> str:
    out, i = [], 0
    while i < len(fmt):
        if fmt[i] == "[":
            j = fmt.find("]", i)
            if j < 0:
                out.append(fmt[i + 1:]); break
            out.append(fmt[i + 1:j]); i = j + 1; continue
        for tok, fn in MOMENT_TOKENS:
            if fmt.startswith(tok, i):
                out.append(fn(d)); i += len(tok); break
        else:
            out.append(fmt[i]); i += 1
    return "".join(out)


_DAILY_CFG: dict = {}


def daily_config(vault: Path) -> dict:
    """Obsidian's daily-notes settings; read once and reused until the file changes
    (daily_relpath() asks for it ~100x per build)."""
    f = vault / ".obsidian/daily-notes.json"
    try:
        mt = f.stat().st_mtime_ns
    except OSError:
        mt = 0
    hit = _DAILY_CFG.get(str(vault))
    if hit and hit[0] == mt:
        return hit[1]
    cfg = load_json(f, {})
    c = {
        "folder": (cfg.get("folder") or "").strip("/"),
        "format": cfg.get("format") or "YYYY-MM-DD",
        "template": (cfg.get("template") or "").strip(),
    }
    _DAILY_CFG[str(vault)] = (mt, c)
    return c


def daily_relpath(vault: Path, d: dt.date) -> str:
    c = daily_config(vault)
    name = moment_format(c["format"], d) + ".md"
    return f"{c['folder']}/{name}" if c["folder"] else name


def obsidian_uri(vault_name: str, relpath: str) -> str:
    rel = relpath[:-3] if relpath.endswith(".md") else relpath
    return "obsidian://open?vault=" + urllib.parse.quote(vault_name, safe="") + "&file=" + urllib.parse.quote(rel, safe="")


DATE = r"(\d{4}-\d{2}-\d{2})"
TAG_RE = re.compile(r"(?<![\w&/#])(#[A-Za-zА-Яа-яЁё][\w/-]{1,40})")
TASK_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[( |/)\]\s+(.*)$")
DUE_PATTERNS = [
    ("due", re.compile(r"📅\s*" + DATE)),
    ("due", re.compile(r"\[due::\s*" + DATE + r"\]", re.I)),
    ("due", re.compile(r"(?<![\w\[])due::?\s*" + DATE, re.I)),
    ("due", re.compile(r"@due\(" + DATE + r"\)", re.I)),
    ("reminder", re.compile(r"\(@" + DATE + r"(?:\s+(\d{1,2}:\d{2}))?\)")),
    ("scheduled", re.compile(r"⏳\s*" + DATE)),
    ("scheduled", re.compile(r"\[scheduled::\s*" + DATE + r"\]", re.I)),
]
STRIP_RES = [
    re.compile(r"[📅⏳🛫➕✅❌]\s*\d{4}-\d{2}-\d{2}"),
    re.compile(r"🔁[^📅⏳🛫➕✅❌⏫🔼🔽🔺⏬]*"),
    re.compile(r"\[(?:due|scheduled|start|created|completion|priority|repeat)::[^\]]*\]", re.I),
    re.compile(r"(?<![\w\[])due::?\s*\d{4}-\d{2}-\d{2}", re.I),
    re.compile(r"@due\([^)]*\)", re.I),
    re.compile(r"\(@\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2})?\)"),
    re.compile(r"\s\^[\w-]+\s*$"),
    re.compile(r"[⏫🔼🔽🔺⏬]"),
    re.compile(r"%%.*?%%"),
]


def clean_task_text(t: str) -> str:
    for r in STRIP_RES:
        t = r.sub("", t)
    t = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", r"\2", t)
    t = re.sub(r"\[\[([^\]]+)\]\]", lambda m: m.group(1).split("/")[-1].split("#")[0], t)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)
    return re.sub(r"\s{2,}", " ", t).strip() or "(empty task)"


def priority_of(t: str) -> int:
    for ch, p in (("🔺", 3), ("⏫", 2), ("🔼", 1), ("🔽", -1), ("⏬", -2)):
        if ch in t:
            return p
    return 0


VAULT_SCAN = CACHE / "vault-scan.json"
VAULT_SCAN_VERSION = 1


def _scan_note(text: str) -> dict:
    """Date-independent facts of one note (cached by mtime): its tags and open-task lines."""
    tags = TAG_RE.findall(text)
    fm = re.match(r"---\n(.*?)\n---", text, re.S)
    if fm:
        mt = re.search(r"^tags:\s*\[([^\]]*)\]", fm.group(1), re.M)
        for tg in (mt.group(1).split(",") if mt else []):
            tg = "#" + tg.strip().strip("'\"").lstrip("#")
            if len(tg) > 1:
                tags.append(tg)
    tasks = []
    if "[ ]" in text or "[/]" in text:
        in_fence = False
        for ln, line in enumerate(text.splitlines(), 1):
            st = line.lstrip()
            if st.startswith("```") or st.startswith("~~~"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            m = TASK_RE.match(line)
            # captured events live in local-events.ics; their task line would only duplicate them
            if m and "%%gcal:" not in m.group(2):
                tasks.append([ln, m.group(1) == "/", m.group(2)])
    return {"tags": tags, "tasks": tasks}


def _valid_hhmm(s: str) -> str | None:
    """'9:30' -> '09:30'; None for impossible times like 9:75 or 25:00 (24:00 is allowed)."""
    try:
        hh, mi = map(int, s.split(":"))
    except ValueError:
        return None
    return f"{hh:02d}:{mi:02d}" if 0 <= hh <= 24 and 0 <= mi <= 59 and not (hh == 24 and mi) else None


def scan_vault(settings, today: dt.date, win_start: dt.date, win_end: dt.date, tz):
    vault: Path = settings["vault_path"]
    vname = settings["vault_name"]
    info = {"vault": str(vault), "vaultName": vname, "ok": vault.is_dir()}
    if not vault.is_dir():
        return [], {}, info
    today_rel = daily_relpath(vault, today)
    # per-note results are cached by (mtime, size): unchanged notes are not re-read every minute
    cache = load_json(VAULT_SCAN, {})
    if cache.get("v") != VAULT_SCAN_VERSION or cache.get("vault") != str(vault):
        cache = {"v": VAULT_SCAN_VERSION, "vault": str(vault), "files": {}}
    files, seen, dirty = cache["files"], set(), False
    tasks = []
    tag_count, notes = {}, []
    for root, dirs, fnames in os.walk(vault):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules",)]
        for fn in fnames:
            if not fn.endswith(".md"):
                continue
            p = Path(root) / fn
            rel = os.path.relpath(p, vault)
            try:
                stt = p.stat()
            except OSError:
                continue
            seen.add(rel)
            ent = files.get(rel)
            if not ent or ent.get("m") != stt.st_mtime_ns or ent.get("s") != stt.st_size:
                try:
                    text = p.read_text(encoding="utf-8", errors="replace")
                except Exception:
                    continue
                ent = files[rel] = {"m": stt.st_mtime_ns, "s": stt.st_size, **_scan_note(text)}
                dirty = True
            if not rel.startswith(("raw/",)):
                for tg in ent["tags"]:
                    tag_count[tg] = tag_count.get(tg, 0) + 1
                notes.append((stt.st_mtime, p.stem))
            for ln, in_progress, body in ent["tasks"]:
                due, kind, time_s, rem = None, None, "", None
                for k, rx in DUE_PATTERNS:
                    mm = rx.search(body)
                    if not mm:
                        continue
                    try:
                        dd = dt.date.fromisoformat(mm.group(1))
                    except ValueError:
                        continue
                    if k == "reminder":
                        # a malformed time (9:75) is ignored instead of aborting the whole build
                        hhmm = _valid_hhmm(mm.group(2)) if mm.lastindex and mm.lastindex >= 2 and mm.group(2) else None
                        if hhmm:
                            rem = (dd, hhmm)
                        if due is not None:
                            continue
                    if due is None:
                        due, kind = dd, k
                if due is None and rel == today_rel:
                    due, kind = today, "daily"
                if due is None or due > win_end:
                    continue
                if rem and rem[0] == due:
                    time_s = rem[1]
                item = {
                    "text": clean_task_text(body),
                    "due": due.isoformat(),
                    "time": time_s,
                    "kind": kind,
                    "file": rel,
                    "note": p.stem,
                    "line": ln,
                    "uri": obsidian_uri(vname, rel),
                    "overdue": due < today,
                    "inProgress": in_progress,
                    "priority": priority_of(body),
                }
                if rem:
                    hh, mi = map(int, rem[1].split(":"))
                    item["atMs"] = int(dt.datetime.combine(rem[0], dt.time(hh % 24, mi), tz).timestamp() * 1000)
                tasks.append(item)
    for rel in [r for r in files if r not in seen]:
        del files[rel]
        dirty = True
    if dirty or not VAULT_SCAN.exists():
        try:
            atomic_write(VAULT_SCAN, json.dumps(cache, ensure_ascii=False), 0o600)
        except OSError as e:
            log(f"vault scan cache not written: {e}")
    tasks.sort(key=lambda t: (t["due"], t["time"] or "99", -t["priority"], t["text"].lower()))
    daily = {}
    d = win_start
    while d <= win_end:
        rel = daily_relpath(vault, d)
        if (vault / rel).exists():
            daily[d.isoformat()] = {"file": rel, "uri": obsidian_uri(vname, rel)}
        d += dt.timedelta(days=1)
    info.update({
        "dailyFolder": daily_config(vault)["folder"],
        "todayNote": today_rel,
        "todayExists": (vault / today_rel).exists(),
        "todayUri": obsidian_uri(vname, today_rel),
        "inbox": find_inbox(vault) or "",
        "tags": [t for t, _ in sorted(tag_count.items(), key=lambda kv: -kv[1])[:40]],
        "notes": [n for _, n in sorted(notes, reverse=True)[:30]],
    })
    return tasks, daily, info


def find_inbox(vault: Path) -> str | None:
    for cand in ("Inbox.md", "inbox.md", "INBOX.md", "00 Inbox.md", "0. Inbox.md", "Inbox/Inbox.md", "inbox/inbox.md"):
        if (vault / cand).is_file():
            return cand
    return None


def ensure_daily(settings, d: dt.date, tz) -> tuple[Path, str, bool]:
    vault: Path = settings["vault_path"]
    rel = daily_relpath(vault, d)
    path = vault / rel
    created = False
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        content = ""
        tpl = daily_config(vault)["template"]
        if tpl:
            tp = vault / (tpl if tpl.endswith(".md") else tpl + ".md")
            if tp.is_file():
                now = dt.datetime.now(tz)
                content = tp.read_text(encoding="utf-8", errors="replace")
                content = re.sub(r"\{\{\s*date(?::([^}]+))?\s*\}\}",
                                 lambda m: moment_format(m.group(1) or "YYYY-MM-DD", d), content)
                content = re.sub(r"\{\{\s*time(?::([^}]+))?\s*\}\}",
                                 lambda m: now.strftime("%H:%M") if not m.group(1) else moment_format(m.group(1), now), content)
                content = re.sub(r"\{\{\s*title\s*\}\}", path.stem, content)
        with open(path, "x", encoding="utf-8") as f:
            f.write(content)
        created = True
    return path, rel, created


# ───────────────────────────── pipeline ─────────────────────────────

def window(today: dt.date, settings):
    past = int(settings.get("past_days", 35))
    days = int(settings.get("days", 60))
    start = min(today.replace(day=1) - dt.timedelta(days=7), today - dt.timedelta(days=past))
    return start, today + dt.timedelta(days=days)


def build(force_fetch=False, quiet=False):
    cp, settings, cals = read_conf()
    tz = local_tz(settings)
    now = dt.datetime.now(tz)
    today = now.date()
    win_start, win_end = window(today, settings)
    state = load_json(STATE, {})
    feeds = state.setdefault("feeds", {})
    parsed = load_json(PARSED, {})

    interval = max(1, int(settings.get("interval", 5))) * 60
    cal_status = []
    events = []
    any_change = False
    for cal in cals:
        key = hashlib.sha256(cal["url"].encode()).hexdigest()[:20]
        meta = feeds.setdefault(key, {})
        st = {"name": cal["name"], "color": cal["color"], "enabled": cal["enabled"], "ok": True, "error": "", "lastSync": meta.get("lastOk", 0), "local": bool(cal.get("local"))}
        if not cal["enabled"]:
            cal_status.append(st)
            continue
        due = force_fetch or cal.get("local") or (time.time() - meta.get("lastTry", 0) >= interval) or not raw_path(cal["url"]).exists()
        changed = False
        if due:
            meta["lastTry"] = time.time()
            changed, err = fetch(cal["url"], meta)
            if err:
                meta["error"] = err
                if not quiet:
                    log(f"[{cal['name']}] {err}")
            else:
                meta["error"] = ""
                meta["lastOk"] = time.time()
                st["lastSync"] = meta["lastOk"]
        st["error"] = meta.get("error", "")
        st["ok"] = not st["error"]
        rp = raw_path(cal["url"])
        # (re)parse when the feed changed, the window moved, or the calendar's settings changed
        sig = f"v{PARSER_VERSION}|{key}|{win_start}|{win_end}|{cal['name']}|{cal['color']}|{cal.get('id','')}|{tz.key}|{rp.stat().st_mtime if rp.exists() else 0}"
        entry = parsed.get(key)
        if rp.exists() and (changed or not entry or entry.get("sig") != sig):
            try:
                evs, feed_name = parse_calendar(cal, rp.read_bytes(), win_start, win_end, tz)
                entry = parsed[key] = {"sig": sig, "events": evs, "feedName": feed_name}
                any_change = True
            except Exception as e:
                st["ok"], st["error"] = False, f"parse error: {type(e).__name__}: {e}"
                if not quiet:
                    log(f"[{cal['name']}] {st['error']}")
        if entry:
            events.extend(entry["events"])
            st["feedName"] = entry.get("feedName", "")
            st["count"] = len(entry["events"])
        cal_status.append(st)
    keep = {hashlib.sha256(c["url"].encode()).hexdigest()[:20] for c in cals}
    for k in list(parsed):
        if k not in keep:
            del parsed[k]; any_change = True
    if any_change or not PARSED.exists():
        atomic_write(PARSED, json.dumps(parsed, ensure_ascii=False), 0o600)

    events.sort(key=lambda e: (e["startDate"], not e["allDay"], e["startMs"], e["title"].lower()))
    tasks, daily, vinfo = scan_vault(settings, today, win_start, win_end, tz)

    days = {}
    for e in events:
        d = dt.date.fromisoformat(e["startDate"])
        last = dt.date.fromisoformat(e["endDate"])
        while d <= last:
            k = d.isoformat()
            slot = days.setdefault(k, {"events": 0, "tasks": 0, "colors": []})
            slot["events"] += 1
            if e["color"] not in slot["colors"] and len(slot["colors"]) < 3:
                slot["colors"].append(e["color"])
            d += dt.timedelta(days=1)
    for t in tasks:
        k = t["due"] if not t["overdue"] else today.isoformat()
        days.setdefault(k, {"events": 0, "tasks": 0, "colors": []})["tasks"] += 1

    write_enabled = bool(shutil.which("gcalcli") or (Path(sys.prefix) / "bin/gcalcli").exists()) and GCALCLI_TOKEN.exists()
    doc = {
        "version": 1,
        "today": today.isoformat(),
        "tz": tz.key,
        "range": [win_start.isoformat(), win_end.isoformat()],
        "configured": any(not c.get("local") for c in cals),
        "calendars": cal_status,
        "writeEnabled": write_enabled,
        "obsidian": vinfo,
        "events": events,
        "tasks": tasks,
        "daily": daily,
        "days": days,
    }
    body = json.dumps(doc, ensure_ascii=False, sort_keys=True)
    old = load_json(OUT, {})
    old.pop("generated", None)
    if json.dumps(old, ensure_ascii=False, sort_keys=True) != body:
        doc["generated"] = now.isoformat(timespec="seconds")
        atomic_write(OUT, json.dumps(doc, ensure_ascii=False, indent=1), 0o600)
    state["lastRun"] = time.time()
    atomic_write(STATE, json.dumps(state, indent=1), 0o600)
    return settings, doc, tz


# ───────────────────────────── reminders ─────────────────────────────

def serp_dnd() -> bool:
    s = load_json(SERP_SETTINGS, {})
    return bool((s.get("notifications") or {}).get("dnd"))


def remind(settings, doc, tz):
    if settings.get("reminders", "yes").lower() in ("no", "false", "0", "off"):
        return
    lead = int(settings.get("remind_minutes", 10)) * 60
    now = time.time()
    state = load_json(STATE, {})
    sent = state.setdefault("reminded", {})
    dnd = serp_dnd()
    items = []
    for e in doc["events"]:
        if e["allDay"]:
            continue
        items.append((e["id"], e["startMs"] / 1000, e["title"], e))
        for a in e.get("alarms") or []:
            if a * 60 > lead:  # extra, earlier reminder requested in the event (VALARM)
                items.append((f"{e['id']}-a{a}", e["startMs"] / 1000 - a * 60 + lead, e["title"], e))
    for t in doc["tasks"]:
        if t.get("atMs"):
            items.append(("task:" + hashlib.sha1(f"{t['file']}|{t['text']}|{t['atMs']}".encode()).hexdigest()[:12], t["atMs"] / 1000, t["text"], None))
    for key, start, title, e in items:
        delta = start - now
        if key.startswith("task:"):
            delta += lead  # task reminders fire at their own time, not `lead` minutes early
        if -90 < delta <= lead + 45 and key not in sent:
            sent[key] = start
            real = (e["startMs"] / 1000 - now) if e else 0
            mins = max(0, round(real / 60))
            when = "now" if mins == 0 else (f"in {mins} min" if mins < 120 else (f"in {round(mins / 60)} h" if mins < 2880 else f"in {round(mins / 1440)} days"))
            if not e:
                when = "reminder"
            st = dt.datetime.fromtimestamp(start, tz).strftime("%H:%M")
            if e:
                en = dt.datetime.fromtimestamp(e["endMs"] / 1000, tz).strftime("%H:%M")
                body = f"{st}–{en}"
                if e["location"]:
                    body += " · " + e["location"]
                if e["meet"]:
                    body += "\n" + e["meet"]
                body += "\n" + e["calendar"]
                icon = "x-office-calendar"
            else:
                body, icon = f"{st} · Obsidian task", "obsidian"
            cmd = ["notify-send", "-a", "Calendar", "-i", icon, "-u", "normal",
                   "-h", "string:x-canonical-private-synchronous:gcal-" + key,
                   f"{title} — {when}", body]
            if dnd:
                cmd[1:1] = ["-h", "boolean:suppress-sound:true"]
            try:
                subprocess.run(cmd, timeout=10, check=False)
            except Exception as ex:
                log("notify-send failed:", ex)
    cutoff = now - 2 * 86400
    state["reminded"] = {k: v for k, v in sent.items() if v > cutoff}
    atomic_write(STATE, json.dumps(state, indent=1), 0o600)


# ───────────────────────────── commands ─────────────────────────────

def xdg_open(uri: str):
    subprocess.Popen(["xdg-open", uri], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def cmd_run(args):
    with locked():
        settings, doc, tz = build(force_fetch=args.cmd == "sync", quiet=args.quiet)
        if not args.no_remind:
            remind(settings, doc, tz)
    if args.cmd == "sync" and not args.quiet:
        cmd_status(args)


def cmd_daily(args):
    _, settings, _ = read_conf()
    tz = local_tz(settings)
    d = dt.date.fromisoformat(args.date) if args.date else dt.datetime.now(tz).date()
    if not settings["vault_path"].is_dir():
        raise SystemExit(f"vault not found: {settings['vault_path']}")
    path, rel, created = ensure_daily(settings, d, tz)
    uri = obsidian_uri(settings["vault_name"], rel)
    if created:
        with locked():
            build(quiet=True)
        time.sleep(0.4)  # let a running Obsidian notice the new file
    if not args.no_open:
        xdg_open(uri)
    print(json.dumps({"file": rel, "uri": uri, "created": created}))


def cmd_capture(args):
    text = " ".join(args.text).strip()
    text = re.sub(r"^\s*(?:[-*+]\s*)?(?:\[[ xX]\]\s*)?", "", text).replace("\n", " ").strip()
    if not text:
        raise SystemExit("nothing to capture")
    _, settings, _ = read_conf()
    tz = local_tz(settings)
    vault: Path = settings["vault_path"]
    if not vault.is_dir():
        raise SystemExit(f"vault not found: {vault}")
    mode = settings.get("capture", "auto")
    today = dt.datetime.now(tz).date()
    if mode not in ("auto", "daily", "inbox") and mode:
        rel = mode if mode.endswith(".md") else mode + ".md"
        path = vault / rel
        created = not path.exists()
        path.parent.mkdir(parents=True, exist_ok=True)
    elif mode in ("auto", "inbox") and find_inbox(vault):
        rel = find_inbox(vault); path, created = vault / rel, False
    else:
        path, rel, created = ensure_daily(settings, today, tz)
    existing = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    line = f"- [ ] {text}"
    sep = "" if (not existing or existing.endswith("\n")) else "\n"
    with open(path, "a", encoding="utf-8") as f:
        f.write(sep + line + "\n")
    with locked():
        build(quiet=True)
    print(json.dumps({"file": rel, "uri": obsidian_uri(settings["vault_name"], rel), "created": created, "task": line}, ensure_ascii=False))


def gcalcli_bin():
    p = Path(sys.prefix) / "bin/gcalcli"
    return str(p) if p.exists() else shutil.which("gcalcli")


def cmd_event(args):
    text = " ".join(args.text).strip()
    exe = gcalcli_bin()
    if not exe or not GCALCLI_TOKEN.exists():
        raise SystemExit("Google write access is not set up. Run: gcal-setup write")
    cmd = [exe, "--nocolor", "quick", text]
    if args.calendar:
        cmd[2:2] = ["--calendar", args.calendar]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise SystemExit("gcalcli failed: " + (r.stderr or r.stdout).strip()[-300:])
    with locked():
        build(force_fetch=True, quiet=True)
    print(json.dumps({"ok": True, "out": r.stdout.strip()[-300:]}))


# ───────────────────────────── smart capture ─────────────────────────────

def parse_context():
    doc = load_json(OUT, {})
    ob = doc.get("obsidian") or {}
    return {"calendars": [c["name"] for c in doc.get("calendars", []) if not c.get("local")],
            "tags": ob.get("tags") or [], "projects": ob.get("notes") or []}


def smart_parse(text, settings, tz, engine="auto", timeout=None):
    import gcal_parse as P
    now = dt.datetime.now(tz).replace(tzinfo=None)
    t0 = time.monotonic()
    rules = P.parse_rules(text, now)
    rules["ms"] = int((time.monotonic() - t0) * 1000)
    if engine == "rules" or settings.get("llm", "auto") == "off":
        return rules
    base = settings.get("llm_url") or P.LLM_URL
    st = P.llm_status(base)
    if st == "offline":
        rules["llmState"] = "offline"
        return rules
    try:
        # a socket-activated model that is still loading needs ~45 s for its first answer
        return P.parse_hybrid(text, now, parse_context(), base=base, timeout=timeout or (90 if st == "loading" else 20))
    except Exception as e:
        rules["llmState"] = f"failed: {type(e).__name__}"
        return rules


def field_update(item: dict, field: str, value: str, tz) -> dict:
    """Apply a hand-edited preview chip ("fri", "3pm", "90 min", …) to an item."""
    import gcal_parse as P
    now = dt.datetime.now(tz).replace(tzinfo=None)
    item = dict(item)
    v = (value or "").strip()
    if field in ("title", "location"):
        item[field] = v or (None if field == "location" else item.get("title"))
    elif field == "kind":
        item["kind"] = "event" if v == "event" else "task"
        if item["kind"] == "event":
            item["allDay"] = not item.get("time")
            if item.get("time") and not item.get("duration"):
                item["duration"] = 60
        else:
            item["duration"] = None
    elif field == "priority":
        item["priority"] = v if v in P.PRIO_EMOJI else None
    elif field == "tags":
        item["tags"] = ["#" + t.lstrip("#") for t in re.split(r"[\s,]+", v) if t.strip("#")]
    elif not v:
        item[field] = None
        if field == "time":
            item["allDay"] = item.get("kind") == "event"
    else:
        probe = P.parse_rules({"date": "x " + v, "time": "x at " + v if re.fullmatch(r"\d{1,2}", v) else "x " + v,
                               "duration": "x for " + v if re.fullmatch(r"[\d.,]+", v) else "x " + v,
                               "recurrence": "x " + (v if re.match(r"(every|each|каждый|каждую|по)\b", v, re.I) else "every " + v),
                               "reminder": "x remind me " + v}.get(field, "x " + v), now)
        if field == "date" and probe.get("date"):
            item["date"] = probe["date"]
        elif field == "time" and probe.get("time"):
            item["time"] = probe["time"]
            if item.get("kind") == "event":
                item["allDay"] = False
                item["duration"] = item.get("duration") or 60
        elif field == "duration" and (probe.get("duration") or re.fullmatch(r"\d+", v)):
            item["duration"] = probe.get("duration") or int(v)
        elif field == "recurrence" and probe.get("recurrence"):
            item["recurrence"] = probe["recurrence"]
        elif field == "reminder":
            base = P.parse_rules("x " + (item.get("date") or "") + " " + (item.get("time") or "") + " remind me " + v, now)
            if base.get("reminder"):
                item["reminder"] = base["reminder"]
    item["edited"] = True
    return item


def cmd_parse(args):
    _, settings, _ = read_conf()
    tz = local_tz(settings)
    print(json.dumps(smart_parse(" ".join(args.text), settings, tz, engine=args.engine), ensure_ascii=False))


def cmd_parse_server(args):
    """Line protocol for the quick-capture preview (QML Process):
    in : {"id": n, "text": "...", "llm": true}  |  {"id": n, "op": "field", "item": {...}, "field": "date", "value": "fri"}
    out: {"id": n, "stage": "rules"|"llm"|"field"|"llm-failed", "item": {...}, "llm": "pending"|"loading"|"offline"|"off"}"""
    import threading
    import gcal_parse as P
    _, settings, _ = read_conf()
    tz = local_tz(settings)
    base = settings.get("llm_url") or P.LLM_URL
    llm_enabled = settings.get("llm", "auto") != "off"
    out_lock = threading.Lock()
    state = {"latest": 0, "health": (0.0, "offline"), "cache": {}}
    cond = threading.Condition()
    pending = {}

    def emit(obj):
        with out_lock:
            sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    def llm_status():
        """online | loading | offline (cached: 15 s when online, 5 s otherwise)"""
        t, st = state["health"]
        if time.monotonic() - t > (15 if st == "online" else 5):
            st = P.llm_status(base)
            state["health"] = (time.monotonic(), st)
        return st

    def llm_worker():
        while True:
            with cond:
                while not pending:
                    cond.wait()
                rid = max(pending)
                text = pending.pop(rid)
                pending.clear()
            if rid < state["latest"]:
                continue
            now = dt.datetime.now(tz).replace(tzinfo=None)
            try:
                if text in state["cache"]:
                    item = state["cache"][text]
                else:
                    # still loading (socket-activated, ~45 s): wait for the model instead of failing
                    item = P.parse_hybrid(text, now, parse_context(), base=base,
                                          timeout=90 if state["health"][1] == "loading" else 25)
                    state["cache"][text] = item
                emit({"id": rid, "stage": "llm", "item": item})
            except Exception as e:
                state["health"] = (time.monotonic(), "offline")
                emit({"id": rid, "stage": "llm-failed", "error": f"{type(e).__name__}: {e}"[:160]})

    threading.Thread(target=llm_worker, daemon=True).start()
    for line in sys.stdin:
        try:
            req = json.loads(line)
        except Exception:
            continue
        rid = int(req.get("id", 0))
        if req.get("op") == "field":
            emit({"id": rid, "stage": "field", "item": field_update(req.get("item") or {}, req.get("field", ""), req.get("value", ""), tz)})
            continue
        if req.get("op") == "health":
            emit({"id": rid, "stage": "health", "llm": llm_status()})
            continue
        text = (req.get("text") or "").strip()
        state["latest"] = max(state["latest"], rid)
        if not text:
            continue
        now = dt.datetime.now(tz).replace(tzinfo=None)
        t0 = time.monotonic()
        item = P.parse_rules(text, now)
        item["ms"] = int((time.monotonic() - t0) * 1000)
        want_llm = bool(req.get("llm")) and llm_enabled
        llm_state = "off"
        if want_llm:
            if text in state["cache"]:
                emit({"id": rid, "stage": "llm", "item": state["cache"][text]})
                continue
            st = llm_status()
            llm_state = {"online": "pending", "loading": "loading"}.get(st, "offline")
        emit({"id": rid, "stage": "rules", "item": item, "llm": llm_state})
        if llm_state in ("pending", "loading"):
            with cond:
                pending[rid] = text
                cond.notify()


def capture_target(settings, tz):
    vault: Path = settings["vault_path"]
    mode = settings.get("capture", "auto")
    today = dt.datetime.now(tz).date()
    if mode not in ("auto", "daily", "inbox") and mode:
        rel = mode if mode.endswith(".md") else mode + ".md"
        path = vault / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        return path, rel
    if mode in ("auto", "inbox") and find_inbox(vault):
        rel = find_inbox(vault)
        return vault / rel, rel
    path, rel, _ = ensure_daily(settings, today, tz)
    return path, rel


def append_line(path: Path, line: str):
    existing = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    sep = "" if (not existing or existing.endswith("\n")) else "\n"
    with open(path, "a", encoding="utf-8") as f:
        f.write(sep + line + "\n")


def add_local_event(item: dict, uid: str, tz):
    import gcal_parse as P
    LOCAL_ICS.parent.mkdir(parents=True, exist_ok=True)
    ve = P.vevent(item, uid, tz.key)
    if LOCAL_ICS.exists():
        cur = LOCAL_ICS.read_text(encoding="utf-8")
        i = cur.rfind("END:VCALENDAR")
        cur = (cur[:i] if i >= 0 else cur).rstrip("\r\n") + "\r\n" + ve + "\r\nEND:VCALENDAR\r\n"
    else:
        cur = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//gcal-sync//capture//EN\r\nX-WR-CALNAME:Captured\r\n"
               + ve + "\r\nEND:VCALENDAR\r\n")
    atomic_write(LOCAL_ICS, cur, 0o600)


def cmd_add(args):
    """Commit a (possibly hand-tweaked) parsed item: task -> Obsidian; event -> Google (if write
    access is set up) or local-events.ics + an Obsidian event-task."""
    import uuid
    import gcal_parse as P
    _, settings, _ = read_conf()
    tz = local_tz(settings)
    if args.json:
        item = json.loads(args.json)
    else:
        item = smart_parse(" ".join(args.text or []), settings, tz, engine=args.engine)
    if not (item.get("title") or "").strip():
        raise SystemExit("empty title")
    vault: Path = settings["vault_path"]
    if not vault.is_dir():
        raise SystemExit(f"vault not found: {vault}")
    item.setdefault("date", dt.datetime.now(tz).date().isoformat())
    result = {"ok": True, "kind": item.get("kind", "task")}
    if item.get("kind") == "event":
        exe = gcalcli_bin()
        google_done = False
        if exe and GCALCLI_TOKEN.exists() and not args.local:
            import tempfile
            uid = f"{uuid.uuid4()}@gcal-sync"
            ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//gcal-sync//capture//EN\r\n" + P.vevent(item, uid, tz.key) + "\r\nEND:VCALENDAR\r\n"
            with tempfile.NamedTemporaryFile("w", suffix=".ics", delete=False) as f:
                f.write(ics)
            cmd = [exe, "--nocolor", "import"]
            if args.calendar:
                cmd += ["--calendar", args.calendar]
            r = subprocess.run(cmd + [f.name], capture_output=True, text=True, timeout=60)
            os.unlink(f.name)
            google_done = r.returncode == 0
            if not google_done:
                result["googleError"] = (r.stderr or r.stdout).strip()[-200:]
        if google_done:
            result["where"] = "Google Calendar"
            with locked():
                build(force_fetch=True, quiet=True)
        else:
            uid = f"{uuid.uuid4()}@gcal-sync.local"
            add_local_event(item, uid, tz)
            path, rel = capture_target(settings, tz)
            append_line(path, P.task_line(item, local_uid=uid))
            result.update({"where": "Calendar (local) + " + rel.removesuffix(".md"), "file": rel, "uid": uid})
            with locked():
                build(quiet=True)
    else:
        path, rel = capture_target(settings, tz)
        line = P.task_line(item)
        append_line(path, line)
        result.update({"where": rel.removesuffix(".md"), "file": rel, "line": line})
        with locked():
            build(quiet=True)
    result["message"] = ("Event added to " if result["kind"] == "event" else "Task added to ") + result["where"]
    print(json.dumps(result, ensure_ascii=False))


def cmd_status(args):
    doc = load_json(OUT, {})
    if not doc:
        print("no data yet — run `gcal-sync sync`")
        return
    print(f"today {doc['today']} ({doc['tz']}), window {doc['range'][0]} → {doc['range'][1]}")
    if not doc.get("calendars"):
        print("calendars: none configured (run gcal-setup)")
    for c in doc.get("calendars", []):
        last = dt.datetime.fromtimestamp(c["lastSync"]).strftime("%Y-%m-%d %H:%M") if c.get("lastSync") else "never"
        state = "ok" if c["ok"] else "ERROR: " + c["error"]
        print(f"  [{c['color']}] {c['name']}: {c.get('count', 0)} events, last sync {last}, {state}")
    ob = doc.get("obsidian", {})
    print(f"obsidian: {ob.get('vault')} — {len(doc.get('tasks', []))} open tasks with dates, "
          f"{len(doc.get('daily', {}))} daily notes in window, today's note: {ob.get('todayNote')} "
          f"({'exists' if ob.get('todayExists') else 'not created yet'})")
    print("google write (gcalcli):", "enabled" if doc.get("writeEnabled") else "not set up (optional: gcal-setup write)")


# ───────────────────────────── setup (interactive) ─────────────────────────────

B, D, R, G, Y, C0 = "\033[1m", "\033[2m", "\033[31m", "\033[32m", "\033[33m", "\033[0m"


def setup_add():
    print(f"""
{B}Connect a Google calendar (read-only, private iCal link){C0}

  1. Open {B}https://calendar.google.com/calendar/r/settings{C0} in your browser.
  2. Left side → {B}Settings for my calendars{C0} → click the calendar → {B}Integrate calendar{C0}.
  3. Copy {B}"Secret address in iCal format"{C0} (ends with /basic.ics) and paste it below.
     {D}(The input is hidden; it is stored only in {CONF} with mode 600.){C0}
""")
    cp, settings, cals = read_conf()
    while True:
        try:
            url = getpass.getpass(f"{B}Secret iCal address{C0} (empty = done): ").strip().strip('"').strip("'")
        except (EOFError, KeyboardInterrupt):
            print(); break
        if not url:
            break
        if not re.match(r"^(https?|webcal|file)://|^[/~]", url):
            print(f"  {R}That doesn't look like a link.{C0}"); continue
        if url.startswith("https://calendar.google.com/calendar/embed") or "cid=" in url:
            print(f"  {R}That's the public/embed link — use the *Secret address in iCal format*.{C0}"); continue
        if any(c["url"] == url for c in cals):
            print(f"  {Y}Already added.{C0}"); continue
        print(f"  checking {mask_url(url)} …", end="", flush=True)
        tmp_meta = {}
        try:
            req = urllib.request.Request(normalize_url(url), headers={"User-Agent": "gcal-sync/1.0"})
            with urllib.request.urlopen(req, timeout=25) as r:
                data = r.read()
        except Exception as e:
            print(f" {R}failed: {e}{C0}"); continue
        if not looks_like_ics(data):
            print(f" {R}not an iCal feed.{C0}"); continue
        tz = local_tz(settings)
        today = dt.datetime.now(tz).date()
        try:
            evs, feed = parse_calendar({"name": "x", "url": url, "color": "blue"}, data, today, today + dt.timedelta(days=60), tz)
        except Exception as e:
            print(f" {R}could not parse: {e}{C0}"); continue
        print(f" {G}ok{C0} — “{feed or 'calendar'}”, {len(evs)} events in the next 60 days")
        for e in evs[:3]:
            when = e["startDate"] if e["allDay"] else e["start"][:16].replace("T", " ")
            print(f"     {D}{when}  {e['title']}{C0}")
        default_name = feed or f"Calendar {len(cals) + 1}"
        name = input(f"  Name [{default_name}]: ").strip() or default_name
        name = re.sub(r"[\[\]]", "", name)
        while cp.has_section(name):
            name += " 2"
        color = PALETTE[len(cals) % len(PALETTE)]
        c = input(f"  Color ({' '.join(PALETTE)} or #hex) [{color}]: ").strip() or color
        cp.add_section(name)
        cp.set(name, "url", url)
        cp.set(name, "color", c)
        write_conf(cp)
        cals.append({"name": name, "url": url})
        print(f"  {G}saved.{C0} Paste another link, or press Enter to finish.")
    if not cals:
        print("No calendars configured. Run gcal-setup again any time.")
        return
    if not cp.has_section(SETTINGS_SECTION):
        cp.add_section(SETTINGS_SECTION)
        for k in ("vault", "remind_minutes", "interval"):
            cp.set(SETTINGS_SECTION, k, DEFAULTS[k])
        write_conf(cp)
    print(f"\n{B}Starting the background sync…{C0}")
    subprocess.run(["systemctl", "--user", "enable", "--now", "gcal-sync.timer"], check=False)
    with locked():
        build(force_fetch=True)
    cmd_status(None)
    print(f"\n{G}Done.{C0} Mod+C shows the agenda; the desktop calendar shows dots on busy days.")


def setup_list():
    cp, settings, cals = read_conf()
    if not cals:
        print("No calendars. Run gcal-setup to add one.")
    for c in cals:
        print(f"  {c['name']}  [{c['color']}]  {'' if c['enabled'] else '(disabled) '}{mask_url(c['url'])}")
    print(f"config: {CONF}")


def setup_remove(name):
    cp, _, _ = read_conf()
    if not cp.has_section(name):
        raise SystemExit(f"no calendar named {name!r} (see gcal-setup list)")
    cp.remove_section(name)
    write_conf(cp)
    with locked():
        build(quiet=True)
    print(f"removed {name}")


def setup_write():
    exe = gcalcli_bin()
    print(f"""
{B}Optional: create Google events from the desktop (gcalcli, OAuth){C0}
The read-only iCal links are all the agenda needs. This extra step only enables
quick-adding events ("/e Lunch with Anna tomorrow 13:00" in the capture prompt).

  1. https://console.cloud.google.com/ → create a project → APIs & Services →
     enable {B}Google Calendar API{C0}.
  2. OAuth consent screen → External → add yourself as a {B}test user{C0}.
  3. Credentials → Create credentials → {B}OAuth client ID{C0} → type {B}Desktop app{C0}.
  4. Run (a browser window opens once to grant access):
       {B}{exe or '~/.venvs/gcal/bin/gcalcli'} --client-id=YOUR_ID init{C0}
     (it asks for the client secret). The token is stored in {GCALCLI_TOKEN}.
  5. Run {B}gcal-sync sync{C0}: the capture prompt now accepts /e events.
""")
    if not exe:
        print(f"{Y}gcalcli is not installed: ~/.venvs/gcal/bin/pip install gcalcli{C0}")
    print("Status:", "ENABLED" if (exe and GCALCLI_TOKEN.exists()) else "not set up")


def cmd_setup(args):
    sub = args.what or "add"
    if sub == "add":
        setup_add()
    elif sub == "list":
        setup_list()
    elif sub == "remove":
        if not args.name:
            raise SystemExit("usage: gcal-setup remove NAME")
        setup_remove(" ".join(args.name))
    elif sub == "write":
        setup_write()
    else:
        raise SystemExit("usage: gcal-setup [add|list|remove NAME|write]")


def cmd_range(args):
    """Events/tasks/daily notes for an arbitrary date range, from the cached feeds only
    (no network). Used by the agenda's Month view for months outside events.json's window."""
    _, settings, cals = read_conf()
    tz = local_tz(settings)
    start = dt.date.fromisoformat(args.start)
    end = dt.date.fromisoformat(args.end)
    today = dt.datetime.now(tz).date()
    events = []
    for cal in cals:
        rp = raw_path(cal["url"])
        if not cal["enabled"] or not rp.exists():
            continue
        try:
            evs, _ = parse_calendar(cal, rp.read_bytes(), start, end + dt.timedelta(days=1), tz)
            events.extend(evs)
        except Exception as e:
            log(f"[{cal['name']}] parse error: {e}")
    events.sort(key=lambda e: (e["startDate"], not e["allDay"], e["startMs"], e["title"].lower()))
    tasks, daily, _ = scan_vault(settings, today, start, end, tz)
    tasks = [t for t in tasks if t["due"] >= start.isoformat()]
    print(json.dumps({"from": start.isoformat(), "to": end.isoformat(), "events": events,
                      "tasks": tasks, "daily": daily}, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(prog="gcal-sync", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd")
    for n in ("run", "sync"):
        p = sp.add_parser(n)
        p.add_argument("--no-remind", action="store_true")
        p.add_argument("-q", "--quiet", action="store_true")
    p = sp.add_parser("daily"); p.add_argument("--date"); p.add_argument("--no-open", action="store_true")
    p = sp.add_parser("capture"); p.add_argument("text", nargs="+")
    p = sp.add_parser("event"); p.add_argument("text", nargs="+"); p.add_argument("--calendar")
    sp.add_parser("status")
    p = sp.add_parser("parse"); p.add_argument("text", nargs="+"); p.add_argument("--engine", choices=["auto", "rules", "llm"], default="auto")
    sp.add_parser("parse-server")
    p = sp.add_parser("range"); p.add_argument("start"); p.add_argument("end")
    p = sp.add_parser("add"); p.add_argument("text", nargs="*"); p.add_argument("--json"); p.add_argument("--calendar")
    p.add_argument("--local", action="store_true", help="never write to Google, keep events local")
    p.add_argument("--engine", choices=["auto", "rules", "llm"], default="auto")
    p = sp.add_parser("setup"); p.add_argument("what", nargs="?"); p.add_argument("name", nargs="*")
    args = ap.parse_args()
    if not args.cmd:
        args.cmd, args.no_remind, args.quiet = "sync", False, False
    {"run": cmd_run, "sync": cmd_run, "daily": cmd_daily, "capture": cmd_capture, "event": cmd_event,
     "status": cmd_status, "setup": cmd_setup, "parse": cmd_parse, "parse-server": cmd_parse_server,
     "add": cmd_add, "range": cmd_range}[args.cmd](args)


if __name__ == "__main__":
    main()
