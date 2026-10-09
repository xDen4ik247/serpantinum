import QtQuick

// Your Library → Artists: round photos (the artist's newest cover), A–Z or by songs.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: grid
    property var tint: null
    property string sort: "name"
    function scrollTop() { grid.contentY = grid.originY; }
    readonly property var names: {
        const a = app.lib.artists;
        if (sort === "songs") return a.slice().sort((x, y) => y.nt - x.nt).map(x => x.n);
        if (sort === "played") {
            const c = {};
            for (const f in app.home.counts) { const i = app.fileIdx[f]; if (i !== undefined) { const p = app.lib.tracks[i].p; c[p] = (c[p] || 0) + app.home.counts[f]; } }
            return a.slice().sort((x, y) => (c[y.n] || 0) - (c[x.n] || 0) || y.nt - x.nt).map(x => x.n);
        }
        return a.map(x => x.n);
    }
    readonly property int cols: Math.max(2, Math.floor((width - 36 + 8) / (176 + 8)))
    readonly property real cell: (width - 36) / cols

    GridView {
        id: grid
        anchors.fill: parent
        leftMargin: 18; rightMargin: 18
        cellWidth: pg.cell
        cellHeight: pg.cell + 50
        model: pg.names.length
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 400
        reuseItems: true
        header: PageTitle {
            app: pg.app
            width: grid.width - 36
            topPad: pg.topPad
            title: "Artists"
            subtitle: pg.app.lib.artists.length + " artists"
            Row {
                spacing: 8
                Chip { app: pg.app; text: "A–Z"; active: pg.sort === "name"; onClicked: pg.sort = "name" }
                Chip { app: pg.app; text: "Most songs"; active: pg.sort === "songs"; onClicked: pg.sort = "songs" }
                Chip { app: pg.app; text: "Most played"; active: pg.sort === "played"; onClicked: pg.sort = "played" }
            }
        }
        delegate: Card {
            required property int index
            readonly property var a: pg.app.artistByName[pg.names[index]]
            app: pg.app
            width: pg.cell - 8
            circle: true
            coverKey: a ? a.c : ""
            title: a ? a.n : ""
            subtitle: a ? pg.app.n(a.al.length, "album") + " · " + pg.app.n(a.nt, "song") : ""
            playing: !!pg.app.curTrack && !!a && pg.app.curTrack.p === a.n
            onClicked: pg.app.goArtist(a.n)
            onPlay: pg.app.playArtist(a.n, false)
        }
        footer: Item { width: 1; height: 30 }
    }
}
