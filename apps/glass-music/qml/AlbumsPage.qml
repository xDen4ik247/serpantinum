import QtQuick

// Your Library → Albums: a virtualised cover grid with sort chips.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: grid
    property var tint: null
    property string sort: "added"
    function scrollTop() { grid.contentY = grid.originY; }
    readonly property var keys: {
        const a = app.lib.albums;
        if (sort === "added") return app.albumsByAdded;
        if (sort === "year") return a.slice().sort((x, y) => (y.y || "").localeCompare(x.y || "")).map(x => x.k);
        if (sort === "name") return a.slice().sort((x, y) => x.n.localeCompare(y.n)).map(x => x.k);
        return a.map(x => x.k);   // by artist (library order)
    }
    readonly property int cols: Math.max(2, Math.floor((width - 36 + 8) / (184 + 8)))
    readonly property real cell: (width - 36) / cols

    GridView {
        id: grid
        anchors.fill: parent
        leftMargin: 18; rightMargin: 18
        cellWidth: pg.cell
        cellHeight: pg.cell + 58
        model: pg.keys.length
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 400
        reuseItems: true
        header: PageTitle {
            app: pg.app
            width: grid.width - 36
            topPad: pg.topPad
            title: "Albums"
            subtitle: pg.app.lib.albums.length + " albums"
            Row {
                spacing: 8
                Chip { app: pg.app; text: "Recently added"; active: pg.sort === "added"; onClicked: pg.sort = "added" }
                Chip { app: pg.app; text: "Artist"; active: pg.sort === "artist"; onClicked: pg.sort = "artist" }
                Chip { app: pg.app; text: "Title"; active: pg.sort === "name"; onClicked: pg.sort = "name" }
                Chip { app: pg.app; text: "Year"; active: pg.sort === "year"; onClicked: pg.sort = "year" }
            }
        }
        delegate: Card {
            required property int index
            readonly property var a: pg.app.albumByKey[pg.keys[index]]
            app: pg.app
            width: pg.cell - 8
            coverKey: a ? a.k : ""
            title: a ? a.n : ""
            subtitle: a ? (a.y ? a.y + " • " : "") + a.ar : ""
            playing: !!pg.app.curTrack && !!a && pg.app.curTrack.k === a.k
            onClicked: pg.app.goAlbum(a.k)
            onPlay: pg.app.playAlbum(a.k, false)
            onRightClicked: (x, y) => pg.app.albumMenu(a.k, pg.app.rootItem, x, y)
        }
        footer: Item { width: 1; height: 30 }
    }
}
