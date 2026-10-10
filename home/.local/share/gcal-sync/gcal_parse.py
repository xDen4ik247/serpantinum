"""Natural-language capture parser for gcal-sync (EN / RU / basic JA).

parse(text) -> item dict:
  kind        "task" | "event"
  title       cleaned title
  date        YYYY-MM-DD (event day / task due) or None
  time        HH:MM start (or None)
  duration    minutes (events) or None
  allDay      bool (events without a time)
  location    str or None
  recurrence  {"freq": daily|weekly|monthly|yearly, "interval": n, "byday": ["MO",..], "text": "..."} or None
  priority    highest|high|medium|low|lowest or None
  tags        ["#tag", ...]
  scheduled   YYYY-MM-DD or None (Tasks ⏳)
  reminder    {"date": YYYY-MM-DD, "time": HH:MM} or None
  parser      "rules" | "llm"

Two engines: a fast rule-based parser (always available) and the local LLM
(llama.cpp server, OpenAI-compatible, JSON-schema constrained output).
"""
from __future__ import annotations

import datetime as dt
import json
import re
import time
import urllib.request
import os


def _system_tz() -> str:
    """IANA name of the machine's timezone (from /etc/localtime), e.g. 'Europe/Berlin'."""
    try:
        return os.path.realpath("/etc/localtime").split("/zoneinfo/", 1)[1]
    except Exception:
        return "UTC"


SYSTEM_TZ = _system_tz()

LLM_URL = "http://127.0.0.1:8765"
WD_CODES = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
WD_EN = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
WD_EN_SHORT = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
# Russian weekday stems (понедельник/понедельника/понедельникам, вторник, среду/среда/среды, …)
WD_RU = [r"понедельник\w*|пн", r"вторник\w*|вт", r"сред[аеуыой]\w*|ср", r"четверг\w*|чт",
         r"пятниц[аеуыой]\w*|пт", r"суббот[аеуыой]\w*|сб", r"воскресень[еяюи]\w*|вс"]
WD_JA = ["月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜"]
MONTHS_EN = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
MONTHS_RU = ["январ", "феврал", "март", "апрел", "ма[йяе]", "июн", "июл", "август", "сентябр", "октябр", "ноябр", "декабр"]
NUM_WORDS = {"a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "half": 0.5,
             "один": 1, "одну": 1, "одна": 1, "два": 2, "две": 2, "три": 3, "четыре": 4, "пять": 5, "полтора": 1.5, "полторы": 1.5}
PRIO_EMOJI = {"highest": "🔺", "high": "⏫", "medium": "🔼", "low": "🔽", "lowest": "⏬"}


def _num(s: str) -> float:
    s = s.strip().lower().replace(",", ".")
    if s in NUM_WORDS:
        return NUM_WORDS[s]
    try:
        return float(s)
    except ValueError:
        return 1


class _Text:
    """Text with consumed spans; what is left becomes the title."""

    def __init__(self, s: str):
        self.s = s
        self.mask = [False] * len(s)

    def find(self, pattern, flags=re.I):
        # match against the not-yet-consumed text (consumed chars become spaces),
        # so a greedy pattern can't swallow a word another rule already took
        for m in re.finditer(pattern, self.rest(), flags):
            if m.group(0).strip() and not any(self.mask[m.start():m.end()]):
                yield m

    def first(self, pattern, flags=re.I):
        return next(self.find(pattern, flags), None)

    def eat(self, m, group=0):
        a, b = m.span(group)
        for i in range(a, b):
            self.mask[i] = True

    def rest(self) -> str:
        return "".join(" " if self.mask[i] else c for i, c in enumerate(self.s))


def _hhmm(h: int, m: int = 0) -> str | None:
    if 0 <= h <= 24 and 0 <= m < 60:
        return f"{h % 24:02d}:{m:02d}"
    return None


def _next_weekday(today: dt.date, wd: int, force_next=False) -> dt.date:
    delta = (wd - today.weekday()) % 7
    if delta == 0 and force_next:
        delta = 7
    return today + dt.timedelta(days=delta)


def _wd_index(word: str) -> int | None:
    w = word.lower()
    for i, en in enumerate(WD_EN):
        if w == en or w == WD_EN_SHORT[i] or (len(w) >= 3 and en.startswith(w)):
            return i
    for i, ru in enumerate(WD_RU):
        if re.fullmatch(ru, w):
            return i
    for i, ja in enumerate(WD_JA):
        if w.startswith(ja):
            return i
    return None


WD_ANY = "(?:" + "|".join(WD_EN + WD_EN_SHORT) + "|" + "|".join(WD_RU) + r")\b|" + "|".join(j + "日?" for j in WD_JA)


# ───────────────────────────── repeats ─────────────────────────────
# "every Monday at 10", "every 2 weeks on tue until December", "last friday of every month",
# "каждый вторник в 18:00", "по будням", "каждые 2 недели в субботу до конца года", "10 раз" …

_WD_EN_ONE = r"(?:(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?|mon|tues?|weds?|thu(?:rs?)?|fri|sat|sun)"
_WD_ONE = r"(?:" + _WD_EN_ONE + "|" + "|".join(WD_RU) + r")\b"
_WD_LIST = _WD_ONE + r"(?:\s*(?:,|and|&|и|или|or)\s*(?:on\s+|в\s+|во\s+|по\s+)?" + _WD_ONE + r")*"
_N = (r"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
      r"два|две|двух|три|тр[её]х|четыре|четыр[её]х|пять|пяти|шесть|шести|семь|семи|восемь|восьми|десять|десяти)")
_NUMW = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
         "eleven": 11, "twelve": 12, "other": 2, "second": 2, "два": 2, "две": 2, "двух": 2, "три": 3, "трёх": 3, "трех": 3,
         "четыре": 4, "четырёх": 4, "четырех": 4, "пять": 5, "пяти": 5, "шесть": 6, "шести": 6, "семь": 7, "семи": 7,
         "восемь": 8, "восьми": 8, "десять": 10, "десяти": 10}
_ORD_EN = r"(first|1st|second|2nd|third|3rd|fourth|4th|fifth|5th|last)"
_ORD_RU = (r"(перв(?:ый|ую|ое|ая|ого|ой)|втор(?:ой|ую|ое|ая|ого)|трет(?:ий|ью|ье|ья|ьего|ьей)|"
           r"четв[её]рт(?:ый|ую|ое|ая|ого|ой)|пят(?:ый|ую|ое|ая|ого|ой)|последн(?:ий|юю|ее|яя|его|ей))")
_HOUR_NUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
             "eleven": 11, "twelve": 12, "двух": 2, "два": 2, "трёх": 3, "трех": 3, "три": 3, "четырёх": 4, "четырех": 4,
             "четыре": 4, "пяти": 5, "пять": 5, "шести": 6, "шесть": 6, "семи": 7, "семь": 7, "восьми": 8, "восемь": 8,
             "девяти": 9, "девять": 9, "десяти": 10, "десять": 10, "одиннадцати": 11, "одиннадцать": 11,
             "двенадцати": 12, "двенадцать": 12}
_HOUR_WORDS = "(?:" + "|".join(sorted(_HOUR_NUM, key=len, reverse=True)) + ")"
_MON_EN = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"
_MON_RU = "(?:" + "|".join(MONTHS_RU) + r")\w*"


def _n(s: str | None, default=1) -> int:
    if not s:
        return default
    s = s.lower()
    if s.isdigit():
        return int(s)
    if s.startswith("втор"):
        return 2
    return _NUMW.get(s, default)


def _ord(s: str) -> int:
    s = s.lower()
    for k, v in (("first", 1), ("1st", 1), ("second", 2), ("2nd", 2), ("third", 3), ("3rd", 3), ("fourth", 4), ("4th", 4),
                 ("fifth", 5), ("5th", 5), ("last", -1), ("перв", 1), ("втор", 2), ("трет", 3), ("четв", 4), ("пят", 5),
                 ("последн", -1)):
        if s.startswith(k):
            return v
    return 1


def _wd_code(word: str) -> str | None:
    w = word.lower()
    if w.endswith("days") or w in ("tues", "weds", "thurs"):
        w = w[:-1]
    i = _wd_index(w)
    return WD_CODES[i] if i is not None else None


def _days_in(s: str) -> list[str]:
    out = []
    for w in re.findall(_WD_ONE, s or "", re.I):
        c = _wd_code(w)
        if c and c not in out:
            out.append(c)
    return sorted(out, key=WD_CODES.index)


def _freq_of(unit: str) -> str:
    u = unit.lower()
    if u.startswith(("day", "дн", "ден", "сут")):
        return "daily"
    if u.startswith(("week", "недел")):
        return "weekly"
    if u.startswith(("month", "месяц")):
        return "monthly"
    return "yearly"


