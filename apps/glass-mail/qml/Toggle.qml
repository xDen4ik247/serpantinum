import QtQuick

// A setting row: title + description + a switch.
Item {
    id: t
    property var app
    property string title: ""
    property string desc: ""
    property bool on: false
    signal toggled(bool on)
    height: Math.max(52, col.implicitHeight + 16)
    Column {
        id: col
        anchors { left: parent.left; right: sw.left; rightMargin: 16; verticalCenter: parent.verticalCenter }
        spacing: 3
        Text { width: parent.width; text: t.title; color: t.app.th.text; font.family: t.app.th.font; font.pixelSize: 14; font.weight: Font.Medium; wrapMode: Text.WordWrap }
        Text { width: parent.width; visible: t.desc !== ""; text: t.desc; color: t.app.th.sub1; font.family: t.app.th.font; font.pixelSize: 12; wrapMode: Text.WordWrap }
    }
    Rectangle {
        id: sw
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        width: 44; height: 26; radius: 13
        color: t.on ? t.app.th.accent : t.app.th.alpha(t.app.th.text, 0.16)
        Behavior on color { ColorAnimation { duration: 180 } }
        Rectangle {
            width: 20; height: 20; radius: 10
            y: 3
            x: t.on ? parent.width - width - 3 : 3
            color: t.on ? t.app.th.onAccent : t.app.th.sub0
            Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        }
    }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: t.toggled(!t.on) }
}
