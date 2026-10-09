import QtQuick
import QtQuick.Effects

// Right-click menu overlay. Items: {icon, text, act} | {sep: true} | {…, sub: "playlists"|"savequeue", files}.
// "Add to playlist" swaps the menu to the stored playlists plus a "New playlist" name field.
Item {
    id: m
    property var app
    property var items: []
    property var mode: null               // null | {sub, files}
    readonly property bool shown: box.opacity > 0.01 && open_
    property bool open_: false
    visible: open_ || box.opacity > 0.01
    z: 900

    function open(list, item, x, y) {
        items = list;
        mode = null;
        nameField.text = "";
        open_ = true;
        Qt.callLater(() => {
            box.x = Math.max(8, Math.min(x, m.width - box.width - 8));
            box.y = Math.max(8, Math.min(y, m.height - box.height - 8));
        });
    }
    function close() { open_ = false; mode = null; m.app.rootItem.forceActiveFocus(); }
    function run(it) {
        if (it.sub) { mode = { sub: it.sub, files: it.files || [] }; if (it.sub === "savequeue") Qt.callLater(() => nameField.forceActiveFocus()); return; }
        close();
        if (it.act) it.act();
    }

    MouseArea {
        anchors.fill: parent
        enabled: m.open_
        acceptedButtons: Qt.AllButtons
        onPressed: m.close()
        onWheel: w => m.close()
    }

    Item {
        id: box
        width: 270
        height: col.height + 12
        opacity: m.open_ ? 1 : 0
        scale: m.open_ ? 1 : 0.96
        transformOrigin: Item.TopLeft
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
        RectangularShadow { anchors.fill: parent; radius: 12; blur: 30; offset.y: 8; color: Qt.rgba(0, 0, 0, 0.5) }
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: m.app.th.mix(m.app.th.surface1, m.app.th.base, 0.2)
            border.color: m.app.th.alpha("white", 0.09)
        }
        MouseArea { anchors.fill: parent }   // swallow clicks on the frame

        Column {
            id: col
            x: 6; y: 6
            width: parent.width - 12

            // main list
            Repeater {
                model: m.mode === null ? m.items : []
                delegate: Loader {
                    required property var modelData
                    width: col.width
                    sourceComponent: modelData.sep ? sepC : rowC
                    property var it: modelData
                }
            }

            // playlist picker
            Column {
                visible: m.mode !== null && m.mode.sub === "playlists"
                width: col.width
                MenuRow { app: m.app; width: parent.width; icon: "back"; text: "Add to playlist"; bold: true; onPicked: m.mode = null }
                Rectangle { width: parent.width; height: 1; color: m.app.th.alpha(m.app.th.text, 0.08) }
                Repeater {
                    model: m.mode !== null && m.mode.sub === "playlists" ? m.app.playlists : []
                    MenuRow {
                        required property var modelData
                        app: m.app; width: col.width; icon: "playlist"; text: modelData.n
                        onPicked: { m.app.send({ cmd: "playlistadd", name: modelData.n, files: m.mode.files }); m.close(); }
                    }
                }
            }
            // name field (new playlist / save queue)
            Item {
                visible: m.mode !== null
                width: col.width
                height: 48
                Rectangle {
                    anchors { fill: parent; margins: 6 }
                    radius: 8
                    color: m.app.th.alpha(m.app.th.text, 0.08)
                    border.color: nameField.activeFocus ? m.app.th.alpha(m.app.th.accent, 0.8) : "transparent"
                    TextInput {
                        id: nameField
                        anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                        verticalAlignment: TextInput.AlignVCenter
                        color: m.app.th.text
                        font.family: m.app.th.font
                        font.pixelSize: 14
                        clip: true
                        onAccepted: {
                            const n = text.trim();
                            if (!n) return;
                            if (m.mode.sub === "savequeue") m.app.send({ cmd: "savequeue", name: n });
                            else m.app.send({ cmd: "playlistadd", name: n, files: m.mode.files });
                            m.close();
                        }
                        Keys.onEscapePressed: m.close()
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: nameField.text === ""
                            text: m.mode && m.mode.sub === "savequeue" ? "Playlist name, then Enter" : "New playlist name, then Enter"
                            color: m.app.th.sub1
                            font: nameField.font
                        }
                    }
                }
            }
        }
    }

    Component { id: sepC; Item { height: 9; Rectangle { anchors.centerIn: parent; width: parent.width - 8; height: 1; color: m.app.th.alpha(m.app.th.text, 0.08) } } }
    Component {
        id: rowC
        MenuRow {
            app: m.app
            icon: parent && parent.it ? parent.it.icon || "" : ""
            text: parent && parent.it ? parent.it.text || "" : ""
            chevron: !!(parent && parent.it && parent.it.sub === "playlists")
            onPicked: m.run(parent.it)
        }
    }
}
