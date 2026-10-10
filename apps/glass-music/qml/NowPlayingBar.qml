import QtQuick
import QtQuick.Effects

// Bottom now-playing island: cover + title/artist (→ album / artist) + ♥ · transport with
// shuffle / repeat and a seekable progress line · My Vibe, lyrics, queue, volume.
Item {
    id: bar
    property var app
    readonly property var t: app.curTrack
    readonly property real dur: app.status.duration || (t ? t.d : 0)
    readonly property bool compact: width < 900

    Glass {
        anchors.fill: parent
        theme: bar.app.th
        radius: 18
        tintAlpha: 0.30
    }

    // ---- left: track
    Item {
        id: left
        x: 12
        width: bar.compact ? bar.width * 0.34 : Math.min(bar.width * 0.3, 380)
        height: parent.height
        Item {
            id: art
            width: 60; height: 60
            anchors.verticalCenter: parent.verticalCenter
            RectangularShadow { anchors.fill: parent; radius: 8; blur: 16; offset.y: 4; color: Qt.rgba(0, 0, 0, 0.35); visible: !!bar.t }
            Cover { anchors.fill: parent; app: bar.app; radius: 8; albumKey: bar.t ? bar.t.k : "" }
            TapHandler { onTapped: if (bar.t) bar.app.goAlbum(bar.t.k) }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
        }
        Column {
            anchors { left: art.right; leftMargin: 14; right: likeBtn.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
            spacing: 3
            LinkText {
                app: bar.app
                width: Math.min(implicitWidth, parent.width)
                text: bar.t ? bar.t.t : (bar.app.status.title || (bar.app.ready ? "Nothing playing" : ""))
                color: bar.app.th.text
                font.pixelSize: 15
                font.weight: Font.Medium
                onClicked: if (bar.t) bar.app.goAlbum(bar.t.k)
            }
            LinkText {
                app: bar.app
                width: Math.min(implicitWidth, parent.width)
                text: bar.t ? bar.t.a : (bar.app.status.artist || "")
                color: hovered ? bar.app.th.text : bar.app.th.sub1
                font.pixelSize: 13
                onClicked: if (bar.t) bar.app.goArtist(bar.t.p)
            }
        }
        IconButton {
            id: likeBtn
            app: bar.app
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: !!bar.t
            size: 34; iconSize: 20
            icon: bar.app.isLiked(bar.app.curIdx) ? "star" : "star-outline"
            active: bar.app.isLiked(bar.app.curIdx)
            tip: active ? "Favourite · click to remove" : "Add to Favourites (My Vibe plays it more often)"
            onClicked: bar.app.toggleLike(bar.app.curIdx)
        }
    }

    // ---- centre: transport + progress
    Column {
        id: centre
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(bar.width * (bar.compact ? 0.36 : 0.4), 720)
        spacing: 2
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: bar.compact ? 4 : 12
            IconButton {
                app: bar.app; icon: "shuffle"; size: 34; iconSize: 20; dot: true
                active: bar.app.status.random
                tip: active ? "Disable shuffle" : "Enable shuffle"
                anchors.verticalCenter: parent.verticalCenter
                onClicked: bar.app.toggleShuffle()
            }
            IconButton {
                app: bar.app; icon: "prev"; size: 36; iconSize: 24; tip: "Previous"
                anchors.verticalCenter: parent.verticalCenter
                onClicked: bar.app.prev()
            }
            IconButton {
                app: bar.app; filled: true; size: 40; iconSize: 24
                icon: bar.app.playing ? "pause" : "play"
                tip: bar.app.playing ? "Pause" : "Play"
                onClicked: bar.app.toggle()
            }
            IconButton {
                app: bar.app; icon: "next"; size: 36; iconSize: 24; tip: "Next"
                anchors.verticalCenter: parent.verticalCenter
                onClicked: bar.app.next()
            }
            IconButton {
                app: bar.app; size: 34; iconSize: 20; dot: true
                icon: bar.app.status.repeat && bar.app.status.single ? "repeat-one" : "repeat"
                active: bar.app.status.repeat
                tip: !bar.app.status.repeat ? "Enable repeat" : (bar.app.status.single ? "Disable repeat" : "Enable repeat one")
                anchors.verticalCenter: parent.verticalCenter
                onClicked: bar.app.cycleRepeat()
            }
        }
        Row {
            width: parent.width
            spacing: 8
            Text {
                width: 42
                horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
                text: bar.app.fmt(seek.dragging ? seek.dragValue * bar.dur : bar.app.position)
                color: bar.app.th.sub1
                font.family: bar.app.th.font
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
            Slider {
                id: seek
                app: bar.app
                width: parent.width - 100
                anchors.verticalCenter: parent.verticalCenter
                value: bar.dur > 0 ? bar.app.position / bar.dur : 0
                onMoved: v => { if (bar.dur > 0) bar.app.seek(v * bar.dur); }
            }
            Text {
                width: 42
                anchors.verticalCenter: parent.verticalCenter
                text: bar.app.fmt(bar.dur)
                color: bar.app.th.sub1
                font.family: bar.app.th.font
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }
    }

    // ---- right: smart / lyrics / queue / volume
    Row {
        id: right
        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
        spacing: 2
        Item {
            width: smartBtn.width + (smartLabel.visible ? smartLabel.implicitWidth + 6 : 0)
            height: 36
            anchors.verticalCenter: parent.verticalCenter
            IconButton {
                id: smartBtn
                app: bar.app; size: 34; iconSize: 20; dot: true
                icon: active ? bar.app.styleIcon(bar.app.smart.style || "default") : "vibe"
                active: !!bar.app.smart.active
                tip: active ? "My Vibe · " + (bar.app.smart.styleLabel || "") + " · click: re-roll · right-click: off" : "Play My Vibe · " + bar.app.styleLabel(bar.app.curStyle)
                onClicked: bar.app.smartStart(true)
                onRightClicked: bar.app.send({ cmd: "smart", action: "stop" })
            }
            Text {
                id: smartLabel
                visible: !!bar.app.smart.active && !bar.compact && bar.width > 1250
                anchors { left: smartBtn.right; leftMargin: 2; verticalCenter: parent.verticalCenter }
                text: bar.app.smart.styleLabel || bar.app.smart.vibeLabel || ""
                color: bar.app.th.accent
                font.family: bar.app.th.font
                font.pixelSize: 12
                font.weight: Font.Medium
            }
        }
        IconButton {
            app: bar.app; icon: "lyrics"; size: 34; iconSize: 20; dot: true
            anchors.verticalCenter: parent.verticalCenter
            active: bar.app.rightPanel === "lyrics"
            enabledState: true
            tip: "Lyrics (Ctrl+L)"
            onClicked: bar.app.togglePanel("lyrics")
        }
        IconButton {
            app: bar.app; icon: "queue"; size: 34; iconSize: 20; dot: true
            anchors.verticalCenter: parent.verticalCenter
            active: bar.app.rightPanel === "queue"
            tip: "Queue"
            onClicked: bar.app.togglePanel("queue")
        }
        IconButton {
            app: bar.app; size: 34; iconSize: 20
            anchors.verticalCenter: parent.verticalCenter
            property int lastVol: 60
            icon: bar.app.status.volume <= 0 ? "vol-off" : bar.app.status.volume < 34 ? "vol-low" : bar.app.status.volume < 67 ? "vol-mid" : "vol-high"
            tip: bar.app.status.volume <= 0 ? "Unmute" : "Mute"
            onClicked: {
                if (bar.app.status.volume > 0) { lastVol = bar.app.status.volume; bar.app.setVolume(0); }
                else bar.app.setVolume(lastVol || 60);
            }
        }
        Slider {
            app: bar.app
            live: true
            visible: bar.width > 760
            width: bar.compact ? 80 : 110
            anchors.verticalCenter: parent.verticalCenter
            value: Math.max(0, bar.app.status.volume) / 100
            onMoved: v => bar.app.setVolume(v * 100)
        }
    }
}
