import QtQuick

// One sidebar row: icon, name, unread badge.
Item {
    id: s
    property var app
    property string icon: "folder"
    property string title: ""
    property int count: 0
    property bool strong: false          // inbox with unread mail: bold name, accent badge
    property bool active: false
    property bool collapsed: false
    property int depth: 0
    property color tint: app.th.accent
    signal clicked()
    width: parent ? parent.width : 200
    height: visible ? 40 : 0

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: s.active ? s.app.th.alpha(s.tint, 0.20) : s.app.th.alpha(s.app.th.text, hover.hovered ? 0.06 : 0)
        Behavior on color { ColorAnimation { duration: 160 } }
    }
    Icon {
        id: ic
        app: s.app
        x: s.collapsed ? (s.width - width) / 2 : 14 + Math.min(s.depth, 3) * 14
        anchors.verticalCenter: parent.verticalCenter
        name: s.icon
        size: 20
        color: s.active ? s.tint : (s.strong ? s.app.th.text : s.app.th.sub0)
    }
    Text {
        visible: !s.collapsed
        anchors { left: ic.right; leftMargin: 14; right: badge.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
        text: s.title
        elide: Text.ElideRight
        color: s.active ? s.app.th.text : (s.strong ? s.app.th.text : s.app.th.sub0)
        font.family: s.app.th.font
        font.pixelSize: 14
        font.weight: s.active || s.strong ? Font.DemiBold : Font.Normal
    }
    Rectangle {
        id: badge
        visible: s.count > 0 && !s.collapsed
        anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
        height: 22
        width: Math.max(22, num.implicitWidth + 14)
        radius: 11
        color: s.strong ? s.tint : s.app.th.alpha(s.app.th.text, 0.10)
        Text {
            id: num
            anchors.centerIn: parent
            text: s.count > 999 ? "999+" : s.count
            color: s.strong ? s.app.th.onAccent : s.app.th.sub0
            font.family: s.app.th.font
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
    }
    // collapsed: a dot instead of the count
    Rectangle {
        visible: s.collapsed && s.count > 0 && s.strong
        width: 8; height: 8; radius: 4
        color: s.tint
        x: ic.x + ic.width - 2; y: ic.y
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: s.clicked() }
    ToolTipLite { app: s.app; text: s.title + (s.count ? " · " + s.count : ""); shown: s.collapsed && hover.hovered; below: false }
}
