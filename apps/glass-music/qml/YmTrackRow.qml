import QtQuick

// A Yandex Music song row (search / album / artist / playlist pages). Same layout as TrackRow;
// the status column shows where the file is (in ~/Music, cached in temp, or downloading).
// Playing always downloads first (yandex-music-downloader), then MPD plays the local file.
Item {
    id: row
    property var app
    property var t: null                  // track object from the Yandex worker
    property var ctx: []                  // the list this row belongs to (becomes the queue)
    property int at: 0
    property string num: ""
    property bool showAlbum: true
    readonly property string state_: t ? app.ymState(t) : ""
    readonly property string uri: t ? app.ymUri(t) : ""
    readonly property bool current: uri !== "" && app.status.file === uri
    readonly property bool liked: !!t && app.ymIsLiked(t)
    readonly property bool wideAlbum: showAlbum && width > 620
    readonly property bool ok: !t || t.ok !== false
    height: 58
    opacity: ok ? 1 : 0.45

    function play() { if (ok) app.ymPlay(ctx && ctx.length ? ctx : [t], ctx && ctx.length ? at : 0); }

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: row.app.th.alpha(row.app.th.text, hover.hovered ? 0.07 : 0)
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    HoverHandler { id: hover }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: row.app.rootItem.forceActiveFocus()
        onClicked: m => {
            if (row.t && m.button === Qt.RightButton) {
                const p = mapToItem(row.app.rootItem, m.x, m.y);
                row.app.ymTrackMenu(row.t, row.ctx, row.at, row.app.rootItem, p.x, p.y);
            }
        }
        onDoubleClicked: m => { if (m.button === Qt.LeftButton) row.play(); }
    }

    Item {
        id: numBox
        x: 4
        width: 40
        height: parent.height
        Text {
            anchors.centerIn: parent
            visible: !hover.hovered && !row.current && row.state_ !== "busy"
            text: row.num
            color: row.app.th.sub1
            font.family: row.app.th.font
            font.pixelSize: 14
            font.features: { "tnum": 1 }
        }
        Icon {
            anchors.centerIn: parent
            visible: row.state_ === "busy" && !hover.hovered
            app: row.app
            name: "download"
            size: 18
            color: row.app.th.accent
            SequentialAnimation on opacity {
                running: row.state_ === "busy"
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
            }
        }
        Icon {
            anchors.centerIn: parent
            visible: row.current && !hover.hovered && row.state_ !== "busy"
            app: row.app
            name: row.app.playing ? "waveform" : "pause"
            size: 18
            color: row.app.th.accent
        }
        IconButton {
            anchors.centerIn: parent
            visible: hover.hovered && row.ok
            app: row.app
            size: 32; iconSize: 20
            icon: row.current && row.app.playing ? "pause" : "play"
            fg: row.app.th.text
            onClicked: { if (row.current) row.app.toggle(); else row.play(); }
        }
    }

    Cover {
        id: cov
        app: row.app
        x: numBox.x + numBox.width + 6
        anchors.verticalCenter: parent.verticalCenter
        width: 42; height: 42
        radius: 6
        url: row.t ? row.t.c : ""
    }

    Column {
        id: titleCol
        anchors.verticalCenter: parent.verticalCenter
        x: cov.x + cov.width + 12
        width: (row.wideAlbum ? albumCol.x : where.x) - x - 16
        spacing: 3
        Text {
            width: parent.width
            text: row.t ? row.t.t : ""
            elide: Text.ElideRight
            color: row.current ? row.app.th.accent : row.app.th.text
            font.family: row.app.th.font
            font.pixelSize: 15
            font.weight: Font.Medium
        }
        Row {
            width: parent.width
            spacing: 4
            Text {
                id: lrcBadge
                visible: !!row.t && row.t.lrc
                text: "LRC"
                color: row.app.th.base
                font.family: row.app.th.font
                font.pixelSize: 9
                font.weight: Font.Bold
                topPadding: 1; bottomPadding: 1; leftPadding: 3; rightPadding: 3
                anchors.verticalCenter: parent.verticalCenter
                Rectangle { anchors.fill: parent; radius: 3; color: row.app.th.alpha(row.app.th.sub0, 0.75); z: -1 }
            }
            LinkText {
                app: row.app
                width: Math.min(implicitWidth, parent.width - (lrcBadge.visible ? lrcBadge.width + 4 : 0))
                text: row.t ? (row.t.ok === false ? "Not available · " : "") + row.t.a : ""
                onClicked: if (row.t && row.t.ar && row.t.ar.length) row.app.ymOpen("artist", row.t.ar[0].id)
                color: hovered ? row.app.th.text : row.app.th.sub1
                font.pixelSize: 13
            }
        }
    }

    LinkText {
        id: albumCol
        app: row.app
        visible: row.wideAlbum
        x: Math.round(row.width * 0.56)
        width: Math.min(implicitWidth, where.x - x - 16)
        anchors.verticalCenter: parent.verticalCenter
        text: row.t ? row.t.al : ""
        color: hovered ? row.app.th.text : row.app.th.sub1
        font.pixelSize: 14
        onClicked: if (row.t && row.t.alId) row.app.ymOpen("album", row.t.alId)
    }

    // where the file lives: ✓ in ~/Music · cloud ✓ temp cache · ⬇ save to library
    IconButton {
        id: where
        app: row.app
        x: heart.x - width
        anchors.verticalCenter: parent.verticalCenter
        size: 32; iconSize: 18
        readonly property string s: row.state_
        icon: s === "lib" ? "check" : s === "tmp" ? "cloud-check" : "download"
        active: s === "lib"
        opacity: s === "lib" || s === "tmp" || hover.hovered ? 1 : 0
        visible: row.ok && s !== "busy"
        tip: s === "lib" ? "In your library (~/Music)" : s === "tmp" ? "In the temporary cache · click to keep it in ~/Music" : "Save to library"
        onClicked: if (s !== "lib") row.app.ymFetch([row.t], 0, "save")
    }
    IconButton {
        id: heart
        app: row.app
        x: dur.x - width - 4
        anchors.verticalCenter: parent.verticalCenter
        size: 32; iconSize: 18
        icon: row.liked ? "heart" : "heart-outline"
        active: row.liked
        opacity: row.liked || hover.hovered ? 1 : 0
        tip: row.liked ? "Liked on Yandex · click to remove" : "Like on Yandex"
        onClicked: row.app.ymLike(row.t)
    }
    Text {
        id: dur
        x: row.width - width - 4
        width: 64
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        text: row.t ? row.app.fmt(row.t.d) : ""
        color: row.app.th.sub1
        font.family: row.app.th.font
        font.pixelSize: 14
        font.features: { "tnum": 1 }
    }
}