def _month_index(word: str) -> int | None:
    w = word.lower().rstrip(".")
    if re.match(r"[a-z]", w):
        return MONTHS_EN.index(w[:3]) + 1 if w[:3] in MONTHS_EN else None
    for i, p in enumerate(MONTHS_RU):
        if re.match(p, w):
            return i + 1
    return None


def _last_day(y: int, m: int) -> dt.date:
    return (dt.date(y, m, 28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)


def _until_date(phrase: str, today: dt.date) -> dt.date | None:
    """End of a series: "December" (= up to Nov 30), "Dec 20", "20 декабря", "end of the year",
    "конца месяца", "15.12", "2026-12-20"."""
    p = re.sub(r"\s+", " ", phrase.lower().strip())
    if re.search(r"(end of (the )?year|конца года|нового года)", p):
        return dt.date(today.year, 12, 31)
    if re.search(r"(end of (the )?month|конца месяца)", p):
        return _last_day(today.year, today.month)
    if re.search(r"next month|следующего месяца", p):
        return _last_day(today.year, today.month)
    if re.search(r"next year|следующего года", p):
        return dt.date(today.year, 12, 31)
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", p)
    if m:
        try:
            return dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            return None
    m = re.search(r"(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?", p)
    if m:
        y = int(m.group(3)) + (2000 if m.group(3) and len(m.group(3)) == 2 else 0) if m.group(3) else today.year
        try:
            d = dt.date(y, int(m.group(2)), int(m.group(1)))
        except ValueError:
            return None
        return d if m.group(3) or d >= today else d.replace(year=y + 1)
    words = re.findall(r"[a-zа-яё]+\.?", p)
    mon = next((_month_index(w) for w in words if _month_index(w)), None)
    if mon is None:
        return None
    y = today.year if mon >= today.month else today.year + 1
    day = re.search(r"\b(\d{1,2})(?:st|nd|rd|th|-?го)?\b", p)
    end_of = re.search(r"end of|конца", p)
    if end_of:
        return _last_day(y, mon)
    if day:
        try:
            d = dt.date(today.year, mon, int(day.group(1)))
        except ValueError:
            return None
        return d if d >= today else d.replace(year=today.year + 1)
    # "until December": the series stops before December starts
    return dt.date(y, mon, 1) - dt.timedelta(days=1)


def _eat_recurrence(T: "_Text", item: dict, today: dt.date) -> dict | None:
    def mk(freq, interval=1, byday=None, bymonthday=None):
        return {"freq": freq, "interval": max(1, interval), "byday": byday or [], "bymonthday": bymonthday or [],
                "count": None, "until": None}

    rec = None
    # every morning / каждое утро → daily + a default time of day
    m = T.first(r"\b(every\s+(morning|evening|night)|каждое\s+утро|каждый\s+вечер|каждую\s+ночь)\b")
    if m:
        w = m.group(0).lower()
        item["_daypart"] = "09:00" if ("morning" in w or "утро" in w) else ("22:00" if ("night" in w or "ночь" in w) else "19:00")
        rec = mk("daily")
        T.eat(m)

    # monthly on the Nth weekday: "last friday of every month", "каждый второй четверг месяца"
    if not rec:
        for pat in (r"\b(?:(?:every|each|on)\s+)?(?:the\s+)?" + _ORD_EN + r"\s+(" + _WD_ONE + r")\s+of\s+(?:every|each|the|a)\s+month\b",
                    r"\b(?:every\s+month|monthly|each\s+month)\s+on\s+the\s+" + _ORD_EN + r"\s+(" + _WD_ONE + ")",
                    r"\bevery\s+(first|1st|third|3rd|fourth|4th|fifth|5th|last)\s+(" + _WD_ONE + ")",
                    r"(?:\b(?:кажд\w+|в|во)\s+)?" + _ORD_RU + r"\s+(" + _WD_ONE + r")\s+(?:каждого\s+)?месяца\b",
                    r"\b(?:каждый\s+месяц|ежемесячно)\s+(?:в\s+|во\s+)?" + _ORD_RU + r"\s+(" + _WD_ONE + ")",
                    r"\bкажд\w+\s+(перв\w+|трет\w+|четв[её]рт\w+|последн\w+)\s+(" + _WD_ONE + ")"):
            m = T.first(pat)
            if m:
                code = _wd_code(m.group(2))
                if code:
                    rec = mk("monthly", byday=[f"{_ord(m.group(1))}{code}"])
                    T.eat(m)
                    break

    # "monthly team retro on the first monday", "ежемесячно … в последнюю пятницу": the two halves apart
    if not rec:
        mm = T.first(r"\b(?:monthly|every\s+month|each\s+month|ежемесячно|каждый\s+месяц)\b")
        if mm:
            mo = T.first(r"\b(?:on\s+)?the\s+" + _ORD_EN + r"\s+(" + _WD_ONE + ")") or T.first(r"\b(?:в|во)\s+" + _ORD_RU + r"\s+(" + _WD_ONE + ")")
            if mo and _wd_code(mo.group(2)):
                rec = mk("monthly", byday=[f"{_ord(mo.group(1))}{_wd_code(mo.group(2))}"])
                T.eat(mm)
                T.eat(mo)

    # monthly on a day of the month: "on the 1st of every month", "каждое 15 число", "15 числа каждого месяца"
    if not rec:
        for pat, day in ((r"\b(?:on\s+)?the\s+last\s+day\s+of\s+(?:every|each|the)\s+month\b|\bв\s+последний\s+день\s+(?:каждого\s+)?месяца\b", -1),
                         (r"\b(?:on\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(?:day\s+)?of\s+(?:every|each|the|a)\s+month\b", None),
                         (r"\b(?:every\s+month|monthly|each\s+month)\s+on\s+(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\b", None),
                         (r"\bevery\s+(\d{1,2})(?:st|nd|rd|th)\b(?:\s+of\s+(?:the|each|every)\s+month)?", None),
                         (r"\bкаждое\s+(\d{1,2})(?:-?е)?\s+число\b", None),
                         (r"\b(\d{1,2})(?:-?го)?\s+числа\s+каждого\s+месяца\b", None),
                         (r"\b(?:каждый\s+месяц|ежемесячно)\s+(\d{1,2})(?:-?го|\s+числа)\b", None)):
            m = T.first(pat)
            if m:
                n = day if day is not None else int(m.group(1))
                if 1 <= abs(n) <= 31:
                    rec = mk("monthly", bymonthday=[n])
                    T.eat(m)
                    break

    # intervals: "every 2 weeks (on tue)", "every other wednesday", "biweekly", "каждые 2 недели", "раз в две недели"
    if not rec:
        m = T.first(r"\bevery\s+(other|second|" + _N[1:-1] + r")\s+(day|week|month|year)s?\b(?:\s+on\s+(" + _WD_LIST + "))?")
        if m:
            rec = mk(_freq_of(m.group(2)), _n(m.group(1)), _days_in(m.group(3)) if _freq_of(m.group(2)) == "weekly" else [])
            T.eat(m)
    if not rec:
        m = T.first(r"\bevery\s+(?:other|second|alternate)\s+(" + _WD_LIST + ")")
        if m:
            rec = mk("weekly", 2, _days_in(m.group(1)))
            T.eat(m)
    if not rec:
        m = T.first(r"\b(?:bi-?weekly|fortnightly|every\s+fortnight)\b(?:\s+on\s+(" + _WD_LIST + "))?")
        if m:
            rec = mk("weekly", 2, _days_in(m.group(1)))
            T.eat(m)
    if not rec:
        m = T.first(r"\bкажд(?:ые|ую|ый|ое|ой)\s+(втор\w+|" + _N[1:-1] + r")\s+(дн\w*|день|сут\w*|недел\w*|месяц\w*|год\w*|лет)\b"
                    r"(?:\s+(?:в|во|по)\s+(" + _WD_LIST + "))?")
        if m:
            f = _freq_of(m.group(2))
            rec = mk(f, _n(m.group(1)), _days_in(m.group(3)) if f == "weekly" else [])
            T.eat(m)
    if not rec:
        m = T.first(r"\bраз\s+в\s+(?:" + _N + r"\s+)?(дн\w*|день|сутки|недел\w*|месяц\w*|год|года|лет)\b(?:\s+(?:в|во|по)\s+(" + _WD_LIST + "))?")
        if m:
            f = _freq_of(m.group(2))
            rec = mk(f, _n(m.group(1)), _days_in(m.group(3)) if f == "weekly" else [])
            T.eat(m)
    if not rec:
        m = T.first(r"\bкажд(?:ый|ую|ое)\s+втор(?:ой|ую|ое)\s+(" + _WD_ONE + ")")
        if m:
            rec = mk("weekly", 2, _days_in(m.group(1)))
            T.eat(m)

    # every weekday / по будням, weekends / по выходным
    if not rec:
        m = T.first(r"\b(?:every\s+weekday|on\s+weekdays|weekdays|every\s+workday|on\s+workdays|workdays|"
                    r"monday\s+(?:to|through|thru|-|–)\s+friday|mon\s*[-–]\s*fri|по\s+будням|в\s+будни|"
                    r"каждый\s+будний\s+день|по\s+будним\s+дням|по\s+рабочим\s+дням|в\s+рабочие\s+дни|"
                    r"с\s+понедельника\s+по\s+пятницу|пн\s*[-–]\s*пт)\b|平日")
        if m:
            rec = mk("weekly", 1, WD_CODES[:5])
            T.eat(m)
    if not rec:
        m = T.first(r"\b(?:every\s+weekend|on\s+weekends|weekends|по\s+выходным|каждые\s+выходные)\b")
        if m:
            rec = mk("weekly", 1, ["SA", "SU"])
            T.eat(m)

    # weekly on named days: "every mon and wed", "mondays", "каждый вторник", "по средам и пятницам", 毎週火曜
    if not rec:
        m = T.first(r"\b(?:every|each|каждый|каждую|каждое|каждые|по)\s+(" + _WD_LIST + ")")
        if not m:
            m = T.first(r"\b(?:on\s+)?((?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)s"
                        r"(?:\s*(?:,|and|&)\s*(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)s)*)\b")
        if m and _days_in(m.group(1)):
            rec = mk("weekly", 1, _days_in(m.group(1)))
            T.eat(m)
        else:
            m = T.first(r"毎週\s*(" + "|".join(WD_JA) + r")日?")
            if m:
                rec = mk("weekly", 1, [WD_CODES[WD_JA.index(m.group(1))]])
                T.eat(m)

    # plain: daily / weekly (on …) / monthly / yearly
    if not rec:
        for pat, f in ((r"\b(?:every\s*day|daily|each\s+day|ежедневно|каждый\s+день|каждые\s+сутки)\b|毎日", "daily"),
                       (r"\b(?:every\s+week|weekly|each\s+week|once\s+a\s+week|еженедельно|каждую\s+неделю)\b|毎週", "weekly"),
                       (r"\b(?:every\s+month|monthly|each\s+month|once\s+a\s+month|ежемесячно|каждый\s+месяц)\b|毎月", "monthly"),
                       (r"\b(?:every\s+year|yearly|annually|each\s+year|once\s+a\s+year|ежегодно|каждый\s+год)\b|毎年", "yearly")):
            m = T.first(pat)
            if m:
                rec = mk(f)
                T.eat(m)
                if f == "weekly":
                    # the day usually follows right after: "every week on thursday", "каждую неделю по средам"
                    for m2 in T.find(r"(?:\bon\s+|\bв\s+|\bво\s+|\bпо\s+)?(" + _WD_LIST + ")"):
                        if not T.rest()[m.end():m2.start()].strip():
                            rec["byday"] = _days_in(m2.group(1))
                            T.eat(m2)
                        break
                break
    if not rec:
        return None
    # the days may come later: "раз в две недели созвон по четвергам", "every week … on tuesday"
    if rec["freq"] == "weekly" and not rec["byday"]:
        m = T.first(r"(?:\bon\s+|\bпо\s+|\bв\s+|\bво\s+)(" + _WD_LIST + ")")
        if m and _days_in(m.group(1)):
            rec["byday"] = _days_in(m.group(1))
            T.eat(m)

    # a redundant second phrasing ("по средам … каждую неделю", "… of every month")
    for pat, f in ((r"\b(?:every\s+week|weekly|еженедельно|каждую\s+неделю)\b", "weekly"),
                   (r"\b(?:of\s+(?:every|each|the)\s+month|every\s+month|monthly|каждого\s+месяца|ежемесячно)\b", "monthly")):
        if rec["freq"] == f:
            m = T.first(pat)
            if m:
                T.eat(m)

    # ── end of the series ──
    m = T.first(r"\b(?:for\s+)?" + _N + r"\s+(?:times|occurrences|sessions|lessons|classes)\b|\b" + _N + r"\s+раза?\b(?!\s+в\s+(?:дн|день|сутки|недел|месяц|год|лет))")
    if m:
        rec["count"] = _n(m.group(1) or m.group(2))
        T.eat(m)
    else:
        m = T.first(r"\bfor\s+(?:the\s+next\s+)?" + _N + r"\s+(day|week|month|year)s?\b"
                    r"|\b(?:в\s+течение|на\s+протяжении)\s+(?:следующих\s+)?" + _N + r"\s+(дн\w*|недел\w*|месяц\w*|лет|год\w*)\b"
                    r"|\b" + _N + r"\s+(недел\w*|месяц\w*|дн\w*)\s+подряд\b")
        if m:
            g = m.groups()
            n, unit = next((_n(g[i]), g[i + 1]) for i in (0, 2, 4) if g[i])
            rec["_span"] = (n, _freq_of(unit))
            T.eat(m)
    if not rec["count"] and "_span" not in rec:
        phrase_en = (r"(?:the\s+)?end\s+of\s+(?:the\s+)?(?:year|month|" + _MON_EN + r")|next\s+(?:month|year)|"
                     + _MON_EN + r"(?:\s+\d{1,2}(?:st|nd|rd|th)?)?(?:,?\s+\d{4})?|(?:the\s+)?\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?" + _MON_EN
                     + r"|\d{4}-\d{2}-\d{2}|\d{1,2}[./]\d{1,2}(?:[./]\d{2,4})?")
        phrase_ru = (r"конца\s+(?:года|месяца|" + _MON_RU + r")|нового\s+года|следующего\s+(?:месяца|года)|\d{1,2}(?:-?го)?\s+"
                     + _MON_RU + "|" + _MON_RU + r"|\d{1,2}[./]\d{1,2}(?:[./]\d{2,4})?")
        m = T.first(r"\b(?:until|till|til|through|thru|up\s+to|ending(?:\s+on)?|ends?\s+on)\s+(" + phrase_en + r")(?![\w])"
                    r"|\bдо\s+(" + phrase_ru + r")(?![\w])|\bпо\s+(\d{1,2}(?:-?е|-?го)?\s+" + _MON_RU + r")")
        if m:
            u = _until_date(m.group(1) or m.group(2) or m.group(3), today)
            if u:
                rec["until"] = u.isoformat()
                T.eat(m)
    return rec


def _finish_recurrence(item: dict, now: dt.datetime):
    """Move the series start onto its first real occurrence and turn "for 10 weeks" into COUNT/UNTIL."""
    from gcal_rec import first_on_or_after, normalize
    rec = item.get("recurrence")
    if not rec:
        return
    span = rec.pop("_span", None)
    today = now.date()
    start = dt.date.fromisoformat(item["date"]) if item.get("date") else today
    if start < today:
        start = today
    first = first_on_or_after(rec, start, item.get("time"), now.replace(tzinfo=None))
    item["date"] = first.isoformat()
    if rec["freq"] == "monthly" and not rec["byday"] and not rec["bymonthday"]:
        rec["bymonthday"] = [first.day]          # "Monthly on day N", as Google shows it
    if span:
        n, unit = span
        if unit == rec["freq"]:
            rec["count"] = n * (len(rec["byday"]) if rec["freq"] == "weekly" and rec["byday"] else 1)
        else:
            days = {"daily": 1, "weekly": 7, "monthly": 30, "yearly": 365}[unit] * n
            rec["until"] = (first + dt.timedelta(days=days - 1)).isoformat()
    item["recurrence"] = normalize(rec)



def parse_rules(text: str, now: dt.datetime) -> dict:
    today = now.date()
    T = _Text(text)
    item = {"kind": None, "title": "", "date": None, "time": None, "duration": None, "allDay": False,
            "location": None, "recurrence": None, "priority": None, "tags": [], "scheduled": None,
            "reminder": None, "parser": "rules"}
    deadline = False

    # ── tags ──
    for m in T.find(r"(?<![\w&])#([\w/-]+)"):
        item["tags"].append("#" + m.group(1))
        T.eat(m)

    # ── priority ──
    prio_pats = [
        (r"\b(?:highest|top)\s+prio(?:rity)?\b|\bp0\b|!!!+|🔺", "highest"),
        (r"\b(?:high|hi)\s+prio(?:rity)?\b|\bprio(?:rity)?\s+high\b|\burgent\b|\basap\b|\bimportant\b|\bp1\b|(?<!!)!!(?!!)|⏫|\bсрочно\b|\bважно\b|\bвысокий\s+приоритет\b|急ぎ|至急|重要", "high"),
        (r"\b(?:medium|normal|mid)\s+prio(?:rity)?\b|\bp2\b|🔼|\bсредний\s+приоритет\b", "medium"),
        (r"\blow\s+prio(?:rity)?\b|\bp3\b|🔽|\bнизкий\s+приоритет\b|\bне\s+срочно\b", "low"),
    ]
    for pat, p in prio_pats:
        m = T.first(pat)
        if m:
            item["priority"] = p
            T.eat(m)
            break

    # ── reminders ("remind me day before", "напомни за час", "remind me at 9") ──
    rem_offset = None
    rem_time = None
    m = T.first(r"(?:,?\s*)\b(?:remind(?:\s+me)?|reminder|напомни(?:ть)?(?:\s+мне)?|リマインド)\s*"
                r"(?:(?:a|the|1|one)?\s*(day|hour|week)\s+before|(\d+)\s*(min(?:ute)?s?|h(?:ours?)?|days?)\s+before"
                r"|за\s+(день|час|неделю|сутки|(\d+)\s*(минут\w*|час\w*|дн\w*))"
                r"|(?:at|в)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?")
    if m:
        unit = (m.group(1) or m.group(4) or "").lower()
        if unit in ("day", "день", "сутки"):
            rem_offset = dt.timedelta(days=1)
        elif unit in ("hour", "час"):
            rem_offset = dt.timedelta(hours=1)
        elif unit in ("week", "неделю"):
            rem_offset = dt.timedelta(weeks=1)
        elif m.group(2):
            n, u = int(m.group(2)), m.group(3).lower()
            rem_offset = dt.timedelta(minutes=n) if u.startswith("min") else (dt.timedelta(hours=n) if u.startswith("h") else dt.timedelta(days=n))
        elif m.group(5):
            n, u = int(m.group(5)), m.group(6).lower()
            rem_offset = dt.timedelta(minutes=n) if u.startswith("мин") else (dt.timedelta(hours=n) if u.startswith("час") else dt.timedelta(days=n))
        elif m.group(7):
            h = int(m.group(7)) + (12 if (m.group(9) or "").lower() == "pm" and int(m.group(7)) < 12 else 0)
            rem_time = _hhmm(h, int(m.group(8) or 0))
        else:
            rem_offset = dt.timedelta(minutes=0)
        T.eat(m)

    # ── recurrence (repeat rule + its end: "until December", "10 times", "до конца года") ──
    item["recurrence"] = _eat_recurrence(T, item, today)

    # ── relative "in 2 hours" / "через 2 часа" / "через полчаса" (date + time) ──
    m = T.first(r"\b(?:in|через)\s+(\d+(?:[.,]\d+)?|an?|one|two|three|half\s+an|полчаса|час|полтора|два|три|пару)?\s*"
                r"(hours?|hrs?|h|minutes?|mins?|m|час\w*|минут\w*|мин|полчаса)\b|(\d+)\s*(時間|分)後")
    if m and (m.group(2) or m.group(4)):
        unit = (m.group(2) or m.group(4)).lower()
        raw = (m.group(1) or m.group(3) or "1").lower()
        if raw in ("half an", "полчаса") or unit == "полчаса":
            mins = 30
        else:
            n = {"пару": 2}.get(raw) or _num(raw)
            mins = n * 60 if unit[0] in "hч" or unit == "時間" else n
        at = now + dt.timedelta(minutes=mins)
        item["date"], item["time"] = at.date().isoformat(), at.strftime("%H:%M")
        T.eat(m)

    # ── time ranges & times ──
    def eat_time():
        # 15:00-16:30, 3-4pm, с 15 до 17, 3pm–5pm
        m = T.first(r"(?:\bс\s+|\bfrom\s+)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|to|до)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"
                    r"|(?:\bс\s+|\bfrom\s+)?\b(\d{1,2}):(\d{2})\s*(?:-|–|—|to|до)\s*(\d{1,2}):(\d{2})\b"
                    r"|\bс\s+(\d{1,2})(?::(\d{2}))?\s+до\s+(\d{1,2})(?::(\d{2}))?\b")
        if m:
            g = m.groups()
            if g[0]:
                h1, m1, ap1, h2, m2, ap2 = int(g[0]), int(g[1] or 0), (g[2] or g[5]).lower(), int(g[3]), int(g[4] or 0), g[5].lower()
                if ap2 == "pm" and h2 < 12:
                    h2 += 12
                if ap1 == "pm" and h1 < 12:
                    h1 += 12
                if h1 > h2:
                    h1 -= 12 if h1 >= 12 else 0
            elif g[6]:
                h1, m1, h2, m2 = int(g[6]), int(g[7]), int(g[8]), int(g[9])
            else:
                h1, m1, h2, m2 = int(g[10]), int(g[11] or 0), int(g[12]), int(g[13] or 0)
            s, e = _hhmm(h1, m1), _hhmm(h2, m2)
            if s and e:
                item["time"] = s
                d = (h2 * 60 + m2) - (h1 * 60 + m1)
                item["duration"] = d if d > 0 else d + 24 * 60
                T.eat(m)
                return True
        m = T.first(r"(?:\b(?:at|@|в|во|к)\s*)?\b(\d{1,2})(?::|\.)?(\d{2})?\s*(am|pm|a\.m\.|p\.m\.)(?!\w)"
                    r"|(?:\b(?:at|@|в|во|к)\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\b"
                    r"|\b(?:at|в|во|к)\s+(\d{1,2})(?:\s*(утра|дня|вечера|ночи|h|ч))?(?=\s|$|,)(?!\s*(?:" + "|".join(MONTHS_RU) + "|" + "|".join(MONTHS_EN) + r"|числ|-?го\b|th\b|st\b|nd\b|rd\b))"
                    r"|(\d{1,2})時(?:(\d{1,2})分|(半))?"
                    r"|\b(noon|midday|midnight|полдень|полночь|tonight|this\s+evening|in\s+the\s+morning|in\s+the\s+evening|in\s+the\s+afternoon|morning|afternoon|evening|утром|вечером|днём|днем|ночью)\b")
        if not m:
            # approximate / spelled-out hours: "around 4", "about five pm", "где-то с четырёх", "в семь вечера"
            m = T.first(r"(?:\b(?:at\s+)?(?:around|about|approx\.?|roughly|около|примерно(?:\s+в)?|где-?то(?:\s+(?:в|с|к|около))?)\s*|~\s*)"
                        r"(\d{1,2}|" + _HOUR_WORDS + r")(?:[:.](\d{2}))?(?:\s*(am|pm|утра|дня|вечера|ночи|o'?clock))?(?![\w:./])"
                        r"|\b(?:at|в|во|к|с|начиная\s+с)\s+(" + _HOUR_WORDS + r")(?:\s*(am|pm|утра|дня|вечера|ночи|o'?clock))?\b")
            if not m:
                return False
            raw, mins, suf = (m.group(1), m.group(2), m.group(3)) if m.group(1) else (m.group(4), None, m.group(5))
            h = int(raw) if raw.isdigit() else _HOUR_NUM.get(raw.lower(), 0)
            suf = (suf or "").lower()
            if suf in ("pm", "вечера", "дня") and h < 12:
                h += 12
            elif suf == "am" and h == 12:
                h = 0
            elif not suf and 1 <= h <= 7:
                h += 12
            t = _hhmm(h, int(mins or 0)) if 0 < h <= 24 else None
            if t:
                item["time"] = t
                T.eat(m)
                return True
            return False
        g = m.groups()
        t = None
        if g[0]:
            h = int(g[0]) % 12 + (12 if g[2].lower().startswith("p") else 0)
            t = _hhmm(h, int(g[1] or 0))
        elif g[3]:
            t = _hhmm(int(g[3]), int(g[4]))
        elif g[5]:
            h = int(g[5])
            suf = (g[6] or "").lower()
            if suf in ("вечера", "дня") and h < 12:
                h += 12
            elif not suf and 1 <= h <= 7:
                h += 12          # "at 3" → 15:00 (nobody books 3 am)
            t = _hhmm(h)
        elif g[7]:
            t = _hhmm(int(g[7]), 30 if g[9] else int(g[8] or 0))
        elif g[10]:
            w = g[10].lower()
            t = {"noon": "12:00", "midday": "12:00", "полдень": "12:00", "midnight": "00:00", "полночь": "00:00",
                 "tonight": "20:00", "this evening": "19:00", "in the evening": "19:00", "вечером": "19:00",
                 "in the morning": "09:00", "утром": "09:00", "morning": "09:00", "afternoon": "15:00", "in the afternoon": "15:00", "evening": "19:00", "днём": "14:00", "днем": "14:00", "ночью": "23:00"}.get(re.sub(r"\s+", " ", w))
        if t:
            item["time"] = t
            T.eat(m)
            return True
        return False

    if not item["time"]:
        eat_time()

    # ── durations ──
    m = T.first(r"\b(?:for\s+)?(?:a\s+)?couple\s+(?:of\s+)?hours\b|\b(?:на\s+)?пар[уа]\s+час(?:ов|а)\b|\bчаса\s+(два|три|четыре)\b"
                r"|\b(?:for\s+)?an\s+hour\s+or\s+two\b|\bчас(?:ик)?\s+или\s+два\b")
    if m and not item["duration"]:
        item["duration"] = {"три": 180, "четыре": 240}.get((m.group(1) or "").lower(), 120)
        T.eat(m)
    m = T.first(r"\b(?:for\s+)?(\d+(?:[.,]\d+)?|an?|one|two|three|half\s+an)\s*(h|hrs?|hours?|m|mins?|minutes?)\b(?:\s*(\d+)\s*(?:m|min)\b)?"
                r"|\b(\d+)h(\d+)\b"
                r"|\bна\s+(\d+(?:[.,]\d+)?|полтора|два|три|пару)?\s*(час\w*|минут\w*|мин)\b"
                r"|\b(полтора\s+часа|полчаса)\b"
                r"|(\d+(?:[.,]\d+)?)\s*(час\w*|ч|минут\w*|мин)\b"
                r"|(\d+)(時間|分)(?!後)")
    if m and not item["duration"]:
        g = m.groups()
        mins = None
        if g[0]:
            raw = g[0].lower()
            n = 0.5 if raw == "half an" else _num(raw)
            mins = n * 60 if g[1].lower().startswith("h") else n
            if g[2]:
                mins += int(g[2])
        elif g[3]:
            mins = int(g[3]) * 60 + int(g[4])
        elif g[6]:
            n = {"пару": 2}.get((g[5] or "").lower()) or _num(g[5] or "1")
            mins = n * 60 if g[6].lower().startswith("час") else n
        elif g[7]:
            mins = 90 if g[7].lower().startswith("полтора") else 30
        elif g[9]:
            n = _num(g[8])
            mins = n * 60 if g[9].lower().startswith("ч") else n
        elif g[11]:
            mins = int(g[10]) * (60 if g[11] == "時間" else 1)
        if mins and 0 < mins <= 24 * 60:
            item["duration"] = int(round(mins))
            T.eat(m)

    # ── dates ──
    def set_date(d: dt.date, m):
        if not item["date"] or item["recurrence"]:
            item["date"] = d.isoformat()
        T.eat(m)

    dl_prefix = r"(?:\b(by|before|due|until|till|no\s+later\s+than|до|к|ко|не\s+позже)\s+)?"
    simple = [
        (r"\b(day\s+after\s+tomorrow|послезавтра)\b|明後日|あさって", 2),
        (r"\b(tomorrow|tmrw|tmr|tmrow|tomorow|завтра)\b|明日|あした", 1),
        (r"\b(today|tonight|сегодня|сёдня)\b|今日|今夜", 0),
        (r"\b(yesterday|вчера)\b", -1),
    ]
    for pat, off in simple:
        m = T.first(dl_prefix + "(?:" + pat + ")")
        if m:
            deadline |= bool(m.group(1))
            set_date(today + dt.timedelta(days=off), m)
            if "tonight" in m.group(0).lower() and not item["time"]:
                item["time"] = "20:00"
            break
    if not item["date"]:
        m = T.first(dl_prefix + r"\b(?:end\s+of\s+(?:the\s+)?(month|week|year)|(?:в\s+|к\s+|до\s+)?конц[ауе]\s+(месяца|недели|года))\b|(月末|週末)")
        if m:
            deadline = True
            u = (m.group(2) or m.group(3) or m.group(4) or "").lower()
            if u in ("month", "месяца", "月末"):
                nm = (today.replace(day=28) + dt.timedelta(days=4)).replace(day=1)
                d = nm - dt.timedelta(days=1)
            elif u in ("week", "недели", "週末"):
                d = _next_weekday(today, 6)
            else:
                d = dt.date(today.year, 12, 31)
            set_date(d, m)
    if not item["date"]:
        m = T.first(dl_prefix + r"\b(?:(next|this|coming|следующ\w+|эт\w+|ближайш\w+)\s+)?(?:on\s+|в\s+|во\s+|на\s+)?(" + WD_ANY + r")\b|(" + "|".join(WD_JA) + r")日?")
        if m:
            wd = _wd_index(m.group(3) or m.group(4))
            if wd is not None:
                deadline |= bool(m.group(1))
                nxt = (m.group(2) or "").lower()
                # same weekday as today means next week, unless "this …"/"эт…"
                d = _next_weekday(today, wd, force_next=not nxt.startswith(("this", "эт")))
                set_date(d, m)
    if not item["date"]:
        m = T.first(dl_prefix + r"\b(next\s+week|на\s+следующей\s+неделе|следующей\s+неделе)\b|来週")
        if m:
            deadline |= bool(m.group(1))
            set_date(_next_weekday(today, 0, force_next=True), m)
    if not item["date"]:
        m = T.first(dl_prefix + r"\b(?:in|через)\s+(\d+|a|an|one|two|three|пару|один|два|три|неделю|месяц)?\s*(days?|weeks?|months?|дн\w*|день|недел\w*|месяц\w*)\b|(\d+)(日|週間)後")
        if m:
            deadline |= bool(m.group(1))
            raw = (m.group(2) or m.group(4) or "1").lower()
            u = (m.group(3) or m.group(5) or "").lower()
            n = {"пару": 2, "неделю": 1, "месяц": 1}.get(raw) or int(_num(raw))
            if raw == "неделю":
                u = "week"
            if u.startswith(("week", "недел", "週")):
                d = today + dt.timedelta(weeks=n)
            elif u.startswith(("month", "месяц")):
                d = today + dt.timedelta(days=30 * n)
            else:
                d = today + dt.timedelta(days=n)
            set_date(d, m)
    if not item["date"]:
        # "Oct 14", "14 Oct", "14 октября", "14.10", "2026-10-14", "on the 14th", "14-го", "14日"
        mon_en = "(?:" + "|".join(MONTHS_EN) + r")[a-z]*\.?"
        mon_ru = "(?:" + "|".join(MONTHS_RU) + r")\w*"
        m = T.first(dl_prefix + r"(?:\bon\s+)?(?:the\s+)?\b(?:(\d{4})-(\d{2})-(\d{2})"
                    r"|(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(" + mon_en + r")|(" + mon_en + r")\s+(\d{1,2})(?:st|nd|rd|th)?"
                    r"|(\d{1,2})\s+(" + mon_ru + r")"
                    r"|(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?"
                    r"|(\d{1,2})(?:st|nd|rd|th|-?го|-?е)\b)|(\d{1,2})月(\d{1,2})日|\b(\d{1,2})日")
        if m:
            g = m.groups()
            y, mo, d = today.year, None, None
            try:
                if g[1]:
                    y, mo, d = int(g[1]), int(g[2]), int(g[3])
                elif g[4]:
                    d, mo = int(g[4]), MONTHS_EN.index(g[5][:3].lower()) + 1
                elif g[6]:
                    mo, d = MONTHS_EN.index(g[6][:3].lower()) + 1, int(g[7])
                elif g[8]:
                    d = int(g[8])
                    mo = next(i + 1 for i, p in enumerate(MONTHS_RU) if re.match(p, g[9].lower()))
                elif g[10]:
                    d, mo = int(g[10]), int(g[11])
                    if g[12]:
                        y = int(g[12]) + (2000 if len(g[12]) == 2 else 0)
                elif g[13]:
                    d = int(g[13])
                elif g[14]:
                    mo, d = int(g[14]), int(g[15])
                elif g[16]:
                    d = int(g[16])
                if mo is None:
                    mo = today.month
                    cand = dt.date(y, mo, d)
                    if cand < today:
                        cand = (cand.replace(day=1) + dt.timedelta(days=32)).replace(day=d)
                else:
                    cand = dt.date(y, mo, d)
                    if cand < today - dt.timedelta(days=1) and not g[1] and not g[12]:
                        cand = cand.replace(year=y + 1)
                deadline |= bool(g[0])
                set_date(cand, m)
            except (ValueError, StopIteration):
                pass
    # a second time expression may follow the date ("tomorrow at 15")
    if not item["time"]:
        eat_time()

    # ── location ──
    m = T.first(r"\b(?:near|at|in\s+room|room|@)\s+([A-ZА-ЯЁ0-9][\w\-.]*(?:\s+[A-ZА-ЯЁ0-9][\w\-.]*)*|the\s+\w+(?:\s+\w+)?|\w+\s+(?:station|office|cafe|café|library|park|gym|metro))"
                r"|\b(near\s+(?:the\s+)?\w+(?:\s+\w+)?)\b"
                r"|\b((?:у|возле|около|рядом\s+с)\s+\w+(?:\s+\w+)?)\b"
                r"|\b(?:в|во)\s+((?:аудитори\w+|кабинет\w*|ауд\.?)\s*[\w\-]+|[А-ЯЁ][\w\-]+(?:\s+[А-ЯЁ][\w\-]+)*)", 0)
    if m:
        loc = next(g for g in m.groups() if g)
        if not re.fullmatch(r"\d{1,2}(:\d{2})?", loc) and loc.lower() not in ("the morning", "the evening"):
            item["location"] = loc.strip()
            T.eat(m)

    daypart = item.pop("_daypart", None)
    if daypart and not item["time"]:
        item["time"] = daypart
    _finish_recurrence(item, now)

    # ── kind ──
    event_words = r"\b(meeting|meet|call with|lunch|dinner|breakfast|appointment|dentist|doctor|lecture|class|seminar|exam|party|concert|flight|gym|workout|interview|conference|wedding|birthday|trip|festival|game|match|встреч\w*|созвон\w*|обед|ужин|лекци\w*|семинар\w*|экзамен\w*|врач\w*|стоматолог\w*|спортзал\w*|тренировк\w*|концерт\w*|вечеринк\w*|собеседовани\w*|конференци\w*|свадьб\w*|день\s+рождения|поездк\w*|матч\w*)\b|会議|歯医者|ジム"
    task_words = r"\b(submit|finish|read|buy|call|write|send|pay|fix|prepare|review|learn|study|clean|do|сдать|сделать|купить|позвонить|написать|отправить|прочитать|прочесть|оплатить|подготовить|выучить|доделать|починить)\b"
    has_event_word = bool(re.search(event_words, text, re.I))
    has_task_word = bool(re.search(task_words, text, re.I))
    if deadline:
        kind = "task"
    elif item["time"] and (item["duration"] or item["location"] or has_event_word or item["recurrence"]):
        kind = "event"
    elif item["time"] and not has_task_word:
        kind = "event"
    elif has_event_word and item["date"] and not has_task_word:
        kind = "event"
    else:
        kind = "task"
    item["kind"] = kind
    item["found"] = [k for k in ("date", "time", "duration", "recurrence", "priority", "location", "reminder") if item[k]]
    if rem_offset is not None or rem_time:
        item["found"].append("reminder")
    if deadline or has_event_word or has_task_word or (item["time"] and item["duration"]):
        item["found"].append("kind")
    if deadline:
        item["found"].append("deadline")

    if kind == "task" and not item["date"] and not item["recurrence"]:
        item["date"] = today.isoformat()
    if kind == "event":
        if not item["date"]:
            item["date"] = today.isoformat() if not item["time"] or item["time"] > now.strftime("%H:%M") else (today + dt.timedelta(days=1)).isoformat()
        item["allDay"] = not item["time"]
        if item["time"] and not item["duration"]:
            item["duration"] = 60
    # task with a clock time → reminder at that time
    if kind == "task" and item["time"] and not rem_offset and not rem_time:
        rem_time = item["time"]
    if rem_offset is not None or rem_time:
        base_d = dt.date.fromisoformat(item["date"]) if item["date"] else today
        if rem_time and rem_offset is None:
            item["reminder"] = {"date": base_d.isoformat(), "time": rem_time}
        else:
            base_t = item["time"] or "09:00"
            at = dt.datetime.combine(base_d, dt.time.fromisoformat(base_t)) - rem_offset
            if not item["time"] and rem_offset >= dt.timedelta(days=1):
                at = at.replace(hour=9, minute=0)
            item["reminder"] = {"date": at.date().isoformat(), "time": at.strftime("%H:%M")}
            if kind == "task" and rem_offset >= dt.timedelta(days=1):
                item["scheduled"] = at.date().isoformat()

    # ── title ──
    rest = T.rest()
    rest = re.sub(r"\b(on|at|by|for|the|in|before|due|until|и|в|во|к|до|на|с|по)\s*(?=[,.;]|$)", " ", rest, flags=re.I)
    rest = re.sub(r"(^|\s)(on|at|by|for|before|due|until|в|во|к|до|на|с|по)(\s+(on|at|by|в|на|к))*\s*$", " ", rest, flags=re.I)
    rest = re.sub(r"^\s*(on|at|by|в|во|к|на|до)\s+", "", rest, flags=re.I)
    rest = re.sub(r"\s*[,;]\s*(?=[,;]|$)", "", rest)
    rest = re.sub(r"\s{2,}", " ", rest).strip(" ,.;:-—–")
    rest = re.sub(r"^(?:starting|beginning|from|начиная(?:\s+с)?)\s+|\s+(?:starting|beginning|начиная(?:\s+с)?)$", "", rest, flags=re.I)
    short = _tidy_title(rest)
    if short != rest:
        item["notes"] = text.strip()           # nothing is lost: the whole note goes to the description
    rest = short
    item["title"] = (rest[:1].upper() + rest[1:]) if rest else text.strip()
    item["confident"] = _confident(text, rest, short is not None and "notes" not in item)
    return item


# ── deterministic title clean-up and the "rules are enough" check ──
_FILLER_RE = re.compile(r"\b(?:i\s+(?:want|need|have|would\s+like|'d\s+like|wanna|gotta)\s+to|i'?ll|i\s+will|i'?m\s+going\s+to|"
                        r"i\s+should|gonna|wanna|let'?s|хочу|хотела?|надо|нужно|мне|собираюсь|буду|наверное|наверно|"
                        r"может\s+быть|кажется)\b", re.I)
_EDGE_FILLER_RE = re.compile(r"^(?:(?:so|and|then|well|ok|okay|maybe|probably|also|i|я|ну|так|и|потом|ещё|еще|может)\b[\s,]*)+"
                             r"|(?:[\s,]+\b(?:maybe|probably|perhaps|or\s+so|наверное|может|возможно|или\s+около\s+того))+$", re.I)


def _tidy_title(t: str) -> str:
    """Long rambling notes get a short title (first clause, <= 8 words); short ones stay as typed."""
    words = t.split()
    if len(words) <= 8 and len(t) <= 60:
        return t
    s = _FILLER_RE.sub(" ", t)
    s = re.sub(r"\s{2,}", " ", s).strip(" ,.;:-")
    for _ in range(3):
        s2 = _EDGE_FILLER_RE.sub("", s).strip(" ,.;:-")
        if s2 == s:
            break
        s = s2
    if len(s.split()) > 8:
        first = re.split(r"[.;!?]\s|\s*,\s*|\s+(?:and|and\s+then|then|but|и|а|но|потом)\s+", s)[0].strip()
        if len(first.split()) >= 2:
            s = first
    w = s.split()
    if len(w) > 9:
        w = w[:9]
        while len(w) > 2 and re.fullmatch(r"(?:a|an|the|to|of|with|for|and|at|in|on|в|во|с|со|и|к|на|по|для|из)", w[-1], re.I):
            w.pop()
        s = " ".join(w)
    return s or t


_VAGUE_RE = re.compile(r"\d|\b(?:after|before|around|about|until|till|next|this|last|morning|evening|night|noon|tonight|weekends?|"
                       r"later|soon|maybe|probably|o'?clock|am|pm|hours?|minutes?|mins?|days?|weeks?|months?|years?|times|twice|"
                       r"every|each|other|once|daily|weekly|monthly|first|second|third|fourth|fifth|1st|2nd|3rd|4th|5th|"
                       r"mon|tue|wed|thu|fri|sat|sun|(?:mon|tues|wednes|thurs|fri|satur|sun)days?|"
                       r"jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec|january|february|march|april|june|july|august|"
                       r"september|october|november|december)\b"
                       r"|\b(?:после|перед|около|где-?то|примерно|потом|позже|скоро|наверн|может|утр|вечер|ноч|недел|месяц|перв|трет|четв[её]рт|последн|"
                       r"год|числ|час|минут|дн|день|раз|кажд|через|выходн|будн|понедельн|вторн|сред|четверг|пятниц|суббот|"
                       r"воскрес|январ|феврал|март|апрел|мая|июн|июл|август|сентябр|октябр|ноябр|декабр)\w*", re.I)


def _confident(text: str, title: str, untouched: bool) -> bool:
    """True when the rule parse is final and the LLM can be skipped: a short note whose leftover title
    has no numbers or time-ish words the rules failed to understand."""
    if not untouched or not title or len(text) > 90 or len(text.split()) > 14:
        return False
    if len(title.split()) > 6:
        return False
    return not _VAGUE_RE.search(title)


# ───────────────────────────── LLM ─────────────────────────────

SCHEMA = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": ["task", "event"]},
        "title": {"type": "string"},
        "date": {"type": ["string", "null"]},
        "time": {"type": ["string", "null"]},
        "duration": {"type": ["integer", "null"]},
        "location": {"type": ["string", "null"]},
        "recurrence": {"type": ["string", "null"], "enum": [None, "daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"]},
        "byday": {"type": "array", "items": {"type": "string", "enum": WD_CODES}},
        "tags": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["kind", "title", "date", "time", "duration", "location", "recurrence", "byday", "tags"],
    "additionalProperties": False,
}


