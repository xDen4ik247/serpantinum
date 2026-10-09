// aidict recording pill: a small liquid-glass capsule at the bottom centre while dictating.
// Started by the aidict daemon (dictd.py); state comes from the JSON file in $AIDICT_STATE
// (phase: recording -> transcribing -> done | error -> idle). Never takes keyboard focus,
// so the focused window keeps receiving the typed text. Quits itself on "idle".
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root
    readonly property string home: Quickshell.env("HOME") ?? ""
    property var st: ({ phase: "recording", level: 0 })
    readonly property string phase: st.phase ?? "recording"
    property real level: 0
    property real elapsed: 0
    property bool leaving: false

    property color cBase: "#1e1e2e"
    property color cText: "#cdd6f4"
    property color cSub: "#a6adc8"
    property color cAccent: "#89b4fa"
    property color cRed: "#f38ba8"
    FileView {
        path: root.home + "/.local/state/serpantinum/qs_matugen_colors.json"
        onLoaded: {
            try {
                let c = JSON.parse(text()); c = c.colors ?? c;
                root.cBase = c.base ?? root.cBase; root.cText = c.text ?? root.cText;
                root.cSub = c.subtext0 ?? root.cSub; root.cAccent = c.blue ?? root.cAccent;
                root.cRed = c.red ?? root.cRed;
            } catch (e) {}
        }
    }
    FileView {
        id: sf
        path: Quickshell.env("AIDICT_STATE") ?? ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.st = JSON.parse(text()); } catch (e) { return; }
            root.level = root.st.level ?? 0;
            if (root.phase === "idle" && !root.leaving) { root.leaving = true; bye.start(); }
        }
    }
    Timer { interval: 80; repeat: true; running: true; onTriggered: { sf.reload(); if (root.st.t0) root.elapsed = Date.now() / 1000 - root.st.t0; } }
    SequentialAnimation {
        id: bye
        NumberAnimation { target: pill; property: "opacity"; to: 0; duration: 260; easing.type: Easing.OutCubic }
        ScriptAction { script: Qt.quit() }
    }

    PanelWindow {
        id: win
        anchors.bottom: true
        margins.bottom: 34
        implicitWidth: 460
        implicitHeight: 76
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "aidict"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}
        BackgroundEffect.blurRegion: Region {
            x: Math.round(pill.x); y: Math.round(pill.y)
            width: Math.round(pill.width); height: Math.round(pill.height)
            radius: pill.height / 2
        }

        Item {
            id: pill
            readonly property bool rec: root.phase === "recording"
            readonly property bool busy: root.phase === "transcribing"
            height: 44
            width: Math.min(win.width - 20, row.implicitWidth + 36)
            anchors.horizontalCenter: parent.horizontalCenter
            y: 16
            Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutQuint } }
            opacity: 0
            scale: 0.92
            Component.onCompleted: { opacity = 1; scale = 1; }
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }

            RectangularShadow {
                anchors.fill: parent; radius: height / 2; offset.y: 5; blur: 24
                color: Qt.rgba(0, 0, 0, 0.38); cached: true
            }
            ShaderEffect {
                anchors.fill: parent
                property size size: Qt.size(width, height)
                property real radius: height / 2
                property real rimWidth: 1.2
                property vector4d tint: Qt.vector4d(root.cBase.r, root.cBase.g, root.cBase.b, 0.58)
                property vector4d rimTop: Qt.vector4d(1, 1, 1, 0.46)
                property vector4d rimBottom: Qt.vector4d(1, 1, 1, 0.07)
                property real sheen: 0.05
                fragmentShader: Qt.resolvedUrl("shaders/glass.frag.qsb")
            }

            Row {
                id: row
                anchors.centerIn: parent
                spacing: 12

                // pulsing record dot / spinner / check
                Item {
                    width: 16; height: 16
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                        anchors.centerIn: parent
                        width: 16 + root.level * 10; height: width; radius: width / 2
                        color: root.cRed; opacity: pill.rec ? 0.25 : 0
                        Behavior on width { NumberAnimation { duration: 90 } }
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        width: 10; height: 10; radius: 5
                        color: pill.rec ? root.cRed : (root.phase === "error" ? root.cSub : root.cAccent)
                        visible: !pill.busy
                        SequentialAnimation on opacity {
                            running: pill.rec; loops: Animation.Infinite
                            NumberAnimation { to: 0.45; duration: 600; easing.type: Easing.InOutCubic }
                            NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutCubic }
                        }
                    }
                    Rectangle {
                        anchors.centerIn: parent
                        visible: pill.busy
                        width: 14; height: 14; radius: 7
                        color: "transparent"; border.width: 2; border.color: root.cAccent
                        Rectangle { width: 5; height: 5; radius: 2.5; color: root.cAccent; x: 4.5; y: -1.5 }
                        RotationAnimation on rotation { running: pill.busy; loops: Animation.Infinite; from: 0; to: 360; duration: 900 }
                    }
                }

                // live level meter (recording only)
                Row {
                    visible: pill.rec
                    spacing: 3
                    anchors.verticalCenter: parent.verticalCenter
                    Repeater {
                        model: 9
                        Rectangle {
                            required property int index
                            readonly property real shape: 1 - Math.abs(index - 4) / 5
                            width: 3; radius: 1.5
                            height: 4 + 18 * root.level * shape * (0.75 + 0.25 * Math.sin(root.elapsed * 9 + index))
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.cText; opacity: 0.85
                            Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                        }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 330)
                    elide: Text.ElideRight
                    color: root.cText
                    font.family: "Google Sans"; font.pixelSize: 14; font.weight: Font.Medium
                    text: pill.rec ? "Listening" : pill.busy ? "Transcribing…"
                        : root.phase === "error" ? (root.st.text ?? "Error")
                        : (root.st.how === "clipboard" ? "Copied · " : "") + (root.st.text ?? "")
                }
                Rectangle {
                    visible: pill.rec || root.phase === "done"
                    anchors.verticalCenter: parent.verticalCenter
                    height: 20; radius: 10
                    width: chip.implicitWidth + 14
                    color: Qt.rgba(1, 1, 1, 0.09)
                    Text {
                        id: chip
                        anchors.centerIn: parent
                        color: root.cSub
                        font.family: "Google Sans"; font.pixelSize: 11
                        text: pill.rec
                            ? (root.st.lang === "auto" ? "AUTO" : (root.st.lang ?? "auto").toUpperCase()) + " · "
                              + Math.floor(root.elapsed / 60) + ":" + ("0" + Math.floor(root.elapsed % 60)).slice(-2)
                            : (root.st.asr_ms ?? 0) + " ms · NPU"
                    }
                }
            }
        }
    }
}
