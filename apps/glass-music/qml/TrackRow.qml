import QtQuick

// A song row: # (play button on hover, equaliser when playing) · cover · title/artist ·
// album · ♥ · duration. Double-click plays it in its context (ctx = list of track indexes).
Item {
    id: row
    property var app
    property int ti: -1                   // track index in app.lib.tracks
    property var ctx: []                  // the list this row belongs to (becomes the queue)
    property int at: 0                    // position in ctx
    property string num: ""
    property bool showCover: true
    property bool showAlbum: true
    property string extra: ""             // optional middle column (e.g. play count)
    readonly property var t: ti >= 0 && ti < app.lib.tracks.length ? app.lib.tracks[ti] : null
    readonly property bool current: !!t && app.status.file === t.f
    readonly property bool liked: !!t && !!app.likes[t.f]
    readonly property bool sel: !!t && app.selected === t.f
    readonly property bool wideAlbum: showAlbum && width > 620
    height: 58

    function play() { app.playContext(ctx && ctx.length ? ctx : [ti], ctx && ctx.length ? at : 0, false); }

    Rectangle {
        anchors.fill: parent
        radius: 10
        color: row.app.th.alpha(row.app.th.text, row.sel ? 0.13 : (hover.hovered ? 0.07 : 0))
        Behavior on color { ColorAnimation { duration: 120 } }
    }
    HoverHandler { id: hover }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: row.app.rootItem.forceActiveFocus()
        onClicked: m => {
            if (!row.t) return;
            row.app.selected = row.t.f;
            if (m.button === Qt.RightButton) {
                const p = mapToItem(row.app.rootItem, m.x, m.y);
                row.app.trackMenu(row.ti, row.ctx, row.at, row.app.rootItem, p.x, p.y);
            }
        }
        onDoubleClicked: m => { if (m.button === Qt.LeftButton) row.play(); }
    }

    // # / play / now-playing
    Item {
        id: numBox
        x: 4
        width: 40
        height: parent.height
        Text {
            anchors.centerIn: parent
            visible: !hover.hovered && !row.current
            text: row.num
            color: row.app.th.sub1
            font.family: row.app.th.font
            font.pixelSize: 14
            font.features: { "tnum": 1 }
        }
        Icon {
            anchors.centerIn: parent
            visible: row.current && !hover.hovered
            app: row.app
            name: row.app.playing ? "waveform" : "pause"
            size: 18
            color: row.app.th.accent
        }
        IconButton {
            anchors.centerIn: parent
            visible: hover.hovered
            app: row.app
            size: 32; iconSize: 20
            icon: row.current && row.app.playing ? "pause" : "play"
            fg: row.app.th.text
            onClicked: { if (row.current) row.app.toggle(); else row.play(); }
        }
    }

    Cover {
        id: cov
        visible: row.showCover
        app: row.app
        x: numBox.x + numBox.width + 6
        anchors.verticalCenter: parent.verticalCenter
        width: row.showCover ? 42 : 0
        height: 42
        radius: 6
        albumKey: row.showCover && row.t ? row.t.k : ""
    }

    Column {
        id: titleCol
        anchors.verticalCenter: parent.verticalCenter
        x: (row.showCover ? cov.x + cov.width : numBox.x + numBox.width) + 12
        width: (row.wideAlbum ? albumCol.x : extraCol.x) - x - 16
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
                id: explicitLrc
                visible: !!row.t && row.t.l
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
                width: Math.min(implicitWidth, parent.width - (explicitLrc.visible ? explicitLrc.width + 4 : 0))
                text: row.t ? row.t.a : ""
                onClicked: row.app.goTrackArtist(row.ti)
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
        width: Math.min(implicitWidth, extraCol.x - x - 16)
        anchors.verticalCenter: parent.verticalCenter
        text: row.t ? row.t.al : ""
        color: hovered ? row.app.th.text : row.app.th.sub1
        font.pixelSize: 14
        onClicked: row.app.goTrackAlbum(row.ti)
    }

    Text {
        id: extraCol
        x: heart.x - (row.extra !== "" ? 90 : 0)
        width: row.extra !== "" ? 80 : 0
        anchors.verticalCenter: parent.verticalCenter
        text: row.extra
        horizontalAlignment: Text.AlignRight
        color: row.app.th.sub1
        font.family: row.app.th.font
        font.pixelSize: 13
    }

    IconButton {
        id: heart
        app: row.app
        x: dur.x - width - 4
        anchors.verticalCenter: parent.verticalCenter
        size: 32; iconSize: 18
        icon: row.liked ? "star" : "star-outline"
        active: row.liked
        opacity: row.liked || hover.hovered ? 1 : 0
        tip: row.liked ? "Favourite · click to remove" : "Add to Favourites"
        onClicked: row.app.toggleLike(row.ti)
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
