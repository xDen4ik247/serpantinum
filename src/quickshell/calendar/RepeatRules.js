.pragma library
// Repeat rules for the agenda's event editor (same dict shape and wording as gcal_rec.py):
//   { freq: "daily|weekly|monthly|yearly", interval: n, byday: ["MO"] | ["2TU"] | ["-1FR"],
//     bymonthday: [15], count: n|null, until: "YYYY-MM-DD"|null }

var WD_CODES = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"];
var WD_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
var MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August",
                   "September", "October", "November", "December"];
var ORD_WORDS = { "1": "first", "2": "second", "3": "third", "4": "fourth", "5": "fifth", "-1": "last", "-2": "second to last" };
var FREQS = ["daily", "weekly", "monthly", "yearly"];
var UNIT = { daily: "day", weekly: "week", monthly: "month", yearly: "year" };

function dateOf(key) { var p = String(key).split("-"); return new Date(+p[0], +p[1] - 1, +p[2]); }
function keyOf(d) { return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2); }
// Monday = 0 … Sunday = 6
function weekdayIndex(d) { return (d.getDay() + 6) % 7; }
function ordinal(n) {
    var s = (n % 100 >= 11 && n % 100 <= 13) ? "th" : ({ 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th");
    return n + s;
}
function parseByday(c) {
    var m = /^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$/.exec(String(c).toUpperCase().trim());
    return m ? { n: m[1] ? parseInt(m[1]) : 0, wd: m[2] } : null;
}

function normalize(rec) {
    if (!rec || typeof rec !== "object") return null;
    var freq = String(rec.freq || "").toLowerCase();
    if (FREQS.indexOf(freq) < 0) return null;
    var interval = Math.max(1, Math.min(999, parseInt(rec.interval) || 1));
    var byday = [];
    (rec.byday || []).forEach(function (c) {
        var b = parseByday(c);
        if (!b || (b.n && freq !== "monthly" && freq !== "yearly")) return;
        var code = (b.n ? String(b.n) : "") + b.wd;
        if (byday.indexOf(code) < 0) byday.push(code);
    });
    if (freq === "weekly") byday.sort(function (a, b) { return WD_CODES.indexOf(a.slice(-2)) - WD_CODES.indexOf(b.slice(-2)); });
    if (freq === "daily") byday = byday.filter(function (c) { return !parseByday(c).n; });
    var bymonthday = [];
    (rec.bymonthday || []).forEach(function (n) {
        n = parseInt(n);
        if (!isNaN(n) && Math.abs(n) >= 1 && Math.abs(n) <= 31 && bymonthday.indexOf(n) < 0) bymonthday.push(n);
    });
    var count = parseInt(rec.count);
    count = (!isNaN(count) && count >= 1 && count <= 9999) ? count : null;
    var until = rec.until && /^\d{4}-\d{2}-\d{2}/.test(rec.until) ? String(rec.until).slice(0, 10) : null;
    if (count) until = null;
    return { freq: freq, interval: interval, byday: byday, bymonthday: bymonthday, count: count, until: until };
}

function dayList(codes) {
    var names = codes.map(function (c) { return WD_NAMES[WD_CODES.indexOf(c.slice(-2))]; });
    if (names.length <= 2) return names.join(" and ");
    return names.map(function (n) { return n.slice(0, 3); }).join(", ");
}

// "Weekly on Tuesday", "Monthly on the last Friday", "Every 2 weeks on Monday and Wednesday, until Nov 30, 2026"
function describe(rec, startKey) {
    rec = normalize(rec);
    if (!rec) return "Does not repeat";
    var start = startKey ? dateOf(startKey) : null;
    var n = rec.interval, f = rec.freq;
    var head = n === 1 ? { daily: "Daily", weekly: "Weekly", monthly: "Monthly", yearly: "Annually" }[f] : "Every " + n + " " + UNIT[f] + "s";
    var tail = "";
    if (f === "weekly") {
        var days = rec.byday.length ? rec.byday : (start ? [WD_CODES[weekdayIndex(start)]] : []);
        if (days.join() === WD_CODES.slice(0, 5).join() && n === 1) { head = "Every weekday (Monday to Friday)"; days = []; }
        if (days.length) tail = " on " + dayList(days);
    } else if (f === "monthly") {
        if (rec.byday.length) {
            var b = parseByday(rec.byday[0]);
            var k = b.n || 1;
            tail = " on the " + (ORD_WORDS[String(k)] || ordinal(k)) + " " + WD_NAMES[WD_CODES.indexOf(b.wd)];
        } else if (rec.bymonthday.length) {
            tail = " on day " + rec.bymonthday.map(function (d) { return d > 0 ? String(d) : "last"; }).join(", ");
        } else if (start) {
            tail = " on day " + start.getDate();
        }
    } else if (f === "yearly" && start) {
        tail = " on " + MONTH_NAMES[start.getMonth()] + " " + start.getDate();
    } else if (f === "daily" && rec.byday.length) {
        tail = " on " + dayList(rec.byday);
    }
    var out = head + tail;
    if (rec.count) out += rec.count === 1 ? ", 1 time" : ", " + rec.count + " times";
    else if (rec.until) {
        var u = dateOf(rec.until);
        out += ", until " + MONTH_NAMES[u.getMonth()].slice(0, 3) + " " + u.getDate() + ", " + u.getFullYear();
    }
    return out;
}

// which occurrence of its weekday a date is in its month: 1..5, and whether it is the last one
function nthOfMonth(d) {
    var n = Math.floor((d.getDate() - 1) / 7) + 1;
    var next = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 7);
    return { n: n, last: next.getMonth() !== d.getMonth() };
}

// The Repeat menu, like Google's, for an event on `startKey`.
function presets(startKey) {
    var d = dateOf(startKey);
    var wd = WD_CODES[weekdayIndex(d)];
    var nth = nthOfMonth(d);
    var out = [
        { key: "none", rec: null },
        { key: "daily", rec: { freq: "daily" } },
        { key: "weekly", rec: { freq: "weekly", byday: [wd] } },
        { key: "monthday", rec: { freq: "monthly", bymonthday: [d.getDate()] } }
    ];
    if (nth.n <= 4) out.push({ key: "monthnth", rec: { freq: "monthly", byday: [nth.n + wd] } });
    if (nth.last) out.push({ key: "monthlast", rec: { freq: "monthly", byday: ["-1" + wd] } });
    out.push({ key: "yearly", rec: { freq: "yearly" } });
    out.push({ key: "weekdays", rec: { freq: "weekly", byday: WD_CODES.slice(0, 5) } });
    return out.map(function (p) {
        var r = normalize(p.rec);
        return { key: p.key, rec: r, label: describe(r, startKey) };
    });
}

function same(a, b) {
    a = normalize(a); b = normalize(b);
    if (!a || !b) return !a && !b;
    return a.freq === b.freq && a.interval === b.interval && a.byday.join() === b.byday.join()
        && a.bymonthday.join() === b.bymonthday.join() && a.count === b.count && a.until === b.until;
}

// the preset a rule matches (ignoring how it ends), or "custom"
function presetKey(rec, startKey) {
    var r = normalize(rec);
    if (!r) return "none";
    if (r.count || r.until) return "custom";
    var ps = presets(startKey);
    for (var i = 0; i < ps.length; i++) if (same(ps[i].rec, r)) return ps[i].key;
    // weekly without BYDAY means "on the start's weekday"
    if (r.freq === "weekly" && !r.byday.length && r.interval === 1) return "weekly";
    if (r.freq === "monthly" && !r.byday.length && !r.bymonthday.length && r.interval === 1) return "monthday";
    return "custom";
}

// a rule's days/ends adjusted for a new start date (weekly on the old weekday follows the date, like Google)
function retarget(rec, oldKey, newKey) {
    var r = normalize(rec);
    if (!r || !oldKey || !newKey || oldKey === newKey) return r;
    var k = presetKey(r, oldKey);
    if (k === "weekly" || k === "monthday" || k === "monthnth" || k === "monthlast") {
        var ps = presets(newKey);
        for (var i = 0; i < ps.length; i++) if (ps[i].key === k) return ps[i].rec;
        if (k === "monthnth") return presets(newKey).filter(function (p) { return p.key === "monthlast"; })[0].rec;
    }
    return r;
}