def _prompt(text: str, now: dt.datetime, ctx: dict) -> list:
    today = now.date()
    days = []
    for i in range(0, 15):
        d = today + dt.timedelta(days=i)
        label = " (today)" if i == 0 else (" (tomorrow)" if i == 1 else "")
        days.append(f"{d.strftime('%a')} {d.isoformat()}{label}")
    eom = ((today.replace(day=28) + dt.timedelta(days=4)).replace(day=1) - dt.timedelta(days=1)).isoformat()
    sys_msg = (
        "You turn a quick scratch note (English, Russian or Japanese) into a calendar event or a to-do task. "
        "Reply with JSON only.\n"
        f"Now: {now.strftime('%A %Y-%m-%d %H:%M')} (timezone {SYSTEM_TZ}). End of this month: {eom}.\n"
        "Next days: " + "; ".join(days) + ".\n"
        "Rules:\n"
        "- event = something that happens at a time/place (meeting, appointment, class, gym, call with someone at a time). "
        "task = something to do, possibly with a deadline ('by friday', 'до пятницы', 'submit', 'read', 'buy', 'call mom').\n"
        "- date: YYYY-MM-DD (event day or task due date). Tasks without any date are due today. "
        "Weekday names mean the next such day (today if it is that weekday and still upcoming).\n"
        "- time: HH:MM 24h start time or null. '3pm'→15:00, 'в 7 вечера'→19:00, 'через 2 часа' = now+2h.\n"
        "- duration: minutes for events (default 60 when a time is given), null for tasks.\n"
        "- recurrence: daily|weekdays|weekly|biweekly|monthly|yearly or null; byday: weekday codes for weekly (MO..SU).\n"
        "- tags: '#tag' words the user wrote, plus at most one fitting tag from the known list.\n"
        "- title: short; ALWAYS in the same language and script as the note (never translate); "
        "drop the date/time/priority words; capitalize the first letter.\n"
    )
    if ctx.get("calendars"):
        sys_msg += "Known calendars: " + ", ".join(ctx["calendars"]) + ".\n"
    if ctx.get("tags"):
        sys_msg += "Known tags: " + " ".join(ctx["tags"][:25]) + ".\n"
    if ctx.get("projects"):
        sys_msg += "Known notes/projects: " + ", ".join(ctx["projects"][:20]) + ".\n"
    t1 = (today + dt.timedelta(days=1)).isoformat()
    fri = (today + dt.timedelta(days=(4 - today.weekday()) % 7 or 7)).isoformat()
    shots = [
        ("dentist tmrw 3pm 1h near metro",
         {"kind": "event", "title": "Dentist", "date": t1, "time": "15:00", "duration": 60, "location": "near metro",
          "recurrence": None, "byday": [], "tags": []}),
        ("купить подарок брату до пятницы",
         {"kind": "task", "title": "Купить подарок брату", "date": fri, "time": None, "duration": None, "location": None,
          "recurrence": None, "byday": [], "tags": []}),
    ]
    msgs = [{"role": "system", "content": sys_msg}]
    for u, a in shots:
        msgs += [{"role": "user", "content": u}, {"role": "assistant", "content": json.dumps(a, ensure_ascii=False, separators=(",", ":"))}]
    msgs.append({"role": "user", "content": text})
    return msgs


