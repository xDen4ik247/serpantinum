// aipanel: liquid-glass AI popups (standalone quickshell config, started by ~/.local/bin/aipanel).
//   AIP_MODE=actions  Mod+Shift+A: pick an action for the clipboard / primary selection; the
//                     answer streams in from the local LLM (127.0.0.1:8765) and is copied back.
//   AIP_MODE=reader   Mod+Shift+Z: Japanese reading helper: furigana + word gloss (jocr daemon
//                     :8766 /furigana /lookup), translation + grammar breakdown (LLM), Add to Anki (/mine).
// Source texts arrive as files in $AIP_DIR (primary.txt, clip.txt, ocr.txt).
// Look and glass shader are shared with the jocr popup (~/.local/share/npu-ocr/ui).
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string mode: Quickshell.env("AIP_MODE") ?? "actions"
    readonly property string dir: Quickshell.env("AIP_DIR") ?? ""
    readonly property string llm: "http://127.0.0.1:8765"
    readonly property string ocrd: "http://127.0.0.1:8766"
    readonly property bool reader: mode === "reader"

    // sources
    property var src: ({ primary: "", clip: "", ocr: "" })
    property int loadedSrc: 0
    property string srcKey: ""
    readonly property string text: (src[srcKey] ?? "").trim()
    readonly property var srcNames: ({ primary: "Selection", clip: "Clipboard", ocr: "Last OCR" })
    readonly property var srcOrder: ["primary", "clip", "ocr"].filter(k => (src[k] ?? "").trim() !== "")

    // actions mode
    readonly property var actions: [
        { key: "en", label: "Translate → English", icon: "EN", sys: "Translate the user's text into natural English. Output only the translation." },
        { key: "ru", label: "Translate → Russian", icon: "RU", sys: "Translate the user's text into natural Russian. Output only the translation." },
        { key: "ja", label: "Translate → Japanese", icon: "日", sys: "Translate the user's text into natural Japanese. Output only the translation." },
        { key: "sum", label: "Summarize", icon: "≡", sys: "Summarize the user's text concisely: a one-line gist, then the key points as short markdown bullets. Answer in the same language as the text." },
        { key: "fix", label: "Fix grammar & typos", icon: "✓", sys: "Fix spelling, grammar and punctuation in the user's text. Keep its language, meaning, tone and formatting. Output only the corrected text, nothing else." },
        { key: "explain", label: "Explain", icon: "?", sys: "Explain the user's text or code clearly and briefly for a beginner, using markdown. Answer in English unless the text is Russian, then answer in Russian." },
        { key: "keigo", label: "Make polite (敬語)", icon: "敬", sys: "Rewrite the user's text as polite, natural Japanese business keigo (敬語: 尊敬語/謙譲語/丁寧語 as appropriate). If the text is not Japanese, first translate it into Japanese. Output only the rewritten Japanese text." },
        { key: "reply", label: "Suggest a reply", icon: "↩", sys: "The user received this message. Write one short, friendly, natural reply to it in the same language as the message. Output only the reply text." }
    ]
    property int sel: 0
    property var current: null
    property string out: ""
    property string state_: "pick"     // pick | busy | done | error
    property string note: ""
    property string flash: ""

    // reader mode
    property var tokens: []
    property var glosses: ({})          // index -> lookup entry
    property int picked: -1
    property string translation: ""
    property string grammar: ""
    property string rdState: "idle"     // idle | tr | gr | done | error
    property string ankiMsg: ""
    property bool showFurigana: true

    // ---- Matugen colours ---------------------------------------------------------------------
    property color cBase: "#1e1e2e"
    property color cText: "#cdd6f4"
    property color cSub: "#a6adc8"
    property color cAccent: "#89b4fa"
    FileView {
        path: root.home + "/.local/state/serpantinum/qs_matugen_colors.json"
        onLoaded: {
            try {
                let c = JSON.parse(text()); c = c.colors ?? c;
                root.cBase = c.base ?? root.cBase; root.cText = c.text ?? root.cText;
                root.cSub = c.subtext0 ?? root.cSub; root.cAccent = c.blue ?? root.cAccent;
            } catch (e) {}
        }
    }

    // ---- sources -------------------------------------------------------------------------------
    function gotSrc(k, t) {
        let s = Object.assign({}, root.src); s[k] = t; root.src = s;
        if (++root.loadedSrc === 3) root.pickSource();
    }
    FileView { path: root.dir + "/primary.txt"; onLoaded: root.gotSrc("primary", text()); onLoadFailed: root.gotSrc("primary", "") }
    FileView { path: root.dir + "/clip.txt"; onLoaded: root.gotSrc("clip", text()); onLoadFailed: root.gotSrc("clip", "") }
    FileView { path: root.dir + "/ocr.txt"; onLoaded: root.gotSrc("ocr", text()); onLoadFailed: root.gotSrc("ocr", "") }

    function hasJa(t) { return /[぀-ヿ一-鿿]/.test(t ?? ""); }
    function pickSource() {
        let order = root.srcOrder;
        if (root.reader) order = order.filter(k => root.hasJa(root.src[k]));
        root.srcKey = order.length ? order[0] : "";
        if (root.reader) root.startReader();
    }
    function cycleSource() {
        let order = root.reader ? root.srcOrder.filter(k => root.hasJa(root.src[k])) : root.srcOrder;
        if (order.length < 2) return;
        root.srcKey = order[(order.indexOf(root.srcKey) + 1) % order.length];
        if (root.reader) root.startReader(); else root.backToPick();
    }

    // ---- helpers ------------------------------------------------------------------------------
    Process { id: copier }
    function copy(txt, what) {
        if (!txt) return;
        if (!Quickshell.env("AIP_NOCOPY")) {   // AIP_NOCOPY=1: tests leave the clipboard alone
            copier.command = ["wl-copy", "--", txt];
            copier.running = true;
        }
        root.flash = what + " copied";
        flashTimer.restart();
    }
    Timer { id: flashTimer; interval: 1800; onTriggered: root.flash = "" }

    property var xhr: null
    // OpenAI-style streaming chat; calls onDelta(text) per chunk, onDone(ms) / onErr(msg)
    function chat(sys, user, maxTok, onDelta, onDone, onErr) {
        if (root.xhr) root.xhr.abort();
        let x = new XMLHttpRequest();
        root.xhr = x;
        let seen = 0, t0 = Date.now(), finished = false;
        let eat = function(final) {
            let t = x.responseText ?? "";
            let chunk = t.substring(seen);
            let end = final ? chunk.length : chunk.lastIndexOf("\n") + 1;
            if (end < 1) return;
            seen += end;
            for (let ln of chunk.substring(0, end).split("\n")) {
                ln = ln.trim();
                if (!ln.startsWith("data:")) continue;
                let p = ln.substring(5).trim();
                if (p === "[DONE]") continue;
                try {
                    let d = JSON.parse(p);
                    let c = d.choices && d.choices[0] && d.choices[0].delta ? d.choices[0].delta.content : "";
                    if (c) onDelta(c);
                } catch (e) {}
            }
        };
        x.onreadystatechange = function() {
            if (x !== root.xhr) return;
            if (x.readyState === 3 && x.status === 200) eat(false);
            if (x.readyState !== 4 || finished) return;
            finished = true;
            if (x.status === 200) { eat(true); onDone(Date.now() - t0); }
            else onErr(x.status === 0 ? "LLM offline — systemctl --user start npu-llm" : "LLM error " + x.status);
        };
        x.open("POST", root.llm + "/v1/chat/completions");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({ stream: true, max_tokens: maxTok, temperature: 0.3,
                                messages: [{ role: "system", content: sys }, { role: "user", content: user }] }));
    }

    function post(path, body, cb) {
        let x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return;
            let d = null;
            try { d = JSON.parse(x.responseText); } catch (e) {}
            cb(x.status, d);
        };
        x.open("POST", root.ocrd + path);
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify(body));
    }

    // ---- actions --------------------------------------------------------------------------------
    function run(i) {
        if (!root.text) return;
        root.sel = i;
        root.current = root.actions[i];
        root.out = ""; root.note = ""; root.state_ = "busy";
        root.chat(root.current.sys, root.text, 1024,
                  d => root.out += d,
                  ms => { root.out = root.out.trim(); root.state_ = "done"; root.note = (ms / 1000).toFixed(1) + " s"; root.copy(root.out, "Result"); },
                  e => { root.state_ = "error"; root.note = e; });
    }
    function backToPick() {
        if (root.xhr) { root.xhr.abort(); root.xhr = null; }
        root.state_ = "pick"; root.out = ""; root.current = null;
    }

    // ---- reader ---------------------------------------------------------------------------------
    readonly property var skipPos: ["助詞", "助動詞", "補助記号", "空白", "newline", "space", "記号", "接尾辞"]
    // auxiliary verbs after て/で (ている, てしまう…) and かもしれない are grammar, not vocabulary
    function isWord(i) {
        let t = root.tokens[i];
        if (!t || root.skipPos.indexOf(t.pos) >= 0) return false;
        let p = i > 0 ? root.tokens[i - 1] : null;
        if (p && (p.surface === "て" || p.surface === "で") && ["いる", "ある", "しまう", "おく", "くる", "いく", "みる", "あげる", "くれる", "もらう"].indexOf(t.base) >= 0) return false;
        if (p && p.surface === "も" && t.base === "しれる") return false;
        return true;
    }
    function startReader() {
        if (root.xhr) { root.xhr.abort(); root.xhr = null; }
        root.tokens = []; root.glosses = ({}); root.picked = -1; root.ankiMsg = "";
        root.translation = ""; root.grammar = "";
        if (!root.text) { root.rdState = "idle"; return; }
        root.rdState = "tr";
        root.post("/furigana", { text: root.text }, (st, d) => {
            if (st !== 200 || !d) { root.tokens = [{ surface: root.text, ruby: [[root.text, ""]], pos: "" }]; return; }
            root.tokens = d.tokens;
            for (let i = 0; i < d.tokens.length; i++) {
                let t = d.tokens[i];
                if (!root.isWord(i)) continue;
                let idx = i;
                root.post("/lookup", { forms: [t.base, t.surface, t.lemma] }, (s2, r) => {
                    if (s2 === 200 && r && r.entry) { let g = Object.assign({}, root.glosses); g[idx] = r.entry; root.glosses = g; }
                });
            }
        });
        root.chat("Translate the user's Japanese text into natural English. Output only the translation.", root.text, 600,
            d => root.translation += d,
            ms => {
                root.translation = root.translation.trim();
                root.rdState = "gr";
                root.chat("You are a Japanese teacher for an intermediate learner. Give a compact grammar breakdown of the user's Japanese text in English markdown: " +
                          "a bullet per important grammar point, conjugation or particle usage (quote the Japanese form in bold, then explain briefly). " +
                          "No translation of the whole text, no introduction. At most 8 bullets.", root.text, 700,
                    d => root.grammar += d,
                    ms2 => { root.rdState = "done"; root.note = ((ms + ms2) / 1000).toFixed(1) + " s"; },
                    e => { root.rdState = "error"; root.note = e; });
            },
            e => { root.rdState = "error"; root.note = e; });
    }
    function addAnki() {
        if (root.picked < 0) return;
        let t = root.tokens[root.picked];
        root.ankiMsg = "Adding…";
        root.post("/mine", { word: t.surface, base: t.base, sentence: root.text, translation: root.translation,
                             source: "aifeat reader", tags: ["reader", "mining"] }, (st, d) => {
            let s = d ? (d.status ?? (d.error ? "error" : "")) : "";
            root.ankiMsg = st !== 200 ? "Anki: failed" + (d && d.error ? " — " + d.error : "")
                         : s === "added" ? "Added to Anki ✓" : s === "duplicate" ? "Already in Anki"
                         : s === "queued" ? "Queued — Anki is closed" : "Anki: " + (s || "done");
        });
    }

    // =============================================================================================
    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "aipanel"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        BackgroundEffect.blurRegion: Region {
            x: Math.round(card.x); y: Math.round(card.y + card.slide)
            width: Math.round(card.width); height: Math.round(card.height)
            radius: card.radius
        }

        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                let k = event.key;
                event.accepted = true;
                if (k === Qt.Key_Escape) {
                    if (!root.reader && root.state_ !== "pick") root.backToPick(); else Qt.quit();
                } else if (k === Qt.Key_Tab) root.cycleSource();
                else if (root.reader) {
                    if (k === Qt.Key_F) root.showFurigana = !root.showFurigana;
                    else if (k === Qt.Key_C) root.copy(root.translation, "Translation");
                    else if (k === Qt.Key_A) root.addAnki();
                    else if (k === Qt.Key_Right || k === Qt.Key_Left) {
                        let n = root.tokens.length, i = root.picked, step = k === Qt.Key_Right ? 1 : -1;
                        for (let j = 0; j < n; j++) { i = (i + step + n) % n; if (root.isWord(i)) break; }
                        root.picked = i;
                    }
                } else if (root.state_ === "pick") {
                    if (k >= Qt.Key_1 && k <= Qt.Key_8) root.run(k - Qt.Key_1);
                    else if (k === Qt.Key_Down || k === Qt.Key_J) root.sel = (root.sel + 1) % root.actions.length;
                    else if (k === Qt.Key_Up || k === Qt.Key_K) root.sel = (root.sel + root.actions.length - 1) % root.actions.length;
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter) root.run(root.sel);
                } else {
                    if (k === Qt.Key_C) root.copy(root.out, "Result");
                    else if (k === Qt.Key_R) root.run(root.sel);
                    else if (k === Qt.Key_Backspace) root.backToPick();
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter) { root.copy(root.out, "Result"); Qt.quit(); }
                }
            }
        }

        Item {
            id: card
            readonly property real pad: 22
            readonly property real radius: 20
            width: Math.min(win.width - 32, root.reader ? 760 : 640)
            height: Math.min(win.height * 0.86, content.implicitHeight + 2 * pad)
            Behavior on height { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round((win.height - height) * 0.42)
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
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.reader ? "読解  Reading helper" : (root.current ? root.current.label : "AI actions")
                                color: root.cText
                                font.family: root.reader ? "Noto Sans CJK JP" : "Google Sans"
                                font.pixelSize: 16; font.weight: Font.DemiBold
                            }
                            Chip {
                                visible: root.flash !== "" || root.note !== ""
                                label: root.flash !== "" ? root.flash : root.note
                                accent: root.flash !== ""
                            }
                        }
                        Row {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            Btn {
                                visible: root.srcKey !== ""
                                label: (root.srcNames[root.srcKey] ?? "") + ((root.reader ? root.srcOrder.filter(k => root.hasJa(root.src[k])) : root.srcOrder).length > 1 ? "  ⇄" : "")
                                tip: "Tab: switch source"; small: true
                                onClicked: root.cycleSource()
                            }
                            Btn { visible: root.reader && root.tokens.length > 0; label: "あ"; on: root.showFurigana; small: true; onClicked: root.showFurigana = !root.showFurigana }
                            Btn { label: "✕"; small: true; onClicked: Qt.quit() }
                        }
                    }

                    // ---------- empty source
                    Text {
                        visible: root.loadedSrc === 3 && root.text === ""
                        width: parent.width; wrapMode: Text.Wrap
                        color: root.cSub; font.family: "Google Sans"; font.pixelSize: 15
                        text: root.reader ? "No Japanese text in the selection, the clipboard or the last OCR. Select or copy some Japanese (or use Mod+X) and try again."
                                          : "The clipboard and the selection are empty. Copy or select some text first."
                    }

                    // ---------- source preview (actions)
                    Rectangle {
                        visible: !root.reader && root.text !== ""
                        width: parent.width
                        height: prev.implicitHeight + 20
                        radius: 12
                        color: Qt.rgba(1, 1, 1, 0.06)
                        border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.06)
                        Text {
                            id: prev
                            x: 12; y: 10; width: parent.width - 24
                            text: root.text
                            maximumLineCount: root.state_ === "pick" ? 4 : 2
                            elide: Text.ElideRight; wrapMode: Text.Wrap
                            color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13
                            lineHeight: 1.1
                        }
                    }

                    // ---------- action list
                    Column {
                        visible: !root.reader && root.state_ === "pick" && root.text !== ""
                        width: parent.width
                        spacing: 2
                        Repeater {
                            model: root.actions
                            Rectangle {
                                required property var modelData
                                required property int index
                                width: parent.width; height: 40; radius: 12
                                color: index === root.sel ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.20)
                                     : (am.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent")
                                Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                Rectangle {
                                    x: 8; anchors.verticalCenter: parent.verticalCenter
                                    width: 28; height: 28; radius: 9
                                    color: Qt.rgba(1, 1, 1, index === root.sel ? 0.14 : 0.07)
                                    Text {
                                        anchors.centerIn: parent; text: modelData.icon
                                        color: index === root.sel ? root.cAccent : root.cText
                                        font.family: /[^\x00-\x7f]/.test(modelData.icon) && modelData.icon.length === 1 && modelData.icon.charCodeAt(0) > 0x3000 ? "Noto Sans CJK JP" : "Google Sans"
                                        font.pixelSize: 12; font.weight: Font.DemiBold
                                    }
                                }
                                Text {
                                    x: 48; anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.label; color: root.cText
                                    font.family: "Google Sans"; font.pixelSize: 14
                                }
                                Text {
                                    anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
                                    text: index + 1; color: root.cSub; opacity: 0.6
                                    font.family: "Google Sans"; font.pixelSize: 12
                                }
                                MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.run(index) }
                            }
                        }
                    }

                    // ---------- action result
                    Column {
                        visible: !root.reader && root.state_ !== "pick"
                        width: parent.width
                        spacing: 12
                        Dots { visible: root.state_ === "busy" && root.out === "" }
                        TextEdit {
                            visible: root.out !== "" || root.state_ === "error"
                            width: parent.width
                            readOnly: true; selectByMouse: true
                            wrapMode: Text.Wrap
                            textFormat: root.state_ === "done" && root.current && (root.current.key === "sum" || root.current.key === "explain") ? TextEdit.MarkdownText : TextEdit.PlainText
                            text: root.state_ === "error" ? root.note : root.out
                            color: root.state_ === "error" ? root.cSub : root.cText
                            selectionColor: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.4)
                            font.family: root.hasJa(root.out) ? "Noto Sans CJK JP" : "Google Sans"
                            font.pixelSize: 16
                        }
                        Row {
                            spacing: 6
                            visible: root.state_ === "done" || root.state_ === "error"
                            Btn { label: "Copy"; onClicked: root.copy(root.out, "Result"); visible: root.state_ === "done" }
                            Btn { label: "Retry"; onClicked: root.run(root.sel) }
                            Btn { label: "Back"; onClicked: root.backToPick() }
                        }
                    }

                    // ---------- reader: text with furigana
                    Flow {
                        id: flow
                        visible: root.reader && root.text !== ""
                        width: parent.width
                        Repeater {
                            model: root.tokens.length ? root.tokens : (root.reader && root.text ? [{ surface: root.text, ruby: [[root.text, ""]], pos: "" }] : [])
                            delegate: Item {
                                required property var modelData
                                required property int index
                                readonly property bool nl: modelData.pos === "newline" || modelData.surface === "\n"
                                readonly property bool word: root.tokens.length > 0 && root.isWord(index)
                                width: nl ? flow.width : tokRow.implicitWidth + 2
                                height: nl ? 2 : tokRow.implicitHeight + 4
                                Rectangle {
                                    anchors.fill: parent; radius: 6
                                    visible: !parent.nl
                                    color: root.picked === parent.index ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.24)
                                         : (tm.containsMouse && parent.word ? Qt.rgba(1, 1, 1, 0.08) : "transparent")
                                    Behavior on color { ColorAnimation { duration: 160 } }
                                }
                                Row {
                                    id: tokRow
                                    visible: !parent.nl
                                    x: 1; y: 2
                                    Repeater {
                                        model: modelData.ruby ?? [[modelData.surface, ""]]
                                        delegate: Column {
                                            required property var modelData
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                width: Math.max(1, implicitWidth); height: 15
                                                visible: root.showFurigana
                                                text: modelData[1]; color: root.cAccent; opacity: 0.9
                                                font.family: "Noto Sans CJK JP"; font.pixelSize: 11
                                            }
                                            Text {
                                                text: modelData[0]; color: root.cText
                                                font.family: "Noto Sans CJK JP"; font.pixelSize: 26
                                            }
                                        }
                                    }
                                }
                                MouseArea {
                                    id: tm; anchors.fill: parent; hoverEnabled: true
                                    enabled: parent.word
                                    cursorShape: parent.word ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: { root.picked = parent.index; root.ankiMsg = ""; }
                                }
                            }
                        }
                    }

                    // ---------- reader: picked word card
                    Rectangle {
                        id: wcard
                        readonly property var tok: root.picked >= 0 ? root.tokens[root.picked] : null
                        readonly property var ent: root.picked >= 0 ? root.glosses[root.picked] ?? null : null
                        visible: root.reader && tok !== null
                        width: parent.width
                        height: wc.implicitHeight + 24
                        radius: 14
                        color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.10)
                        border.width: 1; border.color: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.22)
                        Column {
                            id: wc
                            x: 14; y: 12; width: parent.width - 28
                            spacing: 6
                            Item {
                                width: parent.width; height: 34
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 10
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: wcard.ent ? wcard.ent.word : (wcard.tok ? wcard.tok.base : "")
                                        color: root.cText; font.family: "Noto Sans CJK JP"; font.pixelSize: 22; font.weight: Font.DemiBold
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        readonly property var e: wcard.ent
                                        text: e && e.kana.length ? "【" + e.kana[0] + "】" : ""
                                        color: root.cAccent; font.family: "Noto Sans CJK JP"; font.pixelSize: 15
                                    }
                                    Chip { anchors.verticalCenter: parent.verticalCenter; label: wcard.tok ? wcard.tok.pos : "" }
                                }
                                Row {
                                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6
                                    Chip { visible: root.ankiMsg !== ""; label: root.ankiMsg; accent: true; anchors.verticalCenter: parent.verticalCenter }
                                    Btn { label: "+ Add to Anki"; on: true; onClicked: root.addAnki() }
                                }
                            }
                            Text {
                                width: parent.width; wrapMode: Text.Wrap
                                readonly property var e: wcard.ent
                                text: e ? e.en.slice(0, 4).map((s, i) => (i + 1) + ". " + s).join("\n") : "Not in JMdict."
                                color: root.cText; font.family: "Google Sans"; font.pixelSize: 14; lineHeight: 1.15
                            }
                            Text {
                                width: parent.width; wrapMode: Text.Wrap
                                readonly property var e: wcard.ent
                                visible: e && e.ru && e.ru.length > 0
                                text: e && e.ru && e.ru.length ? e.ru[0] : ""
                                color: root.cSub; font.family: "Google Sans"; font.pixelSize: 13; maximumLineCount: 3; elide: Text.ElideRight
                            }
                        }
                    }

                    // ---------- reader: word-by-word gloss
                    SectionTitle { visible: root.reader && Object.keys(root.glosses).length > 0; label: "Words" }
                    Flow {
                        visible: root.reader && Object.keys(root.glosses).length > 0
                        width: parent.width
                        spacing: 6
                        Repeater {
                            model: Object.keys(root.glosses).map(k => parseInt(k)).sort((a, b) => a - b)
                            delegate: Rectangle {
                                required property var modelData
                                readonly property var e: root.glosses[modelData]
                                height: 28; radius: 14
                                width: Math.min(gl.implicitWidth + 20, content.width)
                                color: root.picked === modelData ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.22)
                                     : (gm.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(1, 1, 1, 0.06))
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Text {
                                    id: gl
                                    anchors.verticalCenter: parent.verticalCenter; x: 10
                                    width: Math.min(implicitWidth, content.width - 20); elide: Text.ElideRight
                                    textFormat: Text.StyledText
                                    text: "<b>" + e.word + "</b>  <font color='" + root.cSub + "'>" + (e.en[0] ?? "").split(";")[0] + "</font>"
                                    color: root.cText; font.family: "Noto Sans CJK JP"; font.pixelSize: 13
                                }
                                MouseArea { id: gm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.picked = modelData; root.ankiMsg = ""; } }
                            }
                        }
                    }

                    // ---------- reader: translation + grammar
                    SectionTitle { visible: root.reader && root.text !== ""; label: "Translation" }
                    Dots { visible: root.reader && root.rdState === "tr" && root.translation === "" }
                    TextEdit {
                        visible: root.reader && root.translation !== ""
                        width: parent.width; readOnly: true; selectByMouse: true; wrapMode: Text.Wrap
                        text: root.translation; color: root.cText
                        font.family: "Google Sans"; font.pixelSize: 16
                    }
                    SectionTitle { visible: root.reader && (root.rdState === "gr" || root.grammar !== ""); label: "Grammar" }
                    Dots { visible: root.reader && root.rdState === "gr" && root.grammar === "" }
                    TextEdit {
                        visible: root.reader && root.grammar !== ""
                        width: parent.width; readOnly: true; selectByMouse: true; wrapMode: Text.Wrap
                        textFormat: TextEdit.MarkdownText
                        text: root.grammar; color: root.cText
                        font.family: "Noto Sans CJK JP"; font.pixelSize: 14
                    }
                    Text {
                        visible: root.reader && root.rdState === "error"
                        width: parent.width; wrapMode: Text.Wrap
                        text: root.note; color: root.cSub; font.family: "Google Sans"; font.pixelSize: 14
                    }

                    // ---------- footer
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignRight
                        color: root.cSub; opacity: 0.55
                        font.family: "Google Sans"; font.pixelSize: 11
                        text: root.reader ? "Esc close · click a word · ←/→ words · A add to Anki · C copy translation · F furigana · Tab source"
                            : root.state_ === "pick" ? "1–8 or ↑↓ Enter · Tab source · Esc close"
                            : "Result is copied to the clipboard · C copy · R retry · Backspace back · Enter copy & close · Esc back"
                    }
                }
            }
        }
    }

    component Dots: Item {
        width: parent ? parent.width : 100; height: 30
        Row {
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    width: 8; height: 8; radius: 4; color: root.cAccent; opacity: 0.25
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
            font.family: /[぀-鿿]/.test(parent.label) ? "Noto Sans CJK JP" : "Google Sans"
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
        height: small ? 24 : 28
        width: Math.max(height, t.implicitWidth + (small ? 16 : 20))
        radius: height / 2
        color: on ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, ma.containsMouse ? 0.38 : 0.26)
                  : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.17) : Qt.rgba(1, 1, 1, 0.08))
        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Text {
            id: t
            anchors.centerIn: parent
            text: b.label
            color: b.on ? root.cAccent : root.cText
            font.family: /[぀-鿿]/.test(b.label) ? "Noto Sans CJK JP" : "Google Sans"
            font.pixelSize: b.small ? 11 : 12
            font.weight: Font.Medium
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }
}
