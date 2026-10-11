import QtQuick

// Search: "Browse all" My Vibe style tiles while empty; otherwise top result + songs, artists,
// albums and every matching song. Matching runs in the backend (Cyrillic/Japanese aware,
// layout-swap and transliteration tolerant), one round trip per keystroke.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: fl
    property var tint: null
    function scrollTop() { fl.contentY = 0; }
    readonly property var res: app.searchRes
    readonly property bool hasQuery: app.searchText.trim() !== ""
    readonly property var tracks: res ? res.tracks : []
    readonly property var topRes: res ? res.top : null
    readonly property bool wide: width > 860
    property int ymLimit: 6
    Connections { target: pg.app; function onSearchTextChanged() { pg.ymLimit = 6; } }
    readonly property var ymr: app.ymRes
    readonly property var ymTracks: ymr && ymr.tracks ? ymr.tracks : []
    readonly property bool ymAny: !!ymr && (ymTracks.length + ymr.albums.length + ymr.artists.length + ymr.playlists.length) > 0

    Flickable {
        id: fl
        anchors.fill: parent
        contentHeight: col.height + pg.topPad + 40
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            x: 18
            y: pg.topPad + 8
            width: fl.width - 36
            spacing: 28

            // ---- browse
            Column {
                visible: !pg.hasQuery
                width: parent.width
                spacing: 12
                Text { x: 10; text: "Browse all"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 24; font.weight: Font.Bold }
                Flow {
                    id: browse
                    width: parent.width
                    spacing: 14
                    readonly property int cols: Math.max(2, Math.floor((width + 14) / (210 + 14)))
                    readonly property real tileW: (width - (cols - 1) * 14) / cols
                    Repeater {
                        model: pg.app.styleList().filter(x => x.id !== "default" && x.id !== "discover")
                        Rectangle {
                            id: tile
                            required property var modelData
                            width: browse.tileW
                            height: Math.round(width * 0.56)
                            radius: 12
                            clip: true
                            color: pg.app.th.mix(pg.app.styleColor(modelData.id), pg.app.th.base, 0.18)
                            readonly property var sample: {
                                const tr = pg.app.styleTracks(modelData.id);
                                let first = "";
                                for (let j = 0, n = 0; j < tr.length; j++) {
                                    const k = pg.app.lib.tracks[tr[j]].k, al = pg.app.albumByKey[k];
                                    if (al && al.c) { if (!first) first = k; if ((n++) === 3) return k; }
                                }
                                return first;
                            }
                            Text {
                                x: 16; y: 14
                                width: parent.width - 32
                                text: tile.modelData.label
                                color: "white"
                                wrapMode: Text.WordWrap
                                font.family: pg.app.th.font
                                font.pixelSize: 22
                                font.weight: Font.Bold
                            }
                            Text {
                                x: 16
                                anchors { bottom: parent.bottom; bottomMargin: 12 }
                                text: pg.app.n(tile.modelData.n !== undefined ? tile.modelData.n : pg.app.styleTracks(tile.modelData.id).length, "song")
                                color: Qt.rgba(1, 1, 1, 0.75)
                                font.family: pg.app.th.font
                                font.pixelSize: 13
                            }
                            Cover {
                                app: pg.app
                                albumKey: tile.sample
                                width: tile.height * 0.62; height: width
                                radius: 6
                                rotation: 25
                                x: tile.width - width * 0.78
                                y: tile.height - height * 0.82
                            }
                            HoverHandler { id: th; cursorShape: Qt.PointingHandCursor }
                            scale: th.hovered ? 1.02 : 1
                            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                            TapHandler { onTapped: pg.app.go("style", tile.modelData.id) }
                        }
                    }
                }
            }

            Shelf {
                id: added
                app: pg.app
                width: parent.width
                visible: !pg.hasQuery
                title: "Recently added"
                subtitle: "New in ~/Music"
                count: pg.hasQuery ? 0 : Math.min(24, pg.app.albumsByAdded.length)
                rows: 2
                showAllPage: "albums"
                delegate: Card {
                    required property int index
                    readonly property var a: pg.app.albumByKey[pg.app.albumsByAdded[index]]
                    app: pg.app
                    width: added.cardW
                    coverKey: a.k
                    title: a.n
                    subtitle: (a.y ? a.y + " • " : "") + a.ar
                    onClicked: pg.app.goAlbum(a.k)
                    onPlay: pg.app.playAlbum(a.k, false)
                    onRightClicked: (x, y) => pg.app.albumMenu(a.k, pg.app.rootItem, x, y)
                }
            }

            // ---- nothing found
            Column {
                visible: pg.hasQuery && pg.res !== null && !pg.topRes && !pg.ymAny && !pg.app.ymSearching
                width: parent.width
                topPadding: 60
                spacing: 8
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "No results found for “" + pg.app.searchText + "”"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 22; font.weight: Font.Bold }
                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Check the spelling, or try fewer words."; color: pg.app.th.sub1; font.family: pg.app.th.font; font.pixelSize: 15 }
            }

            // ---- top result + songs
            Grid {
                visible: pg.hasQuery && !!pg.topRes
                width: parent.width
                columns: pg.wide ? 2 : 1
                columnSpacing: 20
                rowSpacing: 24
                Column {
                    width: pg.wide ? parent.width * 0.4 : parent.width
                    spacing: 12
                    Text { x: 10; text: "Top result"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 24; font.weight: Font.Bold }
                    TopResult { app: pg.app; width: parent.width; result: pg.topRes }
                }
                Column {
                    width: pg.wide ? parent.width * 0.6 - 20 : parent.width
                    spacing: 2
                    Text { x: 10; text: "Songs"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 24; font.weight: Font.Bold; bottomPadding: 10 }
                    Repeater {
                        model: Math.min(4, pg.tracks.length)
                        TrackRow {
                            required property int index
                            app: pg.app
                            width: parent.width
                            ti: pg.tracks[index]
                            ctx: pg.tracks
                            at: index
                            num: String(index + 1)
                            showAlbum: false
                        }
                    }
                }
            }

            // ---- Yandex Music: everything else (play = download first, then MPD plays it)
            Column {
                visible: pg.hasQuery
                width: parent.width
                spacing: 6
                Row {
                    x: 10
                    spacing: 10
                    Icon { anchors.verticalCenter: parent.verticalCenter; app: pg.app; name: "cloud"; size: 24; color: pg.app.th.accent }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text { text: "Yandex Music"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 24; font.weight: Font.Bold }
                        Text {
                            text: !pg.app.ym.signed ? "Sign in to search everything on Yandex Music"
                                : pg.app.ymSearching && !pg.ymAny ? "Searching…"
                                : pg.ymr && pg.ymr.error ? pg.ymr.error
                                : "Playing a song downloads it " + (pg.app.ym.conf && pg.app.ym.conf.storage === "temp" ? "to the temporary cache" : "into ~/Music") + " first"
                            color: pg.ymr && pg.ymr.error ? pg.app.th.bad : pg.app.th.sub1
                            font.family: pg.app.th.font
                            font.pixelSize: 13
                        }
                    }
                }
                Chip {
                    x: 10
                    visible: !pg.app.ym.signed
                    app: pg.app
                    text: "Sign in to Yandex Music"
                    onClicked: pg.app.go("yandex")
                }
                Repeater {
                    model: Math.min(pg.ymLimit, pg.ymTracks.length)
                    YmTrackRow {
                        required property int index
                        app: pg.app
                        width: parent.width
                        t: pg.ymTracks[index]
                        ctx: [pg.ymTracks[index]]
                        at: 0
                        num: String(index + 1)
                    }
                }
                LinkText {
                    x: 10
                    visible: pg.ymTracks.length > pg.ymLimit
                    app: pg.app
                    text: "Show all " + pg.ymTracks.length + " songs"
                    color: hovered ? pg.app.th.text : pg.app.th.sub1
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    onClicked: pg.ymLimit = 20
                }
            }
            Shelf {
                id: ymArtists
                app: pg.app
                width: parent.width
                visible: pg.hasQuery && count > 0
                title: "Artists on Yandex"
                count: pg.ymr && pg.ymr.artists ? pg.ymr.artists.length : 0
                delegate: Card {
                    required property int index
                    readonly property var a: pg.ymr.artists[index]
                    app: pg.app
                    width: ymArtists.cardW
                    circle: true
                    coverUrl: a.c
                    title: a.n
                    subtitle: "Artist"
                    onClicked: pg.app.ymOpen("artist", a.id)
                    onPlay: pg.app.ymOpen("artist", a.id)
                    onRightClicked: (x, y) => pg.app.ymItemMenu(a, pg.app.rootItem, x, y)
                }
            }
            Shelf {
                id: ymAlbums
                app: pg.app
                width: parent.width
                visible: pg.hasQuery && count > 0
                title: "Albums on Yandex"
                count: pg.ymr && pg.ymr.albums ? pg.ymr.albums.length : 0
                delegate: Card {
                    required property int index
                    readonly property var a: pg.ymr.albums[index]
                    app: pg.app
                    width: ymAlbums.cardW
                    coverUrl: a.c
                    title: a.n
                    subtitle: (a.y ? a.y + " • " : "") + a.s
                    onClicked: pg.app.ymOpen("album", a.id)
                    onPlay: pg.app.ymOpen("album", a.id)
                    onRightClicked: (x, y) => pg.app.ymItemMenu(a, pg.app.rootItem, x, y)
                }
            }
            Shelf {
                id: ymLists
                app: pg.app
                width: parent.width
                visible: pg.hasQuery && count > 0
                title: "Playlists on Yandex"
                count: pg.ymr && pg.ymr.playlists ? pg.ymr.playlists.length : 0
                delegate: Card {
                    required property int index
                    readonly property var a: pg.ymr.playlists[index]
                    app: pg.app
                    width: ymLists.cardW
                    coverUrl: a.c
                    title: a.n
                    subtitle: pg.app.n(a.nt, "song") + (a.s ? " • " + a.s : "")
                    onClicked: pg.app.ymOpen("playlist", a.id)
                    onPlay: pg.app.ymOpen("playlist", a.id)
                    onRightClicked: (x, y) => pg.app.ymItemMenu(a, pg.app.rootItem, x, y)
                }
            }

            Shelf {
                id: artistsShelf
                app: pg.app
                width: parent.width
                visible: pg.hasQuery && count > 0
                title: "Artists in your library"
                count: pg.res ? pg.res.artists.length : 0
                delegate: Card {
                    required property int index
                    readonly property var a: pg.app.artistByName[pg.res.artists[index]]
                    app: pg.app
                    width: artistsShelf.cardW
                    circle: true
                    coverKey: a ? a.c : ""
                    title: a ? a.n : ""
                    subtitle: "Artist"
                    onClicked: pg.app.goArtist(a.n)
                    onPlay: pg.app.playArtist(a.n, false)
                }
            }
            Shelf {
                id: albumsShelf
                app: pg.app
                width: parent.width
                visible: pg.hasQuery && count > 0
                title: "Albums in your library"
                count: pg.res ? pg.res.albums.length : 0
                rows: 2
                delegate: Card {
                    required property int index
                    readonly property var a: pg.app.albumByKey[pg.res.albums[index]]
                    app: pg.app
                    width: albumsShelf.cardW
                    coverKey: a ? a.k : ""
                    title: a ? a.n : ""
                    subtitle: a ? (a.y ? a.y + " • " : "") + a.ar : ""
                    onClicked: pg.app.goAlbum(a.k)
                    onPlay: pg.app.playAlbum(a.k, false)
                    onRightClicked: (x, y) => pg.app.albumMenu(a.k, pg.app.rootItem, x, y)
                }
            }
            Column {
                visible: pg.hasQuery && pg.tracks.length > 4
                width: parent.width
                spacing: 2
                Text { x: 10; text: "All songs"; color: pg.app.th.text; font.family: pg.app.th.font; font.pixelSize: 24; font.weight: Font.Bold; bottomPadding: 10 }
                Repeater {
                    model: pg.tracks.length > 4 ? pg.tracks.length : 0
                    TrackRow {
                        required property int index
                        app: pg.app
                        width: parent.width
                        ti: pg.tracks[index]
                        ctx: pg.tracks
                        at: index
                        num: String(index + 1)
                    }
                }
            }
        }
    }
}
