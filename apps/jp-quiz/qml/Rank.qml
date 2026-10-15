import QtQuick

// Rank: your medal (or plain tier), how much is left to the next tier, the ladder, and what is left in it.
// Calm on purpose: no counters ticking up, no loops; bars ease once when the data changes.
Item {
    id: root
    property var theme
    property var app
    readonly property var rk: app.rankData
    readonly property bool ru: app.ru()
    readonly property bool dota: rk ? rk.dota : true
    readonly property var medal: rk ? rk.medal : null
    readonly property var target: rk ? rk.tiers.find(t => t.label === rk.medal.target) : null
    readonly property color tint: dota && medal ? medalView.metal : theme.accent
    readonly property var partNames: ({ words: ["JLPT words", "Слова JLPT"], everyday: ["Everyday words", "Повседневные слова"],
                                        kanji: ["Kanji", "Кандзи"], grammar: ["Grammar", "Грамматика"] })
    function tr(p) { return ru && p[1] ? p[1] : p[0] }
    // days -> "12 days" / "8 wk" / "5 mo" / "2 yr"
    function eta(d) {
        if (d === null || d === undefined) return "—";
        if (d < 14) return d + (ru ? " дн" : " d");
        if (d < 70) return Math.round(d / 7) + (ru ? " нед" : " wk");
        if (d < 730) return Math.round(d / 30.4) + (ru ? " мес" : " mo");
        return (d / 365).toFixed(1) + (ru ? " г" : " yr");
    }
    function num(n) { return Number(n).toLocaleString(Qt.locale("en_US"), "f", 0) }
    // the name of a step on the ladder: a Dota medal, or the tier itself in plain style
    function stepName(i) {
        if (!rk) return "";
        if (dota) return tr(rk.medals[i]);
        if (i === 0) return ru ? "Начало" : "Starting out";
        if (i <= 6) return (ru ? "Пройден " : "Reached ") + rk.tiers[i - 1].label;
        return ru ? "Всё пройдено" : "Everything";
    }
    function headline() {
        if (!medal) return "";
        if (medal.index >= 7) return ru ? "Все списки выучены целиком" : "Every list, known in full";
        if (medal.index === 6) return ru ? "Путь к 100 % всего" : "On the way to 100 % of everything";
        const tgt = medal.target === "常用" ? "常用漢字" : medal.target;
        if (!dota) return (ru ? "80 % каждой части — и " : "80 % of every part and ") + tgt + (ru ? " пройден" : " is yours");
        return (medal.reached ? (medal.reached + " ✓ · ") : "") + (ru ? "дальше " : "next: ") + tgt;
    }

    Text {
        anchors.centerIn: parent
        visible: !root.rk
        text: root.ru ? "Загрузка…" : "Loading…"
        color: theme.subtext1
        font { family: theme.font; pixelSize: 15 }
    }

    // ---------------- top: medal card + what the next tier needs
    Item {
        id: top
        visible: !!root.rk
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 262

        Item {
            id: medalCard
            anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
            width: Math.round(parent.width * 0.44)
            Glass { theme: root.theme; anchors.fill: parent; radius: 18; tintAlpha: 0.30 }
            Medal {
                id: medalView
                theme: root.theme
                anchors { left: parent.left; leftMargin: 10; top: parent.top; topMargin: 4 }
                width: Math.min(184, parent.height - planBox.height - 12); height: width
                dota: root.dota
                index: root.medal ? root.medal.index : 0
                stars: root.medal ? root.medal.stars : 1
                progress: root.medal ? root.medal.progress : 0
                label: root.medal ? root.medal.target : "N5"
            }
            Column {
                anchors { left: medalView.right; leftMargin: 8; right: parent.right; rightMargin: 18; verticalCenter: medalView.verticalCenter }
                spacing: 6
                Text {
                    width: parent.width
                    text: root.dota ? root.stepName(root.medal ? root.medal.index : 0).toUpperCase() : (root.medal ? (root.medal.reached || (root.ru ? "Начало" : "Start")) + " → " + root.medal.target : "")
                    color: root.dota ? Qt.lighter(root.tint, 1.25) : theme.text
                    elide: Text.ElideRight
                    font { family: root.dota ? "Noto Serif CJK JP" : theme.font; pixelSize: root.dota ? 26 : 24; weight: Font.DemiBold; letterSpacing: root.dota ? 3 : 0 }
                }
                Text {
                    visible: root.dota && root.medal && root.medal.index < 7
                    text: root.medal ? "★".repeat(root.medal.stars) + "☆".repeat(5 - root.medal.stars) : ""
                    color: Qt.rgba(1, 0.86, 0.55, 0.95)
                    font { pixelSize: 16; letterSpacing: 2 }
                }
                Text {
                    width: parent.width
                    text: root.headline()
                    color: theme.subtext0
                    wrapMode: Text.WordWrap
                    font { family: theme.font; pixelSize: 14 }
                }
                Item { width: 1; height: 4 }
                Rectangle {
                    width: parent.width; height: 8; radius: 4
                    color: theme.alpha(theme.text, 0.09)
                    Rectangle {
                        height: parent.height; radius: 4
                        width: parent.width * Math.min(1, root.medal ? root.medal.progress : 0)
                        color: root.tint
                        Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutQuint } }
                    }
                }
                Text {
                    width: parent.width
                    text: !root.medal ? "" : root.medal.index >= 7 ? "" :
                          root.num(root.medal.to_go) + (root.ru ? " до следующего шага · " : " to go · ") + Math.floor(root.medal.progress * 100) + "%"
                    color: theme.subtext1
                    font { family: theme.font; pixelSize: 12; features: { "tnum": 1 } }
                }
            }

            // daily study time: how long the next step takes at a few daily times, from your own pace
            Column {
                id: planBox
                readonly property var plan: root.rk ? root.rk.plan : null
                visible: !!plan && root.medal && root.medal.index < 7
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14; bottomMargin: 12 }
                spacing: 6
                Row {
                    spacing: 5
                    Text {
                        text: root.ru ? "В день:" : "Per day:"
                        color: theme.subtext1
                        anchors.verticalCenter: parent.verticalCenter
                        font { family: theme.font; pixelSize: 11 }
                    }
                    Repeater {
                        model: planBox.plan ? planBox.plan.options.filter(o => o.min !== 45) : []
                        delegate: Rectangle {
                            readonly property bool pick: planBox.plan && modelData.min === planBox.plan.suggest_min
                            width: optText.implicitWidth + 14; height: 22; radius: 11
                            color: pick ? theme.alpha(root.tint, 0.22) : theme.alpha(theme.text, 0.05)
                            border.color: pick ? theme.alpha(root.tint, 0.55) : "transparent"
                            Text {
                                id: optText
                                anchors.centerIn: parent
                                text: modelData.min + (root.ru ? " мин · " : " min · ") + root.eta(modelData.days)
                                color: parent.pick ? theme.text : theme.subtext0
                                font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } }
                            }
                        }
                    }
                }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    color: theme.subtext1
                    font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } }
                    text: {
                        const p = planBox.plan;
                        if (!p || !root.medal) return "";
                        const goal = root.medal.index >= 6 ? "100 %" : (root.medal.target === "常用" ? "常用漢字" : root.medal.target);
                        return root.ru
                            ? "Совет: " + p.suggest_min + " мин/день (~" + p.suggest_questions + " вопросов) → " + goal + " за ~3 мес. · вы в последнее время: " + p.recent_min_per_day + " мин"
                            : "Suggested: " + p.suggest_min + " min/day (~" + p.suggest_questions + " questions) → " + goal + " in ~3 months · lately you: " + p.recent_min_per_day + " min";
                    }
                }
            }
        }

        Item {
            id: needCard
            anchors { top: parent.top; bottom: parent.bottom; left: medalCard.right; leftMargin: 12; right: parent.right }
            Glass { theme: root.theme; anchors.fill: parent; radius: 18; tintAlpha: 0.28 }
            Text {
                id: needTitle
                x: 18; y: 14
                text: root.target ? ((root.ru ? "Чтобы дойти до " : "To reach ") + (root.target.label === "常用" ? "常用漢字" : root.target.label)
                                    + (root.ru ? " — 80 % каждой части (вместе с уровнями ниже)" : " — 80 % of every part, levels below included")) : ""
                color: theme.subtext0
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
            }
            Column {
                anchors { top: needTitle.bottom; topMargin: 14; left: parent.left; leftMargin: 18; right: parent.right; rightMargin: 18 }
                spacing: 13
                Repeater {
                    model: root.target ? ["words", "everyday", "kanji", "grammar"] : []
                    delegate: Item {
                        id: part
                        readonly property var p: root.target.parts[modelData]
                        readonly property int toGo: Math.max(0, p.cum_need - p.cum_known)
                        width: parent.width; height: 34
                        Text {
                            id: pName
                            text: root.tr(root.partNames[modelData])
                            color: theme.text
                            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
                        }
                        Text {
                            anchors { right: parent.right; baseline: pName.baseline }
                            text: part.toGo === 0 ? (root.ru ? "готово ✓" : "done ✓")
                                                  : root.num(part.toGo) + (root.ru ? " осталось" : " to go")
                            color: part.toGo === 0 ? theme.good : theme.subtext0
                            font { family: theme.font; pixelSize: 13; features: { "tnum": 1 } }
                        }
                        Rectangle {
                            id: track
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6 }
                            height: 6; radius: 3
                            color: theme.alpha(theme.text, 0.08)
                            Rectangle {
                                height: parent.height; radius: 3
                                width: parent.width * Math.min(1, part.p.cum_known / Math.max(1, part.p.cum_total))
                                color: part.toGo === 0 ? theme.good : root.tint
                                Behavior on width { NumberAnimation { duration: 700; easing.type: Easing.OutQuint } }
                            }
                            // the 80 % line
                            Rectangle {
                                x: parent.width * part.p.cum_need / Math.max(1, part.p.cum_total) - 1
                                y: -3; width: 2; height: parent.height + 6; radius: 1
                                color: theme.alpha(theme.text, 0.55)
                            }
                        }
                        Text {
                            anchors { left: parent.left; top: track.bottom; topMargin: 2 }
                            text: root.num(part.p.cum_known) + " / " + root.num(part.p.cum_total) + (root.ru ? " знаете" : " known")
                                  + (part.p.learning ? " · " + root.num(part.p.learning) + (root.ru ? " учите" : " learning") : "")
                            color: theme.subtext1
                            font { family: theme.font; pixelSize: 10; features: { "tnum": 1 } }
                        }
                    }
                }
            }
        }
    }

    // ---------------- bottom: ladder + what is left in the tier
    Item {
        id: ladder
        visible: !!root.rk
        anchors { top: top.bottom; topMargin: 12; bottom: parent.bottom; left: parent.left }
        width: Math.round(parent.width * 0.34)
        Glass { theme: root.theme; anchors.fill: parent; radius: 18; tintAlpha: 0.28 }
        Text {
            id: ladderTitle
            x: 16; y: 12
            text: root.ru ? "Лестница" : "Ladder"
            color: theme.subtext0
            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
        }
        Flickable {
            anchors { top: ladderTitle.bottom; topMargin: 8; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
            contentHeight: ladderCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: ladderCol
                width: parent.width
                spacing: 4
                Repeater {
                    // the 8 medals; medal i stands for working toward tier i (6 = 100 % of all, 7 = done)
                    model: root.rk ? 8 : 0
                    delegate: Rectangle {
                        id: step
                        readonly property bool current: root.medal && root.medal.index === index
                        readonly property bool passed: root.medal && root.medal.index > index
                        readonly property var tier: index < 6 ? root.rk.tiers[index] : null
                        width: ladderCol.width; height: 38; radius: 12
                        color: current ? theme.alpha(root.tint, 0.16) : "transparent"
                        border.color: current ? theme.alpha(root.tint, 0.45) : "transparent"
                        Medal {
                            id: mini
                            theme: root.theme
                            anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter }
                            width: 34; height: 34
                            small: true
                            dota: root.dota
                            index: model.index
                            stars: step.current ? root.medal.stars : (step.passed ? 5 : 0)
                            progress: step.tier ? step.tier.progress : 0
                            label: step.tier ? step.tier.label : "∞"
                            opacity: step.passed || step.current ? 1 : 0.55
                        }
                        Text {
                            id: stepText
                            anchors { left: mini.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                            width: 104
                            text: root.dota ? root.tr(root.rk.medals[index]) : (step.tier ? (step.tier.label === "常用" ? "常用漢字" : step.tier.label) : (index === 6 ? "100 %" : (root.ru ? "Всё" : "All")))
                            color: step.current ? theme.text : (step.passed ? theme.subtext0 : theme.subtext1)
                            elide: Text.ElideRight
                            font { family: root.dota ? "Noto Serif CJK JP" : theme.font; pixelSize: 13; weight: step.current ? Font.DemiBold : Font.Normal }
                        }
                        Text {
                            anchors { left: stepText.right; verticalCenter: parent.verticalCenter }
                            visible: root.dota
                            text: step.tier ? "→ " + step.tier.label : (index === 6 ? "→ 100 %" : "")
                            color: theme.subtext1
                            font { family: theme.jp; pixelSize: 11 }
                        }
                        Text {
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: step.passed ? "✓" : (step.tier ? Math.floor(step.tier.progress * 100) + "%" : "")
                            color: step.passed ? theme.good : theme.subtext1
                            font { family: theme.font; pixelSize: 12; features: { "tnum": 1 } }
                        }
                    }
                }
            }
        }
    }

    Item {
        id: leftPane
        visible: !!root.rk
        anchors { top: top.bottom; topMargin: 12; bottom: parent.bottom; left: ladder.right; leftMargin: 12; right: parent.right }
        Glass { theme: root.theme; anchors.fill: parent; radius: 18; tintAlpha: 0.28 }
        Row {
            id: paneTabs
            x: 14; y: 10
            spacing: 6
            Text {
                text: (root.ru ? "Что осталось в " : "Left in ") + (root.rk ? (root.rk.next.label === "常用" ? "常用漢字" : root.rk.next.label) : "") + "  "
                color: theme.subtext0
                anchors.verticalCenter: parent.verticalCenter
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
            }
            Repeater {
                model: [["words", "Words", "Слова"], ["kanji", "Kanji", "Кандзи"], ["grammar", "Grammar", "Грамматика"]]
                delegate: Rectangle {
                    readonly property bool on: app.rankPane === modelData[0]
                    width: tText.implicitWidth + 20; height: 24; radius: 12
                    color: on ? theme.alpha(root.tint, 0.20) : theme.alpha(theme.text, 0.05)
                    border.color: on ? theme.alpha(root.tint, 0.5) : theme.alpha(theme.text, 0.08)
                    Text {
                        id: tText
                        anchors.centerIn: parent
                        text: root.ru ? modelData[2] : modelData[1]
                        color: parent.on ? theme.text : theme.subtext1
                        font { family: theme.font; pixelSize: 12; weight: Font.DemiBold }
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: app.rankPane = modelData[0] }
                }
            }
        }
        Text {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: paneTabs.verticalCenter }
            text: root.ru ? "◌ нет в викторине — через Anki" : "◌ not in the quiz yet — learn it in Anki"
            color: theme.subtext1
            font { family: theme.font; pixelSize: 11 }
        }

        // kanji grid: bright = known, tinted = learning, faint = not yet
        Flickable {
            id: kanjiPane
            visible: app.rankPane === "kanji"
            anchors { top: paneTabs.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
            contentHeight: kFlow.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Flow {
                id: kFlow
                width: parent.width
                spacing: 4
                Repeater {
                    model: root.rk && app.rankPane === "kanji" ? root.rk.next.kanji : []
                    delegate: Rectangle {
                        width: 34; height: 34; radius: 9
                        color: modelData[1] === 2 ? theme.alpha(root.tint, 0.22) : (modelData[1] === 1 ? theme.alpha(theme.accent2, 0.12) : theme.alpha(theme.text, 0.035))
                        border.color: modelData[2] ? "transparent" : theme.alpha(theme.text, 0.14)
                        border.width: modelData[2] ? 0 : 1
                        Text {
                            anchors.centerIn: parent
                            text: modelData[0]
                            color: modelData[1] === 2 ? theme.text : (modelData[1] === 1 ? theme.subtext0 : theme.alpha(theme.subtext1, 0.7))
                            font { family: theme.jp; pixelSize: 19 }
                        }
                    }
                }
            }
        }

        // grammar list
        ListView {
            visible: app.rankPane === "grammar"
            anchors { top: paneTabs.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: root.rk && app.rankPane === "grammar" ? root.rk.next.grammar : []
            delegate: Item {
                width: ListView.view.width; height: 28
                Rectangle {
                    id: gDot
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    width: 8; height: 8; radius: 4
                    color: modelData.s === 2 ? theme.good : (modelData.s === 1 ? theme.accent2 : theme.alpha(theme.text, 0.15))
                }
                Text {
                    id: gPat
                    anchors { left: gDot.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    width: Math.round(parent.width * 0.46)
                    text: modelData.p + (modelData.q ? "" : "  ◌")
                    color: modelData.s === 2 ? theme.subtext1 : theme.text
                    elide: Text.ElideRight
                    font { family: theme.jp; pixelSize: 14 }
                }
                Text {
                    anchors { left: gPat.right; leftMargin: 8; right: parent.right; verticalCenter: parent.verticalCenter }
                    text: root.ru && modelData.ru ? modelData.ru : modelData.en
                    color: theme.subtext1
                    elide: Text.ElideRight
                    font { family: theme.font; pixelSize: 12 }
                }
            }
        }

        // the next words to learn (not known yet), the quiz's own first
        ListView {
            visible: app.rankPane === "words"
            anchors { top: paneTabs.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: root.rk && app.rankPane === "words" ? root.rk.next.words : []
            delegate: Item {
                width: ListView.view.width; height: 30
                Rectangle {
                    id: wDot
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                    width: 8; height: 8; radius: 4
                    color: modelData.s === 1 ? theme.accent2 : theme.alpha(theme.text, 0.15)
                }
                Text {
                    id: wWord
                    anchors { left: wDot.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    width: 118
                    text: modelData.w + (modelData.q ? "" : " ◌")
                    color: theme.text
                    elide: Text.ElideRight
                    font { family: theme.jp; pixelSize: 15 }
                }
                Text {
                    id: wRead
                    anchors { left: wWord.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
                    width: 108
                    text: modelData.r !== modelData.w ? modelData.r : ""
                    color: theme.subtext1
                    elide: Text.ElideRight
                    font { family: theme.jp; pixelSize: 12 }
                }
                Rectangle {
                    id: wChip
                    anchors { left: wRead.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
                    visible: modelData.e
                    width: chipText.implicitWidth + 12; height: 18; radius: 9
                    color: theme.alpha(theme.accent2, 0.12)
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: modelData.tag ? modelData.tag : (root.ru ? "быт" : "daily")
                        color: theme.accent2
                        font { family: theme.font; pixelSize: 10 }
                    }
                }
                Text {
                    anchors { left: modelData.e ? wChip.right : wRead.right; leftMargin: 8; right: parent.right; verticalCenter: parent.verticalCenter }
                    text: root.ru && modelData.ru ? modelData.ru : (modelData.en || (root.ru ? "слово " + modelData.tier : modelData.tier + " word"))
                    color: theme.subtext1
                    elide: Text.ElideRight
                    font { family: theme.font; pixelSize: 12 }
                }
            }
        }
    }
}
