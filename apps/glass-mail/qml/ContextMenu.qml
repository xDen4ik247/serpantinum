import QtQuick
import QtQuick.Effects

// Right-click menu overlay. Items: {icon, text, act} | {sep: true} | {icon, text, sub: "move", acc, rows}.
// "Move to…" swaps the menu to the account's folders.
Item {
    id: m
    property var app
    property var items: []
    property var mode: null               // null | {sub: "move", acc, rows}
    readonly property bool shown: box.opacity > 0.01 && open_
    property bool open_: false
    visible: open_ || box.opacity > 0.01
    z: 900

    function open(list, item, x, y) {
        items = list;
        mode = null;
        open_ = true;
        place(x, y);
    }
    function place(x, y) {
        Qt.callLater(() => {
            box.x = Math.max(8, Math.min(x, m.width - box.width - 8));
            box.y = Math.max(8, Math.min(y, m.height - box.height - 8));
        });
    }
    function close() { open_ = false; mode = null; m.app.rootItem.forceActiveFocus(); }
    function run(it) {
        if (it.sub) { mode = { sub: it.sub, acc: it.acc, rows: it.rows || [] }; place(box.x, box.y); return; }
        close();
        if (it.act) it.act();
    }
    function moveTargets() {
        if (!mode || mode.sub !== "move") return [];
        const from = mode.rows.length ? mode.rows[0].folder : "";
        return (m.app.folders[mode.acc] || []).filter(f => f.path !== from && f.role !== "flagged" && f.role !== "all" && f.role !== "drafts");
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
        height: Math.min(col.height + 12, m.height - 16)
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

        Flickable {
            anchors { fill: parent; margins: 6 }
            contentHeight: col.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: col
                width: parent.width

                Repeater {
                    model: m.mode === null ? m.items : []
                    delegate: Loader {
                        required property var modelData
                        width: col.width
                        sourceComponent: modelData.sep ? sepC : rowC
                        property var it: modelData
                    }
                }

                // move: pick a folder
                Column {
                    visible: m.mode !== null && m.mode.sub === "move"
                    width: col.width
                    MenuRow { app: m.app; width: parent.width; icon: "back"; text: "Move to"; bold: true; onPicked: m.mode = null }
                    Rectangle { width: parent.width; height: 1; color: m.app.th.alpha(m.app.th.text, 0.08) }
                    Repeater {
                        model: m.moveTargets()
                        MenuRow {
                            required property var modelData
                            app: m.app; width: col.width
                            icon: m.app.roleIcon(modelData.role)
                            text: (modelData.depth ? "    ".repeat(Math.min(3, modelData.depth)) : "") + modelData.name
                            onPicked: {
                                const rows = m.mode.rows;
                                m.close();
                                const op = modelData.role === "trash" ? "trash" : modelData.role === "junk" ? "spam" : modelData.role === "archive" ? "archive" : "move";
                                m.app.act(op, rows.length === 1 ? rows[0] : null, modelData.path);
                            }
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
            chevron: !!(parent && parent.it && parent.it.sub)
            onPicked: m.run(parent.it)
        }
    }
}
