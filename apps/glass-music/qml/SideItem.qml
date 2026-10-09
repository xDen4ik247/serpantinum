import QtQuick

// One row in the sidebar: a tile (icon on a gradient, or a cover) + title/subtitle.
Item {
    id: s
    property var app
    property string icon: ""
    property string title: ""
    property string subtitle: ""
    property bool active: false
    property bool collapsed: false
    property bool big: true                 // 44 px tile vs. plain icon row
    property color tint: app.th.accent
    property string coverKey: ""
    property bool glow: false
    signal clicked()
    signal rightClicked(real mx, real my)
    height: big ? 56 : 44
    width: parent ? parent.width : 200

    Rectangle {
        anchors.fill: parent
        radius: 12
        color: s.app.th.alpha(s.app.th.text, s.active ? 0.11 : (hover.hovered ? 0.06 : 0))
        Behavior on color { ColorAnimation { duration: 160 } }
    }
    Item {
        id: tile
        x: s.collapsed ? (s.width - width) / 2 : 6
        anchors.verticalCenter: parent.verticalCenter
        width: s.big ? 44 : 28
        height: width
        Rectangle {
            anchors.fill: parent
            visible: s.big && s.coverKey === ""
            radius: 10
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: s.app.th.mix(s.tint, "#000000", 0.15) }
                GradientStop { position: 1; color: s.app.th.mix(s.tint, s.app.th.base, 0.55) }
            }
        }
        Cover {
            app: s.app
            anchors.fill: parent
            visible: s.coverKey !== ""
            albumKey: s.coverKey
            radius: 10
        }
        Icon {
            app: s.app
            anchors.centerIn: parent
            visible: s.coverKey === ""
            name: s.icon
            size: s.big ? 22 : 22
            color: s.big ? "white" : (s.active ? s.app.th.text : s.app.th.sub0)
        }
        Rectangle {
            visible: s.glow
            anchors.fill: parent
            anchors.margins: -3
            radius: 13
            color: "transparent"
            border.color: s.app.th.accent
            border.width: 2
        }
    }
    Column {
        anchors { left: tile.right; leftMargin: 12; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
        visible: !s.collapsed
        opacity: s.collapsed ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 200 } }
        spacing: 2
        Text {
            width: parent.width
            text: s.title
            elide: Text.ElideRight
            color: s.active && !s.big ? s.app.th.text : (s.active ? s.app.th.accent : s.app.th.text)
            font.family: s.app.th.font
            font.pixelSize: s.big ? 14 : 15
            font.weight: s.big ? Font.Medium : Font.DemiBold
        }
        Text {
            width: parent.width
            visible: s.subtitle !== ""
            text: s.subtitle
            elide: Text.ElideRight
            color: s.app.th.sub1
            font.family: s.app.th.font
            font.pixelSize: 12
        }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => { if (m.button === Qt.RightButton) s.rightClicked(m.x, m.y); else s.clicked(); }
    }
    ToolTipLite { app: s.app; text: s.title; shown: s.collapsed && hover.hovered; below: false }
}
