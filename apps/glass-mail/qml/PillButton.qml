import QtQuick

// Text button with an optional icon: "filled" = accent (Send, Compose), else a soft glass pill.
Rectangle {
    id: b
    property var app
    property string icon: ""
    property string text: ""
    property bool filled: false
    property bool danger: false
    property bool enabledState: true
    property real h: 40
    property real fontSize: 14
    signal clicked()
    height: h
    width: row.implicitWidth + (text ? 32 : 20)
    radius: h / 2
    opacity: enabledState ? 1 : 0.45
    color: filled ? (hover.hovered ? Qt.lighter(app.th.accent, 1.08) : app.th.accent)
                  : app.th.alpha(danger ? app.th.bad : app.th.text, hover.hovered ? 0.16 : 0.09)
    scale: tap.pressed ? 0.96 : 1
    Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    Behavior on color { ColorAnimation { duration: 160 } }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8
        Icon {
            app: b.app
            visible: b.icon !== ""
            name: b.icon
            size: 18
            color: b.filled ? b.app.th.onAccent : (b.danger ? b.app.th.bad : b.app.th.text)
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: b.text !== ""
            text: b.text
            color: b.filled ? b.app.th.onAccent : (b.danger ? b.app.th.bad : b.app.th.text)
            font.family: b.app.th.font
            font.pixelSize: b.fontSize
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    HoverHandler { id: hover; cursorShape: b.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { id: tap; enabled: b.enabledState; onTapped: b.clicked() }
}
