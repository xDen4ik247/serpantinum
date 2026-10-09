import QtQuick

// Filter / sort chip.
Rectangle {
    id: chip
    property var app
    property string text: ""
    property bool active: false
    signal clicked()
    height: 32
    width: label.implicitWidth + 28
    radius: 16
    color: active ? app.th.text : app.th.alpha(app.th.text, hover.hovered ? 0.16 : 0.09)
    Behavior on color { ColorAnimation { duration: 160 } }
    Text {
        id: label
        anchors.centerIn: parent
        text: chip.text
        color: chip.active ? chip.app.th.base : chip.app.th.text
        font.family: chip.app.th.font
        font.pixelSize: 13
        font.weight: Font.Medium
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: chip.clicked() }
}
