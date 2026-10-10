import QtQuick

// Left column: Home / Search, then Your Library (Favourites, Artists, Albums, Songs),
// My Vibe and the MPD stored playlists. Collapses to icons in narrow windows.
Item {
    id: side
    property var app
    property bool collapsed: false

    Glass {
        id: top
        theme: side.app.th
        width: parent.width
        height: 112
        radius: 18
        tintAlpha: 0.26
        Column {
            anchors { fill: parent; margins: 6; topMargin: 8 }
            spacing: 4
            SideItem {
                app: side.app; big: false; collapsed: side.collapsed
                icon: side.app.nav.page === "home" ? "home" : "home-outline"
                title: "Home"; active: side.app.nav.page === "home"
                onClicked: side.app.go("home")
            }
            SideItem {
                app: side.app; big: false; collapsed: side.collapsed
                icon: "search"; title: "Search"; active: side.app.nav.page === "search"
                onClicked: { side.app.go("search"); side.app.focusSearch(); }
            }
        }
    }

    Glass {
        id: libBox
        theme: side.app.th
        anchors { top: top.bottom; topMargin: 8; bottom: parent.bottom }
        width: parent.width
        radius: 18
        tintAlpha: 0.26

        Row {
            id: head
            x: side.collapsed ? (parent.width - width) / 2 : 18
            y: 14
            spacing: 10
            Icon { app: side.app; name: "library"; size: 24; color: side.app.th.sub0 }
            Text {
                visible: !side.collapsed
                text: "Your Library"
                color: side.app.th.sub0
                font.family: side.app.th.font
                font.pixelSize: 15
                font.weight: Font.DemiBold
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Flickable {
            id: flick
            anchors { top: head.bottom; topMargin: 10; left: parent.left; right: parent.right; bottom: parent.bottom; margins: 6 }
            contentHeight: col.height + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: col
                width: flick.width
                spacing: 2
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "star"; tint: side.app.styleColor("favourites")
                    title: "Favourites"; subtitle: side.app.likesCount ? "Starred · " + side.app.n(side.app.likesCount, "song") : "Star the songs you love most"
                    active: side.app.nav.page === "liked"; onClicked: side.app.go("liked")
                }
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "artist"; tint: Qt.hsla(0.55, 0.45, 0.5, 1)
                    title: "Artists"; subtitle: side.app.lib.artists.length + " artists"
                    active: side.app.nav.page === "artists" || side.app.nav.page === "artist"; onClicked: side.app.go("artists")
                }
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "album"; tint: Qt.hsla(0.08, 0.5, 0.52, 1)
                    title: "Albums"; subtitle: side.app.lib.albums.length + " albums"
                    active: side.app.nav.page === "albums" || side.app.nav.page === "album"; onClicked: side.app.go("albums")
                }
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "note"; tint: Qt.hsla(0.95, 0.45, 0.52, 1)
                    title: "Songs"; subtitle: side.app.lib.tracks.length + " songs"
                    active: side.app.nav.page === "songs"; onClicked: side.app.go("songs")
                }

                Item { width: 1; height: 10 }
                SectionLabel { app: side.app; text: "My Vibe"; visible: !side.collapsed }
                SideItem {
                    app: side.app; collapsed: side.collapsed
                    icon: side.app.vibeOn ? side.app.styleIcon(side.app.smart.style || "default") : "vibe"
                    tint: side.app.styleColor(side.app.vibeOn ? (side.app.smart.style || "default") : "default")
                    glow: side.app.vibeOn
                    title: side.app.vibeOn && side.app.smart.style !== "default" ? "My Vibe · " + (side.app.smart.styleLabel || "") : "My Vibe"
                    subtitle: side.app.vibeOn ? "On · click to re-roll, right-click: off" : "One button: what you play most"
                    onClicked: { if (side.app.vibeOn) side.app.vibeReroll(); else side.app.vibePlay(side.app.curStyle); }
                    onRightClicked: side.app.vibeStop()
                }
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "reggae"; tint: side.app.styleColor("reggae")
                    title: "Reggae"; subtitle: "My Vibe style · " + side.app.n(side.app.styleTracks("reggae").length, "song")
                    active: side.app.nav.page === "style" && side.app.nav.arg === "reggae"
                    onClicked: side.app.go("style", "reggae")
                }
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "tag"; tint: side.app.th.surface2
                    title: "All styles"; subtitle: "Moods, Discover, Favourites…"
                    active: side.app.nav.page === "search" && side.app.searchText === ""
                    onClicked: { side.app.search(""); side.app.go("search"); }
                }

                Item { width: 1; height: 10; visible: side.app.playlists.length > 0 }
                SectionLabel { app: side.app; text: "Playlists"; visible: !side.collapsed && side.app.playlists.length > 0 }
                Repeater {
                    model: side.app.playlists
                    SideItem {
                        required property var modelData
                        app: side.app; collapsed: side.collapsed
                        icon: "playlist"; tint: Qt.hsla(0.62, 0.35, 0.45, 1)
                        coverKey: modelData.files.length ? (side.app.fileIdx[modelData.files[0]] !== undefined ? side.app.lib.tracks[side.app.fileIdx[modelData.files[0]]].k : "") : ""
                        title: modelData.n; subtitle: "Playlist · " + side.app.n(modelData.files.length, "song")
                        active: side.app.nav.page === "playlist" && side.app.nav.arg === modelData.n
                        onClicked: side.app.go("playlist", modelData.n)
                    }
                }
            }
        }
    }
}
