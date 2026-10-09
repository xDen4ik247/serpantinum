import QtQuick

// Right island: the queue (reorder / remove) or synced lyrics. Toggled from the bar.
Item {
    id: rp
    property var app
    visible: width > 2
    clip: true
    property string shownPanel: "queue"     // stays put while the panel slides closed
    Connections {
        target: rp.app
        function onRightPanelChanged() { if (rp.app.rightPanel !== "") rp.shownPanel = rp.app.rightPanel; }
    }

    Glass {
        anchors.fill: parent
        theme: rp.app.th
        radius: 18
        tintAlpha: 0.26
    }
    Rectangle {
        anchors.fill: parent
        radius: 18
        visible: rp.shownPanel === "lyrics"
        opacity: rp.app.curTrack ? 0.30 : 0
        gradient: Gradient {
            GradientStop { position: 0; color: rp.app.curTrack ? rp.app.colorFor(rp.app.curTrack.k) : "transparent" }
            GradientStop { position: 1; color: "transparent" }
        }
    }

    Item {
        id: inner
        width: 380
        height: parent.height
        opacity: rp.app.rightPanel !== "" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 240 } }

        Text {
            x: 20; y: 18
            text: rp.shownPanel === "lyrics" ? "Lyrics" : "Queue"
            color: rp.app.th.text
            font.family: rp.app.th.font
            font.pixelSize: 17
            font.weight: Font.Bold
        }
        Row {
            anchors { right: parent.right; rightMargin: 12 + (inner.width - rp.width); top: parent.top; topMargin: 12 }
            spacing: 2
            IconButton {
                visible: rp.shownPanel === "queue" && rp.app.queue.length > 1
                app: rp.app; icon: "clear"; size: 32; iconSize: 18; tip: "Clear queue (keeps the current song)"
                onClicked: rp.app.send({ cmd: "clearqueue" })
            }
            IconButton {
                app: rp.app; icon: "close"; size: 32; iconSize: 18; tip: "Close"
                onClicked: rp.app.rightPanel = ""
            }
        }

        QueuePanel {
            app: rp.app
            visible: rp.shownPanel === "queue"
            anchors { top: parent.top; topMargin: 56; bottom: parent.bottom }
            width: rp.width
        }
        LyricsPanel {
            app: rp.app
            visible: rp.shownPanel === "lyrics"
            anchors { top: parent.top; topMargin: 56; bottom: parent.bottom; bottomMargin: 8 }
            x: 20
            width: rp.width - 40
        }
    }
}
