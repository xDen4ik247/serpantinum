import QtQuick

// A titled row of cards that fits the width (no sideways scrolling): as many columns as
// fit at >= minCard px; "Show all" opens the full page when there are more.
Column {
    id: shelf
    property var app
    property string title: ""
    property string subtitle: ""
    property int count: 0
    property real minCard: 176
    property string showAllPage: ""
    property string showAllArg: ""
    property Component delegate
    property int rows: 1
    readonly property int cols: Math.max(2, Math.floor((width + 8) / (minCard + 8)))
    readonly property real cardW: (width - (cols - 1) * 8) / cols
    readonly property int shown: Math.min(count, cols * rows)
    spacing: 8
    visible: count > 0

    Item {
        width: shelf.width
        height: 40
        Column {
            anchors.verticalCenter: parent.verticalCenter
            x: 10
            Text {
                text: shelf.title
                color: shelf.app.th.text
                font.family: shelf.app.th.font
                font.pixelSize: 24
                font.weight: Font.Bold
            }
            Text {
                visible: shelf.subtitle !== ""
                text: shelf.subtitle
                color: shelf.app.th.sub1
                font.family: shelf.app.th.font
                font.pixelSize: 13
            }
        }
        LinkText {
            app: shelf.app
            visible: shelf.showAllPage !== "" && shelf.count > shelf.shown
            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
            text: "Show all"
            color: hovered ? shelf.app.th.text : shelf.app.th.sub1
            font.pixelSize: 14
            font.weight: Font.DemiBold
            onClicked: shelf.app.go(shelf.showAllPage, shelf.showAllArg)
        }
    }
    Flow {
        width: shelf.width
        spacing: 8
        Repeater {
            model: shelf.shown
            delegate: shelf.delegate
        }
    }
}
