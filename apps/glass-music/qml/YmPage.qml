import QtQuick
import QtQuick.Effects

// A Yandex Music album / artist / playlist / your Yandex likes (arg = "kind:id"). Same hero as
// TrackListPage; play downloads the tracks (clicked one first) and MPD plays the local files.
// "Save to library" hands the whole music.yandex.ru link to yandex-music-downloader.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: list
    readonly property string kind: arg.slice(0, arg.indexOf(":"))
    readonly property var d: app.ymPage
    readonly property var tracks: d && d.tracks ? d.tracks : []
    readonly property var albums: d && d.albums ? d.albums : []
    readonly property color tint: {
        let h = 0;
        const k = arg;
        for (let i = 0; i < k.length; i++) h = (h * 31 + k.charCodeAt(i)) % 360;
        return kind === "likes" ? Qt.hsla(0.0, 0.62, 0.5, 1) : Qt.hsla(h / 360, 0.45, 0.45, 1);
    }
    readonly property string title: d ? (d.n || "") : ""
    readonly property int total: { let s = 0; for (const t of tracks) s += t.d; return s; }
    readonly property int missing: { let n = 0; for (const t of tracks) if (t.ok !== false && app.ymState(t) !== "lib") n++; return n; }
    property string stickyTitle: title
    property real stickyAt: 300 + topPad * 0.5 - 40

    Component.onCompleted: app.ymLoad(arg)
    function playAll(shuffle) {
        if (!tracks.length) return;
        if (shuffle) { const a = tracks.slice(); for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); const x = a[i]; a[i] = a[j]; a[j] = x; } app.ymPlay(a, 0); }
        else app.ymPlay(tracks, 0);
    }
    function saveAll() {
        if (kind === "likes") { app.ymSync(); return; }
        if (d && d.url) app.ymDownload(d.url, title);
    }
    function scrollTop() { list.contentY = list.originY; }

    ListView {
        id: list
        anchors.fill: parent
        model: pg.tracks.length
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        cacheBuffer: 600
        property bool userScrolled: false
        onMovementStarted: userScrolled = true
        Connections {
            target: list.headerItem
            function onHeightChanged() { if (!list.userScrolled) list.positionViewAtBeginning(); }
        }
        header: Column {
            width: list.width
            Item {
                width: parent.width
                height: 300 + pg.topPad * 0.5
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0; color: pg.app.th.alpha(pg.tint, 0.55) }
                        GradientStop { position: 1; color: pg.app.th.alpha(pg.tint, 0.18) }
                    }
                }
                Item {
                    id: art
                    x: 28
                    anchors { bottom: parent.bottom; bottomMargin: 24 }
                    width: Math.min(232, parent.height - pg.topPad - 40)
                    height: width
                    RectangularShadow { anchors.fill: parent; radius: pg.kind === "artist" ? width / 2 : 10; blur: 40; offset.y: 10; color: Qt.rgba(0, 0, 0, 0.45) }
                    Cover {
                        anchors.fill: parent
                        visible: pg.kind !== "likes"
                        app: pg.app
                        radius: 10
                        circle: pg.kind === "artist"
                        url: pg.d && pg.d.c ? pg.d.c.replace("200x200", "400x400") : ""
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: pg.kind === "likes"
                        radius: 10
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: pg.app.th.mix(pg.tint, "#000000", 0.25) }
                            GradientStop { position: 1; color: pg.app.th.mix(pg.tint, "#ffffff", 0.25) }
                        }
                        Icon { app: pg.app; anchors.centerIn: parent; size: parent.width * 0.38; color: "white"; name: "heart" }
                    }
                }
                Column {
                    anchors { left: art.right; leftMargin: 24; right: parent.right; rightMargin: 28; bottom: art.bottom }
                    spacing: 6
                    Text {
                        text: pg.d ? (pg.d.sub || "") + "  ·  Yandex Music" : (pg.app.ym.signed ? "Loading from Yandex Music…" : "Not signed in to Yandex Music")
                        color: pg.app.th.text
                        font.family: pg.app.th.font
                        font.pixelSize: 14
                        font.weight: Font.Medium
                    }
                    Text {
                        width: parent.width
                        height: Math.min(implicitHeight, 150)
                        text: pg.d && pg.d.error ? "Couldn’t load this" : pg.title
                        color: "white"
                        font.family: pg.app.th.font
                        font.pixelSize: text.length > 28 ? 40 : (text.length > 14 ? 56 : 76)
                        font.weight: Font.Black
                        font.letterSpacing: -1
                        fontSizeMode: Text.HorizontalFit
                        minimumPixelSize: 26
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        lineHeight: 0.95
                    }
                    Text {
                        width: parent.width
                        text: pg.d && pg.d.error ? pg.d.error
                            : pg.tracks.length ? pg.app.n(pg.tracks.length, "song") + ", " + pg.app.fmtLong(pg.total)
                              + (pg.missing ? " · " + pg.missing + " not in ~/Music yet" : " · all in ~/Music") : ""
                        color: pg.app.th.sub0
                        font.family: pg.app.th.font
                        font.pixelSize: 14
                        wrapMode: Text.WordWrap
                    }
                }
            }
            // actions
            Item {
                width: parent.width
                height: 96
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0; color: pg.app.th.alpha(pg.tint, 0.16) }
                        GradientStop { position: 1; color: "transparent" }
                    }
                }
                Row {
                    x: 28
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    IconButton {
                        app: pg.app; icon: "play"; filled: true; size: 56; iconSize: 30
                        enabledState: pg.tracks.length > 0
                        tip: "Play (downloads as it goes)"
                        onClicked: pg.playAll(false)
                    }
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        app: pg.app; icon: "shuffle"; size: 42; iconSize: 26
                        enabledState: pg.tracks.length > 0
                        tip: "Shuffle play"
                        onClicked: pg.playAll(true)
                    }
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        app: pg.app; size: 42; iconSize: 24
                        icon: pg.missing ? (pg.kind === "likes" ? "sync" : "download") : "check"
                        active: !pg.missing && pg.tracks.length > 0
                        enabledState: pg.tracks.length > 0
                        tip: pg.kind === "likes" ? "Sync your likes into ~/Music" : pg.missing ? "Save to library (~/Music)" : "Everything is in your library"
                        onClicked: if (pg.missing) pg.saveAll()
                    }
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: pg.kind === "album" || pg.kind === "playlist"
                        app: pg.app; icon: "playlist-plus"; size: 42; iconSize: 24
                        tip: "Add to queue"
                        onClicked: pg.app.ymFetch(pg.tracks, 0, "add")
                    }
                }
            }
            Item { width: 1; height: 4 }
        }
        delegate: YmTrackRow {
            required property int index
            x: 14
            width: list.width - 28
            app: pg.app
            t: pg.tracks[index]
            ctx: pg.tracks
            at: index
            num: String(index + 1)
            showAlbum: pg.kind !== "album"
        }
        footer: Column {
            width: list.width
            topPadding: 20
            bottomPadding: 40
            Shelf {
                id: albumShelf
                x: 18
                width: parent.width - 36
                app: pg.app
                title: "Albums"
                count: pg.albums.length
                rows: 3
                delegate: Card {
                    required property int index
                    readonly property var a: pg.albums[index]
                    app: pg.app
                    width: albumShelf.cardW
                    coverUrl: a.c
                    title: a.n
                    subtitle: (a.y ? a.y + " • " : "") + a.s
                    onClicked: pg.app.ymOpen("album", a.id)
                    onPlay: pg.app.ymOpen("album", a.id)
                    onRightClicked: (x, y) => pg.app.ymItemMenu(a, pg.app.rootItem, x, y)
                }
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: !pg.d && pg.app.ym.signed
        text: "Loading from Yandex Music…"
        color: pg.app.th.sub1
        font.family: pg.app.th.font
        font.pixelSize: 15
    }
}
