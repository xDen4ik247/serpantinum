import QtQuick
import QtQuick.Effects

// Artist: hero banner from the blurred cover, popular tracks by play count, discography,
// and songs where the artist is featured.
Item {
    id: pg
    anchors.fill: parent
    property var app
    property string arg: ""
    property real topPad: 64
    property alias flick: fl
    readonly property var artist: app.artistByName[arg]
    readonly property color tint: artist ? app.colorFor(artist.c) : app.th.accent
    property string stickyTitle: arg
    property real stickyAt: hero.height - 60
    property bool more: false
    readonly property var topTracks: artist ? app.artistTop(arg, more ? 10 : 5) : []
    readonly property var all: artist ? app.artistTracks(arg) : []
    readonly property int playsTotal: { let s = 0; for (const i of all) s += app.plays(i); return s; }
    readonly property var appears: artist ? artist.ap : []
    function playAll(shuffle) { app.playArtist(arg, shuffle); }
    function scrollTop() { fl.contentY = 0; }
    readonly property bool isCurrent: !!app.curTrack && app.curTrack.p === arg

    Flickable {
        id: fl
        anchors.fill: parent
        contentHeight: col.height + 40
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            width: fl.width

            Item {
                id: hero
                width: parent.width
                height: Math.max(300, Math.min(400, fl.width * 0.34))
                clip: true
                Item {
                    id: blurSrc
                    anchors.fill: parent
                    anchors.margins: -60
                    visible: false
                    layer.enabled: true
                    Image {
                        anchors.fill: parent
                        source: pg.artist && pg.artist.c && pg.app.albumByKey[pg.artist.c].c ? "file://" + pg.app.albumByKey[pg.artist.c].c : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        // a tiny decode upscaled is already soft; MultiEffect finishes the blur
                        sourceSize: Qt.size(56, 56)
                    }
                }
                MultiEffect {
                    anchors.fill: blurSrc
                    source: blurSrc
                    blurEnabled: true
                    blurMax: 64
                    blur: 1.0
                    saturation: 0.15
                    brightness: -0.08
                }
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: pg.app.th.alpha(pg.tint, 0.25) }
                        GradientStop { position: 0.55; color: pg.app.th.alpha(pg.app.th.base, 0.15) }
                        GradientStop { position: 1.0; color: pg.app.th.alpha(pg.app.th.base, 0.55) }
                    }
                }
                Item {
                    id: avatar
                    x: 28
                    anchors { bottom: parent.bottom; bottomMargin: 28 }
                    width: Math.min(200, hero.height - pg.topPad - 60)
                    height: width
                    RectangularShadow { anchors.fill: parent; radius: width / 2; blur: 40; offset.y: 10; color: Qt.rgba(0, 0, 0, 0.5) }
                    Cover { anchors.fill: parent; app: pg.app; hires: true; circle: true; albumKey: pg.artist ? pg.artist.c : "" }
                }
                Column {
                    anchors { left: avatar.right; leftMargin: 26; right: parent.right; rightMargin: 28; bottom: avatar.bottom }
                    spacing: 6
                    Row {
                        spacing: 6
                        Icon { app: pg.app; name: "artist"; size: 18; color: pg.app.th.accent }
                        Text { text: "Artist"; color: "white"; font.family: pg.app.th.font; font.pixelSize: 14; font.weight: Font.Medium; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Text {
                        width: parent.width
                        text: pg.arg
                        color: "white"
                        font.family: pg.app.th.font
                        font.pixelSize: pg.arg.length > 18 ? 52 : 84
                        font.weight: Font.Black
                        font.letterSpacing: -1.5
                        fontSizeMode: Text.HorizontalFit
                        minimumPixelSize: 28
                        elide: Text.ElideRight
                        style: Text.Normal
                    }
                    Text {
                        text: pg.artist ? pg.app.n(pg.all.length, "song") + " · " + pg.app.n(pg.artist.al.length, "release") + (pg.playsTotal ? " · " + pg.app.n(pg.playsTotal, "play") : "") : ""
                        color: pg.app.th.alpha("white", 0.85)
                        font.family: pg.app.th.font
                        font.pixelSize: 14
                    }
                }
            }

            Item {
                width: parent.width
                height: 92
                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0; color: pg.app.th.alpha(pg.app.th.base, 0.55) }
                        GradientStop { position: 1; color: "transparent" }
                    }
                }
                Row {
                    x: 28
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 18
                    IconButton {
                        app: pg.app; filled: true; size: 58; iconSize: 30
                        icon: pg.isCurrent && pg.app.playing ? "pause" : "play"
                        tip: "Play " + pg.arg
                        onClicked: { if (pg.isCurrent) pg.app.toggle(); else pg.playAll(false); }
                    }
                    IconButton { app: pg.app; icon: "shuffle"; size: 46; iconSize: 28; anchors.verticalCenter: parent.verticalCenter; tip: "Shuffle play"; onClicked: pg.playAll(true) }
                    IconButton { app: pg.app; icon: "playlist-plus"; size: 46; iconSize: 26; anchors.verticalCenter: parent.verticalCenter; tip: "Add all to queue"; onClicked: pg.app.addQueue(pg.all) }
                }
            }

            Column {
                x: 20
                width: parent.width - 40
                spacing: 2
                Text {
                    x: 10
                    text: "Popular"
                    color: pg.app.th.text
                    font.family: pg.app.th.font
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    bottomPadding: 10
                }
                Repeater {
                    model: pg.topTracks.length
                    TrackRow {
                        required property int index
                        app: pg.app
                        width: parent.width
                        ti: pg.topTracks[index]
                        ctx: pg.topTracks
                        at: index
                        num: String(index + 1)
                        showAlbum: true
                        extra: { const n = pg.app.plays(pg.topTracks[index]); return n ? n + (n === 1 ? " play" : " plays") : ""; }
                    }
                }
                LinkText {
                    x: 14
                    visible: pg.all.length > 5
                    topPadding: 8
                    app: pg.app
                    text: pg.more ? "Show less" : "See more"
                    color: hovered ? pg.app.th.text : pg.app.th.sub1
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    onClicked: pg.more = !pg.more
                }
            }

            Item { width: 1; height: 30 }

            Column {
                x: 18
                width: parent.width - 36
                spacing: 8
                Text {
                    x: 10
                    text: "Discography"
                    color: pg.app.th.text
                    font.family: pg.app.th.font
                    font.pixelSize: 24
                    font.weight: Font.Bold
                }
                Flow {
                    id: disc
                    width: parent.width
                    spacing: 8
                    readonly property int cols: Math.max(2, Math.floor((width + 8) / (176 + 8)))
                    readonly property real cardW: (width - (cols - 1) * 8) / cols
                    Repeater {
                        model: pg.artist ? pg.artist.al : []
                        Card {
                            required property var modelData
                            readonly property var a: pg.app.albumByKey[modelData]
                            app: pg.app
                            width: disc.cardW
                            coverKey: modelData
                            title: a.n
                            subtitle: (a.y ? a.y + " • " : "") + (a.single ? "Single" : "Album") + " · " + pg.app.n(a.tr.length, "song")
                            playing: !!pg.app.curTrack && pg.app.curTrack.k === modelData
                            onClicked: pg.app.goAlbum(modelData)
                            onPlay: pg.app.playAlbum(modelData, false)
                            onRightClicked: (x, y) => pg.app.albumMenu(modelData, pg.app.rootItem, x, y)
                        }
                    }
                }
            }

            Item { width: 1; height: 24; visible: pg.appears.length > 0 }
            Column {
                visible: pg.appears.length > 0
                x: 20
                width: parent.width - 40
                spacing: 2
                Text {
                    x: 10
                    text: "Featured on"
                    color: pg.app.th.text
                    font.family: pg.app.th.font
                    font.pixelSize: 24
                    font.weight: Font.Bold
                    bottomPadding: 10
                }
                Repeater {
                    model: Math.min(pg.appears.length, 20)
                    TrackRow {
                        required property int index
                        app: pg.app
                        width: parent.width
                        ti: pg.appears[index]
                        ctx: pg.appears
                        at: index
                        num: String(index + 1)
                    }
                }
            }
        }
    }
}
