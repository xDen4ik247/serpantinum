import QtQuick

// An attachment: icon by type, name, size. Click opens it, the arrow saves it to ~/Downloads.
Rectangle {
    id: c
    property var app
    property var a: ({})
    width: Math.min(300, Math.max(200, nameT.implicitWidth + 110))
    height: 56
    radius: 14
    color: app.th.alpha(app.th.text, hov.hovered ? 0.11 : 0.07)
    border.color: app.th.alpha("white", 0.06)
    Behavior on color { ColorAnimation { duration: 140 } }
    Rectangle {
        id: tile
        x: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 40; height: 40; radius: 10
        color: c.app.th.alpha(({ pdf: "#e57373", image: "#81c784", sheet: "#66bb6a", doc: "#64b5f6", slides: "#ffb74d", archive: "#bcaaa4", calendar: "#ba68c8" })[c.a.kind] || c.app.th.accent, 0.22)
        Icon { app: c.app; anchors.centerIn: parent; name: c.app.attIcon(c.a.kind); size: 22; color: c.app.th.text }
    }
    Column {
        anchors { left: tile.right; leftMargin: 10; right: save.left; rightMargin: 4; verticalCenter: parent.verticalCenter }
        spacing: 2
        Text { id: nameT; width: parent.width; text: c.a.name || ""; elide: Text.ElideMiddle; color: c.app.th.text; font.family: c.app.th.font; font.pixelSize: 13; font.weight: Font.Medium }
        Text { text: c.app.size(c.a.size || 0); color: c.app.th.sub1; font.family: c.app.th.font; font.pixelSize: 12 }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: c.app.attOpen(c.a) }
    HoverHandler { id: hov }
    IconButton {
        id: save
        app: c.app; icon: "download"; size: 34; iconSize: 19; tip: "Save to Downloads"
        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
        onClicked: c.app.attSave(c.a)
    }
}
