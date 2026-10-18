// claude-menu: liquid-glass folder picker for Claude Code (standalone quickshell config, started by
// ~/.local/bin/claude-menu on the Copilot key; nothing here is loaded by the Serpantinum shell).
// CM_DIRS: the folders, one absolute path per line (~/claude first). CM_CONF: the user's folder list.
// Keys: 1-9 or ↑↓/jk + Enter start Claude Code there, E edits the list, Esc closes.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property string cli: home + "/.local/bin/claude-menu"
    readonly property string conf: Quickshell.env("CM_CONF") ?? ""
    readonly property var dirs: (Quickshell.env("CM_DIRS") ?? (home + "/claude")).split("\n").filter(d => d !== "")
    property var missing: ({})
    property int sel: 0
    readonly property int count: dirs.length + 1     // + "Edit folders…"

    function pretty(d) { return d.startsWith(root.home + "/") ? "~" + d.substring(root.home.length) : d; }
    function pick(i) {
        if (i < 0 || i >= root.count) return;
        if (i === root.dirs.length) {
            Quickshell.execDetached(["kitty", "--title", "Claude folders", "sh", "-c", "${EDITOR:-nano} \"$1\"", "_", root.conf]);
        } else {
            if (root.missing[root.dirs[i]]) return;
            Quickshell.execDetached([root.cli, "run", root.dirs[i]]);
        }
        Qt.quit();
    }

    // folders that don't exist (~/claude is created on start, so it never counts)
    Process {
        running: true
        command: ["sh", "-c", "for d; do [ -d \"$d\" ] || printf '%s\\n' \"$d\"; done", "_"].concat(root.dirs.slice(1))
        stdout: SplitParser { onRead: line => { let m = Object.assign({}, root.missing); m[line] = true; root.missing = m; } }
    }

    // ---- Matugen colours ---------------------------------------------------------------------
    property color cBase: "#1e1e2e"
    property color cText: "#cdd6f4"
    property color cSub: "#a6adc8"
    property color cAccent: "#89b4fa"
    FileView {
        path: root.home + "/.local/state/serpantinum/qs_matugen_colors.json"
        onLoaded: {
            try {
                let c = JSON.parse(text()); c = c.colors ?? c;
                root.cBase = c.base ?? root.cBase; root.cText = c.text ?? root.cText;
                root.cSub = c.subtext0 ?? root.cSub; root.cAccent = c.blue ?? root.cAccent;
            } catch (e) {}
        }
    }

    // =============================================================================================
    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "claude-menu"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        BackgroundEffect.blurRegion: Region {
            x: Math.round(card.x); y: Math.round(card.y + card.slide)
            width: Math.round(card.width); height: Math.round(card.height)
            radius: card.radius
        }

        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                let k = event.key;
                event.accepted = true;
                if (k === Qt.Key_Escape || k === Qt.Key_Q) Qt.quit();
                else if (k >= Qt.Key_1 && k <= Qt.Key_9) root.pick(k - Qt.Key_1 < root.dirs.length ? k - Qt.Key_1 : -1);
                else if (k === Qt.Key_Down || k === Qt.Key_J || k === Qt.Key_Tab) root.sel = (root.sel + 1) % root.count;
                else if (k === Qt.Key_Up || k === Qt.Key_K || k === Qt.Key_Backtab) root.sel = (root.sel + root.count - 1) % root.count;
                else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) root.pick(root.sel);
                else if (k === Qt.Key_E) root.pick(root.dirs.length);
                else event.accepted = false;
            }
        }

        Item {
            id: card
            readonly property real pad: 18
            readonly property real radius: 20
            width: Math.min(win.width - 32, 460)
            height: content.implicitHeight + 2 * pad
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(win.height * 0.2)
            property real slide: (1 - opacity) * 12
            transform: Translate { y: card.slide }
            opacity: 0
            NumberAnimation on opacity { running: true; from: 0; to: 1; duration: 380; easing.type: Easing.OutCubic }

            MouseArea { anchors.fill: parent }

            RectangularShadow {
                anchors.fill: parent; radius: card.radius; offset.y: 8; blur: 36
                color: Qt.rgba(0, 0, 0, 0.42); cached: true
            }
            ShaderEffect {
                anchors.fill: parent
                property size size: Qt.size(width, height)
                property real radius: card.radius
                property real rimWidth: 1.2
                property vector4d tint: Qt.vector4d(root.cBase.r, root.cBase.g, root.cBase.b, 0.62)
                property vector4d rimTop: Qt.vector4d(1, 1, 1, 0.44)
                property vector4d rimBottom: Qt.vector4d(1, 1, 1, 0.07)
                property real sheen: 0.05
                fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
            }

            Column {
                id: content
                x: card.pad; y: card.pad
                width: card.width - 2 * card.pad
                spacing: 10

                Text {
                    leftPadding: 6
                    text: "Claude Code — where?"
                    color: root.cText
                    font.family: "Google Sans"; font.pixelSize: 16; font.weight: Font.DemiBold
                }

                Column {
                    width: parent.width
                    spacing: 2
                    Repeater {
                        model: root.count
                        Rectangle {
                            id: row
                            required property int index
                            readonly property bool edit: index === root.dirs.length
                            readonly property string path: edit ? "" : root.dirs[index]
                            readonly property bool gone: !edit && root.missing[path] === true
                            width: parent.width; height: edit ? 40 : 50; radius: 12
                            color: index === root.sel ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.20)
                                 : (ma.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent")
                            Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            opacity: gone ? 0.45 : 1
                            Rectangle {
                                x: 8; anchors.verticalCenter: parent.verticalCenter
                                width: row.edit ? 26 : 34; height: width; radius: 10
                                color: Qt.rgba(1, 1, 1, row.index === root.sel ? 0.14 : 0.07)
                                Text {
                                    anchors.centerIn: parent
                                    text: row.edit ? "✎" : (row.index === 0 ? "✳" : "▸")
                                    color: row.index === root.sel ? root.cAccent : root.cText
                                    font.family: "Google Sans"; font.pixelSize: row.edit ? 12 : 15; font.weight: Font.DemiBold
                                }
                            }
                            Column {
                                x: row.edit ? 46 : 54; anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - x - 36
                                Text {
                                    width: parent.width; elide: Text.ElideRight
                                    text: row.edit ? "Edit folders…" : (row.path.split("/").pop() || row.path)
                                    color: row.edit ? root.cSub : root.cText
                                    font.family: "Google Sans"; font.pixelSize: row.edit ? 13 : 14; font.weight: Font.Medium
                                }
                                Text {
                                    visible: !row.edit
                                    width: parent.width; elide: Text.ElideMiddle
                                    text: root.pretty(row.path) + (row.gone ? "  (missing)" : "")
                                    color: root.cSub; opacity: 0.75; font.family: "Google Sans"; font.pixelSize: 11
                                }
                            }
                            Text {
                                anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                                text: row.edit ? "E" : (row.index < 9 ? String(row.index + 1) : "")
                                color: root.cSub; opacity: 0.5; font.family: "Google Sans"; font.pixelSize: 12
                            }
                            MouseArea {
                                id: ma
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: row.gone ? Qt.ArrowCursor : Qt.PointingHandCursor
                                onEntered: root.sel = row.index
                                onClicked: root.pick(row.index)
                            }
                        }
                    }
                }
            }
        }
    }
}
