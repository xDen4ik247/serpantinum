import QtQuick

// Placement test: a few words and grammar points per tier, N5 upward, until you stop knowing most of them.
// "Don't know" is a fine answer (guesses are corrected for). Sets where the Rank ladder starts.
Item {
    id: root
    property var theme
    property var app
    readonly property bool ru: app.ru()
    readonly property var q: app.calibQ
    readonly property var res: app.calibDone

    // ---------------- a question
    Item {
        anchors.fill: parent
        visible: !!root.q && !root.res
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, 760)
            spacing: 16
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.q ? (root.ru ? "Тест уровня · " : "Placement test · ") + root.q.tier + " · " + root.q.n + (root.ru ? " из ~" : " of ~") + root.q.of_about : ""
                color: theme.subtext1
                font { family: theme.font; pixelSize: 13; weight: Font.DemiBold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.q ? (root.q.kind === "grammar" ? (root.ru ? "Что значит эта грамматика?" : "What does this grammar mean?")
                                                          : (root.ru ? "Что значит это слово?" : "What does this word mean?")) : ""
                color: theme.subtext0
                font { family: theme.font; pixelSize: 15 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.q ? root.q.prompt : ""
                color: theme.text
                font { family: theme.jp; pixelSize: root.q && root.q.prompt.length > 10 ? 34 : 48; weight: Font.DemiBold }
            }
            Item { width: 1; height: 6 }
            Repeater {
                model: root.q ? root.q.choices : []
                delegate: Rectangle {
                    width: parent.width; height: 48; radius: 14
                    color: area.containsMouse ? theme.alpha(theme.accent, 0.16) : theme.alpha(theme.text, 0.06)
                    border.color: theme.alpha(theme.text, 0.10)
                    Text {
                        anchors { left: parent.left; leftMargin: 18; right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
                        text: (index + 1) + "   " + modelData
                        color: theme.text
                        elide: Text.ElideRight
                        font { family: theme.font; pixelSize: 16 }
                    }
                    MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.calibAnswer(index) }
                }
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: dk.implicitWidth + 32; height: 40; radius: 20
                color: dkArea.containsMouse ? theme.alpha(theme.accent2, 0.16) : theme.alpha(theme.text, 0.05)
                border.color: theme.alpha(theme.accent2, 0.40)
                Text {
                    id: dk
                    anchors.centerIn: parent
                    text: root.ru ? "Space · не знаю" : "Space · don't know"
                    color: theme.accent2
                    font { family: theme.font; pixelSize: 14; weight: Font.DemiBold }
                }
                MouseArea { id: dkArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: app.calibAnswer(null) }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.q && root.q.last ? (root.q.last.ok === true ? "✓" : (root.q.last.ok === false ? "✗" : "–"))
                      + (root.q.last.reading ? "  " + root.q.last.reading : "") : " "
                color: root.q && root.q.last && root.q.last.ok ? theme.good : theme.subtext1
                font { family: theme.jp; pixelSize: 13 }
            }
        }
    }

    // ---------------- the result
    Item {
        anchors.fill: parent
        visible: !!root.res
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, 640)
            spacing: 14
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.res ? (root.res.rank.reached ? (root.ru ? "Ваш уровень: " : "Your level: ") + root.res.rank.reached + " ✓"
                                                        : (root.ru ? "Начинаем с N5" : "Starting at N5")) : ""
                color: theme.text
                font { family: theme.jp; pixelSize: 30; weight: Font.DemiBold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.res ? (root.ru ? "Дальше: " : "Next: ") + root.res.rank.target + " · " + Math.floor(root.res.rank.progress * 100) + "%"
                      + (root.ru ? " · по " : " · from ") + root.res.answers + (root.ru ? " ответам" : " answers") : ""
                color: theme.subtext0
                font { family: theme.font; pixelSize: 15 }
            }
            Item { width: 1; height: 6 }
            Repeater {
                model: root.res ? root.res.tiers : []
                delegate: Item {
                    width: parent.width; height: 26
                    Text {
                        id: tl
                        width: 70
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.tier === "常用" ? "常用漢字" : modelData.tier
                        color: theme.text
                        font { family: theme.jp; pixelSize: 14 }
                    }
                    Rectangle {
                        anchors { left: tl.right; right: pct.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        height: 8; radius: 4
                        color: theme.alpha(theme.text, 0.08)
                        Rectangle {
                            height: parent.height; radius: 4
                            width: parent.width * modelData.score
                            color: modelData.score >= 0.55 ? theme.good : theme.accent
                        }
                    }
                    Text {
                        id: pct
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        width: 48
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(modelData.score * 100) + "%"
                        color: theme.subtext0
                        font { family: theme.font; pixelSize: 13; features: { "tnum": 1 } }
                    }
                }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.ru ? "Это оценка: она считается, пока ваши настоящие повторения не покажут больше. Enter — к рангу."
                              : "This is an estimate: it counts until your real reviews show more. Enter to go back to Rank."
                color: theme.subtext1
                font { family: theme.font; pixelSize: 12 }
            }
        }
    }
}
