// JP Quiz — endless adaptive Japanese quiz (quickshell window + Rust engine).
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
        // the Rust engine (bin/jp-quiz-engine, built by install.sh), JSON lines over stdin/stdout
        command: [shell.appDir + "/bin/jp-quiz-engine"]
        workingDirectory: shell.appDir
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
        property string state: "loading"      // loading welcome question waiting feedback intro | views: stats rank details grammar| views: stats details grammar
        property string prevState: "question"
        property var hello: ({})
        property var settings: ({ lang: "en", furigana: false, sound: true, auto_advance: true, target: 0.75, daily_goal: 30, anki_reviews: false })
        property var q: null
        property var res: null
        property var card: null               // intro / placement card
        property var stats: null
        property var grammar: null             // grammar tab: {points, focus}
        property int grammarSel: 0
        property var grammarEx: null
        property var rankData: null            // rank tab: tiers, what is left, study plan
        property string rankPane: "words"      // words | kanji | grammar
        property var rankBrief: null           // HUD: last tier reached, next one, progress
        property var calibQ: null              // placement test: current question
        property var calibDone: null           // placement test: result
        readonly property var views: ["stats", "rank", "details", "grammar"]
        function inView() { return views.indexOf(state) >= 0 || state === "calib" }
        // question clock: pauses while a view (stats/grammar) is open, so looking things up costs no time
        property double qElapsed: 0
        property bool qRunning: false
        function elapsed() { return qElapsed + (qRunning ? Date.now() - shownAt : 0) }
        function pauseClock() { if (qRunning) { qElapsed += Date.now() - shownAt; qRunning = false; } }
        function resumeClock() { if (!qRunning && state === "question") { shownAt = Date.now(); qRunning = true; } }
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
        property var lastRes: null
        property string wantView: ""
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
                hello = m; settings = m.settings; rating = m.rating; rank = m.rank; rankBrief = m.rank_brief;
                level = m.level_progress; today = m.today; streak = m.streak;
                state = m.placement ? "welcome" : "loading";
                if (!m.placement) next();
            } else if (m.type === "question") {
                q = m; res = null; chosen = -1; orderPicked = [];
                qElapsed = 0; shownAt = Date.now(); qRunning = true;
                state = "question";
            } else if (m.type === "intro") {
                card = m; state = "intro";
            } else if (m.type === "result") {
                res = m;
                ratingDelta = m.rating.after - rating;
                rating = m.rating.after;
                level = m.level_progress; today = m.today; streak = m.streak; combo = m.combo;
                if (m.rank_brief) rankBrief = m.rank_brief;
                state = "feedback";
                shell.play(m.correct ? "correct" : "wrong");
                const bands = [];
                for (const ev of m.events) {
                    if (ev.type === "placement") { pending.push(ev); rank = ev.rank; }
                    else if (ev.type === "rank") rank = ev.rank;    // rating band: not shown any more (the Rank tier is)
                    else if (ev.type === "levelup") { toasts.show("star", (ru() ? "Уровень " : "Level ") + ev.level + "!", theme.gold); shell.play("levelup"); }
                    else if (ev.type === "tier") tierToast(ev);
                    else if (ev.type === "unlock" && ev.what === "band") bands.push(ev);
                    else if (ev.type === "anki") ankiToast(ev);
                    else if (ev.type === "anki_review" && ev.status === "offline")
                        toasts.show("warn", (ru() ? "Anki закрыт — повторы на паузе" : "Anki is closed — reviews paused") +
                                    (ev.pending ? " · " + ev.pending + (ru() ? " ждут отправки" : " waiting to sync") : ""), theme.gold);
                    else if (ev.type === "unlock" && ev.what === "grammar" && !ev.bulk) toasts.show("book", (ru() ? "Новая грамматика: " : "New grammar: ") + ev.items.map(i => i.name).join(", "), theme.accent2);
                }
                if (bands.length) {
                    const lv = Math.min(...bands.map(b => b.level));
                    toasts.show("unlock", (ru() ? "Открыто N" : "Unlocked N") + lv + ": " + bands.filter(b => b.level === lv).map(b => tr(b.cat_name)).join(", "), theme.accent);
                }
                if (m.correct && settings.auto_advance && pending.length === 0) advanceTimer.restart();
                // keep the last answer reachable for "add to Anki" during the next question (an Anki review already is)
                lastRes = m.anki ? null : m;
            } else if (m.type === "stats") {
                stats = m;
                if (wantView === "stats" || wantView === "details") enterView(wantView);
            } else if (m.type === "grammar") {
                grammar = m;
                if (grammarSel >= m.points.length) grammarSel = 0;
                if (wantView === "grammar") enterView("grammar");
                if (m.points.length) send({ cmd: "grammar_example", id: m.points[grammarSel].id });
            } else if (m.type === "rank") {
                rankData = m;
                if (wantView === "rank") enterView("rank");
            } else if (m.type === "calib_q") {
                calibQ = m; calibDone = null; shownAt = Date.now();
                if (state !== "calib") { if (!inView()) { prevState = state; pauseClock(); } state = "calib"; }
            } else if (m.type === "calib_done") {
                calibDone = m; calibQ = null;
                if (m.rank) rankBrief = m.rank;
                send({ cmd: "rank" });
            } else if (m.type === "grammar_example") {
                grammarEx = m;
            } else if (m.type === "peek") {
                const right = peekMode === "right";
                if (m.order && q) { orderPicked = (right ? m.correct : m.correct.slice().reverse()).map(t => q.ui.tiles.indexOf(t)); submitOrder(); }
                else if (m.correct !== null) answer(right ? m.correct : (m.correct + 1) % q.ui.choices.length);
            } else if (m.type === "anki") {
                ankiToast(m);
                if (res && m.key === res.key && (m.status === "sent" || m.status === "queued" || m.status === "duplicate" || m.status === "partial"))
                    res = Object.assign({}, res, { in_anki: true });
                if (state === "details" && stats) send({ cmd: "stats" });
            } else if (m.type === "anki_sync") {
                toasts.show(m.ok ? "cards" : "warn", (ru() ? "Anki: " : "Anki: ") + m.message, m.ok ? theme.good : theme.gold);
                if (m.ok) send({ cmd: "stats" });
            } else if (m.type === "settings") {
                if (!!m.settings.anki_reviews !== !!settings.anki_reviews)
                    toasts.show("cards", m.settings.anki_reviews
                                ? (ru() ? "Повторы Anki: вкл — каждый 3-й вопрос, пока Anki открыт" : "Anki reviews on — every 3rd question while Anki is open")
                                : (ru() ? "Повторы Anki: выкл" : "Anki reviews off"), theme.accent);
                settings = m.settings;
            } else if (m.type === "ignored") {
                // the engine refused an answer that came too fast (a held or bumped key): same question again
                if (state === "waiting" && q && q.qid === m.qid) { state = "question"; resumeClock(); }
            } else if (m.type === "undone") {
                if (m.ok) {
                    rating = m.rating; ratingDelta = 0; level = m.level_progress; today = m.today; streak = m.streak;
                    if (m.rank_brief) rankBrief = m.rank_brief;
                    toasts.show("warn", (ru() ? "Ответ отменён" : "Answer undone") + (m.left ? " · " + m.left + (ru() ? " ещё можно" : " more possible") : ""), theme.accent);
                    lastRes = null;
                    next();
                } else toasts.show("warn", ru() ? "Нечего отменять" : "Nothing to undo", theme.gold);
            } else if (m.type === "error") {
                console.warn("engine error:", m.error, m.trace || "");
                if (state === "waiting") next();
            }
        }

        // a tier reached: one quiet toast
        function tierToast(ev) {
            const reached = ev.reached === "常用" ? "常用漢字" : (ev.reached || "");
            toasts.show("trophy", (ru() ? "Уровень пройден: " : "Tier reached: ") + reached + " ✓", theme.gold);
            shell.play("levelup");
            if (state === "rank") send({ cmd: "rank" });
        }
        // placement test
        function startCalib() {
            advanceTimer.stop();
            calibDone = null;
            send({ cmd: "calib_start" });
        }
        function calibAnswer(i) {
            if (state !== "calib" || !calibQ) return;
            send({ cmd: "calib_answer", choice: i });
        }
        function leaveCalib() {
            if (calibQ) send({ cmd: "calib_cancel" });
            calibQ = null; calibDone = null;
            openView("rank");
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
            const ms = elapsed(); pauseClock();
            state = "waiting";
            send({ cmd: "answer", qid: q.qid, choice: i, ms: ms });
        }
        function submitOrder() {
            if (state !== "question" || !q) return;
            const ms = elapsed(); pauseClock();
            state = "waiting";
            send({ cmd: "answer", qid: q.qid, order: orderPicked.map(i => q.ui.tiles[i]), ms: ms });
        }
        function skip() {
            if (state !== "question" || !q) return;
            chosen = -1;
            const ms = elapsed(); pauseClock();
            state = "waiting";
            send({ cmd: "skip", qid: q.qid, ms: ms });
        }
        // Anki: the current result, or (during the next question) the one you just passed
        function ankiAdd(key) {
            advanceTimer.stop();
            if (key) send({ cmd: "anki_add", key: key });
            else if (state === "feedback" && res && res.anki) toasts.show("cards", ru() ? "Эта карточка уже в Anki" : "This card is already in Anki", theme.accent);
            else if (state === "feedback" && res) send({ cmd: "anki_add", key: res.key });
            else if (lastRes) send({ cmd: "anki_add", key: lastRes.key });
            else toasts.show("warn", ru() ? "Сначала ответьте на вопрос" : "Answer a question first", theme.gold);
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
        // views: Tab cycles Stats -> Rank -> Details -> Grammar -> back to the quiz; R jumps to Rank, G to Grammar
        function openView(name) {
            advanceTimer.stop();
            wantView = name;
            send({ cmd: name === "grammar" ? "grammar" : (name === "rank" ? "rank" : "stats") });
        }
        function enterView(name) {
            if (!inView()) { prevState = state; pauseClock(); }
            wantView = "";
            state = name;
        }
        function cycleView() {
            const i = views.indexOf(state);
            if (i < 0) openView("stats");
            else if (i === views.length - 1) closeStats();
            else if (views[i + 1] === "details") enterView("details");
            else openView(views[i + 1]);
        }
        function openStats() { cycleView() }
        function closeStats() {
            wantView = "";
            if (inView()) state = views.indexOf(prevState) >= 0 ? "question" : prevState;
            if (state === "loading" || state === "waiting" || !q) next();
            else if (state === "question") resumeClock();
        }
        function setFocus(gid) {
            setSetting("focus_gp", gid);
            toasts.show("book", gid ? ((ru() ? "Тренировка: " : "Drilling: ") + (grammar ? (grammar.points.find(p => p.id === gid) || {}).name : gid))
                                    : (ru() ? "Тренировка выключена" : "Drill off — back to the normal mix"), theme.accent2);
            if (grammar) send({ cmd: "grammar" });
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

    // long enough to glance at the meaning and the word glosses after a right answer
    Timer { id: advanceTimer; interval: 2600; onTriggered: if (app.state === "feedback") app.next() }
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
                // safety net: a held key repeats; never let the repeats answer, skip or move on
                const acting = k === Qt.Key_Space || k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Right
                               || k === Qt.Key_0 || (k >= Qt.Key_1 && k <= Qt.Key_9) || k === Qt.Key_U;
                if (event.isAutoRepeat && acting) { event.accepted = true; return; }
                // …and a question can't be answered or skipped in its first moment (a key still down from before)
                if (acting && (st === "question" || st === "calib") && Date.now() - app.shownAt < 450) { event.accepted = true; return; }
                if (k === Qt.Key_U && (st === "question" || st === "feedback")) { advanceTimer.stop(); app.send({ cmd: "undo" }); event.accepted = true; return; }
                if (st === "calib") {
                    // placement test: 1–4 answer, Space / 0 don't know, Esc back to Rank (the result: Enter)
                    const n = k - Qt.Key_1;
                    if (app.calibDone) { if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Escape || k === Qt.Key_Space) app.leaveCalib(); }
                    else if (k === Qt.Key_Escape) app.leaveCalib();
                    else if (n >= 0 && n < 4) app.calibAnswer(n);
                    else if (k === Qt.Key_Space || k === Qt.Key_0) app.calibAnswer(null);
                    event.accepted = true; return;
                }
                if (k === Qt.Key_Escape) {
                    // a normal app window now: Esc only leaves the views; close with Mod+Q like any window
                    if (app.inView()) app.closeStats();
                    event.accepted = true; return;
                }
                if (k === Qt.Key_Tab) { app.cycleView(); event.accepted = true; return; }
                if (k === Qt.Key_G && st !== "welcome" && st !== "grammar") { app.openView("grammar"); event.accepted = true; return; }
                if (k === Qt.Key_R && st !== "welcome" && st !== "rank") { app.openView("rank"); event.accepted = true; return; }
                if (st === "rank") {
                    const panes = ["words", "kanji", "grammar"];
                    const i = panes.indexOf(app.rankPane);
                    if (k === Qt.Key_Right) app.rankPane = panes[(i + 1) % 3];
                    else if (k === Qt.Key_Left) app.rankPane = panes[(i + 2) % 3];
                    else if (k === Qt.Key_T) app.startCalib();
                    else if (k === Qt.Key_R) app.closeStats();
                    else if (k === Qt.Key_L) app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru");
                    event.accepted = true; return;
                }
                if (st === "grammar") {
                    const pts = app.grammar ? app.grammar.points : [];
                    const pick = i => { app.grammarSel = Math.max(0, Math.min(pts.length - 1, i)); app.grammarEx = null;
                                        if (pts.length) app.send({ cmd: "grammar_example", id: pts[app.grammarSel].id }); };
                    if (k === Qt.Key_Down || k === Qt.Key_J) pick(app.grammarSel + 1);
                    else if (k === Qt.Key_Up || k === Qt.Key_K) pick(app.grammarSel - 1);
                    else if (k === Qt.Key_PageDown) pick(app.grammarSel + 8);
                    else if (k === Qt.Key_PageUp) pick(app.grammarSel - 8);
                    else if (k === Qt.Key_G) app.closeStats();
                    else if ((k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_D) && pts.length) {
                        const id = pts[app.grammarSel].id;
                        app.setFocus(app.grammar.focus === id ? null : id);
                    } else if (k === Qt.Key_X) app.setFocus(null);
                    else if (k === Qt.Key_L) app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru");
                    event.accepted = true; return;
                }
                if (st === "details") {
                    if (k === Qt.Key_L) app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru");
                    event.accepted = true; return;
                }
                if (st === "stats") {
                    if (k === Qt.Key_Left) app.setSetting("target", Math.round((app.settings.target - 0.05) * 100) / 100);
                    else if (k === Qt.Key_Right) app.setSetting("target", Math.round((app.settings.target + 0.05) * 100) / 100);
                    else if (k === Qt.Key_L) app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru");
                    else if (k === Qt.Key_F) app.setSetting("furigana", !app.settings.furigana);
                    else if (k === Qt.Key_M) app.setSetting("sound", !app.settings.sound);
                    else if (k === Qt.Key_A) app.setSetting("auto_advance", !app.settings.auto_advance);
                    else if (k === Qt.Key_S) app.send({ cmd: "anki_sync" });
                    else if (k === Qt.Key_K) app.setSetting("anki_auto", !app.settings.anki_auto);
                    else if (k === Qt.Key_V) { app.setSetting("anki_reviews", !app.settings.anki_reviews); app.send({ cmd: "stats" }); }
                    event.accepted = true; return;
                }
                if (k === Qt.Key_F && st !== "welcome") { app.setSetting("furigana", !app.settings.furigana); event.accepted = true; return; }
                if (k === Qt.Key_L) { app.setSetting("lang", app.settings.lang === "ru" ? "en" : "ru"); event.accepted = true; return; }
                if (st === "welcome" || st === "intro") {
                    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) app.next();
                    event.accepted = true; return;
                }
                if (k === Qt.Key_A && (st === "feedback" || st === "question")) { app.ankiAdd(); event.accepted = true; return; }
                if (st === "feedback") {
                    if (k === Qt.Key_W) advanceTimer.stop();      // hold: read the words
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

        // view tabs: Stats · Details · Grammar (click or Tab)
        Row {
            id: viewTabs
            anchors { top: hud.bottom; topMargin: 12; horizontalCenter: parent.horizontalCenter }
            spacing: 8
            opacity: app.inView() ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 220 } }
            Repeater {
                model: [["stats", "Stats", "Статистика"], ["rank", "Rank", "Ранг"], ["details", "Details", "Подробно"], ["grammar", "Grammar", "Грамматика"],
                        ["quiz", "Back to quiz", "К вопросам"]]
                delegate: Rectangle {
                    readonly property bool on: app.state === modelData[0]
                    width: tabText.implicitWidth + 28; height: 30; radius: 15
                    color: on ? theme.alpha(theme.accent, 0.22) : theme.alpha(theme.text, 0.06)
                    border.color: on ? theme.alpha(theme.accent, 0.55) : theme.alpha(theme.text, 0.10)
                    Text {
                        id: tabText
                        anchors.centerIn: parent
                        text: app.ru() ? modelData[2] : modelData[1]
                        color: parent.on ? theme.accent : theme.subtext0
                        font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const v = modelData[0];
                            if (v === "quiz") app.closeStats();
                            else if (v === "details" && app.stats) app.enterView("details");
                            else app.openView(v);
                        }
                    }
                }
            }
        }

        Stats {
            theme: theme
            app: app
            anchors { top: viewTabs.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 12 }
            visible: opacity > 0
            opacity: app.state === "stats" ? 1 : 0
            scale: app.state === "stats" ? 1 : 0.985
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
        }

        Rank {
            id: rankView
            theme: theme
            app: app
            anchors { top: viewTabs.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 12 }
            visible: opacity > 0
            opacity: app.state === "rank" ? 1 : 0
            scale: app.state === "rank" ? 1 : 0.985
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
        }

        Calib {
            id: calibView
            theme: theme
            app: app
            anchors { top: viewTabs.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 12 }
            visible: opacity > 0
            opacity: app.state === "calib" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
        }

        Details {
            theme: theme
            app: app
            anchors { top: viewTabs.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 12 }
            visible: opacity > 0
            opacity: app.state === "details" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
        }

        Grammar {
            theme: theme
            app: app
            anchors { top: viewTabs.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: 18; topMargin: 12 }
            visible: opacity > 0
            opacity: app.state === "grammar" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
        }

        Text {
            id: footer
            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 14 }
            color: theme.alpha(theme.subtext1, 0.9)
            font.family: theme.font
            font.pixelSize: 13
            text: {
                const ru = app.ru();
                if (app.state === "rank") return ru ? "←→ слова / кандзи / грамматика · T тест уровня · L язык · Tab дальше · Esc назад" : "←→ words / kanji / grammar · T placement test · L language · Tab next · Esc back";
                if (app.state === "calib") return app.calibDone ? (ru ? "Enter — к рангу" : "Enter back to Rank") : (ru ? "1–4 ответ · Space не знаю · Esc прервать" : "1–4 answer · Space don't know · Esc stop the test");
                if (app.state === "stats") return ru ? "Tab дальше · Esc назад · ←→ цель · L язык · F фуригана · M звук · A автопереход · S синхр. с Anki · K авто-Anki · V повторы Anki" : "Tab next · Esc back · ←→ target · L language · F furigana · M sound · A auto-advance · S sync with Anki · K auto-add to Anki · V Anki reviews";
                if (app.state === "details") return ru ? "Tab дальше · Esc назад · + у недавних — в Anki" : "Tab next · Esc back · click + on a recent question to add it to Anki";
                if (app.state === "grammar") return ru ? "↑↓ выбор · Enter тренировать / стоп · X выключить тренировку · Esc назад" : "↑↓ choose · Enter drill this point / stop · X drill off · Esc back";
                if (app.state === "feedback") return ru ? "Enter — дальше · U отменить ответ · A в Anki · W задержать · G грамматика · Tab статистика" : "Enter next · U undo answer · A add to Anki · W hold · G grammar · Tab stats";
                const prev = app.lastRes ? (ru ? " · A прошлый → Anki" : " · A add previous to Anki") : "";
                if (app.q && app.q.kind === "order" && app.state === "question") return (ru ? "Цифры — по порядку · Backspace отмена · Space пропуск" : "Press the numbers in order · Backspace undo · Space skip") + prev;
                return (ru ? "1–4 ответ · Space пропуск · U отменить прошлый · F фуригана · L язык · R ранг · G грамматика · Tab статистика" : "1–4 answer · Space skip · U undo last · F furigana · L language · R rank · G grammar · Tab stats") + prev;
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
            if (name === "stats") app.openView("stats");
            else if (name === "next") app.next();
            else if (name === "skip") app.skip();
            else if (name === "back") app.closeStats();
            else if (name === "anki") app.ankiAdd();
            else if (name === "grammar") app.openView("grammar");
            else if (name === "rank") app.openView("rank");
            else if (name === "test") app.startCalib();
            else if (/^calib:/.test(name)) { const v = name.slice(6); if (v === "done") app.leaveCalib(); else app.calibAnswer(v === "x" ? null : parseInt(v)); }
            else if (/^pane:/.test(name)) app.rankPane = name.slice(5);
            else if (name === "tab") app.cycleView();
            else if (name === "sync") app.send({ cmd: "anki_sync" });
            else if (name === "reviews") app.setSetting("anki_reviews", !app.settings.anki_reviews);
            else if (/^[1-9]$/.test(name)) { if (app.q && app.q.kind === "order") app.pickTile(parseInt(name) - 1); else app.answer(parseInt(name) - 1); }
        }
        function quit(): void { app.close() }
        function cheat(): void { app.peekMode = "right"; app.send({ cmd: "peek" }) }
        function miss(): void { app.peekMode = "wrong"; app.send({ cmd: "peek" }) }
        function state(): string { return app.state + (app.q ? " " + app.q.kind : "") }
        // render the Rank view to a PNG (works offscreen too, so checks need no window on screen)
        function shot(path: string): void { (app.state === "calib" ? calibView : rankView).grabToImage(r => r.saveToFile(path)) }
        // the question / feedback view, same idea
        function shotQuiz(path: string): void { quiz.grabToImage(r => r.saveToFile(path)) }
    }
}
