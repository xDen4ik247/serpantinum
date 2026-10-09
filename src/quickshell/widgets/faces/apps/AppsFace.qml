import QtQuick
import Quickshell
import "../../"
import "../../../"

// "Favorites" — a grid of app tiles that launch on click.
// The list comes from the `apps` prop (desktop-entry ids, e.g. "firefox"); entries that are
// not installed are skipped, so the grid re-flows instead of showing broken tiles.
Item {
    id: root
    anchors.fill: parent

    property real minWidth: 90
    property real minHeight: 70
    property real maxWidth: 1400
    property real maxHeight: 900
    property bool isRound: false

    property var apps: ["firefox", "kitty", "org.gnome.Nautilus", "com.ayugram.desktop", "obsidian", "com.microsoft.VSCode", "anki", "steam"]
    property bool showLabels: false

    readonly property var entries: {
        // touch the application list so the binding re-runs once entries finish loading
        let all = (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) ? DesktopEntries.applications.values : [];
        let list = Array.isArray(apps) ? apps : String(apps || "").split(/[,\s]+/);
        let out = [];
        for (let i = 0; i < list.length; i++) {
            let id = String(list[i] || "").trim();
            if (!id) continue;
            let e = DesktopEntries.byId(id);
            if (!e && /\.desktop$/.test(id)) {
                id = id.replace(/\.desktop$/, "");
                e = DesktopEntries.byId(id);
            }
            if (!e) {
                for (let j = 0; j < all.length; j++) {
                    if (all[j].id && all[j].id.toLowerCase() === id.toLowerCase()) { e = all[j]; break; }
                }
            }
            if (e) out.push(e);
        }
        return out;
    }

    readonly property int count: Math.max(1, entries.length)
    readonly property real pad: Math.max(10, Math.min(width, height) * 0.07)
    readonly property real gap: Math.max(6, Math.min(width, height) * 0.045)
    readonly property real labelH: showLabels ? Math.max(14, tile * 0.24) : 0

    readonly property var grid: {
        let best = { cols: 1, rows: count, t: 0 };
        let aw = width - pad * 2;
        let ah = height - pad * 2;
        for (let c = 1; c <= count; c++) {
            let r = Math.ceil(count / c);
            let tw = (aw - (c - 1) * gap) / c;
            let th = (ah - (r - 1) * gap) / r / (showLabels ? 1.26 : 1);
            let t = Math.min(tw, th);
            if (t > best.t + 0.5) best = { cols: c, rows: r, t: t };
        }
        return best;
    }
    readonly property real tile: Math.max(16, Math.min(grid.t, 96))
    readonly property real cellW: (width - pad * 2) / grid.cols
    readonly property real cellH: (height - pad * 2) / grid.rows

    Rectangle {
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.06)
    }

    Text {
        anchors.centerIn: parent
        visible: root.entries.length === 0
        text: "No apps"
        color: ThemeBackend.subtext0
        font.family: ThemeBackend.fontFamily
        font.pixelSize: 13
    }

    Repeater {
        model: root.entries
        delegate: Item {
            id: cell
            required property var modelData
            required property int index
            readonly property int row: Math.floor(index / root.grid.cols)
            readonly property int col: index % root.grid.cols
            readonly property int inRow: row === root.grid.rows - 1 ? (root.entries.length - row * root.grid.cols) : root.grid.cols
            x: root.pad + (root.grid.cols - inRow) * root.cellW / 2 + col * root.cellW
            y: root.pad + row * root.cellH
            width: root.cellW
            height: root.cellH

            Item {
                id: content
                width: root.tile
                height: root.tile + root.labelH
                anchors.centerIn: parent

                Rectangle {
                    id: tileBg
                    width: root.tile
                    height: root.tile
                    radius: root.tile * 0.3
                    color: ma.containsMouse
                        ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.20)
                        : Qt.rgba(ThemeBackend.text.r, ThemeBackend.text.g, ThemeBackend.text.b, 0.055)
                    border.width: 1
                    border.color: ma.containsMouse
                        ? Qt.rgba(ThemeBackend.mauve.r, ThemeBackend.mauve.g, ThemeBackend.mauve.b, 0.45)
                        : "transparent"
                    Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    Behavior on border.color { ColorAnimation { duration: 200 } }
                    scale: ma.pressed ? 0.9 : 1
                    Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

                    Image {
                        id: icon
                        anchors.centerIn: parent
                        width: root.tile * 0.62
                        height: width
                        sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(width * 2))
                        source: Quickshell.iconPath(cell.modelData.icon || "", "application-x-executable")
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        mipmap: true
                        scale: ma.containsMouse ? 1.1 : 1
                        Behavior on scale { NumberAnimation { duration: 360; easing.type: Easing.OutQuint } }
                    }

                    // launch feedback: a soft ring that expands and fades
                    Rectangle {
                        id: pulse
                        anchors.centerIn: parent
                        width: parent.width
                        height: parent.height
                        radius: parent.radius
                        color: "transparent"
                        border.width: 2
                        border.color: ThemeBackend.mauve
                        opacity: 0
                        ParallelAnimation {
                            id: pulseAnim
                            NumberAnimation { target: pulse; property: "scale"; from: 1; to: 1.35; duration: 600; easing.type: Easing.OutCubic }
                            NumberAnimation { target: pulse; property: "opacity"; from: 0.9; to: 0; duration: 600; easing.type: Easing.OutCubic }
                        }
                    }
                }

                Text {
                    visible: root.showLabels
                    anchors.top: tileBg.bottom
                    anchors.topMargin: root.labelH * 0.18
                    anchors.horizontalCenter: tileBg.horizontalCenter
                    width: root.cellW - 4
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: cell.modelData.name || ""
                    color: ma.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Math.max(9, root.labelH * 0.62)
                    font.weight: Font.DemiBold
                }

                MouseArea {
                    id: ma
                    anchors.fill: tileBg
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: {
                        pulseAnim.restart();
                        try { cell.modelData.execute(); } catch (e) {}
                    }
                }
            }
        }
    }
}
