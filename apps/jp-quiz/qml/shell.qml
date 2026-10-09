// JP Quiz — endless adaptive Japanese quiz (quickshell window + Python engine).
// Run: quickshell -p <this dir>   (the jp-quiz launcher does this)
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
    id: shell

    // ------------------------------------------------------------------ theme
    QtObject {
        id: theme
        property color base: "#0d0e13"
        property color mantle: "#1b1b21"
        property color crust: "#121318"
        property color text: "#e3e1e9"
        property color subtext0: "#c6c5d0"
        property color subtext1: "#90909a"
        property color surface0: "#1f1f25"
        property color surface1: "#292a2f"
        property color surface2: "#34343a"
        property color accent: "#b9c3ff"      // Matugen primary ("blue")
        property color accent2: "#e5bad8"     // Matugen tertiary ("peach")
        property color deep: "#384379"        // Matugen primary container ("sapphire")
        property color bad: "#ffb4ab"
        property color good: Qt.hsla(0.40, 0.55, 0.72, 1)
        property color gold: Qt.hsla(0.12, 0.85, 0.70, 1)
        property string font: "Google Sans"
        property string jp: "Noto Sans CJK JP"
        property string icons: iconFont.status === FontLoader.Ready ? iconFont.name : font
        property int radius: 20
        function mix(a, b, t) { return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t) }
        function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    }

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
                set("subtext0", c.subtext0); set("subtext1", c.subtext1); set("surface0", c.surface0);
                set("surface1", c.surface1); set("surface2", c.surface2); set("accent", c.blue);
                set("accent2", c.peach); set("deep", c.sapphire); set("bad", c.red);
            } catch (e) {}
        }
    }

    // ------------------------------------------------------------------ backend
    property string appDir: Quickshell.env("JPQUIZ_APP") || (Quickshell.shellDir + "/..")

    Process {
        id: engine
        command: [Quickshell.env("JPQUIZ_PYTHON") || "python3", "-m", "jpquiz.server"]
        workingDirectory: shell.appDir
        environment: ({ "PYTHONPATH": shell.appDir, "PYTHONUNBUFFERED": "1" })
        stdinEnabled: true
        running: true
        stdout: SplitParser {
            onRead: data => app.receive(data)
        }
        stderr: SplitParser {
            onRead: data => console.warn("engine:", data)
        }
        onExited: (code, status) => { if (!app.closing) app.fatal = "The quiz engine stopped (exit " + code + ")." }
        onStarted: app.send({ cmd: "hello" })
    }

    function play(name) {
        if (!app.settings.sound) return;
        Quickshell.execDetached(["pw-play", "--volume", "0.45", shell.appDir + "/assets/" + name + ".wav"]);
    }

    // ------------------------------------------------------------------ app state
    QtObject {
        id: app
        property string state: "loading"      // loading welcome question waiting feedback intro stats
        property string prevState: "question"
        property var hello: ({})
        property var settings: ({ lang: "en", furigana: false, sound: true, auto_advance: true, target: 0.75, daily_goal: 30 })
        property var q: null
        property var res: null
        property var card: null               // intro / placement card
        property var stats: null
        property var pending: []               // cards to show after feedback (placement result)
        property int rating: 0
        property int ratingDelta: 0
        property var level: ({ level: 1, into: 0, need: 100, xp: 0 })
        property var today: ({ n: 0, goal: 30, streak_days: 0 })
        property int streak: 0
        property real combo: 1
        property string rank: ""
        property int chosen: -1
        property double shownAt: 0
        property bool closing: false
        property string fatal: ""
        property int rid: 0
        property var orderPicked: []
        property string peekMode: "right"

        function send(obj) {
            rid += 1;
            obj.rid = rid;
            engine.write(JSON.stringify(obj) + "\n");
        }
        function ru() { return settings.lang === "ru" }
        function tr(pair) { return pair ? (ru() && pair[1] ? pair[1] : pair[0]) : "" }

        function receive(line) {
            let m;
            try { m = JSON.parse(line); } catch (e) { console.warn("bad line", line); return; }
            if (m.type === "hello") {
                hello = m; settings = m.settings; rating = m.rating; rank = m.rank;
                level = m.level_progress; today = m.today; streak = m.streak;
                state = m.placement ? "welcome" : "loading";
                if (!m.placement) next();
            } else if (m.type === "question") {
                q = m; res = null; chosen = -1; orderPicked = [];
                shownAt = Date.now();
                state = "question";
            } else if (m.type === "intro") {
                card = m; state = "intro";
            } else if (m.type === "result") {
                res = m;
                ratingDelta = m.rating.after - rating;
                rating = m.rating.after;
                level = m.level_progress; today = m.today; streak = m.streak; combo = m.combo;
                state = "feedback";
                shell.play(m.correct ? "correct" : "wrong");
                const bands = [];
                for (const ev of m.events) {
                    if (ev.type === "placement") { pending.push(ev); rank = ev.rank; }
                    else if (ev.type === "rank") { rank = ev.rank; toasts.show("trophy", ru() ? "Новый ранг: " + ev.rank : "Rank up: " + ev.rank, theme.gold); shell.play("levelup"); }
                    else if (ev.type === "levelup") { toasts.show("star", (ru() ? "Уровень " : "Level ") + ev.level + "!", theme.gold); shell.play("levelup"); }
                    else if (ev.type === "unlock" && ev.what === "band") bands.push(ev);
                    else if (ev.type === "anki") ankiToast(ev);
                    else if (ev.type === "unlock" && ev.what === "grammar" && !ev.bulk) toasts.show("book", (ru() ? "Новая грамматика: " : "New grammar: ") + ev.items.map(i => i.name).join(", "), theme.accent2);
                }
                if (bands.length) {
                    const lv = Math.min(...bands.map(b => b.level));
                    toasts.show("unlock", (ru() ? "Открыто N" : "Unlocked N") + lv + ": " + bands.filter(b => b.level === lv).map(b => tr(b.cat_name)).join(", "), theme.accent);
                }
                if (m.correct && settings.auto_advance && pending.length === 0) advanceTimer.restart();
            } else if (m.type === "stats") {
                stats = m; prevState = (state === "stats") ? prevState : state; state = "stats";
            } else if (m.type === "peek") {
                const right = peekMode === "right";
                if (m.order && q) { orderPicked = (right ? m.correct : m.correct.slice().reverse()).map(t => q.ui.tiles.indexOf(t)); submitOrder(); }
                else if (m.correct !== null) answer(right ? m.correct : (m.correct + 1) % q.ui.choices.length);
            } else if (m.type === "anki") {
                ankiToast(m);
            } else if (m.type === "anki_sync") {
                toasts.show(m.ok ? "cards" : "warn", (ru() ? "Anki: " : "Anki: ") + m.message, m.ok ? theme.good : theme.gold);
                if (m.ok) send({ cmd: "stats" });
            } else if (m.type === "settings") {
                settings = m.settings;
            } else if (m.type === "error") {
                console.warn("engine error:", m.error, m.trace || "");
                if (state === "waiting") next();
            }
        }

        function ankiToast(m) {
            const w = m.word ? "「" + m.word + "」 " : "";
            if (m.status === "duplicate")
                toasts.show("cards", (ru() ? "Уже в Anki: " : "Already in Anki: ") + w, theme.accent);
            else if (m.status === "sent" || m.status === "partial")
                toasts.show("cards", (m.auto ? (ru() ? "Авто → Anki: " : "Auto → Anki: ") : (ru() ? "В Anki: " : "Added to Anki: ")) + w + "(Japanese::Quiz)", theme.good);
            else if (m.status === "queued")
                toasts.show("cards", (ru() ? "В очереди для Anki: " : "Queued for Anki: ") + w, theme.accent);
            else toasts.show("warn", "Anki: " + (m.message || m.status), theme.gold);
        }
        function next() {
            advanceTimer.stop();
            if (pending.length > 0) {
                const ev = pending.shift();
                card = ev; state = "intro";
                return;
            }
            state = "loading";
            send({ cmd: "next" });
        }
        function answer(i) {
            if (state !== "question" || !q) return;
            chosen = i;
            state = "waiting";
            send({ cmd: "answer", qid: q.qid, choice: i, ms: Date.now() - shownAt });
        }
        function submitOrder() {
            if (state !== "question" || !q) return;
            state = "waiting";
            send({ cmd: "answer", qid: q.qid, order: orderPicked.map(i => q.ui.tiles[i]), ms: Date.now() - shownAt });
        }
        function skip() {
            if (state !== "question" || !q) return;
            chosen = -1;
            state = "waiting";
            send({ cmd: "skip", qid: q.qid, ms: Date.now() - shownAt });
        }
        function pickTile(i) {
            if (state !== "question" || !q || q.kind !== "order") return;
            if (i < 0 || i >= q.ui.tiles.length || orderPicked.indexOf(i) >= 0) return;
            orderPicked = orderPicked.concat([i]);
            if (orderPicked.length === q.ui.tiles.length) orderSubmit.restart();
        }
        function undoTile() {
            if (orderPicked.length) orderPicked = orderPicked.slice(0, -1);
        }
        function openStats() {
            if (state === "stats") { closeStats(); return; }
            advanceTimer.stop();
            send({ cmd: "stats" });
        }
        function closeStats() {
            state = prevState === "stats" ? "question" : prevState;
            if (state === "loading" || state === "waiting" || !q) next();
        }
        function setSetting(k, v) {
            const s = {}; s[k] = v;
            send({ cmd: "settings", set: s });
        }
        function close() {
            closing = true;
            send({ cmd: "quit" });
            Qt.callLater(Qt.quit);
        }
    }

    Timer { id: advanceTimer; interval: 1250; onTriggered: if (app.state === "feedback") app.next() }
    Timer { id: orderSubmit; interval: 260; onTriggered: app.submitOrder() }

    // ------------------------------------------------------------------ window
    FloatingWindow {
        id: win
        title: Quickshell.env("JPQUIZ_TITLE") || "JP Quiz"
        implicitWidth: 1060
        implicitHeight: 740
        minimumSize: Qt.size(560, 480)
        color: "transparent"
        onClosed: app.close()

        Rectangle {
            id: bg
            anchors.fill: parent
            radius: theme.radius
            color: theme.alpha(theme.base, 0.58)
            gradient: Gradient {
                GradientStop { position: 0.0; color: theme.alpha(theme.mix(theme.base, theme.deep, 0.35), 0.62) }
                GradientStop { position: 1.0; color: theme.alpha(theme.base, 0.66) }
            }
        }

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                const k = event.key;
                const st = app.state;
                if (k === Qt.Key_Escape) {
                    // a normal app window now: Esc only leaves stats; close with Mod+Q like any window
                    if (st === "stats") app.closeStats();
                    event.accepted = true; return;
                }
                if (k === Qt.Key_Tab) { app.openStats(); event.accepted = true; return; }
                if (st === "stats") {
                    if (k === Qt.Key_Left) app.setSetting("target", Math.round((app.settings.target - 0.05) * 100) / 100);
                    else if (k === Qt.Key_Right) app.setSetting("target", Math.round((app.settings.target + 0.05) * 100) / 100);
                    else if (k === Qt.Key_L) app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru");
                    else if (k === Qt.Key_F) app.setSetting("furigana", !app.settings.furigana);
                    else if (k === Qt.Key_M) app.setSetting("sound", !app.settings.sound);
                    else if (k === Qt.Key_A) app.setSetting("auto_advance", !app.settings.auto_advance);
                    else if (k === Qt.Key_S) app.send({ cmd: "anki_sync" });
                    else if (k === Qt.Key_K) app.setSetting("anki_auto", !app.settings.anki_auto);
                    event.accepted = true; return;
                }
                if (k === Qt.Key_F && st !== "welcome") { app.setSetting("furigana", !app.settings.furigana); event.accepted = true; return; }
                if (k === Qt.Key_L) { app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru"); event.accepted = true; return; }
                if (st === "welcome" || st === "intro") {
                    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) app.next();
                    event.accepted = true; return;
                }
                if (st === "feedback") {
                    if (k === Qt.Key_A) { advanceTimer.stop(); app.send({ cmd: "anki_add" }); }
                    else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space || k === Qt.Key_Right) app.next();
                    event.accepted = true; return;
                }
                if (st === "question" && app.q) {
                    const n = k - Qt.Key_1;
                    if (app.q.kind === "order") {
                        if (n >= 0 && n < 9) app.pickTile(n);
                        else if (k === Qt.Key_Backspace) app.undoTile();
                        else if (k === Qt.Key_Space) app.skip();
                        else if ((k === Qt.Key_Return || k === Qt.Key_Enter) && app.orderPicked.length === app.q.ui.tiles.length) app.submitOrder();
                    } else {
                        if (n >= 0 && n < app.q.ui.choices.length) app.answer(n);
                        else if (k === Qt.Key_Space) app.skip();
                    }
                    event.accepted = true;
                }
            }
        }

        Hud {
            id: hud
            theme: theme
            app: app
            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 18 }
            height: 50
        }

        Quiz {
            id: quiz
            theme: theme
            app: app
            shell: shell
            // full-screen tiling: keep the question readable instead of stretching answers edge to edge
            anchors { top: hud.bottom; bottom: footer.top; horizontalCenter: parent.horizontalCenter; margins: 18; topMargin: 14 }
            width: Math.min(parent.width - 36, 1240)
            visible: opacity > 0
            opacity: (app.state === "question" || app.state === "waiting" || app.state === "feedback") ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }

        Cards {
            theme: theme
            app: app
            anchors { top: hud.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 14 }
            visible: opacity > 0
            opacity: (app.state === "welcome" || app.state === "intro" || app.state === "loading") ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }

        Stats {
            theme: theme
            app: app
            anchors { top: hud.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 14 }
            visible: opacity > 0
            opacity: app.state === "stats" ? 1 : 0
            scale: app.state === "stats" ? 1 : 0.985
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
        }

        Text {
            id: footer
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 14 }
            color: theme.alpha(theme.subtext1, 0.9)
            font.family: theme.font
            font.pixelSize: 13
            text: {
                const ru = app.ru();
                if (app.state === "stats") return ru ? "Tab/Esc назад · ←→ цель · L язык · F фуригана · M звук · A автопереход · S синхр. с Anki · K авто-Anki" : "Tab/Esc back · ←→ target · L language · F furigana · M sound · A auto-advance · S sync with Anki · K auto-add to Anki";
                if (app.state === "feedback") return ru ? "Enter — дальше · A в Anki · Tab статистика" : "Enter next · A add to Anki · Tab stats";
                if (app.q && app.q.kind === "order" && app.state === "question") return ru ? "Цифры — по порядку · Backspace отмена · Space пропуск" : "Press the numbers in order · Backspace undo · Space skip";
                return ru ? "1–4 ответ · Space пропуск · F фуригана · L язык · Tab статистика" : "1–4 answer · Space skip · F furigana · L language · Tab stats";
            }
        }

        Toasts {
            id: toasts
            theme: theme
            anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 21 }
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

    // test hook: drive the window without keyboard focus (used for screenshots)
    IpcHandler {
        target: "jpquiz"
        function key(name: string): void {
            if (name === "stats") app.openStats();
            else if (name === "next") app.next();
            else if (name === "skip") app.skip();
            else if (name === "back") app.closeStats();
            else if (name === "anki") app.send({ cmd: "anki_add" });
            else if (name === "sync") app.send({ cmd: "anki_sync" });
            else if (/^[1-9]$/.test(name)) { if (app.q && app.q.kind === "order") app.pickTile(parseInt(name) - 1); else app.answer(parseInt(name) - 1); }
        }
        function quit(): void { app.close() }
        function cheat(): void { app.peekMode = "right"; app.send({ cmd: "peek" }) }
        function miss(): void { app.peekMode = "wrong"; app.send({ cmd: "peek" }) }
        function state(): string { return app.state + (app.q ? " " + app.q.kind : "") }
    }
}
