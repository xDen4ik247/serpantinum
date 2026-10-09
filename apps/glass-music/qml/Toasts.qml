import QtQuick

// Short confirmations ("Added to queue", "Rap mix · 50 tracks") above the bar.
Item {
    id: t
    property var app
    width: pill.width
    height: 44
    property string icon: ""
    property string text: ""
    Connections {
        target: t.app
        function onToast(icon, text) { t.icon = icon; t.text = text; pill.opacity = 1; pill.y = 0; hide.restart(); }
    }
    Timer { id: hide; interval: 2600; onTriggered: { pill.opacity = 0; pill.y = 10; } }
    Rectangle {
        id: pill
        width: row.implicitWidth + 36
        height: 44
        radius: 22
        y: 10
        opacity: 0
        visible: opacity > 0
        color: t.app.th.alpha(t.app.th.text, 0.94)
        Behavior on opacity { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 10
            Icon { app: t.app; name: t.icon === "queue" ? "playlist-plus" : t.icon; size: 18; color: t.app.th.base; anchors.verticalCenter: parent.verticalCenter }
            Text { text: t.text; color: t.app.th.base; font.family: t.app.th.font; font.pixelSize: 14; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
        }
    }
}
