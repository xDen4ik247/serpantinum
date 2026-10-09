import QtQuick

// Round translucent chip inside a glass island. Shows an icon; on hover (or
// while `armed`) it grows to reveal its label, like the bar's chips.
Item {
    id: chip

    property real u: 1
    property string icon: ""
    property string label: ""
    property string iconFont: "JetBrainsMono Nerd Font"
    property string textFont: "Google Sans"
    property color fg: "white"
    property color accent: "#80d4db"
    property color armedColor: "#ffb4ab"
    property bool armed: false          // waiting for a confirming second click
    property bool expandOnHover: true
    property bool showLabel: false      // label always visible (pill instead of circle)
    property string trailing: ""        // optional trailing glyph (e.g. a chevron)
    readonly property bool hovered: mouse.containsMouse
    readonly property bool open: showLabel || armed || (expandOnHover && hovered)
    signal clicked()

    readonly property real base: Math.round(40 * u)
    implicitHeight: base
    implicitWidth: open ? base + labelText.implicitWidth + (trailing !== "" ? trailText.implicitWidth + Math.round(8 * u) : 0) + Math.round(14 * u) : base
    width: implicitWidth
    height: implicitHeight
    Behavior on implicitWidth { NumberAnimation { duration: 450; easing.type: Easing.OutQuint } }

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: height / 2
        color: chip.armed ? Qt.rgba(chip.armedColor.r, chip.armedColor.g, chip.armedColor.b, 0.85)
             : Qt.rgba(1, 1, 1, mouse.pressed ? 0.24 : (chip.hovered ? 0.17 : 0.08))
        Behavior on color { ColorAnimation { duration: 250; easing.type: Easing.OutCubic } }
    }

    Text {
        id: glyph
        x: Math.round((chip.base - width) / 2)
        anchors.verticalCenter: parent.verticalCenter
        text: chip.icon
        font.family: chip.iconFont
        font.pixelSize: Math.round(19 * chip.u)
        color: chip.armed ? "#2a0d0a" : chip.fg
        Behavior on color { ColorAnimation { duration: 250 } }
    }

    Text {
        id: labelText
        x: chip.base - Math.round(4 * chip.u)
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        font.family: chip.textFont
        font.pixelSize: Math.round(14 * chip.u)
        font.weight: Font.DemiBold
        color: glyph.color
        opacity: chip.open ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    }

    Text {
        id: trailText
        visible: chip.trailing !== "" && labelText.visible
        x: labelText.x + labelText.implicitWidth + Math.round(6 * chip.u)
        anchors.verticalCenter: parent.verticalCenter
        text: chip.trailing
        font.family: chip.iconFont
        font.pixelSize: Math.round(14 * chip.u)
        color: glyph.color
        opacity: labelText.opacity * 0.7
    }

    // keep the label inside the chip while it grows
    clip: true

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: chip.clicked()
    }
}
