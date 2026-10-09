import QtQuick

// Big page title with an optional row (chips) underneath; used as a list/grid header.
Column {
    id: t
    property var app
    property real topPad: 64
    property string title: ""
    property string subtitle: ""
    default property alias extra: slot.data
    topPadding: topPad + 8
    bottomPadding: 16
    spacing: 14
    Row {
        x: 10
        spacing: 14
        Text {
            text: t.title
            color: t.app.th.text
            font.family: t.app.th.font
            font.pixelSize: 34
            font.weight: Font.Bold
        }
        Text {
            anchors.baseline: parent.children[0].baseline
            text: t.subtitle
            color: t.app.th.sub1
            font.family: t.app.th.font
            font.pixelSize: 14
        }
    }
    Item { id: slot; x: 10; width: t.width - 20; height: childrenRect.height }
}
