import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../"
import "../bar"

// Liquid-glass shortcut cheat sheet (Mod+Shift+/). The data comes from ~/.local/bin/niri-keys,
// which reads the binds niri actually loads; it is re-read on every open, so new binds show up
// immediately. IPC: `serpantinum ipc call cheatsheet toggle|open|close|reload`.
Scope {
    id: root

    property bool open: false
    property var groups: []
    property int total: 0
    property string query: ""
    readonly property string keysBin: (Quickshell.env("HOME") ?? "") + "/.local/bin/niri-keys"

    function show() {
        if (!loader.running) loader.running = true;   // refresh in the background
        query = "";
        open = true;
    }
    function hide() { open = false; }
    function toggle() { if (open) hide(); else show(); }

    Process {
        id: loader
        command: [root.keysBin, "--json"]
        running: true                                 // one prefetch at startup
        stdout: StdioCollector {
            id: out
            onStreamFinished: {
                try {
                    let d = JSON.parse(out.text);
                    root.groups = d.groups || [];
                    root.total = d.count || 0;
                } catch (e) {
                    console.warn("cheatsheet: bad niri-keys output:", e);
                }
            }
        }
    }

    IpcHandler {
        target: "cheatsheet"
        function toggle(): string { root.toggle(); return root.open ? "open" : "closed"; }
        function open(): string { root.show(); return "open"; }
        function close(): string { root.hide(); return "closed"; }
        function reload(): string { loader.running = true; return "reloading"; }
        // open with a pre-filled filter, e.g. `serpantinum ipc call cheatsheet filter music`
        function filter(q: string): string { root.show(); search.text = q; return root.shownCount + " match"; }
    }

    // ── search ───────────────────────────────────────────────────────────
    readonly property var tokens: query.trim().toLowerCase().split(/\s+/).filter(t => t.length > 0)

    readonly property var keyWords: ({ "⌘": "mod super win", "⇧": "shift", "←": "left", "→": "right",
                                       "↑": "up", "↓": "down", "↵": "enter return", "⌫": "backspace" })

    function fuzzy(tok, s) {        // subsequence match; returns score or -1
        let i = 0, score = 0, last = -2;   // last = string position of the previous hit
        for (let p = 0; p < s.length && i < tok.length; p++) {
            if (s[p] === tok[i]) { score += (last === p - 1 ? 2 : 1); last = p; i++; }
        }
        return i === tok.length ? score : -1;
    }

    function scoreItem(it, groupName, allowFuzzy) {
        let label = it.label.toLowerCase();
        let key = it.key.toLowerCase();
        let caps = it.caps.map(c => (c.t + " " + (keyWords[c.t] || "")).toLowerCase()).join(" ");
        let q = root.query.trim().toLowerCase().replace(/\s*\+\s*/g, "+");
        if (q && (key === q || key.replace(/^mod\+/, "super+") === q)) return 1000;
        let hay = label + " " + key.replace(/\+/g, " ") + " " + caps + " " + groupName.toLowerCase() + " " + (it.cmd || "").toLowerCase();
        let total = 0;
        for (let t of tokens) {
            let tt = t.replace(/\+/g, " ").trim();
            let at = hay.indexOf(tt);
            if (at >= 0) {
                total += 20 + (label.indexOf(tt) === 0 ? 30 : 0) + (/\b/.test(hay[at - 1] || " ") && (at === 0 || " :/(-".indexOf(hay[at - 1]) >= 0) ? 15 : 0);
                continue;
            }
            if (!allowFuzzy || tt.length < 3) return -1;
            let f = fuzzy(tt, label);
            if (f < 0 || f < tt.length * 1.4) return -1;   // demand mostly-contiguous runs
            total += f;
        }
        return total;
    }

    readonly property var filtered: {
        if (tokens.length === 0) return groups;
        // exact (substring) matches first; typo-tolerant fuzzy matching only when nothing matched
        for (let allowFuzzy of [false, true]) {
            let res = [];
            for (let g of groups) {
                let items = [];
                for (let it of g.items) {
                    let s = scoreItem(it, g.name, allowFuzzy);
                    if (s >= 0) items.push({ it: it, s: s });
                }
                if (!items.length) continue;
                items.sort((a, b) => b.s - a.s);
                res.push({ name: g.name, icon: g.icon, items: items.map(x => x.it), best: items[0].s });
            }
            res.sort((a, b) => b.best - a.best);
            if (res.length || allowFuzzy) return res;
        }
        return [];
    }
    readonly property int shownCount: filtered.reduce((n, g) => n + g.items.length, 0)

    function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
    function highlight(label, toks) {
        if (!toks.length) return label;
        let low = label.toLowerCase();
        let mark = new Array(label.length).fill(false);
        for (let t of toks) {
            let at = low.indexOf(t);
            if (at >= 0) for (let i = at; i < at + t.length; i++) mark[i] = true;
        }
        let outS = "", on = false;
        let col = ThemeBackend.text;
        for (let i = 0; i < label.length; i++) {
            if (mark[i] && !on) { outS += "<font color=\"" + col + "\"><b>"; on = true; }
            if (!mark[i] && on) { outS += "</b></font>"; on = false; }
            outS += esc(label[i]);
        }
        if (on) outS += "</b></font>";
        return outS;
    }

    readonly property var accents: [ThemeBackend.blue, ThemeBackend.mauve, ThemeBackend.teal, ThemeBackend.peach,
                                    ThemeBackend.green, ThemeBackend.pink, ThemeBackend.sapphire, ThemeBackend.yellow,
                                    ThemeBackend.maroon, ThemeBackend.red]
    function accentFor(name) {
        let i = groups.findIndex(g => g.name === name);
        let c = accents[(i < 0 ? 0 : i) % accents.length];
        // Matugen can hand out dark tones for some slots; keep every accent readable on glass.
        return c.hslLightness < 0.68 ? Qt.hsla(c.hslHue, Math.max(c.hslSaturation, 0.45), 0.74, 1) : c;
    }

    // ── window ───────────────────────────────────────────────────────────
    PanelWindow {
        id: win
        color: "transparent"
        visible: shown
        property bool shown: false

        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "qs-cheatsheet"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        BackgroundEffect.blurRegion: Region {
            x: Math.round(card.x); y: Math.round(card.y)
            width: Math.round(card.width); height: Math.round(card.height)
            radius: card.radius
        }

        property real t: 0
        Connections {
            target: root
            function onOpenChanged() {
                if (root.open) {
                    win.shown = true;
                    closeAnim.stop();
                    openAnim.restart();
                    flick.contentY = 0;
                    search.forceActiveFocus();
                } else {
                    openAnim.stop();
                    closeAnim.restart();
                }
            }
        }
        NumberAnimation { id: openAnim; target: win; property: "t"; to: 1; duration: 480; easing.type: Easing.OutQuint }
        SequentialAnimation {
            id: closeAnim
            NumberAnimation { target: win; property: "t"; to: 0; duration: 200; easing.type: Easing.InCubic }
            ScriptAction { script: { win.shown = false; root.query = ""; search.text = ""; } }
        }

        // dim scrim; click outside the card closes
        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.30 * win.t)
            MouseArea { anchors.fill: parent; onClicked: root.hide() }
        }

        readonly property int cols: width >= 1500 ? 4 : (width >= 1100 ? 3 : 2)
        readonly property real gap: 14

        // balanced masonry: biggest groups first into the shortest column, then each column
        // keeps the groups in their usual order (estimates match GroupCard's real sizes)
        readonly property var columns: {
            let n = cols, out = [], h = [];
            for (let i = 0; i < n; i++) { out.push([]); h.push(0); }
            let est = g => 60 + gap + g.items.reduce((s, it) => s + (it.label.length > 40 ? 46 : 31), 0);
            let list = root.filtered.map((g, i) => ({ g: g, i: i, h: est(g) }));
            list.slice().sort((a, b) => b.h - a.h || a.i - b.i).forEach(e => {
                let k = 0;
                for (let i = 1; i < n; i++) if (h[i] < h[k]) k = i;
                out[k].push(e);
                h[k] += e.h;
            });
            out.forEach(col => col.sort((a, b) => a.i - b.i));
            out.sort((a, b) => (a.length ? a[0].i : 999) - (b.length ? b[0].i : 999));
            return out.map(col => col.map(e => e.g));
        }

        Item {
            id: card
            readonly property real radius: 26
            readonly property real pad: 24
            width: Math.min(win.width - 96, 1720)
            height: Math.min(win.height - 72, header.height + Math.max(flick.contentHeight, 110) + footer.height + pad * 2 + 36)
            x: Math.round((win.width - width) / 2)
            y: Math.round((win.height - height) / 2 + (1 - win.t) * 18)
            opacity: win.t
            scale: 0.975 + 0.025 * win.t

            GlassPill {
                anchors.fill: parent
                radius: card.radius
                tintAlpha: 0.58
                lit: true
            }
            MouseArea { anchors.fill: parent; onClicked: search.forceActiveFocus() }

            // ── header ──
            Item {
                id: header
                x: card.pad; y: card.pad
                width: card.width - card.pad * 2
                height: 50

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0
                    Text {
                        text: "Keyboard shortcuts"
                        color: ThemeBackend.text
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 26
                        font.weight: Font.Black
                    }
                    Text {
                        text: root.tokens.length
                              ? root.shownCount + " of " + root.total + " match"
                              : root.total + " shortcuts · read live from your niri config"
                        color: ThemeBackend.overlay2
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 13
                    }
                }

                // search field
                Item {
                    id: searchBox
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(460, parent.width * 0.4)
                    height: 46
                    GlassPill {
                        anchors.fill: parent
                        radius: 15
                        tintAlpha: 0.30
                        raised: false
                        lit: search.text.length > 0
                    }
                    Text {
                        id: glass
                        x: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(0xF0349)
                        color: ThemeBackend.overlay2
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: 18
                    }
                    TextInput {
                        id: search
                        anchors.left: glass.right
                        anchors.leftMargin: 10
                        anchors.right: clearBtn.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        color: ThemeBackend.text
                        selectionColor: Qt.rgba(ThemeBackend.blue.r, ThemeBackend.blue.g, ThemeBackend.blue.b, 0.45)
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: 16
                        clip: true
                        focus: true
                        onTextChanged: { root.query = text; flick.contentY = 0; }
                        Keys.onEscapePressed: root.hide()
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Down) { flick.scrollBy(90); event.accepted = true; }
                            else if (event.key === Qt.Key_Up) { flick.scrollBy(-90); event.accepted = true; }
                            else if (event.key === Qt.Key_PageDown) { flick.scrollBy(flick.height * 0.8); event.accepted = true; }
                            else if (event.key === Qt.Key_PageUp) { flick.scrollBy(-flick.height * 0.8); event.accepted = true; }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text.length === 0
                            text: "Search keys, actions, groups…"
                            color: ThemeBackend.overlay1
                            font: search.font
                        }
                    }
                    Text {
                        id: clearBtn
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text.length > 0
                        text: String.fromCodePoint(0xF0156)
                        color: clearMa.containsMouse ? ThemeBackend.text : ThemeBackend.overlay1
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: 16
                        MouseArea { id: clearMa; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true; onClicked: { search.text = ""; search.forceActiveFocus(); } }
                    }
                }
            }

            // ── groups ──
            Flickable {
                id: flick
                x: card.pad
                y: header.y + header.height + 18
                width: card.width - card.pad * 2
                height: card.height - y - footer.height - card.pad - 10
                contentHeight: colsRow.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                function scrollBy(d) { contentY = Math.max(0, Math.min(contentHeight - height, contentY + d)); }
                Behavior on contentY { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

                Row {
                    id: colsRow
                    spacing: win.gap
                    Repeater {
                        model: win.columns
                        delegate: Column {
                            required property var modelData
                            width: (flick.width - win.gap * (win.cols - 1)) / win.cols
                            spacing: win.gap
                            Repeater {
                                model: parent.modelData
                                delegate: GroupCard {
                                    required property var modelData
                                    width: parent.width
                                    group: modelData
                                    accent: root.accentFor(modelData.name)
                                    tokens: root.tokens
                                    highlight: root.highlight
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: root.tokens.length > 0 && root.shownCount === 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 40
                    text: "No shortcut matches “" + root.query + "”"
                    color: ThemeBackend.overlay2
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 16
                }
            }

            // ── footer ──
            Item {
                id: footer
                x: card.pad
                width: card.width - card.pad * 2
                height: 32
                anchors.bottom: parent.bottom
                anchors.bottomMargin: card.pad - 6

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 18
                    Repeater {
                        model: [ { k: "Type", d: "to filter" }, { k: "↑↓", d: "scroll" }, { k: "Esc", d: "close" } ]
                        delegate: Row {
                            required property var modelData
                            spacing: 7
                            Keycap { text: modelData.k; modifier: true; anchors.verticalCenter: parent.verticalCenter }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.d
                                color: ThemeBackend.overlay2
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Repeater {
                        model: [
                            { label: "Edit binds", icon: 0xF03EB, act: "edit" },
                            { label: "niri overlay", icon: 0xF030C, act: "niri" }
                        ]
                        delegate: Item {
                            id: btn
                            required property var modelData
                            width: btnRow.implicitWidth + 24
                            height: 30
                            GlassPill { anchors.fill: parent; radius: 10; tintAlpha: btnMa.containsMouse ? 0.38 : 0.20; raised: false; lit: btnMa.containsMouse }
                            Row {
                                id: btnRow
                                anchors.centerIn: parent
                                spacing: 6
                                Text { text: String.fromCodePoint(btn.modelData.icon); color: ThemeBackend.subtext0; font.family: ThemeBackend.iconFont; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                                Text { text: btn.modelData.label; color: ThemeBackend.subtext1; font.family: ThemeBackend.fontFamily; font.pixelSize: 12; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                            }
                            MouseArea {
                                id: btnMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.hide();
                                    if (btn.modelData.act === "niri")
                                        Quickshell.execDetached(["sh", "-c", "sleep 0.25; niri msg action show-hotkey-overlay"]);
                                    else
                                        Quickshell.execDetached(["kitty", "--directory", (Quickshell.env("HOME") ?? "") + "/.config/niri/user",
                                                                 "zsh", "-ic", "${EDITOR:-nano} binds.kdl; exec zsh"]);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
