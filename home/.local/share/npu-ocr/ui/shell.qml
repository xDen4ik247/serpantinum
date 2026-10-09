// jocr result popup: standalone quickshell config, started per OCR by `jocr --region --ui`.
// State arrives through the JSON file in $JOCR_STATE (phase: capturing -> ocr -> done | error),
// written by the jocr CLI. Translation is requested here from the daemon (POST /translate, SSE).
// Liquid glass: niri blurs only the card (BackgroundEffect.blurRegion, layer namespace "jocr",
// tuned in ~/.config/niri/user/rules-ai.kdl); tint/sheen/rim come from shaders/glass.frag.
// Esc or a click outside the card closes it.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string daemon: Quickshell.env("JOCR_URL") ?? "http://127.0.0.1:8766"
    property var st: ({ phase: "capturing" })
    readonly property string phase: st.phase ?? "capturing"
    readonly property var sel: st.sel ?? ({ x: 0, y: 0, w: 0, h: 0, output: "" })
    readonly property var result: st.result ?? null
    readonly property string jpText: result ? result.text : ""
    readonly property var tokens: result && result.tokens ? result.tokens : []
    property string lang: st.lang ?? "en"
    property string translation: ""
    property string trState: "idle"      // idle | loading | done | error
    property string trNote: ""
    property bool llmOk: false
    property bool showFurigana: true
    property string flash: ""            // short confirmation text in the header
    property bool started: false
    property int selA: -1               // selected token range (Anki word)
    property int selB: -1
    property int hoverTok: -1
    property string toast: ""
    property bool toastOk: true
    property bool mining: false

    // ---- Matugen colours (same files Serpantinum's ThemeBackend reads) ----------------------
    property color cBase: "#1e1e2e"
    property color cText: "#cdd6f4"
    property color cSub: "#a6adc8"
    property color cAccent: "#89b4fa"
    property color cAccent2: "#cba6f7"
    FileView {
        path: root.home + "/.local/state/serpantinum/qs_matugen_colors.json"
        onLoaded: {
            try {
                let c = JSON.parse(text());
                c = c.colors ?? c;
                root.cBase = c.base ?? root.cBase;
                root.cText = c.text ?? root.cText;
                root.cSub = c.subtext0 ?? root.cSub;
                root.cAccent = c.blue ?? root.cAccent;
                root.cAccent2 = c.mauve ?? root.cAccent2;
            } catch (e) {}
        }
    }

    FileView {
        id: stateFile
        path: Quickshell.env("JOCR_STATE") ?? ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.st = JSON.parse(text()); } catch (e) { return; }
            if (root.phase === "done" && !root.started) {
                root.started = true;
                root.checkLlm(root.st.translate === true);
            }
        }
    }

    // fallback poll until the result is in (in case a file-change notification is missed)
    Timer {
        interval: 100
        repeat: true
        running: root.phase !== "done" && root.phase !== "error"
        onTriggered: stateFile.reload()
    }

    Process { id: copier }
    function copy(txt, what) {
        if (!txt) return;
        copier.command = ["wl-copy", "--", txt];
        copier.running = true;
        root.flash = what + " copied";
        flashTimer.restart();
    }
    Timer { id: flashTimer; interval: 1600; onTriggered: root.flash = "" }

    Timer { id: toastTimer; interval: 2600; onTriggered: root.toast = "" }
    function showToast(msg, ok) { root.toast = msg; root.toastOk = ok; toastTimer.restart(); }

    function isWord(t) {
        return t && t.pos !== "補助記号" && t.pos !== "空白" && t.pos !== "space" && t.pos !== "newline" && t.surface.trim() !== "";
    }
    // the word to mine: selection, else the token under the pointer, else the first content word
    function pickRange() {
        if (root.selA >= 0) return [root.selA, root.selB];
        if (root.hoverTok >= 0 && isWord(root.tokens[root.hoverTok])) return [root.hoverTok, root.hoverTok];
        const content = ["名詞", "動詞", "形容詞", "形状詞", "副詞"];
        let first = -1;
        for (let i = 0; i < root.tokens.length; i++) {
            const t = root.tokens[i];
            if (!isWord(t)) continue;
            if (first < 0) first = i;
            if (content.indexOf(t.pos) >= 0 && /[\u3400-\u9fff]/.test(t.surface)) return [i, i];
        }
        return first >= 0 ? [first, first] : null;
    }
    // sentence around token range: from the previous 。！？/newline to the next one
    function sentenceAround(a, b) {
        const stop = t => t.pos === "newline" || /[。！？!?]$/.test(t.surface);
        let i = a, j = b;
        while (i > 0 && !stop(root.tokens[i - 1])) i--;
        while (j < root.tokens.length - 1 && !stop(root.tokens[j]) ) j++;
        let s = "";
        for (let k = i; k <= j; k++) if (root.tokens[k].pos !== "newline") s += root.tokens[k].surface;
        return s.trim();
    }
    function addToAnki() {
        if (root.mining || root.tokens.length === 0) return;
        const r = pickRange();
        if (!r) return;
        root.selA = r[0]; root.selB = r[1];
        let word = "";
        for (let k = r[0]; k <= r[1]; k++) word += root.tokens[k].surface;
        const sentence = sentenceAround(r[0], r[1]);
        const sameText = sentence.replace(/\s/g, "") === root.jpText.replace(/\s/g, "");
        const body = {
            word: word.trim(),
            base: r[0] === r[1] ? root.tokens[r[0]].base : "",
            sentence: sentence,
            translation: (root.trState === "done" && sameText) ? root.translation : "",
            lang: root.lang,
            picture: root.result && root.result.image_path ? root.result.image_path : "",
            source: root.st.source ?? "jocr",
        };
        const deck = Quickshell.env("JOCR_ANKI_DECK");
        if (deck) body.deck = deck;
        root.mining = true;
        root.showToast("Adding " + body.word + " to Anki…", true);
        let x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return;
            root.mining = false;
            let d = {};
            try { d = JSON.parse(x.responseText); } catch (e) {}
            const w = d.expression ?? body.word;
            if (d.status === "added") root.showToast("Added ✓  " + w, true);
            else if (d.status === "queued") root.showToast("Queued " + w + " (Anki closed)", true);
            else if (d.status === "duplicate") root.showToast("Duplicate: " + w + " is already in Anki", false);
            else root.showToast("Anki error: " + (d.message ?? d.error ?? x.status), false);
        };
        x.open("POST", root.daemon + "/mine");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify(body));
    }

    function checkLlm(thenTranslate) {
        let x = new XMLHttpRequest();
        x.onreadystatechange = function() {
            if (x.readyState !== 4) return;
            try { root.llmOk = x.status === 200 && JSON.parse(x.responseText).ok === true; } catch (e) { root.llmOk = false; }
            if (thenTranslate) root.translate();
        };
        x.open("GET", root.daemon + "/llm");
        x.send();
    }

    function translate() {
        if (!root.jpText) return;
        if (!root.llmOk) {
            root.trState = "error";
            root.trNote = "Translator offline — start npu-llm.service (127.0.0.1:8765)";
            return;
        }
        root.trState = "loading";
        root.translation = "";
        root.trNote = "";
        let x = new XMLHttpRequest();
        let seen = 0;
        let eat = function(final) {
            let t = x.responseText ?? "";
            let chunk = t.substring(seen);
            let end = final ? chunk.length : chunk.lastIndexOf("\n\n") + 2;
            if (end < 2) return;
            seen += end;
            for (let ev of chunk.substring(0, end).split("\n\n")) {
                if (!ev.startsWith("data: ")) continue;
                try {
                    let d = JSON.parse(ev.substring(6));
                    if (d.delta) root.translation += d.delta;
                    if (d.done) {
                        root.translation = d.translation;
                        root.trState = "done";
                        root.trNote = (d.model ? d.model.replace(/\.gguf$/, "") + " · " : "") + d.ms + " ms";
                    }
                } catch (e) {}
            }
        };
        x.onreadystatechange = function() {
            if (x.readyState === 3 && x.status === 200) eat(false);
            if (x.readyState !== 4) return;
            if (x.status === 200) {
                eat(true);
                if (root.trState === "loading") root.trState = "done";
            } else {
                root.trState = "error";
                root.trNote = x.status === 503 ? "Translator offline — start npu-llm.service" : "Translation failed (" + x.status + ")";
            }
        };
        x.open("POST", root.daemon + "/translate");
        x.setRequestHeader("Content-Type", "application/json");
        x.send(JSON.stringify({ text: root.jpText, lang: root.lang, stream: true }));
    }

    PanelWindow {
        id: win
        screen: Quickshell.screens.find(s => s.name === root.sel.output) ?? Quickshell.screens[0]
        visible: root.phase !== "capturing"
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "jocr"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        BackgroundEffect.blurRegion: Region {
            Region {
                x: Math.round(card.x)
                y: Math.round(card.y + card.slide)
                width: Math.round(card.width)
                height: Math.round(card.height)
                radius: card.radius
            }
            Region {
                x: Math.round(toastPill.x)
                y: Math.round(toastPill.y)
                width: toastPill.opacity > 0.01 ? Math.round(toastPill.width) : 0
                height: toastPill.opacity > 0.01 ? Math.round(toastPill.height) : 0
                radius: toastPill.height / 2
            }
        }

        // click-away
        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) Qt.quit();
                else if (event.key === Qt.Key_C) root.copy(event.modifiers & Qt.ShiftModifier ? root.translation : root.jpText, event.modifiers & Qt.ShiftModifier ? "Translation" : "Text");
                else if (event.key === Qt.Key_T) root.translate();
                else if (event.key === Qt.Key_A) root.addToAnki();
                else if (event.key === Qt.Key_F) root.showFurigana = !root.showFurigana;
                else if (event.key === Qt.Key_L) { root.lang = root.lang === "en" ? "ru" : "en"; if (root.trState !== "idle") root.translate(); }
                event.accepted = true;
            }
        }

        Rectangle {
            id: toastPill
            z: 10
            readonly property bool below: card.y + card.height + 12 + height <= win.height - 8
            x: Math.round(card.x + card.width / 2 - width / 2)
            y: Math.round(below ? card.y + card.height + 12 : card.y - height - 12)
            width: toastText.implicitWidth + 36
            height: 38
            radius: 19
            color: Qt.rgba(root.cBase.r, root.cBase.g, root.cBase.b, 0.62)
            border.width: 1
            border.color: root.toastOk ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.55) : Qt.rgba(1, 0.6, 0.55, 0.5)
            opacity: root.toast !== "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Text {
                id: toastText
                anchors.centerIn: parent
                text: root.toast
                color: root.toastOk ? root.cText : "#ffb4ab"
                font.family: "Noto Sans CJK JP"
                font.pixelSize: 14
                font.weight: Font.Medium
            }
        }

        Item {
            id: card
            readonly property real pad: 20
            readonly property real radius: 20
            readonly property real gap: 14
            readonly property real maxW: Math.min(660, win.width - 32)
            property real slide: appear.running || opacity < 1 ? (1 - opacity) * 10 : 0
            // natural width: ~one 26 px glyph per character, between 460 and 660 px
            width: Math.min(maxW, Math.max(460, Math.min(root.jpText.length, 22) * 27 + 2 * pad + 8))
            height: Math.min(win.height - 32, content.implicitHeight + 2 * pad)
            Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

            readonly property real below: root.sel.y + root.sel.h + gap
            readonly property real above: root.sel.y - gap - height
            x: Math.max(16, Math.min(win.width - width - 16, root.sel.x + root.sel.w / 2 - width / 2))
            y: below + height <= win.height - 16 ? below
               : (above >= 16 ? above : Math.max(16, Math.min(win.height - height - 16, root.sel.y + root.sel.h - height)))
            transform: Translate { y: card.slide }

            opacity: 0
            NumberAnimation on opacity { id: appear; running: win.visible; from: 0; to: 1; duration: 380; easing.type: Easing.OutCubic }

            MouseArea { anchors.fill: parent }   // clicks inside don't close

            RectangularShadow {
                anchors.fill: parent
                radius: card.radius
                offset.y: 6
                blur: 30
                spread: 0
                color: Qt.rgba(0, 0, 0, 0.40)
                cached: true
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

            Column {
                id: content
                x: card.pad
                y: card.pad
                width: card.width - 2 * card.pad
                spacing: 12

                // header: title, status chip, actions
                Item {
                    width: parent.width
                    height: 30
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10
                        Text {
                            text: "読み取り"
                            color: root.cText
                            font.family: "Noto Sans CJK JP"
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Chip {
                            visible: root.phase === "done" && root.result
                            label: root.flash !== "" ? root.flash
                                 : (root.result ? root.result.device + " · " + Math.round(root.result.timings.total_ms) + " ms" : "")
                            accent: root.flash !== ""
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Btn { label: "あ"; tip: "furigana (F)"; on: root.showFurigana; visible: root.tokens.length > 0; onClicked: root.showFurigana = !root.showFurigana }
                        Btn { label: "Copy"; tip: "copy text (C)"; visible: root.jpText !== ""; onClicked: root.copy(root.jpText, "Text") }
                        Btn { label: "+ Anki"; tip: "add the selected word (A)"; visible: root.tokens.length > 0; on: root.selA >= 0; onClicked: root.addToAnki() }
                        Btn { label: "Translate"; tip: "translate (T)"; visible: root.jpText !== "" && root.trState === "idle"; onClicked: root.translate() }
                        Btn { label: "✕"; tip: "close (Esc)"; onClicked: Qt.quit() }
                    }
                }

                // reading state
                Item {
                    visible: root.phase === "ocr" || root.phase === "capturing"
                    width: parent.width
                    height: 54
                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Repeater {
                            model: 3
                            Rectangle {
                                width: 9; height: 9; radius: 4.5
                                color: root.cAccent
                                opacity: 0.25
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

                Text {
                    visible: root.phase === "error" || (root.phase === "done" && root.jpText === "")
                    width: parent.width
                    wrapMode: Text.Wrap
                    color: root.cSub
                    font.family: "Google Sans"
                    font.pixelSize: 15
                    text: root.phase === "error" ? ("OCR failed: " + (root.st.error ?? "")) : "No Japanese text found in the selection."
                }

                // Japanese text with furigana (token flow; wraps between words)
                Flickable {
                    visible: root.phase === "done" && root.jpText !== ""
                    width: parent.width
                    height: Math.min(flow.implicitHeight, win.height * 0.55)
                    contentHeight: flow.implicitHeight
                    clip: flow.implicitHeight > height
                    interactive: flow.implicitHeight > height
                    Flow {
                        id: flow
                        width: parent.width
                        spacing: 0
                        Repeater {
                            model: root.tokens.length > 0 ? root.tokens : [{ surface: root.jpText, ruby: [[root.jpText, ""]] }]
                            delegate: Loader {
                                required property var modelData
                                required property int index
                                sourceComponent: modelData.surface === "\n" ? breakComp : tokenComp
                                property var tok: modelData
                                property int ti: index
                            }
                        }
                    }
                }

                // translation
                Rectangle {
                    visible: root.trState !== "idle"
                    width: parent.width
                    height: 1
                    color: Qt.rgba(1, 1, 1, 0.10)
                }
                Column {
                    visible: root.trState !== "idle"
                    width: parent.width
                    spacing: 6
                    Text {
                        width: parent.width
                        wrapMode: Text.Wrap
                        color: root.trState === "error" ? root.cSub : root.cText
                        font.family: "Google Sans"
                        font.pixelSize: 17
                        lineHeight: 1.15
                        text: root.trState === "error" ? root.trNote
                            : (root.translation !== "" ? root.translation : "Translating…")
                        opacity: root.translation === "" && root.trState === "loading" ? 0.6 : 1
                    }
                    Row {
                        spacing: 6
                        visible: root.trState === "done"
                        Chip { label: root.lang.toUpperCase() + (root.trNote ? " · " + root.trNote : "") }
                        Btn { label: "Copy"; small: true; onClicked: root.copy(root.translation, "Translation") }
                        Btn {
                            label: root.lang === "en" ? "→ RU" : "→ EN"
                            small: true
                            onClicked: { root.lang = root.lang === "en" ? "ru" : "en"; root.translate(); }
                        }
                    }
                }

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    color: root.cSub
                    opacity: 0.55
                    font.family: "Google Sans"
                    font.pixelSize: 11
                    text: "click a word (Shift+click extends) · A add to Anki · C copy · T translate · F furigana · L language · Esc"
                }
            }
        }
    }

    Component {
        id: breakComp
        Item { width: flow.width; height: 2 }
    }
    Component {
        id: tokenComp
        Item {
            id: tk
            readonly property var ld: parent
            readonly property int ti: ld ? ld.ti : -1
            readonly property bool picked: ti >= root.selA && ti <= root.selB && root.selA >= 0
            readonly property bool word: ld ? root.isWord(ld.tok) && root.tokens.length > 0 : false
            implicitWidth: row.implicitWidth
            implicitHeight: row.implicitHeight
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: root.showFurigana && root.tokens.length > 0 ? 14 : 0
                anchors.bottomMargin: -1
                radius: 7
                color: tk.picked ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.30)
                     : (root.hoverTok === tk.ti && tk.word ? Qt.rgba(1, 1, 1, 0.10) : "transparent")
                Behavior on color { ColorAnimation { duration: 160 } }
            }
            Row {
                id: row
                Repeater {
                    model: tk.ld ? tk.ld.tok.ruby : []
                    delegate: Column {
                        required property var modelData
                        Text {
                            visible: root.showFurigana && root.tokens.length > 0
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.max(1, implicitWidth)   // positioners skip zero-width items
                            height: 15
                            text: modelData[1]
                            color: root.cAccent
                            opacity: 0.9
                            font.family: "Noto Sans CJK JP"
                            font.pixelSize: 11
                        }
                        Text {
                            text: modelData[0]
                            color: root.cText
                            font.family: "Noto Sans CJK JP"
                            font.pixelSize: 26
                        }
                    }
                }
            }
            MouseArea {
                anchors.fill: parent
                enabled: tk.word
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.hoverTok = tk.ti
                onExited: if (root.hoverTok === tk.ti) root.hoverTok = -1
                onClicked: mouse => {
                    if ((mouse.modifiers & Qt.ShiftModifier) && root.selA >= 0) {
                        root.selA = Math.min(root.selA, tk.ti);
                        root.selB = Math.max(root.selB, tk.ti);
                    } else if (tk.picked && root.selA === root.selB) {
                        root.selA = root.selB = -1;
                    } else {
                        root.selA = root.selB = tk.ti;
                    }
                }
            }
        }
    }

    component Chip: Rectangle {
        property string label: ""
        property bool accent: false
        height: 22
        width: chipText.implicitWidth + 16
        radius: 11
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
        height: small ? 24 : 28
        width: Math.max(height, t.implicitWidth + (small ? 16 : 20))
        radius: height / 2
        color: on ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.28)
                  : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.17) : Qt.rgba(1, 1, 1, 0.08))
        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Text {
            id: t
            anchors.centerIn: parent
            text: b.label
            color: b.on ? root.cAccent : root.cText
            font.family: b.label === "あ" ? "Noto Sans CJK JP" : "Google Sans"
            font.pixelSize: b.small ? 11 : 12
            font.weight: Font.Medium
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }
}