def llm_status(base=LLM_URL, timeout=0.6) -> str:
    """"online" | "loading" | "offline".
    The LLM is socket-activated (npu-llm.socket): the first request is accepted at once but only
    answered once the model has loaded (~45 s), so a timeout means "loading", not "offline"."""
    import socket
    import urllib.error
    try:
        with urllib.request.urlopen(base + "/health", timeout=timeout) as r:
            body = r.read(200).decode("utf-8", "replace")
            if r.status == 200 and "loading" not in body.lower():
                return "online"
            return "loading"
    except urllib.error.HTTPError as e:      # llama-server answers 503 {"status":"loading model"}
        return "loading" if e.code == 503 else "offline"
    except (TimeoutError, socket.timeout):
        return "loading"
    except urllib.error.URLError as e:
        return "loading" if isinstance(e.reason, (TimeoutError, socket.timeout)) else "offline"
    except Exception:
        return "offline"


def llm_health(base=LLM_URL, timeout=0.6) -> bool:
    return llm_status(base, timeout) == "online"


def parse_llm(text: str, now: dt.datetime, ctx: dict, base=LLM_URL, timeout=20.0) -> dict:
    payload = {
        "model": "local",
        "messages": _prompt(text, now, ctx),
        "temperature": 0,
        "max_tokens": 160,
        "response_format": {"type": "json_schema", "json_schema": {"name": "capture", "strict": True, "schema": SCHEMA}},
    }
    req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
    content = data["choices"][0]["message"]["content"]
    raw = json.loads(content[content.find("{"): content.rfind("}") + 1])
    return normalize_llm(raw, text, now, int((time.monotonic() - t0) * 1000))


