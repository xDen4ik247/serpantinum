import QtQuick

// "Ask your mail" and "Catch me up": the local model's answer (streamed), citations [n] link
// to the source messages listed underneath.
Item {
    id: ap
    property var app
    property bool stacked: false
    readonly property var a: app.answer

    Glass {
        anchors.fill: parent
        theme: ap.app.th
        radius: 18
        tintAlpha: 0.20
    }

    Item {
        id: bar
        x: 12; y: 12
        width: parent.width - 24
        height: 44
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            IconButton { app: ap.app; icon: "back"; tip: "Back · Esc"; onClicked: ap.app.page = "" }
        }
        Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 2
            IconButton { visible: !!(ap.a && ap.a.loading); app: ap.app; icon: "stop"; tip: "Stop"; onClicked: ap.app.stopAi(ap.a.rid) }
            IconButton { visible: !!(ap.a && !ap.a.loading && ap.a.text); app: ap.app; icon: "copy"; tip: "Copy answer"; onClicked: ap.app.copyText(ap.a.text, "") }
            IconButton {
                visible: !!(ap.a && !ap.a.loading)
                app: ap.app; icon: "refresh"; tip: "Again"
                onClicked: ap.a.kind === "brief" ? ap.app.brief() : ap.app.ask(ap.a.q)
            }
        }
    }

    Flickable {
        id: flick
        anchors { top: bar.bottom; topMargin: 6; left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6 }
        contentHeight: col.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            x: 32
            width: Math.min(flick.width - 64, 820)
            spacing: 16
            topPadding: 14

            Row {
                spacing: 12
                Rectangle {
                    width: 44; height: 44; radius: 14
                    gradient: Gradient {
                        GradientStop { position: 0; color: ap.app.th.accent }
                        GradientStop { position: 1; color: ap.app.th.accent2 }
                    }
                    Icon { app: ap.app; anchors.centerIn: parent; name: ap.a && ap.a.kind === "brief" ? "bolt" : "sparkle"; size: 24; color: ap.app.th.onAccent }
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    width: col.width - 60
                    Text {
                        width: parent.width
                        text: ap.a ? (ap.a.kind === "brief" ? "Catch me up" : ap.a.q) : ""
                        wrapMode: Text.Wrap
                        color: ap.app.th.text
                        font.family: ap.app.th.font
                        font.pixelSize: 24
                        font.weight: Font.Bold
                    }
                    Text {
                        text: ap.a && ap.a.kind === "brief" ? "Your unread inbox, read by the local AI" : "Answered from your mail by the local AI · nothing leaves this laptop"
                        color: ap.app.th.sub1
                        font.family: ap.app.th.font
                        font.pixelSize: 12
                    }
                }
            }

            // the answer
            Rectangle {
                width: parent.width
                height: ansCol.height + 32
                radius: 18
                color: ap.app.th.alpha(ap.app.th.accent, 0.08)
                border.color: ap.app.th.alpha(ap.app.th.accent, 0.20)
                Column {
                    id: ansCol
                    x: 18; y: 16
                    width: parent.width - 36
                    spacing: 8
                    Row {
                        spacing: 8
                        visible: !!(ap.a && ap.a.loading && !ap.a.text)
                        Shimmer { app: ap.app; width: 18; height: 18 }
                        Text { text: ap.app.aiWaitText(); color: ap.app.th.sub0; font.family: ap.app.th.font; font.pixelSize: 14 }
                    }
                    TextEdit {
                        width: parent.width
                        visible: !!(ap.a && ap.a.text)
                        text: ap.a ? ap.app.mdToHtml(ap.a.text, ap.app.th.hex(ap.app.th.accent)) : ""
                        textFormat: TextEdit.RichText
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        color: ap.app.th.text
                        selectionColor: ap.app.th.alpha(ap.app.th.accent, 0.45)
                        font.family: ap.app.th.font
                        font.pixelSize: 15
                        onLinkActivated: link => {
                            const m = /^src:(\d+)$/.exec(link);
                            if (m && ap.a.sources[parseInt(m[1]) - 1]) ap.app.open(ap.a.sources[parseInt(m[1]) - 1]);
                        }
                        HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
                    }
                    Text {
                        width: parent.width
                        visible: !!(ap.a && ap.a.error)
                        wrapMode: Text.Wrap
                        text: ap.a ? ap.a.error : ""
                        color: ap.app.th.bad
                        font.family: ap.app.th.font
                        font.pixelSize: 14
                    }
                }
            }

            // sources
            SectionLabel { app: ap.app; x: 0; visible: !!(ap.a && ap.a.sources.length); text: ap.a && ap.a.kind === "brief" ? "Unread" : "Sources" }
            Repeater {
                model: ap.a ? ap.a.sources : []
                Rectangle {
                    required property var modelData
                    required property int index
                    width: col.width
                    height: 58
                    radius: 14
                    // after the answer: the sources it cited stay bright
                    opacity: ap.a && !ap.a.loading && ap.a.kind === "ask" && /\[\d+\]/.test(ap.a.text) && ap.a.text.indexOf("[" + (index + 1) + "]") < 0 ? 0.45 : 1
                    color: ap.app.th.alpha(ap.app.th.text, sHov.hovered ? 0.09 : 0.05)
                    Text {
                        id: num
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: "[" + (index + 1) + "]"
                        color: ap.app.th.accent
                        font.family: ap.app.th.font
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                    Avatar { id: sav; app: ap.app; size: 32; anchors { left: num.right; leftMargin: 10; verticalCenter: parent.verticalCenter } name: modelData.from_name; addr: modelData.from_addr }
                    Column {
                        anchors { left: sav.right; leftMargin: 12; right: sdate.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        spacing: 2
                        Text { width: parent.width; text: ap.app.sender(modelData); elide: Text.ElideRight; color: ap.app.th.text; font.family: ap.app.th.font; font.pixelSize: 13; font.weight: modelData.seen ? Font.Medium : Font.Bold }
                        Text { width: parent.width; text: modelData.subject || "(no subject)"; elide: Text.ElideRight; color: ap.app.th.sub0; font.family: ap.app.th.font; font.pixelSize: 13 }
                    }
                    Text {
                        id: sdate
                        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        text: ap.app.shortDate(modelData.date)
                        color: ap.app.th.sub1
                        font.family: ap.app.th.font
                        font.pixelSize: 12
                    }
                    HoverHandler { id: sHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: ap.app.open(modelData) }
                }
            }
        }
    }
}
