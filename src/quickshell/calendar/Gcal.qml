pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"

// Google Calendar (iCal) + Obsidian agenda data for the desktop.
// Data comes from ~/.cache/gcal-sync/events.json, written by the gcal-sync
// systemd user timer (~/.local/share/gcal-sync/gcal_sync.py). This singleton
// also owns the agenda panel and the quick-capture prompt, and the IPC target:
//   serpantinum ipc call agenda toggle | open | close | day YYYY-MM-DD | month | monthOf YYYY-MM-DD
//                               | mode week|month | capture | refresh | status
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    // test harnesses set GCAL_PASSIVE=1 so the panels never grab the keyboard/pointer
    readonly property bool passive: Quickshell.env("GCAL_PASSIVE") === "1"
    readonly property string syncBin: home + "/.local/bin/gcal-sync"
    readonly property string dataPath: (Quickshell.env("GCAL_SYNC_CACHE") || (home + "/.cache/gcal-sync")) + "/events.json"

    // ── data ────────────────────────────────────────────────────────────
    property var doc: ({})
    property int revision: 0
    property string generated: ""
    readonly property bool loaded: revision > 0
    readonly property bool configured: !!doc.configured
    readonly property var events: doc.events || []
    readonly property var tasks: doc.tasks || []
    readonly property var days: doc.days || ({})
    readonly property var dailyNotes: doc.daily || ({})
    readonly property var calendars: doc.calendars || []
    readonly property var obsidian: doc.obsidian || ({})
    readonly property bool writeEnabled: !!doc.writeEnabled
    readonly property string vaultName: obsidian.vaultName || ""

    // minute clock: drives "now", ended events and the day rollover
    property double nowMs: Date.now()
    Timer {
        interval: 20000; running: true; repeat: true
        onTriggered: root.nowMs = Date.now()
    }
    readonly property string todayKey: { let n = root.nowMs; return Qt.formatDate(new Date(n), "yyyy-MM-dd"); }
    readonly property string tomorrowKey: shiftKey(todayKey, 1)

    FileView {
        id: dataFile
        path: root.dataPath
        watchChanges: true
        blockLoading: false
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.ingest(text())
    }
    // atomic replaces can drop the inotify watch; a slow poll keeps us honest
    Timer {
        interval: 30000; running: true; repeat: true
        onTriggered: dataFile.reload()
    }

    function ingest(txt) {
        if (!txt) return;
        try {
            let d = JSON.parse(txt);
            if (d.generated === root.generated && root.revision > 0) return;
            root.generated = d.generated || "";
            root.doc = d;
            root.revision++;
        } catch (e) {
            console.warn("Gcal: bad events.json:", e);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────
    function keyOf(d) { return Qt.formatDate(d, "yyyy-MM-dd"); }
    function dateOf(key) { let p = key.split("-"); return new Date(+p[0], +p[1] - 1, +p[2]); }
    function shiftKey(key, n) { let d = dateOf(key); d.setDate(d.getDate() + n); return keyOf(d); }

    function colorFor(c) {
        if (!c) return ThemeBackend.blue;
        if (c[0] === "#") return c;
        let v = ThemeBackend[c];
        return (v !== undefined && v !== null) ? v : ThemeBackend.blue;
    }
    function fmtTime(ms) {
        return Qt.formatTime(new Date(ms), DateTime.is12Hour ? "h:mm AP" : "HH:mm");
    }
    function dayLabel(key) {
        if (key === todayKey) return "Today";
        if (key === tomorrowKey) return "Tomorrow";
        if (key === shiftKey(todayKey, -1)) return "Yesterday";
        let d = dateOf(key);
        return Qt.locale().dayName(d.getDay(), Locale.LongFormat) + ", " + Qt.locale().monthName(d.getMonth(), Locale.ShortFormat) + " " + d.getDate();
    }

    // events touching a day (all-day first, then by start)
    function eventsOn(key) {
        let r = revision;
        let out = [];
        for (let e of events) {
            if (e.startDate <= key && e.endDate >= key) out.push(e);
        }
        out.sort((a, b) => (a.allDay === b.allDay ? a.startMs - b.startMs : (a.allDay ? -1 : 1)));
        return out;
    }
    // open tasks due that day; today also collects overdue ones
    function tasksOn(key) {
        let r = revision;
        let out = [];
        for (let t of tasks) {
            if (t.due === key || (key === todayKey && t.due < todayKey)) out.push(t);
        }
        return out;
    }
    function dayInfo(key) { let r = revision; return days[key] || null; }
    function hasDaily(key) { let r = revision; return !!dailyNotes[key]; }

    // status: is the event happening right now / already over
    function isNow(e) { return !e.allDay && e.startMs <= nowMs && e.endMs > nowMs; }
    function isPast(e) { return e.endMs <= nowMs; }

    // flat list for the desktop widget: next events today/tomorrow + tasks due today
    function upcoming(maxRows) {
        let r = revision, n = nowMs;
        let rows = [];
        let today = eventsOn(todayKey).filter(e => !isPast(e));
        let tt = tasksOn(todayKey);
        let tomorrow = eventsOn(tomorrowKey).filter(e => !(e.allDay && e.startDate < tomorrowKey));
        if (today.length || tt.length) {
            rows.push({ kind: "header", label: "Today", key: todayKey });
            for (let e of today) rows.push({ kind: "event", ev: e });
            let cap = maxRows === -1 ? tt.length : 3;
            for (let t of tt.slice(0, cap)) rows.push({ kind: "task", task: t });
            if (tt.length > cap) rows.push({ kind: "more", label: "+" + (tt.length - cap) + " more tasks", key: todayKey });
        }
        if (tomorrow.length) {
            rows.push({ kind: "header", label: "Tomorrow", key: tomorrowKey });
            for (let e of tomorrow) rows.push({ kind: "event", ev: e });
        }
        if (rows.length === 0) {
            // look further ahead for the next thing at all
            for (let i = 2; i <= 14; i++) {
                let k = shiftKey(todayKey, i);
                let ev = eventsOn(k).filter(e => e.startDate === k);
                if (ev.length) {
                    rows.push({ kind: "header", label: dayLabel(k), key: k });
                    for (let e of ev) rows.push({ kind: "event", ev: e });
                    break;
                }
            }
        }
        return maxRows > 0 ? rows.slice(0, maxRows) : rows;
    }
    function nextEvent() {
        let r = revision, n = nowMs;
        for (let e of events) if (!e.allDay && e.endMs > n) return e;
        return null;
    }

    readonly property string syncStatus: {
        let r = revision, n = nowMs;
        if (!loaded) return "";
        if (!configured) return "Google Calendar not connected";
        let bad = calendars.filter(c => c.enabled && !c.ok && !c.local);
        if (bad.length) return bad[0].name + ": " + bad[0].error;
        let last = 0;
        for (let c of calendars) if (!c.local) last = Math.max(last, c.lastSync || 0);
        if (!last) return "Not synced yet";
        let mins = Math.round((n / 1000 - last) / 60);
        let names = calendars.filter(c => c.enabled && !c.local).length;
        return "Synced " + (mins <= 0 ? "just now" : (mins < 60 ? mins + " min ago" : Math.round(mins / 60) + " h ago")) + " · " + names + (names === 1 ? " calendar" : " calendars");
    }
    readonly property bool syncError: loaded && configured && calendars.some(c => c.enabled && !c.ok && !c.local)

    // ── actions ─────────────────────────────────────────────────────────
    function openUrl(u) {
        if (!u) return;
        Quickshell.execDetached(["xdg-open", u]);
    }
    function openEvent(e) {
        if (!e) return;
        openUrl(e.url || ("https://calendar.google.com/calendar/r/day/" + e.startDate.replace(/-/g, "/")));
        close();
    }
    function openMeet(e) { if (e && e.meet) { openUrl(e.meet); close(); } }
    function openTask(t) { if (t) { openUrl(t.uri); close(); } }
    function openGoogleDay(key) {
        let d = dateOf(key || todayKey);
        openUrl("https://calendar.google.com/calendar/r/day/" + d.getFullYear() + "/" + (d.getMonth() + 1) + "/" + d.getDate());
        close();
    }
    function openDaily(key) {
        Quickshell.execDetached([syncBin, "daily", "--date", key || todayKey]);
        close();
    }
    function runSetup() {
        Quickshell.execDetached(["kitty", "--class", "gcal-setup", "--title", "Connect Google Calendar", "-e", home + "/.local/bin/gcal-setup"]);
        close();
    }
    property bool syncing: syncProc.running
    function refresh(force) {
        if (syncProc.running) return;
        syncProc.command = [syncBin, force ? "sync" : "run", "--quiet", "--no-remind"];
        syncProc.running = true;
    }
    Process {
        id: syncProc
        onExited: dataFile.reload()
    }

    // ── smart capture: live preview (gcal-sync parse-server) + commit (gcal-sync add) ──
    // The parse server answers with the rule-based parse at once and, when the local LLM
    // (llama.cpp, 127.0.0.1:8765) is up, upgrades it a moment later.
    property string captureText: ""
    property var parsed: null              // last parse from the server
    property var overrides: ({})           // hand-edited chip values (survive re-parsing)
    // default date for captures: the day selected in the open Month view
    readonly property string captureDay: panelOpen && view === "month" ? selectedDay : ""
    property var rulesFound: []            // fields the rule parser found explicitly in the text
    readonly property var preview: {
        if (!parsed) return null;
        let it = Object.assign({}, parsed);
        // a day picked in the Month view is the default date unless the text names one
        if (captureDay !== "" && rulesFound.indexOf("date") < 0 && !it.recurrence && captureDay !== it.date) {
            if (it.reminder && it.reminder.date === it.date) it.reminder = Object.assign({}, it.reminder, { date: captureDay });
            if (it.scheduled === it.date) it.scheduled = captureDay;
            it.date = captureDay;
        }
        for (let k in overrides) it[k] = overrides[k];
        return it;
    }
    property string llmState: ""           // pending | offline | off | failed | ""
    property int reqId: 0
    property int llmReqId: 0
    property bool captureUiActive: captureOpen || panelOpen
    property bool parserWanted: false
    onCaptureUiActiveChanged: { if (captureUiActive) { parserLinger.stop(); parserWanted = true; } else parserLinger.restart(); }
    Timer { id: parserLinger; interval: 120000; onTriggered: root.parserWanted = false }

    Process {
        id: parser
        command: [root.syncBin, "parse-server"]
        running: root.parserWanted
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.onParserLine(data) }
        onRunningChanged: {
            if (running && root.captureText.trim() !== "") rulesDebounce.restart();
            if (!running && root.parserWanted) parserRestart.restart();   // crashed: try again shortly
        }
    }
    Timer {
        id: parserRestart; interval: 3000
        onTriggered: { if (root.parserWanted && !parser.running) { root.parserWanted = false; root.parserWanted = true; } }
    }
    function sendParser(obj) {
        if (!parser.running) { parserWanted = true; return false; }
        parser.write(JSON.stringify(obj) + "\n");
        return true;
    }
    function onParserLine(line) {
        let r;
        try { r = JSON.parse(line); } catch (e) { return; }
        if (r.stage === "rules") {
            if (r.id < reqId) return;
            parsed = r.item;
            rulesFound = r.item.found || [];
            if (r.llm !== "pending" || llmState !== "pending") llmState = r.llm || "";
        } else if (r.stage === "llm") {
            if (r.id < llmReqId) return;
            parsed = r.item;
            llmState = "";
        } else if (r.stage === "llm-failed") {
            if (r.id >= llmReqId) llmState = "failed";
        } else if (r.stage === "field") {
            let o = Object.assign({}, overrides);
            let f = pendingField;
            o[f] = r.item[f];
            if (f === "time" || f === "kind") { o.allDay = r.item.allDay; o.duration = r.item.duration; }
            if (f === "kind") o.kind = r.item.kind;
            overrides = o;
            pendingField = "";
        }
    }
    function setCaptureText(t) {
        captureText = t;
        if (t.trim() === "") { parsed = null; llmState = ""; rulesDebounce.stop(); llmDebounce.stop(); return; }
        rulesDebounce.restart();
        llmDebounce.restart();
    }
    Timer {
        id: rulesDebounce; interval: 90
        onTriggered: root.sendParser({ id: ++root.reqId, text: root.captureText, llm: false })
    }
    Timer {
        id: llmDebounce; interval: 650
        onTriggered: {
            root.llmReqId = ++root.reqId;
            if (root.sendParser({ id: root.llmReqId, text: root.captureText, llm: true }) && root.llmState !== "offline")
                root.llmState = "pending";
        }
    }
    property string pendingField: ""
    function editField(field, value) {
        if (!preview) return;
        if (field === "priority" || field === "kind" || field === "title" || field === "location") {
            let o = Object.assign({}, overrides);
            if (field === "kind") {
                o.kind = value;
                o.allDay = value === "event" && !preview.time;
                o.duration = value === "event" ? (preview.duration || (preview.time ? 60 : null)) : null;
            } else {
                o[field] = value === "" ? null : value;
            }
            overrides = o;
            return;
        }
        pendingField = field;
        sendParser({ id: ++reqId, op: "field", item: preview, field: field, value: value });
    }
    function resetCapture() {
        captureText = ""; parsed = null; overrides = ({}); llmState = ""; rulesFound = [];
    }

    property string captureResult: ""
    property bool captureOk: false
    property bool captureBusy: captureProc.running
    signal captured(bool ok, string message)
    function commitCapture() {
        let text = captureText.trim();
        if (!text || captureProc.running) return;
        let it = preview;
        captureProc.command = it ? [syncBin, "add", "--json", JSON.stringify(it)] : [syncBin, "add", "--engine", "rules", text];
        captureProc.running = true;
    }
    // plain capture (kept for scripts): append "- [ ] text" without parsing
    function capture(text) {
        text = (text || "").trim();
        if (!text || captureProc.running) return;
        captureProc.command = [syncBin, "capture", text];
        captureProc.running = true;
    }
    Process {
        id: captureProc
        stdout: StdioCollector { id: capOut }
        stderr: StdioCollector { id: capErr }
        onExited: (code, status) => {
            let ok = code === 0;
            let msg = "";
            if (ok) {
                try {
                    let r = JSON.parse(capOut.text.trim().split("\n").pop());
                    msg = r.message || ("Added to " + (r.file || "note").replace(/\.md$/, ""));
                } catch (e) { msg = "Added"; }
                root.resetCapture();
            } else {
                msg = (capErr.text || "Failed").trim().split("\n").pop();
            }
            root.captureOk = ok;
            root.captureResult = msg;
            root.captured(ok, msg);
            dataFile.reload();
        }
    }

    // chip formatting helpers
    function prettyDate(key) {
        if (!key) return "";
        if (key === todayKey) return "Today";
        if (key === tomorrowKey) return "Tomorrow";
        let d = dateOf(key);
        let days = Math.round((d - dateOf(todayKey)) / 86400000);
        let base = Qt.locale().dayName(d.getDay(), Locale.ShortFormat) + ", " + Qt.locale().monthName(d.getMonth(), Locale.ShortFormat) + " " + d.getDate();
        return days > 0 && days < 7 ? base : base;
    }
    function prettyDuration(m) {
        if (!m) return "";
        if (m < 60) return m + " min";
        let h = Math.floor(m / 60), r = m % 60;
        return r ? h + " h " + r + " min" : h + " h";
    }
    function endOf(it) {
        if (!it || !it.time || !it.duration) return "";
        let p = it.time.split(":");
        let t = (+p[0]) * 60 + (+p[1]) + it.duration;
        return ("0" + Math.floor(t / 60) % 24).slice(-2) + ":" + ("0" + t % 60).slice(-2);
    }

    // ── panel state ─────────────────────────────────────────────────────
    property bool panelOpen: false
    property string focusDay: ""          // "" = week view; otherwise a single day
    property int panelOpenSerial: 0
    property bool captureOpen: false
    property int captureSerial: 0

    // "week" (8-day agenda) or "month"; the last choice is remembered across sessions
    property string view: "week"
    property string monthKey: todayKey.substring(0, 7)   // "yyyy-MM" shown by the Month view
    property string selectedDay: todayKey                // day picked in the Month view
    property bool monthEverShown: false                  // the Month view is loaded lazily, once
    function setView(v) {
        if (v !== "week" && v !== "month") return;
        if (v === "month") monthEverShown = true;
        if (view === v) return;
        view = v;
        viewFile.setText(JSON.stringify({ view: v }) + "\n");
    }
    FileView {
        id: viewFile
        path: Quickshell.env("GCAL_VIEW_STATE") || (root.home + "/.local/state/serpantinum/agenda-view.json")
        blockLoading: true
        printErrors: false
        atomicWrites: true
        onLoaded: {
            try { let v = JSON.parse(text()).view; if (v === "week" || v === "month") root.view = v; } catch (e) {}
        }
    }
    function shiftMonth(n) {
        let p = monthKey.split("-");
        let d = new Date(+p[0], +p[1] - 1 + n, 1);
        monthKey = Qt.formatDate(d, "yyyy-MM");
    }
    function goToday() { monthKey = todayKey.substring(0, 7); selectedDay = todayKey; }
    // Mod+K: open straight into the Month view (toggles when it is already showing)
    function openMonth(key) {
        if (panelOpen && view === "month" && !key) { close(); return; }
        setView("month");
        if (panelOpen && !key) return;
        open(key || "");
    }

    function open(key) {
        captureOpen = false;
        if (view === "month") monthEverShown = true;
        // the Month view starts on the current month (or the requested day's month)
        selectedDay = key || todayKey;
        monthKey = selectedDay.substring(0, 7);
        focusDay = view === "month" ? "" : (key || "");
        panelOpenSerial++;
        panelOpen = true;
        refresh(false);
    }
    function close() { panelOpen = false; captureOpen = false; }
    function toggle() { if (panelOpen) close(); else open(""); }
    function openDay(key) {
        if (panelOpen && focusDay === key) { close(); return; }
        open(key);
    }
    function openCapture() {
        if (captureOpen) { captureOpen = false; return; }
        panelOpen = false;
        resetCapture();
        captureSerial++;
        captureOpen = true;
    }

    // The windows reference Gcal themselves, so they are created at runtime from their
    // file URLs (not as typed children) to keep the singleton free of a compile-time cycle.
    property var _windows: []
    Timer {
        interval: 0; running: true
        onTriggered: {
            for (let f of ["AgendaPanel.qml", "CapturePrompt.qml"]) {
                let c = Qt.createComponent(Qt.resolvedUrl(f));
                if (c.status === Component.Ready) root._windows.push(c.createObject(root));
                else console.warn("Gcal: cannot create", f, c.errorString());
            }
        }
    }

    IpcHandler {
        target: "agenda"
        function toggle(): string { root.toggle(); return root.panelOpen ? "open" : "closed"; }
        function open(): string { root.open(""); return "open"; }
        function close(): string { root.close(); return "closed"; }
        function day(date: string): string { root.open(date); return "open " + date; }
        function month(): string { root.openMonth(""); return root.panelOpen ? "open month" : "closed"; }
        function monthOf(date: string): string { root.openMonth(date); return "open month " + date; }
        function mode(v: string): string { root.setView(v); return root.view; }
        function capture(): string { root.openCapture(); return "capture"; }
        function refresh(): string { root.refresh(true); return "refreshing"; }
        function status(): string {
            return JSON.stringify({ open: root.panelOpen, view: root.view, month: root.monthKey, selected: root.selectedDay, loaded: root.loaded, configured: root.configured,
                                    events: root.events.length, tasks: root.tasks.length, status: root.syncStatus });
        }
    }
}
