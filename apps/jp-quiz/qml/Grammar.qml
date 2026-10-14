import QtQuick

// Grammar tab: every grammar point (N5 → N3) with your accuracy / rating / memory, its explanation
// and example sentences, and a focused drill (Enter) that serves only that point until you stop it.
Item {
    id: root
    property var theme
    property var app
    readonly property var gr: app.grammar
    readonly property var pts: gr ? gr.points : []
    readonly property var sel: pts.length ? pts[Math.min(app.grammarSel, pts.length - 1)] : null
    readonly property bool ru: app.ru()

    function pct(v) { return v === null || v === undefined ? "–" : Math.round(v * 100) + "%" }
    function select(i) {
        app.grammarSel = i;
        app.grammarEx = null;
        app.send({ cmd: "grammar_example", id: root.pts[i].id });
    }

    // ---------------- list
    Item {
        id: listBox
        anchors { top: parent.top; left: parent.left; bottom: parent.bottom }
        width: Math.max(300, parent.width * 0.42)
        Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
        Text {
            id: listTitle
            x: 14; y: 10
            text: (root.ru ? "Грамматика · открыто " : "Grammar · unlocked ") + root.pts.filter(p => p.unlocked).length + " / " + root.pts.length
            color: theme.subtext0
            font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
        }
        ListView {
            id: list
            anchors { fill: parent; margins: 8; topMargin: 34 }
            clip: true
            model: root.pts
            currentIndex: app.grammarSel
            highlightMoveDuration: 160
            spacing: 2
            section.property: "level"
            section.delegate: Text {
                required property string section
                text: "N" + section
                leftPadding: 8; topPadding: 6; bottomPadding: 2
                color: theme.accent
                font { family: theme.font; pixelSize: 12; weight: Font.Bold; letterSpacing: 0.8 }
            }
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: list.width
                height: 34
                radius: 10
                readonly property bool cur: index === app.grammarSel
                readonly property bool focused: root.gr && root.gr.focus === modelData.id
                color: cur ? theme.alpha(theme.accent, 0.18) : (rowMouse.containsMouse ? theme.alpha(theme.text, 0.05) : "transparent")
                border.color: focused ? theme.alpha(theme.accent2, 0.7) : "transparent"
                Rectangle {
                    x: 10; anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 4
                    color: !modelData.unlocked ? theme.alpha(theme.text, 0.18)
                         : modelData.due ? theme.gold
                         : modelData.acc === null ? theme.alpha(theme.accent, 0.6)
                         : theme.mix(theme.bad, theme.good, Math.max(0, Math.min(1, (modelData.acc - 0.45) / 0.45)))
                }
                Text {
                    x: 26; anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 26 - 110
                    text: modelData.name + "  " + (root.ru ? modelData.ru : modelData.en)
                    elide: Text.ElideRight
                    color: modelData.unlocked ? theme.text : theme.subtext1
                    font { family: theme.jp; pixelSize: 13 }
                }
                Text {
                    anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                    text: !modelData.unlocked ? (root.ru ? "закрыто" : "locked")
                          : (modelData.n ? root.pct(modelData.acc) + " · " + modelData.n : (root.ru ? "новое" : "new"))
                    color: theme.subtext1
                    font { family: theme.font; pixelSize: 11; features: { "tnum": 1 } }
                }
                MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.select(index) }
            }
        }
    }

    // ---------------- detail
    Item {
        id: detail
        anchors { top: parent.top; left: listBox.right; leftMargin: 12; right: parent.right; bottom: parent.bottom }
        Glass { theme: root.theme; anchors.fill: parent; radius: 16; tintAlpha: 0.28 }
        Column {
            anchors { fill: parent; margins: 20 }
            spacing: 12
            visible: !!root.sel
            Row {
                spacing: 10
                Text {
                    text: root.sel ? root.sel.name : ""
                    color: theme.text
                    font { family: theme.jp; pixelSize: 28; weight: Font.Medium }
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: lvText.implicitWidth + 16; height: 22; radius: 11
                    color: theme.alpha(theme.accent2, 0.16); border.color: theme.alpha(theme.accent2, 0.4)
                    Text { id: lvText; anchors.centerIn: parent; text: root.sel ? "N" + root.sel.level : ""; color: theme.accent2; font { family: theme.font; pixelSize: 11; weight: Font.Bold } }
                }
            }
            Text {
                width: parent.width
                text: root.sel ? (root.ru ? root.sel.ru : root.sel.en) : ""
                color: theme.accent
                wrapMode: Text.WordWrap
                font { family: theme.font; pixelSize: 17; weight: Font.DemiBold }
            }
            Text {
                width: parent.width
                text: root.sel ? (root.ru ? root.sel.explain_ru : root.sel.explain_en) : ""
                color: theme.text
                wrapMode: Text.WordWrap
                lineHeight: 1.25
                font { family: theme.font; pixelSize: 14 }
            }
            // your numbers for this point
            Row {
                spacing: 8
                Repeater {
                    model: root.sel ? [
                        [root.ru ? "ответов" : "answered", root.sel.n],
                        [root.ru ? "точность" : "accuracy", root.pct(root.sel.acc)],
                        [root.ru ? "рейтинг" : "rating", root.sel.rating === null ? "–" : root.sel.rating + (root.sel.sure ? "" : "?")],
                        [root.ru ? "память" : "memory", root.sel.r === null ? "–" : Math.round(root.sel.r * 100) + "%"],
                        [root.ru ? "ошибок" : "lapses", root.sel.lapses],
                        [root.ru ? "вопросов" : "questions", root.sel.items]
                    ] : []
                    delegate: Rectangle {
                        width: (detail.width - 40 - 40) / 6; height: 50; radius: 12
                        color: theme.alpha(theme.text, 0.05)
                        Column {
                            anchors.centerIn: parent
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[1]; color: theme.text; font { family: theme.font; pixelSize: 16; weight: Font.DemiBold; features: { "tnum": 1 } } }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: modelData[0]; color: theme.subtext1; font { family: theme.font; pixelSize: 10 } }
                        }
                    }
                }
            }
            Text {
                text: root.ru ? "Примеры" : "Examples"
                color: theme.subtext0
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
            }
            Repeater {
                model: app.grammarEx && root.sel && app.grammarEx.id === root.sel.id ? app.grammarEx.examples : []
                delegate: Column {
                    width: detail.width - 40
                    spacing: 2
                    Text { width: parent.width; text: modelData.ja || ""; wrapMode: Text.WordWrap; color: theme.text; font { family: theme.jp; pixelSize: 17 } }
                    Text { width: parent.width; text: (root.ru && modelData.ru) ? modelData.ru : (modelData.en || ""); wrapMode: Text.WordWrap; color: theme.subtext1; font { family: theme.font; pixelSize: 13; italic: true } }
                }
            }
            Text {
                visible: root.sel && root.sel.items === 0
                text: root.ru ? "Для этой темы пока нет вопросов." : "No questions for this point yet."
                color: theme.subtext1
                font { family: theme.font; pixelSize: 13 }
            }
        }
        // drill button
        Rectangle {
            id: drill
            anchors { right: parent.right; bottom: parent.bottom; margins: 18 }
            visible: !!root.sel && root.sel.items > 0
            readonly property bool on: root.gr && root.sel && root.gr.focus === root.sel.id
            width: drillText.implicitWidth + 32; height: 38; radius: 19
            color: on ? theme.alpha(theme.accent2, 0.24) : (drillMouse.containsMouse ? theme.alpha(theme.accent, 0.28) : theme.alpha(theme.accent, 0.16))
            border.color: on ? theme.alpha(theme.accent2, 0.6) : theme.alpha(theme.accent, 0.45)
            Text {
                id: drillText
                anchors.centerIn: parent
                text: drill.on ? (root.ru ? "Остановить тренировку (Enter)" : "Stop drilling (Enter)")
                               : (root.sel && !root.sel.unlocked ? (root.ru ? "Открыть и тренировать (Enter)" : "Unlock & drill this (Enter)")
                                                                 : (root.ru ? "Тренировать только это (Enter)" : "Drill only this (Enter)"))
                color: drill.on ? theme.accent2 : theme.accent
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
            }
            MouseArea { id: drillMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.setFocus(drill.on ? null : root.sel.id) }
        }
        Text {
            anchors { left: parent.left; bottom: parent.bottom; margins: 20; bottomMargin: 28 }
            visible: !!(root.gr && root.gr.focus)
            text: (root.ru ? "Сейчас тренируется: " : "Drilling now: ") + (root.gr && root.gr.focus ? (root.pts.find(p => p.id === root.gr.focus) || {}).name : "")
            color: theme.accent2
            font { family: theme.jp; pixelSize: 13; weight: Font.DemiBold }
        }
    }
}
