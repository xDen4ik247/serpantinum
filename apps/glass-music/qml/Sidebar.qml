import QtQuick

// Left column: Home / Search, then Your Library (Artists, Albums, Songs, Liked Songs),
// smart mixes and the MPD stored playlists. Collapses to icons in narrow windows.
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
                    app: side.app; collapsed: side.collapsed; icon: "heart"; tint: Qt.hsla(0.72, 0.55, 0.55, 1)
                    title: "Liked Songs"; subtitle: "Playlist · " + side.app.n(side.app.likesCount, "song")
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
                SectionLabel { app: side.app; text: "Smart mixes"; visible: !side.collapsed }
                SideItem {
                    app: side.app; collapsed: side.collapsed; icon: "smart"; tint: side.app.th.accent
                    glow: !!side.app.smart.active
                    title: "Smart shuffle"
                    subtitle: side.app.smart.active ? "On · " + (side.app.smart.vibeLabel || "") + " vibe" : "Learns what you play"
                    onClicked: side.app.smartStart(true)
                    onRightClicked: side.app.send({ cmd: "smart", action: "stop" })
                }
                Repeater {
                    model: side.app.lib.moods
                    SideItem {
                        required property var modelData
                        app: side.app; collapsed: side.collapsed
                        icon: modelData.id; tint: side.app.moodColor(modelData.id)
                        title: modelData.label + " mix"; subtitle: modelData.n + " songs"
                        active: side.app.nav.page === "mood" && side.app.nav.arg === modelData.id
                        onClicked: side.app.go("mood", modelData.id)
                    }
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
