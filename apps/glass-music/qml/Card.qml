import QtQuick
import QtQuick.Effects

// Spotify-style card: artwork (album cover, round artist photo, or a gradient mix tile),
// title + subtitle, and a play button that rises in on hover.
Item {
    id: card
    property var app
    property string coverKey: ""
    property bool circle: false
    property string title: ""
    property string subtitle: ""
    property string tileIcon: ""          // gradient tile instead of a cover
    property string tileText: ""
    property color tint: app.th.accent
    property bool glow: false
    property bool playing: false
    signal clicked()
    signal play()
    signal rightClicked(real gx, real gy)
    implicitHeight: width + 64

    Rectangle {
        anchors.fill: parent
        radius: 14
        color: card.app.th.alpha(card.app.th.text, hover.hovered ? 0.08 : 0)
        Behavior on color { ColorAnimation { duration: 180 } }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => {
            if (m.button === Qt.RightButton) { const p = mapToItem(card.app.rootItem, m.x, m.y); card.rightClicked(p.x, p.y); }
            else card.clicked();
        }
        onDoubleClicked: m => { if (m.button === Qt.LeftButton) card.play(); }
    }

    Item {
        id: art
        x: 10; y: 10
        width: card.width - 20
        height: width
        RectangularShadow {
            anchors.fill: parent
            radius: card.circle ? width / 2 : 10
            blur: 22; offset.y: 6; spread: -2
            color: Qt.rgba(0, 0, 0, hover.hovered ? 0.42 : 0.28)
            Behavior on color { ColorAnimation { duration: 200 } }
        }
        Cover {
            anchors.fill: parent
            visible: card.tileIcon === ""
            app: card.app
            albumKey: card.coverKey
            circle: card.circle
            radius: 10
        }
        Rectangle {
            anchors.fill: parent
            visible: card.tileIcon !== ""
            radius: 10
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: card.app.th.mix(card.tint, "#ffffff", 0.12) }
                GradientStop { position: 1; color: card.app.th.mix(card.tint, "#000000", 0.45) }
            }
            Icon {
                app: card.app
                x: parent.width * 0.1; y: parent.height * 0.1
                name: card.tileIcon
                size: parent.width * 0.26
                color: Qt.rgba(1, 1, 1, 0.92)
            }
            Text {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: parent.width * 0.09 }
                text: card.tileText
                color: "white"
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                font.family: card.app.th.font
                font.pixelSize: Math.max(14, Math.round(parent.width * 0.15))
                font.weight: Font.Black
                font.letterSpacing: -0.5
                lineHeight: 0.92
            }
        }
        Rectangle {
            visible: card.glow
            anchors.fill: parent
            anchors.margins: -3
            radius: 13
            color: "transparent"
            border.width: 2
            border.color: card.app.th.accent
        }
        IconButton {
            id: playBtn
            app: card.app
            filled: true
            size: 48; iconSize: 26
            icon: card.playing && card.app.playing ? "pause" : "play"
            anchors { right: parent.right; rightMargin: 8 }
            y: parent.height - height - 8 + (hover.hovered || card.playing ? 0 : 10)
            opacity: hover.hovered || card.playing ? 1 : 0
            Behavior on y { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
            Behavior on opacity { NumberAnimation { duration: 200 } }
            RectangularShadow { anchors.fill: parent; radius: width / 2; blur: 14; offset.y: 4; color: Qt.rgba(0, 0, 0, 0.35); z: -1 }
            onClicked: { if (card.playing) card.app.toggle(); else card.play(); }
        }
    }
    Column {
        anchors { left: art.left; right: art.right; top: art.bottom; topMargin: 10 }
        spacing: 3
        Text {
            width: parent.width
            text: card.title
            elide: Text.ElideRight
            color: card.app.th.text
            font.family: card.app.th.font
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            text: card.subtitle
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WordWrap
            color: card.app.th.sub1
            font.family: card.app.th.font
            font.pixelSize: 13
        }
    }
}
