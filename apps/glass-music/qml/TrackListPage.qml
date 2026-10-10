import QtQuick
import QtQuick.Effects

// Album, Favourites, all Songs, a playlist, a My Vibe style, Recently / Most played:
// a coloured hero, the action row (play / shuffle / …) and a virtualised song list.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: list
    readonly property string kind: app.nav.page === "mood" ? "style" : app.nav.page
    readonly property var album: kind === "album" ? app.albumByKey[arg] : null
    readonly property var playlist: {
        if (kind !== "playlist") return null;
        for (const p of app.playlists) if (p.n === arg) return p;
        return null;
    }
    readonly property var tracks: {
        if (kind === "album") return album ? album.tr : [];
        if (kind === "liked") return app.likedTracks();
        if (kind === "songs") { const a = []; for (let i = 0; i < app.lib.tracks.length; i++) a.push(i); return a; }
        if (kind === "playlist") return playlist ? app.idxOfFiles(playlist.files) : [];
        if (kind === "style") return app.styleTracks(arg);
        if (kind === "recent") return app.idxOfFiles(app.home.recent);
        if (kind === "most") return app.idxOfFiles(app.home.most);
        return [];
    }
    readonly property color tint: kind === "album" ? app.colorFor(arg)
        : kind === "liked" ? app.styleColor("favourites")
        : kind === "style" ? app.styleColor(arg)
        : kind === "playlist" && tracks.length ? app.colorFor(app.lib.tracks[tracks[0]].k)
        : app.th.accent
    readonly property string title: kind === "album" ? (album ? album.n : "")
        : kind === "liked" ? "Favourites" : kind === "songs" ? "Songs"
        : kind === "playlist" ? arg : kind === "style" ? app.styleLabel(arg)
        : kind === "recent" ? "Recently played" : kind === "most" ? "Most played" : ""
    readonly property string label: kind === "album" ? (album && album.single ? "Single" : "Album")
        : kind === "style" ? "My Vibe style" : kind === "liked" ? "Starred songs" : kind === "songs" ? "Library" : "Playlist"
    readonly property int total: { let s = 0; for (const i of tracks) s += app.lib.tracks[i].d; return s; }
    property string stickyTitle: title
    property real stickyAt: 300 + topPad * 0.5 - 40

    // a style plays as My Vibe: an endless smart queue that tops itself up
    readonly property bool vibeHere: kind === "style" && app.vibeOn && app.smart.style === arg
    function playAll(shuffle) {
        if (kind === "style" && !shuffle) { app.vibePlay(arg); return; }
        if (tracks.length) app.playContext(tracks, 0, shuffle);
    }
    function scrollTop() { list.contentY = list.originY; }
    readonly property bool isCurrentContext: {
        if (!tracks.length || !app.queue.length || app.queue.length !== tracks.length) return false;
        for (let j = 0; j < Math.min(5, tracks.length); j++) if (app.queue[j].i !== tracks[j]) return false;
        return true;
    }

    ListView {
        id: list
        anchors.fill: parent
        model: pg.tracks.length
        clip: false
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        cacheBuffer: 600
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
            Item {
                id: hero
                width: parent.width
                height: 300 + pg.topPad * 0.5     // fixed: a width-dependent ListView header shifts the view
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
                    RectangularShadow {
                        anchors.fill: parent
                        radius: 10; blur: 40; spread: 0; offset.y: 10
                        color: Qt.rgba(0, 0, 0, 0.45)
                    }
                    Cover {
                        anchors.fill: parent
                        visible: pg.kind === "album" || (pg.kind === "playlist" && pg.tracks.length > 0)
                        app: pg.app
                        hires: true
                        radius: 10
                        albumKey: pg.kind === "album" ? pg.arg : (pg.tracks.length ? pg.app.lib.tracks[pg.tracks[0]].k : "")
                    }
                    Rectangle {
                        anchors.fill: parent
                        visible: !(pg.kind === "album" || (pg.kind === "playlist" && pg.tracks.length > 0))
                        radius: 10
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: pg.app.th.mix(pg.tint, "#000000", 0.25) }
                            GradientStop { position: 1; color: pg.app.th.mix(pg.tint, "#ffffff", 0.25) }
                        }
                        Icon {
                            app: pg.app
                            anchors.centerIn: parent
                            size: parent.width * 0.38
                            color: "white"
                            name: pg.kind === "liked" ? "star" : pg.kind === "style" ? pg.app.styleIcon(pg.arg) : pg.kind === "recent" ? "history" : pg.kind === "most" ? "fire" : "note"
                        }
                    }
                }
                Column {
                    anchors { left: art.right; leftMargin: 24; right: parent.right; rightMargin: 28; bottom: art.bottom }
                    spacing: 6
                    Text {
                        text: pg.label
                        color: pg.app.th.text
                        font.family: pg.app.th.font
                        font.pixelSize: 14
                        font.weight: Font.Medium
                    }
                    Text {
                        width: parent.width
                        height: Math.min(implicitHeight, 150)
                        text: pg.title
                        color: "white"
                        font.family: pg.app.th.font
                        font.pixelSize: pg.title.length > 28 ? 40 : (pg.title.length > 14 ? 56 : 76)
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
                        visible: text !== ""
                        width: parent.width
                        text: pg.kind === "liked" ? "Your whole library already counts as liked. Star (☆) the songs you love most: My Vibe plays them more often."
                            : pg.kind === "style" ? pg.app.styleInfo(pg.arg).desc + " · press play for an endless mix that tops itself up"
                            : ""
                        color: pg.app.th.text
                        opacity: 0.85
                        font.family: pg.app.th.font
                        font.pixelSize: 14
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                    Row {
                        width: parent.width
                        spacing: 6
                        Cover {
                            visible: pg.kind === "album"
                            app: pg.app
                            width: 24; height: 24
                            circle: true
                            albumKey: pg.album ? (pg.app.artistByName[pg.album.p] ? pg.app.artistByName[pg.album.p].c : "") : ""
                        }
                        LinkText {
                            visible: pg.kind === "album"
                            app: pg.app
                            anchors.verticalCenter: parent.verticalCenter
                            text: pg.album ? pg.album.ar : ""
                            color: "white"
                            font.pixelSize: 14
                            font.weight: Font.Bold
                            onClicked: if (pg.album) pg.app.goArtist(pg.album.p)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: (pg.kind === "album" ? " • " + (pg.album && pg.album.y ? pg.album.y + " • " : "") : "")
                                  + pg.tracks.length + (pg.tracks.length === 1 ? " song, " : " songs, ") + pg.app.fmtLong(pg.total)
                            color: pg.app.th.sub0
                            font.family: pg.app.th.font
                            font.pixelSize: 14
                        }
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
                    spacing: 18
                    IconButton {
                        app: pg.app; filled: true; size: 58; iconSize: 30
                        icon: (pg.isCurrentContext || pg.vibeHere) && pg.app.playing ? "pause" : "play"
                        tip: pg.kind === "style" ? "Play My Vibe · " + pg.app.styleLabel(pg.arg) : "Play"
                        onClicked: { if (pg.isCurrentContext || pg.vibeHere) pg.app.toggle(); else pg.playAll(false); }
                    }
                    IconButton {
                        app: pg.app; icon: "shuffle"; size: 46; iconSize: 28; anchors.verticalCenter: parent.verticalCenter
                        tip: "Shuffle play"
                        onClicked: pg.playAll(true)
                    }
                    IconButton {
                        visible: pg.kind === "liked" && pg.tracks.length > 0
                        app: pg.app; icon: "vibe"; size: 46; iconSize: 26; anchors.verticalCenter: parent.verticalCenter
                        active: pg.app.vibeOn && pg.app.smart.style === "favourites"
                        tip: "My Vibe · Favourites: an endless mix of them"
                        onClicked: pg.app.vibePlay("favourites")
                    }
                    IconButton {
                        app: pg.app; icon: "playlist-plus"; size: 46; iconSize: 26; anchors.verticalCenter: parent.verticalCenter
                        tip: "Add to queue"
                        onClicked: pg.app.addQueue(pg.tracks)
                    }
                    IconButton {
                        visible: pg.kind === "album"
                        app: pg.app; icon: "dots"; size: 46; iconSize: 26; anchors.verticalCenter: parent.verticalCenter
                        onClicked: m => { const p = mapToItem(pg.app.rootItem, 0, height); pg.app.albumMenu(pg.arg, pg.app.rootItem, p.x, p.y); }
                    }
                    IconButton {
                        visible: pg.kind === "playlist"
                        app: pg.app; icon: "delete"; size: 46; iconSize: 24; anchors.verticalCenter: parent.verticalCenter
                        tip: "Delete playlist"
                        onClicked: { pg.app.send({ cmd: "playlistdelete", name: pg.arg }); pg.app.go("home"); }
                    }
                }
            }
            ColumnHeader {
                app: pg.app
                width: parent.width - 40
                x: 20
                showAlbum: pg.kind !== "album"
            }
            Text {
                visible: pg.tracks.length === 0
                x: 28
                topPadding: 24
                text: pg.kind === "liked" ? "No favourites yet. Star (☆) a song in any list or in the player bar."
                    : pg.kind === "recent" || pg.kind === "most" ? "Nothing yet: music-smart logs what you play." : "Nothing here yet."
                color: pg.app.th.sub1
                font.family: pg.app.th.font
                font.pixelSize: 15
            }
        }
        delegate: TrackRow {
            required property int index
            app: pg.app
            x: 20
            width: list.width - 40
            ti: pg.tracks[index]
            ctx: pg.tracks
            at: index
            num: pg.kind === "album" ? String(pg.app.lib.tracks[pg.tracks[index]].n || index + 1) : String(index + 1)
            showCover: pg.kind !== "album"
            showAlbum: pg.kind !== "album"
        }
        footer: Item { width: 1; height: 40 }
    }
}
