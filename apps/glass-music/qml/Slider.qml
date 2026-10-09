import QtQuick

// Spotify-like slim slider: grows and turns accent on hover, shows a knob; `live` emits
// while dragging (volume), otherwise once on release (seeking).
Item {
    id: s
    property var app
    property real value: 0               // 0..1
    property bool live: false
    readonly property bool dragging: area.pressed
    property real dragValue: 0
    readonly property real shown: dragging ? dragValue : Math.max(0, Math.min(1, value))
    signal moved(real v)
    height: 18

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: hover.hovered || s.dragging ? 6 : 4
        radius: height / 2
        color: s.app.th.alpha(s.app.th.text, 0.22)
        Behavior on height { NumberAnimation { duration: 140 } }
        Rectangle {
            width: Math.max(height, parent.width * s.shown)
            height: parent.height
            radius: height / 2
            color: hover.hovered || s.dragging ? s.app.th.accent : s.app.th.text
            Behavior on color { ColorAnimation { duration: 140 } }
        }
    }
    Rectangle {
        width: 13; height: 13; radius: 6.5
        color: "white"
        x: s.width * s.shown - width / 2
        anchors.verticalCenter: parent.verticalCenter
        visible: hover.hovered || s.dragging
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        id: area
        anchors.fill: parent
        anchors.topMargin: -4; anchors.bottomMargin: -4
        preventStealing: true
        function at(mx) { return Math.max(0, Math.min(1, mx / s.width)); }
        onPressed: m => { s.dragValue = at(m.x); if (s.live) s.moved(s.dragValue); }
        onPositionChanged: m => { if (pressed) { s.dragValue = at(m.x); if (s.live) s.moved(s.dragValue); } }
        onReleased: m => { s.dragValue = at(m.x); s.moved(s.dragValue); }
    }
    WheelHandler {
        enabled: s.live
        onWheel: e => s.moved(Math.max(0, Math.min(1, s.value + (e.angleDelta.y > 0 ? 0.05 : -0.05))))
    }
}
