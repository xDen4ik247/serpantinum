import QtQuick

// Short confirmations ("Archived", "Message sent") with an optional action (Undo).
Item {
    id: t
    property var app
    width: pill.width
    height: 48
    property string icon: ""
    property string text: ""
    property string action: ""
    Connections {
        target: t.app
        function onToast(icon, text, action) {
            t.icon = icon; t.text = text; t.action = action;
            pill.opacity = 1; pill.y = 0;
            hide.interval = action ? 5200 : 2800;
            hide.restart();
        }
    }
    Timer { id: hide; interval: 2800; onTriggered: { pill.opacity = 0; pill.y = 10; t.action = ""; } }
    Rectangle {
        id: pill
        width: row.implicitWidth + 36
        height: 48
        radius: 24
        y: 10
        opacity: 0
        visible: opacity > 0
        color: t.app.th.alpha(t.app.th.text, 0.95)
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 10
            Icon { app: t.app; name: t.icon; size: 18; color: t.app.th.base; anchors.verticalCenter: parent.verticalCenter }
            Text { text: t.text; color: t.app.th.base; font.family: t.app.th.font; font.pixelSize: 14; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
            Rectangle {
                visible: t.action !== ""
                width: act.implicitWidth + 24
                height: 32
                radius: 16
                anchors.verticalCenter: parent.verticalCenter
                color: t.app.th.alpha(t.app.th.base, actHov.hovered ? 0.18 : 0.10)
                Text {
                    id: act
                    anchors.centerIn: parent
                    text: t.action
                    color: t.app.th.deep
                    font.family: t.app.th.font
                    font.pixelSize: 14
                    font.weight: Font.Bold
                }
                HoverHandler { id: actHov; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        if (t.app.pendingSend) t.app.undoSend(); else t.app.undo();
                        t.action = "";
                        hide.interval = 1200; hide.restart();
                    }
                }
            }
        }
    }
}
