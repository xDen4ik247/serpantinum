import QtQuick

// Compact horizontal tile for the top of Home (Spotify's 2×4 grid).
Item {
    id: q
    property var app
    property string coverKey: ""
    property string icon: ""
    property color tint: app.th.accent
    property string title: ""
    property bool glow: false
    property bool playing: false
    signal clicked()
    signal play()
    height: 60

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: q.app.th.alpha(q.app.th.text, hover.hovered ? 0.16 : 0.08)
        border.color: q.glow ? q.app.th.alpha(q.app.th.accent, 0.8) : q.app.th.alpha("white", 0.05)
        border.width: q.glow ? 1.5 : 1
        Behavior on color { ColorAnimation { duration: 160 } }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    MouseArea { anchors.fill: parent; onClicked: q.clicked(); onDoubleClicked: q.play() }
    Item {
        id: art
        width: 60; height: 60
        Cover { anchors.fill: parent; visible: q.coverKey !== ""; app: q.app; albumKey: q.coverKey; radius: 10 }
        Rectangle {
            anchors.fill: parent
            visible: q.coverKey === ""
            topLeftRadius: 10; bottomLeftRadius: 10
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: q.app.th.mix(q.tint, "#000000", 0.2) }
                GradientStop { position: 1; color: q.app.th.mix(q.tint, "#ffffff", 0.2) }
            }
            Icon { app: q.app; anchors.centerIn: parent; name: q.icon; size: 24; color: "white" }
        }
    }
    Text {
        anchors { left: art.right; leftMargin: 14; right: playBtn.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
        text: q.title
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.WordWrap
        color: q.app.th.text
        font.family: q.app.th.font
        font.pixelSize: 14
        font.weight: Font.Bold
    }
    IconButton {
        id: playBtn
        app: q.app; filled: true; size: 36; iconSize: 20
        icon: q.playing && q.app.playing ? "pause" : "play"
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        opacity: hover.hovered || q.playing ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        onClicked: { if (q.playing) q.app.toggle(); else q.play(); }
    }
}
