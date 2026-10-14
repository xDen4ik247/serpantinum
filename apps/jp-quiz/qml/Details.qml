import QtQuick

// Details: more stats — question types, levels, time, card states, review forecast, last 14 days,
// time of day, how well the matchmaking predicts you, and recent questions (add any to Anki).
Item {
    id: root
    property var theme
    property var app
    readonly property var m: app.stats && app.stats.more ? app.stats.more : null
    readonly property bool ru: app.ru()
    readonly property int gap: 12

    function pct(v) { return v === null || v === undefined ? "–" : Math.round(v * 100) + "%" }
    function accColor(a) { return a === null || a === undefined ? theme.alpha(theme.text, 0.15) : theme.mix(theme.bad, theme.good, Math.max(0, Math.min(1, (a - 0.45) / 0.45))) }

    component Box: Item {
        property string title
        default property alias content: inner.data
        Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
        Text { id: boxTitle; x: 14; y: 10; text: parent.title; color: theme.subtext0; font { family: theme.font; pixelSize: 13; weight: Font.DemiBold } }
        Item { id: inner; anchors { fill: parent; margins: 14; topMargin: 34 } }
    }

    // ---------------- tiles
    Row {
        id: tiles
        anchors { top: parent.top; left: parent.left; right: parent.right }
        spacing: 10
        Repeater {
            model: root.m ? [
                [root.ru ? "время всего" : "time studied", root.m.time.total_min >= 60 ? Math.floor(root.m.time.total_min / 60) + "h " + root.m.time.total_min % 60 + "m" : root.m.time.total_min + " min"],
                [root.ru ? "сегодня" : "today", root.m.time.today_min + " min"],
                [root.ru ? "сек. на вопрос" : "sec / question", root.m.time.per_q_s],
                [root.ru ? "слов выучено" : "words known", root.m.cards.words_known],
                [root.ru ? "учится · молодые · зрелые" : "learning · young · mature", root.m.cards.learning + " · " + root.m.cards.young + " · " + root.m.cards.mature]
            ] : []
            delegate: Item {
                width: (tiles.width - 40) / 5
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

    // ---------------- left: question types
    Box {
        id: kindsBox
        title: root.ru ? "По типам вопросов" : "By question type"
        anchors { top: tiles.bottom; topMargin: root.gap; left: parent.left; bottom: parent.bottom }
        width: (parent.width - 2 * root.gap) * 0.36
        Column {
            anchors.fill: parent
            spacing: 6
            Row {
                spacing: 8
                Text { width: kindsBox.width * 0.40; text: ""; font.pixelSize: 10 }
                Text { width: 44; text: root.ru ? "отв." : "n"; color: theme.subtext1; horizontalAlignment: Text.AlignRight; font { family: theme.font; pixelSize: 10 } }
                Text { width: kindsBox.width * 0.22; text: root.ru ? "точность" : "accuracy"; color: theme.subtext1; font { family: theme.font; pixelSize: 10 } }
                Text { width: 40; text: root.ru ? "мед. с" : "med s"; color: theme.subtext1; horizontalAlignment: Text.AlignRight; font { family: theme.font; pixelSize: 10 } }
            }
            Repeater {
                model: root.m ? root.m.kinds.filter(k => k.active) : []
                delegate: Row {
                    spacing: 8
                    Text { width: kindsBox.width * 0.40; text: app.tr(modelData.name); elide: Text.ElideRight; color: theme.text; font { family: theme.font; pixelSize: 12 } }
                    Text { width: 44; text: modelData.n; color: theme.subtext0; horizontalAlignment: Text.AlignRight; font { family: theme.font; pixelSize: 12; features: { "tnum": 1 } } }
                    Item {
                        width: kindsBox.width * 0.22; height: 14
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width - 32; height: 6; radius: 3; color: theme.alpha(theme.text, 0.08)
                            Rectangle { height: 6; radius: 3; width: parent.width * modelData.acc; color: root.accColor(modelData.acc) } }
                        Text { anchors { right: parent.right; verticalCenter: parent.verticalCenter } text: root.pct(modelData.acc); color: theme.subtext0; font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } } }
                    }
                    Text { width: 40; text: modelData.median_s === null ? "–" : modelData.median_s; color: theme.subtext0; horizontalAlignment: Text.AlignRight; font { family: theme.font; pixelSize: 12; features: { "tnum": 1 } } }
                }
            }
            Item { width: 1; height: 6 }
            Text { text: root.ru ? "По уровням" : "By level"; color: theme.subtext0; font { family: theme.font; pixelSize: 13; weight: Font.DemiBold } }
            Row {
                spacing: 10
                Repeater {
                    model: root.m ? root.m.levels : []
                    delegate: Rectangle {
                        width: (kindsBox.width - 28 - 20) / 3; height: 46; radius: 12
                        color: theme.alpha(root.accColor(modelData.acc), 0.14)
                        border.color: theme.alpha(root.accColor(modelData.acc), 0.4)
                        Column {
                            anchors.centerIn: parent
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "N" + modelData.level + "  " + root.pct(modelData.acc); color: theme.text; font { family: theme.font; pixelSize: 14; weight: Font.DemiBold } }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.n + (root.ru ? " отв." : " answers"); color: theme.subtext1; font { family: theme.font; pixelSize: 10 } }
                        }
                    }
                }
            }
        }
    }

    // ---------------- middle: days, forecast, calibration
    Column {
        id: mid
        anchors { top: tiles.bottom; topMargin: root.gap; left: kindsBox.right; leftMargin: root.gap; bottom: parent.bottom }
        width: (parent.width - 2 * root.gap) * 0.32
        spacing: root.gap
        readonly property int boxH: (height - 2 * spacing) / 3

        Box {
            width: parent.width; height: mid.boxH
            title: root.ru ? "14 дней · ответы и точность" : "Last 14 days · answers & accuracy"
            Row {
                anchors.fill: parent
                spacing: 3
                readonly property int maxN: root.m ? Math.max(1, ...root.m.days14.map(d => d.n)) : 1
                Repeater {
                    model: root.m ? root.m.days14 : []
                    delegate: Item {
                        width: (parent.width - 13 * 3) / 14; height: parent.height
                        Rectangle {
                            anchors { bottom: parent.bottom; bottomMargin: 14; horizontalCenter: parent.horizontalCenter }
                            width: parent.width; radius: 3
                            height: Math.max(2, (parent.height - 16) * modelData.n / parent.parent.maxN)
                            color: theme.alpha(root.accColor(modelData.acc), 0.75)
                        }
                        Text { anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter } text: modelData.day.slice(8); color: theme.subtext1; font { family: theme.font; pixelSize: 9 } }
                    }
                }
            }
        }
        Box {
            width: parent.width; height: mid.boxH
            title: root.ru ? "Повторы на 7 дней" : "Reviews due · next 7 days"
            Row {
                anchors.fill: parent
                spacing: 6
                readonly property int maxN: root.m ? Math.max(1, ...root.m.forecast) : 1
                Repeater {
                    model: root.m ? root.m.forecast : []
                    delegate: Item {
                        width: (parent.width - 6 * 6) / 7; height: parent.height
                        Rectangle {
                            anchors { bottom: parent.bottom; bottomMargin: 14; horizontalCenter: parent.horizontalCenter }
                            width: parent.width; radius: 3
                            height: Math.max(2, (parent.height - 30) * modelData / parent.parent.maxN)
                            color: theme.alpha(theme.accent, 0.7)
                            Text { anchors { bottom: parent.top; bottomMargin: 2; horizontalCenter: parent.horizontalCenter } text: modelData; color: theme.subtext0; font { family: theme.font; pixelSize: 10 } }
                        }
                        Text {
                            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter }
                            text: index === 0 ? (root.ru ? "сег." : "today") : "+" + index
                            color: theme.subtext1; font { family: theme.font; pixelSize: 9 }
                        }
                    }
                }
            }
        }
        Box {
            width: parent.width; height: mid.boxH
            title: root.ru ? "Прогноз vs факт (шанс → верно)" : "Predicted vs actual (match → right)"
            Column {
                anchors.fill: parent
                spacing: 4
                Repeater {
                    model: root.m ? root.m.calibration : []
                    delegate: Row {
                        spacing: 8
                        Text { width: 40; text: root.pct(modelData.p); color: theme.subtext0; horizontalAlignment: Text.AlignRight; font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } } }
                        Item {
                            width: mid.width - 28 - 40 - 90; height: 12
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 6; radius: 3; color: theme.alpha(theme.text, 0.08) }
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width * modelData.acc; height: 6; radius: 3; color: theme.alpha(theme.good, 0.8) }
                            Rectangle { x: parent.width * modelData.p - 1; width: 2; height: 12; color: theme.alpha(theme.text, 0.7) }
                        }
                        Text { text: root.pct(modelData.acc) + "  (" + modelData.n + ")"; color: theme.subtext1; font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } } }
                    }
                }
            }
        }
    }

    // ---------------- right: time of day + recent questions
    Column {
        id: right
        anchors { top: tiles.bottom; topMargin: root.gap; left: mid.right; leftMargin: root.gap; right: parent.right; bottom: parent.bottom }
        spacing: root.gap
        Box {
            width: parent.width; height: 118
            title: root.ru ? "Время суток" : "Time of day"
            Row {
                anchors.fill: parent
                spacing: 2
                readonly property int maxN: root.m ? Math.max(1, ...root.m.hours.map(h => h.n)) : 1
                Repeater {
                    model: root.m ? root.m.hours : []
                    delegate: Item {
                        width: (parent.width - 23 * 2) / 24; height: parent.height
                        Rectangle {
                            anchors { bottom: parent.bottom; bottomMargin: 13 }
                            width: parent.width; radius: 2
                            height: Math.max(1, (parent.height - 15) * modelData.n / parent.parent.maxN)
                            color: theme.alpha(root.accColor(modelData.acc), modelData.n ? 0.75 : 0.2)
                        }
                        Text { visible: index % 6 === 0; anchors.bottom: parent.bottom; text: index; color: theme.subtext1; font { family: theme.font; pixelSize: 9 } }
                    }
                }
            }
        }
        Box {
            id: recentBox
            width: parent.width; height: parent.height - 118 - root.gap
            title: root.ru ? "Недавние вопросы · + в Anki" : "Recent questions · + adds to Anki"
            Column {
                anchors.fill: parent
                spacing: 5
                clip: true
                Repeater {
                    model: root.m ? root.m.recent.slice(0, Math.max(3, Math.floor((recentBox.height - 40) / 29))) : []
                    delegate: Row {
                        width: parent.width
                        spacing: 8
                        Rectangle { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter; color: modelData.correct ? theme.good : theme.bad }
                        Text {
                            width: parent.width - 8 - 30 - 16
                            anchors.verticalCenter: parent.verticalCenter
                            text: (modelData.word ? modelData.word + " · " : "") + modelData.full
                            elide: Text.ElideRight
                            color: theme.text
                            font { family: theme.jp; pixelSize: 13 }
                        }
                        Rectangle {
                            width: 26; height: 24; radius: 8
                            color: modelData.in_anki ? theme.alpha(theme.good, 0.16) : (addMouse.containsMouse ? theme.alpha(theme.accent, 0.3) : theme.alpha(theme.accent, 0.14))
                            Text { anchors.centerIn: parent; text: modelData.in_anki ? "" : ""; color: modelData.in_anki ? theme.good : theme.accent; font { family: theme.icons; pixelSize: 12 } }
                            MouseArea { id: addMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.ankiAdd(modelData.key) }
                        }
                    }
                }
            }
        }
    }
}
