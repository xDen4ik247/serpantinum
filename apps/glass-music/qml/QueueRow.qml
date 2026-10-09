import QtQuick

// A queue entry: cover, title/artist, and on hover a remove button + drag handle.
Item {
    id: q
    property var app
    property var entry: null
    property bool isCurrent: false
    property bool dimmed: false
    signal dragStart(real gy)
    signal dragMove(real gy)
    signal dragEnd()
    readonly property var t: entry && entry.i >= 0 ? app.lib.tracks[entry.i] : null
    height: 56

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 8; anchors.rightMargin: 8
        radius: 10
        color: q.app.th.alpha(q.app.th.text, hover.hovered ? 0.07 : 0)
    }
    HoverHandler { id: hover }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: m => { if (m.button === Qt.LeftButton && q.entry) q.app.send({ cmd: "playid", id: q.entry.id }); }
        onClicked: m => {
            if (m.button === Qt.RightButton && q.entry) {
                const p = mapToItem(q.app.rootItem, m.x, m.y);
                q.app.queueMenu(q.entry, q.app.rootItem, p.x, p.y);
            }
        }
    }
    Cover {
        id: cov
        x: 16
        anchors.verticalCenter: parent.verticalCenter
        width: 42; height: 42; radius: 6
        app: q.app
        albumKey: q.t ? q.t.k : ""
        dim: hover.hovered ? 0.45 : 0
        Icon {
            anchors.centerIn: parent
            visible: hover.hovered
            app: q.app
            name: q.isCurrent ? (q.app.playing ? "pause" : "play") : "play"
            size: 22
            color: "white"
            TapHandler { onTapped: { if (q.isCurrent) q.app.toggle(); else if (q.entry) q.app.send({ cmd: "playid", id: q.entry.id }); } }
        }
    }
    Column {
        anchors { left: cov.right; leftMargin: 12; right: tools.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
        spacing: 2
        Text {
            width: parent.width
            text: q.t ? q.t.t : (q.entry ? q.entry.t || "" : "")
            elide: Text.ElideRight
            color: q.isCurrent ? q.app.th.accent : q.app.th.text
            opacity: q.dimmed ? 0.6 : 1
            font.family: q.app.th.font
            font.pixelSize: 14
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            text: q.t ? q.t.a : (q.entry ? q.entry.a || "" : "")
            elide: Text.ElideRight
            color: q.app.th.sub1
            opacity: q.dimmed ? 0.6 : 1
            font.family: q.app.th.font
            font.pixelSize: 12
        }
    }
    Row {
        id: tools
        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
        opacity: hover.hovered && !q.isCurrent ? 1 : 0
        width: q.isCurrent ? 0 : implicitWidth
        IconButton {
            app: q.app; icon: "close"; size: 28; iconSize: 16; tip: "Remove"
            onClicked: if (q.entry) q.app.send({ cmd: "deleteid", id: q.entry.id })
        }
        Item {
            width: 24; height: 28
            Icon { anchors.centerIn: parent; app: q.app; name: "drag"; size: 18; color: q.app.th.sub1 }
            MouseArea {
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                preventStealing: true
                onPressed: m => q.dragStart(mapToItem(null, m.x, m.y).y)
                onPositionChanged: m => { if (pressed) q.dragMove(mapToItem(null, m.x, m.y).y); }
                onReleased: q.dragEnd()
            }
        }
    }
}
