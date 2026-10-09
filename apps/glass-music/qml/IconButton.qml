import QtQuick

// Round icon button: soft hover disc, press scale, optional "active" accent + dot.
Item {
    id: b
    property var app
    property string icon: ""
    property real size: 36
    property real iconSize: 20
    property bool active: false
    property bool dot: false
    property bool filled: false          // solid accent disc (main play button)
    property color fg: filled ? app.th.onAccent : (active ? app.th.accent : (hover.hovered ? app.th.text : app.th.sub0))
    property string tip: ""
    property bool enabledState: true
    signal clicked(var mouse)
    signal rightClicked(var mouse)
    width: size
    height: size
    opacity: enabledState ? 1 : 0.4

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: b.filled ? (hover.hovered ? Qt.lighter(b.app.th.accent, 1.08) : b.app.th.accent)
                        : b.app.th.alpha(b.app.th.text, hover.hovered ? 0.10 : 0)
        scale: area.pressed ? 0.92 : (b.filled && hover.hovered ? 1.05 : 1)
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 180 } }
    }
    Icon {
        app: b.app
        anchors.centerIn: parent
        name: b.icon
        size: b.iconSize
        color: b.fg
        scale: area.pressed ? 0.9 : 1
        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
    Rectangle {
        visible: b.dot && b.active
        width: 4; height: 4; radius: 2
        color: b.app.th.accent
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 1 }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        id: area
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        enabled: b.enabledState
        onClicked: m => { if (m.button === Qt.RightButton) b.rightClicked(m); else b.clicked(m); }
    }
    ToolTipLite { app: b.app; text: b.tip; shown: hover.hovered && b.tip !== "" }
}
