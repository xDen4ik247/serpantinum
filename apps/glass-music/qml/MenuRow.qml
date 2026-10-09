import QtQuick

Item {
    id: r
    property var app
    property string icon: ""
    property string text: ""
    property bool chevron: false
    property bool bold: false
    signal picked()
    height: 40
    Rectangle {
        anchors.fill: parent
        radius: 8
        color: r.app.th.alpha(r.app.th.text, hover.hovered ? 0.10 : 0)
    }
    Icon { id: ic; app: r.app; name: r.icon; size: 18; x: 10; anchors.verticalCenter: parent.verticalCenter; color: r.app.th.sub0 }
    Text {
        anchors { left: ic.right; leftMargin: 12; right: chev.left; verticalCenter: parent.verticalCenter }
        text: r.text
        elide: Text.ElideRight
        color: r.app.th.text
        font.family: r.app.th.font
        font.pixelSize: 14
        font.weight: r.bold ? Font.DemiBold : Font.Normal
    }
    Icon { id: chev; app: r.app; name: "chev-right"; size: 18; visible: r.chevron; anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter } color: r.app.th.sub1 }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: r.picked() }
}
