import QtQuick

// "#  Title  Album  🕒" header over song lists.
Item {
    id: h
    property var app
    property bool showAlbum: true
    height: 40
    Text { x: 4; width: 40; horizontalAlignment: Text.AlignHCenter; anchors.verticalCenter: parent.verticalCenter; text: "#"; color: h.app.th.sub1; font.family: h.app.th.font; font.pixelSize: 14 }
    Text { x: 58; anchors.verticalCenter: parent.verticalCenter; text: "Title"; color: h.app.th.sub1; font.family: h.app.th.font; font.pixelSize: 14 }
    Text { visible: h.showAlbum && h.width > 620; x: Math.round(h.width * 0.56); anchors.verticalCenter: parent.verticalCenter; text: "Album"; color: h.app.th.sub1; font.family: h.app.th.font; font.pixelSize: 14 }
    Icon { app: h.app; x: h.width - 68; width: 64; anchors.verticalCenter: parent.verticalCenter; name: "clock"; size: 18; color: h.app.th.sub1 }
    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: h.app.th.alpha(h.app.th.text, 0.1) }
    Item { width: 1; height: 8; anchors.top: parent.bottom }
}
