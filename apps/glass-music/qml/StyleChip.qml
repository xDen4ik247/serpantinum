import QtQuick

// A My Vibe style in the picker: glyph + name. The picked style is filled with its colour;
// the one that is playing shows a small live dot.
Item {
    id: chip
    property var app
    property var style: ({})
    property bool active: false
    property bool live: false
    signal clicked()
    readonly property color tint: app.styleColor(style.id || "default")
    height: 38
    width: row.implicitWidth + 30

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: chip.active ? chip.app.th.alpha(chip.app.th.mix(chip.tint, chip.app.th.base, 0.18), 0.92)
                           : chip.app.th.alpha(chip.app.th.text, hover.hovered ? 0.15 : 0.075)
        border.width: 1
        border.color: chip.active ? chip.app.th.alpha("white", 0.22) : chip.app.th.alpha("white", hover.hovered ? 0.10 : 0.05)
        scale: tap.pressed ? 0.95 : 1
        Behavior on color { ColorAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        Icon {
            app: chip.app
            anchors.verticalCenter: parent.verticalCenter
            name: chip.app.styleIcon(chip.style.id || "default")
            size: 17
            color: chip.active ? "white" : chip.app.th.mix(chip.tint, chip.app.th.text, 0.35)
            Behavior on color { ColorAnimation { duration: 260 } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.style.label || ""
            color: chip.active ? "white" : chip.app.th.text
            font.family: chip.app.th.font
            font.pixelSize: 14
            font.weight: chip.active ? Font.DemiBold : Font.Medium
        }
        Rectangle {
            visible: chip.live
            anchors.verticalCenter: parent.verticalCenter
            width: 6; height: 6; radius: 3
            color: chip.active ? "white" : chip.tint
        }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { id: tap; onTapped: chip.clicked() }
    ToolTipLite {
        app: chip.app
        below: true
        text: (chip.style.desc || "") + (chip.style.n !== undefined ? "  ·  " + chip.app.n(chip.style.n, "song") : "")
        shown: hover.hovered && text !== ""
    }
}
