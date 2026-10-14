import QtQuick

// The reader's AI card: a summary, to-dos, dates (→ calendar) and smart replies that the AI
// turns into a full reply. Runs on the local model; results are cached per message.
Rectangle {
    id: card
    property var app
    readonly property var an: app.analysis
    readonly property var res: an && an.result ? an.result : null
    readonly property bool mine: !!(an && app.cur && an.key === app.key(app.cur))
    width: parent ? parent.width : 400
    height: mine ? col.height + 28 : startRow.height
    radius: 18
    color: mine ? app.th.alpha(app.th.accent, 0.08) : "transparent"
    border.color: mine ? app.th.alpha(app.th.accent, 0.22) : "transparent"
    visible: app.aiOn && !!app.msg && !app.msg.error

    // not analysed yet: one quiet pill
    Row {
        id: startRow
        visible: !card.mine
        spacing: 8
        PillButton { app: card.app; icon: "sparkle"; text: "Summarize & suggest replies"; h: 36; fontSize: 13; onClicked: card.app.analyze(false, false) }
    }

    Column {
        id: col
        visible: card.mine
        x: 18; y: 14
        width: parent.width - 36
        spacing: 10

        Row {
            spacing: 8
            width: parent.width
            Icon { app: card.app; name: "sparkle"; size: 17; color: card.app.th.accent; anchors.verticalCenter: parent.verticalCenter; visible: !(card.an && card.an.loading) }
            Shimmer { app: card.app; width: 17; height: 17; anchors.verticalCenter: parent.verticalCenter; visible: !!(card.an && card.an.loading) }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: card.an && card.an.loading ? card.app.aiWaitText() : card.an && card.an.error ? "AI unavailable" : "Summary"
                color: card.app.th.accent
                font.family: card.app.th.font
                font.pixelSize: 13
                font.weight: Font.DemiBold
                font.letterSpacing: 0.3
            }
        }
        Text {
            width: parent.width
            visible: !!(card.an && card.an.error)
            wrapMode: Text.Wrap
            text: card.an ? card.an.error || "" : ""
            color: card.app.th.sub0
            font.family: card.app.th.font
            font.pixelSize: 13
        }
        // loading skeleton
        Column {
            visible: !!(card.an && card.an.loading)
            spacing: 7
            Repeater {
                model: [0.92, 0.75, 0.55]
                Rectangle {
                    required property var modelData
                    width: col.width * modelData; height: 11; radius: 5.5
                    color: card.app.th.alpha(card.app.th.text, 0.08)
                    SequentialAnimation on opacity { loops: Animation.Infinite; NumberAnimation { to: 0.4; duration: 650 } NumberAnimation { to: 1; duration: 650 } }
                }
            }
        }
        Text {
            width: parent.width
            visible: !!card.res
            text: card.res ? card.res.summary : ""
            wrapMode: Text.Wrap
            color: card.app.th.text
            font.family: card.app.th.font
            font.pixelSize: 15
            lineHeight: 1.12
        }
        // to-dos
        Repeater {
            model: card.res ? card.res.actions : []
            Row {
                required property var modelData
                spacing: 8
                width: col.width
                Icon { app: card.app; name: "check-circle"; size: 16; color: card.app.th.accent2; y: 1 }
                Text { width: parent.width - 30; text: modelData; wrapMode: Text.Wrap; color: card.app.th.sub0; font.family: card.app.th.font; font.pixelSize: 14 }
            }
        }
        // dates → calendar
        Flow {
            width: parent.width
            spacing: 6
            visible: !!(card.res && card.res.events && card.res.events.length)
            Repeater {
                model: card.res ? card.res.events : []
                Rectangle {
                    required property var modelData
                    height: 34
                    width: evRow.implicitWidth + 24
                    radius: 17
                    color: card.app.th.alpha(card.app.th.accent2, evHov.hovered ? 0.24 : 0.14)
                    Row {
                        id: evRow
                        anchors.centerIn: parent
                        spacing: 7
                        Icon { app: card.app; name: "calendar-plus"; size: 16; color: card.app.th.accent2; anchors.verticalCenter: parent.verticalCenter }
                        Text { text: modelData.title + " · " + modelData.when; color: card.app.th.text; font.family: card.app.th.font; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                    }
                    HoverHandler { id: evHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: card.app.addEvent(modelData) }
                    ToolTipLite { app: card.app; text: "Add to calendar"; shown: evHov.hovered }
                }
            }
        }
        // smart replies
        Flow {
            width: parent.width
            spacing: 6
            visible: !!(card.res && card.res.replies && card.res.replies.length)
            topPadding: 2
            Repeater {
                model: card.res ? card.res.replies : []
                Rectangle {
                    required property var modelData
                    height: 34
                    width: Math.min(col.width, rTxt.implicitWidth + 44)
                    radius: 17
                    color: card.app.th.alpha(card.app.th.text, rHov.hovered ? 0.16 : 0.09)
                    Icon { id: rIc; app: card.app; name: "reply"; size: 15; color: card.app.th.sub0; x: 12; anchors.verticalCenter: parent.verticalCenter }
                    Text {
                        id: rTxt
                        anchors { left: rIc.right; leftMargin: 7; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: modelData
                        elide: Text.ElideRight
                        color: card.app.th.text
                        font.family: card.app.th.font
                        font.pixelSize: 13
                    }
                    HoverHandler { id: rHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: card.app.aiReplyWith(modelData) }
                    ToolTipLite { app: card.app; text: "AI writes this reply for you"; shown: rHov.hovered }
                }
            }
        }
    }
    MouseArea {
        visible: card.mine && !!card.res
        anchors { right: parent.right; top: parent.top; margins: 8 }
        width: 26; height: 26
        cursorShape: Qt.PointingHandCursor
        onClicked: card.app.analyze(true, false)
        Icon { app: card.app; anchors.centerIn: parent; name: "refresh"; size: 15; color: card.app.th.sub1 }
    }
}