def normalize_llm(raw: dict, text: str, now: dt.datetime, ms: int) -> dict:
    def date_ok(v):
        try:
            return dt.date.fromisoformat(v).isoformat() if v else None
        except Exception:
            return None

    def time_ok(v):
        m = re.fullmatch(r"(\d{1,2}):(\d{2})", (v or "").strip())
        return _hhmm(int(m.group(1)), int(m.group(2))) if m else None

    kind = raw.get("kind") if raw.get("kind") in ("task", "event") else "task"
    item = {"kind": kind, "title": (raw.get("title") or text).strip()[:200], "date": date_ok(raw.get("date")),
            "time": time_ok(raw.get("time")), "duration": None, "allDay": False,
            "location": (raw.get("location") or "").strip() or None, "recurrence": None,
            "priority": None,
            "tags": [], "scheduled": None, "reminder": None, "parser": "llm", "ms": ms}
    try:
        dur = int(raw.get("duration") or 0)
        item["duration"] = dur if 0 < dur <= 24 * 60 else None
    except Exception:
        pass
    for t in raw.get("tags") or []:
        t = "#" + re.sub(r"[^\w/-]", "", str(t).lstrip("#"))
        if len(t) > 1 and t not in item["tags"]:
            item["tags"].append(t)
    rec = raw.get("recurrence")
    byday = [d for d in (raw.get("byday") or []) if d in WD_CODES]
    if rec == "weekdays":
        item["recurrence"] = {"freq": "weekly", "interval": 1, "byday": WD_CODES[:5], "text": "every weekday"}
    elif rec in ("daily", "weekly", "biweekly", "monthly", "yearly"):
        freq = "weekly" if rec == "biweekly" else rec
        interval = 2 if rec == "biweekly" else 1
        if freq == "weekly" and not byday and item["date"]:
            byday = [WD_CODES[dt.date.fromisoformat(item["date"]).weekday()]]
        txt = {"daily": "every day", "monthly": "every month", "yearly": "every year"}.get(freq)
        if freq == "weekly":
            names = ", ".join(WD_EN[WD_CODES.index(d)].capitalize() for d in byday) if byday else "week"
            txt = ("every 2 weeks on " if interval == 2 else "every ") + names
        item["recurrence"] = {"freq": freq, "interval": interval, "byday": byday if freq == "weekly" else [], "text": txt}
    today = now.date()
    if not item["date"]:
        item["date"] = today.isoformat()
    if kind == "event":
        item["allDay"] = not item["time"]
        if item["time"] and not item["duration"]:
            item["duration"] = 60
    else:
        item["duration"] = None
    if kind == "task" and item["time"]:
        item["reminder"] = {"date": item["date"], "time": item["time"]}
    return item


