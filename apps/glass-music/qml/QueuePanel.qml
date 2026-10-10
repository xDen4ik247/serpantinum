import QtQuick

// Now playing + Next up. Drag the handle to reorder (MPD moveid), × removes (deleteid).
Item {
    id: qp
    property var app
    readonly property int cur: app.status.pos
    readonly property var upNext: {
        const q = app.queue, out = [];
        for (let j = Math.max(0, cur + 1); j < q.length; j++) out.push({ e: q[j], pos: j });
        return out;
    }
    readonly property var played: {
        const q = app.queue, out = [];
        for (let j = 0; j < Math.min(cur, q.length); j++) out.push({ e: q[j], pos: j });
        return out;
    }
    // drag state
    property int dragFrom: -1        // index in upNext
    property int dragTo: -1
    property real dragY: 0

    ListView {
        id: list
        anchors.fill: parent
        model: qp.upNext.length
        boundsBehavior: Flickable.StopAtBounds
        interactive: qp.dragFrom < 0
        clip: true
        // A header whose height settles after creation leaves ListView parked on the first row;
        // until the user scrolls, keep the view at the very top.
        property bool userScrolled: false
        onMovementStarted: userScrolled = true
        Connections {
            target: list.headerItem
            function onHeightChanged() { if (!list.userScrolled) list.positionViewAtBeginning(); }
        }
        Component.onCompleted: Qt.callLater(() => { if (!list.userScrolled) list.positionViewAtBeginning(); })
        header: Column {
            width: list.width
            SectionLabel { app: qp.app; x: 20; text: "Now playing"; visible: qp.cur >= 0 && qp.cur < qp.app.queue.length }
            QueueRow {
                visible: qp.cur >= 0 && qp.cur < qp.app.queue.length
                width: parent.width
                app: qp.app
                entry: qp.cur >= 0 && qp.cur < qp.app.queue.length ? qp.app.queue[qp.cur] : null
                isCurrent: true
            }
            Item { width: 1; height: 10 }
            Item {
                width: parent.width
                height: 30
                visible: qp.upNext.length > 0
                SectionLabel { app: qp.app; x: 20; text: qp.app.smart.active ? "Next up · My Vibe · " + (qp.app.smart.styleLabel || "") : (qp.app.status.random ? "Next up · shuffled" : "Next up") }
            }
            Text {
                visible: qp.app.queue.length === 0
                x: 20; width: parent.width - 40
                topPadding: 20
                wrapMode: Text.WordWrap
                text: "The queue is empty. Double-click a song to play it with its album or list, or use Play next / Add to queue from its menu."
                color: qp.app.th.sub1
                font.family: qp.app.th.font
                font.pixelSize: 14
            }
        }
        delegate: QueueRow {
            required property int index
            width: list.width
            app: qp.app
            entry: qp.upNext[index].e
            dimmed: qp.dragFrom === index
            onDragStart: gy => { qp.dragFrom = index; qp.dragTo = index; qp.dragY = gy; }
            onDragMove: gy => {
                qp.dragY = gy;
                const p = list.mapFromItem(null, 0, gy);
                let j = list.indexAt(10, p.y + list.contentY);
                if (j < 0) j = p.y + list.contentY < list.headerItem.height ? 0 : qp.upNext.length - 1;
                qp.dragTo = j;
                // auto-scroll near the edges
                if (p.y < 40) list.contentY = Math.max(list.originY, list.contentY - 12);
                else if (p.y > list.height - 40) list.contentY = Math.min(list.contentHeight - list.height + list.originY, list.contentY + 12);
            }
            onDragEnd: {
                if (qp.dragFrom >= 0 && qp.dragTo >= 0 && qp.dragTo !== qp.dragFrom)
                    qp.app.send({ cmd: "moveid", id: qp.upNext[qp.dragFrom].e.id, to: qp.upNext[qp.dragTo].pos });
                qp.dragFrom = -1; qp.dragTo = -1;
            }
        }
        footer: Column {
            width: list.width
            visible: qp.played.length > 0
            Item { width: 1; height: 16 }
            SectionLabel { app: qp.app; x: 20; text: "Played" }
            Repeater {
                model: Math.min(15, qp.played.length)
                QueueRow {
                    required property int index
                    width: list.width
                    app: qp.app
                    entry: qp.played[qp.played.length - 1 - index].e
                    dimmed: true
                }
            }
            Item { width: 1; height: 20 }
        }
    }

    // drop indicator
    Rectangle {
        visible: qp.dragFrom >= 0 && qp.dragTo >= 0 && qp.dragTo !== qp.dragFrom
        x: 16; width: parent.width - 32; height: 2; radius: 1
        color: qp.app.th.accent
        y: {
            const it = list.itemAtIndex(qp.dragTo);
            if (!it) return -10;
            const p = it.mapToItem(qp, 0, 0);
            return qp.dragTo > qp.dragFrom ? p.y + it.height - 1 : p.y - 1;
        }
    }
}
