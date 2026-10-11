import QtQuick

// The Yandex Music side of a local album / artist page: the same album or artist looked up on
// Yandex (by the downloader's link tag, the liked tracks, or a search). Album: the songs you
// don't have yet + "Download full album". Artist: popular songs and the whole discography.
// Songs already in the library (also under another album, e.g. a single) show ✓ and play from
// there; saving skips them, so nothing is downloaded twice.
Column {
    id: sec
    property var app
    property string kind: "album"          // album | artist
    property string name: ""
    property string artist: ""
    property var files: []                 // a few library files of this album / artist (rel paths)
    readonly property string key: kind + "\u0001" + artist + "\u0001" + name
    readonly property var d: app.ymLocal[key]
    readonly property var tracks: d && d.tracks ? d.tracks : []
    readonly property var missing: tracks.filter(t => t.ok !== false && app.ymState(t) !== "lib")
    readonly property var albums: d && d.albums ? d.albums : []
    property bool more: false
    spacing: 8
    visible: app.ym.signed
    Component.onCompleted: app.ymResolve(kind, name, artist, files, key)

    Row {
        x: 10
        spacing: 10
        Icon { anchors.verticalCenter: parent.verticalCenter; app: sec.app; name: "cloud"; size: 22; color: sec.app.th.accent }
        Column {
            anchors.verticalCenter: parent.verticalCenter
            Text {
                text: sec.kind === "album" ? "Full album on Yandex Music" : "Popular on Yandex Music"
                color: sec.app.th.text; font.family: sec.app.th.font; font.pixelSize: 24; font.weight: Font.Bold
            }
            Text {
                text: !sec.d ? "Looking it up…"
                    : !sec.d.found ? "Not found on Yandex Music"
                    : sec.kind === "album" ? (sec.missing.length ? sec.app.n(sec.missing.length, "song") + " not in your library yet · " + sec.app.n(sec.tracks.length, "song") + " in the album"
                                                                 : "You have the whole album (" + sec.app.n(sec.tracks.length, "song") + ")")
                    : sec.app.n(sec.tracks.filter(t => sec.app.ymState(t) === "lib").length, "of these", "of these") + " in your library · ✓ = already downloaded"
                color: sec.app.th.sub1; font.family: sec.app.th.font; font.pixelSize: 13
            }
        }
    }
    Row {
        x: 10
        spacing: 10
        visible: !!sec.d && sec.d.found
        Chip {
            visible: sec.kind === "album" && sec.missing.length > 0
            app: sec.app
            text: "⬇  Download full album"
            onClicked: sec.app.ymFetch(sec.missing, 0, "save")
        }
        Chip {
            visible: sec.kind === "album" && sec.missing.length > 0
            app: sec.app
            text: "▶  Play full album"
            onClicked: sec.app.ymPlay(sec.tracks, 0)
        }
        Chip {
            visible: sec.kind === "artist" && sec.albums.length > 0
            app: sec.app
            text: "⬇  Download whole discography"
            onClicked: if (sec.d.url) sec.app.ymDownload(sec.d.url, sec.d.n)
        }
        Chip {
            app: sec.app
            text: sec.kind === "album" ? "Open on Yandex" : "Open artist on Yandex"
            onClicked: sec.app.ymOpen(sec.kind, sec.d.id)
        }
    }
    Repeater {
        model: sec.kind === "album" ? sec.missing.length : Math.min(sec.tracks.length, sec.more ? 50 : 10)
        YmTrackRow {
            required property int index
            app: sec.app
            width: sec.width
            t: sec.kind === "album" ? sec.missing[index] : sec.tracks[index]
            ctx: sec.kind === "album" ? sec.tracks : sec.tracks
            at: sec.kind === "album" ? Math.max(0, sec.tracks.indexOf(sec.missing[index])) : index
            num: sec.kind === "album" ? String(Math.max(0, sec.tracks.indexOf(sec.missing[index])) + 1) : String(index + 1)
            showAlbum: sec.kind === "artist"
        }
    }
    LinkText {
        x: 14
        visible: sec.kind === "artist" && sec.tracks.length > 10
        app: sec.app
        text: sec.more ? "Show less" : "See more"
        color: hovered ? sec.app.th.text : sec.app.th.sub1
        font.pixelSize: 14
        font.weight: Font.Bold
        onClicked: sec.more = !sec.more
    }
    Shelf {
        id: shelf
        visible: sec.kind === "artist" && count > 0
        width: sec.width
        app: sec.app
        title: "Discography on Yandex"
        subtitle: "Open an album to play it; right-click → Save to library (songs you have are skipped)"
        count: sec.albums.length
        rows: 2
        showAllPage: sec.d && sec.d.found ? "ym" : ""
        showAllArg: sec.d && sec.d.found ? "artist:" + sec.d.id : ""
        delegate: Card {
            required property int index
            readonly property var a: sec.albums[index]
            app: sec.app
            width: shelf.cardW
            coverUrl: a.c
            title: a.n
            subtitle: (a.y ? a.y + " • " : "") + sec.app.n(a.nt, "song")
            onClicked: sec.app.ymOpen("album", a.id)
            onPlay: sec.app.ymOpen("album", a.id)
            onRightClicked: (x, y) => sec.app.ymItemMenu(a, sec.app.rootItem, x, y)
        }
    }
}