def _script(t: str) -> str:
    if re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", t):
        return "ja"
    if re.search(r"[А-Яа-яЁё]", t):
        return "ru"
    return "en"


def merge(rules: dict, llm: dict, text: str) -> dict:
    """Hybrid: the rule parser owns everything it explicitly found (dates, times, durations,
    repeats, priority, reminders — it is exact there); the LLM fills the gaps and judges
    kind, place and title."""
    found = set(rules.get("found") or [])
    out = dict(llm)
    for f in ("date", "time", "duration", "recurrence", "reminder", "scheduled"):
        if f in found or (f == "scheduled" and rules.get("scheduled")):
            out[f] = rules[f]
    out["priority"] = rules.get("priority")
    if "kind" in found:
        out["kind"] = rules["kind"]
    if not out.get("title") or _script(out["title"]) != _script(text) or len(out["title"]) > len(text) + 5:
        out["title"] = rules["title"]
    if not out.get("location") and rules.get("location"):
        out["location"] = rules["location"]
    tags = list(rules.get("tags") or [])
    for t in out.get("tags") or []:
        if t not in tags:
            tags.append(t)
    out["tags"] = tags
    if out["kind"] == "event":
        out["allDay"] = not out.get("time")
        if out.get("time") and not out.get("duration"):
            out["duration"] = 60
    else:
        out["duration"] = None
        out["allDay"] = False
        if out.get("time") and not out.get("reminder"):
            out["reminder"] = {"date": out["date"], "time": out["time"]}
    out["parser"] = "llm"
    out["hybrid"] = True
    return out


