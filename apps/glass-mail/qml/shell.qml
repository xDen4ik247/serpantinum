// Glass Mail: a mail app in the liquid-glass / Matugen look of the Serpantinum desktop.
// A quickshell window (app-id glass-mail, set by the launcher through QS_APP_ID) plus a Python
// backend (backend/ in Rust, or glassmail.server) over stdin/stdout. Run: glass-mail
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: shell

    // ------------------------------------------------------------------ theme
    QtObject {
        id: theme
        property color base: "#090f10"
        property color mantle: "#161d1d"
        property color crust: "#0e1415"
        property color text: "#dde4e4"
        property color sub0: "#bec8c9"
        property color sub1: "#899393"
        property color surface0: "#1a2121"
        property color surface1: "#252b2c"
        property color surface2: "#303636"
        property color accent: "#80d4db"      // Matugen primary
        property color accent2: "#b7c7ea"     // Matugen tertiary
        property color deep: "#004f54"        // Matugen primary container
        property color bad: "#ffb4ab"
        readonly property color onAccent: Qt.rgba(base.r * 0.9, base.g * 0.9, base.b * 0.9, 1)
        property string font: "Google Sans"
        property string mono: "JetBrains Mono"
        property string icons: iconFont.status === FontLoader.Ready ? iconFont.name : "Symbols Nerd Font Mono"
        function mix(a, b, t) { a = Qt.color(a); b = Qt.color(b); return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t) }
        function alpha(c, a) { const k = Qt.color(c); return Qt.rgba(k.r, k.g, k.b, a) }
        function hex(c) { const k = Qt.color(c); const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2); return "#" + h(k.r) + h(k.g) + h(k.b) }
        function colors() { return { link: hex(accent), quote: hex(sub1), code: hex(surface1) } }
        onAccentChanged: themeTimer.restart()
    }
    Timer { id: themeTimer; interval: 300; onTriggered: app.send({ cmd: "theme", colors: theme.colors() }) }

    FontLoader {
        id: iconFont
        source: "file:///usr/lib/kitty/fonts/SymbolsNerdFontMono-Regular.ttf"
    }

    FileView {
        id: colorsFile
        path: (Quickshell.env("HOME") || "") + "/.local/state/serpantinum/qs_colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const c = JSON.parse(text());
                const set = (k, v) => { if (v) theme[k] = v; };
                set("base", c.base); set("mantle", c.mantle); set("crust", c.crust); set("text", c.text);
                set("sub0", c.subtext0); set("sub1", c.subtext1); set("surface0", c.surface0);
                set("surface1", c.surface1); set("surface2", c.surface2); set("accent", c.blue);
                set("accent2", c.peach); set("deep", c.sapphire); set("bad", c.red);
            } catch (e) {}
        }
    }

    // ------------------------------------------------------------------ backend
    property string appDir: Quickshell.env("GLASS_MAIL_APP") || (Quickshell.shellDir + "/..")

    Process {
        id: engine
        // the Rust backend when installed; GLASS_MAIL_PYTHON (or no binary) runs the Python one
        command: ["sh", "-c", "[ -z \"$GLASS_MAIL_PYTHON\" ] && [ -x \"$0/bin/glass-mail-backend\" ] && exec \"$0/bin/glass-mail-backend\"; exec \"${GLASS_MAIL_PYTHON:-python3}\" -m glassmail.server", shell.appDir]
        workingDirectory: shell.appDir
        environment: ({ "PYTHONPATH": shell.appDir, "PYTHONUNBUFFERED": "1" })
        stdinEnabled: true
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => app.receive(data)
        }
        stderr: SplitParser {
            onRead: data => console.warn("backend:", data)
        }
        onExited: (code, status) => { if (!app.closing) app.fatal = "The mail backend stopped (exit " + code + ")." }
        onStarted: app.send({ cmd: "hello", colors: theme.colors() })
    }

    // ------------------------------------------------------------------ app state
    QtObject {
        id: app
        readonly property var th: theme
        property var rootItem: null
        property bool closing: false
        property string fatal: ""
        property bool ready: false
        property var settings: ({})

        // accounts and folders
        property var accounts: []                 // public account confs (+ status)
        property var folders: ({})                // acc -> [{path, name, role, depth, unread, total}]
        property var unread: ({ unread: 0, accounts: {} })
        readonly property bool multi: accounts.length > 1

        // the list on screen
        property var view: null                   // {acc, folder} | {acc: "*", role} | {kind: "starred"}
        property var items: []
        property bool complete: true
        property bool loadingOlder: false
        property int listRid: 0
        property string filter: "all"             // all | unread | starred | att
        property var syncing: ({})                // acc -> true while the first sync of a view runs

        // search
        property string searchText: ""
        property int searchRid: 0
        property var searchLocal: []
        property var searchServer: []
        property int searchPending: 0
        readonly property bool searching: searchText.trim() !== ""

        // selection and the open message
        property var cur: null                    // row of the open message
        property var msg: null                    // its view from the backend
        property int openRid: 0
        property bool msgLoading: false
        property var sel: ({})                    // key -> row (multi-select)
        readonly property int selCount: Object.keys(sel).length
        property bool showImages: false

        // compose
        property var compose: null
        property bool composeMin: false
        property var pendingSend: null
        property int sendRid: 0
        property var contacts: []
        property int contactsRid: 0

        // pages over the list + reader: "" | "settings"
        property string page: ""
        property var editAccount: null            // null | {} (new) | account conf
        property var accountResult: null
        property bool accountBusy: false

        // undo for the last move
        property var lastMove: null               // {acc, src, dest, msgids, op}
        property bool undoWanted: false

        // AI (the local model, npu-llm) and login codes
        readonly property bool aiOn: settings.aiOn !== false
        property string aiState: "idle"           // idle | waking | ready | off
        property int aiRid: 1000
        property var aiJobs: ({})                 // rid -> {kind}
        property var analysis: null               // {key, rid, loading, result, error}
        property var translation: null            // {key, rid, text, loading, on, target, error}
        property var assist: null                 // compose AI: {rid, mode, loading, head, tail, before, beforeSubject, error}
        property var answer: null                 // ask / brief: {rid, kind, q, text, loading, sources, error}

        signal toast(string icon, string text, string action)
        signal focusSearch()
        signal scrollToCurrent()

        function send(obj) { engine.write(JSON.stringify(obj) + "\n"); }

        function receive(line) {
            let m;
            try { m = JSON.parse(line); } catch (e) { console.warn("bad line", line.slice(0, 200)); return; }
            const t = m.type;
            if (t === "hello") {
                settings = m.settings;
                ready = true;
                if (m.drafts && m.drafts.length) {
                    const d = m.drafts[m.drafts.length - 1];
                    compose = Object.assign({ to: "", cc: "", bcc: "", subject: "", body: "", attachments: [], mode: "new" }, d);
                    composeMin = true;
                }
            }
            else if (t === "accounts") onAccounts(m.items);
            else if (t === "folders") { const f = Object.assign({}, folders); f[m.acc] = m.items; folders = f; if (!view) pickDefaultView(); }
            else if (t === "list") onList(m);
            else if (t === "changed") onChanged(m);
            else if (t === "msg") onMsg(m);
            else if (t === "acted") onActed(m);
            else if (t === "undone") { toast("undo", m.n ? "Moved back" : "Couldn’t undo that", ""); refreshList(); }
            else if (t === "search") onSearch(m);
            else if (t === "contacts") { if (m.rid === contactsRid) contacts = m.items; }
            else if (t === "sent") onSent(m);
            else if (t === "picked") { if (compose && m.files.length) setCompose({ attachments: (compose.attachments || []).concat(m.files) }); }
            else if (t === "saved") {}
            else if (t === "unread") unread = m;
            else if (t === "acc-status") setAccStatus(m.acc, { state: m.state, text: m.text });
            else if (t === "account-saved") onAccountSaved(m);
            else if (t === "settings") settings = m.settings;
            else if (t === "toast") toast(m.icon, m.text, "");
            else if (t === "op-failed") onFailed(m);
            else if (t === "error") console.warn("backend error:", m.error, m.trace || "");
            else if (t === "ai-state") aiState = m.state;
            else if (t === "ai-analysis") { if (analysis && analysis.rid === m.rid) analysis = Object.assign({}, analysis, { loading: false, result: m.result }); }
            else if (t === "ai-chunk") onAiChunk(m);
            else if (t === "ai-done") onAiDone(m);
            else if (t === "ai-error") onAiError(m);
            else if (t === "ai-sources") { if (answer && answer.rid === m.rid) answer = Object.assign({}, answer, { sources: m.items }); }
            else if (t === "code") toast("key", m.code + " copied · " + m.from, "");
        }

        // ---- accounts
        function onAccounts(list) {
            accounts = list;
            const f = {};
            for (const a of list) f[a.id] = folders[a.id] || [];
            folders = f;
            if (!list.length) { view = null; items = []; cur = null; msg = null; if (page === "") { page = "settings"; editAccount = ({}); } return; }
            if (view && view.acc && view.acc !== "*" && !list.some(a => a.id === view.acc)) view = null;
            if (!view) pickDefaultView();
        }
        function account(id) { for (const a of accounts) if (a.id === id) return a; return null; }
        function accColor(id) { const a = account(id); return a ? a.color : th.accent; }
        function setAccStatus(id, st) {
            accounts = accounts.map(a => a.id === id ? Object.assign({}, a, { status: st }) : a);
            if (st.state === "auth") toast("warn", (account(id) ? account(id).email + ": " : "") + "sign-in failed — check the password in Settings", "");
        }
        function myAddrs() { return accounts.map(a => a.email.toLowerCase()); }
        function folderOf(acc, path) { for (const f of (folders[acc] || [])) if (f.path === path) return f; return null; }
        function roleFolder(acc, role) { for (const f of (folders[acc] || [])) if (f.role === role) return f; return null; }
        function pickDefaultView() {
            if (!accounts.length) return;
            if (multi) { setView({ acc: "*", role: "inbox" }); return; }
            const f = roleFolder(accounts[0].id, "inbox");
            if (f) setView({ acc: accounts[0].id, folder: f.path });
        }

        // ---- views and the list
        function viewKey(v) { return v ? JSON.stringify(v) : ""; }
        function isView(v) { return viewKey(v) === viewKey(view); }
        function setView(v) {
            if (searching) clearSearch();
            page = "";
            if (isView(v)) { refreshList(); return; }
            view = v;
            items = [];
            complete = true;
            filter = "all";
            sel = ({});
            refreshList(true);
        }
        function refreshList(watch) {
            if (!view) return;
            listRid += 1;
            send({ cmd: "list", view: view, rid: listRid, limit: Math.max(300, items.length + 20), watch: !!watch });
        }
        function onList(m) {
            if (m.rid !== listRid) return;
            items = m.items;
            complete = m.complete;
            loadingOlder = false;
            // the open message may have been archived elsewhere: keep it open, but refresh its row
            if (cur) { const r = items.find(x => key(x) === key(cur)); if (r) cur = r; }
        }
        function onChanged(m) {
            if (m.older) loadingOlder = false;
            if (!view) return;
            if (view.kind === "starred" || view.acc === "*" || (view.acc === m.acc && view.folder === m.folder)) changeTimer.restart();
        }
        function loadOlder() {
            if (complete || loadingOlder || !view || view.acc === "*" || view.kind) return;
            loadingOlder = true;
            send({ cmd: "older", view: view });
        }
        function refresh() { send({ cmd: "refresh", retry: true }); toast("refresh", "Checking for new mail…", ""); }
        function viewTitle() {
            if (searching) return "Search";
            if (!view) return "";
            if (view.kind === "starred") return "Starred";
            if (view.acc === "*") return "All inboxes";
            const f = folderOf(view.acc, view.folder);
            return f ? f.name : view.folder;
        }
        function viewIcon() {
            if (!view) return "inbox";
            if (view.kind === "starred") return "star";
            if (view.acc === "*") return "inboxes";
            const f = folderOf(view.acc, view.folder);
            return roleIcon(f ? f.role : "");
        }
        function roleIcon(role) {
            return ({ inbox: "inbox", sent: "sent", drafts: "drafts", archive: "archive-outline", all: "mails", junk: "spam", trash: "trash", flagged: "star-outline" })[role] || "folder";
        }
        function visibleItems() {
            const src = searching ? searchResults() : items;
            if (filter === "unread") return src.filter(r => !r.seen);
            if (filter === "starred") return src.filter(r => r.flagged);
            if (filter === "att") return src.filter(r => r.att);
            if (filter === "people" || filter === "updates" || filter === "news") return src.filter(r => (r.cat || "people") === filter);
            return src;
        }
        // rows + date headers for the ListView
        function rows() {
            const out = [];
            if (searching && aiOn) out.push({ ask: searchText.trim() });
            let last = "";
            for (const r of visibleItems()) {
                const g = dateGroup(r.date);
                if (g !== last) { out.push({ header: g }); last = g; }
                out.push(r);
            }
            return out;
        }

        // ---- search
        function search(q) {
            searchText = q;
            searchRid += 1;
            searchLocal = []; searchServer = [];
            if (q.trim() === "") { searchPending = 0; return; }
            searchTimer.restart();
        }
        function runSearch() {
            searchPending = accounts.length;
            send({ cmd: "search", q: searchText, rid: searchRid });
        }
        function onSearch(m) {
            if (m.rid !== searchRid) return;
            if (m.local) searchLocal = m.items;
            else { searchServer = searchServer.concat(m.items); searchPending = Math.max(0, searchPending - 1); }
        }
        function searchResults() {
            const seen = {}, out = [];
            for (const r of searchServer.concat(searchLocal)) {
                const k = r.msgid ? r.acc + "|" + r.msgid : key(r);
                if (seen[k]) continue;
                seen[k] = true;
                out.push(r);
            }
            out.sort((a, b) => b.date - a.date);
            return out;
        }
        function clearSearch() { searchText = ""; searchRid += 1; searchLocal = []; searchServer = []; searchPending = 0; }

        // ---- opening messages
        function key(r) { return r ? r.acc + "|" + r.folder + "|" + r.uid : ""; }
        function open(r) {
            if (!r) return;
            sel = ({});
            page = "";
            if (cur && key(cur) === key(r) && msg) return;
            cur = r;
            msg = null;
            msgLoading = true;
            openRid += 1;
            showImages = false;
            send({ cmd: "open", acc: r.acc, folder: r.folder, uid: r.uid, rid: openRid });
            if (!r.seen && settings.markRead !== false) patch([r], { seen: true });
        }
        function onMsg(m) {
            if (m.rid !== openRid) return;
            msgLoading = false;
            if (m.error) { msg = { error: m.error }; return; }
            msg = m.view;
            showImages = !!m.view.showImages;
            if (!analysis || analysis.key !== key(cur)) analysis = null;
            if (!translation || translation.key !== key(cur)) translation = null;
            if (aiOn && settings.aiAuto !== false && !msg.code) autoAnalyze.restart();
            if (replyWhenReady) { const w = replyWhenReady; replyWhenReady = ""; if (w === "forward") forward(); else reply(w === "replyall"); }
        }
        function openKey(acc, folder, uid) {
            const r = items.find(x => x.acc === acc && x.folder === folder && x.uid === uid);
            open(r || { acc: acc, folder: folder, uid: uid, seen: true, subject: "", from_name: "", from_addr: "", date: 0 });
        }
        function step(d) {
            const list = visibleItems();
            if (!list.length) return;
            let i = cur ? list.findIndex(x => key(x) === key(cur)) : -1;
            i = i < 0 ? 0 : Math.max(0, Math.min(list.length - 1, i + d));
            open(list[i]);
            scrollToCurrent();
            if (i > list.length - 15) loadOlder();
        }
        function closeMsg() { cur = null; msg = null; }

        // ---- AI
        function aiNew(kind) { aiRid += 1; const j = Object.assign({}, aiJobs); j[aiRid] = kind; aiJobs = j; return aiRid; }
        function analyze(force, auto) {
            if (!cur || !msg || msg.error || !aiOn) return;
            if (!force && analysis && analysis.key === key(cur) && (analysis.loading || analysis.result)) return;
            const rid = aiNew("analyze");
            analysis = { key: key(cur), rid: rid, loading: true, result: null, error: "" };
            send({ cmd: "ai-analyze", acc: cur.acc, folder: cur.folder, uid: cur.uid, rid: rid, force: !!force, auto: !!auto });
        }
        function translate() {
            if (!cur || !msg || msg.error) return;
            if (translation && translation.key === key(cur)) { translation = Object.assign({}, translation, { on: !translation.on }); return; }
            const pref = settings.translateTo || "ru";
            const text = (msg.subject || "") + " " + (msg.plain || "").slice(0, 1500);
            const cyr = (text.match(/[а-яё]/gi) || []).length, lat = (text.match(/[a-z]/gi) || []).length;
            const isRu = cyr > lat * 0.6;
            const target = pref === "ru" && isRu ? "en" : (pref !== "ru" && !isRu && pref === "en" ? "ru" : pref);
            const rid = aiNew("translate");
            translation = { key: key(cur), rid: rid, text: "", loading: true, on: true, target: target, error: "" };
            send({ cmd: "ai-translate", acc: cur.acc, folder: cur.folder, uid: cur.uid, target: target, rid: rid });
        }
        function langName(k) { return ({ ru: "Russian", en: "English", ja: "Japanese" })[k] || k; }
        function ask(q) {
            q = (q || "").trim();
            if (!q || !aiOn) return;
            const rid = aiNew("answer");
            answer = { rid: rid, kind: "ask", q: q, text: "", loading: true, sources: [], error: "" };
            page = "ai";
            send({ cmd: "ai-ask", q: q, rid: rid });
        }
        function brief() {
            if (!aiOn) { openSettings(); settingsTab = "ai"; return; }
            const rid = aiNew("answer");
            answer = { rid: rid, kind: "brief", q: "Catch me up", text: "", loading: true, sources: [], error: "" };
            page = "ai";
            send({ cmd: "ai-brief", rid: rid });
        }
        function stopAi(rid) { if (rid) send({ cmd: "ai-cancel", rid: rid }); }
        // compose: the part you wrote vs. signature + quoted history underneath
        function splitBody(body) {
            let i = body.length;
            for (const re of [/\n-- \n/, /\n\nOn .{5,160} wrote:\n/, /\n\n---------- Forwarded message ---------/]) {
                const mm = re.exec(body);
                if (mm && mm.index < i) i = mm.index;
            }
            return [body.slice(0, i), body.slice(i)];
        }
        function aiCompose(mode, prompt) {
            if (!compose || !aiOn) return;
            if (assist && assist.loading) return;
            const parts = splitBody(compose.body || "");
            const rid = aiNew("assist");
            const write = mode === "prompt" && !parts[0].trim();
            assist = { rid: rid, mode: write ? "write" : mode, loading: true, head: "", tail: parts[1], before: compose.body,
                       beforeSubject: compose.subject, error: "" };
            if (write) send({ cmd: "ai-write", rid: rid, acc: compose.acc, prompt: prompt,
                              ctx: { to: compose.to, subject: compose.subject, quote: compose.mode && compose.mode.indexOf("reply") === 0 && msg ? (msg.plain || "") : "" } });
            else send({ cmd: "ai-rewrite", rid: rid, text: parts[0], mode: mode === "prompt" ? prompt : mode });
        }
        function aiReplyWith(intent) {
            if (!msg || !cur) return;
            reply(false);
            if (!compose) return;
            const parts = splitBody(compose.body || "");
            const rid = aiNew("assist");
            assist = { rid: rid, mode: "reply", loading: true, head: "", tail: parts[1], before: compose.body, beforeSubject: compose.subject, error: "" };
            send({ cmd: "ai-reply", acc: cur.acc, folder: cur.folder, uid: cur.uid, intent: intent, rid: rid });
        }
        function undoAssist() {
            if (!assist || !compose) return;
            setCompose({ body: assist.before, subject: assist.beforeSubject });
            assist = null;
        }
        function assistBody(head) {
            let h = head, subj = "";
            const mm = /^\s*(subject|тема)\s*:\s*(.+?)\s*\n+/i.exec(h);
            if (mm) { subj = mm[2]; h = h.slice(mm[0].length); }
            return [h, subj];
        }
        function onAiChunk(m) {
            const kind = aiJobs[m.rid];
            if (kind === "assist" && assist && assist.rid === m.rid && compose) {
                assist = Object.assign({}, assist, { head: assist.head + m.text });
                const hb = assistBody(assist.head);
                const f = { body: hb[0] + (assist.tail ? (hb[0].endsWith("\n") ? "" : "\n") + assist.tail : "") };
                if (hb[1] && !assist.beforeSubject) f.subject = hb[1];
                setCompose(f);
            } else if (kind === "translate" && translation && translation.rid === m.rid) {
                translation = Object.assign({}, translation, { text: translation.text + m.text });
            } else if (kind === "answer" && answer && answer.rid === m.rid) {
                answer = Object.assign({}, answer, { text: answer.text + m.text });
            }
        }
        function onAiDone(m) {
            const kind = aiJobs[m.rid];
            if (kind === "assist" && assist && assist.rid === m.rid) {
                if (compose && m.text !== undefined && !m.cancelled) {
                    const f = { body: m.text.replace(/\s+$/, "") + (assist.tail ? "\n" + assist.tail : "") };
                    if (m.subject && !assist.beforeSubject) f.subject = m.subject;
                    setCompose(f);
                }
                assist = Object.assign({}, assist, { loading: false });
            } else if (kind === "translate" && translation && translation.rid === m.rid) {
                translation = Object.assign({}, translation, { loading: false, text: m.text !== undefined ? m.text : translation.text });
            } else if (kind === "answer" && answer && answer.rid === m.rid) {
                answer = Object.assign({}, answer, { loading: false, text: m.text !== undefined ? m.text : answer.text });
            }
        }
        function onAiError(m) {
            const kind = aiJobs[m.rid];
            if (kind === "analyze" && analysis && analysis.rid === m.rid) analysis = Object.assign({}, analysis, { loading: false, error: m.text });
            else if (kind === "assist" && assist && assist.rid === m.rid) { assist = Object.assign({}, assist, { loading: false, error: m.text }); toast("warn", m.text, ""); }
            else if (kind === "translate" && translation && translation.rid === m.rid) translation = Object.assign({}, translation, { loading: false, error: m.text });
            else if (kind === "answer" && answer && answer.rid === m.rid) answer = Object.assign({}, answer, { loading: false, error: m.text });
            else toast("warn", m.text, "");
        }
        // the model's light Markdown -> Qt rich text; [n] become links to the sources
        function mdToHtml(text, color) {
            const esc = x => x.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            const out = [];
            for (let ln of (text || "").split("\n")) {
                let h = esc(ln);
                h = h.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`([^`]+)`/g, "<code>$1</code>");
                h = h.replace(/\[(\d{1,2})\]/g, '<a href="src:$1" style="color:' + color + '; text-decoration:none">[$1]</a>');
                if (/^\s*#{1,4}\s+/.test(ln)) h = "<b>" + h.replace(/^\s*#{1,4}\s+/, "") + "</b>";
                else if (/^\s*[-*•]\s+/.test(ln)) h = "&nbsp;&nbsp;•&nbsp;&nbsp;" + h.replace(/^\s*[-*•]\s+/, "");
                out.push(h);
            }
            return out.join("<br>");
        }
        function copyText(t, what) { send({ cmd: "copy", text: t, clear: what === "code" ? 180 : 0 }); toast(what === "code" ? "key" : "copy", (what === "code" ? t + " copied · clears in 3 min" : "Copied"), ""); }
        function addEvent(e) { send({ cmd: "calendar", title: e.title, when: e.when }); toast("calendar-plus", "Adding “" + e.title + "”…", ""); }
        function aiWaitText() { return aiState === "waking" ? "Waking the local AI (about 45 s the first time)…" : "Thinking…"; }

        // ---- actions (optimistic: the list changes now, the server catches up)
        function targets(r) {
            if (r) return [r];
            if (selCount) return Object.values(sel);
            return cur ? [cur] : [];
        }
        function patch(rs, fields) {
            const keys = {};
            for (const r of rs) keys[key(r)] = true;
            const upd = x => keys[key(x)] ? Object.assign({}, x, fields) : x;
            items = items.map(upd);
            searchLocal = searchLocal.map(upd);
            searchServer = searchServer.map(upd);
            if (cur && keys[key(cur)]) cur = Object.assign({}, cur, fields);
        }
        function drop(rs) {
            const keys = {};
            for (const r of rs) keys[key(r)] = true;
            // the next message opens in place of the one that goes away
            let next = null;
            if (cur && keys[key(cur)]) {
                const list = visibleItems();
                const i = list.findIndex(x => key(x) === key(cur));
                for (let j = i + 1; j < list.length && !next; j++) if (!keys[key(list[j])]) next = list[j];
                for (let j = i - 1; j >= 0 && !next; j--) if (!keys[key(list[j])]) next = list[j];
            }
            items = items.filter(x => !keys[key(x)]);
            searchLocal = searchLocal.filter(x => !keys[key(x)]);
            searchServer = searchServer.filter(x => !keys[key(x)]);
            sel = ({});
            if (cur && keys[key(cur)]) { if (next && settings.openNext !== false) open(next); else closeMsg(); }
        }
        function act(op, r, dest) {
            const rs = targets(r);
            if (!rs.length) return;
            const its = rs.map(x => ({ acc: x.acc, folder: x.folder, uid: x.uid, msgid: x.msgid || "" }));
            if (op === "seen" || op === "unseen") patch(rs, { seen: op === "seen" });
            else if (op === "flag" || op === "unflag") patch(rs, { flagged: op === "flag" });
            else {
                if (op === "archive") {
                    const f = folderOf(rs[0].acc, rs[0].folder);
                    if (f && (f.role === "archive" || f.role === "all")) { toast("archive", "Already archived", ""); return; }
                }
                drop(rs);
                lastMove = null; undoWanted = false;
                const n = rs.length > 1 ? rs.length + " messages" : "Message";
                const forever = op === "delete" || (op === "trash" && (folderOf(rs[0].acc, rs[0].folder) || {}).role === "trash");
                const words = { archive: " archived", trash: " moved to Trash", spam: " marked as spam", notspam: " moved to Inbox", move: " moved" };
                toast(forever ? "delete" : op === "spam" ? "spam" : op === "trash" ? "trash" : "archive",
                      forever ? (n + " deleted forever") : n + (words[op] || " moved") + (op === "move" && dest ? " to " + ((folderOf(rs[0].acc, dest) || {}).name || dest) : ""),
                      forever ? "" : "Undo");
            }
            send({ cmd: "act", op: op, items: its, dest: dest || null, rid: 1 });
        }
        function toggleStar(r) { const rs = targets(r); if (rs.length) act(rs.every(x => x.flagged) ? "unflag" : "flag", r); }
        function toggleRead(r) { const rs = targets(r); if (rs.length) act(rs.every(x => x.seen) ? "unseen" : "seen", r); }
        function onActed(m) {
            if (["archive", "trash", "spam", "notspam", "move"].indexOf(m.op) >= 0 && m.dest) {
                lastMove = { acc: m.acc, src: m.folder, dest: m.dest, msgids: (m.msgids || []).filter(x => x) };
                if (undoWanted) undo();
            } else if (m.text) toast("info", m.text, "");
        }
        function undo() {
            if (!lastMove) { undoWanted = true; return; }
            if (!lastMove.msgids.length) { toast("warn", "Can’t undo this one", ""); lastMove = null; return; }
            send({ cmd: "undo", acc: lastMove.acc, src: lastMove.src, dest: lastMove.dest, msgids: lastMove.msgids, rid: 1 });
            lastMove = null; undoWanted = false;
        }
        function onFailed(m) {
            if (m.op === "open") { msgLoading = false; msg = { error: m.text }; }
            else if (m.op === "search") searchPending = Math.max(0, searchPending - 1);
            else if (m.op === "send") onSent({ ok: false, text: m.text, rid: m.rid });
            else if (m.op === "act" || m.op === "undo") { toast("warn", m.text, ""); refreshList(); }
            else if (m.op === "older") loadingOlder = false;
        }
        function toggleSel(r) {
            const s = Object.assign({}, sel), k = key(r);
            if (s[k]) delete s[k]; else s[k] = r;
            sel = s;
        }
        function selectRange(r) {
            const list = visibleItems();
            const a = cur ? list.findIndex(x => key(x) === key(cur)) : 0;
            const b = list.findIndex(x => key(x) === key(r));
            const s = Object.assign({}, sel);
            if (cur && !Object.keys(s).length) s[key(cur)] = cur;
            for (let i = Math.min(a, b); i <= Math.max(a, b); i++) if (i >= 0) s[key(list[i])] = list[i];
            sel = s;
        }
        function selectAll() { const s = {}; for (const r of visibleItems()) s[key(r)] = r; sel = s; }
        function rowMenu(r, item, mx, my) {
            const rs = sel[key(r)] ? Object.values(sel) : [r];
            const one = rs.length === 1;
            const f = folderOf(r.acc, r.folder) || {};
            const items_ = [];
            if (one) items_.push({ icon: "mail-open", text: "Open", act: () => open(r) },
                                 { icon: "reply", text: "Reply", act: () => { open(r); replyWhenReady = "reply"; } },
                                 { icon: "forward", text: "Forward", act: () => { open(r); replyWhenReady = "forward"; } },
                                 { sep: true });
            items_.push({ icon: rs.every(x => x.seen) ? "mail-unread" : "mail-open", text: rs.every(x => x.seen) ? "Mark as unread" : "Mark as read", act: () => act(rs.every(x => x.seen) ? "unseen" : "seen", one ? r : null) },
                        { icon: rs.every(x => x.flagged) ? "star" : "star-outline", text: rs.every(x => x.flagged) ? "Remove star" : "Star", act: () => act(rs.every(x => x.flagged) ? "unflag" : "flag", one ? r : null) },
                        { sep: true });
            if (f.role !== "archive" && f.role !== "all") items_.push({ icon: "archive", text: "Archive", act: () => act("archive", one ? r : null) });
            items_.push({ icon: "folder", text: "Move to…", sub: "move", acc: r.acc, rows: rs });
            if (f.role === "junk") items_.push({ icon: "inbox", text: "Not spam", act: () => act("notspam", one ? r : null) });
            else items_.push({ icon: "spam", text: "Report spam", act: () => act("spam", one ? r : null) });
            items_.push({ icon: "trash", text: f.role === "trash" ? "Delete forever" : "Delete", act: () => act("trash", one ? r : null) });
            if (!one) { sel = (() => { const s = {}; for (const x of rs) s[key(x)] = x; return s; })(); }
            menu.open(items_, item, mx, my);
        }
        property string replyWhenReady: ""
        function moveMenu(rs, item, mx, my) {
            if (!rs.length) return;
            menu.open([], item, mx, my);
            menu.run({ sub: "move", acc: rs[0].acc, rows: rs });
        }

        // ---- compose
        function newDraftId() { return "d" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36); }
        function defaultAcc() {
            if (cur && account(cur.acc)) return cur.acc;
            if (view && view.acc && view.acc !== "*" && account(view.acc)) return view.acc;
            return accounts.length ? accounts[0].id : "";
        }
        function signature(acc) { const a = account(acc); return a && a.signature ? "\n\n-- \n" + a.signature : ""; }
        function startCompose(c) {
            if (!accounts.length) { openSettings(); return; }
            const acc = c.acc || defaultAcc();
            if (aiOn && aiState !== "ready") send({ cmd: "ai-warm" });
            compose = Object.assign({ id: newDraftId(), acc: acc, to: "", cc: "", bcc: "", subject: "", body: signature(acc),
                                      attachments: [], showCc: false, mode: "new" }, c);
            composeMin = false;
        }
        function newMessage(to) { startCompose({ to: to || "" }); }
        function mailto(url) {
            const m = /^mailto:([^?]*)(?:\?(.*))?$/i.exec(url || "");
            if (!m) { newMessage(); return; }
            const q = {};
            for (const part of (m[2] || "").split("&")) { const i = part.indexOf("="); if (i > 0) q[part.slice(0, i).toLowerCase()] = decodeURIComponent(part.slice(i + 1).replace(/\+/g, " ")); }
            startCompose({ to: decodeURIComponent(m[1] || q.to || ""), cc: q.cc || "", bcc: q.bcc || "", subject: q.subject || "", body: (q.body || "") + signature(defaultAcc()), showCc: !!(q.cc || q.bcc) });
        }
        function fmtAddr(p) { return p[0] ? (/[,;"]/.test(p[0]) ? '"' + p[0].replace(/"/g, "") + '"' : p[0]) + " <" + p[1] + ">" : p[1]; }
        function reply(all) {
            if (!msg || !cur || msg.error) return;
            const me = myAddrs();
            const from = msg.replyTo && msg.replyTo.length ? msg.replyTo : msg.from;
            let to = from.filter(p => me.indexOf((p[1] || "").toLowerCase()) < 0);
            // replying to your own sent message: answer its recipients
            if (!to.length) to = msg.to.filter(p => me.indexOf((p[1] || "").toLowerCase()) < 0);
            let cc = [];
            if (all) {
                const seen = {};
                for (const p of to) seen[(p[1] || "").toLowerCase()] = true;
                for (const p of msg.to.concat(msg.cc)) {
                    const a = (p[1] || "").toLowerCase();
                    if (!a || seen[a] || me.indexOf(a) >= 0) continue;
                    seen[a] = true; cc.push(p);
                }
            }
            const acc = pickReplyAccount();
            startCompose({ acc: acc, mode: all ? "replyall" : "reply", to: to.map(fmtAddr).join(", "), cc: cc.map(fmtAddr).join(", "), showCc: cc.length > 0,
                           subject: prefixed("Re", msg.subject), body: "\n" + signature(acc) + quoteText(),
                           inReplyTo: msg.msgid, refs: msg.refs, replyTo: { folder: cur.folder, uid: cur.uid } });
        }
        function forward() {
            if (!msg || !cur || msg.error) return;
            const acc = pickReplyAccount();
            startCompose({ acc: acc, mode: "forward", subject: prefixed("Fwd", msg.subject), body: "\n" + signature(acc) + forwardText(),
                           forward: { folder: cur.folder, uid: cur.uid, keep: msg.attachments.map(a => a.i) },
                           forwardAtts: msg.attachments.slice() });
        }
        function pickReplyAccount() {
            // answer from the address the mail was sent to, when it is one of yours
            const all = msg.to.concat(msg.cc).map(p => (p[1] || "").toLowerCase());
            for (const a of accounts) if (all.indexOf(a.email.toLowerCase()) >= 0) return a.id;
            return cur.acc;
        }
        function prefixed(p, s) {
            s = s || "";
            if (p === "Re" && /^\s*(re|aw|sv|ответ)\s*:/i.test(s)) return s;
            if (p === "Fwd" && /^\s*(fwd?|wg|пересл)\s*:/i.test(s)) return s;
            return p + ": " + s;
        }
        function longDate(t) { return t ? Qt.formatDateTime(new Date(t * 1000), "ddd, d MMM yyyy 'at' HH:mm") : ""; }
        function quoteText() {
            const who = msg.from.length ? fmtAddr(msg.from[0]) : "someone";
            const body = (msg.plain || "").replace(/\s+$/, "");
            return "\n\nOn " + longDate(msg.date) + ", " + who + " wrote:\n" + body.split("\n").map(l => l ? "> " + l : ">").join("\n") + "\n";
        }
        function forwardText() {
            const lines = ["", "", "---------- Forwarded message ---------"];
            if (msg.from.length) lines.push("From: " + fmtAddr(msg.from[0]));
            if (msg.date) lines.push("Date: " + longDate(msg.date));
            lines.push("Subject: " + (msg.subject || ""));
            if (msg.to.length) lines.push("To: " + msg.to.map(fmtAddr).join(", "));
            if (msg.cc.length) lines.push("Cc: " + msg.cc.map(fmtAddr).join(", "));
            lines.push("", (msg.plain || "").replace(/\s+$/, ""));
            return lines.join("\n") + "\n";
        }
        function setCompose(fields) {
            if (!compose) return;
            compose = Object.assign({}, compose, fields);
            draftTimer.restart();
        }
        function saveDraft() { if (compose) send({ cmd: "draft-save", id: compose.id, data: compose }); }
        function discard() {
            if (!compose) return;
            send({ cmd: "draft-drop", id: compose.id });
            compose = null;
            toast("delete", "Draft discarded", "");
        }
        function sendNow() {
            const c = compose;
            if (!c) return;
            if (!(c.to + c.cc + c.bcc).trim()) { toast("warn", "Add at least one recipient", ""); return; }
            if (!c.subject.trim() && !c.body.trim()) { toast("warn", "Write something first", ""); return; }
            saveDraft();
            compose = null;
            pendingSend = c;
            sendTimer.restart();
            toast("send-clock", "Sending…", "Undo");
        }
        function undoSend() {
            if (!pendingSend) return;
            sendTimer.stop();
            compose = pendingSend;
            composeMin = false;
            pendingSend = null;
            toast("undo", "Sending cancelled", "");
        }
        function reallySend() {
            const c = pendingSend;
            if (!c) return;
            pendingSend = null;
            sendRid += 1;
            sentDrafts[sendRid] = c;
            send({ cmd: "send", acc: c.acc, rid: sendRid, draftId: c.id, attachments: (c.attachments || []).map(a => a.path), forward: c.forward || null,
                   draft: { to: c.to, cc: c.cc, bcc: c.bcc, subject: c.subject, body: c.body, inReplyTo: c.inReplyTo || "", refs: c.refs || "", replyTo: c.replyTo || null } });
        }
        property var sentDrafts: ({})
        function onSent(m) {
            const c = sentDrafts[m.rid];
            delete sentDrafts[m.rid];
            if (m.ok) {
                toast("send", "Message sent", "");
                if (c && c.replyTo && cur && cur.folder === c.replyTo.folder && cur.uid === c.replyTo.uid) patch([cur], { answered: true });
            } else {
                toast("warn", "Not sent: " + (m.text || "error"), "");
                if (c && !compose) { compose = c; composeMin = false; saveDraft(); }
            }
        }
        function attach() { send({ cmd: "pick", rid: 1 }); }
        function askContacts(q) { contactsRid += 1; if (q.trim().length < 1) { contacts = []; return; } send({ cmd: "contacts", q: q, rid: contactsRid }); }

        // ---- message helpers
        function attOpen(a) { send({ cmd: "att-open", acc: cur.acc, folder: cur.folder, uid: cur.uid, i: a.i }); toast("open", "Opening " + a.name + "…", ""); }
        function attSave(a) { send({ cmd: "att-save", acc: cur.acc, folder: cur.folder, uid: cur.uid, i: a.i }); }
        function openInBrowser() { if (cur) send({ cmd: "browser", acc: cur.acc, folder: cur.folder, uid: cur.uid, images: showImages }); }
        function viewSource() { if (cur) send({ cmd: "source", acc: cur.acc, folder: cur.folder, uid: cur.uid }); }
        function allowImages(always) {
            showImages = true;
            if (always && msg && msg.from.length) { send({ cmd: "images", addr: msg.from[0][1], always: true }); toast("image", "Images from " + msg.from[0][1] + " will always show", ""); }
        }
        function openLink(url) {
            if (/^mailto:/i.test(url)) { mailto(url); return; }
            if (/^https?:/i.test(url)) send({ cmd: "url", url: url });
        }
        function unsubscribe() {
            if (!msg || !msg.unsub) return;
            const links = (msg.unsub.match(/<([^>]+)>/g) || []).map(s => s.slice(1, -1));
            const web = links.find(l => /^https?:/i.test(l));
            const mail = links.find(l => /^mailto:/i.test(l));
            if (web) { send({ cmd: "url", url: web }); toast("unsubscribe", "Opened the unsubscribe page", ""); }
            else if (mail) mailto(mail);
        }
        function msgMenu(item, mx, my) {
            if (!cur) return;
            const f = folderOf(cur.acc, cur.folder) || {};
            const its = [
                { icon: "reply-all", text: "Reply all", act: () => reply(true) },
                { icon: cur.seen ? "mail-unread" : "mail-open", text: cur.seen ? "Mark as unread" : "Mark as read", act: () => toggleRead(cur) },
                { icon: "folder", text: "Move to…", sub: "move", acc: cur.acc, rows: [cur] },
                f.role === "junk" ? { icon: "inbox", text: "Not spam", act: () => act("notspam", cur) } : { icon: "spam", text: "Report spam", act: () => act("spam", cur) },
                { sep: true },
                { icon: "web", text: "Open original in browser", act: () => openInBrowser() },
                { icon: "code", text: "Show original (source)", act: () => viewSource() }
            ];
            if (msg && msg.unsub) its.push({ sep: true }, { icon: "unsubscribe", text: "Unsubscribe", act: () => unsubscribe() });
            menu.open(its, item, mx, my);
        }
        function appMenu(item, mx, my) {
            menu.open([
                { icon: "refresh", text: "Check for new mail", act: () => refresh() },
                { icon: "check-all", text: "Mark all here as read", act: () => { const rs = visibleItems().filter(r => !r.seen); if (rs.length) { sel = ({}); const s = {}; for (const r of rs) s[key(r)] = r; sel = s; act("seen"); sel = ({}); } } },
                { sep: true },
                { icon: "bolt", text: "Catch me up (AI)", act: () => brief() },
                { icon: "accounts", text: "Accounts & settings", act: () => openSettings() },
                { icon: "keyboard", text: "Keyboard shortcuts", act: () => { openSettings(); settingsTab = "keys"; } }
            ], item, mx, my);
        }

        // ---- settings / accounts
        property string settingsTab: "accounts"
        function openSettings() { page = "settings"; settingsTab = "accounts"; }
        function closeSettings() { if (accounts.length) { page = ""; editAccount = null; } }
        function setSetting(k, v) { const s = {}; s[k] = v; settings = Object.assign({}, settings, s); send({ cmd: "settings", set: s }); }
        function saveAccount(d) { accountBusy = true; accountResult = null; send({ cmd: "account-save", account: d, rid: 1 }); }
        function onAccountSaved(m) {
            accountBusy = false;
            accountResult = m;
            if (m.ok) { toast("check", "Signed in · " + m.folders + " folders", ""); editAccount = null; if (accounts.length <= 1) Qt.callLater(() => { page = ""; }); }
        }

        // ---- formatting
        function n(k, one, many) { return k + " " + (k === 1 ? one : (many || one + "s")); }
        function dayStart(d) { const x = new Date(d); x.setHours(0, 0, 0, 0); return x.getTime(); }
        function dateGroup(t) {
            if (!t) return "Earlier";
            const now = new Date(), d = new Date(t * 1000);
            const today = dayStart(now), day = dayStart(d);
            if (day >= today) return "Today";
            if (day >= today - 86400000) return "Yesterday";
            if (day >= today - 6 * 86400000) return "This week";
            if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()) return "This month";
            return Qt.formatDate(d, d.getFullYear() === now.getFullYear() ? "MMMM" : "MMMM yyyy");
        }
        function shortDate(t) {
            if (!t) return "";
            const now = new Date(), d = new Date(t * 1000);
            if (dayStart(d) === dayStart(now)) return Qt.formatTime(d, "HH:mm");
            if (dayStart(now) - dayStart(d) < 6 * 86400000) return Qt.formatDate(d, "ddd");
            if (d.getFullYear() === now.getFullYear()) return Qt.formatDate(d, "d MMM");
            return Qt.formatDate(d, "dd.MM.yy");
        }
        function fullDate(t) { return t ? Qt.formatDateTime(new Date(t * 1000), "ddd, d MMMM yyyy, HH:mm") : ""; }
        function size(b) { return b < 1024 ? b + " B" : b < 1048576 ? Math.round(b / 1024) + " KB" : (b / 1048576).toFixed(1) + " MB"; }
        function sender(r) { return r.from_name || r.from_addr || "(unknown)"; }
        function attIcon(kind) { return ({ image: "image-outline", pdf: "pdf", archive: "archive-file", doc: "doc", sheet: "sheet", slides: "slides", audio: "audio", video: "video", calendar: "calendar", mail: "mail-outline" })[kind] || "file"; }

        function close() {
            closing = true;
            if (compose) saveDraft();
            if (pendingSend) reallySend();
            send({ cmd: "quit" });
            Qt.callLater(Qt.quit);
        }
    }

    Timer { id: changeTimer; interval: 150; onTriggered: app.refreshList() }
    // summaries start only when you stay on a message (J/K through the list doesn't queue them up)
    Timer { id: autoAnalyze; interval: 1200; onTriggered: app.analyze(false, true) }
    Timer { id: searchTimer; interval: 260; onTriggered: app.runSearch() }
    Timer { id: draftTimer; interval: 1500; onTriggered: app.saveDraft() }
    Timer { id: sendTimer; interval: 5000; onTriggered: app.reallySend() }
    // relative dates ("Today") and groups roll over while the window stays open
    Timer { interval: 60000; repeat: true; running: true; onTriggered: if (app.items.length) app.items = app.items.slice() }

    // ------------------------------------------------------------------ window
    FloatingWindow {
        id: win
        title: Quickshell.env("GLASS_MAIL_TITLE") || "Glass Mail"
        implicitWidth: parseInt(Quickshell.env("GM_W") || "1440")
        implicitHeight: parseInt(Quickshell.env("GM_H") || "900")
        minimumSize: Qt.size(620, 480)
        color: "transparent"
        onClosed: app.close()

        Item {
            id: root
            anchors.fill: parent
            focus: true
            Component.onCompleted: app.rootItem = root

            Keys.onPressed: event => {
                const k = event.key, ctrl = event.modifiers & Qt.ControlModifier, shift = event.modifiers & Qt.ShiftModifier;
                const t = event.text;
                let done = true;
                if (k === Qt.Key_Escape) {
                    if (menu.shown) menu.close();
                    else if (app.selCount) app.sel = ({});
                    else if (app.page !== "") app.closeSettings();
                    else if (app.searching) app.clearSearch();
                    else if (root.stacked && app.cur) app.closeMsg();
                    else done = false;
                }
                else if (ctrl && (k === Qt.Key_F || k === Qt.Key_K)) app.focusSearch();
                else if (ctrl && k === Qt.Key_N) app.newMessage();
                else if (ctrl && k === Qt.Key_R || k === Qt.Key_F5) app.refresh();
                else if (ctrl && k === Qt.Key_A) app.selectAll();
                else if (ctrl && k === Qt.Key_Z || t === "z") app.undo();
                else if (ctrl && k === Qt.Key_Comma) app.openSettings();
                else if (ctrl) done = false;
                else if (t === "j" || k === Qt.Key_Down) app.step(1);
                else if (t === "k" || k === Qt.Key_Up) app.step(-1);
                else if (t === "/") app.focusSearch();
                else if (t === "c") app.newMessage();
                else if (t === "e") app.act("archive");
                else if (t === "#" || k === Qt.Key_Delete) app.act(shift && k === Qt.Key_Delete ? "delete" : "trash");
                else if (t === "!") app.act("spam");
                else if (t === "s") app.toggleStar();
                else if (t === "u" || t === "U") app.toggleRead();
                else if (t === "r") app.reply(false);
                else if (t === "a") app.reply(true);
                else if (t === "f") app.forward();
                else if (t === "x") { if (app.cur) app.toggleSel(app.cur); }
                else if (t === "t") app.translate();
                else if (t === "b") app.brief();
                else if (t === "?") { app.openSettings(); app.settingsTab = "keys"; }
                else if (k === Qt.Key_Return || k === Qt.Key_Enter || t === "o") { if (!app.cur) app.step(0); }
                else done = false;
                event.accepted = done;
            }

            // window tint: niri blurs what is behind (rules-mail.kdl), we add the Matugen wash
            Rectangle {
                anchors.fill: parent
                radius: 20
                gradient: Gradient {
                    GradientStop { position: 0.0; color: theme.alpha(theme.mix(theme.base, theme.deep, 0.30), 0.62) }
                    GradientStop { position: 1.0; color: theme.alpha(theme.base, 0.72) }
                }
            }

            readonly property real gap: 8
            readonly property bool narrow: width < 1180
            readonly property bool stacked: width < 940          // list and message take turns
            readonly property real sideW: narrow ? 72 : Math.round(Math.min(290, Math.max(236, width * 0.18)))
            readonly property real listW: stacked ? width - sideW - gap * 3 : Math.round(Math.min(500, Math.max(360, (width - sideW) * 0.36)))

            Sidebar {
                id: sidebar
                app: app
                collapsed: root.narrow
                x: root.gap; y: root.gap
                width: root.sideW
                height: root.height - root.gap * 2
                Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            }

            MessageList {
                id: list
                app: app
                x: sidebar.x + sidebar.width + root.gap
                y: root.gap
                width: root.listW
                height: root.height - root.gap * 2
                visible: (app.page === "" || app.page === "ai") && !(root.stacked && (app.cur || app.page === "ai"))
            }

            Reader {
                id: reader
                app: app
                stacked: root.stacked
                x: root.stacked ? list.x : list.x + list.width + root.gap
                y: root.gap
                width: root.width - x - root.gap
                height: root.height - root.gap * 2
                visible: app.page === "" && (!root.stacked || app.cur)
            }

            AiPanel {
                id: aiPanel
                app: app
                stacked: root.stacked
                x: reader.x
                y: root.gap
                width: reader.width
                height: root.height - root.gap * 2
                visible: app.page === "ai"
            }

            SettingsPage {
                id: settingsPage
                app: app
                x: list.x
                y: root.gap
                width: root.width - x - root.gap
                height: root.height - root.gap * 2
                visible: app.page === "settings"
            }

            Compose {
                id: composer
                app: app
                visible: app.compose !== null
                width: Math.min(680, root.width - sidebar.width - root.gap * 4)
                height: app.composeMin ? 52 : Math.min(720, root.height - root.gap * 6)
                x: root.width - width - root.gap * 3
                y: root.height - height - root.gap * 3
                Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
            }

            Toasts {
                id: toasts
                app: app
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 26 }
            }

            ContextMenu {
                id: menu
                app: app
                anchors.fill: parent
            }

            Text {
                anchors.centerIn: parent
                visible: app.fatal !== ""
                text: app.fatal
                color: theme.bad
                font.family: theme.font
                font.pixelSize: 18
            }
        }
    }

    // notifications (glass-mail --open), mailto: links (glass-mail --mailto) and test hooks
    IpcHandler {
        target: "glassmail"
        function openMessage(acc: string, folder: string, uid: int): void {
            const f = app.folderOf(acc, folder);
            if (f && f.role === "inbox" && !app.multi) app.setView({ acc: acc, folder: folder });
            else if (f && f.role === "inbox") app.setView({ acc: "*", role: "inbox" });
            else if (f) app.setView({ acc: acc, folder: folder });
            app.openKey(acc, folder, uid);
        }
        function mailto(url: string): void { app.mailto(url) }
        function compose(): void { app.newMessage() }
        function view(acc: string, folder: string): void { app.setView(acc === "*" ? { acc: "*", role: folder || "inbox" } : acc === "starred" ? { kind: "starred" } : { acc: acc, folder: folder }) }
        function openIndex(i: int): void { const l = app.visibleItems(); if (l.length > i) app.open(l[i]) }
        function search(q: string): void { app.search(q) }
        function settings(tab: string): void { app.openSettings(); if (tab) app.settingsTab = tab }
        function addAccount(): void { app.openSettings(); app.editAccount = ({}) }
        function reply(all: bool): void { app.reply(all) }
        function forward(): void { app.forward() }
        function images(): void { app.allowImages(false) }
        function menuDemo(): void { const l = app.visibleItems(); if (l.length) app.rowMenu(l[0], app.rootItem, app.rootItem.width / 2, app.rootItem.height / 3) }
        function closeMenu(): void { menu.close() }
        function minimize(on: bool): void { app.composeMin = on }
        function act(op: string): void { app.act(op) }
        function selectFirst(n: int): void { const l = app.visibleItems(); const s = {}; for (let i = 0; i < Math.min(n, l.length); i++) s[app.key(l[i])] = l[i]; app.sel = s }
        function state(): string { return JSON.stringify({ accounts: app.accounts.length, view: app.view, items: app.items.length, cur: app.cur ? app.cur.subject : "", msg: app.msg ? (app.msg.subject || app.msg.error || "") : "", page: app.page, compose: !!app.compose, unread: app.unread.unread, search: app.searchResults().length }) }
        function aiReply(i: int): void { if (app.analysis && app.analysis.result && app.analysis.result.replies.length > i) app.aiReplyWith(app.analysis.result.replies[i]) }
        function aiCompose(mode: string, prompt: string): void { app.aiCompose(mode, prompt) }
        function ask(q: string): void { app.ask(q) }
        function brief(): void { app.brief() }
        function translate(): void { app.translate() }
        function aiState(): string { return JSON.stringify({ state: app.aiState, analysis: app.analysis ? (app.analysis.loading ? "loading" : app.analysis.error || "done") : "", assist: app.assist ? (app.assist.loading ? "loading" : "done") : "", answer: app.answer ? (app.answer.loading ? "loading" : "done") : "", translation: app.translation ? (app.translation.loading ? "loading" : "done") : "", body: app.compose ? app.compose.body.slice(0, 200) : "" }) }
        function quit(): void { app.close() }
        // renders only this window's own content to a PNG (no screen capture)
        function shot(path: string): void { app.rootItem.grabToImage(r => r.saveToFile(path)) }
    }
}
