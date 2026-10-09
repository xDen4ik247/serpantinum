import QtQuick
import "../"
import "../bar"

// One group of shortcuts ("Windows", "Music", …) as an inner glass tile.
Item {
    id: card
    property var group: ({ name: "", icon: 0xF0B23, items: [] })
    property color accent: ThemeBackend.blue
    property var tokens: []               // active search tokens (for highlighting)
    property var highlight: null          // function(label, tokens) -> rich text

    readonly property real pad: 14
    implicitHeight: col.implicitHeight + pad * 2

    GlassPill {
        anchors.fill: parent
        radius: 16
        tintAlpha: 0.20
        raised: false
    }
    // faint accent wash in the top-left corner
    Rectangle {
        anchors.fill: parent
        radius: 16
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.07) }
            GradientStop { position: 0.6; color: "transparent" }
        }
    }

    Column {
        id: col
        x: card.pad
        y: card.pad - 2
        width: card.width - card.pad * 2
        spacing: 2

        // header
        Item {
            width: parent.width
            height: 30
            Rectangle {
                id: iconBg
                width: 26; height: 26; radius: 9
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.20)
                border.width: 1
                border.color: Qt.rgba(card.accent.r, card.accent.g, card.accent.b, 0.35)
                Text {
                    anchors.centerIn: parent
                    text: String.fromCodePoint(card.group.icon)
                    color: card.accent
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: 15
                }
            }
            Text {
                anchors.left: iconBg.right
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: card.group.name
                color: ThemeBackend.text
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 15
                font.weight: Font.Bold
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: card.group.items.length
                color: ThemeBackend.overlay1
                font.family: ThemeBackend.fontFamily
                font.pixelSize: 12
                font.weight: Font.Medium
            }
        }
        Item { width: 1; height: 3 }

        Repeater {
            model: card.group.items
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: col.width
                height: Math.max(29, lab.implicitHeight + 8)

                Rectangle {   // hover wash
                    anchors.fill: parent
                    anchors.leftMargin: -6
                    anchors.rightMargin: -6
                    radius: 8
                    color: Qt.rgba(1, 1, 1, hov.hovered ? 0.06 : 0)
                    Behavior on color { ColorAnimation { duration: 160 } }
                }
                HoverHandler { id: hov }

                Text {
                    id: lab
                    anchors.left: parent.left
                    anchors.right: caps.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.highlight ? card.highlight(row.modelData.label, card.tokens) : row.modelData.label
                    textFormat: card.tokens.length ? Text.StyledText : Text.PlainText
                    color: ThemeBackend.subtext1
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    lineHeight: 0.95
                }
                Row {
                    id: caps
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4
                    Repeater {
                        model: row.modelData.caps
                        delegate: Keycap {
                            required property var modelData
                            text: modelData.t
                            modifier: modelData.mod
                            sep: modelData.sep === true
                        }
                    }
                }
            }
        }
    }
}