# ── compact LLM step (2026-10): the model only names things (kind, short title, place) and copies the
# note's own date/time/repeat words; the rule parser turns those words into dates. Short static prompt,
# ~30 output tokens, so a warm 4B model answers in ~1-2 s instead of ~4-6 s, and never miscounts weekdays.
SCHEMA_SMART = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": ["task", "event"]},
        "title": {"type": "string"},
        "when": {"type": ["string", "null"]},
        "repeat": {"type": ["string", "null"]},
        "place": {"type": ["string", "null"]},
    },
    "required": ["kind", "title", "when", "repeat", "place"],
    "additionalProperties": False,
}
SYSTEM_SMART = (
    "Turn a quick note (English or Russian) into a calendar entry. Reply with JSON only.\n"
    "kind: \"event\" if it happens at a time or place (meeting, class, appointment, sport, going somewhere), "
    "\"task\" if it is something to do (buy, send, submit, read, pay).\n"
    "title: 2-6 words in the note's language, without date, time or repeat words.\n"
    "when: the note's own date/time words copied exactly, or null.\n"
    "repeat: the note's own repeat words copied exactly, or null.\n"
    "place: where, copied from the note, or null."
)
SHOTS_SMART = [
    ("so tmrw after work i want to grab coffee with Alex at the cafe near the office maybe at 6",
     {"kind": "event", "title": "Coffee with Alex", "when": "tmrw after work maybe at 6", "repeat": None,
      "place": "the cafe near the office"}),
    ("надо бы каждую неделю по средам сдавать отчёт начальнику до обеда",
     {"kind": "task", "title": "Сдать отчёт начальнику", "when": "до обеда", "repeat": "каждую неделю по средам", "place": None}),
]


