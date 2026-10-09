import QtQuick
import "../"

// Slim seek/volume bar: a thin rounded track that thickens on hover, with a knob that
// appears while hovering or dragging. Click or drag to pick a value; `moved` fires while
// dragging and `committed` once on release (seeking only commits, so MPD isn't flooded).
Item {
    id: root

    property real value: 0
    property real from: 0
    property real to: 1
    property bool interactive: true
    property real trackHeight: 4
    property real hoverTrackHeight: 6
    property real knobSize: 12
    property color trackColor: Qt.alpha(ThemeBackend.text, 0.16)
    property color fillColor: ThemeBackend.mauve
    property color knobColor: ThemeBackend.text

    signal moved(real value)
    signal committed(real value)

    readonly property bool dragging: mouse.pressed
    readonly property bool hovered: mouse.containsMouse
    property real dragValue: 0
    // After a release the bar keeps showing the picked value until the player catches up.
    property bool holding: false
    Timer { id: holdTimer; interval: 900; onTriggered: root.holding = false }
    onValueChanged: if (holding && Math.abs(value - dragValue) <= Math.max(0.01, (to - from) * 0.01)) holding = false
    readonly property real shownValue: (dragging || holding) ? dragValue : value
    readonly property real frac: to > from ? Math.max(0, Math.min(1, (shownValue - from) / (to - from))) : 0

    implicitHeight: Math.max(knobSize, hoverTrackHeight) + 6

    function valueAt(x) {
        let f = Math.max(0, Math.min(1, x / Math.max(1, width)));
        return from + f * (to - from);
    }

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: (root.hovered || root.dragging) && root.interactive ? root.hoverTrackHeight : root.trackHeight
        radius: height / 2
        color: root.trackColor
        Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        Rectangle {
            height: parent.height
            radius: height / 2
            width: Math.max(height, parent.width * root.frac)
            color: root.fillColor
            Behavior on color { ColorAnimation { duration: 300 } }
        }
    }

    Rectangle {
        id: knob
        width: root.knobSize
        height: root.knobSize
        radius: width / 2
        color: root.knobColor
        anchors.verticalCenter: parent.verticalCenter
        x: Math.round(root.frac * root.width - width / 2)
        scale: root.interactive && (root.hovered || root.dragging) ? (root.dragging ? 1.15 : 1.0) : 0.0
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        enabled: root.interactive
        hoverEnabled: true
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        preventStealing: true
        onPressed: (m) => { root.dragValue = root.valueAt(m.x); root.moved(root.dragValue); }
        onPositionChanged: (m) => { if (pressed) { root.dragValue = root.valueAt(m.x); root.moved(root.dragValue); } }
        onReleased: (m) => {
            root.dragValue = root.valueAt(m.x);
            root.holding = true;
            holdTimer.restart();
            root.committed(root.dragValue);
        }
    }
}
