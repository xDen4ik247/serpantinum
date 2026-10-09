import QtQuick
import QtQuick.Effects

// The big "Top result" card on the search page (artist, album or song).
Item {
    id: tr
    property var app
    property var result: null
    readonly property string kind: result ? result.kind : ""
    readonly property var artist: kind === "artist" ? app.artistByName[result.ref] : null
    readonly property var album: kind === "album" ? app.albumByKey[result.ref] : null
    readonly property var track: kind === "track" ? app.lib.tracks[result.ref] : null
    height: 236

    Rectangle {
        anchors.fill: parent
        radius: 14
        color: tr.app.th.alpha(tr.app.th.text, hover.hovered ? 0.13 : 0.07)
        border.color: tr.app.th.alpha("white", 0.06)
        Behavior on color { ColorAnimation { duration: 180 } }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => {
            if (m.button === Qt.RightButton) {
                const p = mapToItem(tr.app.rootItem, m.x, m.y);
                if (tr.track) tr.app.trackMenu(tr.result.ref, [], 0, tr.app.rootItem, p.x, p.y);
                else if (tr.album) tr.app.albumMenu(tr.album.k, tr.app.rootItem, p.x, p.y);
                return;
            }
            if (tr.artist) tr.app.goArtist(tr.artist.n);
            else if (tr.album) tr.app.goAlbum(tr.album.k);
            else if (tr.track) tr.app.goAlbum(tr.track.k);
        }
        onDoubleClicked: tr.play()
    }
    function play() {
        if (artist) app.playArtist(artist.n, false);
        else if (album) app.playAlbum(album.k, false);
        else if (track) app.playContext([result.ref], 0, false);
    }
    Item {
        id: art
        x: 20; y: 20
        width: 96; height: 96
        RectangularShadow { anchors.fill: parent; radius: tr.artist ? 48 : 8; blur: 24; offset.y: 6; color: Qt.rgba(0, 0, 0, 0.4) }
        Cover {
            anchors.fill: parent
            app: tr.app
            circle: !!tr.artist
            radius: 8
            albumKey: tr.artist ? tr.artist.c : tr.album ? tr.album.k : tr.track ? tr.track.k : ""
        }
    }
    Text {
        id: name
        x: 20
        anchors { top: art.bottom; topMargin: 18 }
        width: parent.width - 40
        text: tr.artist ? tr.artist.n : tr.album ? tr.album.n : tr.track ? tr.track.t : ""
        elide: Text.ElideRight
        color: tr.app.th.text
        font.family: tr.app.th.font
        font.pixelSize: 30
        font.weight: Font.Bold
    }
    Row {
        x: 20
        anchors { top: name.bottom; topMargin: 6 }
        spacing: 8
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !!tr.album || !!tr.track
            text: tr.album ? tr.album.ar : tr.track ? tr.track.a : ""
            color: tr.app.th.sub0
            font.family: tr.app.th.font
            font.pixelSize: 14
        }
        Rectangle {
            height: 24; radius: 12
            width: kindLabel.implicitWidth + 20
            color: tr.app.th.alpha(tr.app.th.base, 0.55)
            Text {
                id: kindLabel
                anchors.centerIn: parent
                text: tr.artist ? "Artist" : tr.album ? (tr.album.single ? "Single" : "Album") : "Song"
                color: tr.app.th.text
                font.family: tr.app.th.font
                font.pixelSize: 12
                font.weight: Font.Bold
            }
        }
    }
    IconButton {
        app: tr.app; filled: true; size: 52; iconSize: 28; icon: "play"
        anchors { right: parent.right; rightMargin: 20 }
        y: parent.height - height - 20 + (hover.hovered ? 0 : 10)
        opacity: hover.hovered ? 1 : 0
        Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
        Behavior on opacity { NumberAnimation { duration: 200 } }
        onClicked: tr.play()
    }
}
