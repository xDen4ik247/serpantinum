// ai-notes panel: liquid-glass UI for the local Obsidian AI tools (standalone quickshell config,
// started by ~/.local/bin/ai-notes-panel; nothing here is loaded by the Serpantinum shell).
//   AIN_MODE=ask   Mod+N        ask your vault; answer streams in with clickable [[note]] citations
//   AIN_MODE=menu  Mod+Shift+N  actions for the note open in Obsidian: links/tags, tidy (diff), study cards,
//                               voice note, weekly review
// All work is done by the `ai-notes` CLI (--jsonl event lines). The vault is only written after an explicit accept.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string cli: home + "/.local/bin/ai-notes"
    readonly property string runDir: (Quickshell.env("XDG_RUNTIME_DIR") ?? "/tmp") + "/ai-notes"
    property string view: (Quickshell.env("AIN_MODE") ?? "ask") === "menu" ? "menu" : "ask"

    // note context
    property string note: ""
    property var recent: []
    property var voice: ({ phase: "idle" })
    readonly property string noteTitle: note === "" ? "" : note.split("/").pop().replace(/\.md$/, "")

    // job state
    property bool busy: false
    property string status: ""
    property string err: ""
    property string question: ""
    property string answer: ""
    property var sources: []
    property var result: null
    property string flash: ""
    property int sel: 0
    property var picks: ({})        // suggest: key -> true/false ; cards: index -> bool
    property double tStart: 0
    property string took: ""

    readonly property var actions: [
        { key: "suggest", label: "Suggest links & tags", icon: "⇄", hint: "related notes and tags as chips — nothing is written until you accept" },
        { key: "tidy", label: "Tidy this note", icon: "✓", hint: "formatting, headings, RU/EN typos — shown as a diff" },
        { key: "cards", label: "Study cards", icon: "▤", hint: "Q/A cards, or Japanese vocab with furigana → Anki" },
        { key: "voice", label: "Voice note", icon: "●", hint: "record → Whisper (NPU) → structured note in “Voice notes/”" },
        { key: "weekly", label: "Weekly review", icon: "◷", hint: "daily notes + tasks + calendar → Weekly/YYYY-Www" },
        { key: "ask", label: "Ask your vault", icon: "?", hint: "question → answer with [[note]] citations" }
    ]

    // ---- Matugen colours ---------------------------------------------------------------------
    property color cBase: "#1e1e2e"
    property color cText: "#cdd6f4"
    property color cSub: "#a6adc8"
    property color cAccent: "#89b4fa"
    property color cGreen: "#a6e3a1"
    property color cRed: "#f38ba8"
    FileView {
        path: root.home + "/.local/state/serpantinum/qs_matugen_colors.json"
        onLoaded: {
            try {
                let c = JSON.parse(text()); c = c.colors ?? c;
                root.cBase = c.base ?? root.cBase; root.cText = c.text ?? root.cText;
                root.cSub = c.subtext0 ?? root.cSub; root.cAccent = c.blue ?? root.cAccent;
                root.cGreen = c.green ?? root.cGreen; root.cRed = c.red ?? root.cRed;
            } catch (e) {}
        }
    }

    // voice state file (written by `ai-notes voice …`; watched, no polling)
    FileView {
        id: voiceFile
        path: root.runDir + "/voice.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { try { root.voice = JSON.parse(text()); } catch (e) {} }
    }
    property int recSecs: 0
    Timer {
        running: root.voice.phase === "recording"
        interval: 1000; repeat: true; triggeredOnStart: true
        onTriggered: root.recSecs = Math.max(0, Math.round(Date.now() / 1000 - (root.voice.t0 ?? Date.now() / 1000)))
    }

    // ---- context ------------------------------------------------------------------------------
    Process {
        id: ctx
        running: true
        command: [root.cli, "current", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let d = JSON.parse(text);
                    root.note = d.current ?? "";
                    root.recent = d.recent ?? [];
                    if (d.voice) root.voice = d.voice;
                } catch (e) {}
                // tests: AIN_NOTE overrides the note, AIN_AUTO=suggest|tidy|cards|voice|weekly|ask:question runs a view
                let n = Quickshell.env("AIN_NOTE") ?? "";
                if (n !== "") root.note = n;
                let auto = Quickshell.env("AIN_AUTO") ?? "";
                if (auto.startsWith("ask:")) { root.view = "ask"; root.ask(auto.substring(4)); }
                else if (auto !== "") root.openAction(root.actions.findIndex(a => a.key === auto));
            }
        }
    }
    function cycleNote() {
        if (root.view !== "menu" || root.recent.length < 2) return;
        let i = root.recent.indexOf(root.note);
        root.note = root.recent[(i + 1) % root.recent.length];
    }

    // ---- job runner: `ai-notes --jsonl …` ------------------------------------------------------
    Process {
        id: job
        stdout: SplitParser {
            onRead: line => {
                let d = null;
                try { d = JSON.parse(line); } catch (e) { return; }
                if (d.type === "status") root.status = d.msg;
                else if (d.type === "sources") root.sources = d.sources;
                else if (d.type === "delta") { root.answer += d.text; root.status = ""; }
                else if (d.type === "error") root.err = d.msg;
                else if (d.type === "result") root.onResult(d);
                else if (d.type === "done") root.took = (d.ms / 1000).toFixed(1) + " s";
            }
        }
        stderr: SplitParser { onRead: line => { if (line.indexOf("Error") >= 0 || line.indexOf("error") >= 0) root.lastStderr = line; } }
        onExited: (code, st) => {
            root.busy = false;
            root.status = "";
            if (code !== 0 && root.err === "" && root.result === null && root.answer === "")
                root.err = root.lastStderr !== "" ? root.lastStderr : "ai-notes failed (exit " + code + ")";
            if (root.took === "" && root.tStart > 0) root.took = ((Date.now() - root.tStart) / 1000).toFixed(1) + " s";
            root.afterJob();
        }
    }
    property string lastStderr: ""
    property string pending: ""     // what the running job is (for afterJob)
    function run(kind, args) {
        if (job.running) job.running = false;
        root.pending = kind;
        root.err = ""; root.status = "Starting…"; root.took = ""; root.lastStderr = "";
        root.tStart = Date.now();
        root.busy = true;
        job.command = [root.cli, "--jsonl"].concat(args);
        job.running = true;
    }
    function onResult(d) {
        let k = root.pending;
        if (k === "apply-suggest" || k === "tidy-apply" || k === "cards-send" || k === "weekly-write") {
            root.applyDone(k, d);
            return;
        }
        root.result = d;
        if (k === "suggest") {
            let p = {};
            for (let l of d.links ?? []) p["l:" + l.link] = true;
            for (let t of d.tags ?? []) p["t:" + t.tag] = t.existing === true;
            root.picks = p;
        } else if (k === "cards") {
            let p = {};
            for (let i = 0; i < (d.cards ?? []).length; i++) p[i] = true;
            root.picks = p;
        }
    }
    function afterJob() {}
    function applyDone(k, d) {
        if (k === "apply-suggest") root.flash = d.changed ? "Written to the note ✓" : "Nothing to change";
        else if (k === "tidy-apply") root.flash = d.changed ? "Note tidied ✓ (backup kept)" : "Nothing to change";
        else if (k === "weekly-write") root.flash = d.written ? "Weekly note written ✓" : (d.error === "exists" ? "Exists — press again to overwrite" : "Not written");
        else if (k === "cards-send") {
            let parts = [];
            if (d.sent) parts.push(d.sent + (d.to === "sr" ? " appended" : " added"));
            if (d.queued) parts.push(d.queued + " queued (Anki closed)");
            if (d.duplicate) parts.push(d.duplicate + " duplicate");
            if (d.errors && d.errors.length) parts.push(d.errors.length + " failed");
            root.flash = parts.join(" · ") || "Done";
        }
        if (k === "weekly-write" && d.error === "exists") root.weeklyForce = true;
        else root.done = true;
    }
    property bool done: false
    property bool weeklyForce: false

    function reset() {
        if (job.running) job.running = false;
        root.busy = false; root.status = ""; root.err = ""; root.answer = ""; root.sources = [];
        root.result = null; root.flash = ""; root.picks = ({}); root.took = ""; root.done = false; root.weeklyForce = false;
    }
    function openAction(i) {
        let a = root.actions[i];
        root.sel = i;
        if (a.key === "ask") { root.reset(); root.view = "ask"; return; }
        if (a.key === "voice") { root.reset(); root.view = "voice"; return; }
        if (a.key !== "weekly" && root.note === "") { root.flash = "No note open in Obsidian"; return; }
        root.reset();
        root.view = a.key;
        if (a.key === "suggest") root.run("suggest", ["suggest", root.note]);
        else if (a.key === "tidy") root.run("tidy", ["tidy", root.note]);
        else if (a.key === "cards") root.run("cards", ["cards", root.note]);
        else if (a.key === "weekly") root.run("weekly", ["weekly"]);
    }
    function back() {
        if (root.view === "menu" || (root.view === "ask" && (Quickshell.env("AIN_MODE") ?? "ask") !== "menu")) { Qt.quit(); return; }
        root.reset();
        root.view = "menu";
    }
    function ask(q) {
        q = q.trim();
        if (q === "") return;
        root.reset();
        root.question = q;
        root.run("ask", ["ask", q]);
    }
    function openUri(u) {
        Quickshell.execDetached(["xdg-open", u]);
        Qt.quit();
    }
    // small markdown -> StyledText (so linkColor applies), with [n] -> clickable [[note]]
    function esc(t) { return t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
    function linked(md) {
        let src = root.sources;
        let out = [];
        for (let ln of md.split("\n")) {
            let t = root.esc(ln);
            let h = t.match(/^\s*#{1,6}\s+(.*)$/);
            if (h) t = "<b>" + h[1] + "</b>";
            t = t.replace(/^(\s*)[-*+]\s+/, (m, sp) => "&nbsp;".repeat(sp.length * 2 + 2) + "•&nbsp;");
            t = t.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>").replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<i>$2</i>")
                 .replace(/`([^`]+)`/g, "<tt>$1</tt>");
            t = t.replace(/\[(\d{1,2})\]/g, (m, n) => {
                let s = src.find(x => x.n === parseInt(n));
                return s ? "<a href=\"" + s.uri + "\">[[" + root.esc(s.link) + "]]</a>" : m;
            });
            out.push(t);
        }
        return out.join("<br>");
    }
    // accept helpers
    function applySuggest() {
        let args = ["apply-suggest", root.result.note];
        for (let l of root.result.links ?? []) if (root.picks["l:" + l.link]) args.push("--link", l.link);
        for (let t of root.result.tags ?? []) if (root.picks["t:" + t.tag]) args.push("--tag", t.tag);
        if (args.length === 2) { root.flash = "Nothing accepted"; return; }
        root.run("apply-suggest", args);
    }
    function sendCards(to) {
        let idx = [];
        for (let i = 0; i < (root.result.cards ?? []).length; i++) if (root.picks[i]) idx.push(i);
        if (!idx.length) { root.flash = "No cards selected"; return; }
        root.run("cards-send", ["cards-send", root.result.proposal, "--to", to, "--select", idx.join(",")]);
    }
    function wc(k) { return root.result && root.result.counts ? root.result.counts[k] : 0; }
    function togglePick(k) { let p = Object.assign({}, root.picks); p[k] = !p[k]; root.picks = p; }
    function pickCount() { let n = 0; for (let k in root.picks) if (root.picks[k]) n++; return n; }

    // voice: start/stop run detached (survive closing the panel); progress comes from voice.json
    function voiceStart() { Quickshell.execDetached([root.cli, "voice", "start"]); }
    function voiceStop() { Quickshell.execDetached(["systemd-run", "--user", "--collect", "--quiet", root.cli, "voice", "stop"]); }
    function voiceCancel() { Quickshell.execDetached([root.cli, "voice", "cancel"]); }
    function fmtSecs(s) { return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2); }

    // =============================================================================================
    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "ai-notes"
        // AIN_NOFOCUS=1 (tests): do not grab the keyboard
        WlrLayershell.keyboardFocus: (Quickshell.env("AIN_NOFOCUS") ?? "") !== "" ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive

        BackgroundEffect.blurRegion: Region {
            x: Math.round(card.x); y: Math.round(card.y + card.slide)
            width: Math.round(card.width); height: Math.round(card.height)
            radius: card.radius
        }

        // tests (AIN_NOFOCUS): only the card takes input, clicks elsewhere go to the user's windows
        mask: (Quickshell.env("AIN_NOFOCUS") ?? "") !== "" ? testMask : null
        Region { id: testMask; item: card }

        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

        Item {
            id: keys
            anchors.fill: parent
            focus: root.view !== "ask"
            Keys.onPressed: event => {
                let k = event.key;
                event.accepted = true;
                if (k === Qt.Key_Escape) { root.back(); return; }
                if (root.view === "menu") {
                    if (k >= Qt.Key_1 && k <= Qt.Key_6) root.openAction(k - Qt.Key_1);
                    else if (k === Qt.Key_Down || k === Qt.Key_J) root.sel = (root.sel + 1) % root.actions.length;
                    else if (k === Qt.Key_Up || k === Qt.Key_K) root.sel = (root.sel + root.actions.length - 1) % root.actions.length;
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.openAction(root.sel);
                    else if (k === Qt.Key_Tab) root.cycleNote();
                    else if (k === Qt.Key_S) root.openAction(0);
                    else if (k === Qt.Key_T) root.openAction(1);
                    else if (k === Qt.Key_C) root.openAction(2);
                    else if (k === Qt.Key_V) root.openAction(3);
                    else if (k === Qt.Key_W) root.openAction(4);
                    else if (k === Qt.Key_A) root.openAction(5);
                } else if (root.view === "tidy" && root.result && !root.busy && !root.done) {
                    if (k === Qt.Key_Return || k === Qt.Key_Enter) root.run("tidy-apply", ["tidy-apply", root.result.proposal]);
                    else if (k === Qt.Key_Backspace) root.back();
                } else if (root.view === "voice") {
                    if (k === Qt.Key_Space || k === Qt.Key_Return || k === Qt.Key_Enter) {
                        if (root.voice.phase === "recording") root.voiceStop();
                        else if (root.voice.phase !== "transcribing" && root.voice.phase !== "writing") root.voiceStart();
                    } else if (k === Qt.Key_O && root.voice.phase === "done" && root.voice.uri) root.openUri(root.voice.uri);
                } else if (k === Qt.Key_Backspace) root.back();
                else if (k === Qt.Key_O && root.result && root.result.uri) root.openUri(root.result.uri);
            }
        }

        Item {
            id: card
            readonly property real pad: 22
            readonly property real radius: 20
            width: Math.min(win.width - 32, root.view === "ask" || root.view === "tidy" || root.view === "weekly" ? 760 : 680)
            Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
            height: Math.min(win.height * 0.86, content.implicitHeight + 2 * pad)
            Behavior on height { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(win.height * 0.14)
            property real slide: (1 - opacity) * 12
            transform: Translate { y: card.slide }
            opacity: 0
            NumberAnimation on opacity { running: true; from: 0; to: 1; duration: 420; easing.type: Easing.OutCubic }

            MouseArea { anchors.fill: parent }

            RectangularShadow {
                anchors.fill: parent; radius: card.radius; offset.y: 8; blur: 36
                color: Qt.rgba(0, 0, 0, 0.42); cached: true
            }
            ShaderEffect {
                anchors.fill: parent
                property size size: Qt.size(width, height)
                property real radius: card.radius
                property real rimWidth: 1.2
                property vector4d tint: Qt.vector4d(root.cBase.r, root.cBase.g, root.cBase.b, 0.62)
                property vector4d rimTop: Qt.vector4d(1, 1, 1, 0.44)
                property vector4d rimBottom: Qt.vector4d(1, 1, 1, 0.07)
                property real sheen: 0.05
                fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
            }

            Flickable {
                id: flick
                x: card.pad; y: card.pad
                width: card.width - 2 * card.pad
                height: card.height - 2 * card.pad
                contentHeight: content.implicitHeight
                clip: contentHeight > height
                interactive: contentHeight > height
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: content
                    width: flick.width
                    spacing: 14

                    // ---------- header
                    Item {
                        width: parent.width; height: 30
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            Btn {
                                visible: root.view !== "menu" && (Quickshell.env("AIN_MODE") ?? "ask") === "menu"
                                label: "‹"; small: true; onClicked: root.back()
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: ({ ask: "Ask your vault", menu: "Note actions", suggest: "Links & tags", tidy: "Tidy note",
                                         cards: "Study cards", voice: "Voice note", weekly: "Weekly review" })[root.view] ?? ""
                                color: root.cText
                                font.family: "Google Sans"; font.pixelSize: 16; font.weight: Font.DemiBold
                            }
                            Chip {
                                visible: root.flash !== "" || root.took !== ""
                                label: root.flash !== "" ? root.flash : root.took
                                accent: root.flash !== ""
                            }
                        }
                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            Btn {
                                visible: root.view !== "ask" && root.view !== "voice" && root.view !== "weekly" && root.note !== ""
                                label: root.noteTitle + (root.view === "menu" && root.recent.length > 1 ? "  ⇄" : "")
                                tip: "Tab: other recent note"; small: true
                                onClicked: root.view === "menu" ? root.cycleNote() : root.openUri("obsidian://open?vault=Vault&file=" + encodeURIComponent(root.note.replace(/\.md$/, "")))
                            }
                            Btn { label: "✕"; small: true; onClicked: Qt.quit() }
                        }
                    }

                    // ================= ASK
                    Rectangle {
                        visible: root.view === "ask"
                        width: parent.width; height: 46; radius: 14
                        color: Qt.rgba(1, 1, 1, input.activeFocus ? 0.10 : 0.06)
                        border.width: 1
                        border.color: input.activeFocus ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.55) : Qt.rgba(1, 1, 1, 0.08)
                        Behavior on border.color { ColorAnimation { duration: 220 } }
                        Text {
                            x: 16; anchors.verticalCenter: parent.verticalCenter
                            visible: input.text === ""
                            text: "Ask anything about your notes…  (EN / RU / JA)"
                            color: root.cSub; opacity: 0.7
                            font.family: "Google Sans"; font.pixelSize: 15
                        }
                        TextInput {
                            id: input
                            x: 16; width: parent.width - 32
                            anchors.verticalCenter: parent.verticalCenter
                            focus: root.view === "ask"
                            color: root.cText; selectionColor: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.4)
                            font.family: "Google Sans"; font.pixelSize: 15
                            clip: true
                            Keys.onReturnPressed: root.ask(text)
                            Keys.onEnterPressed: root.ask(text)
                            Keys.onEscapePressed: root.back()
                            Component.onCompleted: if (root.view === "ask") forceActiveFocus()
                        }
                    }
                    Connections {
                        target: root
                        function onViewChanged() { if (root.view === "ask") input.forceActiveFocus(); else keys.forceActiveFocus(); }
                    }
                    Row {
                        visible: root.view === "ask" && root.busy && root.answer === ""
                        spacing: 12
                        Dots {}
                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.status; color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13 }
                    }
                    Text {
                        visible: root.view === "ask" && root.answer !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        textFormat: Text.StyledText
                        text: root.linked(root.answer.trim())
                        color: root.cText; linkColor: root.cAccent
                        font.family: "Google Sans"; font.pixelSize: 15
                        lineHeight: 1.12
                        onLinkActivated: link => root.openUri(link)
                        HoverHandler { cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                    }
                    SectionTitle { visible: root.view === "ask" && root.sources.length > 0; label: "Sources" }
                    Flow {
                        visible: root.view === "ask" && root.sources.length > 0
                        width: parent.width; spacing: 6
                        Repeater {
                            model: root.view === "ask" ? root.sources : []
                            Btn {
                                required property var modelData
                                label: modelData.n + "  [[" + modelData.title + "]]"
                                small: true
                                onClicked: root.openUri(modelData.uri)
                            }
                        }
                    }

                    // ================= MENU
                    Text {
                        visible: root.view === "menu" && root.note === "" && !ctx.running
                        width: parent.width; wrapMode: Text.Wrap
                        text: "No note is open in Obsidian — note actions need one (weekly review, voice note and ask still work)."
                        color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13
                    }
                    Column {
                        visible: root.view === "menu"
                        width: parent.width
                        spacing: 2
                        Repeater {
                            model: root.actions
                            Rectangle {
                                id: row
                                required property var modelData
                                required property int index
                                readonly property bool rec: modelData.key === "voice" && root.voice.phase === "recording"
                                width: parent.width; height: 48; radius: 12
                                color: index === root.sel ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.20)
                                     : (am.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent")
                                Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                Rectangle {
                                    x: 8; anchors.verticalCenter: parent.verticalCenter
                                    width: 32; height: 32; radius: 10
                                    color: row.rec ? Qt.rgba(root.cRed.r, root.cRed.g, root.cRed.b, 0.25) : Qt.rgba(1, 1, 1, index === root.sel ? 0.14 : 0.07)
                                    Text {
                                        anchors.centerIn: parent; text: row.modelData.icon
                                        color: row.rec ? root.cRed : (row.index === root.sel ? root.cAccent : root.cText)
                                        font.family: "Google Sans"; font.pixelSize: 14; font.weight: Font.DemiBold
                                    }
                                }
                                Column {
                                    x: 52; anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 52 - 40
                                    Text {
                                        text: row.rec ? "Voice note — recording " + root.fmtSecs(root.recSecs) + " (open to stop)" : row.modelData.label
                                        color: root.cText; font.family: "Google Sans"; font.pixelSize: 14; font.weight: Font.Medium
                                    }
                                    Text {
                                        width: parent.width; elide: Text.ElideRight
                                        text: row.modelData.hint
                                        color: root.cSub; opacity: 0.75; font.family: "Google Sans"; font.pixelSize: 11
                                    }
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    text: String(row.index + 1)
                                    color: root.cSub; opacity: 0.5; font.family: "Google Sans"; font.pixelSize: 12
                                }
                                MouseArea {
                                    id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openAction(row.index)
                                }
                            }
                        }
                    }

                    // ================= shared: progress + error
                    Row {
                        visible: root.view !== "ask" && root.view !== "menu" && root.view !== "voice" && root.busy
                        spacing: 12
                        Dots {}
                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.status; color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13 }
                    }
                    Rectangle {
                        visible: root.err !== ""
                        width: parent.width; height: errText.implicitHeight + 20; radius: 12
                        color: Qt.rgba(root.cRed.r, root.cRed.g, root.cRed.b, 0.14)
                        Text {
                            id: errText
                            x: 12; y: 10; width: parent.width - 24; wrapMode: Text.Wrap
                            text: root.err; color: root.cText; font.family: "Google Sans"; font.pixelSize: 13
                        }
                    }

                    // ================= SUGGEST
                    SectionTitle { visible: root.view === "suggest" && root.result !== null; label: "Links — click to accept / reject" }
                    Text {
                        visible: root.view === "suggest" && root.result !== null && (root.result.links ?? []).length === 0
                        text: "No new related notes found."; color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13
                    }
                    Column {
                        visible: root.view === "suggest" && root.result !== null
                        width: parent.width; spacing: 6
                        Repeater {
                            model: root.view === "suggest" && root.result ? root.result.links : []
                            Rectangle {
                                id: lk
                                required property var modelData
                                readonly property bool on: root.picks["l:" + modelData.link] === true
                                width: parent.width; height: 44; radius: 12
                                color: on ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, lma.containsMouse ? 0.30 : 0.20)
                                          : Qt.rgba(1, 1, 1, lma.containsMouse ? 0.10 : 0.05)
                                border.width: 1; border.color: on ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.45) : Qt.rgba(1, 1, 1, 0.06)
                                Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
                                Text {
                                    x: 12; anchors.verticalCenter: parent.verticalCenter
                                    text: lk.on ? "✓" : "✕"; color: lk.on ? root.cAccent : root.cSub
                                    font.family: "Google Sans"; font.pixelSize: 14; font.weight: Font.Bold
                                }
                                Column {
                                    x: 36; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 36 - 60
                                    Text {
                                        text: "[[" + lk.modelData.link + "]]"; color: lk.on ? root.cText : root.cSub
                                        font.family: "Google Sans"; font.pixelSize: 13; font.weight: Font.Medium
                                        font.strikeout: !lk.on; elide: Text.ElideRight; width: parent.width
                                    }
                                    Text {
                                        text: lk.modelData.reason; color: root.cSub; opacity: 0.8; elide: Text.ElideRight; width: parent.width
                                        font.family: "Google Sans"; font.pixelSize: 11
                                    }
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                    text: Math.round(lk.modelData.score * 100) + "%"; color: root.cSub; opacity: 0.6
                                    font.family: "Google Sans"; font.pixelSize: 11
                                }
                                MouseArea { id: lma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.togglePick("l:" + lk.modelData.link) }
                            }
                        }
                    }
                    SectionTitle { visible: root.view === "suggest" && root.result !== null && (root.result.tags ?? []).length > 0; label: "Tags" }
                    Flow {
                        visible: root.view === "suggest" && root.result !== null
                        width: parent.width; spacing: 6
                        Repeater {
                            model: root.view === "suggest" && root.result ? root.result.tags : []
                            Btn {
                                required property var modelData
                                label: (root.picks["t:" + modelData.tag] ? "✓ #" : "#") + modelData.tag + (modelData.existing ? "" : "  new")
                                on: root.picks["t:" + modelData.tag] === true
                                onClicked: root.togglePick("t:" + modelData.tag)
                            }
                        }
                    }
                    Row {
                        visible: root.view === "suggest" && root.result !== null && !root.done
                        spacing: 8
                        Btn { label: "Apply accepted (" + root.pickCount() + ")"; on: true; onClicked: root.applySuggest() }
                        Btn { label: "Reject all"; onClicked: root.back() }
                    }

                    // ================= TIDY
                    Row {
                        visible: root.view === "tidy" && root.result !== null
                        spacing: 6
                        Chip { label: "+" + (root.result ? root.result.added : 0); accent: true }
                        Chip { label: "−" + (root.result ? root.result.removed : 0) }
                        Chip { visible: !!(root.result && root.result.parts_kept > 0); label: (root.result ? root.result.parts_kept : 0) + " part(s) left unchanged (safety check)" }
                    }
                    Text {
                        visible: root.view === "tidy" && root.result !== null && (root.result.diff ?? []).length === 0
                        text: "Already tidy — nothing to change."; color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13
                    }
                    Rectangle {
                        visible: root.view === "tidy" && root.result !== null && (root.result.diff ?? []).length > 0
                        width: parent.width; height: diffCol.implicitHeight + 16; radius: 12
                        color: Qt.rgba(0, 0, 0, 0.18)
                        Column {
                            id: diffCol
                            x: 8; y: 8; width: parent.width - 16
                            Repeater {
                                model: root.view === "tidy" && root.result ? root.result.diff : []
                                Rectangle {
                                    required property var modelData
                                    width: parent.width; height: dl.implicitHeight + 2
                                    radius: 4
                                    color: modelData.t === "add" ? Qt.rgba(root.cGreen.r, root.cGreen.g, root.cGreen.b, 0.14)
                                         : modelData.t === "del" ? Qt.rgba(root.cRed.r, root.cRed.g, root.cRed.b, 0.14) : "transparent"
                                    Text {
                                        id: dl
                                        x: 6; y: 1; width: parent.width - 12; wrapMode: Text.WrapAnywhere
                                        text: (modelData.t === "add" ? "+ " : modelData.t === "del" ? "− " : modelData.t === "hunk" ? "" : "  ") + modelData.s
                                        color: modelData.t === "add" ? root.cGreen : modelData.t === "del" ? root.cRed
                                             : modelData.t === "hunk" ? root.cAccent : root.cSub
                                        opacity: modelData.t === "ctx" ? 0.7 : 1
                                        font.family: "JetBrains Mono"; font.pixelSize: 12
                                        textFormat: Text.PlainText
                                    }
                                }
                            }
                        }
                    }
                    Row {
                        visible: root.view === "tidy" && root.result !== null && (root.result.diff ?? []).length > 0 && !root.done
                        spacing: 8
                        Btn { label: "Accept  ⏎"; on: true; onClicked: root.run("tidy-apply", ["tidy-apply", root.result.proposal]) }
                        Btn { label: "Reject"; onClicked: root.back() }
                    }

                    // ================= CARDS
                    Text {
                        visible: root.view === "cards" && root.result !== null
                        text: root.result ? (root.result.kind === "vocab" ? "Japanese vocabulary · readings from the jocr dictionary" : "Question / answer cards") + " · click to include / skip" : ""
                        color: root.cSub; font.family: "Google Sans"; font.pixelSize: 12
                    }
                    Column {
                        visible: root.view === "cards" && root.result !== null
                        width: parent.width; spacing: 6
                        Repeater {
                            model: root.view === "cards" && root.result ? root.result.cards : []
                            Rectangle {
                                id: cd
                                required property var modelData
                                required property int index
                                readonly property bool on: root.picks[index] === true
                                readonly property bool vocab: root.result && root.result.kind === "vocab"
                                width: parent.width; height: cdCol.implicitHeight + 16; radius: 12
                                color: on ? Qt.rgba(1, 1, 1, cma.containsMouse ? 0.12 : 0.08) : Qt.rgba(1, 1, 1, cma.containsMouse ? 0.05 : 0.02)
                                border.width: 1; border.color: on ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.35) : Qt.rgba(1, 1, 1, 0.05)
                                opacity: on ? 1 : 0.55
                                Behavior on opacity { NumberAnimation { duration: 200 } }
                                Text {
                                    x: 12; y: 9; text: cd.on ? "✓" : "○"; color: cd.on ? root.cAccent : root.cSub
                                    font.family: "Google Sans"; font.pixelSize: 13; font.weight: Font.Bold
                                }
                                Column {
                                    id: cdCol
                                    x: 34; y: 8; width: parent.width - 46; spacing: 2
                                    Row {
                                        visible: cd.vocab; spacing: 10
                                        Text { text: cd.modelData.expression ?? ""; color: root.cText; font.family: "Noto Sans CJK JP"; font.pixelSize: 17; font.weight: Font.Medium }
                                        Text { anchors.baseline: parent.children[0].baseline; text: cd.modelData.reading ?? ""; color: root.cAccent; font.family: "Noto Sans CJK JP"; font.pixelSize: 12 }
                                        Text { anchors.baseline: parent.children[0].baseline; text: (cd.modelData.meaning_en ?? "") + " · " + (cd.modelData.meaning_ru ?? ""); color: root.cText; font.family: "Google Sans"; font.pixelSize: 13 }
                                    }
                                    Text {
                                        visible: cd.vocab; width: parent.width; wrapMode: Text.Wrap
                                        text: (cd.modelData.example ?? "") + "  — " + (cd.modelData.example_translation ?? "")
                                        color: root.cSub; font.family: "Noto Sans CJK JP"; font.pixelSize: 12
                                    }
                                    Text {
                                        visible: !cd.vocab; width: parent.width; wrapMode: Text.Wrap
                                        text: cd.modelData.front ?? ""; color: root.cText; font.family: "Google Sans"; font.pixelSize: 13; font.weight: Font.Medium
                                    }
                                    Text {
                                        visible: !cd.vocab; width: parent.width; wrapMode: Text.Wrap
                                        text: cd.modelData.back ?? ""; color: root.cSub; font.family: "Google Sans"; font.pixelSize: 12
                                    }
                                }
                                MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.togglePick(cd.index) }
                            }
                        }
                    }
                    Row {
                        visible: root.view === "cards" && root.result !== null && !root.done
                        spacing: 8
                        Btn { label: "Send " + root.pickCount() + " to Anki"; on: true; onClicked: root.sendCards("anki") }
                        Btn { visible: !!(root.result && root.result.note); label: "Append to note (SR syntax)"; onClicked: root.sendCards("sr") }
                    }

                    // ================= VOICE
                    Item {
                        visible: root.view === "voice"
                        width: parent.width; height: 120
                        Rectangle {
                            id: recBtn
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 6; width: 74; height: 74; radius: 37
                            readonly property bool rec: root.voice.phase === "recording"
                            readonly property bool working: root.voice.phase === "transcribing" || root.voice.phase === "writing"
                            color: rec ? Qt.rgba(root.cRed.r, root.cRed.g, root.cRed.b, vma.containsMouse ? 0.45 : 0.32)
                                       : Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, vma.containsMouse ? 0.32 : 0.20)
                            border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.25)
                            Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
                            Rectangle {
                                anchors.centerIn: parent
                                width: recBtn.rec ? 22 : 26; height: width; radius: recBtn.rec ? 5 : 13
                                color: recBtn.rec ? root.cRed : root.cAccent
                                visible: !recBtn.working
                                Behavior on radius { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutQuint } }
                            }
                            Dots { visible: recBtn.working; width: 40; anchors.centerIn: parent }
                            // soft pulse ring while recording only
                            Rectangle {
                                anchors.centerIn: parent; width: parent.width; height: width; radius: width / 2
                                color: "transparent"; border.width: 2; border.color: root.cRed
                                visible: recBtn.rec
                                opacity: 0
                                SequentialAnimation on scale {
                                    running: recBtn.rec; loops: Animation.Infinite
                                    NumberAnimation { from: 1; to: 1.35; duration: 1400; easing.type: Easing.OutCubic }
                                }
                                SequentialAnimation on opacity {
                                    running: recBtn.rec; loops: Animation.Infinite
                                    NumberAnimation { from: 0.6; to: 0; duration: 1400; easing.type: Easing.OutCubic }
                                }
                            }
                            MouseArea {
                                id: vma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: recBtn.rec ? root.voiceStop() : (recBtn.working ? null : root.voiceStart())
                            }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 92
                            text: root.voice.phase === "recording" ? "Recording  " + root.fmtSecs(root.recSecs) + "  ·  Space / click to stop"
                                : root.voice.phase === "transcribing" ? "Transcribing with Whisper (NPU)…"
                                : root.voice.phase === "writing" ? "Structuring the note with the local LLM…"
                                : root.voice.phase === "done" ? "Saved: " + (root.voice.title ?? "")
                                : root.voice.phase === "error" ? "Failed: " + (root.voice.error ?? "")
                                : "Space / click to start recording"
                            color: root.voice.phase === "error" ? root.cRed : root.cSub
                            font.family: "Google Sans"; font.pixelSize: 13
                        }
                    }
                    Text {
                        visible: root.view === "voice" && (root.voice.phase === "writing") && (root.voice.transcript ?? "") !== ""
                        width: parent.width; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                        text: "“" + (root.voice.transcript ?? "") + "”"
                        color: root.cSub; opacity: 0.8; font.family: "Google Sans"; font.pixelSize: 12; font.italic: true
                    }
                    Row {
                        visible: root.view === "voice"
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8
                        Btn { visible: root.voice.phase === "done" && (root.voice.uri ?? "") !== ""; label: "Open note  O"; on: true; onClicked: root.openUri(root.voice.uri) }
                        Btn { visible: root.voice.phase === "recording"; label: "Discard"; onClicked: root.voiceCancel() }
                    }
                    Text {
                        visible: root.view === "voice"
                        width: parent.width; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter
                        text: "Recording continues if you close this panel — open it again (Mod+Shift+N → 4) to stop. Long lectures are fine; audio is cut into 28 s pieces for Whisper. The note goes to “Voice notes/” in your vault."
                        color: root.cSub; opacity: 0.6; font.family: "Google Sans"; font.pixelSize: 11
                    }

                    // ================= WEEKLY
                    Flow {
                        visible: root.view === "weekly" && root.result !== null
                        width: parent.width; spacing: 6
                        Chip { label: root.result ? (root.result.week ?? "") : ""; accent: true }
                        Chip { label: root.wc("daily") + " daily notes" }
                        Chip { label: root.wc("done") + " done" }
                        Chip { label: root.wc("overdue") + " overdue" }
                        Chip { label: root.wc("events") + " events" }
                        Chip { visible: !!(root.view === "weekly" && root.result && root.result.exists); label: "note exists" }
                    }
                    Rectangle {
                        visible: root.view === "weekly" && root.result !== null
                        width: parent.width; height: wk.implicitHeight + 24; radius: 12
                        color: Qt.rgba(0, 0, 0, 0.14)
                        Text {
                            id: wk
                            x: 14; y: 12; width: parent.width - 28; wrapMode: Text.Wrap
                            textFormat: Text.MarkdownText
                            text: root.result && root.view === "weekly" ? root.result.markdown.replace(/^---[\s\S]*?\n---\n/, "") : ""
                            color: root.cText; linkColor: root.cAccent
                            font.family: "Google Sans"; font.pixelSize: 13
                        }
                    }
                    Row {
                        visible: root.view === "weekly" && root.result !== null && !root.done
                        spacing: 8
                        Btn {
                            label: (root.weeklyForce || (root.result && root.result.exists) ? "Overwrite " : "Write ") + (root.result ? root.result.note : "")
                            on: true
                            onClicked: root.run("weekly-write", ["weekly-write", root.result.proposal].concat(root.weeklyForce ? ["--force"] : []))
                        }
                        Btn { label: "Cancel"; onClicked: root.back() }
                    }
                    Btn {
                        visible: root.view === "weekly" && root.done && root.result !== null
                        label: "Open " + (root.result ? root.result.note : ""); on: true
                        onClicked: root.openUri(root.result.uri)
                    }

                    // ---------- footer
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignRight
                        color: root.cSub; opacity: 0.55
                        font.family: "Google Sans"; font.pixelSize: 11
                        text: root.view === "ask" ? "Enter ask · click a [[note]] to open it in Obsidian · Esc close · everything runs locally"
                            : root.view === "menu" ? "1–6 or S T C V W A · ↑↓ Enter · Tab other recent note · Esc close"
                            : root.view === "tidy" ? "Enter accept · Backspace/Esc reject · a backup is kept in ~/.local/share/ai-notes/backups"
                            : root.view === "voice" ? "Space start/stop · O open note · Esc back"
                            : "Nothing is written until you accept · Esc back"
                    }
                }
            }
        }
    }

    component Dots: Item {
        width: 40; height: 20
        Row {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    width: 7; height: 7; radius: 4; color: root.cAccent; opacity: 0.25
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        PauseAnimation { duration: index * 140 }
                        NumberAnimation { to: 1; duration: 320; easing.type: Easing.OutCubic }
                        NumberAnimation { to: 0.25; duration: 420; easing.type: Easing.InOutCubic }
                        PauseAnimation { duration: (2 - index) * 140 }
                    }
                }
            }
        }
    }

    component SectionTitle: Text {
        property string label: ""
        text: label.toUpperCase()
        color: root.cSub; opacity: 0.8
        font.family: "Google Sans"; font.pixelSize: 11; font.weight: Font.DemiBold; font.letterSpacing: 1.2
    }

    component Chip: Rectangle {
        property string label: ""
        property bool accent: false
        height: 22; radius: 11
        width: chipText.implicitWidth + 16
        color: accent ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.22) : Qt.rgba(1, 1, 1, 0.08)
        Behavior on color { ColorAnimation { duration: 250 } }
        Text {
            id: chipText
            anchors.centerIn: parent
            text: parent.label
            color: parent.accent ? root.cAccent : root.cSub
            font.family: "Google Sans"
            font.pixelSize: 11
        }
    }

    component Btn: Rectangle {
        id: b
        property string label: ""
        property string tip: ""
        property bool on: false
        property bool small: false
        signal clicked()
        height: small ? 24 : 30
        width: Math.min(360, Math.max(height, t.implicitWidth + (small ? 16 : 22)))
        radius: height / 2
        color: on ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, ma.containsMouse ? 0.38 : 0.26)
                  : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.17) : Qt.rgba(1, 1, 1, 0.08))
        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Text {
            id: t
            anchors.centerIn: parent
            width: Math.min(implicitWidth, 360 - (b.small ? 16 : 22))
            elide: Text.ElideMiddle
            text: b.label
            color: b.on ? root.cAccent : root.cText
            font.family: /[぀-鿿]/.test(b.label) ? "Noto Sans CJK JP" : "Google Sans"
            font.pixelSize: b.small ? 11 : 12
            font.weight: Font.Medium
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }
}