def llm_smart(text: str, base=LLM_URL, timeout=20.0) -> dict:
    msgs = [{"role": "system", "content": SYSTEM_SMART}]
    for u, a in SHOTS_SMART:
        msgs += [{"role": "user", "content": u}, {"role": "assistant", "content": json.dumps(a, ensure_ascii=False, separators=(",", ":"))}]
    msgs.append({"role": "user", "content": text})
    payload = {"model": "local", "messages": msgs, "temperature": 0, "max_tokens": 90,
               "response_format": {"type": "json_schema", "json_schema": {"name": "entry", "strict": True, "schema": SCHEMA_SMART}}}
    req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = json.loads(r.read())
    content = data["choices"][0]["message"]["content"]
    raw = json.loads(content[content.find("{"): content.rfind("}") + 1])
    raw["_ms"] = int((time.monotonic() - t0) * 1000)
    return raw


def merge_smart(rules: dict, raw: dict, text: str, now: dt.datetime) -> dict:
    """Rules own everything they found in the text; the LLM's copied when/repeat words fill the gaps
    (parsed by the same rules); the LLM names the entry (kind, title, place)."""
    found = set(rules.get("found") or [])
    out = dict(rules)
    when = (raw.get("when") or "").strip()
    rep = (raw.get("repeat") or "").strip()
    if (when or rep) and not ({"date", "time"} <= found and (rules.get("recurrence") or not rep)):
        extra = parse_rules((when + " " + rep).strip(), now)
        xf = set(extra.get("found") or [])
        for f in ("date", "time", "duration", "recurrence"):
            if f not in found and f in xf:
                out[f] = extra[f]
        if "recurrence" not in found and extra.get("recurrence"):
            out["date"] = extra["date"]
    kind = raw.get("kind") if raw.get("kind") in ("task", "event") else rules["kind"]
    out["kind"] = rules["kind"] if "deadline" in found else kind
    title = (raw.get("title") or "").strip().strip(".")
    if title and _script(title) == _script(text) and len(title) <= max(len(text), 12):
        out["title"] = title[:1].upper() + title[1:]
    place = (raw.get("place") or "").strip()
    if not rules.get("location") and place and place.lower() in text.lower():
        out["location"] = place
    if len(text.split()) > 8 and len(out["title"]) < len(text) * 0.7:
        out["notes"] = text.strip()
    if out["kind"] == "event":
        out["allDay"] = not out.get("time")
        if out.get("time") and not out.get("duration"):
            out["duration"] = 60
        if not out.get("date"):
            out["date"] = now.date().isoformat()
    else:
        out["duration"] = None
        out["allDay"] = False
        if out.get("time") and not out.get("reminder"):
            out["reminder"] = {"date": out["date"], "time": out["time"]}
    out["parser"] = "llm"
    out["hybrid"] = True
    out["confident"] = True
    out["ms"] = raw.get("_ms")
    return out


def parse_smart(text: str, now: dt.datetime, ctx: dict | None = None, base=LLM_URL, timeout=20.0, force_llm=False) -> dict:
    """Fast path first: a confident rule parse is final (instant). Only hard notes go to the LLM."""
    t0 = time.monotonic()
    rules = parse_rules(text, now)
    rules["ms"] = int((time.monotonic() - t0) * 1000)
    if rules.get("confident") and not force_llm:
        rules["path"] = "rules"
        return rules
    out = merge_smart(rules, llm_smart(text, base=base, timeout=timeout), text, now)
    out["path"] = "llm"
    return out


def parse_hybrid(text: str, now: dt.datetime, ctx: dict, base=LLM_URL, timeout=20.0) -> dict:
    rules = parse_rules(text, now)
    llm = parse_llm(text, now, ctx, base=base, timeout=timeout)
    out = merge(rules, llm, text)
    out["ms"] = llm.get("ms")
    return out


# ───────────────────────────── rendering ─────────────────────────────

def task_line(item: dict, local_uid: str | None = None) -> str:
    """Obsidian Tasks-plugin line: - [ ] title (@reminder) 🔁 ⏫ ⏳ 📅 #tags"""
    parts = [f"- [ ] {item['title'].strip()}"]
    if item.get("kind") == "event" and item.get("time"):
        end = ""
        if item.get("duration"):
            e = dt.datetime.combine(dt.date.today(), dt.time.fromisoformat(item["time"])) + dt.timedelta(minutes=item["duration"])
            end = "–" + e.strftime("%H:%M")
        parts.append(f"🕒 {item['time']}{end}")
    if item.get("location"):
        parts.append(f"📍 {item['location']}")
    if item.get("reminder"):
        parts.append(f"(@{item['reminder']['date']} {item['reminder']['time']})")
    if item.get("recurrence"):
        parts.append("🔁 " + item["recurrence"]["text"])
    if item.get("priority"):
        parts.append(PRIO_EMOJI[item["priority"]])
    if item.get("scheduled"):
        parts.append(f"⏳ {item['scheduled']}")
    if item.get("date"):
        parts.append(f"📅 {item['date']}")
    parts.extend(item.get("tags") or [])
    if local_uid:
        parts.append(f"%%gcal:{local_uid}%%")
    return " ".join(parts)


def vevent(item: dict, uid: str, tzname=SYSTEM_TZ) -> str:
    def esc(s):
        return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    d = dt.date.fromisoformat(item["date"])
    lines = ["BEGIN:VEVENT", f"UID:{uid}", f"DTSTAMP:{now}", f"SUMMARY:{esc(item['title'])}"]
    if item.get("time"):
        s = dt.datetime.combine(d, dt.time.fromisoformat(item["time"]))
        e = s + dt.timedelta(minutes=item.get("duration") or 60)
        lines += [f"DTSTART;TZID={tzname}:{s.strftime('%Y%m%dT%H%M%S')}", f"DTEND;TZID={tzname}:{e.strftime('%Y%m%dT%H%M%S')}"]
    else:
        lines += [f"DTSTART;VALUE=DATE:{d.strftime('%Y%m%d')}", f"DTEND;VALUE=DATE:{(d + dt.timedelta(days=1)).strftime('%Y%m%d')}"]
    if item.get("location"):
        lines.append(f"LOCATION:{esc(item['location'])}")
    rec = item.get("recurrence")
    if rec:
        r = f"RRULE:FREQ={rec['freq'].upper()}"
        if rec.get("interval", 1) > 1:
            r += f";INTERVAL={rec['interval']}"
        if rec.get("byday"):
            r += ";BYDAY=" + ",".join(rec["byday"])
        lines.append(r)
    if item.get("tags"):
        lines.append("CATEGORIES:" + ",".join(esc(t.lstrip("#")) for t in item["tags"]))
    if item.get("reminder") and item.get("time"):
        start = dt.datetime.combine(d, dt.time.fromisoformat(item["time"]))
        at = dt.datetime.combine(dt.date.fromisoformat(item["reminder"]["date"]), dt.time.fromisoformat(item["reminder"]["time"]))
        mins = max(0, int((start - at).total_seconds() // 60))
        lines += ["BEGIN:VALARM", "ACTION:DISPLAY", f"DESCRIPTION:{esc(item['title'])}", f"TRIGGER:-PT{mins}M", "END:VALARM"]
    lines.append("END:VEVENT")
    return "\r\n".join(lines)
