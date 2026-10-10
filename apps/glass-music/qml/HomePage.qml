import QtQuick

// Home: greeting, My Vibe (one play button + styles), quick tiles, recently / most played,
// jump back in, your artists.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: fl
    property var tint: null
    function scrollTop() { fl.contentY = 0; }

    readonly property var recentIdx: app.idxOfFiles(app.home.recent)
    readonly property var mostIdx: app.idxOfFiles(app.home.most)
    readonly property string curAlbum: app.curTrack ? app.curTrack.k : ""
    readonly property var jumpBack: {
        const seen = {}, out = [];
        for (const i of recentIdx) { const k = app.lib.tracks[i].k; if (!seen[k]) { seen[k] = 1; out.push(k); } }
        for (const k of app.albumsByAdded) { if (out.length >= 24) break; if (!seen[k]) { seen[k] = 1; out.push(k); } }
        return out;
    }
    readonly property var topArtists: {
        const c = {};
        for (const f in app.home.counts) { const i = app.fileIdx[f]; if (i !== undefined) { const p = app.lib.tracks[i].p; c[p] = (c[p] || 0) + app.home.counts[f]; } }
        const names = Object.keys(c).sort((a, b) => c[b] - c[a]);
        // pad with the artists that have the most songs in the library
        const more = app.lib.artists.slice().sort((a, b) => b.nt - a.nt).map(a => a.n);
        for (const n of more) { if (names.length >= 24) break; if (c[n] === undefined) names.push(n); }
        return names;
    }
    readonly property var quick: {
        const out = [{ kind: "liked" }];
        for (const k of jumpBack) { if (out.length >= 8) break; out.push({ kind: "album", k: k }); }
        return out;
    }

    Flickable {
        id: fl
        anchors.fill: parent
        contentHeight: col.height + pg.topPad + 40
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            x: 18
            y: pg.topPad + 4
            width: fl.width - 36
            spacing: 28

            Column {
                width: parent.width
                spacing: 16
                Text {
                    x: 10
                    text: pg.app.greeting()
                    color: pg.app.th.text
                    font.family: pg.app.th.font
                    font.pixelSize: 32
                    font.weight: Font.Bold
                }
                MyVibeHero {
                    id: vibeHero
                    app: pg.app
                    width: parent.width
                    height: implicitHeight
                    shown: fl.contentY < y + height + pg.topPad
                }
                Item { width: 1; height: 4 }
                Grid {
                    id: quickGrid
                    width: parent.width
                    columns: width > 980 ? 4 : 2
                    spacing: 8
                    readonly property real tileW: (width - (columns - 1) * spacing) / columns
                    Repeater {
                        model: pg.quick
                        QuickTile {
                            required property var modelData
                            app: pg.app
                            width: quickGrid.tileW
                            coverKey: modelData.kind === "album" ? modelData.k : ""
                            icon: "star"
                            tint: pg.app.styleColor("favourites")
                            playing: modelData.kind === "album" && pg.curAlbum === modelData.k
                            title: modelData.kind === "liked" ? "Favourites"
                                 : (pg.app.albumByKey[modelData.k] ? pg.app.albumByKey[modelData.k].n : "")
                            onClicked: {
                                if (modelData.kind === "liked") pg.app.go("liked");
                                else pg.app.goAlbum(modelData.k);
                            }
                            onPlay: {
                                if (modelData.kind === "liked") { const t = pg.app.likedTracks(); if (t.length) pg.app.playContext(t, 0, false); }
                                else pg.app.playAlbum(modelData.k, false);
                            }
                        }
                    }
                }
            }

            Shelf {
                id: recent
                app: pg.app
                width: parent.width
                title: "Recently played"
                count: pg.recentIdx.length
                showAllPage: "recent"
                delegate: Card {
                    required property int index
                    readonly property var t: pg.app.lib.tracks[pg.recentIdx[index]]
                    app: pg.app
                    width: recent.cardW
                    coverKey: t.k
                    title: t.t
                    subtitle: t.a
                    playing: pg.app.status.file === t.f
                    onClicked: pg.app.goAlbum(t.k)
                    onPlay: pg.app.playContext(pg.recentIdx, index, false)
                    onRightClicked: (x, y) => pg.app.trackMenu(pg.recentIdx[index], pg.recentIdx, index, pg.app.rootItem, x, y)
                }
            }

            Shelf {
                id: most
                app: pg.app
                width: parent.width
                title: "Most played"
                subtitle: "From your listening history"
                count: pg.mostIdx.length
                showAllPage: "most"
                delegate: Card {
                    required property int index
                    readonly property var t: pg.app.lib.tracks[pg.mostIdx[index]]
                    app: pg.app
                    width: most.cardW
                    coverKey: t.k
                    title: t.t
                    subtitle: t.a + " · " + pg.app.n(pg.app.home.counts[t.f] || 0, "play")
                    playing: pg.app.status.file === t.f
                    onClicked: pg.app.goAlbum(t.k)
                    onPlay: pg.app.playContext(pg.mostIdx, index, false)
                    onRightClicked: (x, y) => pg.app.trackMenu(pg.mostIdx[index], pg.mostIdx, index, pg.app.rootItem, x, y)
                }
            }

            Shelf {
                id: jump
                app: pg.app
                width: parent.width
                title: "Jump back in"
                count: pg.jumpBack.length
                rows: 2
                delegate: Card {
                    required property int index
                    readonly property var a: pg.app.albumByKey[pg.jumpBack[index]]
                    app: pg.app
                    width: jump.cardW
                    coverKey: a.k
                    title: a.n
                    subtitle: (a.y ? a.y + " • " : "") + a.ar
                    playing: pg.curAlbum === a.k
                    onClicked: pg.app.goAlbum(a.k)
                    onPlay: pg.app.playAlbum(a.k, false)
                    onRightClicked: (x, y) => pg.app.albumMenu(a.k, pg.app.rootItem, x, y)
                }
            }

            Shelf {
                id: artists
                app: pg.app
                width: parent.width
                title: "Your artists"
                count: pg.topArtists.length
                showAllPage: "artists"
                delegate: Card {
                    required property int index
                    readonly property var a: pg.app.artistByName[pg.topArtists[index]]
                    app: pg.app
                    width: artists.cardW
                    circle: true
                    coverKey: a.c
                    title: a.n
                    subtitle: "Artist"
                    onClicked: pg.app.goArtist(a.n)
                    onPlay: pg.app.playArtist(a.n, false)
                }
            }
        }
    }
}
