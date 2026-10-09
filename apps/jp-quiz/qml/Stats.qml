import QtQuick

// Stats: rating graph, success vs target, category skills, particles, weakest cards, streak calendar, settings.
Item {
    id: root
    property var theme
    property var app
    readonly property var st: app.stats
    readonly property bool ru: app.ru()
    readonly property var catColors: ({ g: theme.text, particles: theme.accent, grammar: theme.accent2,
                                         kanji: theme.gold, vocab: theme.good, reading: Qt.hsla(0.55, 0.6, 0.72, 1) })

    // ---------------- top totals
    Row {
        id: totals
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: 10
        Repeater {
            model: root.st ? [
                [root.ru ? "рейтинг" : "rating", root.st.rating + " · " + root.st.rank],
                [root.ru ? "ответов" : "answered", root.st.totals.answered],
                [root.ru ? "точность" : "accuracy", root.st.totals.answered ? Math.round(100 * root.st.totals.correct / root.st.totals.answered) + "%" : "–"],
                [root.ru ? "лучшая серия" : "best streak", root.st.totals.best_streak],
                [root.ru ? "карточек к повтору" : "reviews due", root.st.totals.due + " / " + root.st.totals.cards],
                [root.ru ? "грамматика" : "grammar", root.st.totals.unlocked_gp + " / " + root.st.totals.total_gp]
            ] : []
            delegate: Item {
                width: (totals.width - 50) / 6
                height: 62
                Glass { theme: root.theme; anchors.fill: parent; radius: 14; tintAlpha: 0.28 }
                Column {
                    anchors.centerIn: parent
                    spacing: 2
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; color: theme.text; font { family: theme.font; pixelSize: 19; weight: Font.DemiBold; features: { "tnum": 1 } } }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[0]; color: theme.subtext1; font { family: theme.font; pixelSize: 11; letterSpacing: 0.4 } }
                }
            }
        }
    }

    // ---------------- rating graph
    Item {
        id: graphBox
        anchors { top: totals.bottom; topMargin: 12; left: parent.left }
        width: parent.width * 0.58
        // tall tiled windows: give spare height to the graphs (the calendar keeps ~160 px)
        readonly property int extra: Math.max(0, root.height - 62 - 36 - 250 - 104 - 160)
        height: 250 + Math.round(extra * 0.75)
        Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
        Text {
            x: 16; y: 12
            text: root.ru ? "Рейтинг по навыкам" : "Skill ratings over time"
            color: theme.subtext0
            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
        }
        Row {
            anchors { right: parent.right; rightMargin: 14; top: parent.top; topMargin: 12 }
            spacing: 10
            Repeater {
                model: ["g", "particles", "grammar", "kanji", "vocab", "reading"]
                delegate: Row {
                    spacing: 4
                    Rectangle { width: 10; height: 3; radius: 1.5; color: root.catColors[modelData]; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        text: modelData === "g" ? (root.ru ? "общий" : "global") : (root.st && root.st.cats[modelData] ? app.tr(root.st.cats[modelData].name) : modelData)
                        color: theme.subtext1
                        font { family: theme.font; pixelSize: 10 }
                    }
                }
            }
        }
        Canvas {
            id: graph
            anchors { fill: parent; margins: 14; topMargin: 38; leftMargin: 44 }
            onWidthChanged: requestPaint()
            Connections { target: app; function onStatsChanged() { graph.requestPaint() } }
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const s = root.st;
                if (!s || !s.series.g || s.series.g.length < 2) {
                    ctx.fillStyle = Qt.rgba(1, 1, 1, 0.4);
                    ctx.font = "14px '" + theme.font + "'";
                    ctx.fillText(root.ru ? "Ответьте на несколько вопросов…" : "Answer a few questions to see your graph…", 10, height / 2);
                    return;
                }
                let lo = 1e9, hi = -1e9;
                for (const k in s.series) for (const v of s.series[k]) { lo = Math.min(lo, v); hi = Math.max(hi, v); }
                lo = Math.floor((lo - 20) / 50) * 50; hi = Math.ceil((hi + 20) / 50) * 50;
                const X = i => i / (s.series.g.length - 1) * width;
                const Y = v => height - (v - lo) / (hi - lo) * height;
                ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.07);
                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.45);
                ctx.lineWidth = 1;
                ctx.font = "10px '" + theme.font + "'";
                const step = (hi - lo) > 400 ? 200 : ((hi - lo) > 200 ? 100 : 50);
                for (let v = lo; v <= hi; v += step) {
                    ctx.beginPath(); ctx.moveTo(0, Y(v)); ctx.lineTo(width, Y(v)); ctx.stroke();
                    ctx.fillText(v, -38, Y(v) + 3);
                }
                const order = ["reading", "vocab", "kanji", "grammar", "particles", "g"];
                for (const k of order) {
                    const arr = s.series[k];
                    if (!arr || arr.length < 2) continue;
                    ctx.strokeStyle = root.catColors[k];
                    ctx.globalAlpha = k === "g" ? 1.0 : 0.75;
                    ctx.lineWidth = k === "g" ? 3 : 1.6;
                    ctx.lineJoin = "round";
                    ctx.beginPath();
                    for (let i = 0; i < arr.length; i++) { const x = X(i), y = Y(arr[i]); if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y); }
                    ctx.stroke();
                }
                ctx.globalAlpha = 1;
            }
        }
    }

    // ---------------- success vs target
    Item {
        id: rateBox
        anchors { top: graphBox.bottom; topMargin: 12; left: parent.left }
        width: graphBox.width
        height: 104 + Math.round(graphBox.extra * 0.25)
        Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
        Text {
            x: 16; y: 10
            text: (root.ru ? "Успешность (20 последних) · цель " : "Success rate (last 20) · target ") + Math.round(app.settings.target * 100) + "%"
            color: theme.subtext0
            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
        }
        Canvas {
            id: rate
            anchors { fill: parent; margins: 14; topMargin: 32; leftMargin: 44 }
            Connections { target: app; function onStatsChanged() { rate.requestPaint() } }
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const s = root.st;
                if (!s || s.rolling.length < 2) return;
                const r = s.rolling, n = r.length;
                const X = i => i / (n - 1) * width;
                const Y = v => height - v * height;
                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.06);
                ctx.fillRect(0, Y(s.target + 0.05), width, Y(s.target - 0.05) - Y(s.target + 0.05));
                ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.25);
                ctx.setLineDash([4, 4]);
                ctx.beginPath(); ctx.moveTo(0, Y(s.target)); ctx.lineTo(width, Y(s.target)); ctx.stroke();
                ctx.setLineDash([]);
                ctx.fillStyle = Qt.rgba(1, 1, 1, 0.45);
                ctx.font = "10px '" + theme.font + "'";
                ctx.fillText("100%", -38, 8); ctx.fillText("50%", -32, Y(0.5) + 3); ctx.fillText("0%", -26, height);
                ctx.strokeStyle = theme.good;
                ctx.lineWidth = 2;
                ctx.beginPath();
                for (let i = 0; i < n; i++) { if (i) ctx.lineTo(X(i), Y(r[i])); else ctx.moveTo(X(i), Y(r[i])); }
                ctx.stroke();
            }
        }
    }

    // ---------------- calendar heatmap
    Item {
        id: calBox
        anchors { top: rateBox.bottom; topMargin: 12; left: parent.left; bottom: parent.bottom }
        width: graphBox.width
        Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
        Text {
            x: 16; y: 10
            text: (root.ru ? "Календарь · серия " : "Streak calendar · ") + (root.st ? root.st.today.streak_days : 0) + (root.ru ? " дн." : ((root.st && root.st.today.streak_days === 1) ? " day" : " days"))
            color: theme.subtext0
            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
        }
        Grid {
            id: cal
            anchors { left: parent.left; leftMargin: 16; top: parent.top; topMargin: 34 }
            rows: 7
            flow: Grid.TopToBottom
            spacing: 3
            readonly property int weeks: Math.max(4, Math.floor((calBox.width - 32) / 15))
            readonly property var byDay: {
                const m = {};
                if (root.st) for (const d of root.st.calendar) m[d.day] = d.n;
                return m;
            }
            Repeater {
                model: cal.weeks * 7
                delegate: Rectangle {
                    width: 12; height: Math.max(6, Math.min(12, (calBox.height - 44) / 7 - 3)); radius: 3
                    readonly property var date: {
                        const today = new Date();
                        const dow = (today.getDay() + 6) % 7;      // Monday = 0
                        const daysBack = (cal.weeks - 1 - Math.floor(index / 7)) * 7 + (dow - index % 7);
                        const d = new Date(today.getTime() - daysBack * 86400000);
                        return d;
                    }
                    readonly property string key: Qt.formatDate(date, "yyyy-MM-dd")
                    readonly property int n: cal.byDay[key] || 0
                    visible: date <= new Date()
                    color: n === 0 ? theme.alpha(theme.text, 0.07) : theme.alpha(theme.good, Math.min(1, 0.25 + n / 60))
                }
            }
        }
    }

    // ---------------- right column: categories, particles, weakest
    Column {
        anchors { top: totals.bottom; topMargin: 12; left: graphBox.right; leftMargin: 12; right: parent.right; bottom: parent.bottom }
        spacing: 12
        Item {
            width: parent.width
            height: 182
            Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
            Column {
                anchors { fill: parent; margins: 14 }
                spacing: 9
                Text { text: root.ru ? "Навыки" : "Skills"; color: theme.subtext0; font { family: theme.font; pixelSize: 13; weight: Font.DemiBold } }
                Repeater {
                    model: ["particles", "grammar", "kanji", "vocab", "reading"]
                    delegate: Row {
                        spacing: 8
                        readonly property var cat: root.st ? root.st.cats[modelData] : null
                        Text { width: 92; text: cat ? app.tr(cat.name) : ""; color: theme.subtext0; font { family: theme.font; pixelSize: 13 } }
                        Rectangle {
                            width: parent.parent.width - 92 - 8 - 96; height: 8; radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: theme.alpha(theme.text, 0.08)
                            Rectangle {
                                height: 8; radius: 4
                                width: parent.width * (cat ? Math.max(0.03, Math.min(1, (cat.rating - 1150) / 900)) : 0)
                                color: root.catColors[modelData]
                                Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutQuint } }
                            }
                        }
                        Text {
                            width: 88
                            text: cat ? cat.rating + "  " + cat.levels.map(l => "N" + l).slice(-1).join("") : ""
                            color: theme.text
                            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold; features: { "tnum": 1 } }
                        }
                    }
                }
            }
        }
        Item {
            width: parent.width
            height: 112
            Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
            Text { x: 14; y: 10; text: root.ru ? "Частицы" : "Particles"; color: theme.subtext0; font { family: theme.font; pixelSize: 13; weight: Font.DemiBold } }
            Flow {
                anchors { fill: parent; margins: 14; topMargin: 34 }
                spacing: 6
                Repeater {
                    model: root.st ? root.st.particles : []
                    delegate: Rectangle {
                        width: ptx.implicitWidth + 16; height: 26; radius: 13
                        readonly property real t: Math.max(0, Math.min(1, (modelData.rating - 1300) / 500))
                        color: theme.alpha(theme.mix(theme.bad, theme.good, t), 0.16)
                        border.color: theme.alpha(theme.mix(theme.bad, theme.good, t), 0.45)
                        Text {
                            id: ptx
                            anchors.centerIn: parent
                            text: modelData.tag.slice(3) + " " + modelData.rating
                            color: theme.text
                            font { family: theme.jp; pixelSize: 12 }
                        }
                    }
                }
            }
        }
        Item {
            id: weakBox
            width: parent.width
            height: parent.height - 182 - 112 - 24
            Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
            Text { id: weakTitle; x: 14; y: 10; text: root.ru ? "Слабые места" : "Weakest cards"; color: theme.subtext0; font { family: theme.font; pixelSize: 13; weight: Font.DemiBold } }
            Column {
                anchors { left: parent.left; right: parent.right; top: weakTitle.bottom; margins: 14; topMargin: 8 }
                spacing: 6
                Repeater {
                    model: root.st ? root.st.weak.slice(0, Math.max(3, Math.min(10, Math.floor((weakBox.height - 96) / 25)))) : []
                    delegate: Row {
                        spacing: 8
                        width: parent.width
                        Rectangle {
                            width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter
                            color: modelData.lapses > 1 ? theme.bad : theme.gold
                        }
                        Text {
                            width: parent.width - 90
                            text: app.tr(modelData.label)
                            elide: Text.ElideRight
                            color: theme.text
                            font { family: theme.jp; pixelSize: 13 }
                        }
                        Text {
                            text: (root.ru ? "ошибок " : "misses ") + modelData.lapses
                            color: theme.subtext1
                            font { family: theme.font; pixelSize: 11 }
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
                Text {
                    visible: root.st && root.st.weak.length === 0
                    text: root.ru ? "Пока нет — отличная работа!" : "Nothing yet — nice!"
                    color: theme.subtext1
                    font { family: theme.font; pixelSize: 13 }
                }
            }
            Text {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
                horizontalAlignment: Text.AlignHCenter
                lineHeight: 1.3
                text: (root.ru ? "цель " : "target ") + Math.round(app.settings.target * 100) + "%  ·  " +
                      (app.settings.lang === "ru" ? "RU" : "EN") + "  ·  " + (root.ru ? "фуригана " : "furigana ") + (app.settings.furigana ? "on" : "off") +
                      "  ·  " + (root.ru ? "звук " : "sound ") + (app.settings.sound ? "on" : "off") + "  ·  " + (root.ru ? "авто " : "auto ") + (app.settings.auto_advance ? "on" : "off") +
                      "\nAnki: " + (root.st && root.st.anki && root.st.anki.last_sync ? (root.ru ? "известно " : "known ") + root.st.anki.last_sync.known + ", " + (root.ru ? "слабых " : "weak ") + root.st.anki.last_sync.weak : (root.ru ? "не синхронизировано" : "not synced")) +
                      "  ·  " + (root.ru ? "авто-добавление " : "auto-add misses ") + (app.settings.anki_auto ? "on" : "off") +
                      (root.st && root.st.anki && root.st.anki.queued ? "  ·  " + root.st.anki.queued + (root.ru ? " в очереди" : " queued") : "")
                color: theme.alpha(theme.accent, 0.9)
                font { family: theme.font; pixelSize: 11; weight: Font.DemiBold }
            }
        }
    }
}
